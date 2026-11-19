import CoreGraphics
import CoreText
import Foundation

// S9: single bounded layout pass for translated blocks (see Docs/translation-v2.md).
// For every block: choose a target box (balloon interior, else block bounds plus a
// small margin that never grows into a neighbour), choose orientation, binary-search
// the largest Core Text size whose word-wrapped text fits, and centre it. A block is
// never refused: below the 10 px floor the box grows into free space, and as a last
// resort the text overflows its box (still clamped inside the page).
//
// Cost model: every word is shaped once at a reference size and widths are scaled
// linearly, so each fit probe is pure arithmetic. The work per block is bounded by
// one binary search (<= 12 probes), at most 6 growth steps and at most 4 overlap
// shrink steps; there are no retries, DFS or recovery passes.
enum V2Layout {
    static let fontName = "AidokuSerifKR-Bold"
    /// Smallest size the fit search may choose before the box is allowed to grow.
    static let floorPixels: CGFloat = 10
    /// Tunables (defaults selected on dev; see the out-of-repo research scripts (scripts-layout)).
    struct Options: Sendable {
        /// Upper bound of the fit search relative to the measured source lettering size.
        var capRatio: CGFloat = 1.2
        /// Margin added around block bounds, relative to source px (clamped 4...24 px).
        var marginRatio: CGFloat = 0.2
    }
    /// Line advance in em; matches the legacy renderer's Korean line height (1.18 em).
    static let lineHeightEm: CGFloat = 1.18
    /// Vertical cell advance per character, in em.
    static let verticalAdvanceEm: CGFloat = 1.02
    /// Fraction of the box width used for wrapping, leaving room for kerning drift.
    static let widthSlack: CGFloat = 0.97

    struct Diagnostic: Sendable, Equatable {
        var blockID: Int
        /// Box the text was fitted into (after any growth).
        var box: CGRect
        /// Box before growth (balloon interior or margin-expanded bounds).
        var targetBox: CGRect
        var usedBalloon: Bool
        var grew: Bool
        var overflowed: Bool
        var shrunkForOverlap: Bool
        var overlapsPlaced: Bool
        var sourcePixels: CGFloat
    }

    // MARK: - Contract

    static func place(_ blocks: [V2Block], pageSize: CGSize) -> [V2PlacedText] {
        placeWithDiagnostics(blocks, pageSize: pageSize).placed
    }

    static func placeWithDiagnostics(_ blocks: [V2Block], pageSize: CGSize, options: Options = Options())
        -> (placed: [V2PlacedText], diagnostics: [Diagnostic]) {
        let page = CGRect(origin: .zero, size: pageSize)
        guard page.width >= 1, page.height >= 1 else { return ([], []) }
        let paintable = blocks.filter(isPaintable).sorted {
            ($0.readingOrder, $0.id) < ($1.readingOrder, $1.id)
        }
        let sourceBounds = paintable.map { $0.bounds.intersection(page) }
        var placed: [V2PlacedText] = []
        var diagnostics: [Diagnostic] = []
        var frames: [CGRect] = []
        for (index, block) in paintable.enumerated() {
            var obstacles = frames
            for (other, rect) in sourceBounds.enumerated() where other != index && !rect.isNull {
                obstacles.append(rect)
            }
            let result = placeBlock(block, page: page, obstacles: obstacles, placedFrames: frames, options: options)
            placed.append(result.0)
            diagnostics.append(result.1)
            frames.append(result.0.frame)
        }
        return (placed, diagnostics)
    }

    static func isPaintable(_ block: V2Block) -> Bool {
        guard block.role != .background, let text = block.translation else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Font

    struct FontMetrics: Sendable {
        let ascent: CGFloat
        let descent: CGFloat
    }

    private static let registration: Bool = {
        func registered() -> Bool {
            CTFontCopyPostScriptName(CTFontCreateWithName(fontName as CFString, 12, nil)) as String == fontName
        }
        if registered() { return true }
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: fontName, withExtension: "woff2") { urls.append(url) }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root)
                .appendingPathComponent("Aidoku/Resources/Translation/\(fontName).woff2"))
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) || registered() { return true }
        }
        return registered()
    }()

    /// Registers the bundled face from an explicit file (host/test harnesses).
    @discardableResult
    static func registerFont(at url: URL) -> Bool {
        if isBundledFontAvailable { return true }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return CTFontCopyPostScriptName(CTFontCreateWithName(fontName as CFString, 12, nil)) as String == fontName
    }

    static var isBundledFontAvailable: Bool {
        registration || CTFontCopyPostScriptName(CTFontCreateWithName(fontName as CFString, 12, nil)) as String == fontName
    }

    static let referenceSize: CGFloat = 100

    /// Bundled serif when registered, otherwise a system Korean bold face.
    static func font(size: CGFloat) -> CTFont {
        let name = isBundledFontAvailable ? fontName : "AppleSDGothicNeo-Bold"
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    static func metrics() -> FontMetrics {
        let font = font(size: referenceSize)
        return FontMetrics(ascent: CTFontGetAscent(font) / referenceSize, descent: CTFontGetDescent(font) / referenceSize)
    }

    static func strokeWidth(for block: V2Block, fontPixels: CGFloat) -> CGFloat {
        if let style = block.style {
            guard style.strokeColor != nil, style.strokeWidth.isFinite, style.strokeWidth > 0 else { return 0 }
            return min(style.strokeWidth, fontPixels * 0.25)
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

        init(_ text: String, font: CTFont) {
            func line(_ string: String) -> CTLine {
                CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font
                ]))
            }
            spaceWidth = CGFloat(CTLineGetTypographicBounds(line(" "), nil, nil, nil))
            var count = 0
            paragraphs = text.components(separatedBy: .newlines).compactMap { paragraph in
                let words = paragraph.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })
                guard !words.isEmpty else { return nil }
                return words.map { piece in
                    let string = String(piece)
                    let shaped = line(string)
                    var characters: [String] = []
                    var offsets: [CGFloat] = [0]
                    var index = string.startIndex
                    for character in string {
                        characters.append(String(character))
                        index = string.index(after: index)
                        let location = string.utf16.distance(from: string.utf16.startIndex, to: index)
                        offsets.append(CTLineGetOffsetForStringIndex(shaped, location, nil))
                    }
                    count += characters.count
                    let width = CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil))
                    offsets[offsets.count - 1] = width
                    return Word(text: string, width: width, characters: characters, offsets: offsets)
                }
            }
            characterCount = count
        }

        /// Greedy word wrap at `limit` reference units: breaks only at spaces unless a
        /// single word is wider than the line, which is then split between graphemes.
        func wrap(limit: CGFloat) -> (lines: [String], widest: CGFloat) {
            var lines: [String] = []
            var widest: CGFloat = 0
            for paragraph in paragraphs {
                var current = ""
                var width: CGFloat = 0
                func flush() {
                    lines.append(current)
                    widest = max(widest, width)
                    current = ""
                    width = 0
                }
                for word in paragraph {
                    if !current.isEmpty, width + spaceWidth + word.width <= limit {
                        current += " " + word.text
                        width += spaceWidth + word.width
                        continue
                    }
                    if !current.isEmpty { flush() }
                    if word.width <= limit {
                        current = word.text
                        width = word.width
                        continue
                    }
                    // Over-long word: split between graphemes, at least one per line.
                    var start = 0
                    while start < word.characters.count {
                        var end = start + 1
                        while end < word.characters.count, word.offsets[end + 1] - word.offsets[start] <= limit { end += 1 }
                        current = word.characters[start..<end].joined()
                        width = word.offsets[end] - word.offsets[start]
                        if end < word.characters.count { flush() }
                        start = end
                    }
                }
                if !current.isEmpty { flush() }
            }
            return (lines, widest)
        }

        /// Vertical columns: each column holds `cells` characters; words never split
        /// unless longer than a column. A space costs half a cell.
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
                    var remaining = word.characters[...]
                    while remaining.count > cells {
                        result.append(remaining.prefix(cells).joined())
                        remaining = remaining.dropFirst(cells)
                    }
                    current = Array(remaining)
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
    }

    static func horizontalFit(_ text: MeasuredText, size: CGFloat, width: CGFloat) -> Fit {
        let scale = size / referenceSize
        let wrapped = text.wrap(limit: max(width * widthSlack, 1) / scale)
        let extent = CGSize(width: wrapped.widest * scale, height: CGFloat(wrapped.lines.count) * size * lineHeightEm)
        return Fit(size: size, lines: wrapped.lines, extent: extent, vertical: false)
    }

    static func verticalFit(_ text: MeasuredText, size: CGFloat, height: CGFloat) -> Fit {
        let cells = max(1, Int(height / (size * verticalAdvanceEm)))
        let columns = text.columns(cells: cells)
        let longest = columns.map { CGFloat($0.count) }.max() ?? 0
        let extent = CGSize(width: CGFloat(columns.count) * size * lineHeightEm, height: longest * size * verticalAdvanceEm)
        return Fit(size: size, lines: columns, extent: extent, vertical: true)
    }

    private static func fits(_ fit: Fit, in box: CGSize) -> Bool {
        fit.extent.width <= box.width + 0.01 && fit.extent.height <= box.height + 0.01 && !fit.lines.isEmpty
    }

    /// Largest quarter-pixel size in [minimum, maximum] that fits, or nil.
    static func largestFit(_ text: MeasuredText, box: CGSize, vertical: Bool,
                           minimum: CGFloat, maximum: CGFloat) -> Fit? {
        func probe(_ size: CGFloat) -> Fit {
            vertical ? verticalFit(text, size: size, height: box.height) : horizontalFit(text, size: size, width: box.width)
        }
        guard let size = NativeTranslationFontFitSearch.largestFitting(
            minimum: minimum, maximum: max(minimum, maximum), fits: { fits(probe($0), in: box) }
        ) else { return nil }
        return probe(size)
    }

    // MARK: - Boxes

    /// Grows `original` to `expanded` but stops each side at obstacles lying
    /// entirely on that side of `original`; obstacles already overlapping it are ignored.
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

    static func targetBox(_ block: V2Block, page: CGRect, source: CGFloat, marginRatio: CGFloat,
                          obstacles: [CGRect]) -> (CGRect, Bool) {
        let bounds = block.bounds.intersection(page)
        if let balloon = block.balloon?.intersection(page), !balloon.isNull,
           balloon.width >= 8, balloon.height >= 8 {
            // Interior is already inside the outline; keep a 4% breathing inset.
            let inset = min(balloon.width, balloon.height) * 0.04
            return (balloon.insetBy(dx: inset, dy: inset), true)
        }
        let base = bounds.isNull ? CGRect(x: page.midX, y: page.midY, width: 1, height: 1) : bounds
        let margin = min(24, max(4, source * marginRatio))
        let expanded = base.insetBy(dx: -margin, dy: -margin).intersection(page)
        return (clipExpansion(original: base, expanded: expanded, obstacles: obstacles), false)
    }

    // MARK: - Per block

    private static func placeBlock(_ block: V2Block, page: CGRect, obstacles: [CGRect],
                                   placedFrames: [CGRect], options: Options) -> (V2PlacedText, Diagnostic) {
        let text = MeasuredText(block.translation ?? "", font: font(size: referenceSize))
        let source = sourcePixels(block)
        let (target, usedBalloon) = targetBox(block, page: page, source: source,
                                                 marginRatio: options.marginRatio, obstacles: obstacles)
        let cap = max(floorPixels, source * options.capRatio)
        var diagnostic = Diagnostic(blockID: block.id, box: target, targetBox: target, usedBalloon: usedBalloon,
            grew: false, overflowed: false, shrunkForOverlap: false, overlapsPlaced: false, sourcePixels: source)

        func strokeInset(_ size: CGFloat) -> CGFloat { strokeWidth(for: block, fontPixels: size) }
        func fit(in box: CGRect) -> Fit? {
            let inset = strokeInset(cap)
            let inner = CGSize(width: max(1, box.width - 2 * inset), height: max(1, box.height - 2 * inset))
            guard let horizontal = largestFit(text, box: inner, vertical: false, minimum: floorPixels, maximum: cap) else {
                return verticalOption(in: inner, horizontal: nil)
            }
            return verticalOption(in: inner, horizontal: horizontal) ?? horizontal
        }
        // Korean is set horizontally. Vertical is kept only for a vertical source in a
        // very tall, narrow box (h >= 3w) where horizontal would be < 2/3 the vertical size.
        func verticalOption(in inner: CGSize, horizontal: Fit?) -> Fit? {
            guard block.vertical, inner.height >= inner.width * 3, text.characterCount <= 24 else { return nil }
            guard let vertical = largestFit(text, box: inner, vertical: true, minimum: floorPixels, maximum: cap) else {
                return nil
            }
            if let horizontal, horizontal.size * 1.5 >= vertical.size { return nil }
            return vertical
        }

        // Overlapping source blocks: give this block only the part of its box that
        // earlier placed frames leave free, so painted blocks never collide.
        let start = carve(target, around: placedFrames, page: page)
        var box = start
        var chosen = fit(in: box)
        if chosen == nil {
            // Grow into free space (bounded): widen first, then deepen.
            let bounds = block.bounds.intersection(page)
            let anchor = start != target || bounds.isNull ? start : bounds
            for step in 1...6 {
                let dx = start.width * 0.2 * CGFloat(step) + source * CGFloat(step)
                let dy = start.height * 0.1 * CGFloat(step)
                let expanded = start.insetBy(dx: -dx, dy: -dy).intersection(page)
                box = clipExpansion(original: anchor, expanded: expanded, obstacles: obstacles).union(start)
                if let found = fit(in: box) { chosen = found; diagnostic.grew = true; break }
            }
        }
        let fitted: Fit
        if let chosen {
            fitted = chosen
        } else {
            // Floor size, allowed to overflow the grown box vertically.
            diagnostic.overflowed = true
            let inset = strokeInset(floorPixels)
            var size = floorPixels
            var candidate = horizontalFit(text, size: size, width: max(1, box.width - 2 * inset))
            // Keep the text inside the page even for pathological inputs (bounded halving).
            var guardCount = 0
            while candidate.extent.height + 2 * inset > page.height || candidate.extent.width + 2 * inset > page.width,
                  guardCount < 6 {
                size /= 2
                candidate = horizontalFit(text, size: size, width: min(page.width, max(box.width, page.width / 2)))
                guardCount += 1
            }
            fitted = candidate
        }
        diagnostic.box = box

        var current = fitted
        var frame = frameFor(current, in: box, stroke: strokeInset(current.size), page: page)
        if intersectsAny(frame, placedFrames) {
            // Bounded overlap resolution: alternate anchors in the box, then shrink.
            var resolved = false
            for attempt in 0...4 {
                if attempt > 0 {
                    let size = max(min(floorPixels, current.size), current.size * 0.85)
                    guard size < current.size else { break }
                    current = current.vertical ? verticalFit(text, size: size, height: box.height)
                        : horizontalFit(text, size: size, width: box.width - 2 * strokeInset(size))
                    diagnostic.shrunkForOverlap = true
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
                frame = frameFor(current, in: box, stroke: strokeInset(current.size), page: page)
                diagnostic.shrunkForOverlap = false
                diagnostic.overlapsPlaced = true
            }
        }
        let placed = V2PlacedText(blockID: block.id, frame: frame, fontPixels: current.size,
                                  vertical: current.vertical, lines: current.lines)
        return (placed, diagnostic)
    }

    /// Largest axis-aligned remainder of `box` after removing each intersecting frame
    /// (left/right/top/bottom strip, bounded by the number of placed frames); a box that
    /// a frame covers entirely moves to the nearest free side of that frame.
    static func carve(_ box: CGRect, around frames: [CGRect], page: CGRect) -> CGRect {
        var result = box
        for frame in frames {
            let overlap = result.intersection(frame)
            guard !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 else { continue }
            // Raw extents are checked before building rects: CGRect.width/height
            // standardize, so a negative strip would otherwise look valid.
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
            // Box entirely covered by an earlier frame: move beside it (nearest free side).
            let size = result.size
            let beside = [
                CGRect(x: frame.maxX, y: result.minY, width: size.width, height: size.height),
                CGRect(x: frame.minX - size.width, y: result.minY, width: size.width, height: size.height),
                CGRect(x: result.minX, y: frame.maxY, width: size.width, height: size.height),
                CGRect(x: result.minX, y: frame.minY - size.height, width: size.width, height: size.height)
            ].map { clamp($0, page: page) }.filter { candidate in
                !frames.contains { other in
                    let overlap = candidate.intersection(other)
                    return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
                }
            }
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

    /// Centred text frame (including stroke) clamped inside the page.
    static func frameFor(_ fit: Fit, in box: CGRect, stroke: CGFloat, page: CGRect) -> CGRect {
        let size = CGSize(width: fit.extent.width + 2 * stroke, height: fit.extent.height + 2 * stroke)
        return clamp(CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                            width: size.width, height: size.height), page: page)
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
