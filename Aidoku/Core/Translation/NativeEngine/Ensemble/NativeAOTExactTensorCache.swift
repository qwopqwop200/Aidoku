import CoreML
import CryptoKit
import Foundation
import CoreGraphics
import ImageIO

/// Default-OFF exact inference cache owns FP16 output BYTES, never a caller's
/// mutable MLMultiArray. Both existing AOT resident implementations can call
/// this seam after filling their actual image+mask tensors, before scattering.
@available(iOS 16.0, macOS 13.0, *)
final class NativeAOTExactTensorCache: @unchecked Sendable {
    static let shared = NativeAOTExactTensorCache()
    static let imageBytes = 3*1024*1024*2
    static let maskBytes = 1024*1024*2
    static let outputBytes = imageBytes // RGB FP16 is6MiB, NEVER4MiB RGBA8.
    struct Policy: Codable {
        let installedModelSHA256: String
        let computeUnits: String
        let runtime: String
        let tensorABI: String
    }
    struct Lookup {
        let raw: MLMultiArray
        let hit: Bool
        let key: String
        let metrics: [String: Double]
    }
    enum Failure: Error { case inputContract, policy, allocation }
    private struct Entry { let bytes: Data }
    private let lock = NSLock()
    private let budget: Int
    private var entries: [Data: Entry] = [:]
    private var order: [Data] = []
    private var retainedBytes = 0
    private var hits = 0, freshClosures = 0, rejectedSnapshots = 0
    init(budget: Int = 64*1_048_576) { self.budget = min(64*1_048_576,max(0,budget)) }

    private static func valid(_ value: MLMultiArray, mask: Bool) -> Bool {
        value.dataType == .float16 &&
        value.shape.map(\.intValue) == [1,mask ? 1 : 3,1024,1024] &&
        value.strides.map(\.intValue) == [mask ? 1048576 : 3145728,1048576,1024,1]
    }
    func key(image: MLMultiArray, mask: MLMultiArray, policy: Policy) throws -> Data {
        guard Self.valid(image,mask:false), Self.valid(mask,mask:true) else { throw Failure.inputContract }
        guard policy.installedModelSHA256.count == 64,
              policy.installedModelSHA256.allSatisfy(\.isHexDigit),
              !policy.computeUnits.isEmpty, !policy.runtime.isEmpty, !policy.tensorABI.isEmpty else { throw Failure.policy }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        hash.update(data: Data("aot-exact-f16-inputs-v1\0".utf8))
        hash.update(data: try encoder.encode(policy))
        // All padded1024 input bits, including every mask pixel. No image ID,
        // crop bounds, original text, GT or approximate input enters this key.
        hash.update(bufferPointer: UnsafeRawBufferPointer(start: image.dataPointer,count:Self.imageBytes))
        hash.update(bufferPointer: UnsafeRawBufferPointer(start: mask.dataPointer,count:Self.maskBytes))
        return Data(hash.finalize())
    }
    private func reserve(_ bytes: Int) {
        while retainedBytes > max(0,budget-bytes), !order.isEmpty {
            let old = order.removeFirst()
            if let value = entries.removeValue(forKey:old) { retainedBytes -= value.bytes.count }
        }
    }
    /// Existing per-resident executor must still protect its input tensor writes.
    /// Serial shared closure also coalesces concurrent identical model requests.
    /// Clear waits for uninterruptible CoreML work; no second generation can
    /// begin while the protected synchronous prediction is still executing.
    func predict(image: MLMultiArray, mask: MLMultiArray, policy: Policy,
                 fresh: () throws -> MLMultiArray) throws -> Lookup {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        let keyStart = ProcessInfo.processInfo.systemUptime
        let identity = try key(image:image,mask:mask,policy:policy)
        let keySeconds = ProcessInfo.processInfo.systemUptime-keyStart
        let text = identity.map {String(format:"%02x",$0)}.joined()
        if let entry = entries[identity] {
            order.removeAll {$0 == identity}; order.append(identity)
            let copyStart = ProcessInfo.processInfo.systemUptime
            let raw = try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
            guard Self.valid(raw,mask:false) else {throw Failure.allocation}
            entry.bytes.withUnsafeBytes { raw.dataPointer.copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
            try Task.checkCancellation()
            hits += 1
            return Lookup(raw:raw,hit:true,key:text,metrics:["keySeconds":keySeconds,
                "hitOutputCopySeconds":ProcessInfo.processInfo.systemUptime-copyStart,
                "storeOutputCopySeconds":0,"outputValidationSeconds":0])
        }
        reserve(Self.outputBytes)
        try Task.checkCancellation()
        freshClosures += 1
        let raw = try fresh()
        try Task.checkCancellation()
        let validationStart = ProcessInfo.processInfo.systemUptime
        var admissible = Self.valid(raw,mask:false)
        if admissible {
            let values = raw.dataPointer.assumingMemoryBound(to:UInt16.self)
            for i in 0..<(Self.outputBytes/2) {
                if i % (1024*1024) == 0 { try Task.checkCancellation() }
                if values[i] & 0x7c00 == 0x7c00 { admissible = false; break }
            }
        }
        let validationSeconds = ProcessInfo.processInfo.systemUptime-validationStart
        var copySeconds: Double = 0
        if admissible, Self.outputBytes <= budget {
            let start = ProcessInfo.processInfo.systemUptime
            let bytes = Data(bytes:raw.dataPointer,count:Self.outputBytes)
            copySeconds = ProcessInfo.processInfo.systemUptime-start
            try Task.checkCancellation()
            entries[identity] = Entry(bytes:bytes); order.append(identity); retainedBytes += bytes.count
        } else if !admissible {
            // Preserve existing native behavior for an unsupported/nonfinite
            // unused output: return actual raw for its ORIGINAL compose checks,
            // but never cache it or silently manufacture finite values.
            rejectedSnapshots += 1
        }
        return Lookup(raw:raw,hit:false,key:text,metrics:["keySeconds":keySeconds,
            "hitOutputCopySeconds":0,"storeOutputCopySeconds":copySeconds,
            "outputValidationSeconds":validationSeconds])
    }
    static func discardWhenIdle() async {
        await Task.detached(priority: .utility) { shared.clear() }.value
    }
    func clear() {
        lock.lock(); defer {lock.unlock()}
        entries.removeAll();order.removeAll();retainedBytes=0
    }
    func statistics() -> [String:Int] {
        lock.lock();defer {lock.unlock()}
        return ["retainedBytes":retainedBytes,"entries":entries.count,"budget":budget,
                "hits":hits,"freshClosures":freshClosures,"rejectedSnapshots":rejectedSnapshots]
    }
}


/// Process-wide policy is inherited equally by reader and host detached work.
/// OFF keeps the direct native prediction path, without model or input hashing.
enum NativeAOTTensorCachePolicy {
    static let enabled = ProcessInfo.processInfo.environment["AIDOKU_AOT_TENSOR_CACHE"] == "1"
    static let tensorABI = "masked_image:f16:1x3x1024x1024;mask:f16:1x1x1024x1024;raw_rgb:f16:1x3x1024x1024;v1"
}

/// Deliberately AOT-local until a separately reviewed common fingerprint helper
/// extraction; stable RF source/lifecycle is not refactored in this change.
enum NativeAOTCompiledModelIdentity {
    // Recompute ONCE PER RESIDENT binding, never memoize by URL/mtime/length.
    // A replaced compiled tree at the same path must get its new byte identity.
    static func digest(_ input: URL) throws -> String {
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL, url.pathExtension == "mlmodelc",
              let iterator = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var files: [URL] = []
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            if values.isRegularFile == true { files.append(file) }
        }
        guard !files.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var hash = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let relative = String(file.path.dropFirst(url.path.count + 1))
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            hash.update(data: Data("\(relative.utf8.count):\(relative):\(size):".utf8))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        }
        let value = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return value
    }
}

/// Explicit selected-bank capture only. Bytes are copied from the ACTUAL raw
/// MLMultiArray, never reconstructed from post-clamped restored PNG pixels.
@available(iOS 16.0, macOS 13.0, *)
struct NativeAOTRawPredictionSnapshot {
    struct Binding: Codable {
        let schema: String
        let producerSHA256: String
        let producerConfigSHA256: String
        let policy: NativeAOTExactTensorCache.Policy
        let sourceCanonicalRGBASHA256: String
        let sourceInferenceRGBSHA256: String
        let originalMaskSHA256: String
        let inputImageSHA256: String
        let inputMaskSHA256: String
        let exactTensorKey: String
        let rawSHA256: String
        let width: Int, height: Int, contentWidth: Int, contentHeight: Int
        let dtype: String, endian: String
        let shape: [Int], strides: [Int]
        let compositionABI: String
    }
    enum Failure: Error { case binding, tensor, producer, endian, budget, destination }
    let binding: Binding
    let rawBytes: Data
    /// Capture-only original-coordinate bytes for an explicit host archive sink.
    /// Not serialized in legacy bindings; archive readers and two-argument
    /// constructors retain nil. Append still independently verifies source/mask
    /// and regenerated tensor bytes; this context is not an admission shortcut.
    let capturedOriginalMask: [UInt8]?
    init(binding: Binding, rawBytes: Data, capturedOriginalMask: [UInt8]? = nil) {
        self.binding = binding; self.rawBytes = rawBytes
        self.capturedOriginalMask = capturedOriginalMask
    }
    static let compositionABI = "whole1024-area-anyhit-halfpixel-f32-double-originalmask-alpha-v1"
    static func sha(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    static func sha(_ bytes: [UInt8]) -> String { bytes.withUnsafeBytes(shaBuffer) }
    private static func shaBuffer(_ bytes: UnsafeRawBufferPointer) -> String {
        var hash = SHA256()
        hash.update(bufferPointer: bytes)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    // Called after key() checks dtype, shape and dense strides; do not duplicate the 8 MiB model input.
    private static func tensorSHA(_ array: MLMultiArray, count: Int) -> String {
        withExtendedLifetime(array) { shaBuffer(UnsafeRawBufferPointer(start: array.dataPointer, count: count)) }
    }
    static func validSHA(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }

    static func capture(source: CGImage, originalMask: [UInt8], image: MLMultiArray,
                        mask: MLMultiArray, raw: MLMultiArray,
                        policy: NativeAOTExactTensorCache.Policy, producerSHA256: String,
                        producerConfigSHA256: String) throws -> Self {
        guard validSHA(producerSHA256),validSHA(producerConfigSHA256) else { throw Failure.producer }
        guard UInt16(littleEndian:1) == 1 else { throw Failure.endian }
        let exactKey = try NativeAOTExactTensorCache(budget:0).key(image:image,mask:mask,policy:policy)
        guard raw.dataType == .float16,raw.shape.map(\.intValue) == [1,3,1024,1024],
              raw.strides.map(\.intValue) == [3145728,1048576,1024,1] else { throw Failure.tensor }
        let alpha = try NativeAOTAlphaComposition.prepare(source:source)
        guard originalMask.count == alpha.width*alpha.height,
              originalMask.allSatisfy({$0 == 0 || $0 == 1 || $0 == 255}) else { throw Failure.binding }
        let bytes = Data(bytes:raw.dataPointer,count:NativeAOTExactTensorCache.outputBytes)
        // Preserve every actual output bit, including unused nonfinite values;
        // original composition retains its own sampled-value finite checks.
        let scale = min(1,1024.0/Double(max(alpha.width,alpha.height)))
        let binding = Binding(schema:"actual-aot-raw-f16-v1",producerSHA256:producerSHA256,
            producerConfigSHA256:producerConfigSHA256,policy:policy,
            sourceCanonicalRGBASHA256:sha(alpha.canonicalRGBA),sourceInferenceRGBSHA256:sha(alpha.inferenceRGB),
            originalMaskSHA256:sha(originalMask),
            inputImageSHA256:tensorSHA(image,count:NativeAOTExactTensorCache.imageBytes),
            inputMaskSHA256:tensorSHA(mask,count:NativeAOTExactTensorCache.maskBytes),
            exactTensorKey:exactKey.map {String(format:"%02x",$0)}.joined(),rawSHA256:sha(bytes),
            width:alpha.width,height:alpha.height,
            contentWidth:min(1024,max(1,Int(ceil(Double(alpha.width)*scale)))),
            contentHeight:min(1024,max(1,Int(ceil(Double(alpha.height)*scale)))),
            dtype:"float16",endian:"little",shape:[1,3,1024,1024],strides:[3145728,1048576,1024,1],
            compositionABI:compositionABI)
        return Self(binding:binding,rawBytes:bytes,capturedOriginalMask:originalMask)
    }

    /// Rebuild exact8MiB inputs from actual source/mask references and verify all
    /// bits BEFORE either variant is composed. No model instance is constructed.
    func validatedInputs(source: CGImage, originalMask: [UInt8]) throws -> NativeAOTAlphaComposition.Source {
        let b = binding
        guard b.schema == "actual-aot-raw-f16-v1",b.compositionABI == Self.compositionABI,
              b.dtype == "float16",b.endian == "little",UInt16(littleEndian:1) == 1,
              b.shape == [1,3,1024,1024],b.strides == [3145728,1048576,1024,1],
              rawBytes.count == NativeAOTExactTensorCache.outputBytes,Self.sha(rawBytes) == b.rawSHA256,
              source.width == b.width,source.height == b.height,
              originalMask.count == b.width*b.height,Self.sha(originalMask) == b.originalMaskSHA256,
              Self.validSHA(b.producerSHA256),Self.validSHA(b.producerConfigSHA256) else { throw Failure.binding }
        let alpha = try NativeAOTAlphaComposition.prepare(source:source)
        guard Self.sha(alpha.canonicalRGBA) == b.sourceCanonicalRGBASHA256,
              Self.sha(alpha.inferenceRGB) == b.sourceInferenceRGBSHA256 else { throw Failure.binding }
        let image = try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        let mask = try MLMultiArray(shape:[1,1,1024,1024],dataType:.float16)
        let content = try NativeResidentAOT.prepare(rgb:alpha.inferenceRGB,finalMask:originalMask,
            width:b.width,height:b.height,image:image,mask:mask)
        let key = try NativeAOTExactTensorCache(budget:0).key(image:image,mask:mask,policy:b.policy)
        guard content.0 == b.contentWidth,content.1 == b.contentHeight,
              key.map({String(format:"%02x",$0)}).joined() == b.exactTensorKey,
              Self.tensorSHA(image,count:NativeAOTExactTensorCache.imageBytes) == b.inputImageSHA256,
              Self.tensorSHA(mask,count:NativeAOTExactTensorCache.maskBytes) == b.inputMaskSHA256 else { throw Failure.binding }
        return alpha
    }
    func compose(source: CGImage, originalMask: [UInt8], calibrateBoundaryBias: Bool) throws -> NativeAOTResult {
        let alpha = try validatedInputs(source:source,originalMask:originalMask)
        let raw = try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        rawBytes.withUnsafeBytes {raw.dataPointer.copyMemory(from:$0.baseAddress!,byteCount:$0.count)}
        return try NativeResidentAOT.composeRestoration(source:alpha,originalMask:originalMask,raw:raw,
            content:(binding.contentWidth,binding.contentHeight),calibrateBoundaryBias:calibrateBoundaryBias)
    }
    func composeVariants(source: CGImage, originalMask: [UInt8]) throws -> (simple: NativeAOTResult, complex: NativeAOTResult) {
        let alpha = try validatedInputs(source:source,originalMask:originalMask)
        let raw = try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        rawBytes.withUnsafeBytes {raw.dataPointer.copyMemory(from:$0.baseAddress!,byteCount:$0.count)}
        let simple = try NativeResidentAOT.composeRestoration(source:alpha,originalMask:originalMask,raw:raw,
            content:(binding.contentWidth,binding.contentHeight),calibrateBoundaryBias:false)
        let complex = try NativeResidentAOT.composeRestoration(source:alpha,originalMask:originalMask,raw:raw,
            content:(binding.contentWidth,binding.contentHeight),calibrateBoundaryBias:true)
        return (simple,complex)
    }
}

/// Root explicitly owns one selected bank and its <=12GiB budget. No globals,
/// environment-triggered writes, silent truncation, tensor recasting or eviction.
@available(iOS 16.0, macOS 13.0, *)
final class NativeAOTRawPredictionArchive: @unchecked Sendable {
    private let directory: URL
    private let budget: Int
    private var retained = 0
    private let lock = NSLock()
    init(directory: URL, byteBudget: Int) throws {
        guard directory.isFileURL,byteBudget > 0,byteBudget <= 12*1024*1024*1024,
              !FileManager.default.fileExists(atPath:directory.path) else { throw NativeAOTRawPredictionSnapshot.Failure.destination }
        self.directory=directory;self.budget=byteBudget
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    private static func image(_ url: URL) throws -> (Data,CGImage) {
        let data=try Data(contentsOf:url)
        guard let src=CGImageSourceCreateWithData(data as CFData,nil),
              let image=CGImageSourceCreateImageAtIndex(src,0,nil) else { throw NativeAOTRawPredictionSnapshot.Failure.binding }
        let properties=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any]
        guard ((properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1) == 1 else { throw NativeAOTRawPredictionSnapshot.Failure.binding }
        return(data,image)
    }
    /// Source encoded provenance is checked against its actual file. Original
    /// masks are strict gray8/binary; input tensor hashes are regenerated, not
    /// accepted merely because a filename or producer metadata looks plausible.
    func append(_ snapshot: NativeAOTRawPredictionSnapshot, sourceFile: URL,
                expectedSourceEncodedSHA256: String, originalMaskFile: URL) throws -> URL {
        lock.lock();defer {lock.unlock()}
        try Task.checkCancellation()
        let (sourceData,source)=try Self.image(sourceFile), (maskData,mask)=try Self.image(originalMaskFile)
        guard NativeAOTRawPredictionSnapshot.sha(sourceData) == expectedSourceEncodedSHA256,
              source.width > 0,source.height > 0,source.width <= 32_000_000/source.height,
              mask.width == source.width,mask.height == source.height,!mask.isMask,
              mask.bitsPerComponent == 8,mask.bitsPerPixel == 8,mask.colorSpace?.model == .monochrome,
              mask.alphaInfo == .none else { throw NativeAOTRawPredictionSnapshot.Failure.binding }
        var binary=[UInt8](repeating:0,count:mask.width*mask.height)
        try binary.withUnsafeMutableBytes {bytes in
            guard let context=CGContext(data:bytes.baseAddress,width:mask.width,height:mask.height,bitsPerComponent:8,
                bytesPerRow:mask.width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)
            else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
            context.setBlendMode(.copy);context.interpolationQuality = .none
            context.draw(mask,in:CGRect(x:0,y:0,width:mask.width,height:mask.height))
        }
        guard binary.allSatisfy({$0 == 0 || $0 == 255}) else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
        _ = try snapshot.validatedInputs(source:source,originalMask:binary)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bindingData=try encoder.encode(snapshot.binding)
        let identity=NativeAOTRawPredictionSnapshot.sha(bindingData+Data(expectedSourceEncodedSHA256.utf8))
        let rawURL=directory.appendingPathComponent(identity+".raw-f16le")
        let metadataURL=directory.appendingPathComponent(identity+".json")
        if FileManager.default.fileExists(atPath:metadataURL.path) {
            // Exact duplicates may share one immutable record; callers retain
            // ALL source aliases/context rows pointing to that record. Verify
            // the existing raw and references, never replace or ordinal-join.
            let existing = try Self.read(metadataURL)
            guard try encoder.encode(existing.snapshot.binding) == bindingData,
                  existing.snapshot.rawBytes == snapshot.rawBytes else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
            return metadataURL
        }
        guard !FileManager.default.fileExists(atPath:rawURL.path) else {throw NativeAOTRawPredictionSnapshot.Failure.destination}
        let metadata:[String:Any] = ["schema":"actual-aot-raw-reference-archive-v1",
            "binding":try JSONSerialization.jsonObject(with:bindingData),"rawFile":rawURL.lastPathComponent,
            "rawByteCount":snapshot.rawBytes.count,"sourceReference":sourceFile.standardizedFileURL.path,
            "sourceEncodedSHA256":expectedSourceEncodedSHA256,"maskReference":originalMaskFile.standardizedFileURL.path,
            "maskEncodedSHA256":NativeAOTRawPredictionSnapshot.sha(maskData),
            "inputTensorsStored":false,"inputTensorsRegeneratedAndBitVerified":true]
        let data=try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys])
        let bytes=snapshot.rawBytes.count+data.count
        guard bytes <= budget-retained else {throw NativeAOTRawPredictionSnapshot.Failure.budget}
        try snapshot.rawBytes.write(to:rawURL,options:.atomic)
        retained+=snapshot.rawBytes.count // failed metadata remains accounted, never a complete record.
        try data.write(to:metadataURL,options:.atomic);retained+=data.count
        return metadataURL
    }
    static func read(_ metadataURL: URL) throws -> (snapshot: NativeAOTRawPredictionSnapshot, source: CGImage, originalMask: [UInt8]) {
        let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:metadataURL)) as? [String:Any]
        guard let m=metadata,m["schema"] as? String == "actual-aot-raw-reference-archive-v1",
              let sourcePath=m["sourceReference"] as? String,let maskPath=m["maskReference"] as? String,
              let rawName=m["rawFile"] as? String,rawName == URL(fileURLWithPath:rawName).lastPathComponent,
              rawName.hasSuffix(".raw-f16le"),let encoded=m["sourceEncodedSHA256"] as? String,
              m["rawByteCount"] as? Int == NativeAOTExactTensorCache.outputBytes,
              let record=m["binding"] else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
        let binding=try JSONDecoder().decode(NativeAOTRawPredictionSnapshot.Binding.self,
            from:JSONSerialization.data(withJSONObject:record))
        let rawURL=metadataURL.deletingLastPathComponent().appendingPathComponent(rawName)
        let attributes=try FileManager.default.attributesOfItem(atPath:rawURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue == NativeAOTExactTensorCache.outputBytes else {throw NativeAOTRawPredictionSnapshot.Failure.tensor}
        let snapshot=NativeAOTRawPredictionSnapshot(binding:binding,rawBytes:try Data(contentsOf:rawURL))
        let (sourceData,source)=try image(URL(fileURLWithPath:sourcePath)),(maskData,mask)=try image(URL(fileURLWithPath:maskPath))
        guard NativeAOTRawPredictionSnapshot.sha(sourceData) == encoded,
              NativeAOTRawPredictionSnapshot.sha(maskData) == m["maskEncodedSHA256"] as? String,
              source.width == binding.width,source.height == binding.height,
              source.width > 0,source.height > 0,source.width <= 32_000_000/source.height,
              mask.width == source.width,mask.height == source.height,!mask.isMask,
              mask.bitsPerComponent == 8,mask.bitsPerPixel == 8,mask.colorSpace?.model == .monochrome,
              mask.alphaInfo == .none else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
        var binary=[UInt8](repeating:0,count:mask.width*mask.height)
        try binary.withUnsafeMutableBytes {bytes in
            guard let context=CGContext(data:bytes.baseAddress,width:mask.width,height:mask.height,bitsPerComponent:8,
                bytesPerRow:mask.width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)
            else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
            context.setBlendMode(.copy);context.interpolationQuality = .none
            context.draw(mask,in:CGRect(x:0,y:0,width:mask.width,height:mask.height))
        }
        guard binary.allSatisfy({$0 == 0 || $0 == 255}) else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
        _ = try snapshot.validatedInputs(source:source,originalMask:binary)
        return(snapshot,source,binary)
    }
}

/// Explicit read-only replay of a ROOT-attested selected raw bank. This is NOT
/// a page/route/GT lookup: only the complete actual padded8MiB tensor+model key
/// can hit. No RGB/input tensors/global output bytes are retained in memory.
@available(iOS 16.0, macOS 13.0, *)
final class NativeAOTRawPredictionReplay: @unchecked Sendable {
    struct Lookup {
        let raw: MLMultiArray?
        let key: String
        let metadataSHA256: String?
        let seconds: Double
    }
    private struct Entry { let raw: URL; let rawSHA256: String; let metadataSHA256: String }
    private let entries: [String: Entry]
    let indexSHA256: String
    let producerSHA256: String
    let producerConfigSHA256: String
    let compiledModelSHA256: String
    init(indexFile: URL, expectedIndexSHA256: String) throws {
        let data=try Data(contentsOf:indexFile)
        guard NativeAOTRawPredictionSnapshot.validSHA(expectedIndexSHA256),
              NativeAOTRawPredictionSnapshot.sha(data)==expectedIndexSHA256,
              let index=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              index["schema"] as? String == "attested-exact-AOT-raw-replay-index-v1",
              let producer=index["producerSHA256"] as? String,
              let config=index["producerConfigSHA256"] as? String,
              let model=index["compiledModelSHA256"] as? String,
              [producer,config,model].allSatisfy(NativeAOTRawPredictionSnapshot.validSHA),
              let records=index["records"] as? [[String:String]] else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
        var built:[String:Entry]=[:]
        for record in records {
            guard let path=record["metadataPath"],path.hasPrefix("/"),let expected=record["metadataSHA256"],
                  NativeAOTRawPredictionSnapshot.validSHA(expected) else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
            let url=URL(fileURLWithPath:path),bytes=try Data(contentsOf:url)
            guard NativeAOTRawPredictionSnapshot.sha(bytes)==expected,
                  let m=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                  m["schema"] as? String == "actual-aot-raw-reference-archive-v1",
                  m["rawByteCount"] as? Int == NativeAOTExactTensorCache.outputBytes,
                  let rawFile=m["rawFile"] as? String,rawFile==URL(fileURLWithPath:rawFile).lastPathComponent,
                  rawFile.hasSuffix(".raw-f16le"),let rawBinding=m["binding"] else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
            let b=try JSONDecoder().decode(NativeAOTRawPredictionSnapshot.Binding.self,
                from:JSONSerialization.data(withJSONObject:rawBinding))
            guard b.schema=="actual-aot-raw-f16-v1",b.producerSHA256==producer,b.producerConfigSHA256==config,
                  b.policy.installedModelSHA256==model,b.policy.tensorABI==NativeAOTTensorCachePolicy.tensorABI,
                  b.dtype=="float16",b.endian=="little",b.shape==[1,3,1024,1024],b.strides==[3145728,1048576,1024,1],
                  NativeAOTRawPredictionSnapshot.validSHA(b.rawSHA256),NativeAOTRawPredictionSnapshot.validSHA(b.exactTensorKey)
            else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
            let raw=url.deletingLastPathComponent().appendingPathComponent(rawFile)
            guard (try raw.resourceValues(forKeys:[.fileSizeKey])).fileSize==NativeAOTExactTensorCache.outputBytes else {throw NativeAOTRawPredictionSnapshot.Failure.tensor}
            if let prior=built[b.exactTensorKey] {
                guard prior.rawSHA256==b.rawSHA256 else {throw NativeAOTRawPredictionSnapshot.Failure.binding}
            } else {built[b.exactTensorKey]=Entry(raw:raw,rawSHA256:b.rawSHA256,metadataSHA256:expected)}
        }
        entries=built;indexSHA256=expectedIndexSHA256;producerSHA256=producer;producerConfigSHA256=config;compiledModelSHA256=model
    }
    func lookup(image: MLMultiArray, mask: MLMultiArray, policy: NativeAOTExactTensorCache.Policy) throws -> Lookup {
        try Task.checkCancellation()
        let start=ProcessInfo.processInfo.systemUptime
        let key=try NativeAOTExactTensorCache(budget:0).key(image:image,mask:mask,policy:policy)
            .map{String(format:"%02x",$0)}.joined()
        guard let entry=entries[key] else {return Lookup(raw:nil,key:key,metadataSHA256:nil,seconds:ProcessInfo.processInfo.systemUptime-start)}
        let bytes=try Data(contentsOf:entry.raw)
        guard bytes.count==NativeAOTExactTensorCache.outputBytes,NativeAOTRawPredictionSnapshot.sha(bytes)==entry.rawSHA256,
              UInt16(littleEndian:1)==1 else {throw NativeAOTRawPredictionSnapshot.Failure.tensor}
        let raw=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        guard raw.strides.map(\.intValue)==[3145728,1048576,1024,1] else {throw NativeAOTRawPredictionSnapshot.Failure.tensor}
        bytes.withUnsafeBytes {raw.dataPointer.copyMemory(from:$0.baseAddress!,byteCount:$0.count)}
        try Task.checkCancellation()
        return Lookup(raw:raw,key:key,metadataSHA256:entry.metadataSHA256,seconds:ProcessInfo.processInfo.systemUptime-start)
    }
}
