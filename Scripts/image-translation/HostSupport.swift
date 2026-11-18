import AppKit
import CoreML
import CoreGraphics
import ImageIO
import Foundation
import Darwin

// Platform bridges only; OCR/merging/provider decisions come from production sources.
enum TranslationImageWorkBudget { static let minimumHeadroom: UInt64 = 1_280 * 1_024 * 1_024 }
enum BoundedTranslationBatchExecutor { static let allowedMaximumConcurrentRequests = 64 }
enum TranslationCredentialStoreError: Error { case notFound }
enum ReaderTranslationSession {
    static func processAvailableMemory() -> UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * UInt64(vm_page_size)
    }
}
struct ReaderTranslationSettings: Sendable {
    var includePageImage = true
    var shouldAttachPageImage: Bool { includePageImage }
    var sourceLanguage = "auto"
    var targetLanguage = "ko"
    var translationSourceLanguages: [String] = []
    var filterSFXWithLLM = true
    var filterBackgroundWithLLM = true
    var rightToLeftPanelOrder = false
    var modelTier = IPhoneOCRSettings.defaultModelTier
    var usesOCRLanguagePolicy = true
}
enum ReaderTranslationDiagnostics {
    static var context: HostDumpContext? { HostDump.context }
    static func record(_ event: String, count: Int = 0, code: Int = 0, context: HostDumpContext? = nil) {
        var values = ["count": count]
        if code != 0 { values["code"] = code }
        if let context { context.capture(event, values) }
        else { HostDump.capture(event, values) }
    }
}
enum ReaderOCRWordBoundaryResolver {
    @MainActor static func recognizedWords(in candidates: Set<String>) -> Set<String> {
        Set(candidates.filter { NSSpellChecker.shared.checkSpelling(of: $0, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound })
    }
    @MainActor static func unknownWordCount(in words: [String]) -> Int? {
        let known = recognizedWords(in: Set(words))
        return words.filter { !known.contains($0) }.count
    }
}
struct KeychainTranslationCredentialStore: TranslationCredentialProviding {
    static let maximumSecretBytes = 16 * 1024
    func secret(for account: String) throws -> String {
        guard let key = ProcessInfo.processInfo.environment[account], !key.isEmpty else { throw RemoteTranslationError.missingCredential }
        return key
    }
}
enum HostResources {
    static var bundle: Bundle { Bundle(path: ProcessInfo.processInfo.environment["AIDOKU_HOST_MODEL_BUNDLE"]!)! }
    static func prepare(root: URL, tier: IPhoneOCRModelTier, renderOnly: Bool = false,
                        detectorOnly:Bool = false) throws {
        let cache = ProcessInfo.processInfo.environment["AIDOKU_HOST_MODEL_CACHE"].map {
            URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
        } ?? root.appendingPathComponent("build/image-translation-host/Models.bundle")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = cache.deletingLastPathComponent().appendingPathComponent("models.lock")
        let descriptor = open(lockPath.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else { throw HostError.message("Cannot lock model cache") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let resources = cache.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "app.aidoku.ImageTranslationModels", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: cache.appendingPathComponent("Contents/Info.plist"))
        let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
        let source = root.appendingPathComponent("Aidoku/Resources/Translation")
        var modelNames = detectorOnly ? [profile.detectorResourceName] : (renderOnly ? [] : [profile.detectorResourceName, profile.recognizerResourceName])
        if !detectorOnly, NativeMainEnsembleRenderer.enabled { modelNames += ["AOT-1024-FP16", "KoharuHighres648FP16"] }
        if !renderOnly, !detectorOnly, ProcessInfo.processInfo.environment["AIDOKU_DISABLE_RF_LAYOUT"] != "1" {
            modelNames.append(NativeRFDETRLayoutResource.resourceName)
            if tier == .manga, !modelNames.contains(NativeRFDETRLayoutResource.rawCanonicalResourceName) {
                modelNames.append(NativeRFDETRLayoutResource.rawCanonicalResourceName)
            }
        }
        for name in modelNames {
            let package: URL
            if name == NativeRFDETRLayoutResource.resourceName,
               let candidate = ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_PACKAGE"] {
                package = URL(fileURLWithPath: candidate)
            } else {
                package = source.appendingPathComponent(name + ".mlpackage")
            }
            let destination = resources.appendingPathComponent(name + ".mlmodelc")
            // Compare every package file's path/size/mtime; a changed model must not reuse stale compilation.
            guard let enumerator = FileManager.default.enumerator(at: package,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                throw HostError.message("Model package not found: \(package.path)")
            }
            var entries: [String] = []
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                entries.append(file.path.replacingOccurrences(of: package.path, with: "") + ":\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
            let stamp = resources.appendingPathComponent(name + ".stamp")
            let signature = entries.sorted().joined(separator: "\n")
            if (try? String(contentsOf: stamp, encoding: .utf8)) != signature || !FileManager.default.fileExists(atPath: destination.path) {
                fputs("Compiling Core ML model \(name)…\n", stderr)
                let compiled = try MLModel.compileModel(at: package)
                defer { try? FileManager.default.removeItem(at: compiled) }
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: compiled, to: destination)
                try signature.write(to: stamp, atomically: true, encoding: .utf8)
            }
        }
        if !renderOnly, !detectorOnly {
            let dictionary = source.appendingPathComponent(profile.dictionaryResourceName + ".txt")
            try Data(contentsOf: dictionary).write(to: resources.appendingPathComponent(dictionary.lastPathComponent))
            if tier == .manga {
                let languageModel = source.appendingPathComponent("manga_ngram_v03.bin")
                let data = try Data(contentsOf: languageModel)
                let destination = resources.appendingPathComponent(languageModel.lastPathComponent)
                if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
            }
            for file in NativeOCRPremergePolicyBundle.File.allCases {
                let name = file.rawValue + ".json"
                let original = source.appendingPathComponent("PremergeSignalPolicy/" + name)
                let destination = resources.appendingPathComponent(name)
                let data = try Data(contentsOf: original)
                if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
            }
            if tier == .manga {
                for file in NativeOCRRawGeometryModelBundle.File.allCases {
                    let name = file.rawValue + ".json"
                    let data = try Data(contentsOf: source.appendingPathComponent("RawCanonicalGeometry/" + name))
                    let destination = resources.appendingPathComponent(name)
                    if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
                }
            }
        }
        setenv("AIDOKU_HOST_MODEL_BUNDLE", cache.path, 1)
    }
}

final class HostDumpContext: @unchecked Sendable {
    let directory: URL
    /// Actual encoded input for source-bound opt-in observers. Replays may
    /// write into a different directory; this context follows detached workers.
    let sourceURL: URL?
    let quiet: Bool
    private let lock = NSLock()
    private var sequence = 0
    private var failures: [String] = []
    private var capturedOCR: NativeMainEnsembleOCREvidence.Packet?
    var currentOCRPacket: NativeMainEnsembleOCREvidence.Packet? {
        lock.lock(); defer { lock.unlock() }
        return capturedOCR
    }
    /// Called only at the transformed host's current typed packet publication,
    /// before provider mutation. No lookup of a resident packet or old stage.
    func captureOCR(_ packet: NativeMainEnsembleOCREvidence.Packet) {
        lock.lock(); defer { lock.unlock() }
        guard capturedOCR == nil else {
            failures.append("multiple current OCR packet publications in one source invocation")
            return
        }
        capturedOCR = packet
    }
    /// Valid only for the same context, current OCR invocation, and an unchanged typed return.
    struct Mark {
        let contextID: UUID
        let generation: UUID
        let sequence: Int
    }
    private let contextID = UUID()
    private var activeGeneration: UUID?
    private var grouped: (generation: UUID, sequence: Int, url: URL, bytes: Int)?

    func markOrderedInput() -> Mark? {
        guard quiet else { return nil }
        lock.lock(); defer { lock.unlock() }
        let generation = UUID()
        activeGeneration = generation
        return Mark(contextID: contextID, generation: generation, sequence: sequence)
    }

    /// The caller must pass unchanged only when it has not mutated the OCR return value.
    /// Small payloads retain canonical encoding because cloning would cost more.
    @discardableResult
    func captureOrdered(_ value: Any, mark: Mark?, unchanged: Bool) -> Bool {
        lock.lock()
        if quiet, unchanged, let mark, mark.contextID == contextID,
           activeGeneration == mark.generation, let grouped,
           grouped.generation == mark.generation, grouped.sequence > mark.sequence,
           grouped.bytes >= 8192 {
            let next = sequence + 1
            let output = directory.appendingPathComponent(String(format: "%03d-", next) + "ordered-regions.json")
            if (try? ScopedAliasFile.write(source: grouped.url, to: output)) == true {
                sequence = next
                lock.unlock()
                return true
            }
        }
        lock.unlock()
        capture("ordered-regions", value)
        return false
    }
    init(directory: URL, quiet: Bool, sourceURL: URL? = nil) {
        self.directory = directory; self.quiet = quiet; self.sourceURL = sourceURL
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        sequence = names.compactMap { Int($0.prefix(while: { $0.isNumber })) }.max() ?? 0
    }
    func capture(_ stage: String, _ value: Any) {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let name = String(format: "%03d-", sequence) + stage + ".json"
        do {
            let converted = HostDump.json(value)
            let data = try JSONSerialization.data(withJSONObject: ["stage": stage, "value": converted], options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            if stage == "grouped-regions", let generation = activeGeneration {
                grouped = (generation, sequence, directory.appendingPathComponent(name), data.count)
            }
            if !quiet { print(String(decoding: data, as: UTF8.self)) }
        } catch { failures.append("\(name): \(error)") }
    }
    /// The native renderer has already serialized and decoded this JSON object.
    /// Keep the canonical encoder while avoiding Mirror's duplicate object graph.
    /// This specialized entry point rejects non-JSON values; ordinary captures
    /// retain their existing normalization of Swift models and nonfinite values.
    func captureJSONObject(_ stage: String, _ value: Any) {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let name = String(format: "%03d-", sequence) + stage + ".json"
        do {
            let envelope: [String: Any] = ["stage": stage, "value": value]
            guard JSONSerialization.isValidJSONObject(envelope) else {
                throw HostError.message("Native diagnostic object is not valid JSON")
            }
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            if !quiet { print(String(decoding: data, as: UTF8.self)) }
        } catch { failures.append("\(name): \(error)") }
    }
    func requireComplete() throws {
        lock.lock(); defer { lock.unlock() }
        if !failures.isEmpty { throw HostError.message("Diagnostic writes failed: " + failures.joined(separator: "; ")) }
    }
}
enum HostDump {
    @TaskLocal static var context: HostDumpContext?
    static func capture(_ stage: String, _ value: Any) { context?.capture(stage, value) }
    static func captureJSONObject(_ stage: String, _ value: Any) { context?.captureJSONObject(stage, value) }
    static func captureProbabilityMap(_ values: [Float], width: Int, height: Int, originX: Int, originY: Int, fullWidth: Int, fullHeight: Int, context: HostDumpContext?) {
        guard let context, width > 0, height > 0, fullWidth > 0, fullHeight > 0, values.count == width * height else { return }
        do {
            let folder = context.directory.appendingPathComponent("analysis/probabilities")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = UUID().uuidString
            // The synchronous write stays inside the array borrow. The no-copy Data
            // must never escape this scope or outlive the source probability values.
            try values.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                let raw = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                    count: buffer.count, deallocator: .none)
                try raw.write(to: folder.appendingPathComponent(name + ".f32"))
            }
            // Fill the final grayscale buffer directly rather than retaining both an
            // intermediate UInt8 array and its copied Data during PNG encoding.
            var data = Data(count: values.count)
            data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                let bytes = buffer.bindMemory(to: UInt8.self)
                for index in values.indices {
                    let value = values[index]
                    bytes[index] = UInt8(min(255, max(0, (value.isFinite ? value : 0) * 255)))
                }
            }
            guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw HostError.message("Probability image unavailable") }
            try HostAnalysis.encodePNG(image, to: folder.appendingPathComponent(name + ".png"))
            context.capture("detector-probability-map", ["png": "analysis/probabilities/" + name + ".png", "raw": "analysis/probabilities/" + name + ".f32",
                "width": width, "height": height, "format": "little-endian float32 row-major",
                "normalizedRect": [Double(originX)/Double(fullWidth), Double(originY)/Double(fullHeight), Double(width)/Double(fullWidth), Double(height)/Double(fullHeight)]])
        } catch { context.capture("diagnostic-error", String(describing: error)) }
    }
    // Mirror preserves all stored fields of production structs, including optional recovery evidence.
    static func json(_ value: Any) -> Any {
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSNumber {
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return v.boolValue }
            return v.doubleValue.isFinite ? v as Any : NSNull()
        }
        if let v = value as? Double { return v.isFinite ? v as Any : NSNull() }
        if let v = value as? Float { return v.isFinite ? v as Any : NSNull() }
        if let v = value as? CGFloat { return v.isFinite ? Double(v) as Any : NSNull() }
        if let v = value as? Int { return v }
        if let v = value as? UInt64 { return v }
        if let v = value as? Data { return ["byteCount": v.count, "base64": v.base64EncodedString()] }
        if let v = value as? CGRect { return ["x": v.minX, "y": v.minY, "width": v.width, "height": v.height] }
        if let v = value as? CGPoint { return ["x": v.x, "y": v.y] }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first.map { json($0.value) } ?? NSNull() }
        if mirror.displayStyle == .collection || mirror.displayStyle == .set { return mirror.children.map { json($0.value) } }
        if mirror.displayStyle == .dictionary {
            var result: [String: Any] = [:]
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                if pair.count == 2 { result[String(describing: pair[0].value)] = json(pair[1].value) }
            }
            return result
        }
        if mirror.displayStyle == .enum { return String(describing: value) }
        var fields: [String: Any] = [:]
        for child in mirror.children { if let name = child.label { fields[name] = json(child.value) } }
        return fields.isEmpty ? String(describing: value) : fields
    }
}
enum HostError: Error { case message(String) }

struct RecordingTransport: TranslationHTTPTransport {
    let wrapped: ExactHTTPStageCacheTransport
    init() {
        let directory = ProcessInfo.processInfo.environment["AIDOKU_EXACT_HTTP_STAGE_CACHE"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        wrapped = ExactHTTPStageCacheTransport(fallback: BoundedURLSessionTransport(), cacheDirectory: directory,
            forbidsNetwork: ProcessInfo.processInfo.environment["AIDOKU_FORBID_LLM_NETWORK"] == "1") { event in
            HostDump.capture("http-stage-cache", HostDump.json(event))
        }
    }
    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        try await data(for: request, maximumResponseBytes: maximumResponseBytes, bypassesProxy: bypassesProxy, onBodyData: nil)
    }
    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool,
              onBodyData: TranslationHTTPBodyObserver?) async throws -> TranslationHTTPResponse {
        // Body and method only: credentials and URL queries never enter diagnostic files.
        let body = request.httpBody ?? Data()
        HostDump.capture("http-request", ["method": request.httpMethod ?? "GET", "body": String(decoding: body, as: UTF8.self)])
        do {
            let response = try await wrapped.data(for: request, maximumResponseBytes: maximumResponseBytes,
                                                  bypassesProxy: bypassesProxy, onBodyData: onBodyData)
            HostDump.capture("http-response", ["status": response.response.statusCode,
                "body": String(decoding: response.data, as: UTF8.self), "metrics": HostDump.json(response.metrics)])
            return response
        } catch {
            HostDump.capture("http-error", String(describing: error))
            throw error
        }
    }
}

/// A CoW clone preserves the complete canonical JSON body and source isolation.
/// No body omission, reserialization, shared writable inode, or extra retained payload.
enum ScopedAliasFile {
    static func write(source: URL, to output: URL) throws -> Bool {
        let originalHeader = Data("{\"stage\":\"grouped-regions\",\"value\":".utf8)
        let replacementHeader = Data("{\"stage\":\"ordered-regions\",\"value\":".utf8)
        guard originalHeader.count == replacementHeader.count else { return false }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard clonefile(source.path, temporary.path, 0) == 0 else { return false }
        let descriptor = open(temporary.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var header = Data(count: originalHeader.count)
        let bytesRead = header.withUnsafeMutableBytes {
            pread(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard bytesRead == originalHeader.count, header == originalHeader else { return false }
        let bytesWritten = replacementHeader.withUnsafeBytes {
            pwrite(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard bytesWritten == replacementHeader.count else { return false }
        guard rename(temporary.path, output.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return true
    }
}
