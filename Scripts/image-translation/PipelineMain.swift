import AppKit
import Foundation
import CoreGraphics
import ImageIO
import WebKit

struct HostOptions {
    var inputs: [URL] = []
    var lists: [URL] = []
    var recursive = false
    var quiet = false
    var limit: Int?
    var jobs = 8
    var viewport = CGSize(width: 430, height: 932)
    var output: URL
    var resumeRun: URL?
    var tier: IPhoneOCRModelTier = .medium
    var source = "auto"
    var target = "ko"
    var confidence = 0.75
    var detectorSide = 1600
    var recognizerWidth = 1600
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
    var allowLocalHTTP = false
    var includeImage = false
    var filterSFX = false
    var filterBackground = false
    var rtl = false
    var ocrOnly = false
    var translations: [String: String]?
    init(root: URL, arguments: [String]) throws {
        output = root.deletingLastPathComponent().appendingPathComponent("output/image-translation")
        var index = 0
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
        }
        for key in ["AIDOKU_OCR_DETECTOR_SIDE", "AIDOKU_OCR_RECOGNIZER_WIDTH"] {
            if let value = setting(key) {
                guard let parsed = Int(value), parsed > 0 else { throw HostError.message("Invalid positive integer setting: " + key) }
                if key == "AIDOKU_OCR_DETECTOR_SIDE" { detectorSide = parsed } else { recognizerWidth = parsed }
            }
        }
        if let value = setting("AIDOKU_TRANSLATION_PROTOCOL") {
            guard let parsed = RemoteTranslationProtocol(rawValue: value) else { throw HostError.message("Invalid setting: AIDOKU_TRANSLATION_PROTOCOL") }
            apiProtocol = parsed
        }
        for key in ["AIDOKU_OCR_DETECTOR_PIXEL_THRESHOLD", "AIDOKU_OCR_DETECTOR_CONFIDENCE_THRESHOLD", "AIDOKU_OCR_DETECTOR_MINIMUM_BOX_SIDE", "AIDOKU_TRANSLATION_TIMEOUT"] {
            if let value = setting(key) {
                guard let parsed = Double(value), parsed.isFinite, parsed > 0,
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
        includeImage = try boolean("AIDOKU_TRANSLATION_INCLUDE_IMAGE", fallback: includeImage)
        filterSFX = try boolean("AIDOKU_TRANSLATION_FILTER_SFX", fallback: filterSFX)
        filterBackground = try boolean("AIDOKU_TRANSLATION_FILTER_BACKGROUND", fallback: filterBackground)
        rtl = try boolean("AIDOKU_TRANSLATION_RTL", fallback: rtl)
        allowLocalHTTP = try boolean("AIDOKU_TRANSLATION_ALLOW_LOCAL_HTTP", fallback: allowLocalHTTP)
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--list": lists.append(URL(fileURLWithPath: try value()).standardizedFileURL)
            case "--output": output = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--resume-run": resumeRun = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--limit": limit = try positive(value())
            case "--viewport": viewport = try HostRenderGeometry.parseViewport(try value())
            case "--jobs":
                let parsed = try positive(value())
                guard parsed <= 64 else { throw HostError.message("--jobs must be in 1...64") }
                jobs = parsed
            case "--recursive": recursive = true
            case "--quiet": quiet = true
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
            case "--detector-side": detectorSide = try positive(value())
            case "--recognizer-width": recognizerWidth = try positive(value())
            case "--base-url": baseURL = try value()
            case "--model": model = try value()
            case "--key-env": keyEnv = try value()
            case "--protocol":
                guard let parsed = RemoteTranslationProtocol(rawValue: try value()) else { throw HostError.message("Unknown API protocol") }
                apiProtocol = parsed
            case "--allow-local-http": allowLocalHTTP = true
            case "--include-image": includeImage = true
            case "--no-include-image": includeImage = false
            case "--no-filter-sfx": filterSFX = false
            case "--no-filter-background": filterBackground = false
            case "--no-rtl": rtl = false
            case "--filter-sfx": filterSFX = true
            case "--filter-background": filterBackground = true
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
    var configuration: RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(provider: .custom, apiProtocol: apiProtocol, baseURL: baseURL,
            model: model, credentialAccount: keyEnv, reasoningEffort: reasoningEffort, timeout: timeout,
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
        let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif"]
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
                    files = enumeration.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension.lowercased()) }
                    if let enumerationError { throw enumerationError }
                } else {
                    files = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                        .filter { extensions.contains($0.pathExtension.lowercased()) }
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
        // NSApplication services the WebKit and spelling main run loops in a CLI process.
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await execute()) }
        app.run()
    }
    static func execute() async -> Int32 {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"]!)
        let arguments = Array(CommandLine.arguments.dropFirst())
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
                let items = HostProductionLayout.layoutPayload(items: ReaderTranslationRegion.layoutItems(regions, imageSize: imageSize),
                    imageSize: imageSize, sourceRect: CGRect(origin: .zero, size: viewport), settings: settings,
                    targetLanguage: fixture["target"] as? String ?? "ko", viewport: viewport)
                let output: [String: Any] = ["items": items, "appearance": HostOverlayAppearance.value(settings: settings,
                    fonts: HostLetterFonts(root: root)), "viewport": [vw, vh], "metricsPlatform": "AppKit-CoreText"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
                return 0
            } catch { fputs("Layout fixture failed: \(error)\n", stderr); return 1 }
        }
        if arguments.first == "--render-run" {
            guard arguments.count == 2 else { fputs("Usage: --render-run RUN_DIRECTORY\n", stderr); return 2 }
            do {
                let run = URL(fileURLWithPath: arguments[1]).standardizedFileURL
                let directories = try FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                var count = 0
                for directory in directories where FileManager.default.fileExists(atPath: directory.appendingPathComponent("final.json").path) {
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    guard let payload = files.first(where: { $0.lastPathComponent.hasSuffix("-render-payload.json") }),
                        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: payload)) as? [String: Any],
                        let value = object["value"] as? [String: Any] else { continue }
                    let image = try loadImage(directory.appendingPathComponent("input.png"))
                    let dump = HostDumpContext(directory: directory, quiet: true)
                    try await HostDump.$context.withValue(dump) {
                        try await renderPayload(value, image: image, root: root, directory: directory)
                    }
                    try dump.requireComplete()
                    try HostAnalysis.publishFinal(imageDirectory: directory, runDirectory: run)
                    try HostAnalysis.generate(imageDirectory: directory, root: root)
                    count += 1; print("Recomposited: \(directory.lastPathComponent)/final.png")
                }
                guard count > 0 else { throw HostError.message("No completed render payloads found") }
                try HostAnalysis.generateRun(run, root: root)
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
        do {
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try HostResources.prepare(root: root, tier: options.tier)
        } catch { fputs("Preparation: \(error)\n", stderr); return 1 }
        print("Output: \(run.path)")
        let client = RemoteTranslationClient(transport: RecordingTransport())
        var summary: [[String: Any]] = []
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
                if next < images.count { enqueue(next); next += 1 }
            }
            summary = completed.sorted { $0.index < $1.index }.map(\.row)
        }
        do {
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: run.appendingPathComponent("summary.json"), options: .atomic)
        } catch { fputs("Summary: \(error)\n", stderr); return 1 }
        do { try HostAnalysis.generateRun(run, root: root) }
        catch { fputs("Analysis: \(error)\n", stderr); return 1 }
        let failures = summary.filter { $0["status"] as? String == "failed" }.count
        print("Finished: \(images.count - failures) succeeded, \(failures) failed. \(run.path)")
        return failures == 0 ? 0 : 1
    }
    static let renderGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    static let imageProviderGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 3)
    static let textProviderGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 8)
    static func processImage(index: Int, url: URL, count: Int, run: URL, root: URL,
                             options: HostOptions, client: RemoteTranslationClient) async -> HostPageResult {
            let directory = run.appendingPathComponent(String(format: "%04d", index + 1))
            let started = ProcessInfo.processInfo.systemUptime
            var row: [String: Any] = ["input": url.path, "directory": directory.path]
            print("[\(index + 1)/\(count)] \(url.path)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if options.resumeRun != nil, let data = try? Data(contentsOf: directory.appendingPathComponent("final.json")),
               let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard saved["input"] as? String == url.path else { throw HostError.message("Resume input order differs at \(directory.lastPathComponent)") }
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
                    try savePNG(image, to: directory.appendingPathComponent("input.png"))
                    HostDump.capture("input", ["engineFingerprint": ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unknown",
                        "file": url.path, "width": image.width, "height": image.height,
                        "configuration": HostDump.json(options.ocrConfiguration)])
                    HostDump.capture("runtime-settings", ["baseURL": options.baseURL, "model": options.model,
                        "protocol": options.apiProtocol.rawValue, "reasoningEffort": options.reasoningEffort.rawValue,
                        "timeout": options.timeout, "sourceLanguage": options.source, "targetLanguage": options.target,
                        "translationSourceLanguages": options.translationSourceLanguages, "includePageImage": options.includeImage,
                        "filterSFXWithLLM": options.filterSFX, "filterBackgroundWithLLM": options.filterBackground,
                        "rightToLeftPanelOrder": options.rtl, "jobs": options.jobs, "appearance": try options.appearance, "viewport": [options.viewport.width, options.viewport.height]])
                    var regions = try await ReaderOCRService.shared.recognize(image: image,
                        configuration: options.ocrConfiguration)
                    try drawOCR(regions, image: image, to: directory.appendingPathComponent("ocr-boxes.png"))
                    if options.rtl {
                        let ranks = ReaderTranslationPanelOrder.rightToLeftRanks(image: image, inputs: regions.map {
                            .init(rect: $0.rect, isVertical: $0.sourceOrientation == .vertical)
                        })
                        for index in regions.indices { regions[index].translationOrder = ranks[index] }
                        regions.sort { ($0.translationOrder ?? 0) < ($1.translationOrder ?? 0) }
                    }
                    HostDump.capture("ordered-regions", regions)
                    if !options.ocrOnly {
                        if let translations = options.translations {
                            for index in regions.indices {
                                guard let text = translations[regions[index].source] else {
                                    throw HostError.message("Offline translation missing for source: \(regions[index].source)")
                                }
                                regions[index].translation = text
                            }
                            HostDump.capture("offline-translations", regions)
                        } else {
                            let settings = ReaderTranslationSettings(sourceLanguage: options.source, targetLanguage: options.target,
                                translationSourceLanguages: options.translationSourceLanguages,
                                filterSFXWithLLM: options.filterSFX, filterBackgroundWithLLM: options.filterBackground,
                                rightToLeftPanelOrder: options.rtl)
                            let candidates = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
                            HostDump.capture("language-filtered-regions", candidates)
                            let eligibleIDs = Set(candidates.map(\.id))
                            regions = candidates
                            var plans = ReaderTranslationService.plans(regions: regions.filter { eligibleIDs.contains($0.id) }, settings: settings)
                            let originalIndices = Dictionary(uniqueKeysWithValues: regions.enumerated().map { ($0.element.id, $0.offset) })
                            let jpeg = options.includeImage ? try HostTranslationParity.translationJPEG(image) : nil
                            for index in plans.indices {
                                var request = plans[index].request
                                request.imageJPEG = jpeg
                                request.filtersSFX = options.filterSFX ? true : nil
                                request.filtersBackground = options.filterBackground ? true : nil
                                request.translatesPageLettering = true
                                plans[index] = .init(request: request, inputIndicesBySegmentID: plans[index].inputIndicesBySegmentID)
                            }
                            HostDump.capture("translation-batches", plans)
                            for plan in plans {
                                let providerGate = options.includeImage ? imageProviderGate : textProviderGate
                                let initialResult = try await providerGate.withPermit {
                                    try await client.translate(plan.request, configuration: options.configuration,
                                        onPartial: { dump.capture("translation-partial", $0) })
                                }
                                let result = try await HostTranslationParity.recoveringBalloonDialogue(request: plan.request,
                                    result: initialResult, regionsByID: Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })) { recovery in
                                        try await providerGate.withPermit {
                                            try await client.translate(recovery, configuration: options.configuration)
                                        }
                                    }
                                HostDump.capture("translation-result", result)
                                for segment in result.translations {
                                    if let index = originalIndices[segment.id] {
                                        regions[index].translation = ReaderTranslationLanguageFilter.removingForeignScriptTail(segment.text, target: options.target)
                                    }
                                }
                            }
                        }
                        let renderRegions = regions
                        try await renderGate.withPermit { @MainActor in
                            try await render(renderRegions, image: image, target: options.target, root: root, directory: directory, settings: try options.overlaySettings, viewport: options.viewport)
                        }
                    }
                    HostDump.capture("final-regions", regions)
                    let final = try JSONSerialization.data(withJSONObject: ["input": url.path, "width": image.width,
                        "height": image.height, "mode": options.ocrOnly ? "ocr-only" : "translation",
                        "regions": HostDump.json(regions)], options: [.prettyPrinted, .sortedKeys])
                    try final.write(to: directory.appendingPathComponent("final.json"), options: .atomic)
                    try HostAnalysis.publishFinal(imageDirectory: directory, runDirectory: run)
                    try dump.requireComplete()
                    row["regions"] = regions.count
                }
                row["status"] = "success"
            } catch {
                row["status"] = "failed"
                row["error"] = String(describing: error)
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
    static func savePNG(_ image: CGImage, to url: URL) throws { try imageData(image, type: "public.png").write(to: url, options: .atomic) }
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

@MainActor
final class HostNavigation: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(_ url: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        continuation?.resume(throwing: HostError.message("WebKit content process terminated")); continuation = nil
    }
}
extension ImageTranslationMain {
    static func render(_ regions: [ReaderTranslationRegion], image: CGImage, target: String, root: URL, directory: URL,
                       settings: IPhoneOverlaySettings, viewport: CGSize) async throws {
        let imageSize = CGSize(width: image.width, height: image.height)
        let fitted = HostRenderGeometry.displayRect(imageSize: imageSize, viewport: viewport).size
        let sourceRect = CGRect(origin: .zero, size: fitted)
        let overlayItems = ReaderTranslationRegion.layoutItems(regions, imageSize: imageSize)
        let items = HostProductionLayout.layoutPayload(items: overlayItems, imageSize: imageSize, sourceRect: sourceRect,
            settings: settings, targetLanguage: target, viewport: fitted)
        let arguments: [String: Any] = ["items": items, "revision": "1", "session": "host-pipeline",
            "appearance": HostOverlayAppearance.value(settings: settings, fonts: HostLetterFonts(root: root)),
            "hostViewport": [fitted.width, fitted.height], "hostDisplayRect": [0, 0, fitted.width, fitted.height],
            "hostLayout": "production-layout-appkit-metrics"]
        HostDump.capture("render-payload", arguments)
        try await renderPayload(arguments, image: image, root: root, directory: directory)
    }
    static func renderPayload(_ arguments: [String: Any], image: CGImage, root: URL, directory: URL) async throws {
        let savedViewport = arguments["hostViewport"] as? [Double]
        let width = savedViewport?.first ?? Double(image.width)
        let height = savedViewport?.last ?? Double(image.height)
        let displayRect = CGRect(x: 0, y: 0, width: width, height: height)
        // Inline the source so WebKit permits pixel reads in this local-file document.
        let sourceDataURL = try HostRenderGeometry.backgroundDataURL(for: image)
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;width:\(width)px;height:\(height)px;overflow:hidden;background:white}
        #reader-source-image{display:block;width:\(width)px;height:\(height)px}
        </style></head><body><img id="reader-source-image" src="\(sourceDataURL)"></body></html>
        """
        let htmlURL = directory.appendingPathComponent("final.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        HostLetterFonts(root: root).register(in: configuration, contentWorld: .page)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); webView.navigationDelegate = nil }
        let navigation = HostNavigation()
        try await navigation.load(htmlURL, in: webView)
        let waitForImage = "const im=document.getElementById('reader-source-image'); if(!im.complete) await new Promise((ok,fail)=>{im.onload=ok;im.onerror=()=>fail(new Error('source image load failed'));}); if(!im.naturalWidth) throw new Error('source image decode failed'); return true;"
        _ = try await webView.callAsyncJavaScript(waitForImage, arguments: [:], in: nil, contentWorld: .page)
        let renderStarted = ProcessInfo.processInfo.systemUptime
        let result = try await webView.callAsyncJavaScript(HostProductionRenderer.renderScript, arguments: arguments,
                                                          in: nil, contentWorld: .page)
        HostDump.capture("render-result", result as Any)
        let trace = try await webView.callAsyncJavaScript("return globalThis.__aidokuHostSegmentationTrace || {captures:[],dropped:0};", arguments: [:], in: nil, contentWorld: .page)
        try HostSegmentationTrace.save(trace, directory: directory)
        _ = try await webView.callAsyncJavaScript("await document.fonts.ready; document.body.getBoundingClientRect(); return true;",
                                                  arguments: [:], in: nil, contentWorld: .page)
        let diagnostics = try await webView.callAsyncJavaScript("""
        const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
        return {root:root?{...root.dataset}:null,nodes:[...(root?.querySelectorAll('*')||[])].map(n=>({
          tag:n.tagName,text:n.tagName==='CANVAS'?null:n.textContent,dataset:{...n.dataset},style:n.getAttribute('style'),
          bounds:{x:n.getBoundingClientRect().x,y:n.getBoundingClientRect().y,width:n.getBoundingClientRect().width,height:n.getBoundingClientRect().height}
        }))};
        """, arguments: [:], in: nil, contentWorld: .page)
        HostDump.capture("render-dom", diagnostics as Any)
        let exportJSON = try await webView.callAsyncJavaScript(HostProductionExporter.prepareExportScript,
            arguments: [:], in: nil, contentWorld: .page) as? String
        guard let exportJSON, let exportData = exportJSON.data(using: .utf8) else { throw HostError.message("Missing export layers") }
        let layers = try JSONDecoder().decode(HostProductionExporter.ExportLayers.self, from: exportData)
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = displayRect
        let typography = try await webView.pdf(configuration: pdfConfiguration)
        let outputSize = HostRenderGeometry.outputPixelSize(for: CGSize(width: image.width, height: image.height))
        let outputImage = try HostExportCompositor.composite(image: image, layers: layers, typography: typography,
            displayRect: displayRect, size: outputSize)
        try savePNG(outputImage, to: directory.appendingPathComponent("final.png"))
        HostDump.capture("render-timing", ["milliseconds": (ProcessInfo.processInfo.systemUptime - renderStarted) * 1000,
            "width": outputImage.width, "height": outputImage.height, "layout": arguments["hostLayout"] ?? "legacy-payload-replay", "viewport": [width, height], "metricsPlatform": "AppKit-CoreText"])
        // Persist a replayable self-contained render call after the image has loaded.
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), as: UTF8.self)
        let safeArguments = encoded.replacingOccurrences(of: "<", with: "\\u003c")
        let safeScript = HostProductionRenderer.renderScript.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        let replay = "<script>const replay=async()=>{const args=" + safeArguments +
            "; const render=async function({items,revision,session,appearance}){\n" + safeScript +
            "\n}; try{window.renderResult=await render(args);}catch(e){document.body.dataset.renderError=String(e);}}; const im=document.getElementById('reader-source-image'); if(im.complete&&im.naturalWidth)replay();else im.addEventListener('load',replay,{once:true});</script>"
        try html.replacingOccurrences(of: "</body>", with: replay + "</body>").write(to: htmlURL, atomically: true, encoding: .utf8)
    }
}
