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
    static func processAvailableMemory() -> UInt64 { {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * UInt64(vm_page_size)
    }() }
}
struct ReaderTranslationSettings: Sendable {
    var sourceLanguage = "auto"
    var targetLanguage = "ko"
    var translationSourceLanguages: [String] = []
    var filterSFXWithLLM = false
    var filterBackgroundWithLLM = false
    var rightToLeftPanelOrder = false
}
enum ReaderTranslationDiagnostics {
    static func record(_ event: String, count: Int = 0) { HostDump.capture(event, ["count": count]) }
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
    static func prepare(root: URL, tier: IPhoneOCRModelTier) throws {
        let lockPath = root.appendingPathComponent("build/image-translation-host/models.lock")
        let descriptor = open(lockPath.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else { throw HostError.message("Cannot lock model cache") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let cache = root.appendingPathComponent("build/image-translation-host/Models.bundle")
        let resources = cache.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "app.aidoku.ImageTranslationModels", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: cache.appendingPathComponent("Contents/Info.plist"))
        let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
        let source = root.appendingPathComponent("Aidoku/Resources/Translation")
        for name in [profile.detectorResourceName, profile.recognizerResourceName] {
            let package = source.appendingPathComponent(name + ".mlpackage")
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
        let dictionary = source.appendingPathComponent(profile.dictionaryResourceName + ".txt")
        try Data(contentsOf: dictionary).write(to: resources.appendingPathComponent(dictionary.lastPathComponent))
        setenv("AIDOKU_HOST_MODEL_BUNDLE", cache.path, 1)
    }
}

final class HostDumpContext: @unchecked Sendable {
    let directory: URL
    let quiet: Bool
    private let lock = NSLock()
    private var sequence = 0
    private var failures: [String] = []
    init(directory: URL, quiet: Bool) {
        self.directory = directory; self.quiet = quiet
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        sequence = names.compactMap { Int($0.prefix(while: { $0.isNumber })) }.max() ?? 0
    }
    func capture(_ stage: String, _ value: Any) {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let name = String(format: "%03d-", sequence) + stage + ".json"
        do {
            let converted = HostDump.json(value)
            let data = try JSONSerialization.data(withJSONObject: ["stage": stage, "value": converted], options: [.prettyPrinted, .sortedKeys])
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
    static func captureProbabilityMap(_ values: [Float], width: Int, height: Int, originX: Int, originY: Int, fullWidth: Int, fullHeight: Int, context: HostDumpContext?) {
        guard let context, width > 0, height > 0, fullWidth > 0, fullHeight > 0, values.count == width * height else { return }
        do {
            let folder = context.directory.appendingPathComponent("analysis/probabilities")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = UUID().uuidString
            let raw = values.withUnsafeBytes { Data($0) }
            try raw.write(to: folder.appendingPathComponent(name + ".f32"))
            let bytes = values.map { UInt8(min(255, max(0, ($0.isFinite ? $0 : 0) * 255))) }
            let data = Data(bytes)
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
    let wrapped = BoundedURLSessionTransport()
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
