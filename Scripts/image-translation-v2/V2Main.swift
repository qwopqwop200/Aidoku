import CoreGraphics
@preconcurrency import CoreML
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Mac host entry for the V2 pipeline:
//   swift Scripts/image-translation.swift --pipeline v2 [options] [images...]
// Options:
//   --list FILE                JSON array of image paths or {"page_id","image_path"} objects
//   --split dev|train|test     pages of one canonical split (test: run only, never for selection)
//   --manifest FILE            split manifest (default: canonical grouped-source manifest)
//   --limit N                  first N pages after selection
//   --output DIR               output root (default ../output/image-translation-v2/run-<UUID>)
//   --jobs N                   pages in flight (default 3); models stay resident
//   --replay-translations DIR  fill S5 from a saved legacy run (page-index.json); no LLM
//   --replay-fill-unmatched    replay: give blocks with no legacy counterpart a synthetic Korean
//                              placeholder of similar length so S6-S10 exercise every block
//   --no-png                   skip final PNG encoding
// Live LLM translation is intentionally not wired in this host yet.

struct V2HostError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

struct V2HostOptions {
    var images: [(id: String, path: String)] = []
    var output: URL?
    var jobs = 3
    var replay: URL?
    var fillUnmatched = false
    var writePNG = true
    var split: String?
    var limit: Int?
}

@main
@available(macOS 15.0, *)
enum V2Main {
    static let defaultManifest = "pipeline-generalization-20261117/evaluation-audit/CANONICAL-GROUPED-SOURCE-MANIFEST.json"

    static func main() async {
        do { try await execute() } catch {
            FileHandle.standardError.write(Data("image-translation-v2: \(error)\n".utf8))
            exit(1)
        }
    }

    static func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    static func parse(_ arguments: [String], root: URL) throws -> V2HostOptions {
        var options = V2HostOptions()
        var manifest = root.deletingLastPathComponent().appendingPathComponent(defaultManifest)
        var listFile: String?
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw V2HostError("\(flag) needs a value") }
            return next
        }
        while let argument = iterator.next() {
            switch argument {
            case "--list": listFile = try value(argument)
            case "--output": options.output = URL(fileURLWithPath: try value(argument)).standardizedFileURL
            case "--jobs": options.jobs = max(1, Int(try value(argument)) ?? 3)
            case "--replay-translations": options.replay = URL(fileURLWithPath: try value(argument))
            case "--split": options.split = try value(argument)
            case "--manifest": manifest = URL(fileURLWithPath: try value(argument))
            case "--limit": options.limit = Int(try value(argument))
            case "--no-png": options.writePNG = false
            case "--replay-fill-unmatched": options.fillUnmatched = true
            default:
                guard !argument.hasPrefix("--") else { throw V2HostError("unknown option \(argument)") }
                options.images += try expand(argument)
            }
        }
        if let listFile {
            let data = try Data(contentsOf: URL(fileURLWithPath: listFile))
            for item in (try JSONSerialization.jsonObject(with: data)) as? [Any] ?? [] {
                if let path = item as? String {
                    options.images.append((pageID(for: path), path))
                } else if let object = item as? [String: Any], let path = object["image_path"] as? String {
                    options.images.append(((object["page_id"] as? String) ?? pageID(for: path), path))
                }
            }
        }
        if let split = options.split {
            guard ["dev", "train", "test"].contains(split) else { throw V2HostError("--split must be dev, train or test") }
            if split == "test" { log("WARNING: TEST split. Run once at the end; never use for fitting or selection.") }
            let data = try Data(contentsOf: manifest)
            let pages = ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["pages"] as? [[String: Any]] ?? []
            for page in pages where page["split"] as? String == split {
                if let id = page["page_id"] as? String, let path = page["image_path"] as? String {
                    options.images.append((id, path))
                }
            }
        }
        if let limit = options.limit { options.images = Array(options.images.prefix(max(0, limit))) }
        guard !options.images.isEmpty else { throw V2HostError("no input pages") }
        return options
    }

    static func pageID(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        return stem == "input" ? url.deletingLastPathComponent().lastPathComponent : stem
    }

    static func expand(_ path: String) throws -> [(id: String, path: String)] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw V2HostError("missing input \(path)")
        }
        guard isDirectory.boolValue else { return [(pageID(for: path), path)] }
        let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        return names.filter { ["png", "jpg", "jpeg", "webp"].contains(($0 as NSString).pathExtension.lowercased()) }
            .map { name in
                let full = (path as NSString).appendingPathComponent(name)
                return (pageID(for: full), full)
            }
    }

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

    struct PageRecord: Codable {
        var pageID: String
        var image: String
        var width: Int
        var height: Int
        var blocks: [V2Block]
        var placed: [V2PlacedText]
        var timings: [String: Double]
        var failure: String?
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

    static func execute() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["AIDOKU_PIPELINE_ROOT"] else { throw V2HostError("AIDOKU_PIPELINE_ROOT not set") }
        let root = URL(fileURLWithPath: rootPath)
        let cache = URL(fileURLWithPath: environment["AIDOKU_V2_CACHE"] ?? root.appendingPathComponent("build/image-translation-v2").path)
        let options = try parse(Array(CommandLine.arguments.dropFirst()), root: root)
        let output = options.output ?? root.deletingLastPathComponent()
            .appendingPathComponent("output/image-translation-v2/run-\(UUID().uuidString)")
        let pagesDirectory = output.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
        V2Layout.registerFont(at: root.appendingPathComponent("Aidoku/Resources/Translation/\(V2Layout.fontName).woff2"))

        let loadStart = DispatchTime.now().uptimeNanoseconds
        let bundle = try prepareBundle(root: root, cache: cache)
        let models = try V2Models.load(bundle: bundle)
        try await models.warmUp()
        let loadMilliseconds = V2Pipeline.milliseconds(since: loadStart)
        log("Models resident in \(Int(loadMilliseconds)) ms; \(options.images.count) page(s), jobs \(options.jobs)")

        let replay = try options.replay.map { try V2TranslationReplay(root: $0) }
        let fillUnmatched = options.fillUnmatched
        let translator: V2Translator = { page, blocks in
            guard let replay else { return blocks }
            let matched = V2TranslationReplay.apply(replay.entries(pageID: page.id) ?? [], to: blocks)
            guard fillUnmatched else { return matched }
            return matched.map { block in
                guard block.translation == nil, block.role != .background else { return block }
                var output = block
                let syllables = Array("가나다라마바사아자차카타파하")
                let count = max(1, Int((Double(block.sourceText.count) * 0.8).rounded()))
                output.translation = String((0..<count).map { syllables[$0 % syllables.count] })
                return output
            }
        }
        if replay == nil { log("No --replay-translations: S5 leaves translations empty (no LLM in this host).") }

        let runStart = DispatchTime.now().uptimeNanoseconds
        var records: [PageRecord] = []
        let writer = V2SerialExecutor(label: "Aidoku.V2.Writer")
        try await withThrowingTaskGroup(of: PageRecord.self) { group in
            var next = 0
            func submit() {
                guard next < options.images.count else { return }
                let item = options.images[next]
                next += 1
                group.addTask {
                    let image: CGImage
                    do { image = try loadImage(item.path) } catch {
                        return PageRecord(pageID: item.id, image: item.path, width: 0, height: 0, blocks: [], placed: [],
                                          timings: [:], failure: "load: \(error)")
                    }
                    let page = V2Page(id: item.id, image: image)
                    let result = await V2Pipeline.run(page, models: models, translate: translator)
                    let entries = replay?.entries(pageID: item.id)
                    var record = PageRecord(pageID: item.id, image: item.path, width: page.width, height: page.height,
                        blocks: result.blocks, placed: result.placed, timings: result.timings.stages,
                        failure: result.failure,
                        replayAvailable: replay == nil ? nil : entries != nil)
                    if let entries {
                        let cleared = result.blocks.map { block -> V2Block in var b = block; b.translation = nil; return b }
                        let legacy = V2TranslationReplay.match(entries, to: cleared)
                        let legacyIDs = Set(legacy.blocks.filter { $0.translation != nil }.map(\.id))
                        record.replayMatched = legacyIDs.count
                        record.replayLegacyRegions = entries.count
                        record.replayLegacyRegionsUsed = legacy.used.count
                        record.replaySyntheticBlocks = result.blocks.filter { $0.translation != nil && !legacyIDs.contains($0.id) }
                            .map(\.id)
                    }
                    // Encoding/writing stays off the per-page critical path measured above.
                    let encodesPNG = options.writePNG
                    let finalImage = result.output
                    let pageRecord = record
                    let written = try await writer.run { () -> Double in
                        let start = DispatchTime.now().uptimeNanoseconds
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        try encoder.encode(pageRecord).write(to: pagesDirectory.appendingPathComponent(item.id + ".json"))
                        if encodesPNG, let finalImage {
                            try writePNG(finalImage, to: pagesDirectory.appendingPathComponent(item.id + ".png"))
                        }
                        return V2Pipeline.milliseconds(since: start)
                    }
                    record.writeMilliseconds = written
                    return record
                }
            }
            for _ in 0..<options.jobs { submit() }
            while let record = try await group.next() {
                records.append(record)
                let total = record.timings[V2Pipeline.Stage.nonLLM] ?? 0
                log("[\(records.count)/\(options.images.count)] \(record.pageID) blocks \(record.blocks.count) "
                    + "non-LLM \(Int(total)) ms" + (record.failure.map { " FAIL \($0)" } ?? ""))
                submit()
            }
        }
        let wall = V2Pipeline.milliseconds(since: runStart)

        var stages: [String: [String: Double]] = [:]
        let names = Set(records.flatMap { $0.timings.keys })
        for name in names.sorted() {
            let values = records.compactMap { $0.timings[name] }
            stages[name] = ["median": percentile(values, 0.5), "p90": percentile(values, 0.9),
                            "mean": values.reduce(0, +) / Double(max(1, values.count)), "count": Double(values.count)]
        }
        let summary: [String: Any] = [
            "schema": "aidoku-v2-run-summary-v1",
            "pages": records.count,
            "failedPages": records.filter { $0.failure != nil }.map(\.pageID),
            "jobs": options.jobs,
            "split": options.split as Any? ?? NSNull(),
            "replay": options.replay?.path as Any? ?? NSNull(),
            "modelLoadMilliseconds": loadMilliseconds,
            "modelLoadByModel": models.loadMilliseconds,
            "runWallMilliseconds": wall,
            "throughputPagesPerSecond": Double(records.count) / max(wall / 1000, 0.001),
            "stageMilliseconds": stages,
            "stubs": V2HostStubs.active,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("summary.json"))
        let nonLLM = stages[V2Pipeline.Stage.nonLLM] ?? [:]
        log("Done: \(records.count) pages in \(Int(wall)) ms wall; non-LLM median \(Int(nonLLM["median"] ?? 0)) ms, "
            + "p90 \(Int(nonLLM["p90"] ?? 0)) ms")
        print(output.path)
    }
}
