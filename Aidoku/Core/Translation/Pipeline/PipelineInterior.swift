import CoreGraphics
import Foundation

// S4b: free lettering space around each block on the S4 gray raster (RF-DETR balloons are often
// missing or wrong). The rule grows the bounds per side, stopped by other text and balloons, the panel,
// the line reach and ink; for blocks a gate places in a balloon, a side model on the block's paper
// component replaces it (`PipelineLearnedInterior`). The result becomes `PipelineBlock.balloon`, the box
// S9 fits into, with `rows` for rounded balloons.
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

    /// The rule box (`ruleApply`), replaced for blocks the balloon gate accepts by the side model's box
    /// (`PipelineInteriorModel`); without the model file the rule box stays.
    static func apply(_ blocks: [PipelineBlock], raster: PipelineGrayRaster?, pageSize: CGSize,
                      layout: [PipelineLayoutRegion] = [], model: PipelineInteriorModel? = .shared) -> [PipelineBlock] {
        let ruled = ruleApply(blocks, raster: raster, pageSize: pageSize, layout: layout)
        guard let model, let raster, raster.width > 2, raster.height > 2, raster.pixels.count == raster.width * raster.height,
              pageSize.width >= 1, pageSize.height >= 1 else { return ruled }
        return PipelineLearnedInterior.apply(blocks, ruled: ruled, raster: raster, pageSize: pageSize, model: model)
    }

    /// The grow rule: free lettering space per side, stopped by other text, balloons, panel, reach and ink.
    static func ruleApply(_ blocks: [PipelineBlock], raster: PipelineGrayRaster?, pageSize: CGSize,
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

/// S4b side model and balloon gate (Resources/Translation/PipelineInterior.json, fit on TRAIN pages):
/// LightGBM trees as flat arrays (`x[f] <= t` goes left; a negative child is leaf `-child - 1`).
struct PipelineInteriorModel: Decodable, Sendable {
    struct Tree: Decodable, Sendable {
        let f: [Int], t: [Double], l: [Int], r: [Int], v: [Double]
    }

    struct Forest: Decodable, Sendable {
        let trees: [Tree]

        func sum(_ x: [Double]) -> Double {
            var total = 0.0
            for tree in trees {
                var node = 0
                while node >= 0 { node = x[tree.f[node]] <= tree.t[node] ? tree.l[node] : tree.r[node] }
                total += tree.v[-node - 1]
            }
            return total
        }
    }

    /// Least gate probability for the model box.
    let threshold: Double
    /// Outward offset of one side in line thicknesses (quantile 0.35), from `PipelineLearnedInterior.sideFeatures`.
    let joint: Forest
    /// Log-odds that the block lies in a balloon or narration box, from `PipelineLearnedInterior.gateFeatures`.
    let gate: Forest

    static let shared: PipelineInteriorModel? = {
        var urls = [Bundle.main.url(forResource: "PipelineInterior", withExtension: "json")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineInterior.json"))
        }
        return urls.lazy.compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(PipelineInteriorModel.self, from: $0) }.first
    }()
}

/// The learned S4b box: the block's paper component (flood from the text box over cells within 64 gray levels of
/// the paper, own lines erased, inside the text box +- 14 line thicknesses and the panel) gives a candidate box
/// (the largest rectangle in the block's share of it); side profiles of ink, other text and the panel plus the
/// candidate offsets feed one side model, and a gate keeps the rule box for free text.
enum PipelineLearnedInterior {
    typealias Box = PipelineInterior.Box
    static let windowReach = 14, closing = 2, openReach = 3, profileReach: CGFloat = 20
    static let missing = -100.0
    /// Component paths, as feature codes.
    enum Path: Int { case none, toned, open, openRF, enclosed, tonedRF, closed }

    struct Grid {
        let raster: PipelineGrayRaster, sx: CGFloat, sy: CGFloat
        var width: Int { raster.width }
        var height: Int { raster.height }

        func cells(_ rect: CGRect?) -> Box? {
            guard let rect, !rect.isNull, rect.width > 0, rect.height > 0,
                  [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite && abs($0) < 1e9 }) else { return nil }
            let x0 = max(0, Int((rect.minX * sx).rounded(.down))), x1 = min(width, Int((rect.maxX * sx).rounded(.up)))
            let y0 = max(0, Int((rect.minY * sy).rounded(.down))), y1 = min(height, Int((rect.maxY * sy).rounded(.up)))
            return x0 < x1 && y0 < y1 ? (x0, y0, x1, y1) : nil
        }

        /// Nearest cell edges.
        func rounded(_ rect: CGRect?) -> Box? {
            guard let rect, !rect.isNull, [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite }) else { return nil }
            return (Int((rect.minX * sx).rounded()), Int((rect.minY * sy).rounded()),
                    Int((rect.maxX * sx).rounded()), Int((rect.maxY * sy).rounded()))
        }

        func rect(_ box: Box) -> CGRect {
            CGRect(x: CGFloat(box.x0) / sx, y: CGFloat(box.y0) / sy,
                   width: CGFloat(box.x1 - box.x0) / sx, height: CGFloat(box.y1 - box.y0) / sy)
        }

        func gray(_ x: Int, _ y: Int) -> Int { Int(raster.pixels[y * width + x]) }
    }

    static func apply(_ blocks: [PipelineBlock], ruled: [PipelineBlock], raster: PipelineGrayRaster, pageSize: CGSize,
                      model: PipelineInteriorModel) -> [PipelineBlock] {
        let grid = Grid(raster: raster, sx: CGFloat(raster.width) / pageSize.width, sy: CGFloat(raster.height) / pageSize.height)
        let text = blocks.map { $0.role != .background ? grid.cells($0.bounds) : nil }
        return ruled.indices.map { index in
            var block = ruled[index]
            guard let item = Item(index, blocks: blocks, ruled: ruled, text: text, grid: grid),
                  1 / (1 + exp(-model.gate.sum(item.gateFeatures))) >= model.threshold else { return block }
            let offsets = (0..<4).map { max(0, model.joint.sum(item.sideFeatures($0))) }
            let s = item.source, e = Double(item.em)
            let box: Box = (max(0, Int((Double(s.x0) - offsets[0] * e).rounded())),
                            max(0, Int((Double(s.y0) - offsets[2] * e).rounded())),
                            min(grid.width, Int((Double(s.x1) + offsets[1] * e).rounded())),
                            min(grid.height, Int((Double(s.y1) + offsets[3] * e).rounded())))
            block.balloon = grid.rect(box)
            block.rows = item.component.flatMap { rows($0, box: box, grid: grid) }
            return block
        }
    }

    /// One block's features.
    struct Item {
        let source: Box
        let em: CGFloat
        let general: [Double]
        let profiles: [[Double]]
        let offsets: [[Double]]   // comp, comp_c2, rule, RF inscribed, RF (left, right, top, bottom)
        let component: Mask?

        init?(_ index: Int, blocks: [PipelineBlock], ruled: [PipelineBlock], text: [Box?], grid: Grid) {
            let block = blocks[index]
            guard let s = text[index], !block.lines.isEmpty else { return nil }
            let thickness = block.lines.map { block.vertical ? $0.bounds.width : $0.bounds.height }.sorted()
            let line = thickness[thickness.count / 2]
            let em = max(1, line * grid.sx), cells = max(1, Int((line * grid.sx).rounded(.up)))
            let (paper, toned) = PipelineLearnedInterior.paper(grid, s)
            let panel = ruled[index].panel
            let rule = grid.rounded(ruled[index].balloon), rf = grid.cells(block.balloon)
            var inscribed: Box?
            if let balloon = block.balloon {
                let k = (1 - PipelineInterior.ellipseInscribed) / 2
                inscribed = grid.rounded(balloon.insetBy(dx: balloon.width * k, dy: balloon.height * k).union(block.bounds))
            }
            let pass = PipelineLearnedInterior.component(index, blocks: blocks, text: text, grid: grid, em: cells,
                                                         paper: paper, toned: toned, panel: panel)
            let comp = pass.map { $0.box } ?? rule, second = pass.map { $0.closedBox } ?? rule
            source = s
            self.em = em
            component = pass?.mask
            general = [Double(CGFloat(s.x1 - s.x0) / em), Double(CGFloat(s.y1 - s.y0) / em), block.vertical ? 1 : 0,
                       Double(block.lines.count), toned ? 1 : 0, rf != nil ? 1 : 0,
                       Double((pass?.path ?? .none).rawValue), Double((pass?.closedPath ?? .none).rawValue)]
            profiles = PipelineLearnedInterior.profiles(index, blocks: blocks, text: text, grid: grid, em: em, paper: paper,
                                                        panel: grid.cells(panel))
            func outward(_ box: Box?) -> [Double] {
                guard let box else { return [Double](repeating: PipelineLearnedInterior.missing, count: 4) }
                return [Double(CGFloat(s.x0 - box.x0) / em), Double(CGFloat(box.x1 - s.x1) / em),
                        Double(CGFloat(s.y0 - box.y0) / em), Double(CGFloat(box.y1 - s.y1) / em)]
            }
            offsets = [outward(comp), outward(second), outward(rule), outward(inscribed), outward(rf)]
        }

        /// Side model input: side, general, profiles and offsets with this side first.
        func sideFeatures(_ side: Int) -> [Double] {
            let order = [side] + (0..<4).filter { $0 != side }
            var x = [Double(side)] + general
            for t in order { x += profiles[t] }
            for o in offsets { x += order.map { o[$0] } }
            return x
        }

        /// Gate input: general, profiles, then the comp, rule, RF inscribed and RF offsets.
        var gateFeatures: [Double] {
            var x = general
            for p in profiles { x += p }
            for k in [0, 2, 3, 4] { x += offsets[k] }
            return x
        }
    }

    /// Paper level of the text box: the mean of its most common 16-level band; toned for mid-gray paper.
    static func paper(_ grid: Grid, _ s: Box) -> (Int, Bool) {
        var bands = [Int](repeating: 0, count: 16), sums = [Int](repeating: 0, count: 16)
        for y in s.y0..<s.y1 { for x in s.x0..<s.x1 { let v = grid.gray(x, y); bands[v >> 4] += 1; sums[v >> 4] += v } }
        let band = bands.indices.max { bands[$0] < bands[$1] } ?? 15
        let paper = bands[band] > 0 ? sums[band] / bands[band] : 255
        return (paper, bands[band] == 0 || (96 < paper && paper < 160))
    }

    /// Cells of a window, row-major.
    struct Mask {
        let x0: Int, y0: Int, width: Int, height: Int
        var on: [Bool]
    }

    struct Pass {
        let box: Box, path: Path, closedBox: Box, closedPath: Path
        let mask: Mask
    }

    /// Ink in a window, thresholded on first use; own lines (padded) are paper.
    struct Ink {
        let grid: Grid, x0: Int, y0: Int, width: Int, height: Int, paper: Int
        var state: [UInt8]

        init(grid: Grid, window: Box, paper: Int, own: [Box]) {
            self.grid = grid; self.paper = paper
            x0 = window.x0; y0 = window.y0; width = window.x1 - window.x0; height = window.y1 - window.y0
            state = [UInt8](repeating: 0, count: width * height)
            for b in own {
                let bx0 = max(b.x0, x0), bx1 = min(b.x1, window.x1), by0 = max(b.y0, y0), by1 = min(b.y1, window.y1)
                guard bx0 < bx1, by0 < by1 else { continue }
                for y in by0..<by1 { for x in bx0..<bx1 { state[(y - y0) * width + x - x0] = 1 } }
            }
        }

        /// Window-relative cell.
        mutating func dirty(_ x: Int, _ y: Int) -> Bool {
            let i = y * width + x
            if state[i] == 0 { state[i] = abs(grid.gray(x + x0, y + y0) - paper) > 64 ? 2 : 1 }
            return state[i] == 2
        }
    }

    static func ownBoxes(_ block: PipelineBlock, grid: Grid, pad: Int) -> [Box] {
        block.lines.compactMap { grid.cells($0.bounds) }.map { ($0.x0 - pad, $0.y0 - pad, $0.x1 + pad, $0.y1 + pad) }
    }

    /// 4-connected paper cells (no ink within `radius` cells) reached from the paper of `seed` (window-relative);
    /// nil if there is none, or when `stopAtBorder` and the flood reaches the window border.
    static func flood(_ ink: inout Ink, seed: Box, radius: Int, stopAtBorder: Bool) -> (on: [Bool], bounds: Box)? {
        let width = ink.width, height = ink.height, x0 = ink.x0, y0 = ink.y0, paper = ink.paper, stride = ink.grid.width
        var on = [Bool](repeating: false, count: width * height)
        var queue = [Int32](unsafeUninitializedCapacity: 2 * width * height) { _, count in count = 2 * width * height }
        var count = 0, reached = false, bx0 = width, by0 = height, bx1 = 0, by1 = 0
        // Closed test per cell, once (0 unknown, 1 free, 2 near ink).
        var closedState = [UInt8](repeating: 0, count: radius > 0 ? width * height : 0)
        ink.grid.raster.pixels.withUnsafeBufferPointer { pixels in
            ink.state.withUnsafeMutableBufferPointer { state in
              closedState.withUnsafeMutableBufferPointer { closedState in
                on.withUnsafeMutableBufferPointer { on in
                    queue.withUnsafeMutableBufferPointer { queue in
                        @inline(__always) func dirty(_ x: Int, _ y: Int) -> Bool {
                            let i = y * width + x
                            var v = state[i]
                            if v == 0 {
                                v = abs(Int(pixels[(y + y0) * stride + x + x0]) - paper) > 64 ? 2 : 1
                                state[i] = v
                            }
                            return v == 2
                        }
                        @inline(__always) func free(_ x: Int, _ y: Int) -> Bool {
                            guard radius > 0 else { return !dirty(x, y) }
                            let i = y * width + x
                            if closedState[i] == 0 {
                                closedState[i] = 1
                                search: for dy in -radius...radius where y + dy >= 0 && y + dy < height {
                                    let r = radius - abs(dy)
                                    for dx in -r...r where x + dx >= 0 && x + dx < width && dirty(x + dx, y + dy) {
                                        closedState[i] = 2
                                        break search
                                    }
                                }
                            }
                            return closedState[i] == 1
                        }
                        @inline(__always) func push(_ x: Int, _ y: Int) {
                            let i = y * width + x
                            guard !on[i], free(x, y) else { return }
                            on[i] = true
                            queue[2 * count] = Int32(x)
                            queue[2 * count + 1] = Int32(y)
                            count += 1
                            bx0 = min(bx0, x); bx1 = max(bx1, x + 1); by0 = min(by0, y); by1 = max(by1, y + 1)
                            if x == 0 || y == 0 || x == width - 1 || y == height - 1 { reached = true }
                        }
                        for y in seed.y0..<seed.y1 { for x in seed.x0..<seed.x1 { push(x, y) } }
                        var head = 0
                        while head < count, !(stopAtBorder && reached) {
                            let x = Int(queue[2 * head]), y = Int(queue[2 * head + 1])
                            head += 1
                            if x > 0 { push(x - 1, y) }
                            if x + 1 < width { push(x + 1, y) }
                            if y > 0 { push(x, y - 1) }
                            if y + 1 < height { push(x, y + 1) }
                        }
                    }
                }
              }
            }
        }
        return count == 0 || (stopAtBorder && reached) ? nil : (on, (bx0, by0, bx1, by1))
    }

    static func touchesBorder(_ on: [Bool], width: Int, height: Int) -> Bool {
        for x in 0..<width where on[x] || on[(height - 1) * width + x] { return true }
        for y in 0..<height where on[y * width] || on[y * width + width - 1] { return true }
        return false
    }

    /// The paper component and its candidate box; a component reaching the window is retried with the ink closed
    /// by `closing` cells, else clipped to the RF balloon or the text box +- `reach` line thicknesses.
    static func component(_ index: Int, blocks: [PipelineBlock], text: [Box?], grid: Grid, em: Int, paper: Int,
                          toned: Bool, panel: CGRect?) -> Pass? {
        let block = blocks[index]
        guard let s = text[index] else { return nil }
        var window: Box = (max(0, s.x0 - windowReach * em), max(0, s.y0 - windowReach * em),
                           min(grid.width, s.x1 + windowReach * em), min(grid.height, s.y1 + windowReach * em))
        if let p = grid.cells(panel) {
            window = (max(window.x0, p.x0), max(window.y0, p.y0), min(window.x1, p.x1), min(window.y1, p.y1))
        }
        guard window.x0 < window.x1, window.y0 < window.y1 else { return nil }
        let w = window.x1 - window.x0, h = window.y1 - window.y0
        let pad = max(2, Int((CGFloat(em) * 0.2).rounded()))
        var ink = Ink(grid: grid, window: window, paper: paper, own: ownBoxes(block, grid: grid, pad: pad))
        let s0: Box = (max(0, s.x0 - window.x0), max(0, s.y0 - window.y0), min(window.x1, s.x1) - window.x0, min(window.y1, s.y1) - window.y0)
        guard s0.x0 < s0.x1, s0.y0 < s0.y1, let first = flood(&ink, seed: s0, radius: 0, stopAtBorder: false) else { return nil }
        let touches = first.bounds.x0 == 0 || first.bounds.y0 == 0 || first.bounds.x1 == w || first.bounds.y1 == h
        var variants: [(on: [Bool], bounds: Box, open: Bool, path: Path)] =
            [(first.on, first.bounds, touches, toned ? .toned : touches ? .open : .enclosed)]
        // A closed flood reaching the border reaches it after the dilation too: it is dropped as soon as it does.
        if touches, let core = flood(&ink, seed: s0, radius: closing, stopAtBorder: true) {
            // Dilate back by `closing` cells, onto paper only.
            var closed = core.on
            let b = core.bounds
            let grown: Box = (max(0, b.x0 - closing), max(0, b.y0 - closing), min(w, b.x1 + closing), min(h, b.y1 + closing))
            for y in b.y0..<b.y1 { for x in b.x0..<b.x1 where core.on[y * w + x] {
                for dy in -closing...closing {
                    let r = closing - abs(dy)
                    for dx in -r...r where x + dx >= 0 && x + dx < w && y + dy >= 0 && y + dy < h { closed[(y + dy) * w + x + dx] = true }
                }
            } }
            for y in grown.y0..<grown.y1 { for x in grown.x0..<grown.x1 where closed[y * w + x] && ink.dirty(x, y) { closed[y * w + x] = false } }
            if !touchesBorder(closed, width: w, height: h) { variants.append((closed, grown, false, toned ? .toned : .closed)) }
        }
        var results: [(Box, Path, Mask)] = []
        for (on, onBounds, open, base) in variants {
            var path = base, keep: Box?
            if open {
                if block.balloon != nil {
                    path = base == .toned ? .tonedRF : .openRF
                    keep = grid.cells(block.balloon).map { ($0.x0 - window.x0, $0.y0 - window.y0, $0.x1 - window.x0, $0.y1 - window.y0) }
                        ?? (0, 0, 0, 0)
                } else {
                    keep = (s.x0 - openReach * em - window.x0, s.y0 - openReach * em - window.y0,
                            s.x1 + openReach * em - window.x0, s.y1 + openReach * em - window.y0)
                }
            }
            var mask = Mask(x0: window.x0, y0: window.y0, width: w, height: h, on: on)
            if let keep {
                for y in onBounds.y0..<onBounds.y1 {
                    for x in onBounds.x0..<onBounds.x1 where mask.on[y * w + x] && !(x >= keep.x0 && x < keep.x1 && y >= keep.y0 && y < keep.y1) {
                        mask.on[y * w + x] = false
                    }
                }
            }
            // Everything below changes cells only inside the on cells' bounds and the text box.
            var bounds = s0
            if let b = extent(mask, within: onBounds) {
                fillHoles(&mask, b)
                bounds = (min(b.x0, s0.x0), min(b.y0, s0.y0), max(b.x1, s0.x1), max(b.y1, s0.y1))
            }
            for y in s0.y0..<s0.y1 { for x in s0.x0..<s0.x1 { mask.on[y * w + x] = true } }
            share(&mask, bounds, index: index, text: text, s0: s0)
            let r = maxRect(mask, bounds)
            results.append(((min(r.x0 + window.x0, s.x0), min(r.y0 + window.y0, s.y0),
                             max(r.x1 + window.x0, s.x1), max(r.y1 + window.y0, s.y1)), path, mask))
        }
        let second = results.count > 1 ? results[1] : results[0]
        return Pass(box: results[0].0, path: results[0].1, closedBox: second.0, closedPath: second.1, mask: results[0].2)
    }

    /// Off cells of the mask's bounding box that do not reach its border through off cells become on.
    static func fillHoles(_ mask: inout Mask, _ bounds: Box) {
        let w = mask.width
        let bw = bounds.x1 - bounds.x0, bh = bounds.y1 - bounds.y0
        var outside = [Bool](repeating: false, count: bw * bh), queue: [Int32] = []
        func visit(_ x: Int, _ y: Int) {
            let i = y * bw + x
            guard !outside[i], !mask.on[(y + bounds.y0) * w + x + bounds.x0] else { return }
            outside[i] = true; queue.append(Int32(i))
        }
        for x in 0..<bw { visit(x, 0); visit(x, bh - 1) }
        for y in 0..<bh { visit(0, y); visit(bw - 1, y) }
        var head = 0
        while head < queue.count {
            let i = Int(queue[head]), x = i % bw, y = i / bw
            head += 1
            if x > 0 { visit(x - 1, y) }
            if x + 1 < bw { visit(x + 1, y) }
            if y > 0 { visit(x, y - 1) }
            if y + 1 < bh { visit(x, y + 1) }
        }
        for y in 0..<bh { for x in 0..<bw where !outside[y * bw + x] { mask.on[(y + bounds.y0) * w + x + bounds.x0] = true } }
    }

    /// Bounding box of the on cells inside `within` (window-relative).
    static func extent(_ mask: Mask, within: Box) -> Box? {
        var x0 = mask.width, y0 = mask.height, x1 = -1, y1 = -1
        for y in within.y0..<within.y1 { for x in within.x0..<within.x1 where mask.on[y * mask.width + x] {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        return x1 >= 0 ? (x0, y0, x1 + 1, y1 + 1) : nil
    }

    /// Keeps the cells nearer this block's text box than the other text boxes lying >= 50% in the mask
    /// (squared cell distance, ties to this block).
    static func share(_ mask: inout Mask, _ bounds: Box, index: Int, text: [Box?], s0: Box) {
        let w = mask.width, h = mask.height
        var members: [Box] = []
        for (j, c) in text.enumerated() {
            guard j != index, let c else { continue }
            let x0 = max(c.x0 - mask.x0, 0), y0 = max(c.y0 - mask.y0, 0), x1 = min(c.x1 - mask.x0, w), y1 = min(c.y1 - mask.y0, h)
            guard x0 < x1, y0 < y1 else { continue }
            var count = 0
            for y in y0..<y1 { for x in x0..<x1 where mask.on[y * w + x] { count += 1 } }
            if 2 * count >= (c.x1 - c.x0) * (c.y1 - c.y0) {
                members.append((c.x0 - mask.x0, c.y0 - mask.y0, c.x1 - mask.x0, c.y1 - mask.y0))
            }
        }
        guard !members.isEmpty else { return }
        func distance(_ b: Box, _ x: Int, _ y: Int) -> Int {
            let dx = max(b.x0 - x, 0, x - (b.x1 - 1)), dy = max(b.y0 - y, 0, y - (b.y1 - 1))
            return dx * dx + dy * dy
        }
        for y in bounds.y0..<bounds.y1 { for x in bounds.x0..<bounds.x1 where mask.on[y * w + x] {
            let own = distance(s0, x, y)
            if members.contains(where: { distance($0, x, y) < own }) { mask.on[y * w + x] = false }
        } }
        for y in s0.y0..<s0.y1 { for x in s0.x0..<s0.x1 { mask.on[y * w + x] = true } }
    }

    /// Largest all-on rectangle (histogram stack, rows top to bottom; the first of equal areas), window-relative.
    static func maxRect(_ mask: Mask, _ b: Box) -> Box {
        let w = b.x1 - b.x0
        var heights = [Int](repeating: 0, count: w), best = 0, rect: Box = (0, 0, 0, 0)
        var stack: [(start: Int, height: Int)] = []
        for y in b.y0..<b.y1 {
            for x in 0..<w { heights[x] = mask.on[y * mask.width + x + b.x0] ? heights[x] + 1 : 0 }
            stack.removeAll(keepingCapacity: true)
            for x in 0...w {
                let current = x < w ? heights[x] : 0
                var start = x
                while let top = stack.last, top.height >= current {
                    stack.removeLast()
                    start = top.start
                    let area = top.height * (x - start)
                    if area > best { best = area; rect = (start + b.x0, y - top.height + 1, x + b.x0, y + 1) }
                }
                stack.append((start, current))
            }
        }
        return rect
    }

    /// Per side (left, right, top, bottom), along strips across the text box out to text +- 20 line thicknesses:
    /// first distance where the strip's ink share passes 0.05 / 0.2 / 0.5 / 0.9, first other-text contact, distance
    /// to the panel (or raster) edge, all in line thicknesses, and the ink share over the first 1 / 2 / 4.
    static func profiles(_ index: Int, blocks: [PipelineBlock], text: [Box?], grid: Grid, em: CGFloat, paper: Int,
                         panel: Box?) -> [[Double]] {
        guard let s = text[index] else { return [] }
        let d = Int(profileReach * em)
        let window: Box = (max(0, s.x0 - d), max(0, s.y0 - d), min(grid.width, s.x1 + d), min(grid.height, s.y1 + d))
        let own = ownBoxes(blocks[index], grid: grid, pad: max(2, Int((em * 0.2).rounded())))
        let others = text.enumerated().compactMap { $0.offset != index ? $0.element : nil }
        func dirty(_ x: Int, _ y: Int) -> Bool {
            guard abs(grid.gray(x, y) - paper) > 64 else { return false }
            return !own.contains { x >= max($0.x0, window.x0) && x < $0.x1 && y >= max($0.y0, window.y0) && y < $0.y1 }
        }
        let clip = panel ?? (0, 0, grid.width, grid.height)
        let e = Double(em)
        return (0..<4).map { side in
            // Strip k: column (left/right) or row (top/bottom) k + 1 cells outside the text box.
            let length: Int, span: Int, edge: Int
            switch side {
            case 0: length = s.x0 - window.x0; span = s.y1 - s.y0; edge = s.x0 - clip.x0
            case 1: length = window.x1 - s.x1; span = s.y1 - s.y0; edge = clip.x1 - s.x1
            case 2: length = s.y0 - window.y0; span = s.x1 - s.x0; edge = s.y0 - clip.y0
            default: length = window.y1 - s.y1; span = s.x1 - s.x0; edge = clip.y1 - s.y1
            }
            // Other text across the strip line: boxes overlapping the text box's span on the line's position.
            let across = side < 2 ? others.filter { $0.y0 < s.y1 && $0.y1 > s.y0 } : others.filter { $0.x0 < s.x1 && $0.x1 > s.x0 }
            var counts = [Int](repeating: 0, count: length), contact = Double(length)
            for k in 0..<length {
                var ink = 0
                let at = side == 0 ? s.x0 - 1 - k : side == 1 ? s.x1 + k : side == 2 ? s.y0 - 1 - k : s.y1 + k
                let touched = across.contains { side < 2 ? $0.x0 <= at && at < $0.x1 : $0.y0 <= at && at < $0.y1 }
                for j in 0..<span {
                    let (x, y): (Int, Int)
                    switch side {
                    case 0: (x, y) = (s.x0 - 1 - k, s.y0 + j)
                    case 1: (x, y) = (s.x1 + k, s.y0 + j)
                    case 2: (x, y) = (s.x0 + j, s.y0 - 1 - k)
                    default: (x, y) = (s.x0 + j, s.y1 + k)
                    }
                    if dirty(x, y) { ink += 1 }
                }
                counts[k] = ink
                if touched, contact == Double(length) { contact = Double(k) }
            }
            var features = [0.05, 0.2, 0.5, 0.9].map { share in
                Double(counts.firstIndex { Double($0) / Double(span) > share } ?? length) / e
            }
            features += [contact / e, Double(edge) / e]
            for first in [1.0, 2.0, 4.0] {
                let n = min(max(1, Int(first * e)), length)
                features.append(n > 0 ? Double(counts[..<n].reduce(0, +)) / Double(n * span) : 1)
            }
            return features
        }
    }

    /// Row spans of the component through the box centre: per row the centred paper half-width minus one cell,
    /// contiguous rows about the centre row, kept when some row is wider than the box.
    static func rows(_ mask: Mask, box: Box, grid: Grid) -> PipelineRowSpans? {
        let w = mask.width, h = mask.height
        let cx = (box.x0 + box.x1) / 2 - mask.x0, cy = (box.y0 + box.y1) / 2 - mask.y0
        guard cx >= 0, cx < w, cy >= 0, cy < h else { return nil }
        func half(_ y: Int) -> Int {
            guard mask.on[y * w + cx] else { return 0 }
            var left = cx, right = cx
            while left - 1 >= 0, mask.on[y * w + left - 1] { left -= 1 }
            while right + 1 < w, mask.on[y * w + right + 1] { right += 1 }
            return max(0, min(cx - left, right - cx) - 1)
        }
        var halves = [half(cy)], top = cy, bottom = cy
        guard halves[0] > 0 else { return nil }
        while top - 1 >= 0 { let v = half(top - 1); guard v > 0 else { break }; halves.insert(v, at: 0); top -= 1 }
        while bottom + 1 < h { let v = half(bottom + 1); guard v > 0 else { break }; halves.append(v); bottom += 1 }
        guard (halves.max() ?? 0) > (box.x1 - box.x0) / 2 + 1 else { return nil }
        return PipelineRowSpans(top: CGFloat(top + mask.y0) / grid.sy, step: 1 / grid.sy,
                                centre: (CGFloat(cx + mask.x0) + 0.5) / grid.sx, halfWidths: halves.map { CGFloat($0) / grid.sx })
    }
}
