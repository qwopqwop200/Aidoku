import CoreGraphics
import Foundation

// S4b: free lettering space around each block, measured on the S4 gray raster.
// RF-DETR finds no balloon for most vertical source columns, and its balloon boxes
// often span several balloons or cut past rounded outlines, so S9 would either wrap
// the translation inside the tight column box or paint outside the balloon.
// The block's bounds get the legacy granted margin, then grow by legacy steps per side,
// stopped only by other text, other detected balloons, the panel frame, the block's own
// balloon box and the 8 x 4 line reach (no pixel test). On clean paper, per-row spans
// through the source centre stop at outlines and art. The result becomes `V2Block.balloon`,
// the box S9 fits into.
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
    /// Granted margin around the source before the clean growth (legacy exterior start).
    static let baseMargin = (horizontal: CGFloat(3), vertical: CGFloat(1.5))
    /// Legacy exterior growth: step per side in line thicknesses, steps per side and the share
    /// of other text an added strip may cover.
    static let growthStep = (horizontal: CGFloat(1), vertical: CGFloat(0.5))
    static let growthSteps = 6
    static let collisionShare: Double = 0.02
    /// Least share of the grown box's area a balloon lobe keeps to replace it (chosen on train folds).
    static let lobeShare = 0.6
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
            let others = blocks.indices.filter { $0 != index && blocks[$0].role != .background }.compactMap { cells(blocks[$0].bounds) }
            if let (interior, rows) = grow(block, start: start, raster: raster, cells: cells,
                                           bounds: block.panel, avoid: avoided(block, layout: layout), others: others) {
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
                             bounds: CGRect?, avoid: [CGRect], others: [Box]) -> (Box, Rows?)? {
        let width = raster.width, height = raster.height
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
        // Legacy granted margin (3 x 1.5 line thicknesses), within the limit; a side that would
        // reach another block's text stops before it.
        var base: Box = (max(limit.x0, start.x0 - Int(baseMargin.horizontal * CGFloat(emX))),
                         max(limit.y0, start.y0 - Int(baseMargin.vertical * CGFloat(emY))),
                         min(limit.x1, start.x1 + Int(baseMargin.horizontal * CGFloat(emX))),
                         min(limit.y1, start.y1 + Int(baseMargin.vertical * CGFloat(emY))))
        for o in others where o.x0 < base.x1 && o.x1 > base.x0 && o.y0 < base.y1 && o.y1 > base.y0 {
            if o.x0 >= start.x1 { base.x1 = min(base.x1, o.x0) } else if o.x1 <= start.x0 { base.x0 = max(base.x0, o.x1) }
            else if o.y0 >= start.y1 { base.y1 = min(base.y1, o.y0) } else if o.y1 <= start.y0 { base.y0 = max(base.y0, o.y1) }
        }
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
        let band = bands.indices.max { bands[$0] < bands[$1] } ?? 15
        let paper = bands[band] > 0 ? sums[band] / bands[band] : 255
        // Tone or mid-gray art: no paper level, so no row spans (the box still grows).
        let toned = bands[band] == 0 || (midGray.lowerBound < paper && paper < midGray.upperBound)

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
        // Legacy exterior growth (without its edge-risk test): each side in turn (left, right,
        // top, bottom) by 1 em (0.5 em vertically), at most `growthSteps` times, while the added
        // strip covers <= 2% of other blocks' text and enters no other detected balloon.
        func area(_ r: Box) -> Int { max(0, r.x1 - r.x0) * max(0, r.y1 - r.y0) }
        func overlap(_ r: Box, _ o: Box) -> Int { max(0, min(r.x1, o.x1) - max(r.x0, o.x0)) * max(0, min(r.y1, o.y1) - max(r.y0, o.y0)) }
        var best = base
        for side in 0..<4 {
            let step = side < 2 ? max(1, Int(growthStep.horizontal * CGFloat(emX))) : max(1, Int(growthStep.vertical * CGFloat(emY)))
            for _ in 0..<growthSteps {
                var next = best
                switch side {
                case 0: next.x0 = max(limit.x0, best.x0 - step)
                case 1: next.x1 = min(limit.x1, best.x1 + step)
                case 2: next.y0 = max(limit.y0, best.y0 - step)
                default: next.y1 = min(limit.y1, best.y1 + step)
                }
                let strip = area(next) - area(best)
                let hit = others.reduce(0) { $0 + overlap(next, $1) - overlap(best, $1) }
                guard strip > 0, Double(hit) <= Double(strip) * collisionShare,
                      !blocked.contains(where: { overlap(next, $0) > overlap(best, $0) }) else { break }
                best = next
            }
        }
        guard best != start else { return nil }
        guard !toned else { return (best, nil) }
        // An enclosed balloon's tail-free lobe replaces the grown box (row spans still describe the
        // growth) unless it keeps less than `lobeShare` of its area (a narrow lobe cuts words).
        let box = lobeRect(limit, source: start, dirty: dirty).flatMap { Double(area($0)) >= lobeShare * Double(area(best)) ? $0 : nil } ?? best
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
        guard halves[0] > 0 else { return (box, nil) }
        while top - 1 >= limit.y0 { let h = half(top - 1); guard h > 0 else { break }; halves.insert(h, at: 0); top -= 1 }
        while bottom + 1 < limit.y1 { let h = half(bottom + 1); guard h > 0 else { break }; halves.append(h); bottom += 1 }
        let rectHalf = (best.x1 - best.x0) / 2
        guard (halves.max() ?? 0) > rectHalf + 1 else { return (box, nil) }
        return (box, Rows(first: top, centre: centre, halves: halves))
    }

    /// Legacy balloon_consistency lobes: the paper connected to the source inside the balloon box
    /// is split at its distance cores (>= 0.32 of the peak, seeds >= 3% of the core); the lobe
    /// holding >= 70% of the source yields the widest centred rectangle inscribed in its rows
    /// (centre weighted by distance squared, so a thin tail neither pulls nor widens it).
    static func lobeRect(_ box: Box, source: Box, dirty: (Int, Int) -> Bool) -> Box? {
        let w = box.x1 - box.x0, h = box.y1 - box.y0
        guard w > 4, h > 4 else { return nil }
        // Paper 4-connected to the source box.
        var mask = [Bool](repeating: false, count: w * h), queue: [Int] = []
        for y in max(box.y0, source.y0)..<min(box.y1, source.y1) {
            for x in max(box.x0, source.x0)..<min(box.x1, source.x1) where !dirty(x, y) {
                mask[(y - box.y0) * w + x - box.x0] = true
                queue.append((y - box.y0) * w + x - box.x0)
            }
        }
        var head = 0
        while head < queue.count {
            let cell = queue[head], x = cell % w, y = cell / w
            head += 1
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let next = ny * w + nx
                guard !mask[next], !dirty(nx + box.x0, ny + box.y0) else { continue }
                mask[next] = true
                queue.append(next)
            }
        }
        // Only an enclosed balloon: paper reaching the growth limit is open lettering space.
        guard !mask.indices.contains(where: { mask[$0] && ($0 % w == 0 || $0 % w == w - 1 || $0 < w || $0 >= w * (h - 1)) }) else {
            return nil
        }
        // Chamfer (3-4) distance to the nearest non-paper cell.
        var dist = mask.map { $0 ? Int.max / 2 : 0 }
        for pass in 0..<2 {
            for k in 0..<(w * h) {
                let cell = pass == 0 ? k : w * h - 1 - k, x = cell % w, y = cell / w, d = pass == 0 ? -1 : 1
                guard dist[cell] > 0 else { continue }
                var best = (x == 0 || y == 0 || x == w - 1 || y == h - 1) ? 3 : dist[cell]
                for (dx, cost) in [(0, 3), (-1, 4), (1, 4)] where x + dx >= 0 && x + dx < w && y + d >= 0 && y + d < h {
                    best = min(best, dist[(y + d) * w + x + dx] + cost)
                }
                if x + d >= 0, x + d < w { best = min(best, dist[y * w + x + d] + 3) }
                dist[cell] = best
            }
        }
        guard let peak = dist.max(), peak >= 6 else { return nil }
        // Core components, then every paper cell joins its geodesically nearest seed core.
        let core = dist.map { Double($0) >= Double(peak) * 0.32 }
        let coreCount = core.filter { $0 }.count
        var label = [Int](repeating: -1, count: w * h), seeds = 0
        for start in core.indices where core[start] && label[start] < 0 {
            var component = [start], index = 0
            label[start] = seeds
            while index < component.count {
                let cell = component[index], x = cell % w, y = cell / w
                index += 1
                for dy in -1...1 {
                    for dx in -1...1 where x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < h {
                        let next = (y + dy) * w + x + dx
                        if core[next], label[next] < 0 { label[next] = seeds; component.append(next) }
                    }
                }
            }
            if component.count >= max(4, coreCount * 3 / 100) { seeds += 1 } else { component.forEach { label[$0] = -2 } }
        }
        guard seeds > 0 else { return nil }
        var frontier = label.indices.filter { label[$0] >= 0 }
        label = label.map { $0 >= 0 ? $0 : -1 }
        head = 0
        while head < frontier.count {
            let cell = frontier[head], x = cell % w, y = cell / w
            head += 1
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let next = ny * w + nx
                if mask[next], label[next] < 0 { label[next] = label[cell]; frontier.append(next) }
            }
        }
        // The lobe covering most of the source, when it covers >= 70%.
        var cover = [Int](repeating: 0, count: seeds)
        for y in max(box.y0, source.y0)..<min(box.y1, source.y1) {
            for x in max(box.x0, source.x0)..<min(box.x1, source.x1) where label[(y - box.y0) * w + x - box.x0] >= 0 {
                cover[label[(y - box.y0) * w + x - box.x0]] += 1
            }
        }
        guard let lobe = cover.indices.max(by: { cover[$0] < cover[$1] }),
              Double(cover[lobe]) >= 0.7 * Double((source.x1 - source.x0) * (source.y1 - source.y0)) else { return nil }
        var left = [Int](repeating: w, count: h), right = [Int](repeating: 0, count: h)
        var weight = 0.0, cx = 0.0, cy = 0.0
        for cell in label.indices where label[cell] == lobe {
            let x = cell % w, y = cell / w, value = Double(dist[cell] * dist[cell])
            left[y] = min(left[y], x)
            right[y] = max(right[y], x + 1)
            weight += value
            cx += Double(x) * value
            cy += Double(y) * value
        }
        cx /= weight
        cy /= weight
        let rows = Set((0...48).map { $0 * h / 48 } + [Int(cy.rounded())]).sorted()
        var best: (score: Double, rect: Box)?
        for (i, a) in rows.enumerated() where Double(a) <= cy {
            for b in rows[(i + 1)...] where Double(b) >= cy {
                let lo = left[a..<b].max() ?? w, hi = right[a..<b].min() ?? 0
                guard hi > lo else { continue }
                let offset = pow((Double(lo + hi) / 2 - cx), 2) + pow(Double(a + b) / 2 - cy, 2)
                let score = Double((hi - lo) * (b - a)) / (1 + offset / Double(w * h))
                if score > best?.score ?? 0 { best = (score, (lo + box.x0, a + box.y0, hi + box.x0, b + box.y0)) }
            }
        }
        // The source centre lies within the rectangle widened by a quarter per side.
        guard let rect = best?.rect, min(rect.x1 - rect.x0, rect.y1 - rect.y0) >= 3 else { return nil }
        let mx = (source.x0 + source.x1) / 2, my = (source.y0 + source.y1) / 2
        let qx = (rect.x1 - rect.x0) / 4, qy = (rect.y1 - rect.y0) / 4
        guard mx >= rect.x0 - qx, mx <= rect.x1 + qx, my >= rect.y0 - qy, my <= rect.y1 + qy else { return nil }
        return rect
    }
}
