import CoreGraphics
import Foundation

// S4b: free lettering space around each block, measured on the S4 gray raster.
// RF-DETR finds no balloon for most vertical source columns, and its balloon boxes
// often span several balloons or cut past rounded outlines, so S9 would either wrap
// the translation inside the tight column box or paint outside the balloon.
// Starting from the block's own bounds, the sides grow one raster cell at a time
// while the added strip holds only paper-coloured cells (the block's own lines count
// as paper: S6 erases them). Growth stops at other text, balloon outlines, art and
// tone, so the result is a rectangle inscribed in the clean area, kept one cell
// inside where it stopped and bounded by a detected balloon and a reach of a few
// line thicknesses. It becomes `V2Block.balloon`, the box S9 fits into; blocks on
// mid-gray paper (tone) keep their detected balloon, if any.
enum V2Interior {
    typealias Box = (x0: Int, y0: Int, x1: Int, y1: Int)
    /// Raster row spans: rows `first...`, half-widths in cells about column `centre`.
    struct Rows {
        var first: Int
        var centre: Int
        var halves: [Int]
    }

    /// Gray distance from the paper level that marks a cell as ink or art.
    static let inkDistance = 64
    /// Paper levels in this open range (tone, mid-gray art) are not treated as paper.
    static let midGray = 96...160
    /// Growth per side, in source line thicknesses (column width or row height): text
    /// outside any detected balloon may spread up to 8 x 4 (the legacy exterior reach);
    /// inside a detected balloon the balloon box bounds it.
    static let horizontalReach: CGFloat = 8
    static let verticalReach: CGFloat = 4
    /// A panel frame bounds the growth when it holds this share of the block.
    static let frameHold: CGFloat = 0.95

    static func apply(_ blocks: [V2Block], raster: V2GrayRaster?, pageSize: CGSize,
                      layout: [V2LayoutRegion] = []) -> [V2Block] {
        guard let raster, raster.width > 2, raster.height > 2, raster.pixels.count == raster.width * raster.height,
              pageSize.width >= 1, pageSize.height >= 1 else { return blocks }
        let sx = CGFloat(raster.width) / pageSize.width, sy = CGFloat(raster.height) / pageSize.height
        func cells(_ rect: CGRect) -> Box? {
            guard !rect.isNull, rect.width > 0, rect.height > 0,
                  [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite && abs($0) < 1e9 }) else { return nil }
            let x0 = max(0, Int((rect.minX * sx).rounded(.down))), x1 = min(raster.width, Int((rect.maxX * sx).rounded(.up)))
            let y0 = max(0, Int((rect.minY * sy).rounded(.down))), y1 = min(raster.height, Int((rect.maxY * sy).rounded(.up)))
            return x0 < x1 && y0 < y1 ? (x0, y0, x1, y1) : nil
        }
        return blocks.enumerated().map { index, block in
            var block = block
            block.panel = limitBounds(block, layout: layout)
            guard block.role != .background, let start = cells(block.bounds) else { return block }
            var candidates: [CGRect] = []
            var spans: V2RowSpans?
            if let (interior, rows) = grow(block, start: start, raster: raster, cells: cells,
                                           bounds: block.panel, avoid: avoided(block, layout: layout)) {
                candidates.append(CGRect(x: CGFloat(interior.x0) / sx, y: CGFloat(interior.y0) / sy,
                                         width: CGFloat(interior.x1 - interior.x0) / sx,
                                         height: CGFloat(interior.y1 - interior.y0) / sy))
                if let rows {
                    spans = V2RowSpans(top: CGFloat(rows.first) / sy, step: 1 / sy, centre: (CGFloat(rows.centre) + 0.5) / sx,
                                       halfWidths: rows.halves.map { CGFloat($0) / sx })
                }
            }
            // A detected balloon holding no other text: the rectangle inscribed in its
            // ellipse is safe for rounded and square balloons alike (and survives shading
            // inside the balloon that stops the pixel growth).
            if let balloon = block.balloon, !blocks.indices.contains(where: { other in
                other != index && blocks[other].role != .background && blocks[other].bounds.intersects(balloon)
            }) {
                candidates.append(balloon.insetBy(dx: balloon.width * (1 - ellipseInscribed) / 2,
                                                  dy: balloon.height * (1 - ellipseInscribed) / 2))
            }
            guard let best = candidates.map({ $0.union(block.bounds) })
                .max(by: { $0.width * $0.height < $1.width * $1.height }) else { return block }
            // Never smaller than the source text itself.
            block.balloon = best
            // Row spans only describe the pixel-grown interior.
            block.rows = candidates.first.map { $0.union(block.bounds) == best } == true ? spans : nil
            return block
        }
    }

    /// Side of the largest-area rectangle inscribed in an ellipse, relative to its box (1/sqrt 2).
    static let ellipseInscribed: CGFloat = 0.7071

    /// The smallest confident panel frame holding the block (growth never crosses a panel border).
    static func limitBounds(_ block: V2Block, layout: [V2LayoutRegion]) -> CGRect? {
        let area = block.bounds.width * block.bounds.height
        guard area > 0 else { return nil }
        return layout.filter { region in
            guard region.kind == .frame, region.score >= 0.7 else { return false }
            let overlap = region.bounds.intersection(block.bounds)
            return !overlap.isNull && overlap.width * overlap.height >= area * frameHold
        }.map(\.bounds).min { $0.width * $0.height < $1.width * $1.height }
    }

    /// Detected balloons that do not hold the block: exterior text never grows into them.
    static func avoided(_ block: V2Block, layout: [V2LayoutRegion]) -> [CGRect] {
        let centre = CGPoint(x: block.bounds.midX, y: block.bounds.midY)
        return layout.filter { $0.kind == .balloon && $0.score >= 0.5 && !$0.bounds.contains(centre) }.map(\.bounds)
    }

    private static func grow(_ block: V2Block, start: Box, raster: V2GrayRaster, cells: (CGRect) -> Box?,
                             bounds: CGRect?, avoid: [CGRect]) -> (Box, Rows?)? {
        let width = raster.width, height = raster.height
        // Paper level: the most common 16-level band of the block's own box (dense
        // columns can be half ink, so a median would land on gray).
        var bands = [Int](repeating: 0, count: 16), sums = [Int](repeating: 0, count: 16)
        for y in start.y0..<start.y1 {
            for x in start.x0..<start.x1 {
                let value = Int(raster.pixels[y * width + x])
                bands[value >> 4] += 1
                sums[value >> 4] += value
            }
        }
        guard let band = bands.indices.max(by: { bands[$0] < bands[$1] }), bands[band] > 0 else { return nil }
        let paper = sums[band] / bands[band]
        guard !(midGray.lowerBound < paper && paper < midGray.upperBound) else { return nil }

        let thickness = block.lines.map { block.vertical ? $0.bounds.width : $0.bounds.height }.sorted()
        let em = thickness.isEmpty ? 0 : thickness[thickness.count / 2]
        guard em > 0, let unit = cells(CGRect(x: 0, y: 0, width: em, height: em)) else { return nil }
        let emX = max(1, unit.x1 - unit.x0), emY = max(1, unit.y1 - unit.y0)
        var limit: Box = (max(0, start.x0 - Int(horizontalReach * CGFloat(emX))),
                          max(0, start.y0 - Int(verticalReach * CGFloat(emY))),
                          min(width, start.x1 + Int(horizontalReach * CGFloat(emX))),
                          min(height, start.y1 + Int(verticalReach * CGFloat(emY))))
        for bound in [block.balloon, bounds].compactMap({ $0 }) {
            guard let box = cells(bound) else { continue }
            limit = (max(limit.x0, box.x0), max(limit.y0, box.y0), min(limit.x1, box.x1), min(limit.y1, box.y1))
        }
        let blocked = avoid.compactMap(cells)

        // Own lines, padded by a fifth of a line (glyphs overhang detector boxes), are
        // erased by S6, so they count as paper.
        let pad = max(2, Int((CGFloat(emX) * 0.2).rounded()))
        let own = block.lines.compactMap { cells($0.bounds) }.map {
            (x0: $0.x0 - pad, y0: $0.y0 - pad, x1: $0.x1 + pad, y1: $0.y1 + pad)
        }
        func dirty(_ x: Int, _ y: Int) -> Bool {
            if blocked.contains(where: { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }) { return true }
            guard abs(Int(raster.pixels[y * width + x]) - paper) > inkDistance else { return false }
            return !own.contains { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }
        }
        func clean(column x: Int, _ r: Box) -> Bool {
            var count = 0
            for y in r.y0..<r.y1 where dirty(x, y) {
                count += 1
                if count * 100 > r.y1 - r.y0 { return false }
            }
            return true
        }
        func clean(row y: Int, _ r: Box) -> Bool {
            var count = 0
            for x in r.x0..<r.x1 where dirty(x, y) {
                count += 1
                if count * 100 > r.x1 - r.x0 { return false }
            }
            return true
        }
        /// Grows the sides of each phase (0 left, 1 right, 2 top, 3 bottom) round-robin
        /// until all of them stop, then steps one cell back from every grown edge.
        func grown(_ phases: [[Int]]) -> Box {
            var r = start
            for sides in phases {
                var open = Set(sides)
                while !open.isEmpty {
                    for side in sides where open.contains(side) {
                        var moved = false
                        switch side {
                        case 0: if r.x0 > limit.x0, clean(column: r.x0 - 1, r) { r.x0 -= 1; moved = true }
                        case 1: if r.x1 < limit.x1, clean(column: r.x1, r) { r.x1 += 1; moved = true }
                        case 2: if r.y0 > limit.y0, clean(row: r.y0 - 1, r) { r.y0 -= 1; moved = true }
                        default: if r.y1 < limit.y1, clean(row: r.y1, r) { r.y1 += 1; moved = true }
                        }
                        if !moved { open.remove(side) }
                    }
                }
            }
            if r.x0 < start.x0 { r.x0 += 1 }
            if r.x1 > start.x1 { r.x1 -= 1 }
            if r.y0 < start.y0 { r.y0 += 1 }
            if r.y1 > start.y1 { r.y1 -= 1 }
            return r
        }
        // Width-first suits a wide clean area beside a column; all sides together suits a
        // tall one. Inside a rounded balloon they inscribe different rectangles: keep the
        // larger.
        func area(_ box: Box) -> Int { (box.x1 - box.x0) * (box.y1 - box.y0) }
        let best = [grown([[0, 1], [2, 3]]), grown([[0, 1, 2, 3]])].max { area($0) < area($1) } ?? start
        guard best != start else { return nil }
        // Row spans: per raster row, the clean run through the source centre column, as a
        // half-width symmetric about it, one cell inside; kept for the contiguous rows around
        // the centre row and only when some row is wider than the rectangle.
        let centre = (start.x0 + start.x1) / 2, middle = (start.y0 + start.y1) / 2
        func half(_ y: Int) -> Int {
            guard !dirty(centre, y) else { return 0 }
            var left = centre, right = centre
            while left - 1 >= limit.x0, !dirty(left - 1, y) { left -= 1 }
            while right + 1 < limit.x1, !dirty(right + 1, y) { right += 1 }
            return max(0, min(centre - left, right - centre) - 1)
        }
        var top = middle, bottom = middle
        var halves: [Int] = [half(middle)]
        guard halves[0] > 0 else { return (best, nil) }
        while top - 1 >= limit.y0 { let h = half(top - 1); guard h > 0 else { break }; halves.insert(h, at: 0); top -= 1 }
        while bottom + 1 < limit.y1 { let h = half(bottom + 1); guard h > 0 else { break }; halves.append(h); bottom += 1 }
        let rectHalf = (best.x1 - best.x0) / 2
        guard (halves.max() ?? 0) > rectHalf + 1 else { return (best, nil) }
        return (best, Rows(first: top, centre: centre, halves: halves))
    }
}
