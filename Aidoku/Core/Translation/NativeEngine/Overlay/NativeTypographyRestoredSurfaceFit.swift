import CoreGraphics
import Foundation

/// The late fitBalloon(false,true,true,true) search. It predicts whole-word
/// boxes on connected safe paper, then asks the final shaper to prove at most
/// four nearest placements. It never commits a predicted box by itself.
enum NativeTypographyRestoredSurfaceFit {
    struct Grid {
        let width: Int
        let height: Int
        let crop: CGRect
        let sx: CGFloat
        let sy: CGFloat
        let sourceCenter: CGPoint
        let sourceSpan: CGRect
        private let sums: [Int32]

        init?(safe: [UInt8], width: Int, height: Int, crop: CGRect, page: CGRect,
              sourceRects: [CGRect], sourceCenter: CGPoint, glyph: CGFloat,
              obstacles: [CGRect], paintedAlpha: [UInt8]?, interiorAllows: ((CGPoint) -> Bool)?) {
            guard width > 0, height > 0, width <= 262_144 / height,
                  safe.count == width * height, crop.width > 0, crop.height > 0,
                  !sourceRects.isEmpty, glyph.isFinite, glyph > 0 else { return nil }
            self.width = width; self.height = height; self.crop = crop; self.sourceCenter = sourceCenter
            let sx = CGFloat(width) / crop.width, sy = CGFloat(height) / crop.height
            self.sx = sx; self.sy = sy
            var blocked = [UInt8](repeating: 1, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let point = CGPoint(x: crop.minX + (CGFloat(x) + 0.5) / sx, y: crop.minY + (CGFloat(y) + 0.5) / sy)
                    if point.x < page.minX || point.x > page.maxX || point.y < page.minY || point.y > page.maxY { continue }
                    if interiorAllows?(point) == false { continue }
                    if safe[y * width + x] != 0 { blocked[y * width + x] = 0 }
                }
            }
            for rect in obstacles where !rect.isNull {
                let left = max(0, min(width, Int(floor((rect.minX - 1 - crop.minX) * sx))))
                let top = max(0, min(height, Int(floor((rect.minY - 0.75 - crop.minY) * sy))))
                let right = max(0, min(width, Int(ceil((rect.maxX + 1 - crop.minX) * sx))))
                let bottom = max(0, min(height, Int(ceil((rect.maxY + 0.75 - crop.minY) * sy))))
                if left >= right || top >= bottom { continue }
                for y in top..<bottom { for x in left..<right { blocked[y * width + x] = 1 } }
            }
            let core = sourceRects.map { rect in CGRect(x: (rect.minX - crop.minX) * sx, y: (rect.minY - crop.minY) * sy,
                                                       width: rect.width * sx, height: rect.height * sy) }
            var reached = [UInt8](repeating: 0, count: width * height), queue: [Int] = []
            let hasPaint = paintedAlpha?.count == width * height
            for seedPainted in hasPaint ? [true, false] : [false] {
                for rect in core {
                    let left = max(0, min(width, Int(floor(rect.minX)))), right = max(0, min(width, Int(ceil(rect.maxX))))
                    let top = max(0, min(height, Int(floor(rect.minY)))), bottom = max(0, min(height, Int(ceil(rect.maxY))))
                    if left >= right || top >= bottom { continue }
                    for y in top..<bottom { for x in left..<right {
                        let i = y * width + x
                        if seedPainted && paintedAlpha![i] == 0 { continue }
                        if blocked[i] == 0 && reached[i] == 0 { reached[i] = 1; queue.append(i) }
                    } }
                }
                if !queue.isEmpty { break }
            }
            guard !queue.isEmpty else { return nil }
            var head = 0
            while head < queue.count {
                let i = queue[head], x = i % width, y = i / width; head += 1
                for j in [x > 0 ? i - 1 : -1, x < width - 1 ? i + 1 : -1,
                          y > 0 ? i - width : -1, y < height - 1 ? i + width : -1] where j >= 0 {
                    if blocked[j] == 0 && reached[j] == 0 { reached[j] = 1; queue.append(j) }
                }
            }
            var summed = [Int32](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var row: Int32 = 0
                for x in 0..<width {
                    row += reached[y * width + x] == 0 ? 1 : 0
                    summed[(y + 1) * (width + 1) + x + 1] = summed[y * (width + 1) + x + 1] + row
                }
            }
            sums = summed
            let g = glyph * sx / 2
            let union = core.reduce(CGRect.null) { $0.union($1) }
            sourceSpan = union.insetBy(dx: -g, dy: -g)
        }
        func clear(left: Int, top: Int, width: Int, height: Int) -> Bool {
            guard left >= 0, top >= 0, width > 0, height > 0, left + width <= self.width, top + height <= self.height else { return false }
            let stride = self.width + 1
            return sums[(top + height) * stride + left + width] - sums[top * stride + left + width]
                - sums[(top + height) * stride + left] + sums[top * stride + left] == 0
        }
    }
    struct Proposal {
        let size: CGFloat
        let measure: CGFloat
        let center: CGPoint
        let distance: CGFloat
    }
    struct Validation<T> { let value: T; let rank: Int }

    static func proposals(text: String, font: CGFloat, lineHeightRatio: CGFloat, originalLines: Int,
                          sourceWidth: CGFloat, baseWidth: CGFloat, glyph: CGFloat, grid: Grid,
                          style: (CGFloat) -> NativeTranslationTypography.Style, budget: inout Int) -> [Proposal] {
        guard budget > 0, font > 0, glyph > 0, originalLines > 0, text.utf16.count <= 180 else { return [] }
        let bound = min(font, max(8.5, font * 0.95)), upper = floor(font * 4) / 4
        guard upper >= bound else { return [] }
        var sizes: [CGFloat] = []
        for index in 0..<6 {
            let size = max(ceil(bound * 4) / 4, floor((upper - (upper - bound) * CGFloat(index) / 5) * 4) / 4)
            if !sizes.contains(size) { sizes.append(size) }
        }
        let span = grid.sourceSpan, scx = (grid.sourceCenter.x - grid.crop.minX) * grid.sx
        let scy = (grid.sourceCenter.y - grid.crop.minY) * grid.sy
        let maxWidth = min(CGFloat(grid.width) / grid.sx, span.width / grid.sx + glyph * 2)
        let step = max(1, Int(ceil(sqrt(span.width * span.height / 1024))))
        var offsets: [(x: Int, y: Int, distance: CGFloat)] = []
        var y = Int(ceil(span.minY))
        while CGFloat(y) <= span.maxY {
            var x = Int(ceil(span.minX))
            while CGFloat(x) <= span.maxX {
                offsets.append((x, y, pow(CGFloat(x) - scx, 2) + pow(CGFloat(y) - scy, 2))); x += step
            }
            y += step
        }
        offsets = offsets.enumerated().sorted { a, b in
            a.element.distance != b.element.distance ? a.element.distance < b.element.distance : a.offset < b.offset
        }.map(\.element)
        budget -= offsets.count
        var placed: [Proposal] = []
        for size in sizes {
            let fontStyle = style(size), pitch = size * lineHeightRatio
            let mx: CGFloat = 1, my: CGFloat = 0.75 // Late sizes never exceed the committed font.
            let untracked = NativeTranslationTypography.measuredWidth(text: text, style: fontStyle)
                - CGFloat(max(0, text.unicodeScalars.count - 1)) * fontStyle.tracking
            var measures: [CGFloat] = []
            for value in [baseWidth * size / font, sourceWidth, baseWidth * 0.75, baseWidth * 1.15, sourceWidth * 0.8]
                + (untracked + 2 < size * 1.8 ? [ceil((untracked + 2) * 4) / 4] : []) {
                let width = floor(value * 4) / 4
                if !measures.contains(width) { measures.append(width) }
            }
            let word = NativeTypographyPostPolish.koreanWordWidth(text: text, style: fontStyle)
            let narrow = max(floor(word * 4) / 4, size * 1.8)
            for index in 0..<5 {
                let width = floor((narrow + (maxWidth - narrow) * CGFloat(index) / 4) * 4) / 4
                if !measures.contains(width) { measures.append(width) }
            }
            var seen = Set<String>()
            for measure in measures where measure >= narrow - 0.01 && measure <= maxWidth + 0.01 {
                var quoteStyle = fontStyle; quoteStyle.koreanQuoteMode = 0
                guard let lines = NativeTranslationTypography.koreanLines(text: text,
                    available: CGSize(width: measure, height: CGFloat(originalLines + 8) * pitch),
                    style: quoteStyle, maxLines: originalLines + 8), seen.insert(lines.joined(separator: "\n")).inserted else { continue }
                let widths = lines.map { NativeTranslationTypography.measuredWidth(text: $0, style: fontStyle) }
                let boxes = widths.enumerated().map { index, width -> (left: Int, top: Int, width: Int, height: Int) in
                    (Int(floor((-width / 2 - mx) * grid.sx)) - 1,
                     Int(floor(((CGFloat(index) - CGFloat(lines.count) / 2) * pitch - my) * grid.sy)) - 1,
                     Int(ceil((width + 2 * mx) * grid.sx)) + 2, Int(ceil((pitch + 2 * my) * grid.sy)) + 2)
                }
                if boxes.contains(where: { $0.width > grid.width || $0.height > grid.height }) { continue }
                budget -= offsets.count >> 2
                let rowOffsets = lines.count == 1 ? offsets.filter { abs(CGFloat($0.y) - scy) <= size * 0.25 * grid.sy }
                    .map { (x: $0.x, y: $0.y, distance: pow(CGFloat($0.x) - scx, 2) + 9 * pow(CGFloat($0.y) - scy, 2)) }
                    .enumerated().sorted { a, b in a.element.distance != b.element.distance
                        ? a.element.distance < b.element.distance : a.offset < b.offset }.map(\.element) : offsets
                if let hit = rowOffsets.first(where: { point in boxes.allSatisfy {
                    grid.clear(left: point.x + $0.left, top: point.y + $0.top, width: $0.width, height: $0.height)
                } }) {
                    placed.append(Proposal(size: size, measure: measure,
                        center: CGPoint(x: grid.crop.minX + CGFloat(hit.x) / grid.sx,
                                        y: grid.crop.minY + CGFloat(hit.y) / grid.sy), distance: hit.distance))
                }
            }
            if placed.contains(where: { $0.size == size }) { break }
        }
        return placed.enumerated().sorted { a, b in
            if a.element.size != b.element.size { return a.element.size > b.element.size }
            if a.element.distance != b.element.distance { return a.element.distance < b.element.distance }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func verify<T>(_ proposals: [Proposal], text: String, style: (CGFloat) -> NativeTranslationTypography.Style,
                          budget: inout Int, candidate: (Proposal) -> Validation<T>?) -> T? {
        for proposal in proposals.prefix(4) {
            if budget <= 0 { break }; budget -= 256
            guard var best = candidate(proposal) else { continue }
            if best.rank > 0 {
                let word = floor(NativeTypographyPostPolish.koreanWordWidth(text: text, style: style(proposal.size)) * 4) / 4
                if word != proposal.measure,
                   let repaired = candidate(Proposal(size: proposal.size, measure: word, center: proposal.center, distance: proposal.distance)),
                   repaired.rank < best.rank { best = repaired }
            }
            return best.value
        }
        return nil
    }
}
