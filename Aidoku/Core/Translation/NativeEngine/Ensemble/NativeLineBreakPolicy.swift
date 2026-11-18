import Foundation

/// Original UTF16 boundaries only. Rules constrain soft wraps, never author
/// newlines or source text. Applies identically to ordinary and caption layouts.
enum NativeLineBreakPolicy {
    static let opening = Set("([{（［｛〈《「『【〔〖〘〚｟«‹‘“〝⟨⟪⟦⟬⟮¿¡")
    static let closing = Set(")]}）］｝〉》」』】〕〗〙〛｠»›’”〞〟⟩⟫⟧⟭⟯、。，．・：；？！‼⁇⁈⁉!?,.:;…‥｡､･:;،؛؟।॥׃།༎՜՝՞՛։％%‰‱℃℉°′″‴゛゜ﾞﾟヽヾゝゞ々〻〃〱〲〳〴〵ーｰぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿｧｨｩｪｫｯｬｭｮ")
    static let version = "broad-kinsoku-and-semantic-tails-v10"
    private static let expressiveTail = try! NSRegularExpression(pattern:
        #"(?:\.{2,}|…+|‥+)(?:[♡♥❤♪♫♬♩☆★][\uFE0E\uFE0F]?)+[”’」』\"'）)]*[\t ]*(?=$|[\r\n\u2028\u2029])"#)
    private static let parentheticalTail = try! NSRegularExpression(pattern:
        #"[（(][^\r\n()（）]{2,}[）)][\t ]*[”’」』\"']*(?=$|[\r\n\u2028\u2029])"#)

    /// Only complete terminal expressive suffixes may start a separate row.
    /// Interior run boundaries, a lone heart and decimal points stay protected.
    private static func expressiveTailOffsets(text: String) -> Set<Int> {
        let ns = text as NSString
        return Set(expressiveTail.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var offset = match.range.location
            while offset > 0 {
                let range = ns.rangeOfComposedCharacterSequence(at: offset - 1)
                guard let character = ns.substring(with: range).first else { return nil }
                if isSpace(character) { offset = range.location; continue }
                return character.isLetter || character.isNumber ? match.range.location : nil
            }
            return nil
        })
    }

    /// Soft preferences only. Text and hard paragraph ownership are unchanged.
    static func preferredOffsets(text: String) -> Set<Int> {
        let ns = text as NSString
        var result = expressiveTailOffsets(text: text)
        for match in parentheticalTail.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let offset = match.range.location
            guard offset > 0, let previous = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: offset - 1)).first,
                  isSpace(previous) else { continue }
            result.insert(offset)
        }
        return result
    }

    static func isExpressiveTailBoundary(text: String, offset: Int) -> Bool {
        expressiveTailOffsets(text: text).contains(offset)
    }

    static func isExpressiveTailRow(text: String, range: NSRange) -> Bool {
        let ns = text as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= ns.length,
              expressiveTailOffsets(text: text).contains(range.location),
              let match = expressiveTail.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .first(where: { $0.range.location == range.location }),
              NSMaxRange(match.range) <= NSMaxRange(range) else { return false }
        let remainder = NSRange(location: NSMaxRange(match.range), length: NSMaxRange(range) - NSMaxRange(match.range))
        return ns.substring(with: remainder).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private static let directionalControls = Set("\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
    static func isDirectionalControl(_ character: Character) -> Bool { directionalControls.contains(character) }
    private static let decimalPoints = Set(".,．٫")
    private static let openingCategories: Set<Unicode.GeneralCategory> = [.openPunctuation, .initialPunctuation]
    private static let closingCategories: Set<Unicode.GeneralCategory> = [.closePunctuation, .finalPunctuation, .nonspacingMark, .spacingMark, .enclosingMark]
    private static let quotes = Set("\"'＂＇“”‘’„‟‚‛«»‹›〝〞〟")
    private static let wordApostrophe = try! NSRegularExpression(
        pattern: #"(?<=[\p{Latin}\p{Greek}\p{Cyrillic}])['’＇](?=[\p{Latin}\p{Greek}\p{Cyrillic}])"#)
    private static func quoteFamily(_ quote: Character) -> Int {
        switch quote {
        case "'", "＇", "‘", "’", "‚", "‛": 0
        case "«", "»": 1
        case "‹", "›": 2
        case "〝", "〞", "〟": 3
        default: 4
        }
    }
    static let glue: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2060}", "\u{FEFF}", "\u{2011}"]
    static let pairedRun = Set("-‐‒–—―─⸺⸻…‥")
    private static let continuations = Set("-‐‒–—―─⸺⸻~〜～∼")
    private static let suffixMarks = Set("♡♥♥️♥︎❤❤️❤︎♪♫♬♩☆★※†‡¹²³⁰⁴⁵⁶⁷⁸⁹₀₁₂₃₄₅₆₇₈₉")
    // Grouping is explicit: thin/figure spaces or apostrophes separate exact
    // triads. Regular spaces remain available between independent numbers.
    private static let groupedDigits = #"\p{Nd}{1,3}(?:['’＇\u2007\u2009]\p{Nd}{3})+(?:[.,．٫]\p{Nd}+)?(?!\p{Nd})"#
    private static let numbers = #"[+\-−±]?(?:"# + groupedDigits +
        #"|\p{Nd}+(?:[.,，．٫٬:/：／\-‐‒–−~〜～]\p{Nd}+)*|[.,．٫]\p{Nd}+)(?:[eE][+\-−]?\p{Nd}+)?"#
    private static let units = [
        "km/h", "m/s²", "m/s", "km²", "cm²", "mm²", "m²", "m³", "cm³", "mm³",
        "kcal", "kWh", "MHz", "GHz", "kHz", "Hz", "kPa", "MPa", "Pa", "rpm", "dpi", "px", "pt",
        "KiB", "MiB", "GiB", "TiB", "KB", "MB", "GB", "TB", "bit", "bytes", "byte",
        "km", "cm", "mm", "μm", "µm", "nm", "kg", "mg", "μg", "µg", "mL", "ml", "kW", "mW",
        "ms", "μs", "µs", "ns", "min", "mol", "mmol", "dB", "°C", "°F", "℃", "℉",
        "m", "g", "L", "l", "s", "h", "W", "V", "A", "K", "%", "％", "‰", "‱", "°",
        "USD", "EUR", "KRW", "JPY", "CNY", "RMB", "GBP", "TWD", "HKD", "AUD", "CAD",
        "㎏", "㎎", "㎜", "㎝", "㎞", "㎖", "ℓ", "원", "달러", "유로", "엔", "퍼센트",
        "개", "명", "살", "세", "년", "월", "일", "시", "분", "초", "시간", "도", "배", "쪽", "층", "회", "권", "장",
        "개월", "주", "주일", "번", "번째",
        "ミリ", "センチ", "キロ", "グラム", "メートル", "個", "人", "歳", "年", "月", "日", "時", "分", "秒", "円", "本", "冊", "枚", "回", "倍"
    ]
    private static let protectedExpressions: [NSRegularExpression] = {
        func alternatives(_ values: [String]) -> String {
            values.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        }
        // SI prefixes and compound notation are a grammar, rather than a list
        // of observed measurements. Word-boundary checks still reject ordinary
        // words that merely begin with a unit symbol.
        let prefixes = alternatives(["da", "Q", "R", "Y", "Z", "E", "P", "T", "G", "M", "k", "h",
            "d", "c", "m", "µ", "μ", "n", "p", "f", "a", "z", "y", "r", "q"])
        let bases = alternatives(["mol", "kat", "rad", "ohm", "min", "Hz", "Pa", "Wb", "Bq", "Gy", "Sv", "lm", "lx", "cd",
            "m", "g", "s", "A", "K", "L", "B", "N", "J", "W", "C", "V", "F", "S", "T", "H", "Ω", "Ω"])
        let power = #"(?:\^[+\-−]?\p{Nd}+|[⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻]+)?"#
        let term = "(?:(?:" + prefixes + ")?(?:" + bases + "))" + power
        let compound = term + "(?:[·⋅*/]" + term + ")*"
        let koreanUnits = units.filter { $0.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
        let otherUnits = units.filter { !koreanUnits.contains($0) }
        let particles = alternatives(["에게서", "한테서", "으로서", "으로써", "이라고", "이라도", "으로", "에서", "에게", "한테",
            "께서", "부터", "까지", "마다", "처럼", "보다", "만큼", "정도", "이나", "이며", "께", "은", "는", "이", "가", "을", "를",
            "의", "에", "와", "과", "도", "만", "로", "나", "쯤", "째", "씩", "간", "전", "후", "뒤"])
        // A Korean counter must finish its token (including closed-class
        // particles). Otherwise '10 번역' or '10 개성' would be misread as
        // '10번…' / '10개…'. Japanese counters keep continuous-script rules.
        let korean = "(?:" + alternatives(koreanUnits) + ")(?:(?:" + particles + ")){0,3}" + #"(?![\p{Hangul}\p{Latin}\p{Nd}_])"#
        let other = "(?:" + #"[ap]\.?m\.?|"# + compound + "|" + alternatives(otherUnits) + #")(?![\p{Latin}\p{Nd}_])"#
        // Directly attached counters retain their prefix behavior in continuous
        // Korean text. With a separating space, require a complete counter word.
        let attachedKorean = "(?:" + alternatives(koreanUnits) + #")(?![\p{Latin}\p{Nd}_])"#
        let adjacentUnit = korean + "|" + attachedKorean + "|" + other
        let spacedUnit = korean + "|" + other
        return [
            #"[+\-−±]\h*"# + numbers,
            numbers + "(?:(?:" + adjacentUnit + #")|\h+(?:"# + spacedUnit + "))?",
            #"(?:\p{Sc}|\b(?:USD|EUR|KRW|JPY|CNY|RMB|GBP|TWD|HKD|AUD|CAD)\b)\h*"# + numbers,
        ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func isBreak(_ character: Character) -> Bool {
        ["\n", "\r", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"].contains(character)
    }
    static func isSpace(_ character: Character) -> Bool {
        character == "\u{200B}" || (!isBreak(character) && !glue.contains(character) &&
            character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) })
    }
    static func legalOffsets(text: String, allowExpressiveTail: Bool = true) -> Set<Int> {
        let chars = Array(text)
        guard chars.count > 1 else { return [] }
        var ends: [Int] = [], offset = 0
        for c in chars { offset += String(c).utf16.count; ends.append(offset) }
        let controls = chars.map(isDirectionalControl)
        var previous = [Int](repeating: -1, count: chars.count+1)
        var following = [Int](repeating: chars.count, count: chars.count+1)
        for i in chars.indices { previous[i+1] = controls[i] ? previous[i] : i }
        for i in chars.indices.reversed() { following[i] = controls[i] ? following[i+1] : i }
        var left = [Int](repeating: -1, count: chars.count), right = left, last = -1
        for i in chars.indices { if !isSpace(chars[i]) && !controls[i] { last = i }; left[i] = last }
        last = -1
        for i in chars.indices.reversed() { if !isSpace(chars[i]) && !controls[i] { last = i }; right[i] = last }
        // Match lexical rules against visible content, mapping each UTF16 slot
        // back to the untouched source. Direction markers are never stripped
        // from owned ranges, shaped text, or output.
        var expressionText = text, expressionToOriginal: [Int]?
        if controls.contains(true) {
            expressionText = ""
            var mapping: [Int] = []
            for i in chars.indices where !controls[i] {
                let start = i == 0 ? 0 : ends[i-1]
                expressionText.append(chars[i])
                mapping.append(contentsOf: start..<ends[i])
            }
            expressionToOriginal = mapping
        }
        let expressionRange = NSRange(location: 0, length: expressionText.utf16.count)
        func originalStart(_ value: Int) -> Int { expressionToOriginal?[value] ?? value }
        func originalEnd(_ value: Int) -> Int { expressionToOriginal.map { $0[value-1]+1 } ?? value }
        var forbidden = Set<Int>(), numericStarts = Set<Int>()
        for expression in protectedExpressions {
            for match in expression.matches(in: expressionText, range: expressionRange) {
                let start = originalStart(match.range.location), end = originalEnd(NSMaxRange(match.range))
                numericStarts.insert(start)
                for boundary in (start+1)..<end { forbidden.insert(boundary) }
            }
        }
        func category(_ c: Character, _ allowed: Set<Unicode.GeneralCategory>) -> Bool {
            guard let first = c.unicodeScalars.first else { return false }
            return allowed.contains(first.properties.generalCategory)
        }
        var apostrophes = Set(wordApostrophe.matches(in: expressionText, range: expressionRange)
            .map { originalStart($0.range.location) })
        for index in chars.indices where "'’＇".contains(chars[index]) {
            let start = index == 0 ? 0 : ends[index-1], before = previous[index], after = following[index+1]
            if before >= 0 && after < chars.count && chars[before].isNumber && chars[after].isNumber &&
                forbidden.contains(start) && forbidden.contains(ends[index]) {
                // A thousands separator must not close a surrounding quote.
                apostrophes.insert(start)
            }
        }
        var paragraphBreaks = Set<Int>()
        var seenLineBreak = false, contentSinceBreak = false
        for index in chars.indices {
            let c = chars[index]
            if isBreak(c) {
                // Explicit line breaks inside a quote do not end that quote.
                // An empty paragraph or a paragraph separator starts fresh.
                if c == "\u{2029}" || (seenLineBreak && !contentSinceBreak) { paragraphBreaks.insert(index) }
                seenLineBreak = true
                contentSinceBreak = false
                continue
            }
            if !isSpace(c) && !controls[index] { contentSinceBreak = true }
        }
        var nextFamilyQuotes: [Int: Character] = [:], reversePairCandidates = Set<Int>()
        for index in chars.indices.reversed() {
            if paragraphBreaks.contains(index) { nextFamilyQuotes.removeAll() }
            let c = chars[index]
            guard quotes.contains(c), !apostrophes.contains(index == 0 ? 0 : ends[index-1]) else { continue }
            let family = quoteFamily(c), next = nextFamilyQuotes[family]
            if (c == "»" && next == "«") || (c == "›" && next == "‹") ||
                (c == "”" && next == "”") || (c == "’" && next == "’") { reversePairCandidates.insert(index) }
            nextFamilyQuotes[family] = c
        }
        var pendingQuotes = Set<Int>(), openingQuotes = Set<Int>()
        for index in chars.indices {
            let c = chars[index]
            if paragraphBreaks.contains(index) { pendingQuotes.removeAll() }
            if isBreak(c) { continue }
            guard quotes.contains(c), !apostrophes.contains(index == 0 ? 0 : ends[index-1]) else { continue }
            let family = quoteFamily(c)
            // Pair state distinguishes an opener after CJK text or a colon
            // from a closer before a suffix, including spaces inside quotes.
            if pendingQuotes.remove(family) != nil { continue }
            guard index+1 < chars.count, right[index+1] >= 0,
                  !isBreak(chars[right[index+1]]) else { continue }
            let before = previous[index], after = following[index+1]
            guard after < chars.count else { continue }
            if before >= 0 && !isSpace(chars[before]) && !isBreak(chars[before]) &&
                (isSpace(chars[after]) || closing.contains(chars[after])) { continue }
            let openingContext = before < 0 || isSpace(chars[before]) || isBreak(chars[before]) ||
                opening.contains(chars[before]) || pairedRun.contains(chars[before]) ||
                ":：;；=".contains(chars[before])
            if category(c, [.finalPunctuation]) && !openingContext && !reversePairCandidates.contains(index) { continue }
            if before >= 0 && chars[before].isNumber && "\"'＂＇".contains(c) { continue }
            openingQuotes.insert(index)
            pendingQuotes.insert(family)
        }
        func openingQuote(_ index: Int) -> Bool { openingQuotes.contains(index) }
        var allowed = Set<Int>()
        for i in 0..<(chars.count-1) {
            let boundary = ends[i], a = chars[i], b = chars[i+1]
            if isBreak(a) || isBreak(b) { continue }
            if b == "\u{00AD}" { continue }
            if a == "\u{00AD}" {
                let before = previous[i], after = following[i+1]
                if before < 0 || after == chars.count || !(chars[before].isLetter || chars[before].isNumber) ||
                    !(chars[after].isLetter || chars[after].isNumber) { continue }
            }
            if forbidden.contains(boundary) || glue.contains(a) || glue.contains(b) { continue }
            let li = left[i], ri = right[i+1]
            if li >= 0 && ri >= 0 {
                let l = chars[li], r = chars[ri]
                if r == "\u{00AD}" || (l == "\u{00AD}" && controls[i]) { continue }
                if quotes.contains(l) ? openingQuote(li) : (opening.contains(l) || category(l, openingCategories)) { continue }
                let decimalPrefix = decimalPoints.contains(r) && numericStarts.contains(ri == 0 ? 0 : ends[ri-1])
                if quotes.contains(r) ? !openingQuote(ri) : (!decimalPrefix && (closing.contains(r) || category(r, closingCategories))) { continue }
                if pairedRun.contains(l) && pairedRun.contains(r) { continue }
                let beforeL = previous[li], beforeR = previous[ri], afterR = following[ri+1]
                // A drawn-out ending or hyphen stays with the preceding ink.
                // A leading dash/approximation marker instead stays with the
                // following word/number; a spaced separator may start a row.
                if continuations.contains(r) &&
                    ((beforeR >= 0 && !isSpace(chars[beforeR]) && !isBreak(chars[beforeR])) ||
                     afterR == chars.count || isBreak(chars[afterR]) || closing.contains(chars[afterR])) { continue }
                if continuations.contains(l) && (r.isLetter || r.isNumber) {
                    var runStart = li
                    while previous[runStart] >= 0 && continuations.contains(chars[previous[runStart]]) { runStart = previous[runStart] }
                    let beforeRun = previous[runStart]
                    if beforeRun < 0 || isSpace(chars[beforeRun]) || isBreak(chars[beforeRun]) { continue }
                }
                if suffixMarks.contains(r) && (afterR == chars.count || isSpace(chars[afterR]) ||
                    isBreak(chars[afterR]) || closing.contains(chars[afterR]) || suffixMarks.contains(chars[afterR])) { continue }
                if suffixMarks.contains(l) && suffixMarks.contains(r) { continue }
                if suffixMarks.contains(l) && (beforeL < 0 || isSpace(chars[beforeL]) || isBreak(chars[beforeL])) && r.isLetter { continue }
                if apostrophes.contains(li == 0 ? 0 : ends[li-1]) ||
                    apostrophes.contains(ri == 0 ? 0 : ends[ri-1]) { continue }
            }
            allowed.insert(boundary)
        }
        if allowExpressiveTail {
            allowed.formUnion(expressiveTailOffsets(text: text).filter { !forbidden.contains($0) })
        }
        return allowed
    }
}
