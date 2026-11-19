import CoreGraphics
import Foundation

// S5: page translation.
//
// Live mode sends ONE request per page (all dialogue blocks in reading order,
// chunked only above the provider's 64-segment limit) through the legacy
// RemoteTranslationClient / TranslationHTTPCodec with a caller-injected
// transport. Replay mode fills translations from a saved legacy run so the
// pipeline can be evaluated end to end without any LLM call.

@available(iOS 18.0, macOS 15.0, *)
enum V2Translation {
    static func segmentID(_ block: V2Block) -> String { "v2-block-\(block.id)" }

    /// Blocks sent to the provider: non-empty source and not background text.
    static func translatable(_ blocks: [V2Block]) -> [V2Block] {
        blocks.filter { $0.role != .background && !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.readingOrder < $1.readingOrder }
    }

    static func requests(for blocks: [V2Block], pageSize: CGSize, sourceLanguage: String, targetLanguage: String,
                         imageJPEG: Data?) -> [RemoteTranslationRequest] {
        let segments = translatable(blocks).map { block in
            RemoteTranslationSegment(id: segmentID(block), text: block.sourceText,
                bounds: normalizedBounds(block.bounds, pageSize: pageSize))
        }
        return stride(from: 0, to: segments.count, by: RemoteTranslationRequest.maximumSegments).map { start in
            var request = RemoteTranslationRequest(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                segments: Array(segments[start..<min(segments.count, start + RemoteTranslationRequest.maximumSegments)]))
            request.imageJPEG = imageJPEG
            request.filtersSFX = true
            request.filtersBackground = true
            return request
        }
    }

    static func normalizedBounds(_ rect: CGRect, pageSize: CGSize) -> [Double] {
        guard pageSize.width > 0, pageSize.height > 0 else { return [0, 0, 0, 0] }
        let page = CGRect(origin: .zero, size: pageSize)
        let r = rect.intersection(page).isNull ? .zero : rect.intersection(page)
        return [Double(r.minX / pageSize.width), Double(r.minY / pageSize.height),
                Double(r.width / pageSize.width), Double(r.height / pageSize.height)]
    }

    /// Live translation. A provider failure leaves `translation` nil (the
    /// block keeps its source pixels downstream); the page is never dropped.
    static func translate(_ blocks: [V2Block], pageSize: CGSize, client: any RemoteTranslating,
                          configuration: RemoteTranslationConfiguration, sourceLanguage: String = "ja",
                          targetLanguage: String = "ko", imageJPEG: Data? = nil) async throws -> [V2Block] {
        var texts: [String: RemoteTranslatedSegment] = [:]
        try await withThrowingTaskGroup(of: [RemoteTranslatedSegment].self) { group in
            for request in requests(for: blocks, pageSize: pageSize, sourceLanguage: sourceLanguage,
                                    targetLanguage: targetLanguage, imageJPEG: imageJPEG) {
                group.addTask { try await client.translate(request, configuration: configuration).translations }
            }
            for try await result in group { for segment in result { texts[segment.id] = segment } }
        }
        return apply(blocks) { block in texts[segmentID(block)] }
    }

    static func apply(_ blocks: [V2Block], lookup: (V2Block) -> RemoteTranslatedSegment?) -> [V2Block] {
        blocks.map { block in
            var output = block
            guard let segment = lookup(block) else { return output }
            output.translation = segment.text
            if segment.isSFX == true || segment.textRole == .sfx { output.role = .sfx }
            if segment.textRole == .background { output.role = .background }
            return output
        }
    }
}

/// Saved legacy translations for LLM-free evaluation.
///
/// Layout: `<root>/page-index.json` maps page id -> {dir}. Each page dir has
/// `final.json` (regions with `source`, normalized `rect`, `translation`) and
/// `040-translation-result.json` (provider roles by region id).
struct V2TranslationReplay: Sendable {
    struct Entry: Sendable, Codable, Equatable {
        var id: String
        var source: String
        var rect: CGRect
        var translation: String?
        var role: String?
    }

    /// Page id -> legacy page directory, from `<root>/page-index.json`.
    let directories: [String: URL]

    init(root: URL) throws {
        let data = try Data(contentsOf: root.appendingPathComponent("page-index.json"))
        let index = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        directories = index.compactMapValues { record in
            ((record as? [String: Any])?["dir"] as? String).map { URL(fileURLWithPath: $0) }
        }
    }

    /// Entries in page pixels for one page, or nil when the page was not saved.
    func entries(pageID: String) -> [Entry]? {
        directories[pageID].flatMap(Self.load(directory:))
    }

    static func load(directory: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("final.json")),
              let final = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let regions = final["regions"] as? [[String: Any]] else { return nil }
        let width = (final["width"] as? Double) ?? 1, height = (final["height"] as? Double) ?? 1
        var roles: [String: String] = [:]
        if let resultData = try? Data(contentsOf: directory.appendingPathComponent("040-translation-result.json")),
           let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any],
           let value = result["value"] as? [String: Any], let items = value["translations"] as? [[String: Any]] {
            for item in items {
                if let id = item["id"] as? String, let role = item["textRole"] as? String { roles[id] = role }
            }
        }
        return regions.compactMap { region in
            guard let rect = region["rect"] as? [String: Double], let source = region["source"] as? String else { return nil }
            let id = region["id"] as? String ?? ""
            let frame = CGRect(x: (rect["x"] ?? 0) * width, y: (rect["y"] ?? 0) * height,
                               width: (rect["width"] ?? 0) * width, height: (rect["height"] ?? 0) * height)
            return Entry(id: id, source: source, rect: frame, translation: region["translation"] as? String, role: roles[id])
        }
    }

    static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// Fills translations, each legacy region used at most once:
    /// 1. exact normalized source text;
    /// 2. legacy regions lying mostly (>= 50%) inside the block's line union, joined in legacy order;
    /// 3. a block lying mostly (>= 60%) inside one unused legacy region (V2 split a legacy unit:
    ///    the translation goes to the block with the largest overlap);
    /// 4. source-text similarity >= 0.5 (character LCS ratio) with a nearby unused region.
    /// Unmatched blocks keep `translation == nil`.
    static func apply(_ entries: [Entry], to blocks: [V2Block]) -> [V2Block] {
        match(entries, to: blocks).blocks
    }

    /// `apply` plus the indices of the legacy entries that were used.
    static func match(_ entries: [Entry], to blocks: [V2Block]) -> (blocks: [V2Block], used: Set<Int>) {
        var used = Set<Int>()
        var output = blocks
        var byText: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() { byText[normalized(entry.source), default: []].append(index) }
        for i in output.indices {
            let key = normalized(output[i].sourceText)
            guard !key.isEmpty, let match = byText[key]?.first(where: { !used.contains($0) }) else { continue }
            used.insert(match)
            fill(&output[i], with: [entries[match]])
        }
        let areas = output.map(lineUnion)
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat { area(a.intersection(b)) }
        for i in output.indices where output[i].translation == nil {
            let matches = entries.indices.filter { index in
                !used.contains(index) && area(entries[index].rect) > 0
                    && overlap(entries[index].rect, areas[i]) >= 0.5 * area(entries[index].rect)
            }
            guard !matches.isEmpty else { continue }
            used.formUnion(matches)
            fill(&output[i], with: matches.map { entries[$0] })
        }
        for index in entries.indices where !used.contains(index) {
            let rect = entries[index].rect
            let candidates = output.indices.filter { i in
                output[i].translation == nil && area(areas[i]) > 0 && overlap(rect, areas[i]) >= 0.6 * area(areas[i])
            }
            guard let best = candidates.max(by: { overlap(rect, areas[$0]) < overlap(rect, areas[$1]) }) else { continue }
            used.insert(index)
            fill(&output[best], with: [entries[index]])
        }
        for i in output.indices where output[i].translation == nil {
            let source = normalized(output[i].sourceText)
            guard !source.isEmpty else { continue }
            let reach = max(areas[i].width, areas[i].height) * 2
            let scored = entries.indices.filter { !used.contains($0) }.compactMap { index -> (Int, Double)? in
                let r = entries[index].rect
                guard hypot(r.midX - areas[i].midX, r.midY - areas[i].midY) <= reach + max(r.width, r.height) else { return nil }
                return (index, similarity(source, normalized(entries[index].source)))
            }
            guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.5 else { continue }
            used.insert(best.0)
            fill(&output[i], with: [entries[best.0]])
        }
        return (output, used)
    }

    static func lineUnion(_ block: V2Block) -> CGRect {
        let union = block.lines.reduce(CGRect.null) { $0.union($1.bounds) }
        return union.isNull ? block.bounds : union
    }

    /// 2 * LCS / (|a| + |b|) over characters.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            previous = current
        }
        return 2 * Double(previous[y.count]) / Double(x.count + y.count)
    }

    private static func fill(_ block: inout V2Block, with entries: [Entry]) {
        let texts = entries.compactMap(\.translation).filter { !$0.isEmpty }
        if !texts.isEmpty { block.translation = texts.joined(separator: " ") }
        if entries.allSatisfy({ $0.role == "sfx" }) { block.role = .sfx }
        if entries.allSatisfy({ $0.role == "background" }) { block.role = .background }
    }
}
