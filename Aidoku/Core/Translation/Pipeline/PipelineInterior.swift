import CoreGraphics
import Foundation

// S4b: free lettering space around each block on the S4 gray raster (RF-DETR balloons are often
// missing or wrong). The bounds grow per side, stopped by other text and balloons, the panel, the
// line reach and ink; the result becomes `PipelineBlock.balloon`, the box S9 fits into.
enum PipelineInterior {
    typealias Box = (x0: Int, y0: Int, x1: Int, y1: Int)
    /// Raster row spans: rows `first...`, half-widths in cells about column `centre`.
    typealias Rows = (first: Int, centre: Int, halves: [Int])

    /// Gray distance from the paper level that marks a cell as ink or art.
    static let inkDistance = 64
    /// Paper levels in this open range (tone, mid-gray art) are not treated as paper.
    static let midGray = 96...160
    /// Growth reach per side, in source line thicknesses (vertical 3 on the S1 balloon floor 0.4:
    /// compare.py +9, 2.5-3 a plateau; 3.5 -5, 5 neutral).
    static var horizontalReach: CGFloat { PipelineTuning.current.interiorHorizontalReach }
    static var verticalReach: CGFloat { PipelineTuning.current.interiorVerticalReach }
    /// Granted margin around the source before the growth.
    static let baseMargin = (horizontal: CGFloat(3), vertical: CGFloat(1.5))
    /// Growth step in line thicknesses, steps per side and the share of other text a strip may cover.
    static let growthStep = (horizontal: CGFloat(1), vertical: CGFloat(0.5))
    static let growthSteps = 6
    static let collisionShare: Double = 0.02
    /// A step stops at > 3% ink in its strip once the box holds 3 x the source area.
    static let edgeShare = 0.03
    static let edgeGuard = 3
    /// Least share of the grown box's area a balloon lobe keeps to replace it.
    static let lobeShare = 0.6
    /// A panel frame bounds the growth when it holds this share of the block.
    static let frameHold: CGFloat = 0.95

    static func apply(_ blocks: [PipelineBlock], raster: PipelineGrayRaster?, pageSize: CGSize,
                      layout: [PipelineLayoutRegion] = []) -> [PipelineBlock] {
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
        // Cells of every non-background block, computed once (each block's growth avoids all the others).
        let textCells = blocks.map { $0.role != .background ? cells($0.bounds) : nil }
        return blocks.enumerated().map { index, block in
            var block = block
            block.panel = limitBounds(block, layout: layout)
            guard block.role != .background, let start = cells(block.bounds) else { return block }
            var candidates: [CGRect] = []
            var spans: PipelineRowSpans?
            let others = blocks.indices.filter { $0 != index }.compactMap { textCells[$0] }
            if let (interior, rows) = grow(block, start: start, raster: raster, cells: cells,
                                           bounds: block.panel, avoid: avoided(block, layout: layout), others: others) {
                candidates.append(CGRect(x: CGFloat(interior.x0) / sx, y: CGFloat(interior.y0) / sy,
                                         width: CGFloat(interior.x1 - interior.x0) / sx,
                                         height: CGFloat(interior.y1 - interior.y0) / sy))
                if let rows {
                    spans = PipelineRowSpans(top: CGFloat(rows.first) / sy, step: 1 / sy, centre: (CGFloat(rows.centre) + 0.5) / sx,
                                       halfWidths: rows.halves.map { CGFloat($0) / sx })
                }
            }
            // A detected balloon holding no other text: the rectangle inscribed in its ellipse.
            if let balloon = block.balloon, !blocks.indices.contains(where: { other in
                other != index && blocks[other].role != .background && blocks[other].bounds.intersects(balloon)
            }) {
                candidates.append(balloon.insetBy(dx: balloon.width * (1 - ellipseInscribed) / 2,
                                                  dy: balloon.height * (1 - ellipseInscribed) / 2))
            }
            guard let best = candidates.map({ $0.union(block.bounds) })
                .max(by: { $0.width * $0.height < $1.width * $1.height }) else { return block }
            block.balloon = best
            // Row spans only describe the pixel-grown interior.
            block.rows = candidates.first.map { $0.union(block.bounds) == best } == true ? spans : nil
            return block
        }
    }

    /// Side of the largest-area rectangle inscribed in an ellipse, relative to its box (1/sqrt 2).
    static let ellipseInscribed: CGFloat = 0.7071

    /// The smallest confident panel frame holding the block (growth never crosses a panel border).
    static func limitBounds(_ block: PipelineBlock, layout: [PipelineLayoutRegion]) -> CGRect? {
        let area = block.bounds.width * block.bounds.height
        guard area > 0 else { return nil }
        return layout.filter { region in
            guard region.kind == .frame, region.score >= PipelineTuning.current.interiorFrameScore else { return false }
            let overlap = region.bounds.intersection(block.bounds)
            return !overlap.isNull && overlap.width * overlap.height >= area * frameHold
        }.map(\.bounds).min { $0.width * $0.height < $1.width * $1.height }
    }

    /// Detected balloons that do not hold the block: exterior text never grows into them.
    static func avoided(_ block: PipelineBlock, layout: [PipelineLayoutRegion]) -> [CGRect] {
        let centre = CGPoint(x: block.bounds.midX, y: block.bounds.midY)
        return layout.filter { $0.kind == .balloon && $0.score >= PipelineLayoutRegion.balloonFloor && !$0.bounds.contains(centre) }.map(\.bounds)
    }

    private static func grow(_ block: PipelineBlock, start: Box, raster: PipelineGrayRaster, cells: (CGRect) -> Box?,
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
        // Granted margin within the limit; a side reaching another block's text stops before it.
        var base: Box = (max(limit.x0, start.x0 - Int(baseMargin.horizontal * CGFloat(emX))),
                         max(limit.y0, start.y0 - Int(baseMargin.vertical * CGFloat(emY))),
                         min(limit.x1, start.x1 + Int(baseMargin.horizontal * CGFloat(emX))),
                         min(limit.y1, start.y1 + Int(baseMargin.vertical * CGFloat(emY))))
        for o in others where o.x0 < base.x1 && o.x1 > base.x0 && o.y0 < base.y1 && o.y1 > base.y0 {
            if o.x0 >= start.x1 { base.x1 = min(base.x1, o.x0) } else if o.x1 <= start.x0 { base.x0 = max(base.x0, o.x1) }
            else if o.y0 >= start.y1 { base.y1 = min(base.y1, o.y0) } else if o.y1 <= start.y0 { base.y0 = max(base.y0, o.y1) }
        }
        // Paper level: the most common 16-level band of the block's box (dense columns can be half ink).
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

        // Own lines (padded by a fifth of a line) are erased by S6, so they count as paper.
        let pad = max(2, Int((CGFloat(emX) * 0.2).rounded()))
        let own = block.lines.compactMap { cells($0.bounds) }.map {
            (x0: $0.x0 - pad, y0: $0.y0 - pad, x1: $0.x1 + pad, y1: $0.y1 + pad)
        }
        func slowDirty(_ x: Int, _ y: Int) -> Bool {
            if blocked.contains(where: { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }) { return true }
            guard abs(Int(raster.pixels[y * width + x]) - paper) > inkDistance else { return false }
            return !own.contains { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }
        }
        // `slowDirty` tabulated once over the limit and source (every cell the growth reads on clean paper).
        let region: Box = toned ? (0, 0, 0, 0) : (min(limit.x0, start.x0), min(limit.y0, start.y0),
                                                  max(limit.x1, start.x1), max(limit.y1, start.y1))
        let regionWidth = region.x1 - region.x0
        let mask = toned ? [] : dirtyMask(region, raster: raster, paper: paper, own: own, blocked: blocked)
        func dirty(_ x: Int, _ y: Int) -> Bool {
            guard x >= region.x0, x < region.x1, y >= region.y0, y < region.y1 else { return slowDirty(x, y) }
            return mask[(y - region.y0) * regionWidth + x - region.x0]
        }
        // Each side in turn (left, right, top, bottom), while the strip spares other text and balloons
        // (and, on clean paper past `edgeGuard`, holds <= `edgeShare` ink).
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
                if !toned, area(best) >= edgeGuard * area(start) {
                    var ink = 0
                    if best.x0 <= best.x1, best.y0 <= best.y1 {
                        // `next` holds `best` and differs on one side: count only that strip.
                        let strip: Box
                        switch side {
                        case 0: strip = (next.x0, next.y0, best.x0, next.y1)
                        case 1: strip = (best.x1, next.y0, next.x1, next.y1)
                        case 2: strip = (next.x0, next.y0, next.x1, best.y0)
                        default: strip = (next.x0, best.y1, next.x1, next.y1)
                        }
                        for y in strip.y0..<strip.y1 { for x in strip.x0..<strip.x1 where dirty(x, y) { ink += 1 } }
                    } else {
                        for y in next.y0..<next.y1 {
                            for x in next.x0..<next.x1 where (x < best.x0 || x >= best.x1 || y < best.y0 || y >= best.y1) && dirty(x, y) {
                                ink += 1
                            }
                        }
                    }
                    guard Double(ink) <= Double(strip) * edgeShare else { break }
                }
                best = next
            }
        }
        guard best != start else { return nil }
        guard !toned else { return (best, nil) }
        // An enclosed balloon's tail-free lobe replaces the grown box unless it keeps < `lobeShare`.
        // The limit lies inside the tabulated region: its rows of the mask are the lobe's ink.
        var ink = [Bool](); let limitWidth = limit.x1 - limit.x0
        if limitWidth > 4, limit.y1 - limit.y0 > 4 {
            ink.reserveCapacity(limitWidth * (limit.y1 - limit.y0))
            for y in limit.y0..<limit.y1 {
                let row = (y - region.y0) * regionWidth + limit.x0 - region.x0
                ink.append(contentsOf: mask[row..<(row + limitWidth)])
            }
        }
        let box = lobeRect(limit, source: start, ink: ink).flatMap { Double(area($0)) >= lobeShare * Double(area(best)) ? $0 : nil } ?? best
        // Row spans: per row, the clean half-width about the source centre column, for the contiguous
        // rows around the centre, kept only when some row is wider than the rectangle.
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
        return (box, (first: top, centre: centre, halves: halves))
    }

    /// Ink (|gray - paper| > `inkDistance`) outside the own boxes, or inside an avoided balloon, per cell of `region`.
    private static func dirtyMask(_ region: Box, raster: PipelineGrayRaster, paper: Int, own: [Box], blocked: [Box]) -> [Bool] {
        let w = region.x1 - region.x0, h = region.y1 - region.y0
        guard w > 0, h > 0 else { return [] }
        var mask = [Bool](repeating: false, count: w * h)
        let width = raster.width
        // |gray - paper| > inkDistance, as one unsigned compare: gray outside [low, low + span].
        let low = UInt8(clamping: paper - inkDistance), span = UInt8(clamping: paper + inkDistance) &- low
        mask.withUnsafeMutableBufferPointer { mask in
            raster.pixels.withUnsafeBufferPointer { pixels in
                for y in 0..<h {
                    let source = (y + region.y0) * width + region.x0, target = y * w
                    for x in 0..<w { mask[target + x] = pixels[source + x] &- low > span }
                }
            }
            func fill(_ box: Box, _ value: Bool) {
                let x0 = max(box.x0, region.x0), x1 = min(box.x1, region.x1)
                let y0 = max(box.y0, region.y0), y1 = min(box.y1, region.y1)
                guard x0 < x1, y0 < y1 else { return }
                for y in y0..<y1 {
                    let row = (y - region.y0) * w - region.x0
                    for x in x0..<x1 { mask[row + x] = value }
                }
            }
            for box in own { fill(box, false) }
            for box in blocked { fill(box, true) }
        }
        return mask
    }

    /// Balloon lobes: the paper connected to the source is split at its distance cores; the lobe
    /// holding >= 70% of the source yields the largest centred rectangle inscribed in its rows.
    static func lobeRect(_ box: Box, source: Box, dirty: (Int, Int) -> Bool) -> Box? {
        let w = box.x1 - box.x0, h = box.y1 - box.y0
        guard w > 4, h > 4 else { return nil }
        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { ink[y * w + x] = dirty(x + box.x0, y + box.y0) } }
        return lobeRect(box, source: source, ink: ink)
    }

    /// `lobeRect` on the box's dirty cells, row-major (`ink[(y - box.y0) * width + x - box.x0]`).
    /// Flat loops over raw buffers, the fill bounded by its first border cell and the rest by the paper box.
    static func lobeRect(_ box: Box, source: Box, ink: [Bool]) -> Box? {
        let w = box.x1 - box.x0, h = box.y1 - box.y0
        // The source must overlap the box (the seed loops below would trap on an inverted range).
        guard w > 4, h > 4, ink.count == w * h, max(box.x0, source.x0) < min(box.x1, source.x1),
              max(box.y0, source.y0) < min(box.y1, source.y1)
        else { return nil }
        let sx0 = max(box.x0, source.x0) - box.x0, sx1 = min(box.x1, source.x1) - box.x0
        let sy0 = max(box.y0, source.y0) - box.y0, sy1 = min(box.y1, source.y1) - box.y0
        // Paper 4-connected to the source box. Only an enclosed balloon counts: paper reaching the
        // growth limit is open lettering space, so the fill stops at the first border cell.
        let mask = UnsafeMutableBufferPointer<Bool>.allocate(capacity: w * h)
        mask.initialize(repeating: false)
        defer { mask.deallocate() }
        let queue = UnsafeMutableBufferPointer<Int32>.allocate(capacity: w * h)
        defer { queue.deallocate() }
        var count = 0
        let enclosed: Bool = ink.withUnsafeBufferPointer { ink in
            for y in sy0..<sy1 {
                for x in sx0..<sx1 where !ink[y * w + x] {
                    if x == 0 || x == w - 1 || y == 0 || y == h - 1 { return false }
                    mask[y * w + x] = true
                    queue[count] = Int32(y * w + x)
                    count += 1
                }
            }
            var head = 0
            while head < count {
                let cell = Int(queue[head]), x = cell % w, y = cell / w
                head += 1
                // Left, right, up, down (a step onto the border column or row ends the fill).
                if x > 0, !mask[cell - 1], !ink[cell - 1] {
                    if x - 1 == 0 || y == 0 || y == h - 1 { return false }
                    mask[cell - 1] = true; queue[count] = Int32(cell - 1); count += 1
                }
                if x + 1 < w, !mask[cell + 1], !ink[cell + 1] {
                    if x + 1 == w - 1 || y == 0 || y == h - 1 { return false }
                    mask[cell + 1] = true; queue[count] = Int32(cell + 1); count += 1
                }
                if y > 0, !mask[cell - w], !ink[cell - w] {
                    if y - 1 == 0 || x == 0 || x == w - 1 { return false }
                    mask[cell - w] = true; queue[count] = Int32(cell - w); count += 1
                }
                if y + 1 < h, !mask[cell + w], !ink[cell + w] {
                    if y + 1 == h - 1 || x == 0 || x == w - 1 { return false }
                    mask[cell + w] = true; queue[count] = Int32(cell + w); count += 1
                }
            }
            return true
        }
        guard enclosed, count > 0 else { return nil }
        // Everything below reads only the paper and its zero ring: work in the paper's bounding box
        // plus one cell (it never touches the box border), mapped back to box cells at the end.
        var minX = w, maxX = -1, minY = h, maxY = -1
        for index in 0..<count {
            let cell = Int(queue[index]), x = cell % w, y = cell / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        let ox = minX - 1, oy = minY - 1
        let cw = maxX + 2 - ox, ch = maxY + 2 - oy, cells = cw * ch
        let paper = UnsafeMutableBufferPointer<Bool>.allocate(capacity: cells)
        defer { paper.deallocate() }
        for y in 0..<ch { for x in 0..<cw { paper[y * cw + x] = mask[(y + oy) * w + x + ox] } }
        // Chamfer (3-4) distance to the nearest non-paper cell.
        let dist = UnsafeMutableBufferPointer<Int>.allocate(capacity: cells)
        defer { dist.deallocate() }
        for cell in 0..<cells { dist[cell] = paper[cell] ? Int.max / 2 : 0 }
        // Forward pass row-major, backward pass in reverse; each reads the already-swept neighbours.
        for pass in 0..<2 {
            let d = pass == 0 ? -1 : 1
            for k in 0..<ch {
                let y = pass == 0 ? k : ch - 1 - k
                for j in 0..<cw {
                    let x = pass == 0 ? j : cw - 1 - j, cell = y * cw + x
                    guard dist[cell] > 0 else { continue }
                    var best = (x == 0 || y == 0 || x == cw - 1 || y == ch - 1) ? 3 : dist[cell]
                    // The row before (forward pass) or after (backward pass): above/below 3, diagonals 4.
                    if y + d >= 0, y + d < ch {
                        let row = (y + d) * cw + x
                        best = min(best, dist[row] + 3)
                        if x > 0 { best = min(best, dist[row - 1] + 4) }
                        if x + 1 < cw { best = min(best, dist[row + 1] + 4) }
                    }
                    if x + d >= 0, x + d < cw { best = min(best, dist[cell + d] + 3) }
                    dist[cell] = best
                }
            }
        }
        var peak = 0
        for cell in 0..<cells { peak = max(peak, dist[cell]) }
        guard peak >= 6 else { return nil }
        // Core components, then every paper cell joins its geodesically nearest seed core.
        let core = UnsafeMutableBufferPointer<Bool>.allocate(capacity: cells)
        defer { core.deallocate() }
        var coreCount = 0
        for cell in 0..<cells {
            core[cell] = Double(dist[cell]) >= Double(peak) * 0.32
            if core[cell] { coreCount += 1 }
        }
        let label = UnsafeMutableBufferPointer<Int>.allocate(capacity: cells)
        label.initialize(repeating: -1)
        defer { label.deallocate() }
        // `queue` (w * h >= cells) holds each component, then the frontier.
        var seeds = 0
        for start in 0..<cells where core[start] && label[start] < 0 {
            var size = 1, index = 0
            queue[0] = Int32(start)
            label[start] = seeds
            while index < size {
                let cell = Int(queue[index]), x = cell % cw, y = cell / cw
                index += 1
                for dy in -1...1 {
                    for dx in -1...1 where x + dx >= 0 && x + dx < cw && y + dy >= 0 && y + dy < ch {
                        let next = (y + dy) * cw + x + dx
                        if core[next], label[next] < 0 { label[next] = seeds; queue[size] = Int32(next); size += 1 }
                    }
                }
            }
            if size >= max(4, coreCount * 3 / 100) {
                seeds += 1
            } else {
                for index in 0..<size { label[Int(queue[index])] = -2 }
            }
        }
        guard seeds > 0 else { return nil }
        var frontier = 0
        for cell in 0..<cells {
            if label[cell] >= 0 { queue[frontier] = Int32(cell); frontier += 1 } else { label[cell] = -1 }
        }
        var head = 0
        while head < frontier {
            let cell = Int(queue[head]), x = cell % cw, y = cell / cw
            head += 1
            let own = label[cell]
            if x > 0, paper[cell - 1], label[cell - 1] < 0 { label[cell - 1] = own; queue[frontier] = Int32(cell - 1); frontier += 1 }
            if x + 1 < cw, paper[cell + 1], label[cell + 1] < 0 { label[cell + 1] = own; queue[frontier] = Int32(cell + 1); frontier += 1 }
            if y > 0, paper[cell - cw], label[cell - cw] < 0 { label[cell - cw] = own; queue[frontier] = Int32(cell - cw); frontier += 1 }
            if y + 1 < ch, paper[cell + cw], label[cell + cw] < 0 { label[cell + cw] = own; queue[frontier] = Int32(cell + cw); frontier += 1 }
        }
        // The lobe covering most of the source, when it covers >= 70%.
        var cover = [Int](repeating: 0, count: seeds)
        let cy0 = max(sy0 - oy, 0), cy1 = min(sy1 - oy, ch), cx0 = max(sx0 - ox, 0), cx1 = min(sx1 - ox, cw)
        if cy0 < cy1, cx0 < cx1 {
            for y in cy0..<cy1 {
                for x in cx0..<cx1 where label[y * cw + x] >= 0 { cover[label[y * cw + x]] += 1 }
            }
        }
        guard let lobe = cover.indices.max(by: { cover[$0] < cover[$1] }),
              Double(cover[lobe]) >= 0.7 * Double((source.x1 - source.x0) * (source.y1 - source.y0)) else { return nil }
        var left = [Int](repeating: w, count: h), right = [Int](repeating: 0, count: h)
        var weight = 0.0, cx = 0.0, cy = 0.0
        for row in 0..<ch { for column in 0..<cw where label[row * cw + column] == lobe {
            let cell = row * cw + column, x = column + ox, y = row + oy, value = Double(dist[cell] * dist[cell])
            left[y] = min(left[y], x)
            right[y] = max(right[y], x + 1)
            weight += value
            cx += Double(x) * value
            cy += Double(y) * value
        } }
        cx /= weight
        cy /= weight
        let rows = Set((0...48).map { $0 * h / 48 } + [Int(cy.rounded())]).sorted()
        var best: (score: Double, rect: Box)?
        for (i, a) in rows.enumerated() where Double(a) <= cy {
            // left[a..<b].max() and right[a..<b].min(), extended as b grows.
            var lo = Int.min, hi = Int.max, end = a
            for b in rows[(i + 1)...] {
                while end < b { lo = max(lo, left[end]); hi = min(hi, right[end]); end += 1 }
                guard Double(b) >= cy else { continue }
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
