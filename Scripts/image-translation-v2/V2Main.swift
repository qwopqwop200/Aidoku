import CoreGraphics
@preconcurrency import CoreML
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Mac host entry for the V2 page-translation pipeline (Docs/translation-v2.md):
//   swift Scripts/image-translation.swift [options] <image|folder ...> [--list FILE]
// Options and settings: Scripts/image-translation/help.txt and V2HostSettings.swift.
// Modes: live (default; real provider through V2Translation), --replay-translations
// (saved translations, no provider call) and --ocr-only (S1-S4, no LLM/render).

/// Bounds concurrent provider calls (the app's shared limiter caps page calls at three).
actor V2ProviderGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { available = max(1, count) }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }

    func with<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}

/// Saved translations for `--replay-translations`: a legacy run (`page-index.json`) or a V2 run (`pages/*.json`).
struct V2HostReplay: Sendable {
    private let legacy: V2TranslationReplay?
    private let pages: URL?

    init(root: URL) throws {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("page-index.json").path) {
            legacy = try V2TranslationReplay(root: root)
            pages = nil
        } else if FileManager.default.fileExists(atPath: root.appendingPathComponent("pages").path) {
            legacy = nil
            pages = root.appendingPathComponent("pages")
        } else {
            throw V2HostError("--replay-translations needs a saved run with page-index.json or pages/")
        }
    }

    /// Saved regions in page pixels, or nil when the page was not saved.
    func entries(pageID: String) -> [V2TranslationReplay.Entry]? {
        if let legacy { return legacy.entries(pageID: pageID) }
        guard let pages, let data = try? Data(contentsOf: pages.appendingPathComponent(pageID + ".json")),
              let record = try? JSONDecoder().decode(V2Main.PageRecord.self, from: data) else { return nil }
        return record.blocks.map { block in
            V2TranslationReplay.Entry(id: String(block.id), source: block.sourceText, rect: block.bounds,
                                      translation: block.translation, role: block.role.rawValue)
        }
    }
}

@main
@available(macOS 15.0, *)
enum V2Main {
    static func main() async {
        do { exit(try await execute()) } catch {
            FileHandle.standardError.write(Data("image-translation: \(error)\n".utf8))
            exit(2)
        }
    }

    static func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    /// Compiles the V2 model set into a private bundle (cached by package path/size/mtime).
    static func prepareBundle(root: URL, cache: URL) throws -> Bundle {
        let bundle = cache.appendingPathComponent("Models.bundle")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "app.aidoku.ImageTranslationV2Models", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let source = root.appendingPathComponent("Aidoku/Resources/Translation")
        for name in [V2Models.detectorResourceName, V2RecognitionEngine.modelResourceName,
                     V2RFDETRModel.resourceName, V2AOTModel.resourceName] {
            let package = source.appendingPathComponent(name + ".mlpackage")
            let destination = resources.appendingPathComponent(name + ".mlmodelc")
            guard let enumerator = FileManager.default.enumerator(at: package,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                throw V2HostError("model package not found: \(package.path)")
            }
            var entries: [String] = []
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                entries.append(file.path.replacingOccurrences(of: package.path, with: "")
                    + ":\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
            let signature = entries.sorted().joined(separator: "\n")
            let stamp = resources.appendingPathComponent(name + ".stamp")
            if (try? String(contentsOf: stamp, encoding: .utf8)) != signature
                || !FileManager.default.fileExists(atPath: destination.path) {
                log("Compiling Core ML model \(name)...")
                let compiled = try MLModel.compileModel(at: package)
                defer { try? FileManager.default.removeItem(at: compiled) }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: compiled, to: destination)
                try signature.write(to: stamp, atomically: true, encoding: .utf8)
            }
        }
        for file in [V2RecognitionEngine.dictionaryResourceName + ".txt", V2RecognitionEngine.languageModelResourceName + ".bin"] {
            let target = resources.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: source.appendingPathComponent(file), to: target)
            }
        }
        guard let loaded = Bundle(path: bundle.path) else { throw V2HostError("cannot open model bundle") }
        return loaded
    }

    static func loadImage(_ path: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw V2HostError("cannot decode \(path)") }
        return image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw V2HostError("cannot write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw V2HostError("cannot write \(url.path)") }
    }

    /// The page JPEG sent with the provider request; same policy as the app's
    /// `ReaderTranslationImagePreparation.translationJPEG` (long side <= 2048, white matte, q 0.85, <= 4 MiB).
    static func translationJPEG(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0 else { throw RemoteTranslationError.invalidRequest("The page image is empty.") }
        let ratio = min(1, 2048 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let normalized = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        CGImageDestinationAddImage(destination, normalized, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 4 * 1024 * 1024 else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        return data as Data
    }

    struct PageRecord: Codable {
        var pageID: String
        var image: String
        var mode: String?
        var width: Int
        var height: Int
        var blocks: [V2Block]
        var placed: [V2PlacedText]
        var timings: [String: Double]
        var failure: String?
        var translatedBlocks: Int?
        var replayMatched: Int?
        var replayAvailable: Bool?
        var replayLegacyRegions: Int?
        var replayLegacyRegionsUsed: Int?
        var replaySyntheticBlocks: [Int]?
        var writeMilliseconds: Double?
    }

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = q * Double(sorted.count - 1)
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    static func syntheticTranslation(_ block: V2Block) -> String {
        let syllables = Array("가나다라마바사아자차카타파하")
        let count = max(1, Int((Double(block.sourceText.count) * 0.8).rounded()))
        return String((0..<count).map { syllables[$0 % syllables.count] })
    }

    /// Returns the process exit status: 0 when every page finished without a failure, 1 otherwise.
    static func execute() async throws -> Int32 {
        let shell = ProcessInfo.processInfo.environment
        guard let rootPath = shell["AIDOKU_PIPELINE_ROOT"] else { throw V2HostError("AIDOKU_PIPELINE_ROOT not set") }
        let root = URL(fileURLWithPath: rootPath)
        let environment = try V2DotEnv.merged(root: root, environment: shell)
        let settings = try V2HostSettings.parse(Array(CommandLine.arguments.dropFirst()), environment: environment, root: root)
        if settings.printSettings {
            let data = try JSONSerialization.data(withJSONObject: settings.describe(), options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        }
        let mode = settings.mode
        let cache = URL(fileURLWithPath: shell["AIDOKU_V2_CACHE"] ?? root.appendingPathComponent("build/image-translation-v2").path)
        let output = settings.output ?? root.deletingLastPathComponent()
            .appendingPathComponent("output/image-translation/run-\(UUID().uuidString)")
        let pagesDirectory = output.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
        V2Layout.registerFont(at: root.appendingPathComponent("Aidoku/Resources/Translation/\(V2Layout.fontName).woff2"))
        let replay = try settings.replay.map { try V2HostReplay(root: $0) }
        let direction = V2ReadingDirection(rawValue: settings.readingDirection) ?? .rightToLeft

        let loadStart = DispatchTime.now().uptimeNanoseconds
        let bundle = try prepareBundle(root: root, cache: cache)
        // AIDOKU_V2_DETECTORS / AIDOKU_V2_INPAINTERS override the resident pool sizes (default 2/2).
        let pool = { (name: String) in max(1, Int(shell[name] ?? "") ?? 2) }
        let models = try V2Models.load(bundle: bundle, detectorInstances: pool("AIDOKU_V2_DETECTORS"),
                                       inpainterInstances: pool("AIDOKU_V2_INPAINTERS"))
        try await models.warmUp()
        let loadMilliseconds = V2Pipeline.milliseconds(since: loadStart)
        log("Models resident in \(Int(loadMilliseconds)) ms; \(settings.images.count) page(s), jobs \(settings.jobs), mode \(mode.rawValue)")

        let client = RemoteTranslationClient(credentialStore: settings.credentialStore)
        let configuration = settings.configuration
        let gate = V2ProviderGate(settings.providerConcurrency)
        let sourceLanguage = settings.sourceLanguage, targetLanguage = settings.targetLanguage
        let fillUnmatched = settings.fillUnmatched
        let delay = settings.translateDelay
        let writePNGs = settings.writePNG && mode != .ocrOnly

        /// S5 for one page. `jpeg` is encoded concurrently with S1-S4 (live mode only).
        func translator(for jpeg: Task<Data, Error>?) -> V2Translator {
            { page, blocks in
                switch mode {
                case .ocrOnly:
                    return blocks
                case .replay:
                    if delay > 0 { try await Task.sleep(nanoseconds: delay * 1_000_000) }
                    let matched = V2TranslationReplay.apply(replay?.entries(pageID: page.id) ?? [], to: blocks)
                    guard fillUnmatched else { return matched }
                    return matched.map { block in
                        guard block.translation == nil, block.role != .background else { return block }
                        var output = block
                        output.translation = syntheticTranslation(block)
                        return output
                    }
                case .live:
                    guard !V2Translation.translatable(blocks).isEmpty else { return blocks }
                    let image = try await jpeg?.value
                    return try await gate.with {
                        try await V2Translation.translate(blocks, pageSize: CGSize(width: page.width, height: page.height),
                            client: client, configuration: configuration, sourceLanguage: sourceLanguage,
                            targetLanguage: targetLanguage, imageJPEG: image)
                    }
                }
            }
        }
        // OCR-only: S6/S7 never speculate and nothing becomes paintable, so no erase/inpaint/render runs.
        let hooks = mode == .ocrOnly ? V2PipelineHooks(predictTranslated: { _ in [] }) : V2PipelineHooks()

        let runStart = DispatchTime.now().uptimeNanoseconds
        var records = [PageRecord?](repeating: nil, count: settings.images.count)
        var completed = 0
        // PNG/JSON writes run on their own executors, so a finished page frees its slot at once.
        let writers = V2InstancePool((0..<settings.writers).map { V2SerialExecutor(label: "Aidoku.V2.Writer\($0)") })
        var writes: [(Int, Task<Double, Error>)] = []
        try await withThrowingTaskGroup(of: (Int, PageRecord, CGImage?).self) { group in
            var next = 0
            func submit() {
                guard next < settings.images.count else { return }
                let index = next
                let item = settings.images[index]
                next += 1
                group.addTask {
                    let image: CGImage
                    do { image = try loadImage(item.path) } catch {
                        return (index, PageRecord(pageID: item.id, image: item.path, mode: mode.rawValue, width: 0, height: 0,
                                                  blocks: [], placed: [], timings: [:], failure: "load: \(error)"), nil)
                    }
                    let jpeg: Task<Data, Error>? = mode == .live ? Task.detached(priority: .userInitiated) {
                        try translationJPEG(image)
                    } : nil
                    defer { jpeg?.cancel() }
                    let page = V2Page(id: item.id, image: image, readingDirection: direction)
                    let result = await V2Pipeline.run(page, models: models, translate: translator(for: jpeg), hooks: hooks)
                    var record = PageRecord(pageID: item.id, image: item.path, mode: mode.rawValue,
                        width: page.width, height: page.height, blocks: result.blocks, placed: result.placed,
                        timings: result.timings.stages, failure: result.failure,
                        translatedBlocks: result.blocks.filter { $0.translation != nil }.count)
                    if mode == .ocrOnly { record.translatedBlocks = nil }
                    if mode == .replay {
                        let entries = replay?.entries(pageID: item.id)
                        record.replayAvailable = entries != nil
                        if let entries {
                            let cleared = result.blocks.map { block -> V2Block in var b = block; b.translation = nil; return b }
                            let saved = V2TranslationReplay.match(entries, to: cleared)
                            let savedIDs = Set(saved.blocks.filter { $0.translation != nil }.map(\.id))
                            record.replayMatched = savedIDs.count
                            record.replayLegacyRegions = entries.count
                            record.replayLegacyRegionsUsed = saved.used.count
                            record.replaySyntheticBlocks = result.blocks
                                .filter { $0.translation != nil && !savedIDs.contains($0.id) }.map(\.id)
                        }
                    }
                    return (index, record, mode == .ocrOnly ? nil : result.output)
                }
            }
            for _ in 0..<settings.jobs { submit() }
            while let (index, record, finalImage) = try await group.next() {
                records[index] = record
                completed += 1
                let encodesPNG = writePNGs && record.failure?.hasPrefix("load:") != true
                writes.append((index, Task.detached(priority: .utility) {
                    try await writers.with { writer in
                        try await writer.run { () -> Double in
                            let start = DispatchTime.now().uptimeNanoseconds
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.sortedKeys]
                            try encoder.encode(record).write(to: pagesDirectory.appendingPathComponent(record.pageID + ".json"))
                            if encodesPNG, let finalImage {
                                try writePNG(finalImage, to: pagesDirectory.appendingPathComponent(record.pageID + ".png"))
                            }
                            return V2Pipeline.milliseconds(since: start)
                        }
                    }
                }))
                let total = record.timings[V2Pipeline.Stage.nonLLM] ?? 0
                log("[\(completed)/\(settings.images.count)] \(record.pageID) blocks \(record.blocks.count) "
                    + "non-LLM \(Int(total)) ms" + (record.failure.map { " FAIL \($0)" } ?? ""))
                submit()
            }
        }
        let pagesWall = V2Pipeline.milliseconds(since: runStart)
        var writeMilliseconds: [Double] = []
        for (index, write) in writes {
            let elapsed = try await write.value
            records[index]?.writeMilliseconds = elapsed
            writeMilliseconds.append(elapsed)
        }
        let wall = V2Pipeline.milliseconds(since: runStart)
        let finished = records.compactMap { $0 }

        var stages: [String: [String: Double]] = [:]
        for name in Set(finished.flatMap { $0.timings.keys }).sorted() {
            let values = finished.compactMap { $0.timings[name] }
            stages[name] = ["median": percentile(values, 0.5), "p90": percentile(values, 0.9),
                            "mean": values.reduce(0, +) / Double(max(1, values.count)), "count": Double(values.count)]
        }
        let pageResults: [[String: Any]] = finished.map { record in
            var row: [String: Any] = ["pageID": record.pageID, "image": record.image, "json": "pages/\(record.pageID).json",
                                      "blocks": record.blocks.count, "status": record.failure == nil ? "success" : "failed"]
            if let failure = record.failure { row["failure"] = failure }
            if let translated = record.translatedBlocks { row["translatedBlocks"] = translated }
            if FileManager.default.fileExists(atPath: pagesDirectory.appendingPathComponent(record.pageID + ".png").path) {
                row["png"] = "pages/\(record.pageID).png"
            }
            return row
        }
        let failed = finished.filter { $0.failure != nil }.map(\.pageID)
        var summary: [String: Any] = [
            "schema": "aidoku-v2-run-summary-v2",
            "mode": mode.rawValue,
            "pages": finished.count,
            "pageResults": pageResults,
            "failedPages": failed,
            "jobs": settings.jobs,
            "readingDirection": settings.readingDirection,
            "sourceLanguage": sourceLanguage,
            "targetLanguage": targetLanguage,
            "split": settings.split as Any? ?? NSNull(),
            "replay": settings.replay?.path as Any? ?? NSNull(),
            "modelLoadMilliseconds": loadMilliseconds,
            "modelLoadByModel": models.loadMilliseconds,
            "runWallMilliseconds": wall,
            "pagesWallMilliseconds": pagesWall,
            "writeMilliseconds": ["median": percentile(writeMilliseconds, 0.5), "p90": percentile(writeMilliseconds, 0.9)],
            "throughputPagesPerSecond": Double(finished.count) / max(wall / 1000, 0.001),
            "stageMilliseconds": stages,
        ]
        if mode == .live { summary["provider"] = settings.describe()["provider"] }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("summary.json"))
        let nonLLM = stages[V2Pipeline.Stage.nonLLM] ?? [:]
        log("Done: \(finished.count) pages (\(failed.count) failed) in \(Int(wall)) ms wall; non-LLM median "
            + "\(Int(nonLLM["median"] ?? 0)) ms, p90 \(Int(nonLLM["p90"] ?? 0)) ms")
        print(output.path)
        return failed.isEmpty ? 0 : 1
    }
}
