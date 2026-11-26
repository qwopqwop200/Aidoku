import CoreGraphics
import Foundation

/// S3refine, right after the S3 keep gate: learned projection-profile edge snapping of the line boxes
/// (Resources/Translation/PipelineLineBoxes.json; trainer and Python reference Scripts/pipeline/tools/retrain/linebox).
/// The line set is kept. Each of the 4 box edges moves by an offset in line-thickness units that a boosted tree
/// model predicts from an ink projection profile on the S4 gray raster, the S1 text/balloon regions, the other lines,
/// the S2 detector lines and the text shape. The detector quad is stretched onto the new box; text, confidence and
/// the other fields are kept. A line whose refined box is degenerate, or every line without the model or the raster,
/// comes back unchanged. Geometry stays in page pixels; only the pixel windows are read on the raster grid.
enum PipelineLineBoxes {
    /// Boosted trees as flat arrays: `x[f] <= split` goes left, a node with `left < 0` is a leaf.
    struct Forest: Decodable, Sendable {
        let base: Double
        let roots: [Int]
        let feature: [Int]
        let split: [Double]
        let left: [Int]
        let right: [Int]
        let value: [Double]

        /// The baseline plus the leaves, summed tree by tree (the trainer's order).
        func predict(_ x: UnsafeBufferPointer<Double>) -> Double {
            var z = base
            for root in roots {
                var node = root
                while left[node] >= 0 { node = x[feature[node]] <= split[node] ? left[node] : right[node] }
                z += value[node]
            }
            return z
        }
    }

    struct Constants: Decodable, Sendable {
        let ext: Double
        let thresholds: [Double]
        let gaps: [Double]
        let bins: [[Double]]
        let inner: [[Double]]
        let xext: Double
        let tw: Double
        let cgaps: [Double]
        let cbins: [[Double]]
        let cinner: [[Double]]
        let minThickness: Double
        let minSide: Double
    }

    struct Model: Decodable, Sendable {
        let constants: Constants
        /// Text end-character classes 1...6 (end, dots, long vowel, open, close, small kana).
        let charClasses: [String]
        let along: Forest
        let cross: Forest
    }

    static let featureCount = 65

    static let shared: (model: Model, classes: [Set<UInt32>])? = {
        var urls = [Bundle.main.url(forResource: "PipelineLineBoxes", withExtension: "json")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineLineBoxes.json"))
        }
        guard let model = urls.lazy.compactMap({ try? Data(contentsOf: $0) })
            .compactMap({ try? JSONDecoder().decode(Model.self, from: $0) }).first,
            model.constants.thresholds.count == 2 else { return nil }
        return (model, model.charClasses.map { Set($0.unicodeScalars.map(\.value)) })
    }()

    /// The refined lines, in input order (`lines` unchanged without the model or the raster).
    static func refine(_ lines: [PipelineLine], fragments: [PipelineLine], layout: [PipelineLayoutRegion],
                       gray: PipelineGrayRaster?, pageSize: CGSize) -> [PipelineLine] {
        guard let shared, let gray, !lines.isEmpty, gray.width > 0, gray.height > 0,
              gray.pixels.count == gray.width * gray.height, pageSize.width > 0, pageSize.height > 0 else { return lines }
        let model = shared.model
        let page = Page(lines: lines, fragments: fragments, layout: layout, pageSize: pageSize)
        var rows = [Double](repeating: 0, count: 4 * featureCount)
        var scratch = Scratch()
        return gray.pixels.withUnsafeBufferPointer { pixels in
            lines.indices.map { i in
                let meta = features(i, page: page, pixels: pixels, gray: gray, model: model, classes: shared.classes,
                                    rows: &rows, scratch: &scratch)
                var offsets = [Double](repeating: 0, count: 4)
                rows.withUnsafeBufferPointer { all in
                    for side in 0..<4 {
                        let x = UnsafeBufferPointer(rebasing: all[side * featureCount..<(side + 1) * featureCount])
                        offsets[side] = (side < 2 ? model.along : model.cross).predict(x)
                    }
                }
                return apply(lines[i], meta: meta, offsets: offsets, minSide: model.constants.minSide)
            }
        }
    }

    // MARK: geometry

    /// x0, y0, x1, y1; in a line's frame the along axis is y (a horizontal line's box is swapped).
    struct Box {
        var x0, y0, x1, y1: Double
        init(_ r: CGRect) { x0 = r.minX; y0 = r.minY; x1 = r.maxX; y1 = r.maxY }
        init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
        var swapped: Box { Box(y0, x0, y1, x1) }
        func frame(_ vertical: Bool) -> Box { vertical ? self : swapped }
    }

    private struct Page {
        let lines: [PipelineLine]
        let boxes: [Box]
        let fragments: [Box]
        /// S1 text (1) and balloon (2) regions in layout order.
        let regions: [(kind: Int, box: Box)]
        let width: Double, height: Double

        init(lines: [PipelineLine], fragments: [PipelineLine], layout: [PipelineLayoutRegion], pageSize: CGSize) {
            self.lines = lines
            boxes = lines.map { Box($0.bounds) }
            self.fragments = fragments.map { Box($0.bounds) }
            regions = layout.compactMap { r in
                r.kind == .text ? (1, Box(r.bounds)) : r.kind == .balloon ? (2, Box(r.bounds)) : nil
            }
            width = Double(pageSize.width)
            height = Double(pageSize.height)
        }
    }

    /// Per-line buffers, reused across lines.
    private struct Scratch {
        var crop: [UInt8] = []
        var along: [[Int]] = [[], []]
        var cross: [[Int]] = [[], []]
        var marginLeft: [Int] = []
        var marginRight: [Int] = []
    }

    private struct Meta {
        let vertical: Bool
        let box: Box
        let thickness: Double
    }

    private static func nearest(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

    /// [a, b) clamped to [0, n] with b >= a (a numpy slice for a, b >= 0).
    private static func clamp(_ a: Int, _ b: Int, _ n: Int) -> (Int, Int) {
        let lo = min(max(a, 0), n)
        return (lo, min(max(b, lo), n))
    }

    private static func prefix(_ counts: [Int]) -> [Int] {
        var sums = [Int](repeating: 0, count: counts.count + 1)
        for i in counts.indices { sums[i + 1] = sums[i] + counts[i] }
        return sums
    }

    private static func charClass(_ c: UInt32, classes: [Set<UInt32>]) -> Int {
        for (k, set) in classes.enumerated() where set.contains(c) { return k + 1 }
        if (0x3040...0x30FF).contains(c) { return 7 }
        if (0x4E00...0x9FFF).contains(c) { return 8 }
        if (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) { return 9 }
        return 0
    }

    // MARK: features (order of `features` in the JSON; Python reference retrain/linebox/lbfeat.py)

    private static func features(_ i: Int, page: Page, pixels: UnsafeBufferPointer<UInt8>, gray: PipelineGrayRaster,
                                 model: Model, classes: [Set<UInt32>], rows: inout [Double],
                                 scratch: inout Scratch) -> Meta {
        let c = model.constants
        let line = page.lines[i], v = line.vertical
        let b = page.boxes[i].frame(v)
        let (pw, ph) = v ? (page.width, page.height) : (page.height, page.width)
        let x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1
        let th = max(x1 - x0, c.minThickness), length = max(y1 - y0, 1)
        let scalars = Array(line.text.unicodeScalars.map(\.value))
        let count = scalars.count
        let cyc = (y0 + y1) / 2, cxc = (x0 + x1) / 2

        var best: (area: Double, box: Box, kind: Int)?
        for (kind, box) in page.regions {
            let r = box.frame(v)
            guard r.x0 <= cxc, cxc <= r.x1, r.y0 <= cyc, cyc <= r.y1 else { continue }
            let a = (r.x1 - r.x0) * (r.y1 - r.y0)
            if best.map({ a < $0.area }) ?? true { best = (a, r, kind) }
        }
        var gaps = [3.0, 3.0, 3.0, 3.0]
        func neighbour(_ o: Box) {
            if min(x1, o.x1) - max(x0, o.x0) >= 0.5 * min(th, o.x1 - o.x0) {
                if o.y1 <= y0 + 0.2 * th, o.y0 < y0 { gaps[0] = min(gaps[0], (y0 - o.y1) / th) }
                if o.y0 >= y1 - 0.2 * th, o.y1 > y1 { gaps[1] = min(gaps[1], (o.y0 - y1) / th) }
            }
            if min(y1, o.y1) - max(y0, o.y0) >= 0.3 * min(length, o.y1 - o.y0) {
                if o.x1 <= x0 + 0.3 * th, o.x0 < x0 { gaps[2] = min(gaps[2], (x0 - o.x1) / th) }
                if o.x0 >= x1 - 0.3 * th, o.x1 > x1 { gaps[3] = min(gaps[3], (o.x0 - x1) / th) }
            }
        }
        for j in page.boxes.indices where j != i { neighbour(page.boxes[j].frame(v)) }
        var reach = [-1.0, -1.0, -1.0, -1.0], fragments = 0
        for f in page.fragments {
            let o = f.frame(v)
            neighbour(o)
            let ov = min(x1, o.x1) - max(x0, o.x0), ova = min(y1, o.y1) - max(y0, o.y0)
            if ov < 0.5 * min(th, o.x1 - o.x0) || ova < -0.3 * th { continue }
            fragments += 1
            reach[0] = max(reach[0], (y0 - o.y0) / th)
            reach[1] = max(reach[1], (o.y1 - y1) / th)
            reach[2] = max(reach[2], (x0 - o.x0) / th)
            reach[3] = max(reach[3], (o.x1 - x1) / th)
        }
        var skew = 0.0
        if line.polygon.count == 4 {
            let p = line.polygon.map { v ? (x: Double($0.x), y: Double($0.y)) : (x: Double($0.y), y: Double($0.x)) }
            let order = (0..<4).sorted { p[$0].y != p[$1].y ? p[$0].y < p[$1].y : $0 < $1 }
            skew = ((p[order[2]].x + p[order[3]].x) / 2 - (p[order[0]].x + p[order[1]].x) / 2) / th
        }

        // pixels on the raster grid, as a crop [along][cross]
        let gw = gray.width, gh = gray.height
        let sa = v ? Double(gh) / page.height : Double(gw) / page.width
        let sc = v ? Double(gw) / page.width : Double(gh) / page.height
        let (ha, wc) = v ? (gh, gw) : (gw, gh)
        let tr = th * sc
        let ry0 = y0 * sa, ry1 = y1 * sa, rx0 = x0 * sc, rx1 = x1 * sc
        let ex = Int(c.ext * tr) + 1, cx = Int(c.xext * tr) + 1
        let Y0 = Int(max(0, ry0 - Double(ex))), Y1 = Int(min(Double(ha), ry1 + Double(ex)))
        let X0 = Int(max(0, rx0 - Double(cx))), X1 = Int(min(Double(wc), rx1 + Double(cx)))
        let ch = max(0, Y1 - Y0), cw = max(0, X1 - X0)
        scratch.crop.removeAll(keepingCapacity: true)
        scratch.crop.reserveCapacity(ch * cw)
        for a in 0..<ch {
            for k in 0..<cw {
                scratch.crop.append(v ? pixels[(Y0 + a) * gw + X0 + k] : pixels[(X0 + k) * gw + Y0 + a])
            }
        }
        let iy0 = nearest(ry0) - Y0, iy1 = nearest(ry1) - Y0, ix0 = nearest(rx0) - X0, ix1 = nearest(rx1) - X0
        var bx0 = max(0, Int(rx0 + 0.1 * tr) - X0), bx1 = min(cw, Int(rx1 - 0.1 * tr) - X0)
        if bx1 <= bx0 { (bx0, bx1) = (max(0, ix0), min(cw, ix1 + 1)) }
        // inner-box median gray
        let (r0, r1) = clamp(iy0, max(iy0 + 1, iy1), ch), (c0, c1) = clamp(ix0, max(ix0 + 1, ix1), cw)
        var background = 255.0
        if r1 > r0, c1 > c0 {
            var histogram = [Int](repeating: 0, count: 256)
            for a in r0..<r1 { for k in c0..<c1 { histogram[Int(scratch.crop[a * cw + k])] += 1 } }
            let m = (r1 - r0) * (c1 - c0)
            func value(at rank: Int) -> Int {
                var seen = 0
                for g in 0..<256 {
                    seen += histogram[g]
                    if seen > rank { return g }
                }
                return 255
            }
            background = Double(value(at: (m - 1) / 2) + value(at: m / 2)) / 2
        }
        let (b0, b1) = clamp(bx0, bx1, cw)
        let (ys0, ys1) = clamp(max(0, iy0), max(iy0 + 1, iy1), ch)
        let ml = clamp(max(0, ix0 - Int(0.4 * tr)), max(0, ix0 - Int(0.1 * tr)), cw)
        let mr = clamp(min(cw, ix1 + Int(0.1 * tr)), min(cw, ix1 + Int(0.4 * tr)), cw)
        for k in 0..<2 {
            scratch.along[k] = [Int](repeating: 0, count: ch)
            scratch.cross[k] = [Int](repeating: 0, count: cw)
        }
        scratch.marginLeft = [Int](repeating: 0, count: ch)
        scratch.marginRight = [Int](repeating: 0, count: ch)
        let t0 = c.thresholds[0], t1 = c.thresholds[1]
        for a in 0..<ch {
            let inRows = a >= ys0 && a < ys1
            for k in 0..<cw {
                let dev = abs(Double(scratch.crop[a * cw + k]) - background)
                guard dev > t0 || dev > t1 else { continue }
                let inBand = k >= b0 && k < b1
                if dev > t0 {
                    if inBand { scratch.along[0][a] += 1 }
                    if inRows { scratch.cross[0][k] += 1 }
                }
                if dev > t1 {
                    if inBand { scratch.along[1][a] += 1 }
                    if inRows { scratch.cross[1][k] += 1 }
                    if k >= ml.0 && k < ml.1 { scratch.marginLeft[a] += 1 }
                    if k >= mr.0 && k < mr.1 { scratch.marginRight[a] += 1 }
                }
            }
        }
        let alongSums = scratch.along.map(prefix), crossSums = scratch.cross.map(prefix)
        let left = prefix(scratch.marginLeft), right = prefix(scratch.marginRight), band = alongSums[1]
        func window(_ a: Int, _ b: Int) -> [Double] {
            let a = max(0, a), b = min(ch, b)
            guard b > a else { return [-1, -1] }
            let inBand = b1 > b0 ? Double(band[b] - band[a]) / Double((b - a) * (b1 - b0)) : 0
            var side = -1.0
            for (sums, margin) in [(left, ml), (right, mr)] where margin.1 > margin.0 {
                side = max(side, Double(sums[b] - sums[a]) / Double((b - a) * (margin.1 - margin.0)))
            }
            return [inBand, side]
        }
        let reference = window(ys0, ys1)
        var continuation: [[Double]] = []
        for side in 0..<2 {
            let e = side == 0 ? iy0 : iy1, d = side == 0 ? -1 : 1
            var row = reference
            for (a, b) in [(0.0, 0.5), (0.5, 1.0)] {
                let lo = e + d * Int(a * tr), hi = e + d * Int(b * tr)
                row += window(min(lo, hi), max(lo, hi))
            }
            continuation.append(row)
        }

        let general = [th, length / th, Double(count), (length / th) / Double(max(count, 1)), background, v ? 1 : 0,
                       Double(best?.kind ?? 0), Double(line.confidence), Double(line.detectionScore), skew, abs(skew)]
        for side in 0..<4 {
            var f = general
            f.reserveCapacity(featureCount)
            for k in 0..<4 { f.append(side == k ? 1 : 0) }
            let cls: Int
            if side < 2 {
                cls = count == 0 ? -1 : charClass(side == 0 ? scalars[0] : scalars[count - 1], classes: classes)
            } else {
                cls = -2
            }
            for k in -1...9 { f.append(cls == k ? 1 : 0) }
            if let r = best?.box {
                f.append([y0 - r.y0, r.y1 - y1, x0 - r.x0, r.x1 - x1][side] / th)
            } else {
                f.append(9)
            }
            f += [gaps[side], [y0, ph - y1, x0, pw - x1][side] / th, reach[side], Double(fragments)]
            for k in 0..<2 {
                if side < 2 {
                    edge(scratch.along[k], alongSums[k], n: b1 - b0, e: side == 0 ? iy0 : iy1 - 1, d: side == 0 ? -1 : 1,
                         th: tr, gaps: c.gaps, bins: c.bins, inner: c.inner, limitIn: Int(0.5 * tr), limitOut: ex,
                         tw: c.tw, into: &f)
                } else {
                    edge(scratch.cross[k], crossSums[k], n: ys1 - ys0, e: side == 2 ? ix0 : ix1 - 1, d: side == 2 ? -1 : 1,
                         th: tr, gaps: c.cgaps, bins: c.cbins, inner: c.cinner, limitIn: Int(0.3 * tr), limitOut: cx,
                         tw: c.tw, into: &f)
                }
            }
            f += side < 2 ? continuation[side] : [0, 0, 0, 0, 0, 0]
            for k in 0..<featureCount { rows[side * featureCount + k] = f[k] }
        }
        return Meta(vertical: v, box: b, thickness: th)
    }

    /// Features of one edge on a profile of ink counts (`counts[i]` of `n` cells): `e` is the edge cell inside the
    /// line, `d` the outward direction; all lengths in raster thicknesses `th`.
    private static func edge(_ counts: [Int], _ sums: [Int], n: Int, e: Int, d: Int, th: Double, gaps: [Double],
                             bins: [[Double]], inner: [[Double]], limitIn: Int, limitOut: Int, tw: Double,
                             into f: inout [Double]) {
        let count = counts.count
        func ink(_ i: Int) -> Bool { n > 0 && Double(counts[i]) / Double(n) > 0.02 }
        func fraction(_ a: Int, _ b: Int) -> Double? {
            let a = max(0, a), b = min(count, b)
            guard b > a, n > 0 else { return nil }
            return Double(sums[b] - sums[a]) / Double((b - a) * n)
        }
        var gap = 0, i = e
        while i >= 0, i < count, !ink(i), gap < limitIn {
            gap += 1
            i -= d
        }
        f.append(Double(gap) / th)
        let start = min(max(i, 0), count - 1)
        for tolerance in gaps {
            let allowed = Int(tolerance * th)
            var last = start, blank = 0, j = start + d
            while j >= 0, j < count, abs(j - start) <= limitOut {
                if ink(j) {
                    last = j
                    blank = 0
                } else {
                    blank += 1
                    if blank > allowed { break }
                }
                j += d
            }
            f.append(Double((last - e) * d) / th)
        }
        for bin in bins {
            let lo = e + d * (Int(bin[0] * th) + 1), hi = e + d * (Int(bin[1] * th) + 1)
            f.append(fraction(min(lo, hi), max(lo, hi)) ?? -1)
        }
        for bin in inner {
            let lo = e - d * Int(bin[0] * th), hi = e - d * Int(bin[1] * th), k = d > 0 ? 1 : 0
            f.append(fraction(min(lo, hi) + k, max(lo, hi) + k) ?? -1)
        }
        // transitions: the strongest ink -> blank step and the first plateau end, scanning outward
        let w = max(2, Int(tw * th))
        var best = -1.0, bestOffset = 0.0, first: Double?
        let earliest = -((limitIn + 1) / 2)
        for k in -limitIn...limitOut {
            let i = e + d * k
            let inside = (d > 0 ? fraction(i - w + 1, i + 1) : fraction(i, i + w)) ?? 0
            let outside = (d > 0 ? fraction(i + 1, i + 1 + w) : fraction(i - w, i)) ?? 0
            let step = inside - outside
            if step > best { (best, bestOffset) = (step, Double(k) / th) }
            if first == nil, inside > 0.05, outside < 0.01, k >= earliest { first = Double(k) / th }
        }
        f += [bestOffset, best, first ?? Double(limitOut) / th]
    }

    // MARK: box

    private static func apply(_ line: PipelineLine, meta: Meta, offsets o: [Double], minSide: Double) -> PipelineLine {
        let b = meta.box, th = meta.thickness
        let framed = Box(b.x0 - o[2] * th, b.y0 - o[0] * th, b.x1 + o[3] * th, b.y1 + o[1] * th)
        guard framed.y1 - framed.y0 >= minSide, framed.x1 - framed.x0 >= minSide else { return line }
        let n = framed.frame(meta.vertical), old = Box(line.bounds)
        var out = line
        out.measure = line.measure ?? line.polygon
        out.bounds = CGRect(x: n.x0, y: n.y0, width: n.x1 - n.x0, height: n.y1 - n.y0)
        if line.polygon.count >= 4 {
            let sx = (n.x1 - n.x0) / max(old.x1 - old.x0, 1e-6), sy = (n.y1 - n.y0) / max(old.y1 - old.y0, 1e-6)
            out.polygon = line.polygon.map {
                CGPoint(x: n.x0 + (Double($0.x) - old.x0) * sx, y: n.y0 + (Double($0.y) - old.y0) * sy)
            }
        }
        return out
    }
}
