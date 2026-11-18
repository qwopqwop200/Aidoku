import AppKit
import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Darwin
import Metal

final class HostRawDecodeSink: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private var failure: Error?
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw HostError.message("Cannot create raw OCR audit")
        }
        file = try FileHandle(forWritingTo: url)
    }
    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        do { try file.write(contentsOf: data) } catch { failure = error }
    }
    func close() throws {
        lock.lock(); defer { lock.unlock() }
        try file.close()
        if let failure { throw failure }
    }
}

enum HostImageInputs {
    // Keep common raster aliases even on hosts where a codec is unavailable:
    // those inputs then receive the usual per-image decode error, not silence.
    static let extensions: Set<String> = {
        var result: Set<String> = ["png", "jpg", "jpeg", "jpe", "jfif", "avif", "avis", "jxl",
            "webp", "heic", "heif", "tif", "tiff", "bmp", "gif"]
        for identifier in CGImageSourceCopyTypeIdentifiers() as? [String] ?? [] {
            if let type = UTType(identifier) {
                result.formUnion((type.tags[.filenameExtension] ?? []).map { $0.lowercased() })
            }
        }
        return result
    }()

    static func isImage(_ url: URL) -> Bool {
        if extensions.contains(url.pathExtension.lowercased()) { return true }
        // ImageIO identifies actual bytes, including extensionless images and
        // images saved with an unexpected suffix. JSON and sidecars stay out.
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

struct HostOptions {
    var inputs: [URL] = []
    var lists: [URL] = []
    var recursive = false
    var quiet = false
    var compactOutput = false
    var limit: Int?
    var jobs = 8
    var viewport = CGSize(width: 430, height: 932)
    var output: URL
    var resumeRun: URL?
    var retranslateRun: URL?
    var tier: IPhoneOCRModelTier = IPhoneOCRSettings.defaultModelTier
    var source = "auto"
    var target = "ko"
    var confidence = IPhoneOCRSettings.defaultConfidenceThreshold(for: IPhoneOCRSettings.defaultModelTier)
    var detectorSide = IPhoneOCRSettings.defaultDetectorMaximumSide
    var recognizerWidth = IPhoneOCRSettings.defaultRecognizerMaximumWidth
    var detectorPixelThreshold: Double?
    var detectorConfidenceThreshold: Double?
    var detectorMinimumBoxSide = 3.0
    var reasoningEffort: OpenAIReasoningEffort = .modelDefault
    var timeout: Double = 60
    var translationSourceLanguages: [String] = []
    var overlay: [String: Any] = [:]
    var baseURL = ProcessInfo.processInfo.environment["AIDOKU_TRANSLATION_BASE_URL"] ?? ""
    var model = ProcessInfo.processInfo.environment["AIDOKU_TRANSLATION_MODEL"] ?? ""
    var apiProtocol: RemoteTranslationProtocol = .chatCompletions
    var keyEnv = "AIDOKU_TRANSLATION_API_KEY"
    // Nonsecret rotation/tenant generation, never a hash of the API key.
    // Absent generation permits process-local memory reuse only.
    var credentialGeneration: UInt64?
    var allowLocalHTTP = false
    let includeImage = true
    let filterSFX = true
    let filterBackground = true
    var rtl = false
    var ocrOnly = false
    var translations: [String: String]?
    init(root: URL, arguments: [String]) throws {
        output = root.deletingLastPathComponent().appendingPathComponent("output/image-translation")
        var index = 0
        var explicitDetectorSide = false
        var explicitRecognizerWidth = false
        var explicitConfidence = false
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw HostError.message("Missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        func positive(_ text: String) throws -> Int {
            guard let number = Int(text), number > 0 else { throw HostError.message("Expected a positive integer: \(text)") }
            return number
        }
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["AIDOKU_RENDER_VIEWPORT"] { viewport = try HostRenderGeometry.parseViewport(value) }
        if let value = environment["AIDOKU_IMAGE_JOBS"] {
            guard let parsed = Int(value), (1...64).contains(parsed) else { throw HostError.message("AIDOKU_IMAGE_JOBS must be in 1...64") }
            jobs = parsed
        }
        func setting(_ key: String) -> String? { environment[key] }
        func boolean(_ key: String, fallback: Bool) throws -> Bool {
            guard let value = setting(key) else { return fallback }
            switch value.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: throw HostError.message("Invalid boolean setting: " + key)
            }
        }
        if let value = setting("AIDOKU_OCR_TIER") {
            guard let parsed = IPhoneOCRModelTier(rawValue: value) else { throw HostError.message("Invalid setting: AIDOKU_OCR_TIER") }
            tier = parsed
        }
        source = setting("AIDOKU_TRANSLATION_SOURCE") ?? source
        target = setting("AIDOKU_TRANSLATION_TARGET") ?? target
        if let value = setting("AIDOKU_OCR_CONFIDENCE") {
            guard let parsed = Double(value), parsed.isFinite, (0...1).contains(parsed) else {
                throw HostError.message("Invalid setting: AIDOKU_OCR_CONFIDENCE")
            }
            confidence = parsed
            explicitConfidence = true
        }
        for key in ["AIDOKU_OCR_DETECTOR_SIDE", "AIDOKU_OCR_RECOGNIZER_WIDTH"] {
            if let value = setting(key) {
                guard let parsed = Int(value), parsed > 0 else { throw HostError.message("Invalid positive integer setting: " + key) }
                if key == "AIDOKU_OCR_DETECTOR_SIDE" { detectorSide = parsed; explicitDetectorSide = true }
                else { recognizerWidth = parsed; explicitRecognizerWidth = true }
            }
        }
        if let value = setting("AIDOKU_TRANSLATION_PROTOCOL") {
            guard let parsed = RemoteTranslationProtocol(rawValue: value) else { throw HostError.message("Invalid setting: AIDOKU_TRANSLATION_PROTOCOL") }
            apiProtocol = parsed
        }
        for key in ["AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD", "AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD", "AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE", "AIDOKU_TRANSLATION_TIMEOUT"] {
            if let value = setting(key) {
                guard let parsed = Double(value), parsed.isFinite,
                      (key == "AIDOKU_TRANSLATION_TIMEOUT" ? parsed > 0 : parsed >= 0),
                      (!key.hasSuffix("THRESHOLD") || parsed <= 1) else { throw HostError.message("Invalid setting: " + key) }
                switch key {
                case "AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD": detectorPixelThreshold = parsed
                case "AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD": detectorConfidenceThreshold = parsed
                case "AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE": detectorMinimumBoxSide = parsed
                default: timeout = parsed
                }
            }
        }
        if let value = setting("AIDOKU_TRANSLATION_REASONING") {
            guard let parsed = OpenAIReasoningEffort(rawValue: value) else { throw HostError.message("Invalid setting: AIDOKU_TRANSLATION_REASONING") }
            reasoningEffort = parsed
        }
        if let value = setting("AIDOKU_TRANSLATION_SOURCE_LANGUAGES") {
            translationSourceLanguages = try JSONDecoder().decode([String].self, from: Data(value.utf8))
        }
        if let value = setting("AIDOKU_IPHONE_OVERLAY_JSON") {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
                throw HostError.message("Invalid setting: AIDOKU_IPHONE_OVERLAY_JSON")
            }
            overlay = parsed
        }
        keyEnv = setting("AIDOKU_TRANSLATION_KEY_ENV") ?? keyEnv
        if let value = setting("AIDOKU_TRANSLATION_CREDENTIAL_GENERATION") {
            guard let generation = UInt64(value) else {
                throw HostError.message("Invalid nonnegative credential generation")
            }
            credentialGeneration = generation
        }
        rtl = try boolean("AIDOKU_TRANSLATION_RTL", fallback: rtl)
        allowLocalHTTP = try boolean("AIDOKU_TRANSLATION_ALLOW_LOCAL_HTTP", fallback: allowLocalHTTP)
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--list": lists.append(URL(fileURLWithPath: try value()).standardizedFileURL)
            case "--output": output = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--resume-run": resumeRun = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--retranslate-run": retranslateRun = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--limit": limit = try positive(value())
            case "--viewport": viewport = try HostRenderGeometry.parseViewport(try value())
            case "--jobs":
                let parsed = try positive(value())
                guard parsed <= 64 else { throw HostError.message("--jobs must be in 1...64") }
                jobs = parsed
            case "--recursive": recursive = true
            case "--quiet": quiet = true
            case "--compact-output": compactOutput = true
            case "--tier":
                guard let parsed = IPhoneOCRModelTier(rawValue: try value()) else { throw HostError.message("Unknown model tier") }
                tier = parsed
            case "--source": source = try value()
            case "--target": target = try value()
            case "--confidence":
                guard let parsed = Double(try value()), parsed.isFinite, (0...1).contains(parsed) else {
                    throw HostError.message("Confidence must be in 0...1")
                }
                confidence = parsed
                explicitConfidence = true
            case "--detector-side":
                detectorSide = try positive(value())
                explicitDetectorSide = true
            case "--recognizer-width":
                recognizerWidth = try positive(value())
                explicitRecognizerWidth = true
            case "--base-url": baseURL = try value()
            case "--model": model = try value()
            case "--key-env": keyEnv = try value()
            case "--credential-generation":
                guard let generation = UInt64(try value()) else {
                    throw HostError.message("Invalid nonnegative credential generation")
                }
                credentialGeneration = generation
            case "--protocol":
                guard let parsed = RemoteTranslationProtocol(rawValue: try value()) else { throw HostError.message("Unknown API protocol") }
                apiProtocol = parsed
            case "--allow-local-http": allowLocalHTTP = true
            case "--no-rtl": rtl = false
            case "--rtl": rtl = true
            case "--ocr-only": ocrOnly = true
            case "--translations":
                translations = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: value())))
            case "--":
                inputs += arguments.dropFirst(index + 1).map { URL(fileURLWithPath: $0).standardizedFileURL }
                index = arguments.count
                continue
            default:
                guard !argument.hasPrefix("-") else { throw HostError.message("Unknown option: \(argument)") }
                inputs.append(URL(fileURLWithPath: argument).standardizedFileURL)
            }
            index += 1
        }
        if !explicitDetectorSide { detectorSide = IPhoneOCRSettings.defaultDetectorMaximumSide(for: tier) }
        if !explicitRecognizerWidth { recognizerWidth = IPhoneOCRSettings.maximumRecognizerWidth(for: tier) }
        if let supported = tier.restrictedSourceLanguageCodes {
            guard source == "auto" || supported.contains(source == "zh-Hans" ? "zh" : source),
                  translationSourceLanguages.allSatisfy({ supported.contains($0 == "zh-Hans" ? "zh" : $0) }) else {
                throw HostError.message("Manga OCR supports only Japanese and Chinese (Simplified/Traditional) source languages; choose ja, zh-Hans, zh-Hant or auto.")
            }
        }
        // Saved phone profiles and explicit options share the reader's supported OCR range.
        if !explicitConfidence { confidence = IPhoneOCRSettings.defaultConfidenceThreshold(for: tier) }
        detectorSide = min(max(IPhoneOCRSettings.minimumInputDimension, detectorSide), IPhoneOCRSettings.maximumDetectorSide)
        recognizerWidth = min(max(IPhoneOCRSettings.minimumInputDimension, recognizerWidth), IPhoneOCRSettings.maximumRecognizerWidth(for: tier))
        guard !(ocrOnly && translations != nil) else { throw HostError.message("Choose either --ocr-only or --translations") }
        // Let production validators handle language and endpoint policy before expensive model loading.
        try RemoteTranslationRequest(sourceLanguage: source, targetLanguage: target, sourceText: "validation").validate()
        if !ocrOnly && translations == nil {
            guard !baseURL.isEmpty, !model.isEmpty else {
                throw HostError.message("Set --base-url and --model (or their environment variables); use --ocr-only for offline OCR")
            }
            _ = try configuration.validatedEndpoint()
            guard !(ProcessInfo.processInfo.environment[keyEnv] ?? "").isEmpty else { throw HostError.message("Missing key environment variable: \(keyEnv)") }
        }
    }
    func makeTranslationService(root: URL, client: RemoteTranslating) throws -> TranslationService {
        let cache = try TranslationCache(
            configuration: .init(diskEnabled: credentialGeneration != nil),
            storageRootURL: root.appendingPathComponent("build/translation-provider-cache", isDirectory: true),
            storageScope: "page-translation")
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: includeImage ? 3 : 8)
        return TranslationService(client: client, cache: cache, providerRequestLimiter: limiter)
    }
    var configuration: RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(provider: .custom, apiProtocol: apiProtocol, baseURL: baseURL,
            model: model, credentialAccount: keyEnv, credentialGeneration: credentialGeneration ?? 0,
            reasoningEffort: reasoningEffort, timeout: timeout,
            allowsInsecureLocalhostForDevelopment: allowLocalHTTP)
    }
    var ocrConfiguration: ReaderOCRConfiguration {
        ReaderOCRConfiguration(modelTier: tier, detectorMaximumSide: detectorSide, recognizerMaximumWidth: recognizerWidth,
            confidenceThreshold: confidence, detectorPixelThreshold: detectorPixelThreshold,
            detectorConfidenceThreshold: detectorConfidenceThreshold, detectorMinimumBoxSide: detectorMinimumBoxSide)
    }
    var overlaySettings: IPhoneOverlaySettings {
        get throws { try HostOverlayAppearance.settings(saved: overlay) }
    }
    var appearance: [String: Any] {
        get throws {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] ?? FileManager.default.currentDirectoryPath)
            return HostOverlayAppearance.value(settings: try overlaySettings, fonts: HostLetterFonts(root: root))
        }
    }
    func images() throws -> [URL] {
        let manager = FileManager.default
        var candidates = inputs
        for list in lists {
            let data = try Data(contentsOf: list)
            let paths: [String]
            if list.pathExtension.lowercased() == "json" { paths = try JSONDecoder().decode([String].self, from: data) }
            else {
                guard let text = String(data: data, encoding: .utf8) else { throw HostError.message("List must be UTF-8: \(list.path)") }
                paths = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            }
            candidates += paths.map { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path) : list.deletingLastPathComponent().appendingPathComponent(path)
            }
        }
        var seen = Set<String>()
        var result: [URL] = []
        for candidate in candidates {
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory) else { throw HostError.message("Input does not exist: \(url.path)") }
            let files: [URL]
            if directory.boolValue {
                if recursive {
                    var enumerationError: Error?
                    guard let enumeration = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
                        throw HostError.message("Cannot enumerate folder: \(url.path)")
                    }
                    files = enumeration.compactMap { $0 as? URL }.filter { HostImageInputs.isImage($0) }
                    if let enumerationError { throw enumerationError }
                } else {
                    files = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                        .filter { HostImageInputs.isImage($0) }
                }
            } else { files = [url] }
            let filteredFiles = directory.boolValue ? files.filter {
                !$0.standardizedFileURL.path.hasPrefix(output.standardizedFileURL.path + "/")
            } : files
            for file in filteredFiles.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let canonical = file.resolvingSymlinksInPath().standardizedFileURL
                if seen.insert(canonical.path).inserted { result.append(canonical) }
            }
        }
        if let limit { result = Array(result.prefix(limit)) }
        guard !result.isEmpty else { throw HostError.message("No images found") }
        return result
    }
}

struct HostPageResult: @unchecked Sendable {
    let index: Int
    let row: [String: Any]
}

@MainActor
@main
struct ImageTranslationMain {
    static func main() {
        // NSApplication services native AppKit font and spelling facilities in this CLI process.
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let environment = ProcessInfo.processInfo.environment
                let roleName = environment["AIDOKU_POST_LLM_POLICY"] ?? NativePostLLMContentReclassifier.defaultPolicy.rawValue
                guard let role = NativePostLLMContentReclassifier.Policy(rawValue: roleName) else {
                    throw HostError.message("Unknown post-LLM policy")
                }
                var deduplication = NativeOCRRawCanonicalRuntime.defaultSimpleDeduplication
                if let rankName = environment["AIDOKU_SIMPLE_POST_REC_NMS"] {
                    if rankName == "legacy" { deduplication = nil }
                    else {
                        guard let rank = NativeSimpleOCRDedup.Rank(rawValue: rankName),
                              let threshold = Double(environment["AIDOKU_SIMPLE_POST_REC_NMS_IOU"] ?? "0.85"),
                              threshold.isFinite, threshold > 0, threshold <= 1 else {
                            throw HostError.message("Invalid simple post-REC NMS configuration")
                        }
                        deduplication = .init(iouThreshold: threshold, rank: rank)
                    }
                }
                var admission: NativeSimpleRecognitionAdmission.Configuration?
                if let floor = environment["AIDOKU_SIMPLE_REC_CONFIDENCE"] {
                    guard let confidence = Double(floor) else { throw HostError.message("Invalid simple REC confidence") }
                    let agreementText = environment["AIDOKU_SIMPLE_REC_AGREEMENT"] ?? "0.25"
                    let agreement: Double?
                    if agreementText == "none" { agreement = nil }
                    else {
                        guard let value = Double(agreementText) else { throw HostError.message("Invalid simple REC agreement") }
                        agreement = value
                    }
                    let candidate = NativeSimpleRecognitionAdmission.Configuration(confidenceFloor: confidence,
                        agreementFloor: agreement)
                    try NativeSimpleRecognitionAdmission.validate(candidate)
                    admission = candidate
                } else if environment["AIDOKU_SIMPLE_REC_AGREEMENT"] != nil {
                    throw HostError.message("Simple REC agreement requires an explicit confidence floor")
                }
                var boundary: NativeSimpleOCRBoundaryExpansion.Configuration?
                if let enabled = environment["AIDOKU_OCR_BOUNDARY_EXPANSION"] {
                    guard enabled == "0" || enabled == "1" else { throw HostError.message("Invalid boundary expansion switch") }
                    if enabled == "1" {
                        guard let threshold = Double(environment["AIDOKU_OCR_BOUNDARY_THRESHOLD"] ?? "0.3940652310848236"),
                              threshold.isFinite, (0...1).contains(threshold),
                              let margin = Double(environment["AIDOKU_OCR_BOUNDARY_MARGIN"] ?? "0.025"),
                              margin.isFinite, (0...0.1).contains(margin) else {
                            throw HostError.message("Invalid boundary expansion configuration")
                        }
                        boundary = .init(threshold: threshold, margin: margin)
                    }
                } else if environment["AIDOKU_OCR_BOUNDARY_THRESHOLD"] != nil || environment["AIDOKU_OCR_BOUNDARY_MARGIN"] != nil {
                    throw HostError.message("Boundary parameters require an explicit expansion switch")
                }
                let code = await NativeSimpleOCRBoundaryExpansionRuntime.$configuration.withValue(boundary) {
                    await NativeSimpleRecognitionAdmission.$configuration.withValue(admission) {
                        await NativeOCRRawCanonicalRuntime.$simpleDeduplication.withValue(deduplication) {
                            await NativePostLLMContentReclassifier.$activePolicy.withValue(role) { await execute() }
                        }
                    }
                }
                exit(code)
            } catch {
                fputs("Pipeline policy configuration failed: \(error)\n", stderr)
                exit(2)
            }
        }
        app.run()
    }
    static func execute() async -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--native-source-appearance-verify" {
            return await Task.detached(priority: .userInitiated) {
                do { return try HostOperationalAppearance.runVerification(arguments) }
                catch { fputs("Source appearance verification failed: \(error)\n", stderr); return Int32(1) }
            }.value
        }
        if arguments.first == "--native-removal-shadow" {
            if #available(macOS 15.0, *) { return await HostRemovalShadow.run(arguments) }
            fputs("Native removal shadow requires macOS 15 or later\n", stderr); return 2
        }
        if arguments.first == "--native-raw-text-render" { return HostRawTextRender.run(arguments) }
        if arguments.first == "--segmentation-final-jsonl" {
            guard arguments.count == 1 else { return 2 }
            do { try NativeSegmentationFinalStream.run(); return 0 }
            catch { fputs("Invalid source-only final segmentation observations: \(error)\n", stderr); return 1 }
        }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"]!)
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["AIDOKU_AOT_RAW_REPLAY_INDEX"] {
            do {
                guard let digest = environment["AIDOKU_AOT_RAW_REPLAY_INDEX_SHA256"] else {
                    throw HostError.message("AOT raw replay requires an explicit index SHA256")
                }
                let replay = try NativeAOTRawPredictionReplay(indexFile: URL(fileURLWithPath: path), expectedIndexSHA256: digest)
                try NativeMainAOTBackend.shared.configureRawPredictionReplay(replay)
            } catch { fputs("AOT raw replay configuration failed: \(error)\n", stderr); return 2 }
        } else if environment["AIDOKU_AOT_RAW_REPLAY_INDEX_SHA256"] != nil {
            fputs("AOT raw replay SHA256 requires an index path\n", stderr); return 2
        }
        if arguments.first == "--sealed-llm-stage" {
            if #available(macOS 15.0, *) { return await HostSealedLLMStage.run(root: root, arguments: arguments) }
            fputs("Sealed LLM stage requires macOS 15 or later\n", stderr); return 2
        }
        if arguments.first == "--minimal-source-arm" {
            if #available(macOS 15.0, *) { return await HostMinimalSourceArm.run(root: root, arguments: arguments) }
            fputs("Minimal SOURCE arm requires macOS 15 or later\n", stderr); return 2
        }
        if arguments.first == "--matched-reader-render" {
            if #available(macOS 15.0, *) {
                return await HostMatchedReaderRender.run(root: root, arguments: arguments) { regions, image, directory, configuration, aotBudget in
                    try NativeAOTHostPredictionBudget.configure(maximumFreshPredictions: aotBudget)
                    HostDBProbability.requiresCachedProbability = true
                    var capture: HostCanaryRawArchive?
                    if ProcessInfo.processInfo.environment["AIDOKU_CANARY_CAPTURE_AOT"] == "1" {
                        guard let manifest = ProcessInfo.processInfo.environment["AIDOKU_MODULE_BANK_PRODUCER_MANIFEST"],
                              !manifest.isEmpty else { throw HostCanaryRawArchive.Failure.request }
                        let source = directory.appendingPathComponent("input.png")
                        let sourceSHA = try HostRenderProvenance.fileSHA256(source)
                        let config: [String: Any] = ["renderVariant": NativeRenderVariantPolicy.projection,
                            "OCRConfiguration": try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)),
                            "target": "ko", "freshAOTBudget": aotBudget, "sourceEncodedSHA256": sourceSHA]
                        capture = try HostCanaryRawArchive(directory: directory.appendingPathComponent("aot-raw-capture"),
                            sourceFile: source, expectedSourceEncodedSHA256: sourceSHA,
                            producerManifest: URL(fileURLWithPath: manifest),
                            producerConfig: JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
                        try capture?.configureCapture()
                    }
                    defer {
                        let budget = NativeAOTHostPredictionBudget.snapshot()
                        let receipt: [String: Any] = [
                            "configured": budget.configured,
                            "maximumFreshPredictions": budget.maximumFreshPredictions as Any? ?? NSNull(),
                            "actualAOTPredictionAttempts": budget.actualCalls,
                            "remaining": budget.remaining as Any? ?? NSNull(),
                            "budgetEnforcedBeforePrediction": budget.budgetEnforcedBeforePrediction]
                        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
                            try? data.write(to: directory.appendingPathComponent("aot-runtime-budget.json"), options: .atomic)
                        }
                    }
                    do {
                        try await Self.render(regions, image: image, target: "ko", root: root, directory: directory,
                            settings: try HostOverlayAppearance.settings(saved: [:]),
                            viewport: .init(width: 430, height: 932), ocrConfiguration: configuration)
                    } catch {
                        if let capture {
                            let receipt: [String: Any]
                            do { receipt = ["renderSucceeded": false, "rawCapture": try capture.finish()] }
                            catch { receipt = ["renderSucceeded": false, "captureFailure": String(describing: error)] }
                            if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
                                try? data.write(to: directory.appendingPathComponent("aot-capture-failure.json"), options: .atomic)
                            }
                        }
                        throw error
                    }
                    let budget = NativeAOTHostPredictionBudget.snapshot()
                    var receipt: [String: Any] = ["actualAOTCalls": budget.actualCalls,
                        "budgetEnforcedBeforePrediction": budget.budgetEnforcedBeforePrediction,
                        "approximateTargetsOnly": true]
                    if let capture { receipt["AOTRawCapture"] = try capture.finish() }
                    return receipt
                }
            }
            fputs("Matched Reader rendering requires macOS 15 or later\n", stderr); return 2
        }
        if arguments.first == "--observed-reader-stage" {
            if #available(macOS 15.0, *) { return await HostObservedReaderStage.run(root: root, arguments: arguments) }
            fputs("Observed Reader stage requires macOS 15 or later\n", stderr); return 2
        }
        if arguments.first == "--verify-role-prompt-contract" {
            return await HostRolePromptContract.run(arguments)
        }
        if arguments.first == "--evaluate-saved-llm" {
            return await HostSavedLLMEvaluation.run(arguments)
        }
        if arguments.first == "--reclassify-source-signals" {
            guard arguments.count == 3 else { return 2 }
            do {
                return try HostModelRefresh.runRoleSignalReplay(request: URL(fileURLWithPath: arguments[1]),
                    output: URL(fileURLWithPath: arguments[2]))
            } catch { fputs("Source-signal role replay failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--reclassify-saved-llm" {
            return await HostSavedPostLLMEvaluation.run(arguments)
        }
        if arguments.first == "--saved-reader-postprocess" {
            guard HostBuildMode.savedReaderReplay,
                  ProcessInfo.processInfo.environment["AIDOKU_HOST_SAVED_READER_REPLAY"] == "1" else { return 2 }
            return await HostSavedReaderPostprocess.run(arguments)
        }
        if arguments.first == "--first-pass-geometry-probe" {
            guard arguments.count == 3 else {
                fputs("Usage: --first-pass-geometry-probe request.json output-directory\n", stderr)
                return 2
            }
            do {
                return try await HostDirectionReplay.runFirstPassGeometryProbe(
                    request: URL(fileURLWithPath: arguments[1]), output: URL(fileURLWithPath: arguments[2]), root: root)
            } catch {
                fputs("First-pass geometry probe failed: \(error)\n", stderr)
                return 1
            }
        }
        if arguments.first == "--direction-replay" {
            guard arguments.count == 2 else { return 2 }
            do { return try await HostDirectionReplay.run(request:URL(fileURLWithPath:arguments[1]),root:root) }
            catch { fputs("Direction replay failed: \(error)\n",stderr); return 1 }
        }
        if arguments.first == "--direction-audit" {
            guard arguments.count == 3 else { return 2 }
            do { return try HostDirectionAudit.run(input:URL(fileURLWithPath:arguments[1]),output:URL(fileURLWithPath:arguments[2])) }
            catch { fputs("Direction audit failed: \(error)\n",stderr); return 1 }
        }
        if arguments.first == "--source-loss426-controls" {
            guard arguments.count == 2 else { return 2 }
            do {
                let report = try HostSupplementalBodyLoss426Controls.run()
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
                return 0
            } catch { fputs("Supplemental426 controls failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--source-witness436-controls" {
            guard arguments.count == 3 else { return 2 }
            do {
                let report=try HostSourceWitness436.controls(directory:URL(fileURLWithPath:arguments[2]))
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                    .write(to:URL(fileURLWithPath:arguments[1]),options:.atomic)
                return 0
            } catch { fputs("Source witness436 controls failed: \(error)\n",stderr);return 1 }
        }
        if arguments.first == "--source-witness436-audit" {
            guard arguments.count == 4 else { return 2 }
            do { return try HostSourceWitness436.run(input: URL(fileURLWithPath: arguments[1]),
                output: URL(fileURLWithPath: arguments[2]), directory: URL(fileURLWithPath: arguments[3])) }
            catch { fputs("Source witness436 capture failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--source-regression435-controls" {
            guard arguments.count == 2 else { return 2 }
            do {
                let report = try HostSourceRepairControls.runRaw435()
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
                return 0
            } catch { fputs("Raw regression435 controls failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--source-feasible433-controls" {
            guard arguments.count == 2 else { return 2 }
            do {
                let report = try HostSourceRepairControls.runFeasible433()
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
                return 0
            } catch { fputs("Feasible433 controls failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--source-loss424-controls" {
            guard arguments.count == 2 else { return 2 }
            do {
                let report = try HostSourceRepairControls.runSupplemental424()
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
                return 0
            } catch { fputs("Supplemental424 controls failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--native-admission425-controls" {
            guard arguments.count == 2 else { return 2 }
            do {
                let report = try HostNativeAdmission425Controls.run()
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
                return 0
            } catch { fputs("Native admission425 controls failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--source-repair-controls" {
            guard arguments.count == 2 else { return 2 }
            do {
                let report = try HostSourceRepairControls.run()
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
                return 0
            } catch { fputs("Source repair controls failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--raw-source-canonical-geometry" {
            guard arguments.count == 3 else { return 2 }
            do { return try HostRawCanonicalGeometry.run(output: URL(fileURLWithPath: arguments[1]),
                modelURL: URL(fileURLWithPath: arguments[2])) }
            catch { fputs("Canonical raw geometry failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--raw-source-canonical-combined" {
            guard arguments.count == 4 else { return 2 }
            do { return try HostRawCanonicalGeometry.run(output: URL(fileURLWithPath: arguments[1]),
                modelURL: URL(fileURLWithPath: arguments[2]), auxiliaryModelURL: URL(fileURLWithPath: arguments[3])) }
            catch { fputs("Combined canonical raw geometry failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--pre-rec-signal-features" {
            guard arguments.count == 2 else { return 2 }
            do { return try HostPreRecognitionFilter.run(output: URL(fileURLWithPath: arguments[1])) }
            catch { fputs("Pre-rec feature extraction failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--pre-rec-signal-filter" {
            guard arguments.count == 3 else { return 2 }
            do { return try HostPreRecognitionFilter.run(output: URL(fileURLWithPath: arguments[1]),
                policyURL: URL(fileURLWithPath: arguments[2])) }
            catch { fputs("Pre-rec signal filter failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--postmerge-signal-replay" {
            guard arguments.count == 3 || arguments.count == 4 else { return 2 }
            do { return try HostPostMergeSignalFilter.run(requestURL: URL(fileURLWithPath: arguments[1]),
                output: URL(fileURLWithPath: arguments[2]),
                policyURL: arguments.count == 4 ? URL(fileURLWithPath: arguments[3]) : nil) }
            catch { fputs("Post-merge signal replay failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--post-rec-joint-features" {
            guard arguments.count == 2 else { return 2 }
            do { return try HostPostRecognitionFilter.run(output: URL(fileURLWithPath: arguments[1])) }
            catch { fputs("Post-rec feature extraction failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--post-rec-joint-filter" {
            guard arguments.count == 3 else { return 2 }
            do { return try HostPostRecognitionFilter.run(output: URL(fileURLWithPath: arguments[1]),
                policyURL: URL(fileURLWithPath: arguments[2])) }
            catch { fputs("Post-rec joint filter failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--post-rec-joint-filter-and-dedup" {
            guard arguments.count == 3 else { return 2 }
            do { return try HostPostRecognitionFilter.run(output: URL(fileURLWithPath: arguments[1]),
                policyURL: URL(fileURLWithPath: arguments[2]), deduplicate: true) }
            catch { fputs("Post-rec joint filter/dedup failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--post-rec-joint-dedup" {
            guard arguments.count == 2 else { return 2 }
            do { return try HostPostRecognitionFilter.run(output: URL(fileURLWithPath: arguments[1]), deduplicate: true) }
            catch { fputs("Post-rec joint dedup failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--raw-source-boundary-features" {
            guard arguments.count == 2 else { return 2 }
            do { return try await HostRawBoundaryFeatures.capture(output: URL(fileURLWithPath: arguments[1])) }
            catch { fputs("Raw source boundary feature capture failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--endpoint-plan-audit" {
            guard arguments.count == 3 else { return 2 }
            do { return try HostDirectionAudit.planEndpoints(input: URL(fileURLWithPath: arguments[1]),
                output: URL(fileURLWithPath: arguments[2])) }
            catch { fputs("Endpoint planning failed: \(error)\n",stderr); return 1 }
        }
        if arguments.first == "--audit-language-review" {
            guard arguments.count == 3 else { return 2 }
            do {
                return try HostMangaDetectorSearch.auditLanguageReview(source: URL(fileURLWithPath: arguments[1]),
                    output: URL(fileURLWithPath: arguments[2]), root: root)
            } catch { fputs("Language-only audit failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--rf-parameter-capture" {
            guard arguments.count == 2 else { return 2 }
            do { return try await HostRFParameterSearch.run(request: URL(fileURLWithPath: arguments[1]), root: root) }
            catch { fputs("RF648 parameter capture failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--manga-detector-search" {
            guard arguments.count == 2 else { return 2 }
            do { return try await HostMangaDetectorSearch.run(request: URL(fileURLWithPath: arguments[1]), root: root) }
            catch { fputs("Manga detector search failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--recognize-saved-missing" {
            guard arguments.count == 2 else { return 2 }
            do { return try await HostMangaDetectorSearch.recognizeMissing(request: URL(fileURLWithPath: arguments[1]), root: root) }
            catch { fputs("Saved recognition audit failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--admit-bbox-confidence" {
            guard arguments.count == 2 else { return 2 }
            do { return try HostBBoxConfidenceAdmission.run(output: URL(fileURLWithPath: arguments[1])) }
            catch { fputs("BBox-confidence admission failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--deduplicate-individual-geometry" {
            guard arguments.count == 2 else { return 2 }
            do { return try HostBBoxConfidenceAdmission.deduplicate(output: URL(fileURLWithPath: arguments[1])) }
            catch { fputs("Geometry deduplication failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--replay-individual-geometry" {
            guard arguments.count == 3,
                  let mode = NativeOCRIndividualGeometryHypotheses.Mode(rawValue: arguments[2]) else { return 2 }
            do { return try await HostIndividualGeometry.replaySaved(output: URL(fileURLWithPath: arguments[1]), mode: mode) }
            catch { fputs("Saved individual geometry replay failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--manga-recognizer-search" {
            guard arguments.count == 2 else { return 2 }
            do { return try await HostMangaDetectorSearch.recognize(request: URL(fileURLWithPath: arguments[1]), root: root) }
            catch { fputs("Manga recognition search failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--audit-render-run" || arguments.first == "--prepare-render-run" {
            guard arguments.count == 2 else { fputs("Usage: --audit-render-run RUN_DIRECTORY or --prepare-render-run RUN_DIRECTORY\n", stderr); return 2 }
            do {
                return try await auditRenderRun(URL(fileURLWithPath: arguments[1]).standardizedFileURL, root: root,
                    preparationOnly: arguments.first == "--prepare-render-run")
            } catch { fputs("Native render audit failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--layout-fixture" {
            do {
                guard arguments.count == 2,
                      let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[1]))) as? [String: Any],
                      let iw = fixture["imageWidth"] as? Double, let ih = fixture["imageHeight"] as? Double,
                      let vw = fixture["viewportWidth"] as? Double, let vh = fixture["viewportHeight"] as? Double,
                      [iw, ih, vw, vh].allSatisfy({ $0.isFinite && $0 > 0 }),
                      let rawRegions = fixture["regions"] as? [[String: Any]] else { throw HostError.message("Invalid layout fixture") }
                let regions = try rawRegions.enumerated().map { index, raw -> ReaderTranslationRegion in
                    guard let r = raw["rect"] as? [Double], r.count == 4, r.allSatisfy(\.isFinite),
                          let source = raw["source"] as? String else { throw HostError.message("Invalid fixture region") }
                    var region = ReaderTranslationRegion(id: String(index), rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
                        source: source, translation: raw["translation"] as? String)
                    region.sourceOrientation = BrowserOCRSourceOrientation(rawValue: raw["sourceOrientation"] as? String ?? "unknown") ?? .unknown
                    region.polygon = (raw["polygon"] as? [[Double]] ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
                    return region
                }
                let imageSize = CGSize(width: iw, height: ih), viewport = CGSize(width: vw, height: vh)
                let settings = try HostOverlayAppearance.settings(saved: fixture["overlay"] as? [String: Any] ?? [:])
                let frame = HostRenderGeometry.displayRect(imageSize: imageSize, viewport: viewport)
                let items = HostProductionLayout.layoutPayload(items: ReaderTranslationRegion.layoutItems(regions, imageSize: imageSize),
                    imageSize: imageSize, sourceRect: frame, settings: settings,
                    targetLanguage: fixture["target"] as? String ?? "ko", viewport: viewport)
                let output: [String: Any] = ["items": items, "appearance": HostOverlayAppearance.value(settings: settings,
                    fonts: HostLetterFonts(root: root)), "viewport": [vw, vh], "metricsPlatform": "AppKit-CoreText"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
                return 0
            } catch { fputs("Layout fixture failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--render-run" || arguments.first == "--render-run-tuned" {
            let tuned = arguments.first == "--render-run-tuned"
            guard tuned ? (4...5).contains(arguments.count) : (2...3).contains(arguments.count) else {
                fputs("Usage: --render-run RUN_DIRECTORY [NEW_OUTPUT_DIRECTORY], or --render-run-tuned RUN_DIRECTORY NEW_OUTPUT_DIRECTORY PARAMETERS_JSON [PAGE_IDS_JSON]\n", stderr); return 2
            }
            do {
                let nativeReplayStarted = ProcessInfo.processInfo.systemUptime
                try HostResources.prepare(root: root, tier: .manga, renderOnly: true)
                let run = URL(fileURLWithPath: arguments[1]).standardizedFileURL
                let destination = arguments.count >= 3 ? URL(fileURLWithPath: arguments[2]).standardizedFileURL : run
                guard !tuned || destination != run else {
                    throw HostError.message("Tuned replay requires a separate fresh destination")
                }
                let tuning: [String: Any]?
                if tuned {
                    guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf:
                        URL(fileURLWithPath: arguments[3]))) as? [String: Any],
                        Set(values.keys).isSubset(of: Set(NativeTextBoxGeometryParameters.baseline.diagnosticValues.keys)),
                        Set(["sourceMarginMinimum", "sourceMarginMaximum", "sourceWidthRatio", "sourceFontRatio",
                             "openPanelExpansion"]).isSubset(of: Set(values.keys)) else {
                        throw HostError.message("Unknown or missing geometry parameters")
                    }
                    let decoded = try JSONDecoder().decode(NativeTextBoxGeometryParameters.self,
                        from: JSONSerialization.data(withJSONObject: values))
                    guard decoded.isValid else { throw HostError.message("Invalid geometry parameter range") }
                    tuning = values
                } else { tuning = nil }
                let selectedIDs: Set<String>?
                if tuned && arguments.count == 5 {
                    let ids = try JSONDecoder().decode([String].self, from: Data(contentsOf:
                        URL(fileURLWithPath: arguments[4])))
                    guard !ids.isEmpty, Set(ids).count == ids.count,
                        ids.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isNumber) }) else {
                        throw HostError.message("Invalid selected replay page IDs")
                    }
                    selectedIDs = Set(ids)
                } else { selectedIDs = nil }
                let fresh = destination != run
                if fresh {
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        throw HostError.message("Fresh render destination must not already exist")
                    }
                    try FileManager.default.createDirectory(at: destination.appendingPathComponent("final"), withIntermediateDirectories: true)
                }
                let directories = try FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                var count = 0
                var previewLinks: [String] = []
                let runtimeFingerprint = HostRenderProvenance.fingerprint(ProcessInfo.processInfo.environment)
                func publishPreview() throws {
                    let html = """
                    <!doctype html><meta charset="utf-8"><title>Fresh native render</title>
                    <style>body{background:#202124;color:white;font-family:system-ui}main{display:grid;grid-template-columns:minmax(0,1fr);gap:24px;max-width:1000px;margin:auto}img{display:block;width:100%;height:auto}a{color:white}</style>
                    <h1>Native render · \(count) pages</h1><p>Build \(runtimeFingerprint.map { String($0.prefix(12)) } ?? "unmeasured"); saved OCR, translation and planner inputs. This build identifier is not a quality pass. Original-resolution PNGs; no cached final pixels.</p>
                    <main>\(previewLinks.joined())</main>
                    """
                    try html.write(to: destination.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
                }
                // A crash after provider completion may leave a valid saved
                // native payload but no final.json. Recover it only into an
                // explicit fresh destination; never mark the failed run complete.
                for directory in directories where
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent("final.json").path) ||
                    (fresh && FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.png").path)) {
                    if let selectedIDs, !selectedIDs.contains(directory.lastPathComponent) { continue }
                    // A confirmed-input overlay may alias a saved page directory.
                    // Foundation enumeration can reject the unresolved directory URL
                    // with ENOTDIR; read the resolved target but retain the manifest ID.
                    let sourceDirectory = directory.resolvingSymlinksInPath()
                    let files = try HostAnalysis.stageFiles(in: sourceDirectory)
                    guard let payload = files.last(where: { $0.lastPathComponent.hasSuffix("-render-payload.json") }),
                        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: payload)) as? [String: Any],
                        var value = object["value"] as? [String: Any] else { continue }
                    if let tuning { value["hostTextBoxGeometryParameters"] = tuning }
                    let sourceURL = sourceDirectory.appendingPathComponent("input.png")
                    let outputDirectory = fresh ? destination.appendingPathComponent(directory.lastPathComponent) : directory
                    if fresh { try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true) }
                    let dump = HostDumpContext(directory: outputDirectory, quiet: true, sourceURL: sourceURL)
                    try await HostDump.$context.withValue(dump) {
                        try await renderSavedPayload(value, sourceURL: sourceURL, payloadURL: payload, root: root, directory: outputDirectory,
                            sourceMetadata: NativePNGMetadata.source(at: sourceURL))
                    }
                    try dump.requireComplete()
                    if fresh {
                        let name = directory.lastPathComponent
                        try FileManager.default.linkItem(at: outputDirectory.appendingPathComponent("final.png"),
                            to: destination.appendingPathComponent("final/\(name).png"))
                        previewLinks.append("<a href=\"\(name)/final.html\">\(name)<img loading=\"lazy\" src=\"final/\(name).png\"></a>")
                    } else {
                        try markNativeRender(in: directory)
                        try HostAnalysis.publishFinal(imageDirectory: directory, runDirectory: run)
                        try HostAnalysis.generate(imageDirectory: directory, root: root)
                    }
                    count += 1; print("Recomposited: \(directory.lastPathComponent)/final.png")
                    if fresh && (count == 1 || count % 20 == 0) { try publishPreview() }
                }
                guard count > 0 else { throw HostError.message("No completed render payloads found") }
                if let selectedIDs, count != selectedIDs.count {
                    throw HostError.message("Selected replay pages missing stored payloads")
                }
                if fresh { try publishPreview() } else { try HostAnalysis.generateRun(run, root: root) }
                var usage = rusage()
                let usageStatus = getrusage(RUSAGE_SELF, &usage)
                let gpu = MTLCreateSystemDefaultDevice()
                let nativeCost: [String: Any] = ["pages": count,
                    "seconds": ProcessInfo.processInfo.systemUptime - nativeReplayStarted,
                    "nativePeakRSSBytes": usageStatus == 0 ? usage.ru_maxrss as Any : NSNull(),
                    "metalGPUAvailable": gpu != nil, "metalGPUName": gpu?.name as Any? ?? NSNull(),
                    "requestedAOTComputeUnits": "cpuAndGPU; per-operation execution placement not measured",
                    "scope": "native replay process only; excludes Swift launcher/compiler and OCR/RF/translation; includes model setup, mask/text/AOT, diagnostics, PNG/PDF writes",
                    "deviceMeasured": false]
                try JSONSerialization.data(withJSONObject: nativeCost, options: [.sortedKeys])
                    .write(to: destination.appendingPathComponent("native-replay-cost.json"), options: .atomic)
                return 0
            } catch { fputs("Render replay: \(error)\n", stderr); return 1 }
        }
        let options: HostOptions
        let images: [URL]
        do {
            try HostEnvironment.load(root: root)
            options = try HostOptions(root: root, arguments: Array(CommandLine.arguments.dropFirst()))
            images = try options.images()
        } catch { fputs("Configuration: \(error)\n", stderr); return 2 }
        let run = options.resumeRun ?? options.output.appendingPathComponent("run-" + UUID().uuidString)
        if options.retranslateRun == run {
            fputs("Configuration: saved OCR source and output run must differ\n", stderr)
            return 2
        }
        do {
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try HostResources.prepare(root: root, tier: options.tier)
        } catch { fputs("Preparation: \(error)\n", stderr); return 1 }
        print("Output: \(run.path)")
        let client: TranslationService
        do {
            client = try options.makeTranslationService(root: root,
                client: RemoteTranslationClient(transport: RecordingTransport()))
        } catch { fputs("Provider cache preparation failed\n", stderr); return 1 }
        var summary: [[String: Any]] = []
        let analysisReceipts = HostAnalysis.GenerationReceipts()
        do {
            try JSONSerialization.data(withJSONObject: images.map(\.path), options: [.prettyPrinted])
                .write(to: run.appendingPathComponent("input-manifest.json"), options: .atomic)
            try HostAnalysis.publishProgress(run: run, inputs: images, summary: summary, finished: false)
        } catch { fputs("Progress: \(error)\n", stderr); return 1 }
        var progressFailed = false
        print("Concurrency: \(options.jobs) images; OCR 1, rendering 1, translation up to \(min(options.jobs, options.includeImage ? 3 : 8))")
        await withTaskGroup(of: HostPageResult.self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                group.addTask { @MainActor in
                    await processImage(index: index, url: images[index], count: images.count, run: run,
                        root: root, options: options, client: client)
                }
            }
            while next < min(options.jobs, images.count) { enqueue(next); next += 1 }
            var completed: [HostPageResult] = []
            while let result = await group.next() {
                completed.append(result)
                summary = completed.sorted { $0.index < $1.index }.map(\.row)
                do {
                    if let directory = result.row["directory"] as? String {
                        let page = URL(fileURLWithPath: directory)
                        if options.compactOutput {
                            if result.row["status"] as? String == "success" {
                                try HostAnalysis.compactPage(page)
                            }
                        } else {
                            try HostAnalysis.generate(imageDirectory: page, root: root, receipts: analysisReceipts)
                        }
                    }
                } catch { fputs("Page analysis: \(error)\n", stderr) }
                do {
                    try HostAnalysis.publishProgress(run: run, inputs: images, summary: summary, finished: false)
                } catch { progressFailed = true; fputs("Progress: \(error)\n", stderr) }
                let failed = summary.filter { $0["status"] as? String == "failed" }.count
                print("Progress: \(completed.count)/\(images.count) completed; \(completed.count - failed) succeeded, \(failed) failed. \(run.appendingPathComponent("progress.html").path)")
                if next < images.count { enqueue(next); next += 1 }
            }
            summary = completed.sorted { $0.index < $1.index }.map(\.row)
        }
        do {
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: run.appendingPathComponent("summary.json"), options: .atomic)
        } catch { fputs("Summary: \(error)\n", stderr); return 1 }
        do { try HostAnalysis.generateRun(run, root: root, receipts: analysisReceipts,
            compact: options.compactOutput) }
        catch { fputs("Analysis: \(error)\n", stderr); return 1 }
        do { try HostAnalysis.publishProgress(run: run, inputs: images, summary: summary, finished: true) }
        catch { fputs("Progress: \(error)\n", stderr); return 1 }
        let failures = summary.filter { $0["status"] as? String == "failed" }.count
        print("Finished: \(images.count - failures) succeeded, \(failures) failed. \(run.path)")
        return failures == 0 && !progressFailed ? 0 : 1
    }
    static let renderGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    /// Shared app/host operating default; disabled/fixed-pre stay explicit comparisons.
    /// Invalid modes must fail, never silently run a different policy.
    static func sourceAnchorMode() throws -> NativeOCRRawCanonicalRuntime.SourceAnchorMode {
        let value = ProcessInfo.processInfo.environment["AIDOKU_OCR_SOURCE_ANCHOR_MODE"]
        guard let mode = NativeOCRRawCanonicalPolicy.resolvedSourceAnchorMode(override: value) else {
            throw HostError.message("Unknown AIDOKU_OCR_SOURCE_ANCHOR_MODE: \(value ?? "<unset>")")
        }
        return mode
    }
    /// A completed render is reusable only for the same input and translation contract.
    /// Hash credentials-free settings; legacy completion markers remain viewable via render-run.
    static func resumeIdentity(input: URL, options: HostOptions, pageDirectoryName: String) throws -> String {
        let sourceHash = SHA256.hash(data: try Data(contentsOf: input)).map { String(format: "%02x", $0) }.joined()
        let savedOCRHash = try options.retranslateRun.map {
            try HostSavedOCRIdentity.digest(directory: $0.appendingPathComponent(pageDirectoryName))
        }
        var values: [String: Any] = [
            "inputSHA256": sourceHash,
            "engine": ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unknown",
            "segmentationPolicySHA256": NativeSourceSegmentationExecution.policySHA256,
            "erasureSegmentationPolicySHA256": NativeSourceSegmentationExecution.erasurePolicySHA256,
            "cacheVersion": TranslationCacheKey.schemaVersion,
            "preLLMAdmission": NativeFinalOutputContentFilter.admissionPolicyVersion,
            "postLLMContent": NativePostLLMContentReclassifier.activePolicy.version,
            "sourceAnchorMode": try sourceAnchorMode().rawValue,
            "rawCanonicalPolicyVersion": NativeOCRRawCanonicalPolicy.version,
            "sharedOwnerOutlinedGapRelaxed": ProcessInfo.processInfo.environment["AIDOKU_RF_OWNER_RELAX_OUTLINED_GAP"] == "1",
            "sharedRFRawCache": NativeRFRawCachePolicy.enabled,
            "sourceAppearanceBackend": HostOperationalAppearance.selectedBackend,
            "sourceContourOnlyDiagnostic": NativeOperationalAppearance.sourceContourOnlyDiagnosticEnabled,
            "lettering": TranslationHTTPCodec.letteringPolicy,
            "sfx": TranslationHTTPCodec.sfxPolicy, "background": TranslationHTTPCodec.backgroundPolicy,
            "baseURL": options.baseURL, "model": options.model, "protocol": options.apiProtocol.rawValue,
            "reasoning": options.reasoningEffort.rawValue, "instructions": options.configuration.instructions,
            "source": options.source, "target": options.target, "sourceLanguages": options.translationSourceLanguages,
            "ocr": HostDump.json(options.ocrConfiguration), "ocrOnly": options.ocrOnly,
            "premergeCandidateModels": premergeCandidateModelIdentity(),
            "translations": options.translations as Any? ?? NSNull(),
            "savedOCR": options.retranslateRun?.path as Any? ?? NSNull(),
            "savedOCRGrouping": options.retranslateRun == nil ? NSNull() : HostSavedOCRReplay.groupingPolicy as Any,
            "savedOCRContentSHA256": savedOCRHash as Any? ?? NSNull(),
            "appearance": try options.appearance, "viewport": [options.viewport.width, options.viewport.height],
            "rtl": options.rtl
        ]
        if TranslationHTTPCodec.samplingTemperature != 0 {
            values["samplingTemperature"] = TranslationHTTPCodec.samplingTemperature
        }
        if NativeCoreMLDetectionPreprocessor.usesIsotropicContent {
            values["detectorPreprocessingABI"] = NativeCoreMLDetectionPreprocessor.provenanceABI
            values["detectorNormalizationSHA256"] = NativeCoreMLDetectionPreprocessor.normalizationConfigurationSHA256
        }
        if NativeCoreMLDBPostprocessor.alternateCellEnvelopeEnabled {
            values["detectorAlternatePolicyVersion"] = NativeOCRRawCanonicalPolicy.detectorAlternatePolicyVersion
        }
        if let deduplication = NativeOCRRawCanonicalRuntime.simpleDeduplication {
            values["postRecognitionDeduplication"] = ["policy": NativeSimpleOCRDedup.policyVersion,
                "configuration": HostDump.json(deduplication)]
        }
        if let admission = NativeSimpleRecognitionAdmission.configuration {
            values["recognitionAdmission"] = ["policy": NativeSimpleRecognitionAdmission.policyVersion,
                "configuration": HostDump.json(admission)]
        }
        if let boundary = NativeSimpleOCRBoundaryExpansionRuntime.configuration {
            values["boundaryExpansion"] = ["policy": NativeSimpleOCRBoundaryExpansion.policyVersion,
                "configuration": HostDump.json(boundary)]
        }
        if ProcessInfo.processInfo.environment["AIDOKU_MODULE_BANK_CAPTURE"] == "1" {
            let producer = try HostModuleBankBootstrap.producerManifest(environment: ProcessInfo.processInfo.environment)
            values["moduleBankProducerSHA256"] = producer.producerSHA256
            values["sourceBankCapture"] = ProcessInfo.processInfo.environment["AIDOKU_SOURCE_BANK_CAPTURE"] == "1"
        }
        let renderVariants = NativeRenderVariantPolicy.projection
        if !renderVariants.isEmpty { values["renderVariantPolicies"] = renderVariants }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// Runtime weights change OCR admission without changing compiled source fingerprints.
    /// Include their bytes so resume cannot return results from a different filter policy.
    static func premergeCandidateModelIdentity() -> [String: String] {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"]
            ?? FileManager.default.currentDirectoryPath)
        let inputs: [String: URL]
        var identity: [String: String]
        if let path = ProcessInfo.processInfo.environment["AIDOKU_OCR_PREMERGE_MODEL"] {
            let content = URL(fileURLWithPath: path), directory = content.deletingLastPathComponent()
            inputs = ["content": content,
                "quality": directory.appendingPathComponent("quality-model.json"),
                "duplicates": directory.appendingPathComponent("duplicate-policy-minimal-pixel.json"),
                "automatic": directory.appendingPathComponent("auto-policy.json"),
                "experimentalCombination": directory.appendingPathComponent("combination-policy.json")]
            identity = ["status": "explicit-host-override"]
        } else {
            let directory = root.appendingPathComponent("Aidoku/Resources/Translation/PremergeSignalPolicy")
            inputs = Dictionary(uniqueKeysWithValues: NativeOCRPremergePolicyBundle.File.allCases.map {
                ($0.rawValue, directory.appendingPathComponent($0.rawValue + ".json"))
            })
            identity = ["status": "bundled", "version": NativeOCRPremergePolicyBundle.cacheVersion]
        }
        for (name, url) in inputs {
            guard let data = try? Data(contentsOf: url), data.count <= NativeOCRPremergeCandidateModel.maximumModelBytes else {
                identity[name] = "unavailable"
                continue
            }
            identity[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return identity
    }
    static func processImage(index: Int, url: URL, count: Int, run: URL, root: URL,
                             options: HostOptions, client: TranslationService) async -> HostPageResult {
            let directory = run.appendingPathComponent(String(format: "%04d", index + 1))
            let started = ProcessInfo.processInfo.systemUptime
            var row: [String: Any] = ["input": url.path, "directory": directory.path]
            print("[\(index + 1)/\(count)] \(url.path)")
            do {
                if ProcessInfo.processInfo.environment["AIDOKU_SOURCE_BANK_CAPTURE"] == "1",
                   ProcessInfo.processInfo.environment["AIDOKU_MODULE_BANK_CAPTURE"] != "1" {
                    throw HostError.message("Source-bank capture requires module-bank capture")
                }
                if ProcessInfo.processInfo.environment["AIDOKU_MODULE_BANK_CAPTURE"] == "1" {
                    guard options.ocrOnly, options.retranslateRun == nil, options.resumeRun == nil else {
                        throw HostError.message("Module-bank capture requires a fresh --ocr-only run without saved OCR injection")
                    }
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let expectedResumeIdentity = try resumeIdentity(input: url, options: options, pageDirectoryName: directory.lastPathComponent)
                if options.resumeRun != nil, let data = try? Data(contentsOf: directory.appendingPathComponent("final.json")),
               let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard saved["input"] as? String == url.path else { throw HostError.message("Resume input order differs at \(directory.lastPathComponent)") }
                guard saved["resumeIdentity"] as? String == expectedResumeIdentity else {
                    throw HostError.message("Resume input/settings/translation contract differ at \(directory.lastPathComponent). Start a new run; use --render-run to view saved results.")
                }
                if saved["mode"] as? String == "translation", saved["renderEngine"] as? String != "native-coretext-coregraphics" {
                    // Upgrade a completed browser-rendered run from its saved payload without
                    // repeating OCR, provider requests, or replacing the user's translations.
                    let files = try HostAnalysis.stageFiles(in: directory)
                    guard let payload = files.last(where: { $0.lastPathComponent.hasSuffix("-render-payload.json") }),
                          let object = try JSONSerialization.jsonObject(with: Data(contentsOf: payload)) as? [String: Any],
                          let value = object["value"] as? [String: Any] else {
                        throw HostError.message("Completed legacy translation has no saved render payload")
                    }
                    let image = try loadImage(directory.appendingPathComponent("input.png"))
                    let dump = HostDumpContext(directory: directory, quiet: options.quiet)
                    try await HostDump.$context.withValue(dump) {
                        try await renderGate.withPermit { @MainActor in
                            try await renderPayload(value, image: image, root: root, directory: directory,
                            sourceMetadata: NativePNGMetadata.source(at: directory.appendingPathComponent("input.png")))
                        }
                    }
                    try dump.requireComplete()
                    try markNativeRender(in: directory)
                    try HostAnalysis.publishFinal(imageDirectory: directory, runDirectory: run)
                    row["nativeRenderMigrated"] = true
                }
                row["status"] = "success"; row["regions"] = (saved["regions"] as? [Any])?.count ?? 0
                row["resumed"] = true
                print("Already completed: \(directory.lastPathComponent)"); return HostPageResult(index: index, row: row)
            }
            let dump = HostDumpContext(directory: directory, quiet: options.quiet)
                try await HostDump.$context.withValue(dump) {
                    let preparation: Task<Void, Never>? = options.ocrOnly || options.translations != nil ? nil : Task {
                        await client.prepare(configuration: options.configuration)
                    }
                    defer { preparation?.cancel() }
                    let image = try loadImage(url)
                    let moduleBank = try HostModuleBankBootstrap.makeSession(sourceURL: url, original: image,
                        directory: directory, configuration: options.ocrConfiguration,
                        sourceAnchorMode: try sourceAnchorMode().rawValue)
                    var moduleBankFinished = false
                    defer {
                        if let moduleBank, !moduleBankFinished {
                            moduleBank.recordFailure("page transaction did not finish")
                            _ = try? moduleBank.finish()
                        }
                    }
                    let evidenceLease: NativeMainEnsembleEvidenceLease?
                    if NativeMainEnsembleRenderer.enabled {
                        evidenceLease = try NativeMainEnsembleEvidenceStore.shared.lease(original: image)
                    } else {
                        evidenceLease = nil
                    }
                    defer { evidenceLease?.release() }
                    let savedOCR = options.retranslateRun?.appendingPathComponent(directory.lastPathComponent)
                    if let savedOCR {
                        let sourcePNG = savedOCR.appendingPathComponent("input.png")
                        guard FileManager.default.fileExists(atPath: sourcePNG.path) else {
                            throw HostError.message("Saved OCR input missing: \(sourcePNG.path)")
                        }
                        let savedInput = directory.appendingPathComponent("input.png")
                        if FileManager.default.fileExists(atPath: savedInput.path) {
                            guard FileManager.default.contentsEqual(atPath: sourcePNG.path, andPath: savedInput.path) else {
                                throw HostError.message("Saved OCR resume input differs: \(savedInput.path)")
                            }
                        } else {
                            try FileManager.default.linkItem(at: sourcePNG, to: savedInput)
                        }
                    } else {
                        try savePNG(image, to: directory.appendingPathComponent("input.png"),
                            metadata: NativePNGMetadata.source(at: url))
                    }
                    HostDump.capture("input", ["engineFingerprint": ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unknown",
                        "file": url.path, "width": image.width, "height": image.height,
                        "configuration": HostDump.json(options.ocrConfiguration)])
                    HostDump.capture("runtime-settings", ["baseURL": options.baseURL, "model": options.model,
                        "sourceAnchorMode": try sourceAnchorMode().rawValue,
                        "rawCanonicalPolicyVersion": NativeOCRRawCanonicalPolicy.version,
                        "detectorAlternatePolicyVersion": NativeCoreMLDBPostprocessor.alternateCellEnvelopeEnabled
                            ? NativeOCRRawCanonicalPolicy.detectorAlternatePolicyVersion : "disabled",
                        "sourceAppearanceBackend": HostOperationalAppearance.selectedBackend,
                        "sharedRFRawCache": NativeRFRawCachePolicy.enabled,
                        "sharedOwnerOutlinedGapRelaxed": ProcessInfo.processInfo.environment["AIDOKU_RF_OWNER_RELAX_OUTLINED_GAP"] == "1",
                        "protocol": options.apiProtocol.rawValue, "reasoningEffort": options.reasoningEffort.rawValue,
                        "timeout": options.timeout, "sourceLanguage": options.source, "targetLanguage": options.target,
                        "ocr": HostDump.json(options.ocrConfiguration),
                        "translationSourceLanguages": options.translationSourceLanguages, "includePageImage": options.includeImage,
                        "filterSFXWithLLM": options.filterSFX, "filterBackgroundWithLLM": options.filterBackground,
                        "rightToLeftPanelOrder": options.rtl, "jobs": options.jobs, "appearance": try options.appearance, "viewport": [options.viewport.width, options.viewport.height]])
                    let orderedSourceMark = options.rtl ? nil : HostDump.context?.markOrderedInput()
                    let rawSink = savedOCR == nil && NativeCausalRawDecodeDiagnostics.runtimeEnabled
                        ? try HostRawDecodeSink(url: directory.appendingPathComponent("raw-ocr-decode.jsonl")) : nil
                    let rawRecorder = rawSink.map { sink in NativeCausalRawDecodeDiagnostics(sink: { sink.write($0) }) }
                    var regions: [ReaderTranslationRegion]
                    do {
                        if let savedOCR {
                            let grouped = try HostSavedOCRReplay.loadGrouped(from: savedOCR, expectedInput: url,
                                imageSize: CGSize(width: image.width, height: image.height))
                            // One fresh RF-only pass for the regrouped saved owners;
                            // no OCR recognition or prefilter admission is repeated.
                            regions = try await ReaderOCRService.shared.refreshingPostLLMEvidence(
                                regions: grouped.regions, image: image)
                            HostDump.capture("saved-ocr-replay", ["source": savedOCR.path,
                                "regions": regions.count, "originalRegions": grouped.originalCount,
                                "recoveredLineages": grouped.recoveredLineages, "merged": grouped.merged,
                                "split": grouped.split, "evidenceDirectory": grouped.evidenceDirectory,
                                "policy": HostSavedOCRReplay.groupingPolicy])
                        } else {
                            regions = try await NativeCausalRawDecodeDiagnostics.$current.withValue(rawRecorder) {
                                try await NativeOCRRawCanonicalRuntime.$sourceAnchorMode.withValue(try sourceAnchorMode()) {
                                    if let moduleBank {
                                        return try await NativeOCRRawCanonicalRuntime.$moduleObserver.withValue(moduleBank.rawObserver) {
                                            try await NativeCoreMLRecognitionObservations.$current.withValue(moduleBank.recognitionObserver) {
                                                try await ReaderOCRService.shared.recognize(image: image, configuration: options.ocrConfiguration)
                                            }
                                        }
                                    }
                                    return try await ReaderOCRService.shared.recognize(image: image, configuration: options.ocrConfiguration)
                                }
                            }
                        }
                    } catch {
                        rawRecorder?.finish()
                        try? rawSink?.close()
                        throw error
                    }
                    rawRecorder?.finish()
                    try rawSink?.close()
                    // Regrouped boxes must be drawn from the actual provider
                    // inputs, never linked from the old snapshot's preview.
                    try drawOCR(regions, image: image, to: directory.appendingPathComponent("ocr-boxes.png"))
                    if options.rtl && savedOCR == nil {
                        let ranks = ReaderTranslationPanelOrder.rightToLeftRanks(image: image, inputs: regions.map {
                            .init(rect: $0.rect, isVertical: $0.sourceOrientation == .vertical)
                        })
                        for index in regions.indices { regions[index].translationOrder = ranks[index] }
                        regions.sort { ($0.translationOrder ?? 0) < ($1.translationOrder ?? 0) }
                    }
                    if let context = HostDump.context {
                        context.captureOrdered(regions, mark: orderedSourceMark, unchanged: !options.rtl)
                    }
                    print("OCR ready: \(directory.lastPathComponent), \(regions.count) regions; \(directory.appendingPathComponent("ocr-boxes.png").path)")
                    if !options.ocrOnly {
                        if let translations = options.translations {
                            for index in regions.indices {
                                guard let text = translations[regions[index].source] else {
                                    throw HostError.message("Offline translation missing for source: \(regions[index].source)")
                                }
                                regions[index].applyTranslation(RemoteTranslatedSegment(id: regions[index].id, text: text))
                            }
                            HostDump.capture("offline-translations", regions)
                        } else {
                            let settings = ReaderTranslationSettings(includePageImage: options.includeImage,
                                sourceLanguage: options.source, targetLanguage: options.target,
                                translationSourceLanguages: options.translationSourceLanguages,
                                filterSFXWithLLM: options.filterSFX, filterBackgroundWithLLM: options.filterBackground,
                                rightToLeftPanelOrder: options.rtl, modelTier: options.tier)
                            let sourceOwners = regions
                            let candidates = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
                            HostDump.capture("language-filtered-regions", candidates)
                            let eligibleIDs = Set(candidates.map(\.id))
                            regions = candidates
                            var plans = ReaderTranslationService.plans(regions: regions.filter { eligibleIDs.contains($0.id) }, settings: settings)
                            let originalIndices = Dictionary(uniqueKeysWithValues: regions.enumerated().map { ($0.element.id, $0.offset) })
                            let jpeg = options.includeImage ? try HostTranslationParity.translationJPEG(image) : nil
                            let originalImageIdentity = options.includeImage && (options.filterSFX || options.filterBackground)
                                ? try? NativeRFDETRSourceImage.decode(image).identity : nil
                            for index in plans.indices {
                                var request = plans[index].request
                                if index == plans.startIndex {
                                    request.imageJPEG = jpeg
                                    request.roleEvidenceSourceImageIdentity = originalImageIdentity
                                } else {
                                    // Share the immutable page representation and digest memo across batches.
                                    request.copyImageRepresentation(from: plans[plans.startIndex].request)
                                }
                                request.filtersSFX = options.filterSFX ? true : nil
                                request.filtersBackground = options.filterBackground ? true : nil
                                request.translatesPageLettering = true
                                plans[index] = .init(request: request, inputIndicesBySegmentID: plans[index].inputIndicesBySegmentID)
                            }
                            HostDump.capture("translation-batches", plans)
                            for plan in plans {
                                // Provider admission is inside the shared service,
                                // so exact cache hits do not wait for a network slot.
                                let initialResult = try await client.translate(plan.request, configuration: options.configuration,
                                    onPartial: { dump.capture("translation-partial", $0) })
                                // Exact cache/in-flight hits make no new provider call.
                                // A page cache miss gets exactly one provider request;
                                // keep primary misses explicit for review.
                                // no role/literal recovery request follows it.
                                let result = initialResult
                                let primaryMisses = ReaderTranslationService.unresolvedPrimaryTranslationIDs(
                                    plan: plan, result: result, regions: regions, targetLanguage: options.target)
                                let recoveryFailures = Dictionary(uniqueKeysWithValues: primaryMisses.map { ($0, "primary_untranslated") })
                                HostDump.capture("translation-result", result)
                                for segment in result.translations {
                                    if let index = originalIndices[segment.id] {
                                        regions[index].applyTranslation(RemoteTranslatedSegment(id: segment.id,
                                            text: ReaderTranslationLanguageFilter.removingForeignScriptTail(segment.text,
                                                target: options.target),
                                            isSFX: segment.isSFX, textRole: segment.textRole))
                                        regions[index].translationRecoveryFailure = recoveryFailures[segment.id]
                                    }
                                }
                            }
                            regions = ReaderTranslationLanguageFilter.preservingExcludedSource(
                                original: sourceOwners, translated: regions, eligibleIDs: eligibleIDs)
                        }
                        let renderRegions = regions
                        print("Translation ready: \(directory.lastPathComponent); rendering \(renderRegions.count) regions")
                        try await renderGate.withPermit { @MainActor in
                            try await render(renderRegions, image: image, target: options.target, root: root, directory: directory, settings: try options.overlaySettings, viewport: options.viewport,ocrConfiguration:options.ocrConfiguration)
                        }
                    }
                    HostDump.capture("final-regions", regions)
                    if let moduleBank {
                        try moduleBank.writeJSON(stage: "actualGroupedRegions", value: HostDump.json(regions), records: regions.count)
                        if ProcessInfo.processInfo.environment["AIDOKU_SOURCE_BANK_CAPTURE"] == "1" {
                            guard let packet = dump.currentOCRPacket else {
                                throw HostError.message("Source-bank capture requires the actual current OCR packet")
                            }
                            let sourceBank = try HostSourceBankCapture.captureForSession(root: root, originalURL: url, source: image,
                                regions: regions, packet: packet, pageDirectory: directory, session: moduleBank)
                            try moduleBank.writeJSON(stage: "sourceBankReceipt", value: [
                                "manifest": sourceBank.manifest.path,
                                "SHA256": try HostRenderProvenance.fileSHA256(sourceBank.manifest),
                                "observedOwners": sourceBank.observedOwners,
                                "observedEmpty": sourceBank.observedEmpty
                            ], records: 1)
                        }
                        let manifestURL = try moduleBank.finish()
                        moduleBankFinished = true
                        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
                        guard manifest?["complete"] as? Bool == true else {
                            throw HostError.message("OCR completed but module-bank observations are incomplete")
                        }
                    }
                    let final = try JSONSerialization.data(withJSONObject: ["input": url.path, "width": image.width,
                        "resumeIdentity": expectedResumeIdentity,
                        "height": image.height, "mode": options.ocrOnly ? "ocr-only" : "translation",
                        "renderEngine": options.ocrOnly ? "none" : "native-coretext-coregraphics",
                        "unresolvedRecoveryCount": regions.filter { $0.translationRecoveryFailure != nil }.count,
                        "translationRecoveryComplete": !regions.contains { $0.translationRecoveryFailure != nil },
                        "regions": HostDump.json(regions)], options: [.prettyPrinted, .sortedKeys])
                    // final.json is the resume completion marker; failed diagnostic writes
                    // must not leave an incomplete page eligible to be skipped next time.
                    try dump.requireComplete()
                    try final.write(to: directory.appendingPathComponent("final.json"), options: .atomic)
                    do {
                        try HostEnsembleEvidence.captureSavedContext(sourceURL: directory.appendingPathComponent("input.png"),
                            image: image, directory: directory, packet: dump.currentOCRPacket)
                    } catch {
                        // Optional replay evidence must not relabel completed
                        // OCR/rendering as failed or manufacture an empty bank.
                        HostDump.capture("saved-source-context", ["status": "capture-unavailable", "error": String(describing: error)])
                        try dump.requireComplete()
                    }
                    try HostAnalysis.publishFinal(imageDirectory: directory, runDirectory: run)
                    row["regions"] = regions.count
                }
                row["status"] = "success"
            } catch {
                row["status"] = "failed"
                row["error"] = String(describing: error)
                row["errorType"] = String(reflecting: type(of: error))
                fputs("FAILED: \(url.path): \(error)\n", stderr)
                if let data = try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("error.json"))
                }
            }
            row["totalMilliseconds"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            return HostPageResult(index: index, row: row)
    }
    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary) else {
            throw HostError.message("Cannot decode image: \(url.path)")
        }
        return image
    }
    static func imageData(_ image: CGImage, type: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw HostError.message("Image encoder unavailable") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HostError.message("Image encoding failed") }
        return data as Data
    }
    @discardableResult
    static func savePNG(_ image: CGImage, to url: URL, metadata: NativePNGMetadata.Source? = nil) throws
        -> (encodeMilliseconds: Double, commitMilliseconds: Double) {
        try Task.checkCancellation()
        // ImageIO writes directly to a sibling file, avoiding a retained full PNG
        // NSMutableData buffer. The final pathname changes only after finalization.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let started = ProcessInfo.processInfo.systemUptime
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else {
            throw HostError.message("Image encoder unavailable")
        }
        var properties = metadata?.propertiesForUprightPixels(width: image.width, height: image.height)
            ?? [kCGImagePropertyOrientation: 1]
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HostError.message("Image encoding failed") }
        let encoded = ProcessInfo.processInfo.systemUptime
        try Task.checkCancellation()
        // POSIX rename atomically replaces an existing file on this filesystem.
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return ((encoded - started) * 1000, (ProcessInfo.processInfo.systemUptime - encoded) * 1000)
    }
    static func drawOCR(_ regions: [ReaderTranslationRegion], image: CGImage, to url: URL) throws {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw HostError.message("Cannot allocate OCR preview")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.2, alpha: 1))
        context.setLineWidth(2)
        for region in regions {
            let r = region.rect
            context.stroke(CGRect(x: r.minX * CGFloat(image.width), y: (1 - r.maxY) * CGFloat(image.height),
                width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)))
        }
        guard let output = context.makeImage() else { throw HostError.message("OCR preview failed") }
        try savePNG(output, to: url)
    }
}

extension ImageTranslationMain {
    /// Current production PDF/diagnostic evidence, streamed one page at a time.
    /// No source artifacts, OCR/translation state, or images are overwritten.
    /// This branch executes before HostEnvironment.load and never calls a provider.
    static func auditRenderRun(_ run: URL, root: URL, preparationOnly: Bool = false) async throws -> Int32 {
        HostOperationalAppearance.install(root: root)
        _ = HostLetterFonts(root: root)
        let directories = try FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var count = 0, failures = 0
        func values(_ rect: CGRect) -> [Double] {
            [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
        }
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        for directory in directories where FileManager.default.fileExists(atPath: directory.appendingPathComponent("final.json").path) {
            try Task.checkCancellation()
            let page = directory.lastPathComponent
            do {
                // Acquire async shared DB before entering synchronous PDF composition.
                // Preparation-only audits never need a full removal mask or DET.
                let auditDB:(image:CGImage,prepared:NativeMainEnsemblePreparedDB)?
                if !preparationOnly,NativeMainEnsembleRenderer.enabled {
                    let files=try HostAnalysis.stageFiles(in:directory)
                    guard let payload=files.last(where:{$0.lastPathComponent.hasSuffix("-render-payload.json")}),
                          let envelope=try JSONSerialization.jsonObject(with:Data(contentsOf:payload)) as? [String:Any],
                          let stored=envelope["value"] as? [String:Any] else {throw HostError.message("Missing audit render payload")}
                    if let evidence=stored["nativeEnsembleEvidence"] as? [String:Any],
                       evidence["requireCompleteEvidence"] as? Bool == true || evidence["schema"] as? String == HostEnsembleEvidence.completeV2Schema {
                        throw HostError.message("CompleteV2 audit PDF unsupported; use direct-main render-run")
                    }
                    let image=try loadImage(directory.appendingPathComponent("input.png"))
                    let prepared=try await HostDBProbability.prepare(arguments:stored,original:image,
                        stageDirectory:directory,root:root)
                    auditDB=(image,prepared)
                } else {auditDB=nil}
                defer {withExtendedLifetime(auditDB) {}}
                // Include JSON encoding and stdout conversion in the page's pool;
                // the inner render pool alone leaves their temporaries alive.
                try autoreleasepool {
                    let row: [String: Any] = try autoreleasepool {
                        let files = try HostAnalysis.stageFiles(in: directory)
                        guard let payload = files.last(where: { $0.lastPathComponent.hasSuffix("-render-payload.json") }) else {
                            throw HostError.message("Missing saved native payload")
                        }
                        let payloadBytes = try Data(contentsOf: payload)
                        guard let object = try JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any],
                              let stored = object["value"] as? [String: Any],
                              let nativeLayout = stored["nativeLayout"] as? [String: Any],
                              let nativeSettings = stored["nativeSettings"] as? [String: Any] else {
                            throw HostError.message("Audit requires saved native layout and settings; no planner fallback")
                        }
                        let layout = try JSONDecoder().decode(NativeTranslationLayout.self,
                            from: JSONSerialization.data(withJSONObject: nativeLayout))
                        let imageURL = directory.appendingPathComponent("input.png")
                        // Retain only the digest across decoding/rendering, not another
                        // compressed image buffer for the entire audit page lifetime.
                        let inputSHA256 = try autoreleasepool {
                            digest(try Data(contentsOf: imageURL))
                        }
                        let image = try auditDB?.image ?? loadImage(imageURL)
                        let savedMasks = try NativeCausalUnownedInkLiveRecovery.masksFromPayload(
                            stored["causalUnownedContextMasks"], original: image)
                        try NativeMainEnsembleEvidenceStore.shared.register(unownedMasks: savedMasks, original: image)
                        let (viewport, display) = try HostRenderGeometry.savedFrames(stored, fallbackViewport: layout.viewport)
                        guard layout.imageSize == CGSize(width: image.width, height: image.height),
                              layout.viewport == viewport,
                              layout.sourceRect == display else { throw HostError.message("Saved layout/source coordinates mismatch") }
                        var settings = try HostOverlayAppearance.settings(saved: nativeSettings)
                        if let geometry = stored["hostTextBoxGeometryParameters"] as? [String: Any] {
                            settings.textBoxGeometryParameters = try JSONDecoder().decode(NativeTextBoxGeometryParameters.self,
                                from: JSONSerialization.data(withJSONObject: geometry))
                            guard settings.textBoxGeometryParameters.isValid else {
                                throw HostError.message("Invalid saved geometry parameters")
                            }
                        }
                        settings.visible = true
                        let output = HostRenderGeometry.outputPixelSize(for: layout.imageSize)
                        let auditWork = ReadabilityAuditBudget()
                        var auditObservations: [[String: Any]] = []
                        var auditUnavailableCount = 0
                        let observer: NativeTranslationRenderer.AuditCardObserver = { stage, card in
                            if let value = NativeParagraphReadabilityGuard.auditObservation(card, stage: stage.rawValue, work: auditWork) {
                                auditObservations.append(value)
                            } else { auditUnavailableCount += 1 }
                        }
                        let started = ProcessInfo.processInfo.systemUptime
                        if preparationOnly {
                            // Geometry/style/certification replay without final source
                            // composition, PDF export or embedded media. This is not
                            // final-pixel or visual quality evidence.
                            let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout,
                                image: UIImage(cgImage: image), settings: settings,
                                scale: output.width / display.width, renderBounds: display,
                                outputPixelSize: output, collectDiagnostics: true, pdfDeviceScale: 1,
                                auditCardObserver: observer)
                            guard let diagnostics = plan.diagnosticData else {
                                throw HostError.message("Preparation diagnostics unavailable")
                            }
                            var usage = rusage()
                            let highWater: Int64? = getrusage(RUSAGE_SELF, &usage) == 0 && usage.ru_maxrss >= 0
                                ? Int64(usage.ru_maxrss) : nil
                            return ["id": page, "status": "prepared", "finalPixelsObserved": false,
                                "diagnostics": try JSONSerialization.jsonObject(with: diagnostics),
                                "sourceRect": values(layout.sourceRect), "inputSHA256": inputSHA256,
                                "payloadSHA256": digest(payloadBytes), "preparedCardCount": plan.cards.count,
                                "expectedRenderCardIDs": layout.items.filter { !$0.keptLettering && !$0.text.isEmpty }.map(\.id),
                                "limitations": plan.limitations,
                                "prepareMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                "producerProcessHighWaterRSSBytes": highWater as Any? ?? NSNull(),
                                "nativeBuildFingerprint": ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unavailable"]
                        }
                        let rendered = try NativeTranslationRenderer.renderPDFSynchronously(layout: layout,
                            image: UIImage(cgImage: image), settings: settings,
                            scale: output.width / display.width, renderBounds: display,
                            outputPixelSize: output, collectDiagnostics: true, pdfDeviceScale: 1,
                            auditCardObserver: observer,preparedDB:auditDB?.prepared)
                        guard rendered.sourcePatches.isEmpty, let diagnostics = rendered.diagnosticData else {
                            throw HostError.message("Audit requires diagnostic solid text-box output without source patches")
                        }
                        let textLengths = Dictionary(uniqueKeysWithValues: layout.items.map {
                            ($0.id, ($0.typesettingText ?? $0.text).utf16.count)
                        })
                        var usage = rusage()
                        // Darwin reports bytes. This is the producer process lifetime
                        // high-water mark, not this page's renderer-only peak/delta.
                        let highWater: Int64? = getrusage(RUSAGE_SELF, &usage) == 0 && usage.ru_maxrss >= 0
                            ? Int64(usage.ru_maxrss) : nil
                        return ["id": page, "status": "rendered", "pdf": rendered.exportPDFData.base64EncodedString(),
                            "sourceRect": values(layout.sourceRect), "displayRect": values(display),
                            "paintBounds": rendered.paintBounds.map(values),
                            "sourceRestorations": rendered.sourceRestorationRects.map(values),
                            "diagnostics": try JSONSerialization.jsonObject(with: diagnostics), "textLengths": textLengths,
                            "nativeCardMetricAudit": auditObservations,
                            "nativeCardMetricAuditUnavailableCount": auditUnavailableCount,
                            "nativeCardMetricAuditBudgetReason": auditWork.exhaustionReason as Any? ?? NSNull(),
                            "expectedRenderCardIDs": layout.items.filter {
                                !$0.keptLettering && !$0.text.isEmpty
                            }.map(\.id),
                            "inputSHA256": inputSHA256, "payloadSHA256": digest(payloadBytes),
                            "nativeBuildFingerprint": ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unavailable",
                            "renderedItemCount": rendered.renderedItemCount, "limitations": rendered.limitations,
                            "renderMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                            "producerProcessHighWaterRSSBytes": highWater as Any? ?? NSNull(),
                            "outputPixelSize": [Double(output.width), Double(output.height)],
                            "imageSize": [image.width, image.height]]
                    }
                    let encoded = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    print(String(decoding: encoded, as: UTF8.self))
                }
                count += 1
                if (count + failures).isMultiple(of: 25) {
                    fputs("Native audit progress: \(count) rendered, \(failures) failed\n", stderr)
                }
            } catch {
                if error is CancellationError { throw error }
                failures += 1
                let failure: [String: Any] = ["id": page, "status": "failed", "error": String(describing: error),
                    "errorType": String(reflecting: type(of: error))]
                print(String(decoding: try JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]), as: UTF8.self))
            }
        }
        guard count + failures > 0 else { throw HostError.message("No saved completed pages") }
        fputs("Native audit stream: \(count) rendered, \(failures) failed; no media artifacts written\n", stderr)
        return failures == 0 ? 0 : 1
    }

    static func render(_ regions: [ReaderTranslationRegion], image: CGImage, target: String, root: URL, directory: URL,
                       settings: IPhoneOverlaySettings, viewport: CGSize,ocrConfiguration:ReaderOCRConfiguration) async throws {
        var settings = settings
        settings.visible = true // Export the translated page even when the reader overlay is currently hidden.
        let imageSize = CGSize(width: image.width, height: image.height)
        let sourceRect = HostRenderGeometry.displayRect(imageSize: imageSize, viewport: viewport)
        let overlayItems = ReaderTranslationRegion.layoutItems(regions, imageSize: imageSize)
        let items = HostProductionLayout.layoutPayload(items: overlayItems, imageSize: imageSize, sourceRect: sourceRect,
            settings: settings, targetLanguage: target, viewport: viewport)
        let nativeItems = try JSONDecoder().decode([NativeTranslationLayoutItem].self,
            from: JSONSerialization.data(withJSONObject: items))
        let layout = NativeTranslationLayout(imageSize: imageSize, sourceRect: sourceRect, viewport: viewport,
            items: nativeItems, sourceObjectFit: "contain")
        var arguments: [String: Any] = ["items": items, "revision": "1", "session": "host-pipeline",
            "appearance": HostOverlayAppearance.value(settings: settings, fonts: HostLetterFonts(root: root)),
            "hostViewportContract": HostRenderGeometry.readerFitContract,
            "hostViewport": [viewport.width, viewport.height],
            "hostDisplayRect": [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height],
            "hostLayout": "production-layout-appkit-metrics", "hostRenderer": "native-coretext-coregraphics",
            "nativeLayout": try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)),
            "nativeSettings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)),
            "nativeOCRConfiguration": try JSONSerialization.jsonObject(with:JSONEncoder().encode(ocrConfiguration))]
        if NativeCausalUnownedInkLiveRecovery.runtimeEnabled || NativeCausalRFOriginalContextRecovery.runtimeEnabled {
            let masks = try NativeMainEnsembleEvidenceStore.shared.unownedMasks(original: image)
            if !masks.isEmpty {
                arguments["causalUnownedContextMasks"] = try NativeCausalUnownedInkLiveRecovery.maskPayload(masks, original: image)
            }
        }
        HostDump.capture("render-payload", arguments)
        try await renderPayload(arguments, image: image, root: root, directory: directory,
            sourceMetadata: NativePNGMetadata.source(at: directory.appendingPathComponent("input.png")))
    }
    static func markNativeRender(in directory: URL) throws {
        let url = directory.appendingPathComponent("final.json")
        guard var value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw HostError.message("Invalid saved final metadata")
        }
        value["renderEngine"] = "native-coretext-coregraphics"
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    /// End the worker/result lifetime before final full-page PNG encoding.
    private static func composeAndPersistRender(layout: NativeTranslationLayout, image: CGImage,
        settings: IPhoneOverlaySettings, outputSize: CGSize, displayRect: CGRect, directory: URL,
        completeEvidence: NativeMainEnsembleRenderEvidence? = nil,
        preparedDB:NativeMainEnsemblePreparedDB? = nil) async throws
        -> (image: CGImage, renderedItemCount: Int, limitations: [String], stagesMilliseconds: [String: Double]) {
        defer {withExtendedLifetime(preparedDB) {}}
        if completeEvidence == nil,NativeMainEnsembleRenderer.enabled {
            guard let preparedDB else {throw NativeMainEnsemblePreparedDB.Failure.requiredDBUnavailable}
            try preparedDB.validate(original:image)
        }
        if HostRenderProvenance.directMainPNGRequested(ProcessInfo.processInfo.environment),
           NativeMainEnsembleRenderer.enabled,
           displayRect == layout.sourceRect,
           outputSize == CGSize(width: image.width, height: image.height) {
            // The real production page already contains restoration and complete
            // retained text at these exact source coordinates. No PDF export,
            // rescale or secondary raster composition is required for PNG-only.
            let start = ProcessInfo.processInfo.systemUptime
            let dumpContext = HostDump.context
            let worker = Task.detached(priority: .userInitiated) {
                try HostDump.$context.withValue(dumpContext) {
                    try NativeMainEnsembleRenderer.page(layout: layout, source: image,
                        completeEvidence: completeEvidence,preparedDB:preparedDB)
                }
            }
            let page = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            if ProcessInfo.processInfo.environment["AIDOKU_EXPORT_ENSEMBLE_EVALUATION"] == "1",
               let removalMask = page.result.removalMask,
               let report = try JSONSerialization.jsonObject(with: page.diagnostics) as? [String: Any] {
                _ = try savePNG(page.result.restored, to: directory.appendingPathComponent("restored.png"))
                _ = try savePNG(page.result.text, to: directory.appendingPathComponent("text.png"))
                _ = try savePNG(removalMask, to: directory.appendingPathComponent("removal-mask.png"))
                try JSONSerialization.data(withJSONObject: ["report": report,
                    "renderItems": report["renderItems"] ?? [], "mask": "removal-mask.png", "restored": "restored.png",
                    "text": "text.png"], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent("main-ensemble-evaluation.json"), options: .atomic)
            }
            try page.layoutData.write(to: directory.appendingPathComponent("native-layout.json"), options: .atomic)
            HostDump.captureJSONObject("native-render-diagnostics", try JSONSerialization.jsonObject(with: page.diagnostics))
            try JSONSerialization.data(withJSONObject: ["mode": "png-only-direct-main",
                "typographyPDFPersisted": false, "typographyPDFComputed": false,
                "portableLayerReplayAvailable": false,
                "pixelAuthority": "production NativeMainEnsembleRenderer.page result, exact source-size geometry",
                "omitted": ["final-typography.pdf", "final-layers.json"]], options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("artifact-persistence.json"), options: .atomic)
            return (page.result.image, page.count, [], ["native.directMainPNG":
                (ProcessInfo.processInfo.systemUptime - start) * 1000])
        }
        guard completeEvidence == nil else {
            throw HostError.message("CompleteV2 evidence cannot enter an unsupported PDF facade")
        }
        // The page gate serializes this synchronous native operation. PDF capture does not
        // depend on an attached UIKit window or the reader's live display-only minifier.
        let profileStages = ProcessInfo.processInfo.environment["AIDOKU_PROFILE_RENDER_STAGES"] == "1"
        var stagesMilliseconds: [String: Double] = [:]
        var stageStarted = profileStages ? ProcessInfo.processInfo.systemUptime : 0
        func finishStage(_ name: String) {
            guard profileStages else { return }
            let now = ProcessInfo.processInfo.systemUptime
            stagesMilliseconds[name] = (now - stageStarted) * 1000
            stageStarted = now
        }
        let renderSettings = settings
        let dumpContext = HostDump.context
        let worker = Task.detached(priority: .userInitiated) {
            try HostDump.$context.withValue(dumpContext) {
                try NativeTranslationRenderer.renderPDFSynchronously(layout: layout, image: UIImage(cgImage: image),
                    settings: renderSettings, scale: outputSize.width / displayRect.width, renderBounds: displayRect,
                    outputPixelSize: outputSize, collectDiagnostics: true, pdfDeviceScale: 1,preparedDB:preparedDB)
            }
        }
        let rendered = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        if ProcessInfo.processInfo.environment["AIDOKU_EXPORT_ENSEMBLE_EVALUATION"] == "1",
           let restored = rendered.ensembleRestored, let mask = rendered.ensembleRemovalMask,
           let diagnostics = rendered.diagnosticData,
           let report = try JSONSerialization.jsonObject(with: diagnostics) as? [String: Any] {
            _ = try savePNG(restored, to: directory.appendingPathComponent("restored.png"))
            _ = try savePNG(mask, to: directory.appendingPathComponent("removal-mask.png"))
            let artifacts: [String: Any] = ["report": report, "renderItems": report["renderItems"] ?? [],
                "mask": "removal-mask.png", "restored": "restored.png"]
            try JSONSerialization.data(withJSONObject: artifacts, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("main-ensemble-evaluation.json"), options: .atomic)
        }
        finishStage("nativeRenderPDF")
        if profileStages { stagesMilliseconds.merge(rendered.stagesMilliseconds) { _, latest in latest } }
        let typography = rendered.exportPDFData
        let output = try HostExportCompositor.composite(image: image, rendered: rendered, typography: typography,
            displayRect: displayRect, size: outputSize)
        finishStage("composite")
        let pngOnly = ProcessInfo.processInfo.environment["AIDOKU_REPLAY_PNG_ONLY"] == "1"
        if !pngOnly {
            try typography.write(to: directory.appendingPathComponent("final-typography.pdf"), options: .atomic)
        } else {
            // PDF still participates in the identical native composition above.
            // This explicit batch option only avoids persisting a second large
            // representation after the final raster has already been produced.
            let persistence: [String: Any] = ["mode": "png-only",
                "typographyPDFPersisted": false, "typographyPDFComputed": true, "portableLayerReplayAvailable": false,
                "nativeCompositionUnchanged": true,
                "retained": ["final.png", "native-layout.json", "native-render-diagnostics"],
                "omitted": ["final-typography.pdf"]]
            try JSONSerialization.data(withJSONObject: persistence, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("artifact-persistence.json"), options: .atomic)
        }
        try rendered.layoutData.write(to: directory.appendingPathComponent("native-layout.json"), options: .atomic)
        finishStage("typographyAndLayoutWrite")
        // Persist diagnostics before encoding the portable layer artifact.
        try autoreleasepool {
            guard let diagnostics = rendered.diagnosticData else { return }
            let decoded = try JSONSerialization.jsonObject(with: diagnostics)
            HostDump.captureJSONObject("native-render-diagnostics", decoded)
            finishStage("diagnosticJSONDecodeAndWrite")
        }
        try autoreleasepool {
            let layers = try HostExportCompositor.layers(for: rendered)
            try JSONEncoder().encode(layers).write(to: directory.appendingPathComponent("final-layers.json"), options: .atomic)
        }
        finishStage("layersExport")
        return (output, rendered.renderedItemCount, rendered.limitations, stagesMilliseconds)
    }

    /// Replay the stored planner output through the same native renderer used by the reader.
    /// Older payloads retain all item geometry and are migrated without OCR or a provider call.
    private struct PreparedPayload {
        let output: CGImage
        let renderedItemCount: Int
        let limitations: [String]
        let stagesMilliseconds: [String: Double]
        let layoutVersion: Int
        let started: TimeInterval
        let width: Double
        let height: Double
    }

    // Borrowed-image routes retain their original ownership contract.
    static func renderPayload(_ arguments: [String: Any], image: CGImage, root: URL, directory: URL,
                              sourceMetadata: NativePNGMetadata.Source? = nil) async throws {
        let prepared = try await preparePayload(arguments, image: image, root: root, directory: directory)
        let sourceURL = directory.appendingPathComponent("input.png")
        try persistPayload(prepared, arguments: arguments, directory: directory, sourceMetadata: sourceMetadata,
            sourceURL: FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil, payloadURL: nil)
    }

    private static func renderSavedPayload(_ arguments: [String: Any], sourceURL: URL, payloadURL: URL, root: URL, directory: URL,
                                          sourceMetadata: NativePNGMetadata.Source?) async throws {
        let prepared = try await prepareSavedPayload(arguments, sourceURL: sourceURL, root: root, directory: directory)
        try persistPayload(prepared, arguments: arguments, directory: directory, sourceMetadata: sourceMetadata,
            sourceURL: sourceURL, payloadURL: payloadURL)
    }

    private static func prepareSavedPayload(_ arguments: [String: Any], sourceURL: URL, root: URL,
                                           directory: URL) async throws -> PreparedPayload {
        // The owned source scope ends after composition and layer persistence, before PNG encoding.
        let image = try loadImage(sourceURL)
        if let evidence = arguments["nativeEnsembleEvidence"] as? [String: Any] {
            if evidence["requireCompleteEvidence"] as? Bool == true ||
                evidence["schema"] as? String == HostEnsembleEvidence.completeV2Schema {
                guard evidence["schema"] as? String == HostEnsembleEvidence.completeV2Schema else {
                    throw HostError.message("Unsupported required complete evidence schema")
                }
                return try await preparePayload(arguments, image: image, root: root, directory: directory,
                    completeDescriptor: evidence, completeSourceURL: sourceURL)
            }
            // Legacy caller format and behavior remain unchanged unless v2 is explicit.
            try HostEnsembleEvidence.register(evidence, sourceURL: sourceURL, image: image)
        }
        return try await preparePayload(arguments, image: image, root: root, directory: directory,
            configurationDirectory:sourceURL.deletingLastPathComponent())
    }

    private static func preparePayload(_ arguments: [String: Any], image: CGImage, root: URL,
                                       directory: URL, completeDescriptor: [String: Any]? = nil,
                                       completeSourceURL: URL? = nil,
                                       configurationDirectory:URL? = nil) async throws -> PreparedPayload {
        HostOperationalAppearance.install(root: root)
        try Task.checkCancellation()
        _ = HostLetterFonts(root: root)
        // Always replace the resident ledger, including absent/legacy payloads.
        // Saved evidence activates ONLY its exact original/source-bound pixels.
        if completeDescriptor == nil {
            let savedMasks = try NativeCausalUnownedInkLiveRecovery.masksFromPayload(
                arguments["causalUnownedContextMasks"], original: image)
            try NativeMainEnsembleEvidenceStore.shared.register(unownedMasks: savedMasks, original: image)
        }
        let imageSize = CGSize(width: image.width, height: image.height)
        let (viewport, displayRect) = try HostRenderGeometry.savedFrames(arguments, fallbackViewport: imageSize)
        var settings: IPhoneOverlaySettings
        if let stored = arguments["nativeSettings"] as? [String: Any] {
            settings = try HostOverlayAppearance.settings(saved: stored)
        } else {
            let appearance = arguments["appearance"] as? [String: Any] ?? [:]
            settings = try HostOverlayAppearance.settings(saved: [
                "opacity": appearance["opacity"] ?? 0.84,
                "preserveSourceTextColor": appearance["preserveSourceTextColor"] ?? false,
                "preserveSourceBackgroundColor": appearance["preserveSourceBackgroundColor"] ?? false,
                "inpaintingEnabled": appearance["inpaintingEnabled"] ?? false
            ])
        }
        settings.visible = true // Matches ReaderTranslationImageExporter.renderSerial.
        if let values = arguments["hostTextBoxGeometryParameters"] as? [String: Any] {
            settings.textBoxGeometryParameters = try JSONDecoder().decode(NativeTextBoxGeometryParameters.self,
                from: JSONSerialization.data(withJSONObject: values))
            guard settings.textBoxGeometryParameters.isValid else { throw HostError.message("Invalid geometry tuning") }
        }
        let layout: NativeTranslationLayout
        if let stored = arguments["nativeLayout"] as? [String: Any] {
            layout = try JSONDecoder().decode(NativeTranslationLayout.self,
                from: JSONSerialization.data(withJSONObject: stored))
            guard layout.imageSize == imageSize, layout.viewport == viewport, layout.sourceRect == displayRect else {
                throw HostError.message("Saved native layout does not match the source image and viewport")
            }
        } else {
            guard let items = arguments["items"] as? [[String: Any]] else {
                throw HostError.message("Missing saved render items")
            }
            layout = NativeTranslationLayout(imageSize: imageSize, sourceRect: displayRect, viewport: viewport,
                items: try JSONDecoder().decode([NativeTranslationLayoutItem].self,
                    from: JSONSerialization.data(withJSONObject: items)), sourceObjectFit: "fill")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let outputSize = HostRenderGeometry.outputPixelSize(for: imageSize)
        var completeEvidence: NativeMainEnsembleRenderEvidence?
        if let descriptor = completeDescriptor {
            // Complete snapshots are supported only by the direct shared page
            // facade in this patch. Reject before any RF/style/AOT model demand.
            guard let sourceURL = completeSourceURL,
                  HostRenderProvenance.directMainPNGRequested(ProcessInfo.processInfo.environment),
                  NativeMainEnsembleRenderer.enabled,
                  displayRect == layout.sourceRect,
                  outputSize == CGSize(width: image.width, height: image.height) else {
                throw HostError.message("CompleteV2 requires direct-main source-size PNG; PDF facade unsupported")
            }
            completeEvidence = try await HostEnsembleEvidence.prepareCompleteV2(descriptor,
                sourceURL: sourceURL, image: image, root: root, arguments: arguments)
        } else { completeEvidence = nil }
        let preparedDB:NativeMainEnsemblePreparedDB?
        if completeEvidence == nil,NativeMainEnsembleRenderer.enabled {
            preparedDB=try await HostDBProbability.prepare(arguments:arguments,original:image,
                stageDirectory:configurationDirectory ?? directory,root:root)
        } else {preparedDB=nil} // CompleteV2 remains its explicit no-DET exception.
        if completeEvidence == nil, let preparedDB, let sourceURL = HostDump.context?.sourceURL {
            if HostRenderProvenance.directMainPNGRequested(ProcessInfo.processInfo.environment),
               displayRect == layout.sourceRect,
               outputSize == CGSize(width: image.width, height: image.height) {
                completeEvidence = try await HostEnsembleEvidence.prepareSavedContext(sourceURL: sourceURL,
                    image: image, directory: configurationDirectory ?? sourceURL.deletingLastPathComponent(),
                    arguments: arguments, preparedDB: preparedDB)
                HostDump.capture("saved-source-context", ["status": completeEvidence == nil ? "unavailable-no-source-binding" : "source-bound",
                    "legacyOCRProducerAttestationInvented": false])
            } else {
                HostDump.capture("saved-source-context", ["status": "unsupported-PDF-facade", "complete": false])
            }
        }
        defer {withExtendedLifetime(preparedDB) {}}
        let composed = try await composeAndPersistRender(layout: layout, image: image, settings: settings,
            outputSize: outputSize, displayRect: displayRect, directory: directory,
            completeEvidence: completeEvidence,preparedDB:preparedDB)
        return PreparedPayload(output: composed.image, renderedItemCount: composed.renderedItemCount,
            limitations: composed.limitations, stagesMilliseconds: composed.stagesMilliseconds,
            layoutVersion: layout.version, started: started, width: Double(viewport.width), height: Double(viewport.height))
    }

    private static func persistPayload(_ prepared: PreparedPayload, arguments: [String: Any], directory: URL,
                                       sourceMetadata: NativePNGMetadata.Source?, sourceURL: URL?, payloadURL: URL?) throws {
        let output = prepared.output, width = prepared.width, height = prepared.height, started = prepared.started
        HostDump.capture("render-result", ["engine": "native-coretext-coregraphics", "renderedItemCount": prepared.renderedItemCount,
            "limitations": prepared.limitations, "layoutVersion": prepared.layoutVersion])
        let profileStages = !prepared.stagesMilliseconds.isEmpty
        var stagesMilliseconds = prepared.stagesMilliseconds
        let pngTiming = try savePNG(output, to: directory.appendingPathComponent("final.png"), metadata: sourceMetadata)
        try HostRenderProvenance.write(directory: directory, sourceURL: sourceURL, payloadURL: payloadURL,
            effectivePayload: arguments, environment: ProcessInfo.processInfo.environment)
        if profileStages {
            stagesMilliseconds["finalPNGEncode"] = pngTiming.encodeMilliseconds
            stagesMilliseconds["finalPNGWrite"] = pngTiming.commitMilliseconds
        }
        var renderTiming: [String: Any] = ["milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
            "width": output.width, "height": output.height, "layout": arguments["hostLayout"] ?? "legacy-payload-replay",
            "viewport": [width, height], "metricsPlatform": "AppKit-CoreText", "engine": "native-coretext-coregraphics"]
        renderTiming["PNGResolutionStatus"] = sourceMetadata?.resolutionStatus ?? "unavailable-source-properties"
        renderTiming["PNGOrientation"] = 1
        if profileStages { renderTiming["stagesMilliseconds"] = stagesMilliseconds }
        HostDump.capture("render-timing", renderTiming)
        // HTML is a portable view of the native result. Offline recomposition is performed
        // by --render-run with the stored payload; opening this page executes no renderer.
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Native translation result</title><style>html,body{margin:0;background:#202124}img{display:block;max-width:100%;height:auto;margin:auto}</style>
        </head><body data-renderer="native-coretext-coregraphics" data-render-build="\(HostRenderProvenance.fingerprint(ProcessInfo.processInfo.environment) ?? "unmeasured")"><img alt="Translated page" width="\(output.width)" height="\(output.height)" src="final.png"></body></html>
        """
        try html.write(to: directory.appendingPathComponent("final.html"), atomically: true, encoding: .utf8)
    }
}

extension NativeTranslationRenderer.PDFResult: HostExportCompositingOutput {}
