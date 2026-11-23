import CoreGraphics
import Foundation

/// S6 input: where each detector line really ends along its axis. The DB box often stops short of
/// the last glyph (median 0.1 T at the bottom of a column, > 0.5 T for 3% of lines). Per line end, a
/// LightGBM forest fit on GT train lines (`V2Weights.bin` lineEnds; port-eval/bboxagent/export.py)
/// predicts the end's offset in line thicknesses from the ink profile around it and the enclosing
/// RF text/balloon edge. S6 moves an end outward only where that end plus `margin` passes its own
/// 0.5 T line-end search, so its ROI reaches glyphs the detector left out; every other stage keeps the
/// detector lines (longer lines made S3 and S4 worse on GT).
enum V2LineEnds {
    /// Ink thresholds (|gray - box median|) of the two profiles.
    static let deltas: [Double] = [40, 90]
    /// Profile reach beyond each end, in thicknesses.
    static let reach = 1.5
    /// 19 bins of 0.1 T, from 0.6 T inside the end to 1.3 T past it.
    static let binCount = 19
    /// An end is searched up to its predicted position plus this many thicknesses (train-fold CV).
    static let margin = 0.35
    static let regionMinimumScore: Float = 0.5

    /// `lines` with ends moved outward by `max(0, (offset + margin - lineEndExtension) * T)`.
    static func refined(_ lines: [V2Line], pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
                        layout: [V2LayoutRegion], forest: V2StyleForest) -> [V2Line] {
        let regions = layout.filter { $0.score >= regionMinimumScore && ($0.kind == .text || $0.kind == .balloon) }
        return lines.map { line in
            guard let (start, end) = offsets(line, pixels: pixels, width: width, height: height, regions: regions,
                                             forest: forest) else { return line }
            let b = line.bounds
            let vertical = b.height >= b.width
            let thickness = Double(vertical ? b.width : b.height)
            let slack = margin - V2RemovalMask.lineEndExtension
            let d0 = CGFloat(max(0, (start + slack) * thickness)), d1 = CGFloat(max(0, (end + slack) * thickness))
            guard d0 > 0 || d1 > 0 else { return line }
            var out = line
            let mid = vertical ? b.midY : b.midX
            out.polygon = line.polygon.map { p in
                vertical ? CGPoint(x: p.x, y: p.y < mid ? p.y - d0 : p.y + d1)
                         : CGPoint(x: p.x < mid ? p.x - d0 : p.x + d1, y: p.y)
            }
            out.bounds = vertical ? CGRect(x: b.minX, y: b.minY - d0, width: b.width, height: b.height + d0 + d1)
                                  : CGRect(x: b.minX - d0, y: b.minY, width: b.width + d0 + d1, height: b.height)
            return out
        }
    }

    /// Predicted (start, end) offsets in thicknesses (positive = the lettering runs past the box).
    static func offsets(_ line: V2Line, pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
                        regions: [V2LayoutRegion], forest: V2StyleForest) -> (Double, Double)? {
        let b = line.bounds
        let x0 = Double(b.minX), y0 = Double(b.minY), x1 = Double(b.maxX), y1 = Double(b.maxY)
        guard [x0, y0, x1, y1].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { return nil }
        let vertical = b.height >= b.width
        let thickness = vertical ? x1 - x0 : y1 - y0
        guard thickness > 0, thickness <= V2RemovalMask.maximumThickness else { return nil }
        func gray(_ x: Int, _ y: Int) -> Int {
            let i = (y * width + x) * 4
            return (Int(pixels[i]) * 19595 + Int(pixels[i + 1]) * 38470 + Int(pixels[i + 2]) * 7471 + 0x8000) >> 16
        }
        // Background: the median gray inside the box.
        var histogram = [Int](repeating: 0, count: 256)
        let bx0 = max(0, Int(x0)), by0 = max(0, Int(y0))
        let bx1 = min(width, Int(x1.rounded(.up))), by1 = min(height, Int(y1.rounded(.up)))
        if bx1 > bx0, by1 > by0 {
            for y in by0..<by1 { for x in bx0..<bx1 { histogram[gray(x, y)] += 1 } }
        }
        let count = histogram.reduce(0, +)
        var background = 255.0
        if count > 0 {
            func value(_ rank: Int) -> Int {
                var seen = 0
                for (level, n) in histogram.enumerated() {
                    seen += n
                    if seen > rank { return level }
                }
                return 255
            }
            background = count % 2 == 1 ? Double(value(count / 2)) : Double(value(count / 2 - 1) + value(count / 2)) / 2
        }
        // Along-axis ink profiles over the box's middle 80% across the axis, `reach` T past both ends.
        let r = Int((reach * thickness).rounded(.up))
        let crossLow = vertical ? x0 : y0, crossHigh = vertical ? x1 : y1
        let alongLow = vertical ? y0 : x0, alongHigh = vertical ? y1 : x1
        let crossLimit = vertical ? width : height, alongLimit = vertical ? height : width
        let start = Int((crossLow + 0.1 * thickness).rounded(.toNearestOrEven))
        let a = max(0, start)
        let c = min(crossLimit, max(start + 1, Int((crossHigh - 0.1 * thickness).rounded(.toNearestOrEven))))
        guard c > a else { return nil }
        let lo = Int(alongLow.rounded(.down)) - r, hi = Int(alongHigh.rounded(.up)) + r
        let length = hi - lo
        var profiles = [[Double]](repeating: [Double](repeating: 0, count: length), count: deltas.count)
        for i in 0..<length {
            let along = lo + i
            guard along >= 0, along < alongLimit else { continue }
            var hits = [Int](repeating: 0, count: deltas.count)
            for cross in a..<c {
                let d = abs(Double(vertical ? gray(cross, along) : gray(along, cross)) - background)
                for k in deltas.indices where d > deltas[k] { hits[k] += 1 }
            }
            for k in deltas.indices { profiles[k][i] = Double(hits[k]) / Double(c - a) }
        }
        let first = Int(alongLow.rounded(.down)) - lo, last = Int(alongHigh.rounded(.up)) - lo
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        func features(_ which: Int) -> [Double] {
            let position = Double(which == 1 ? last : first), sign = which == 1 ? 1.0 : -1.0
            var x: [Double] = []
            x.reserveCapacity(deltas.count * binCount + 7)
            for profile in profiles {
                for k in 0..<binCount {
                    let p = position + sign * (Double(k - 6) / 10) * thickness
                    let q = position + sign * (Double(k - 5) / 10) * thickness
                    let from = max(0, Int(min(p, q).rounded(.toNearestOrEven)))
                    let to = min(length, max(from + 1, Int(max(p, q).rounded(.toNearestOrEven))))
                    x.append(to > from ? profile[from..<to].reduce(0, +) / Double(to - from) : 0)
                }
            }
            let end = vertical ? (which == 1 ? y1 : y0) : (which == 1 ? x1 : x0)
            func distance(_ kind: V2LayoutKind) -> Double {
                var best = 9.0
                for region in regions where region.kind == kind {
                    let q = region.bounds
                    guard Double(q.minX) <= cx, cx <= Double(q.maxX), Double(q.minY) <= cy, cy <= Double(q.maxY) else { continue }
                    let edge = Double(vertical ? (which == 1 ? q.maxY : q.minY) : (which == 1 ? q.maxX : q.minX))
                    best = min(best, sign * (edge - end) / thickness)
                }
                return best
            }
            x += [thickness, (alongHigh - alongLow) / thickness, vertical ? 1 : 0, Double(which),
                  distance(.text), distance(.balloon), background]
            return x
        }
        return (forest.logit(features(0)), forest.logit(features(1)))
    }
}
