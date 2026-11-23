import CoreGraphics
import CoreText
import Foundation

// S9: per block, binary-search the largest size whose wrapped text fits
// the balloon interior (else the block bounds plus a margin); below the floor the box grows, then
// the text may overflow it (clamped to the page). Words are shaped once, so fit probes are arithmetic.
enum V2Layout {
    /// Smallest size the fit search may choose before the box is allowed to grow.
    static let floorPixels: CGFloat = 10
    /// Fit-search cap relative to the source lettering size (legacy hold: 1.05x in a balloon).
    static func capRatio(_ block: V2Block) -> CGFloat { block.balloon != nil ? 1.05 : 1 }
    /// Margin added around block bounds, relative to source px (clamped 4...24 px).
    static let marginRatio: CGFloat = 0.2
    /// Line advance in em; matches the legacy renderer's Korean line height (1.18 em).
    static let lineHeightEm: CGFloat = 1.18
    /// Painted ink of one line in em (0.83 above, 0.11 below the baseline).
    static let inkHeightEm: CGFloat = 0.94
    /// Baseline below the top of a line's ink, in em.
    static let inkAscentEm: CGFloat = 0.83
    /// Vertical cell advance per character, in em.
    static let verticalAdvanceEm: CGFloat = 1.02
    /// Fraction of the box width used for wrapping, leaving room for kerning drift.
    static let widthSlack: CGFloat = 0.97
    /// Smallest whole-word size, relative to the split-word size, that is preferred over splitting.
    static let wholeWordRatio: CGFloat = 0.85
    /// Horizontal scale of a condensed fit (whole words narrowed rather than split); 0.85 beat 0.9
    /// on every fold (compare.py +23, test +7; 0.8 +19, 0.875 +7, 0.95 -62).
    static let condenseScale: CGFloat = 0.85
    /// Tilted text keeps the source tilt down to this share of its upright size.
    static let rotationSizeRatio: CGFloat = 0.9
    /// The strict Korean line-break rules yield when the fit they allow is below this share of the relaxed one.
    static let strictRuleRatio: CGFloat = 0.9
    /// A stacked horizontal fit yields to vertical columns at no less than this share of its size.
    static let stackedVerticalRatio: CGFloat = 0.85
    /// Compaction may take a wrap up to this much wider than the narrowest one when it has fewer bad breaks.
    static let compactBreakWidth: CGFloat = 1.15

    /// Three or more horizontal lines averaging under two graphemes (a vertical stack).
    static func isStacked(_ fit: Fit) -> Bool {
        guard !fit.vertical, fit.lines.count >= 3 else { return false }
        let graphemes = fit.lines.reduce(0) { $0 + $1.filter { $0 != " " }.count }
        return graphemes < fit.lines.count * 2
    }

    // MARK: - Contract

    static func place(_ blocks: [V2Block], pageSize: CGSize) -> [V2PlacedText] {
        let page = CGRect(origin: .zero, size: pageSize)
        guard page.width >= 1, page.height >= 1 else { return [] }
        let paintable = blocks.filter(isPaintable).sorted {
            ($0.readingOrder, $0.id) < ($1.readingOrder, $1.id)
        }
        let sourceBounds = paintable.map { $0.bounds.intersection(page) }
        let plan = V2Cohort.plan(paintable, sources: paintable.map(sourcePixels), capRatio: capRatio, floor: floorPixels)
        // Shaped once per block; family re-fits reuse it.
        let texts = paintable.map(measured)
        func obstacles(_ index: Int, _ frames: [CGRect]) -> [CGRect] {
            frames + sourceBounds.enumerated().compactMap { other, rect in other != index && !rect.isNull ? rect : nil }
        }
        var placed: [V2PlacedText] = []
        var frames: [CGRect] = []
        for (index, block) in paintable.enumerated() {
            let result = placeBlock(block, text: texts[index], page: page, obstacles: obstacles(index, frames), placedFrames: frames,
                                    source: plan.sources[index], cap: plan.caps[index])
            placed.append(result)
            frames.append(result.bounds)
        }
        // Families: members are re-fitted at the family size (earlier frames, else all), kept when no larger and clear.
        let firstFits = placed.map(\.fontPixels)
        var sizes = plan.cohorts.map { V2Cohort.familySize(cap: plan.caps[$0[0]], fits: $0.map { placed[$0].fontPixels }) }
        // One page scale: every family takes the smallest family step.
        if let scale = zip(plan.cohorts, sizes).compactMap({ group, size in size.map { $0 / plan.caps[group[0]] } }).min() {
            sizes = zip(plan.cohorts, sizes).map { group, size in
                size.map { _ in max(min(plan.caps[group[0]], V2Cohort.minimumPixels), (plan.caps[group[0]] * scale * 4).rounded(.down) / 4) }
            }
        }
        for (cohort, family) in zip(plan.cohorts, sizes) {
            guard var size = family else { continue }
            // A re-fit can land below the family size; the family then follows its smallest member (3 more rounds).
            for round in 0..<4 {
                if round > 0 {
                    let reached = cohort.filter {
                        firstFits[$0] >= ((plan.caps[$0] * V2Cohort.steps.last!) * 4).rounded(.down) / 4 - 0.01
                    }.map { placed[$0].fontPixels }
                    guard let low = reached.min(), low < size - 0.01 else { break }
                    size = (low * 4).rounded(.down) / 4
                }
                for index in cohort where placed[index].fontPixels > size + 0.01 {
                    let others = frames.enumerated().compactMap { $0.offset != index ? $0.element : nil }
                    for context in [Array(frames[..<index]), others] {
                        let result = placeBlock(paintable[index], text: texts[index], page: page, obstacles: obstacles(index, context),
                                                placedFrames: context, source: plan.sources[index], cap: size)
                        if result.fontPixels <= placed[index].fontPixels, !intersectsAny(result.bounds, others) {
                            placed[index] = result
                            frames[index] = result.bounds
                            break
                        }
                    }
                }
            }
        }
        alignStarts(&placed, paintable, sources: plan.sources, page: page)
        // One alignment per cohort: the majority of its horizontal members (narration left, else centre).
        for cohort in plan.cohorts {
            let members = cohort.filter { !placed[$0].vertical }
            guard members.count > 1 else { continue }
            let left = members.filter { paintable[$0].role == .narration }.count
            let selected = left > members.count - left
            for index in members where (paintable[index].role == .narration) != selected { placed[index].leading = selected }
        }
        return placed
    }

    /// Shared start lines: chained upright blocks of one orientation and panel (tops within 0.75 em,
    /// under 5 em apart) share the median centred start on their least-spread axis, clamped to every
    /// member's balloon (else panel); a member that collides there keeps its frame.
    static func alignStarts(_ placed: inout [V2PlacedText], _ blocks: [V2Block], sources: [CGFloat], page: CGRect) {
        var parent = Array(blocks.indices)
        func root(_ index: Int) -> Int { parent[index] == index ? index : root(parent[index]) }
        for a in blocks.indices {
            for b in blocks.indices where b > a && blocks[a].vertical == blocks[b].vertical && blocks[a].panel == blocks[b].panel {
                let one = blocks[a].bounds, two = blocks[b].bounds, em = min(sources[a], sources[b])
                if abs(one.minY - two.minY) <= 0.75 * em, max(one.minX, two.minX) - min(one.maxX, two.maxX) < 5 * em {
                    parent[root(b)] = root(a)
                }
            }
        }
        for cluster in Dictionary(grouping: blocks.indices, by: root).values.sorted(by: { $0[0] < $1[0] }) {
                let group = cluster.filter { placed[$0].angle == nil }
            guard group.count >= 2 else { continue }
            let lefts = group.map { blocks[$0].bounds.minX }, tops = group.map { blocks[$0].bounds.minY }
            let top = lefts.max()! - lefts.min()! >= tops.max()! - tops.min()!
            func start(_ rect: CGRect) -> CGFloat { top ? rect.minY : rect.minX }
            func length(_ rect: CGRect) -> CGFloat { top ? rect.height : rect.width }
            let sourceStart = group.allSatisfy { blocks[$0].role == .narration && blocks[$0].balloon == nil }
            var members = group
            while members.count >= 2 {
                let anchor = V2Cohort.median(members.map { index in
                    let source = blocks[index].bounds
                    return start(source) + (sourceStart ? 0 : (length(source) - length(placed[index].frame)) / 2)
                })
                var low = start(page), high = start(page) + length(page)
                for index in members {
                    let box = (blocks[index].balloon?.insetBy(dx: -1, dy: -1) ?? blocks[index].panel ?? page).intersection(page)
                    low = max(low, start(box))
                    high = min(high, start(box) + length(box) - length(placed[index].frame))
                }
                guard low <= high else { break }
                var trial = placed
                for index in members {
                    if top { trial[index].frame.origin.y = min(high, max(low, anchor)) } else {
                        trial[index].frame.origin.x = min(high, max(low, anchor))
                    }
                }
                let colliding = members.filter { index in
                    intersectsAny(trial[index].bounds, trial.indices.filter { $0 != index }.map { trial[$0].bounds })
                }
                guard let far = colliding.max(by: { abs(start(placed[$0].frame) - anchor) < abs(start(placed[$1].frame) - anchor) })
                else { placed = trial; break }
                members.removeAll { $0 == far }
            }
        }
    }

    static func isPaintable(_ block: V2Block) -> Bool {
        guard block.role != .background, !V2RoleFilter.keepsSource(block), let text = block.translation else { return false }
        // As painted: markup-only text ("<br>", zero-width space) would erase the source and paint nothing.
        return !displayText(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Font

    struct FontMetrics: Sendable {
        let ascent: CGFloat
        let descent: CGFloat
    }

    static let referenceSize: CGFloat = 100

    /// The legacy overlay face: Apple SD Gothic Neo Medium; bold lettering takes the Heavy weight so the
    /// emphasis reads clearly against Medium (Bold was barely distinguishable).
    static func font(size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateWithName((bold ? "AppleSDGothicNeo-Heavy" : "AppleSDGothicNeo-Medium") as CFString, size, nil)
    }

    static func isBold(_ block: V2Block) -> Bool { block.style?.bold ?? false }

    static func metrics() -> FontMetrics {
        let font = font(size: referenceSize)
        return FontMetrics(ascent: CTFontGetAscent(font) / referenceSize, descent: CTFontGetDescent(font) / referenceSize)
    }

    static func strokeWidth(for block: V2Block, fontPixels: CGFloat) -> CGFloat {
        if let style = block.style {
            guard style.strokeColor != nil, style.strokeWidth.isFinite, style.strokeWidth > 0 else { return 0 }
            // The source outline keeps its proportion to the lettering when the size changes.
            let scaled = style.fontPixels > 0 ? style.strokeWidth * fontPixels / style.fontPixels : style.strokeWidth
            return min(max(scaled, fontPixels * 0.035), fontPixels * 0.25)
        }
        return max(1, fontPixels / 12)
    }

    // MARK: - Measured text

    /// Words shaped once at `referenceSize`; all widths are in reference units.
    struct MeasuredText {
        struct Word {
            var text: String
            var width: CGFloat
            /// Grapheme strings and cumulative caret offsets, for over-long words.
            var characters: [String]
            var offsets: [CGFloat]
        }
        var paragraphs: [[Word]]
        var spaceWidth: CGFloat
        var characterCount: Int
        /// Korean phrase coupling, no lone trailing syllable, no line-initial suffix mark.
        var strict = true
        /// Horizontal scale the widths were measured at (1, or the condense scale).
        var scale: CGFloat = 1

        init(_ text: String, font: CTFont) {
            func line(_ string: String) -> CTLine {
                CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font
                ]))
            }
            spaceWidth = CGFloat(CTLineGetTypographicBounds(line(" "), nil, nil, nil))
            var count = 0
            paragraphs = text.components(separatedBy: .newlines).compactMap { paragraph in
                let words = Self.glued(paragraph.split(whereSeparator: { $0.isWhitespace || $0 == "\u{200B}" }).map(String.init))
                guard !words.isEmpty else { return nil }
                return words.map { string in
                    let shaped = line(string)
                    var characters: [String] = []
                    var offsets: [CGFloat] = [0]
                    // Per-index caret queries are linear in the line, so long words read all carets in one pass.
                    let carets = string.utf16.count > Self.longWord ? Self.leadingCarets(shaped, length: string.utf16.count) : []
                    var location = 0
                    for character in string {
                        characters.append(String(character))
                        location += character.utf16.count
                        let caret = location < carets.count ? carets[location] : nil
                        offsets.append(caret ?? CTLineGetOffsetForStringIndex(shaped, location, nil))
                    }
                    count += characters.count
                    let width = CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil))
                    offsets[offsets.count - 1] = width
                    return Word(text: string, width: width, characters: characters, offsets: offsets)
                }
            }
            characterCount = count
        }

        /// Words longer than this (UTF-16 units) take their caret offsets from one enumeration.
        static let longWord = 256

        /// Punctuation that must not begin a line; ellipses may (Korean lines often open with one).
        static let closing: Set<Character> = Set("!?,.:;~)]}」』）】〉》〕〙〛’”。、，．！？：；～")
        static let ellipses: Set<Character> = Set("…‥·・")
        /// Suffix marks and dashes stay with the ink before them.
        static let suffixMarks: Set<Character> = Set("♡♥❤♪♫♬♩☆★※†‡—–―─")
        static let determiners: Set<String> = ["몇", "한", "두", "세", "네", "각", "모든", "어떤", "무슨", "이런", "그런", "저런",
                                               "이", "그", "저", "못", "안", "더", "덜", "잘", "꼭", "좀"]
        static let dependentNouns = ["것", "거", "게", "걸", "건", "수", "줄", "데", "뿐", "때", "듯", "적", "척", "만큼", "대로", "채", "바", "리"]

        /// Two characters of one Latin word or number (a digit next to its grouping or decimal mark).
        static func joinsLatinOrNumber(_ a: Character, _ b: Character) -> Bool {
            func word(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
            return (word(a) && word(b)) || (a.isNumber && ",.%".contains(b)) || (",.".contains(a) && b.isNumber)
        }

        /// Whether a break between `previous` and `next` would split a Korean phrase.
        static func couples(_ previous: String, _ next: String) -> Bool {
            if determiners.contains(previous) { return true }
            let stem = next.prefix { !closing.contains($0) && !ellipses.contains($0) }
            return dependentNouns.contains { stem.hasPrefix($0) && stem.count <= $0.count + 2 }
        }
        /// Punctuation that must not end a line (opening brackets and quotes).
        static let opening: Set<Character> = Set("([{「『（【〈《〔〘〚‘“")

        /// Joins a piece made only of punctuation to its neighbour (closing marks to the word
        /// before, opening marks to the word after) so a break never isolates it.
        static func glued(_ pieces: [String]) -> [String] {
            var result: [String] = []
            var pendingOpen: String?
            for piece in pieces {
                if piece.allSatisfy({ opening.contains($0) }) {
                    pendingOpen = pendingOpen.map { $0 + " " + piece } ?? piece
                    continue
                }
                let word = pendingOpen.map { $0 + " " + piece } ?? piece
                pendingOpen = nil
                let numeric = result.last.map { last in
                    last.allSatisfy { $0.isNumber || ",.%$".contains($0) } && word.count <= 3
                        && !word.contains { closing.contains($0) || ellipses.contains($0) }
                } ?? false
                if let last = result.last,
                   numeric || word.allSatisfy({ closing.contains($0) || ellipses.contains($0) || suffixMarks.contains($0) }) {
                    result[result.count - 1] = last + " " + word
                } else {
                    result.append(word)
                }
            }
            if let pendingOpen {
                if let last = result.last { result[result.count - 1] = last + " " + pendingOpen } else { result.append(pendingOpen) }
            }
            return result
        }

        /// Moves a split point off a bad break (closing mark first, opening mark last, ...): earlier when
        /// possible, else later; `end` is unchanged when neither helps.
        static func adjustedSplit(_ characters: [String], start: Int, end: Int, strict: Bool = true) -> Int {
            func bad(_ index: Int) -> Bool {
                guard index > start, index < characters.count else { return false }
                let next = characters[index].first.map { closing.contains($0) || (strict && suffixMarks.contains($0)) } ?? false
                let previous = characters[index - 1].last.map { opening.contains($0) } ?? false
                // Nor punctuation alone, nor a single trailing syllable of a word of three or more.
                let alone = characters[index...].allSatisfy { $0.allSatisfy { closing.contains($0) || ellipses.contains($0) } }
                let lone = strict && characters.count >= 3 && characters.count - index == 1
                let inside = strict && characters[index - 1].last.map { a in
                    characters[index].first.map { b in Self.joinsLatinOrNumber(a, b) } ?? false
                } ?? false
                return next || previous || alone || lone || inside
            }
            guard bad(end) else { return end }
            var candidate = end
            while bad(candidate), candidate - 1 > start { candidate -= 1 }
            if !bad(candidate) { return candidate }
            candidate = end
            while bad(candidate), candidate < characters.count { candidate += 1 }
            return bad(candidate) ? end : candidate
        }

        /// First leading-edge caret offset reported for each UTF-16 index of `line`.
        static func leadingCarets(_ line: CTLine, length: Int) -> [CGFloat?] {
            var carets = [CGFloat?](repeating: nil, count: length + 1)
            CTLineEnumerateCaretOffsets(line) { offset, index, leadingEdge, _ in
                if leadingEdge, index >= 0, index < carets.count, carets[index] == nil { carets[index] = offset }
            }
            return carets
        }

        /// The same words at `scale` horizontal width (arithmetic, no re-shaping).
        func condensed(by scale: CGFloat) -> MeasuredText {
            var copy = self
            copy.scale *= scale
            copy.spaceWidth *= scale
            copy.paragraphs = paragraphs.map { words in
                words.map { word in
                    var word = word
                    word.width *= scale
                    word.offsets = word.offsets.map { $0 * scale }
                    return word
                }
            }
            return copy
        }

        /// Widest single word, in reference units.
        var widestWord: CGFloat {
            paragraphs.lazy.flatMap { $0 }.map(\.width).max() ?? 0
        }

        /// Greedy word wrap with a limit (reference units) per line index; only over-long words split.
        func wrap(limits limit: (Int) -> CGFloat) -> (lines: [String], widest: CGFloat, widths: [CGFloat], split: Bool) {
            var widths: [CGFloat] = []
            var split = false
            var lines: [String] = []
            var widest: CGFloat = 0
            for paragraph in paragraphs {
                var current = ""
                var width: CGFloat = 0
                func flush() {
                    lines.append(current)
                    widths.append(width)
                    widest = max(widest, width)
                    current = ""
                    width = 0
                }
                var last: Word?
                var lastStart = ""
                var lastStartWidth: CGFloat = 0
                for word in paragraph {
                    defer { last = word }
                    if !current.isEmpty, width + spaceWidth + word.width <= limit(lines.count) {
                        lastStart = current
                        lastStartWidth = width
                        current += " " + word.text
                        width += spaceWidth + word.width
                        continue
                    }
                    // Korean phrase coupling: carry the previous word down when the pair fits a line.
                    if strict, let previous = last, current != previous.text, current.hasSuffix(" " + previous.text),
                       Self.couples(previous.text, word.text), previous.width + spaceWidth + word.width <= limit(lines.count + 1) {
                        current = lastStart
                        width = lastStartWidth
                        flush()
                        current = previous.text + " " + word.text
                        width = previous.width + spaceWidth + word.width
                        lastStart = previous.text
                        lastStartWidth = previous.width
                        continue
                    }
                    if !current.isEmpty { flush() }
                    lastStart = ""
                    lastStartWidth = 0
                    if word.width <= limit(lines.count) {
                        current = word.text
                        width = word.width
                        continue
                    }
                    // Over-long word: split between graphemes, at least one per line.
                    split = true
                    var start = 0
                    while start < word.characters.count {
                        var end = start + 1
                        while end < word.characters.count, word.offsets[end + 1] - word.offsets[start] <= limit(lines.count) { end += 1 }
                        end = Self.adjustedSplit(word.characters, start: start, end: end, strict: strict)
                        current = word.characters[start..<end].joined()
                        width = word.offsets[end] - word.offsets[start]
                        if end < word.characters.count { flush() }
                        start = end
                    }
                }
                if !current.isEmpty { flush() }
            }
            return (lines, widest, widths, split)
        }

        /// Vertical columns of `cells` characters; words split only when longer. A space is half a cell.
        func columns(cells: Int) -> [String] {
            guard cells > 0 else { return [] }
            var result: [String] = []
            for paragraph in paragraphs {
                var current: [String] = []
                var used: CGFloat = 0
                for word in paragraph {
                    let length = CGFloat(word.characters.count)
                    if !current.isEmpty, used + 0.5 + length <= CGFloat(cells) {
                        current.append(" ")
                        current.append(contentsOf: word.characters)
                        used += 0.5 + length
                        continue
                    }
                    if !current.isEmpty { result.append(current.joined()); current = []; used = 0 }
                    var start = 0
                    while word.characters.count - start > cells {
                        let end = Self.adjustedSplit(word.characters, start: start, end: start + cells, strict: strict)
                        result.append(word.characters[start..<end].joined())
                        start = end
                    }
                    current = Array(word.characters[start...])
                    used = CGFloat(current.count)
                }
                if !current.isEmpty { result.append(current.joined()) }
            }
            return result
        }
    }

    struct Fit {
        var size: CGFloat
        var lines: [String]
        /// Text block extent, excluding stroke.
        var extent: CGSize
        var vertical: Bool
        /// Measured with the 0.9 horizontal condense.
        var condensed = false
    }

    static func horizontalFit(_ text: MeasuredText, size: CGFloat, width: CGFloat) -> Fit {
        let scale = size / referenceSize
        let limit = max(width * widthSlack, 1) / scale
        let wrapped = text.wrap(limits: { _ in limit })
        let extent = CGSize(width: wrapped.widest * scale, height: (CGFloat(wrapped.lines.count - 1) * lineHeightEm + inkHeightEm) * size)
        return Fit(size: size, lines: wrapped.lines, extent: extent, vertical: false)
    }

    static func verticalFit(_ text: MeasuredText, size: CGFloat, height: CGFloat) -> Fit {
        let cells = max(1, Int(height / (size * verticalAdvanceEm)))
        let columns = text.columns(cells: cells)
        let longest = columns.map { CGFloat($0.count) }.max() ?? 0
        // Columns advance by the line height; the last one only needs its 1 em glyph width.
        let extent = CGSize(width: columns.isEmpty ? 0 : (CGFloat(columns.count - 1) * lineHeightEm + 1) * size,
                            height: longest * size * verticalAdvanceEm)
        return Fit(size: size, lines: columns, extent: extent, vertical: true)
    }

    private static func fits(_ fit: Fit, in box: CGSize) -> Bool {
        fit.extent.width <= box.width + 0.01 && fit.extent.height <= box.height + 0.01 && !fit.lines.isEmpty
    }

    /// Largest quarter-pixel size in [minimum, maximum] that fits, or nil.
    static func largestFit(_ text: MeasuredText, box: CGSize, vertical: Bool, minimum: CGFloat, maximum: CGFloat) -> Fit? {
        func probe(_ size: CGFloat) -> Fit {
            vertical ? verticalFit(text, size: size, height: box.height) : horizontalFit(text, size: size, width: box.width)
        }
        guard let size = NativeTranslationFontFitSearch.largestFitting(
            minimum: minimum, maximum: max(minimum, maximum), fits: { fits(probe($0), in: box) }
        ) else { return nil }
        return probe(size)
    }

    // MARK: - Boxes

    /// Grows `original` to `expanded`, stopping each side at obstacles entirely on that side.
    static func clipExpansion(original: CGRect, expanded: CGRect, obstacles: [CGRect]) -> CGRect {
        var minX = expanded.minX, maxX = expanded.maxX, minY = expanded.minY, maxY = expanded.maxY
        for obstacle in obstacles where !obstacle.isNull && obstacle.intersects(expanded)
            && !obstacle.intersects(original) {
            let candidate = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard obstacle.intersects(candidate) else { continue }
            // Cut the side that loses the least area.
            var options: [(CGFloat, Int)] = []
            if obstacle.minX >= original.maxX { options.append(((maxX - obstacle.minX) * (maxY - minY), 0)) }
            if obstacle.maxX <= original.minX { options.append(((obstacle.maxX - minX) * (maxY - minY), 1)) }
            if obstacle.minY >= original.maxY { options.append(((maxY - obstacle.minY) * (maxX - minX), 2)) }
            if obstacle.maxY <= original.minY { options.append(((obstacle.maxY - minY) * (maxX - minX), 3)) }
            guard let side = options.min(by: { $0.0 < $1.0 })?.1 else { continue }
            switch side {
            case 0: maxX = min(maxX, obstacle.minX)
            case 1: minX = max(minX, obstacle.maxX)
            case 2: maxY = min(maxY, obstacle.minY)
            default: minY = max(minY, obstacle.maxY)
            }
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    static func sourcePixels(_ block: V2Block) -> CGFloat {
        if let size = block.style?.fontPixels, size.isFinite, size > 0 { return size }
        // Fallback: line thickness (column width or row height) is about 1.1 em.
        let thickness = block.lines.map { block.vertical ? $0.bounds.width : $0.bounds.height }.sorted()
        if !thickness.isEmpty { return max(floorPixels, thickness[thickness.count / 2] / 1.1) }
        return max(floorPixels, min(block.bounds.width, block.bounds.height) / 3)
    }

    static func targetBox(_ block: V2Block, page: CGRect, source: CGFloat, obstacles: [CGRect]) -> CGRect {
        let bounds = block.bounds.intersection(page)
        if let balloon = block.balloon?.intersection(page), !balloon.isNull,
           balloon.width >= 8, balloon.height >= 8 {
            // Interior is already inside the outline; keep a 4% breathing inset.
            let inset = min(balloon.width, balloon.height) * 0.04
            return balloon.insetBy(dx: inset, dy: inset)
        }
        let base = bounds.isNull ? CGRect(x: page.midX, y: page.midY, width: 1, height: 1) : bounds
        let margin = min(24, max(4, source * marginRatio))
        let expanded = base.insetBy(dx: -margin, dy: -margin).intersection(page)
        return clipExpansion(original: base, expanded: expanded, obstacles: obstacles)
    }

    // MARK: - Display text

    /// The translation as painted: provider line-break markup becomes a space, spaces collapse, a
    /// long-vowel mark after Hangul becomes a tilde and a stray sokuon is dropped; newlines stay.
    static func displayText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value >= 0x80 || $0 == "<" || $0 == "|" }) else { return text }
        var result = text.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        let hangul = result.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        result = String(String.UnicodeScalarView(result.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.value {
            case 0x2028, 0x2029, 0x200B, 0x2800, 0xFEFF: " "
            case 0x7C where hangul: " "
            default: scalar
            }
        }))
        if hangul {
            result = result.replacingOccurrences(of: "(?<=[가-힣])[ーｰ]+", with: "~", options: .regularExpression)
            // A slash marking a source line break ("중에/숨기고"); kept next to Latin letters or digits ("1/2").
            result = result.replacingOccurrences(of: "(?<![A-Za-z0-9] ?)/(?! ?[A-Za-z0-9])", with: " ", options: .regularExpression)
            let kana = result.unicodeScalars.filter { (0x3040...0x30FF).contains($0.value) }
            if !kana.isEmpty, kana.allSatisfy({ $0 == "っ" || $0 == "ッ" }) {
                result = result.replacingOccurrences(of: "[っッ]", with: "", options: .regularExpression)
            }
        }
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return result.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    // MARK: - Per block

    private static func measured(_ block: V2Block) -> MeasuredText {
        MeasuredText(displayText(V2TranslationLengthCap.capped(block.translation ?? "", sourceText: block.sourceText)),
                     font: font(size: referenceSize, bold: isBold(block)))
    }

    private static func placeBlock(_ block: V2Block, text: MeasuredText, page: CGRect, obstacles: [CGRect],
                                   placedFrames: [CGRect], source: CGFloat, cap: CGFloat) -> V2PlacedText {
        let target = targetBox(block, page: page, source: source, obstacles: obstacles)

        func strokeInset(_ size: CGFloat) -> CGFloat { strokeWidth(for: block, fontPixels: size) }
        var loose = text
        loose.strict = false
        var active = text
        func fit(in box: CGRect) -> Fit? {
            var chosen = fit(in: box, text: text), base = text
            if let strictSize = chosen?.size, let relaxed = fit(in: box, text: loose),
               !(strictSize >= relaxed.size * strictRuleRatio) {
                chosen = relaxed
                base = loose
            }
            active = chosen?.condensed == true ? base.condensed(by: condenseScale) : base
            return chosen
        }
        func fit(in box: CGRect, text: MeasuredText) -> Fit? {
            let inset = strokeInset(cap)
            var inner = CGSize(width: max(1, box.width - 2 * inset), height: max(1, box.height - 2 * inset))
            // A tall paragraph in a balloon is not flattened (lines within 1.35x the source width).
            if block.balloon != nil, block.bounds.height >= block.bounds.width * 1.4 {
                inner.width = min(inner.width, max(block.bounds.width * 1.35, cap * 3.5, text.widestWord * cap / referenceSize))
            }
            guard var horizontal = largestFit(text, box: inner, vertical: false, minimum: floorPixels, maximum: cap) else {
                return verticalOption(in: inner, horizontal: nil, text: text)
            }
            // Prefer whole words unless that costs much more than splitting.
            let widest = text.widestWord
            if widest > 0, horizontal.lines.count > 1 {
                let whole = inner.width * widthSlack * referenceSize / widest
                if whole < horizontal.size, whole >= max(floorPixels, horizontal.size * wholeWordRatio),
                   let unsplit = largestFit(text, box: inner, vertical: false, minimum: floorPixels, maximum: whole) {
                    horizontal = unsplit
                } else if whole < horizontal.size, whole / condenseScale >= max(floorPixels, horizontal.size * wholeWordRatio) {
                    // Before splitting: the same words narrowed to 0.9 width.
                    let narrow = text.condensed(by: condenseScale)
                    if var unsplit = largestFit(narrow, box: inner, vertical: false, minimum: floorPixels,
                                                maximum: min(horizontal.size, whole / condenseScale)) {
                        unsplit.condensed = true
                        horizontal = unsplit
                    }
                }
            }
            return verticalOption(in: inner, horizontal: horizontal, text: text) ?? horizontal
        }
        // A vertical source switches to columns when the horizontal fit degenerated into a stack,
        // or in a very tall, narrow box where horizontal would be < 2/3 the vertical size.
        func verticalOption(in inner: CGSize, horizontal: Fit?, text: MeasuredText) -> Fit? {
            guard block.vertical, inner.height >= inner.width * 1.5 else { return nil }
            let stacked = horizontal.map(isStacked) ?? false
            guard stacked || (inner.height >= inner.width * 3 && text.characterCount <= 24) else { return nil }
            guard let vertical = largestFit(text, box: inner, vertical: true, minimum: floorPixels, maximum: cap) else {
                return nil
            }
            if let horizontal {
                if stacked ? vertical.size < horizontal.size * stackedVerticalRatio : horizontal.size * 1.5 >= vertical.size {
                    return nil
                }
            }
            return vertical
        }

        // Only the part of the box that earlier frames leave free.
        let start = carve(target, around: placedFrames, page: page)
        var box = start
        var chosen = fit(in: box)
        if chosen == nil {
            let bounds = block.bounds.intersection(page)
            let anchor = start != target || bounds.isNull ? start : bounds
            for step in 1...6 {
                let dx = start.width * 0.2 * CGFloat(step) + source * CGFloat(step)
                let dy = start.height * 0.1 * CGFloat(step)
                let expanded = start.insetBy(dx: -dx, dy: -dy).intersection(block.panel.map { $0.union(start) } ?? page)
                    .intersection(page)
                box = clipExpansion(original: anchor, expanded: expanded, obstacles: obstacles).union(start)
                if let found = fit(in: box) { chosen = found; break }
            }
        }
        var fitted: Fit
        if let chosen {
            fitted = compact(chosen, text: active, box: box, stroke: strokeInset(chosen.size), sourceHeight: block.bounds.height)
        } else {
            // Floor size, allowed to overflow the grown box vertically.
            let inset = strokeInset(floorPixels)
            var size = floorPixels
            var candidate = horizontalFit(active, size: size, width: max(1, box.width - 2 * inset))
            var guardCount = 0
            while candidate.extent.height + 2 * inset > page.height || candidate.extent.width + 2 * inset > page.width,
                  guardCount < 6 {
                size /= 2
                candidate = horizontalFit(active, size: size, width: min(page.width, max(box.width, page.width / 2)))
                guardCount += 1
            }
            fitted = candidate
        }

        var current = fitted
        let anchor = CGPoint(x: block.bounds.midX, y: block.bounds.midY)
        var frame = frameFor(current, in: box, stroke: strokeInset(current.size), page: page, anchor: anchor)
        // Rounded balloon: lines as wide as the clean row spans allow, when that is >= 3% larger.
        var shaped = false
        if let rows = block.rows, !fitted.vertical, box == target, target == start {
            let whole = active.widestWord * fitted.size / referenceSize <= (box.width - 2 * strokeInset(fitted.size)) * widthSlack
            func probe(_ size: CGFloat) -> (fit: Fit, top: CGFloat)? {
                spanFit(active, size: size, rows: rows, centreY: anchor.y, stroke: strokeInset(size), whole: whole)
            }
            if let size = NativeTranslationFontFitSearch.largestFitting(minimum: fitted.size * 1.03, maximum: cap,
                                                                         fits: { probe($0) != nil }),
               let found = probe(size) {
                let stroke = strokeInset(size)
                let candidate = CGRect(x: rows.centre - found.fit.extent.width / 2 - stroke, y: found.top - stroke,
                                       width: found.fit.extent.width + 2 * stroke, height: found.fit.extent.height + 2 * stroke)
                if page.contains(candidate.insetBy(dx: 0.5, dy: 0.5)), !intersectsAny(candidate, placedFrames) {
                    current = found.fit
                    fitted = found.fit
                    frame = candidate
                    shaped = true
                }
            }
        }
        if !shaped, intersectsAny(frame, placedFrames) {
            // Bounded overlap resolution: alternate anchors in the box, then shrink.
            var resolved = false
            for attempt in 0...4 {
                if attempt > 0 {
                    let size = max(min(floorPixels, current.size), current.size * 0.85)
                    guard size < current.size else { break }
                    current = current.vertical ? verticalFit(active, size: size, height: box.height)
                        : horizontalFit(active, size: size, width: box.width - 2 * strokeInset(size))
                }
                let stroke = strokeInset(current.size)
                if let free = alignedFrames(current, in: box, stroke: stroke, page: page)
                    .first(where: { !intersectsAny($0, placedFrames) }) {
                    frame = free
                    resolved = true
                    break
                }
            }
            if !resolved {
                current = fitted
                frame = frameFor(current, in: box, stroke: strokeInset(current.size), page: page, anchor: anchor)
            }
        }
        var placed = V2PlacedText(blockID: block.id, frame: frame, fontPixels: current.size,
                                  vertical: current.vertical, lines: current.lines,
                                  condense: !current.vertical && active.scale != 1 ? active.scale : nil)
        // Tilted source: the text at the source tilt when that costs <= 10% of the size and stays clear.
        let angle = shaped ? 0 : V2Rotation.angle(block)
        if angle != 0, !current.vertical {
            let stroke = strokeInset(current.size)
            let inner = CGSize(width: box.width - 2 * stroke, height: box.height - 2 * stroke)
            let capInset = strokeInset(cap)
            if let room = V2Rotation.inscribed(inner, angle: angle),
               let found = fit(in: CGRect(x: 0, y: 0, width: room.width + 2 * capInset, height: room.height + 2 * capInset)),
               !found.vertical, found.size <= current.size + 0.01, found.size >= current.size * rotationSizeRatio {
                let tilted = compact(found, text: active, box: CGRect(origin: .zero, size: room), stroke: 0,
                                     sourceHeight: block.bounds.height)
                let pad = 2 * strokeInset(tilted.size)
                let text = CGSize(width: tilted.extent.width + pad, height: tilted.extent.height + pad)
                let outer = V2Rotation.bounds(CGRect(origin: .zero, size: text), angle: angle)
                let shell = Fit(size: tilted.size, lines: tilted.lines, extent: outer.size, vertical: false)
                let rotatedBounds = frameFor(shell, in: box, stroke: 0, page: page, anchor: anchor)
                if !intersectsAny(rotatedBounds, placedFrames), page.contains(rotatedBounds.insetBy(dx: 0.5, dy: 0.5)) {
                    placed = V2PlacedText(blockID: block.id,
                                          frame: CGRect(x: rotatedBounds.midX - text.width / 2,
                                                        y: rotatedBounds.midY - text.height / 2,
                                                        width: text.width, height: text.height),
                                          fontPixels: tilted.size, vertical: false, lines: tilted.lines, angle: angle,
                                          condense: active.scale != 1 ? active.scale : nil)
                }
            }
        }
        return placed
    }

    /// Largest remaining strip of `box` beside each intersecting frame; a covered box moves beside it.
    static func carve(_ box: CGRect, around frames: [CGRect], page: CGRect) -> CGRect {
        var result = box
        for frame in frames {
            let overlap = result.intersection(frame)
            guard !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 else { continue }
            // Raw extents: CGRect.width/height standardize negative strips.
            let strips: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (result.minX, result.minY, frame.minX - result.minX, result.height),
                (frame.maxX, result.minY, result.maxX - frame.maxX, result.height),
                (result.minX, result.minY, result.width, frame.minY - result.minY),
                (result.minX, frame.maxY, result.width, result.maxY - frame.maxY)
            ]
            let candidates = strips.filter { $0.2 > 0 && $0.3 > 0 }.map { CGRect(x: $0.0, y: $0.1, width: $0.2, height: $0.3) }
            if let best = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                result = best
                continue
            }
            let size = result.size
            let beside = [
                CGRect(x: frame.maxX, y: result.minY, width: size.width, height: size.height),
                CGRect(x: frame.minX - size.width, y: result.minY, width: size.width, height: size.height),
                CGRect(x: result.minX, y: frame.maxY, width: size.width, height: size.height),
                CGRect(x: result.minX, y: frame.minY - size.height, width: size.width, height: size.height)
            ].map { clamp($0, page: page) }.filter { !intersectsAny($0, frames) }
            func distance(_ rect: CGRect) -> CGFloat { hypot(rect.midX - box.midX, rect.midY - box.midY) }
            if let nearest = beside.min(by: { distance($0) < distance($1) }) { result = nearest }
        }
        return result
    }

    private static func intersectsAny(_ rect: CGRect, _ others: [CGRect]) -> Bool {
        others.contains { other in
            let overlap = rect.intersection(other)
            return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
        }
    }

    /// Text frame (with stroke) centred on `anchor` (default: box centre), kept in the box and page.
    static func frameFor(_ fit: Fit, in box: CGRect, stroke: CGFloat, page: CGRect, anchor: CGPoint? = nil) -> CGRect {
        let size = CGSize(width: fit.extent.width + 2 * stroke, height: fit.extent.height + 2 * stroke)
        let centre = anchor ?? CGPoint(x: box.midX, y: box.midY)
        func axis(_ centre: CGFloat, _ length: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            let start = centre - length / 2
            guard length <= high - low else { return (low + high - length) / 2 }
            return min(max(start, low), high - length)
        }
        let margin = min(12, max(2, (fit.size * 0.12).rounded(.up)))
        let inner = page.insetBy(dx: margin, dy: margin)
        let edge = inner.width >= size.width && inner.height >= size.height ? inner : page
        return clamp(CGRect(x: axis(centre.x, size.width, box.minX, box.maxX),
                            y: axis(centre.y, size.height, box.minY, box.maxY),
                            width: size.width, height: size.height), page: edge)
    }

    /// Horizontal fit at `size` whose lines may be as wide as the row spans at their height, centred
    /// on `centreY`; nil when no line count fits (or a word would split and `whole`).
    static func spanFit(_ text: MeasuredText, size: CGFloat, rows: V2RowSpans, centreY: CGFloat, stroke: CGFloat,
                        whole: Bool) -> (fit: Fit, top: CGFloat)? {
        let pitch = size * lineHeightEm, ink = size * inkHeightEm, scale = size / referenceSize
        let most = Int((rows.bottom - rows.top - 2 * stroke - ink) / pitch) + 1
        guard most >= 1, scale > 0 else { return nil }
        for count in 1...min(most, 40) {
            let height = CGFloat(count - 1) * pitch + ink
            let top = min(max(centreY - height / 2, rows.top + stroke), rows.bottom - stroke - height)
            let halves = (0..<count).map { line in
                rows.halfWidth(top + CGFloat(line) * pitch - stroke, top + CGFloat(line) * pitch + ink + stroke) - stroke
            }
            let wrapped = text.wrap(limits: { line in line < count ? max(0, 2 * halves[line] * widthSlack / scale) : 0 })
            guard wrapped.lines.count == count, !(whole && wrapped.split),
                  zip(wrapped.widths, halves).allSatisfy({ $0 * scale <= 2 * $1 + 0.01 }) else { continue }
            return (Fit(size: size, lines: wrapped.lines, extent: CGSize(width: wrapped.widest * scale, height: height),
                        vertical: false), top)
        }
        return nil
    }

    /// The narrowest same-size wrap no taller than the source (or the fit) that fits the box, so a
    /// grown box does not spread the text into long lines.
    static func compact(_ fit: Fit, text: MeasuredText, box: CGRect, stroke: CGFloat, sourceHeight: CGFloat) -> Fit {
        guard !fit.vertical, fit.lines.count >= 2 else { return fit }
        let scale = fit.size / referenceSize
        let maxHeight = min(box.height - 2 * stroke, max(sourceHeight, fit.extent.height))
        let whole = text.widestWord * scale / widthSlack
        // The narrowest wrap wins unless one at most 1.15x wider has fewer bad breaks.
        var wraps = [fit]
        while wraps.count < 64, let last = wraps.last {
            let width = last.extent.width / widthSlack - 0.05
            guard width >= whole else { break }
            let next = horizontalFit(text, size: fit.size, width: width)
            guard next.extent.height <= maxHeight + 0.01 else { break }
            wraps.append(next)
        }
        let narrowest = wraps[wraps.count - 1], limit = narrowest.extent.width * compactBreakWidth + 0.01
        return wraps.reversed().filter { $0.extent.width <= limit }
            .min { badBreaks($0.lines) < badBreaks($1.lines) } ?? narrowest
    }

    /// Lines of one bare grapheme plus breaks that split a Korean phrase.
    static func badBreaks(_ lines: [String]) -> Int {
        guard lines.count > 1 else { return 0 }
        return lines.filter { $0.count == 1 && $0.allSatisfy(\.isLetter) }.count + zip(lines, lines.dropFirst()).filter { a, b in
            guard let last = a.split(separator: " ").last, let first = b.split(separator: " ").first else { return false }
            return MeasuredText.couples(String(last), String(first))
        }.count
    }

    private static func alignedFrames(_ fit: Fit, in box: CGRect, stroke: CGFloat, page: CGRect) -> [CGRect] {
        let centred = frameFor(fit, in: box, stroke: stroke, page: page)
        let width = centred.width, height = centred.height
        let candidates = [
            centred,
            CGRect(x: centred.minX, y: box.minY, width: width, height: height),
            CGRect(x: centred.minX, y: box.maxY - height, width: width, height: height),
            CGRect(x: box.minX, y: centred.minY, width: width, height: height),
            CGRect(x: box.maxX - width, y: centred.minY, width: width, height: height)
        ]
        return candidates.map { clamp($0, page: page) }
    }

    static func clamp(_ rect: CGRect, page: CGRect) -> CGRect {
        let width = min(rect.width, page.width), height = min(rect.height, page.height)
        let x = min(max(rect.minX, page.minX), page.maxX - width)
        let y = min(max(rect.minY, page.minY), page.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
