import CoreGraphics
import CoreText
import Darwin
import Foundation

/// One fixed-font, fixed-width typesetter. Standard Core Text wraps retain a
/// fitting whitespace-delimited unit prefix and respect actual glyph ink width.
/// Parent placement still owns page, balloon and neighbour admission.
enum NativeSimpleTextLayout {
    // Query a single live flag during shaping instead of materializing the
    // complete process environment for each owner and width-fit attempt.
    static func enabledUnlessZero(_ name: String) -> Bool {
        getenv(name).map { strcmp($0, "0") != 0 } ?? true
    }
    static var version: String {
        let widthPolicy = widthFitEnabled
            ? (NativeSimpleFinalWidthFallback.enabled ? NativeSimpleFinalWidthFallback.version : "coretext-single-source-width-v6")
            : "coretext-token-tail-fit-v5"
        return widthPolicy + "-coherent-repeat-runs-v1"
    }
    @TaskLocal private static var widthFitOverride: Bool?
    // Width ingress can be rolled back without restoring the rich legacy wrapper.
    static var widthFitEnabled: Bool {
        enabled && (widthFitOverride ?? enabledUnlessZero("AIDOKU_SIMPLE_WIDTH_FIT"))
    }
    static func withWidthFit<Value>(_ enabled: Bool, operation: () throws -> Value) rethrows -> Value {
        try $widthFitOverride.withValue(enabled, operation: operation)
    }
    @TaskLocal private static var enabledOverride: Bool?
    static var enabled: Bool {
        enabledOverride ?? enabledUnlessZero("AIDOKU_SIMPLE_TEXT_LAYOUT")
    }
    static func withEnabled<Value>(_ enabled: Bool, operation: () throws -> Value) rethrows -> Value {
        try $enabledOverride.withValue(enabled, operation: operation)
    }

    // A width search owns one immutable text/font/color input. Line breaking
    // still runs independently at every width, with no shared result cache.
    struct TypesettingInput {
        let text: String
        let size: CGFloat
        let face: CTFont
        let attributed: NSAttributedString
        let typesetter: CTTypesetter

        init(text: String, font: CTFont, size: CGFloat, color: CGColor) {
            self.text = text
            self.size = size
            face = CTFontCreateCopyWithAttributes(font, size, nil, nil)
            attributed = NSAttributedString(string: text, attributes: [
                .init(kCTFontAttributeName as String): face,
                .init(kCTForegroundColorAttributeName as String): color])
            typesetter = CTTypesetterCreateWithAttributedString(attributed)
        }
    }

    static func layout(text: String, font: CTFont, size: CGFloat, width: CGFloat,
                       color: CGColor = CGColor(gray: 0, alpha: 1)) throws -> NativeWholeWordWrap.Result {
        guard size.isFinite, size > 0, width.isFinite, width > 0 else {
            throw NativeWholeWordWrap.Failure.invalidInput
        }
        try Task.checkCancellation()
        return try layout(TypesettingInput(text: text, font: font, size: size, color: color), width: width)
    }

    static func layout(_ input: TypesettingInput, width: CGFloat) throws -> NativeWholeWordWrap.Result {
        guard width.isFinite, width > 0 else { throw NativeWholeWordWrap.Failure.invalidInput }
        try Task.checkCancellation()
        let (text, size, face, attributed, typesetter) = (input.text, input.size, input.face, input.attributed, input.typesetter)
        let ns = text as NSString
        var graphemes: [NSRange] = [], paragraphs: [(Int, Int, Int)] = []
        var whitespaceEnds = Set<Int>()
        var offset = 0, paragraphStart = 0
        for character in text {
            let length = String(character).utf16.count
            let range = NSRange(location: offset, length: length)
            graphemes.append(range)
            if NativeLineBreakPolicy.isSpace(character) { whitespaceEnds.insert(offset + length) }
            if character.isNewline {
                paragraphs.append((paragraphStart, offset, offset + length))
                paragraphStart = offset + length
            }
            offset += length
        }
        if paragraphStart < ns.length { paragraphs.append((paragraphStart, ns.length, ns.length)) }
        let ends = graphemes.map(NSMaxRange)
        let boundaries = Dictionary(uniqueKeysWithValues: ends.enumerated().map { ($0.element, $0.offset) })
        let characters = Array(text)
        // Unicode hard nonbreaking glue is a constraint, not a language rule.
        // An overwide glued unit declares overflow for the parent width solver.
        let glue = Set<Character>(["\u{00A0}", "\u{202F}", "\u{2060}", "\u{FEFF}", "\u{2011}"])
        var forbidden = Set(graphemes.indices.dropLast().compactMap { index -> Int? in
            glue.contains(characters[index]) || glue.contains(characters[index+1]) ? ends[index] : nil
        })
        // Keep a terminal punctuation/symbol run with its preceding lexical
        // ink. This is Unicode structure, without decorative-character lists
        // or expression-specific standalone-tail exceptions.
        for (begin, end, _) in paragraphs {
            let members = graphemes.indices.filter { graphemes[$0].location >= begin && ends[$0] <= end }
            guard let lastLetter = members.last(where: { characters[$0].isLetter || characters[$0].isNumber }),
                  members.contains(where: { $0 > lastLetter && (characters[$0].isPunctuation || characters[$0].isSymbol) })
            else { continue }
            let beginTail = graphemes[lastLetter].location
            let tail = CTTypesetterCreateLine(typesetter, CFRange(location: beginTail, length: end-beginTail))
            let tailInk = CTLineGetBoundsWithOptions(tail, [.useGlyphPathBounds])
            let tailAdvance = CGFloat(CTLineGetTypographicBounds(tail, nil, nil, nil))
            let tailLeft = tailInk.isNull || tailInk.isEmpty ? 0 : min(0, tailInk.minX)
            let tailRight = max(tailAdvance, tailInk.isNull || tailInk.isEmpty ? 0 : tailInk.maxX)
            // This attachment is a soft readability constraint. Unlike authored
            // Unicode glue, an overwide decorative suffix must remain wrappable.
            guard tailRight-tailLeft <= width+0.01 else { continue }
            for index in members where index >= lastLetter && ends[index] < end { forbidden.insert(ends[index]) }
        }
        // Keep identical punctuation or symbol graphemes together only when
        // the entire run fits the real ink and advance of this fixed width.
        // Authored newlines and overwide runs retain the ordinary wrapper.
        var runStart = 0
        while runStart < characters.count {
            guard characters[runStart].isPunctuation || characters[runStart].isSymbol else { runStart += 1; continue }
            var runEnd = runStart + 1
            while runEnd < characters.count && characters[runEnd] == characters[runStart] { runEnd += 1 }
            if runEnd - runStart > 1 {
                let begin = graphemes[runStart].location, end = ends[runEnd-1]
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: begin, length: end-begin))
                let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).union(CTLineGetImageBounds(line, nil))
                let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let occupied = max(advance, ink.isNull || ink.isEmpty ? 0 : ink.maxX)
                    - min(0, ink.isNull || ink.isEmpty ? 0 : ink.minX)
                if occupied <= width+0.01 {
                    for member in runStart..<(runEnd-1) { forbidden.insert(ends[member]) }
                }
            }
            runStart = runEnd
        }
        var rows: [NativeWholeWordWrap.Row] = []
        func row(_ owned: NSRange, hard: Bool) -> NativeWholeWordWrap.Row {
            var paint = owned
            while paint.length > 0 {
                let tail = ns.rangeOfComposedCharacterSequence(at: NSMaxRange(paint)-1)
                guard ns.substring(with: tail).allSatisfy(\.isWhitespace) else { break }
                paint.length = tail.location - paint.location
            }
            // A zero-length typesetter range means "to end", not an empty
            // paragraph. Empty owned rows must never duplicate later glyphs.
            let line = paint.length == 0
                ? CTLineCreateWithAttributedString(NSAttributedString(string: ""))
                : CTTypesetterCreateLine(typesetter, CFRange(location: paint.location, length: paint.length))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            if paint.length == 0 { ascent = CTFontGetAscent(face); descent = CTFontGetDescent(face) }
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let left = ink.isNull || ink.isEmpty ? 0 : min(0, ink.minX)
            let right = max(advance, ink.isNull || ink.isEmpty ? 0 : ink.maxX)
            return .init(ownedRange: owned, paintedRange: paint, line: line, advance: advance,
                ascent: ascent, descent: descent, leading: leading, inkBounds: ink, hardBreak: hard,
                overflow: max(0, right-left-width), discretionaryHyphen: false)
        }
        for (begin, end, terminatorEnd) in paragraphs {
            try Task.checkCancellation()
            if begin == end {
                rows.append(row(NSRange(location: begin, length: terminatorEnd-begin), hard: true))
                continue
            }
            var cursor = begin
            while cursor < end {
                // Core Text's preferred Unicode boundary is the only initial
                // choice. Grapheme fallback guarantees progress at narrow widths.
                let suggested = cursor + CTTypesetterSuggestLineBreak(typesetter, cursor, Double(width))
                var boundary = min(end, suggested)
                if boundaries[boundary] == nil {
                    boundary = ends.last(where: { $0 > cursor && $0 <= boundary }) ??
                        ends.first(where: { $0 > cursor })!
                }
                if boundary <= cursor { boundary = ends.first(where: { $0 > cursor })! }
                // Standard CJK line breaking may cut a whitespace-delimited
                // word although its preceding whole units fit. Retain the
                // longest fitting whole-unit prefix; no language/length table,
                // balanced-row DP, tail exception or wider proposal is needed.
                if boundary < end, let whole = ends.last(where: {
                    $0 > cursor && $0 <= boundary && whitespaceEnds.contains($0)
                }) { boundary = whole }
                if boundary < end, forbidden.contains(boundary) {
                    boundary = ends.last(where: { $0 > cursor && $0 < boundary && !forbidden.contains($0) }) ??
                        ends.first(where: { $0 > boundary && $0 <= end && ($0 == end || !forbidden.contains($0)) })!
                }
                var candidate = row(NSRange(location: cursor, length: boundary-cursor), hard: false)
                // One physical objective: retain the longest suggested prefix
                // whose advance AND visible overhang fit. Never split a glyph.
                while candidate.overflow > 0.01, let previous = ends.last(where: {
                    $0 > cursor && $0 < boundary && !forbidden.contains($0)
                }) {
                    boundary = ends.last(where: {
                        $0 > cursor && $0 <= previous && whitespaceEnds.contains($0) && !forbidden.contains($0)
                    }) ?? previous
                    candidate = row(NSRange(location: cursor, length: boundary-cursor), hard: false)
                }
                if boundary == end, terminatorEnd > end {
                    candidate = row(NSRange(location: cursor, length: terminatorEnd-cursor), hard: true)
                }
                rows.append(candidate)
                cursor = boundary
            }
        }
        // Balance only the final adjacent pair of an original hard paragraph.
        // The greedy prefix, font, width and row count stay fixed. One measured
        // native-boundary pass replaces global DP and tail retry variants.
        func wordCut(_ boundary: Int) -> Int {
            guard let index = boundaries[boundary], index+1 < characters.count else { return 0 }
            return (characters[index].isLetter || characters[index].isNumber) &&
                (characters[index+1].isLetter || characters[index+1].isNumber) ? 1 : 0
        }
        for index in rows.indices where index > 0 && (index == rows.count-1 || rows[index].hardBreak) && !rows[index-1].hardBreak {
            let first = rows[index-1], last = rows[index]
            let begin = first.ownedRange.location, end = NSMaxRange(last.ownedRange)
            var bestFirst = first, bestLast = last
            var cost = abs(first.occupiedWidth-last.occupiedWidth)
            var cuts = wordCut(NSMaxRange(first.ownedRange))
            let originalBoundary = NSMaxRange(first.ownedRange)
            for boundary in ends where boundary > begin && boundary < end && boundary != originalBoundary && !forbidden.contains(boundary) {
                let candidateCuts = wordCut(boundary)
                guard candidateCuts <= cuts else { continue }
                let a = row(NSRange(location: begin, length: boundary-begin), hard: false)
                guard a.hasInk, a.overflow <= 0.01 else { continue }
                let b = row(NSRange(location: boundary, length: end-boundary), hard: last.hardBreak)
                guard b.hasInk, b.overflow <= 0.01 else { continue }
                if !whitespaceEnds.contains(boundary),
                   CTTypesetterSuggestLineBreak(typesetter, begin, Double(a.advance)+0.01) != boundary-begin { continue }
                let balanced = abs(a.occupiedWidth-b.occupiedWidth)
                if candidateCuts < cuts || balanced < cost-0.01 {
                    bestFirst = a; bestLast = b; cost = balanced; cuts = candidateCuts
                }
            }
            rows[index-1] = bestFirst
            rows[index] = bestLast
        }
        var missing = Set<NSRange>(), fallback = Set<NSRange>()
        for measured in rows {
            for run in CTLineGetGlyphRuns(measured.line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let actualFont = attributes[kCTFontAttributeName] as! CTFont
                let isFallback = !CFEqual(actualFont, face)
                let lastResort = (CTFontCopyPostScriptName(actualFont) as String).lowercased().contains("lastresort")
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for index in 0..<count {
                    guard isFallback || lastResort || glyphs[index] == 0 else { continue }
                    // Typesetter lines retain original attributed-string indices.
                    let position = indices[index]
                    guard let range = graphemes.first(where: { NSLocationInRange(position, $0) }) else { continue }
                    if isFallback { fallback.insert(range) }
                    if glyphs[index] == 0 || lastResort {
                        let visible = ns.substring(with: range).unicodeScalars.contains {
                            !CharacterSet.controlCharacters.contains($0) && $0.value != 0x200d && !(0xfe00...0xfe0f).contains($0.value)
                        }
                        if visible { missing.insert(range) }
                    }
                }
            }
        }
        for index in characters.indices where characters[index].unicodeScalars.contains(where: {
            $0.properties.generalCategory == .unassigned
        }) { missing.insert(graphemes[index]) }
        let ordered: (NSRange, NSRange) -> Bool = { $0.location < $1.location }
        var cursor = 0, complete = true
        for measured in rows {
            complete = complete && measured.ownedRange.location == cursor
            cursor = NSMaxRange(measured.ownedRange)
        }
        return .init(text: text, attributedText: attributed, rows: rows, graphemeRanges: graphemes,
            unresolvedGlyphRanges: missing.sorted(by: ordered), fallbackRanges: fallback.sorted(by: ordered),
            completeOwnership: complete && cursor == ns.length,
            requiredWidth: rows.map(\.occupiedWidth).max() ?? 0,
            bodyHeight: rows.reduce(0) { $0 + $1.upperExtent + $1.lowerExtent + max($1.leading, size*0.12) },
            requestedFontName: CTFontCopyPostScriptName(face) as String, requestedFontSize: size)
    }
}
