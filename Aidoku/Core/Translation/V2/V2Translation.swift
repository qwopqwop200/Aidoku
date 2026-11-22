import CoreGraphics
import Foundation

// S5: one provider request per page (blocks in reading order, chunked above the 64-segment
// limit) through RemoteTranslationClient; replay fills translations from a saved run.

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
            // The page-lettering contract (page roles, one call, no retries/fallbacks) needs the image.
            if imageJPEG != nil { request.translatesPageLettering = true }
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

    /// Live translation; a missing reply leaves `translation` nil (source pixels are kept).
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
        return apply(blocks, targetLanguage: targetLanguage) { block in texts[segmentID(block)] }
    }

    static func apply(_ blocks: [V2Block], targetLanguage: String = "ko",
                      lookup: (V2Block) -> RemoteTranslatedSegment?) -> [V2Block] {
        blocks.map { block in
            var output = block
            guard let segment = lookup(block) else { return output }
            // Legacy reply repair: JSON escapes leaked as literal text (backslash-n, backslash-u + hex) are decoded.
            let text = TranslationHTTPCodec.decodingLeakedEscapes(in: segment.text, source: block.sourceText)
            // A reply that repeats lettered source text, or is still Japanese prose without any
            // Hangul (legacy wrong-language rule), keeps the source pixels.
            guard !V2TranslationLengthCap.copiesSource(text, block.sourceText), segment.isSFX == true
                    || text.unicodeScalars.contains(where: V2ReplyText.isHangul)
                    || !V2ReplyText.isUntranslatedJapaneseReply(
                        source: block.sourceText, translation: text, target: targetLanguage) else { return output }
            output.translation = V2TranslationLengthCap.capped(text, sourceText: block.sourceText)
            if segment.isSFX == true || segment.textRole == .sfx { output.role = .sfx }
            if segment.textRole == .narration || segment.textRole == .storyText { output.role = .narration }
            // A provider "error" (misread art, noise) keeps its source pixels like background text.
            if segment.textRole == .background || segment.textRole == .error { output.role = .background }
            return output
        }
    }
}

/// Legacy provider-reply text rules (ReaderTranslationLanguageFilter), for target "ko".
enum V2ReplyText {
    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9D).contains(scalar.value)
    }

    static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value) || (0x3130...0x318F).contains(scalar.value)
    }

    /// A Japanese sentence re-punctuated by the provider is not a Korean translation; exact
    /// copies (SFX/background preservation), short names and quoted terms are not rejected.
    static func isUntranslatedJapaneseReply(source: String, translation: String, target: String,
                                           preservesExactSource: Bool = true) -> Bool {
        guard target == "ko",
              (!preservesExactSource || source.trimmingCharacters(in: .whitespacesAndNewlines) !=
                translation.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        if containsCopiedJapaneseClause(source: source, translation: translation) { return true }
        let letters = translation.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard letters.count >= 20, letters.filter(isKana).count >= 2,
              source.unicodeScalars.filter(isKana).count >= 2 else { return false }
        return !letters.contains(where: isHangul)
    }

    /// A long source-matching run with hiragana grammar is a copied clause, even beside Korean.
    private static func containsCopiedJapaneseClause(source: String, translation: String) -> Bool {
        func japanese(_ scalar: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value) ||
                (0xFF66...0xFF9D).contains(scalar.value)
        }
        func normalized(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter(japanese)))
        }
        let sourceLetters = normalized(source)
        func copiedClause(_ run: String) -> Bool {
            let text = run.trimmingCharacters(in: .whitespacesAndNewlines)
            for (opening, closing) in [("「", "」"), ("『", "』"), ("\"", "\""), ("“", "”")] {
                if text.hasPrefix(opening), text.hasSuffix(closing) { return false }
            }
            let letters = normalized(text)
            let hiragana = letters.unicodeScalars.filter { (0x3041...0x3096).contains($0.value) }.count
            return letters.count >= 10 && hiragana >= 5 && sourceLetters.contains(letters)
        }
        var run = ""
        for scalar in translation.unicodeScalars {
            if japanese(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.punctuationCharacters.contains(scalar) {
                run.unicodeScalars.append(scalar)
            } else {
                if copiedClause(run) { return true }
                run = ""
            }
        }
        return copiedClause(run)
    }
}

/// Per-block bound on translation text relative to its source, so a runaway reply (the codec
/// allows 512 KiB per segment) never reaches S9/S10 or the caches; real dialogue stays far below.
enum V2TranslationLengthCap {
    /// Allowance for any block, even one with very short or empty source text.
    static let minimumCharacters = 256
    /// Translated characters allowed per source character.
    static let charactersPerSourceCharacter = 8
    /// Hard ceiling regardless of source length.
    static let maximumCharacters = 4096

    /// Maximum translation length, in Characters (grapheme clusters).
    static func limit(sourceText: String) -> Int {
        // Counting stops at the source length that reaches the ceiling.
        let ceilingSource = maximumCharacters / charactersPerSourceCharacter
        let sourceCount = sourceText.utf8.count <= ceilingSource ? sourceText.count
            : sourceText.prefix(ceilingSource).count
        return min(maximumCharacters, max(minimumCharacters, sourceCount * charactersPerSourceCharacter))
    }

    /// Whether `translation` equals `source` (ignoring whitespace) and the source has letters;
    /// punctuation-only sources ("……", "!?") still paint.
    static func copiesSource(_ translation: String, _ source: String) -> Bool {
        let a = V2TranslationReplay.normalized(translation), b = V2TranslationReplay.normalized(source)
        return !a.isEmpty && a == b && b.contains { $0.isLetter }
    }

    /// `translation` unchanged when within the limit, else its first `limit`
    /// grapheme clusters (never splitting a Character).
    static func capped(_ translation: String, sourceText: String) -> String {
        let limit = limit(sourceText: sourceText)
        // UTF-8 length bounds the Character count, so short text skips any walk.
        guard translation.utf8.count > limit else { return translation }
        let end = translation.index(translation.startIndex, offsetBy: limit, limitedBy: translation.endIndex)
        guard let end, end < translation.endIndex else { return translation }
        return String(translation[..<end])
    }
}

/// Saved legacy translations for LLM-free evaluation: `<root>/page-index.json` maps page id ->
/// {dir}, whose `final.json` has the regions and `NNN-translation-result.json` the provider roles.
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
        // The stage number in the result file name varies between runs (037-, 040-, ...).
        let resultName = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix("-translation-result.json") }.sorted().last ?? "040-translation-result.json"
        if let resultData = try? Data(contentsOf: directory.appendingPathComponent(resultName)),
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
        if entries.allSatisfy({ $0.role == "narration" || $0.role == "story_text" }) { block.role = .narration }
        if entries.allSatisfy({ $0.role == "background" || $0.role == "error" }) { block.role = .background }
        if let translation = block.translation, V2TranslationLengthCap.copiesSource(translation, block.sourceText) {
            block.translation = nil
        }
    }
}
