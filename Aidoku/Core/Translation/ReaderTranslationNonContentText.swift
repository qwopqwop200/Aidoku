import CoreGraphics
import Foundation
import NaturalLanguage

/// Non-content lettering that stays exactly as printed: watermarks and notices a reader
/// should not see translated ("SAMPLE", "無断転載禁止", "Do Not Repost", @handles, URLs,
/// short copyright lines). Replacing them would only add plates over the artwork.
/// The Japanese notice words extend the OCR recovery lexicon
/// (`NativeOCRAdjacentLineRecovery.isNotice`) but require a notice phrase, not a single
/// word such as 禁止, so dialogue ("ウソつくの禁止") and signs ("立入禁止") still translate.
enum ReaderTranslationNonContentText {
    /// A watermark, anti-reupload notice, handle/URL line or short copyright line.
    static func isNotice(_ source: String) -> Bool {
        let text = normalized(source)
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return false }
        let latin = String(compact.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) })
        let tokens = words(text)
        if compact.hasPrefix("©") || compact.lowercased().hasPrefix("(c)") || latin.hasPrefix("copyright")
            || latin.contains("allrightsreserved") {
            return compact.count <= 16 || latin.hasPrefix("copyright") || latin.contains("allrightsreserved")
        }
        // 禁 / 止 on the same line negate like "No" ("止AI TRANING" = the end of 学習禁止 + "NO AI TRANING").
        let prohibited = compact.contains("禁") || compact.contains("止")
        if isSampleWatermark(compact, tokens) || isHandleOrURL(text) || isLatinNotice(latin, tokens, prohibited: prohibited) {
            return true
        }
        let rest = replacing(japaneseVocabulary, in: compact, with: "")
        if isGarbledNoticeLine(compact, rest) { return true }
        guard matches(japaneseTrigger, compact) else { return false }
        // A notice line may carry a few other characters (OCR noise, a signature), not a sentence.
        return rest.unicodeScalars.filter(isCJK).count <= 4
    }

    /// Two different notice words and at most two other kanji, no kana ("A学習自作共言" = AI学習・自作発言):
    /// an OCR-garbled notice line that misses the phrase trigger. Sentences always carry kana.
    private static func isGarbledNoticeLine(_ compact: String, _ rest: String) -> Bool {
        guard compact.count <= 12 else { return false }
        let words = strongNoticeWords.filter { compact.contains($0) }
        guard Set(words.map { $0 == "転载" ? "転載" : $0 == "学习" ? "学習" : $0 }).count >= 2 else { return false }
        let others = rest.unicodeScalars.filter(isCJK)
        return others.count <= 2 && !others.contains { 0x3040...0x30FF ~= $0.value }
    }

    /// Only notice glyphs (無断転載禁止, AI学習, 複製・加工, 自作発言), at most six: a piece of a Japanese notice
    /// line that OCR garbled or cut ("学断工", "载", "止", "載禁止"). Such pieces are also dialogue words
    /// (断言, 禁止) or misread SFX (載, 加), so they are kept only inside or against a notice of their size.
    static func isNoticeGlyphFragment(_ source: String) -> Bool {
        let compact = normalized(source).filter { !$0.isWhitespace && !"・·/、。".contains($0) }
        guard !compact.isEmpty, compact.count <= 6 else { return false }
        return compact.allSatisfy(noticeGlyphs.contains)
    }

    /// Only notice vocabulary ("禁止", "Do not", "Repost is"): a piece of a tiled or split notice.
    /// It is kept only next to a whole notice on the same page (see `keepsOriginalLettering`).
    static func isNoticeFragment(_ source: String) -> Bool {
        let text = normalized(source)
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.count <= 24,
              !replacing(japaneseVocabulary, in: compact, with: "").unicodeScalars.contains(where: isCJK)
        else { return false }
        // A tiled or cropped line is cut at both ends: the first word may be the end of a vocabulary word
        // ("oduction"; six letters, so UI words such as "Load" or "works" are not pieces of "reupload").
        let known = words(text).enumerated().allSatisfy { index, word in
            fragmentVocabulary.contains {
                $0 == word || (word.count >= 3 && $0.hasPrefix(word)) || (index == 0 && word.count >= 6 && $0.hasSuffix(word))
            }
        }
        return known && compact.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Notice regions, plus vocabulary-only fragments within two line thicknesses of one,
    /// misread pieces of a tiled SAMPLE watermark on a page that has an exact one, and
    /// decorative pattern lettering along a page edge (see `decorativePatterns`).
    static func notices(in regions: [ReaderTranslationRegion]) -> [Bool] {
        var result = regions.map { isNotice($0.source) }
        let anchors = result.indices.filter { result[$0] }
        if !anchors.isEmpty {
            for index in regions.indices where !result[index] {
                let source = regions[index].source
                let rect = regions[index].rect
                let pad = 2 * min(rect.width, rect.height)
                let expanded = rect.insetBy(dx: -pad, dy: -pad)
                if isNoticeFragment(source) {
                    result[index] = anchors.contains { expanded.intersects(regions[$0].rect) }
                } else if isNoticeGlyphFragment(source) {
                    // A garbled piece of the notice block: its glyphs are no larger than the notice's lines.
                    let size = thickness(regions[index])
                    result[index] = anchors.contains {
                        expanded.intersects(regions[$0].rect) && size <= 1.5 * thickness(regions[$0])
                    }
                }
            }
        }
        if anchors.contains(where: { isSampleWatermark(regions[$0].source) }) {
            for index in regions.indices where !result[index] && isMisreadSamplePiece(regions[index]) {
                result[index] = true
            }
        }
        for (index, pattern) in decorativePatterns(in: regions).enumerated() where pattern { result[index] = true }
        return result
    }

    /// Box thickness in page-height units (a line's glyph size, or more for a block).
    private static func thickness(_ region: ReaderTranslationRegion) -> CGFloat {
        let aspect = CGFloat(region.sourceImageAspectRatio ?? 1)
        return min(region.rect.width * aspect, region.rect.height)
    }

    /// Ornamental lettering repeated along a page edge ("YURI TETSU YURI TETSU ..." printed down a border):
    /// Latin-only pieces whose words are all pieces of one cyclic pattern made of the page's most frequent
    /// words, forming a dense run of at least four pieces in the outer fifth of the page over at least 30 %
    /// of its length. Dialogue repeats words too, but not as a tiled strip along the edge.
    static func decorativePatterns(in regions: [ReaderTranslationRegion]) -> [Bool] {
        var result = [Bool](repeating: false, count: regions.count)
        var pieces: [Int: [String]] = [:]
        for (index, region) in regions.enumerated() {
            let text = normalized(region.source)
            guard !containsNonASCIIAlphanumeric(text), !text.unicodeScalars.contains(where: { ("0"..."9").contains($0) })
            else { continue }
            let tokens = words(text).map { $0.uppercased() }
            let letters = tokens.reduce(0) { $0 + $1.count }
            guard letters >= 2, letters <= 24, tokens.allSatisfy({ $0.count <= 12 }) else { continue }
            pieces[index] = tokens
        }
        guard pieces.count >= 4 else { return result }
        var frequency: [String: Int] = [:]
        for tokens in pieces.values { for word in Set(tokens) where word.count >= 3 { frequency[word, default: 0] += 1 } }
        let top = frequency.filter { $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).map(\.key)
        guard let first = top.first else { return result }
        let patterns = top.count == 1 ? [first] : [first + top[1], top[1] + first]
        let cycles = patterns.map { String(repeating: $0, count: 3) }
        let members = Set(pieces.filter { _, tokens in
            cycles.contains { cycle in
                tokens.allSatisfy { cycle.contains($0) || ($0.count >= 3 && cycle.contains(String($0.dropLast()))) }
            }
        }.keys)
        let period = patterns[0].count
        for vertical in [true, false] {
            for far in [false, true] {
                // `vertical`: a column along the left/right edge (runs down the page); otherwise a row.
                let band = pieces.keys.filter { index in
                    let rect = regions[index].rect
                    let (low, high) = vertical ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
                    return far ? low >= 0.8 : high <= 0.2
                }.sorted { vertical ? regions[$0].rect.minY < regions[$1].rect.minY : regions[$0].rect.minX < regions[$1].rect.minX }
                guard band.count >= 4 else { continue }
                // Text height in the run's axis units (rows need the page aspect for x units).
                func height(_ index: Int) -> CGFloat {
                    vertical ? regions[index].rect.height
                        : regions[index].rect.height / CGFloat(regions[index].sourceImageAspectRatio ?? 1)
                }
                func span(_ index: Int) -> (CGFloat, CGFloat) {
                    let rect = regions[index].rect
                    return vertical ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX)
                }
                var runs: [[Int]] = [[band[0]]]
                for index in band.dropFirst() {
                    let previous = runs[runs.count - 1].last!
                    if span(index).0 - span(previous).1 <= 3.5 * min(height(previous), height(index)) {
                        runs[runs.count - 1].append(index)
                    } else {
                        runs.append([index])
                    }
                }
                for run in runs {
                    let fitting = run.filter(members.contains)
                    let letters = fitting.reduce(0) { $0 + pieces[$1]!.reduce(0) { $0 + $1.count } }
                    guard fitting.count >= 4, fitting.count * 10 >= run.count * 7, letters >= 3 * period,
                          span(run[run.count - 1]).1 - span(run[0]).0 >= 0.3 else { continue }
                    for index in run { result[index] = true }
                }
            }
        }
        return result
    }

    /// Fine print of a document drawn as background art and cut by what covers it (a contract under a hand,
    /// a lab report under caption boxes): a cluster of at least six mixed-case Latin prose pieces, many
    /// starting mid-sentence, whose English words are often cut off ("wn as party ract pertain", "Result
    /// Biologi", "rivate appraisal"). Per-piece translations of such text are fragments ("경", "문", "사적"),
    /// so it stays as printed art. A legible document, a UI post or a split balloon has whole words: at
    /// least 15 % of 20 or more lowercase words must be unknown to the English spelling dictionary (cut
    /// documents 18-25 %; whole sentences, slang and names at most 12 %). The dictionary needs the main actor,
    /// so the OCR marks the regions and `keepsOriginalLettering` keeps them like a notice.
    static func markingOccludedDocumentText(_ regions: [ReaderTranslationRegion]) async -> [ReaderTranslationRegion] {
        let candidates = occludedDocumentCandidates(in: regions)
        guard !candidates.isEmpty else { return regions }
        var result = regions
        for candidate in candidates {
            let words = lowercaseWords(candidate.cluster.map { regions[$0].source })
            guard words.count >= 20, let unknown = await ReaderOCRWordBoundaryResolver.unknownWordCount(in: words),
                  100 * unknown >= 15 * words.count else { continue }
            for index in candidate.members { result[index].isOccludedFinePrint = true }
        }
        return result
    }

    /// Clusters that look like occluded English fine print before the dictionary check: `cluster` are the
    /// linked prose pieces, `members` adds isolated scraps of the same document inside their extent ("Mu ed").
    static func occludedDocumentCandidates(in regions: [ReaderTranslationRegion]) -> [(cluster: [Int], members: [Int])] {
        let prose = regions.indices.filter { isRunningLatinText(regions[$0].source) }
        guard prose.count >= 6 else { return [] }
        // Lettering of any case between pieces (caption boxes over the document) links them, never joins them.
        let nodes = regions.indices.filter { regions[$0].source.unicodeScalars.contains(where: isASCIILetter) }
        let sizes = Dictionary(uniqueKeysWithValues: nodes.map { ($0, glyphSize(regions[$0])) })
        var parent = Dictionary(uniqueKeysWithValues: nodes.map { ($0, $0) })
        func root(_ index: Int) -> Int {
            var index = index
            while let next = parent[index], next != index { parent[index] = parent[next]; index = next }
            return index
        }
        for (position, first) in nodes.enumerated() {
            for second in nodes[(position + 1)...]
            where gap(regions[first], regions[second]) <= 1.5 * max(sizes[first] ?? 0, sizes[second] ?? 0) {
                parent[root(first)] = root(second)
            }
        }
        var clusters: [Int: [Int]] = [:]
        for index in prose { clusters[root(index), default: []].append(index) }
        var result: [(cluster: [Int], members: [Int])] = []
        for cluster in clusters.values.map({ $0.sorted() }).sorted(by: { $0[0] < $1[0] }) {
            let sources = cluster.map { regions[$0].source }
            let continuations = sources.filter(startsWithLowercaseLetter).count
            let sentences = sources.filter { $0.split(whereSeparator: \.isWhitespace).count >= 3 }.count
            let letters = sources.reduce(0) { $0 + $1.unicodeScalars.filter(isASCIILetter).count }
            guard cluster.count >= 6, continuations >= 3, 5 * continuations >= 2 * cluster.count, sentences >= 2,
                  letters >= 60 else { continue }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sources.joined(separator: "\n"))
            guard recognizer.dominantLanguage == .english else { continue }
            let extent = cluster.dropFirst().reduce(regions[cluster[0]].rect) { $0.union(regions[$1].rect) }
            let members = prose.filter {
                cluster.contains($0) || extent.contains(CGPoint(x: regions[$0].rect.midX, y: regions[$0].rect.midY))
            }
            result.append((cluster, members))
        }
        return result
    }

    /// Lowercase-initial Latin words of two or more letters (apostrophes kept inside: "don't").
    static func lowercaseWords(_ sources: [String]) -> [String] {
        sources.flatMap { source in
            source.unicodeScalars.split { !isASCIILetter($0) && $0 != "'" }
                .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
                .filter { $0.unicodeScalars.count >= 2 && ("a"..."z").contains($0.unicodeScalars.first!) }
        }
    }

    /// Mixed-case Latin prose: at least three ASCII letters, half of them lowercase, no CJK or other wide script.
    private static func isRunningLatinText(_ source: String) -> Bool {
        let letters = source.unicodeScalars.filter(isASCIILetter)
        guard letters.count >= 3, !source.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) else { return false }
        return 2 * letters.filter { ("a"..."z").contains($0) }.count >= letters.count
    }

    private static func startsWithLowercaseLetter(_ source: String) -> Bool {
        guard let first = source.unicodeScalars.first(where: { isASCIILetter($0) || ("0"..."9").contains($0) }) else {
            return false
        }
        return ("a"..."z").contains(first)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// Glyph size in page-height units (`BrowserOverlayTypography.sourceSize` on the aspect-corrected box).
    private static func glyphSize(_ region: ReaderTranslationRegion) -> CGFloat {
        let width = region.rect.width * CGFloat(region.sourceImageAspectRatio ?? 1), height = region.rect.height
        let units = region.source.unicodeScalars.reduce(CGFloat.zero) { sum, scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) ? sum : sum + (scalar.value < 0x3000 ? 0.55 : 1)
        }
        guard units >= 2 else { return min(width, height) }
        return min(width, height, sqrt(width * height / units))
    }

    /// Distance between two boxes in page-height units.
    private static func gap(_ first: ReaderTranslationRegion, _ second: ReaderTranslationRegion) -> CGFloat {
        let aspect = CGFloat(first.sourceImageAspectRatio ?? 1)
        let a = first.rect, b = second.rect
        let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)) * aspect
        let dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func isSampleWatermark(_ source: String) -> Bool {
        let text = normalized(source)
        return isSampleWatermark(text.filter { !$0.isWhitespace }, words(text))
    }

    /// One Latin word of four to six letters one OCR edit away from a piece of SAMPLE
    /// ("Sami" for "Samp"), which the translation also reads as SAMPLE (or 샘플).
    private static func isMisreadSamplePiece(_ region: ReaderTranslationRegion) -> Bool {
        let text = normalized(region.source)
        let compact = text.filter { !$0.isWhitespace }
        let tokens = words(text)
        guard tokens.count == 1, let piece = tokens.first, (4...6).contains(piece.count), piece.count == compact.count,
              !isSampleWatermark(compact, tokens), let translation = region.translation else { return false }
        let word = Array("sample".unicodeScalars), letters = Array(piece.unicodeScalars)
        let near = [Array(word.prefix(letters.count)), Array(word.suffix(letters.count))].contains {
            zip($0, letters).filter { $0 != $1 }.count <= 1
        }
        let reply = normalized(translation).lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let readsAsSample = reply == "샘플" || reply.count >= 4 && ("sample".hasPrefix(reply) || "sample".hasSuffix(reply))
        return near && readsAsSample
    }

    private static let japaneseTrigger =
        regex("転[載载]|自作発言|AI学.?禁|学習禁|無断.?[転耘載载使複禁]|複[製装].?[禁加転・·]")
    private static let japaneseVocabulary =
        regex("無断|転[載载]|禁止|禁|学習|学习|使用|複製|加工|転写|自作発言|自作|営利|翻訳|利用|及|載|AI")
    private static let strongNoticeWords = ["無断", "転載", "転载", "学習", "学习", "自作", "複製", "加工"]
    private static let noticeGlyphs = Set("無断転載载禁止学習习使用複製装加工写営利翻訳自作発言")
    private static let handle = regex("@[A-Za-z0-9_.\\-]+")
    private static let url = regex(
        "https?://[A-Za-z0-9./_\\-%?=&#:~]+|www\\.[A-Za-z0-9./_\\-%?=&#:~]+"
            + "|[A-Za-z0-9\\-]+(\\.[A-Za-z0-9\\-]+)*\\.(com|net|org|jp|me|io|tv|info)(/[A-Za-z0-9./_\\-%?=&#:~]*)?",
        options: .caseInsensitive
    )
    private static let platforms: Set<String> = [
        "twitter", "instagram", "pixiv", "fanbox", "fantia", "patreon", "skeb", "bluesky", "youtube", "tiktok", "x", "id"
    ]
    private static let fragmentVocabulary = [
        "do", "not", "no", "dont", "repost", "reposts", "reupload", "reuploading", "use", "my", "art", "artwork", "artworks",
        "ai", "al", "training", "learning", "train", "is", "are", "prohibited", "and", "or", "for", "to", "other", "sites",
        "reproduction", "of", "secondary"
    ]

    /// Every Latin word is SAMPLE or a piece of the tiled word; a lone piece needs four letters.
    private static func isSampleWatermark(_ compact: String, _ tokens: [String]) -> Bool {
        guard !tokens.isEmpty, !containsNonASCIIAlphanumeric(compact), tokens.allSatisfy({ $0.count <= 6 }) else {
            return false
        }
        if tokens.contains("sample") {
            return tokens.allSatisfy { "sample".contains($0) || $0.hasPrefix("sa") }
        }
        guard tokens.count == 1, let piece = tokens.first, piece.count >= 4 else { return false }
        return "sample".hasPrefix(piece) || "sample".hasSuffix(piece)
    }

    /// Only handles, URLs and platform labels ("Twitter @name Instagram @name").
    private static func isHandleOrURL(_ text: String) -> Bool {
        guard matches(handle, text) || matches(url, text) else { return false }
        let rest = replacing(handle, in: replacing(url, in: text, with: " "), with: " ")
        return words(rest).allSatisfy(platforms.contains) && !containsNonASCIIAlphanumeric(rest)
            && !rest.unicodeScalars.contains { ("0"..."9").contains($0) }
    }

    /// "Do not repost", "No reuploading No AI training", "DO NOT USE MY ARTWORK" (OCR may drop spaces).
    private static func isLatinNotice(_ latin: String, _ tokens: [String], prohibited: Bool = false) -> Bool {
        guard latin.count <= 120 else { return false }
        let negated = tokens.contains { ["no", "not", "dont", "never"].contains($0) }
            || latin.contains("rohib") || latin.contains("forbid")
        if (latin.contains("reupload") || latin.contains("repost")) && (negated || tokens.count <= 3) { return true }
        if negated || prohibited,
           ["aitrain", "altrain", "ailearn", "allearn", "aitraning", "altraning"].contains(where: latin.contains) { return true }
        return latin.contains("notusemyart")
    }

    /// Source-text evidence for the overlay's keep-source + gloss path: sound effects and logos whose
    /// lettering cannot be erased cleanly keep the source and get a small outlined note instead of a
    /// plate over the artwork. Dialogue and captions must never qualify, so the evidence is narrow.
    enum EffectLettering: String {
        /// Onomatopoeia: effect katakana (ゴゴゴ, キキーッ, シーン), effect glyphs (嗡嗡, 啪嗒) or one glyph
        /// repeated (科科科科). The overlay also requires body size and a plate over artwork.
        case soundEffect = "sfx"
        /// A short display word that is effect lettering or a logo only when giant (スイッチ, はっ, 驚);
        /// the same words are names, gasps or speech at text size.
        case display
        /// A title or series logo (推しの子, 救世主《メシア》): eligible only when it is at least 3x the page's
        /// text, set horizontally outside balloons, on a title page or in title brackets.
        case title
        /// A short kana piece (ぱっ read as は): never eligible alone; it only joins an effect it touches.
        case piece
    }

    /// The payload role: `effectLettering`, else a title (`titleLettering`), else a short kana piece.
    static func letteringRole(_ source: String, pageHasHiragana: Bool, pageHasCredits: Bool) -> EffectLettering? {
        if let effect = effectLettering(source, pageHasHiragana: pageHasHiragana) { return effect }
        if titleLettering(source, pageHasCredits: pageHasCredits) { return .title }
        let letters = source.unicodeScalars.filter { !$0.properties.isWhitespace && !effectPunctuation.contains($0) }
        guard !source.contains("?"), !source.contains("？"), (1...3).contains(letters.count) else { return nil }
        if letters.allSatisfy({ (0x30A1...0x30FA).contains($0.value) || (0x3041...0x3096).contains($0.value) }) { return .piece }
        // A Han glyph repeated two or three times (啦啦 beside 嘩): a piece of the effect it touches.
        let han = letters.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        guard han, letters.count >= 2, Set(letters).count == 1, let glyph = letters.first else { return nil }
        return hanInterjections.contains(glyph) ? nil : .piece
    }

    /// Title or logo lettering: 2-12 letters of kana or Han (Latin letters only mixed in; no digits), no
    /// question, full stop or comma (sentences), and not credit vocabulary itself. Evidence: a title page
    /// (`pageHasCredits`: another region names a chapter, volume, serial, original work or release) or
    /// title brackets 【】《》『』. Large display dialogue elsewhere never qualifies.
    static func titleLettering(_ source: String, pageHasCredits: Bool) -> Bool {
        let text = String(String.UnicodeScalarView(source.unicodeScalars.filter { !$0.properties.isWhitespace }))
        guard !text.isEmpty, !text.contains(where: { "?？。、".contains($0) }), !containsTitleCredits(text) else { return false }
        let letters = text.unicodeScalars.filter { !titlePunctuation.contains($0) && !effectPunctuation.contains($0) }
        guard (2...12).contains(letters.count) else { return false }
        func cjk(_ scalar: Unicode.Scalar) -> Bool {
            [0x30A1...0x30FA, 0x3041...0x3096, 0x4E00...0x9FFF, 0x3400...0x4DBF].contains { $0.contains(scalar.value) }
        }
        guard letters.allSatisfy({ cjk($0) || $0.isASCII && $0.properties.isAlphabetic }), letters.contains(where: cjk) else { return false }
        return pageHasCredits || text.unicodeScalars.contains { "【《『】》』".unicodeScalars.contains($0) }
    }

    /// Title-page evidence for `titleLettering` (checked on the page's other regions): a chapter or volume
    /// number, a serial, the original work, artwork credits, a release or a final chapter.
    static func containsTitleCredits(_ text: String) -> Bool {
        matches(titleCredits, text)
    }

    /// `pageHasHiragana`: another region of the page contains hiragana (a Japanese page), where a lone
    /// kanji is usually a piece of a word or a label; elsewhere a lone Han glyph is effect lettering (驚, 拿).
    static func effectLettering(_ source: String, pageHasHiragana: Bool) -> EffectLettering? {
        let text = String(String.UnicodeScalarView(source.unicodeScalars.filter { !$0.properties.isWhitespace }))
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 24, !text.contains("?"), !text.contains("？") else { return nil }
        let letters = scalars.filter { !effectPunctuation.contains($0) }
        guard !letters.isEmpty else { return nil }
        let count = letters.count
        // The shortest unit that the letters repeat (ゴ in ゴゴゴ, ワイ in ワイワイ), at most four letters.
        let unit = count < 2 ? nil : (1...min(4, count / 2)).first { size in
            count % size == 0 && letters.indices.allSatisfy { letters[$0] == letters[$0 % size] }
        }
        func all(_ range: ClosedRange<UInt32>...) -> Bool {
            letters.allSatisfy { letter in range.contains { $0.contains(letter.value) } }
        }
        let katakana: ClosedRange<UInt32> = 0x30A1...0x30FA, hiragana: ClosedRange<UInt32> = 0x3041...0x3096
        if all(katakana) {
            // An effect ending: a small kana or ッ, a long vowel after a small kana or long vowel (キャー,
            // ポーーン; カレー and コーヒー are nouns), or ン after one of them (シーン, ガチャン) or as ドン.
            let tail = Array(text.unicodeScalars.reversed().drop { "!！…‥・.。、,~〜～".unicodeScalars.contains($0) }.reversed())
            let last = tail.last, previous = tail.count >= 2 ? tail[tail.count - 2] : nil
            let small = "ァィゥェォャュョッーｰ".unicodeScalars
            let ending = last.map { "ッァィゥェォャュョ".unicodeScalars.contains($0) } == true ||
                last.map { "ーｰ".unicodeScalars.contains($0) } == true && previous.map(small.contains) == true ||
                last == "ン" && (count == 2 || previous.map(small.contains) == true)
            if count <= 6, let unit, unit > 1 || count >= 3 { return .soundEffect }
            if (2...4).contains(count) && ending { return .soundEffect }
            // Short pieces, names and loanwords (ウチ, ティレル, スイッチ).
            return count <= 6 ? .display : nil
        }
        if all(hiragana) {
            // Gasps, repeated and one-letter kana (はっ, どきどき, あ) are also speech. A lone particle (は, を, の)
            // is a piece of a phrase.
            let particle = count == 1 && "はをがのにともへでや".unicodeScalars.contains(letters[0])
            return count <= 6 && unit != nil || count == 1 && !particle || count <= 3 && letters.last == "っ" ? .display : nil
        }
        if all(katakana, hiragana) { return count <= 6 && unit != nil ? .display : nil }
        if all(0x4E00...0x9FFF, 0x3400...0x4DBF) {
            // Effect glyphs only, or one glyph three or more times; repeated words (大丈夫大丈夫) are speech.
            if count <= 6 && letters.allSatisfy(hanSoundEffects.contains) ||
                (3...8).contains(count) && Set(letters).count == 1 && !hanInterjections.contains(letters[0]) {
                return .soundEffect
            }
            return count == 1 && !pageHasHiragana ? .display : nil
        }
        if letters.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }),
           source.split(whereSeparator: \.isWhitespace).count == 1 {
            // One elongated word (Woooooo) is an effect when giant; shorter stretches (NOOOO, MMM) are speech.
            let lower = letters.map { Character($0).lowercased() }
            let stretched = lower.indices.contains { index in index >= 4 && (index - 4...index).allSatisfy { lower[$0] == lower[index] } }
            return stretched ? .display : nil
        }
        return nil
    }

    /// Japanese-page evidence for `effectLettering` (checked on the page's other regions).
    static func containsHiragana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) }
    }

    private static let titlePunctuation = Set("【】《》『』「」〈〉・·~〜～!！、,♡♥❤☆★ー-—―.:：".unicodeScalars)
    private static let titleCredits = regex(
        "連載|原作|作画|発売|最終回|第\\s*[0-9０-９一二三四五六七八九十百]+\\s*[話巻]|[0-9０-９]+\\s*[話巻]|chapter\\s*[0-9]|episode\\s*[0-9]|單行本|单行本",
        options: [.caseInsensitive]
    )
    private static let effectPunctuation = Set("ーｰ〜～~!！…‥・·.。,、，-—―♪♡♥❤☆★'\"“”‘’「」『』()（）［］[]:：;；".unicodeScalars)
    // Chinese sound-effect glyphs (knocks, bangs, rustles, laughter); interjections (啊, 嗯, 喔) are speech.
    private static let hanSoundEffects = Set("啪嗒咚砰轟轰嘩哗唰噹咔嚓叮噠哒嘭嗖咻嗡吱嘎噔啾啵咕嚕噜呼噗喀咯嘀叭咣哐嘣噼啷铛鐺噌哈嘻呵".unicodeScalars)
    private static let hanInterjections = Set("啊嗯喔哦呀哇唉嘿呃嗚呜".unicodeScalars)

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(_ text: String) -> [String] {
        let letters = text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        return letters.unicodeScalars.split { !("a"..."z").contains($0) }.map { String(String.UnicodeScalarView($0)) }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        0x3040...0x30FF ~= scalar.value || 0x3400...0x9FFF ~= scalar.value
    }

    private static func containsNonASCIIAlphanumeric(_ text: String) -> Bool {
        text.unicodeScalars.contains { !$0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replacing(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
