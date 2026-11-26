import CoreGraphics
import Foundation

/// S6 input: where each detector line really ends (the DB box often stops short of the last glyph).
/// Per end, a LightGBM forest (`PipelineWeights.bin` lineEnds) predicts the offset in line thicknesses
/// from the ink profile and the enclosing text/balloon edge; S6 alone uses the moved ends.
/// A whole missing glyph (often 1-3 T) is flagged by `PipelineLineEndClassifier` on the same features inside an
/// RF text region; such an end reaches along the ink run, at most to that region's edge.
enum PipelineLineEnds {
    /// Ink thresholds (|gray - box median|) of the two profiles.
    static let deltas: [Double] = [40, 90]
    /// Profile reach beyond each end, in thicknesses.
    static let reach = 1.5
    /// 19 bins of 0.1 T, from 0.6 T inside the end to 1.3 T past it.
    static let binCount = 19
    /// An end is searched up to its predicted position plus this many thicknesses (train-fold CV).
    static var margin: Double { PipelineTuning.current.lineEndMargin }
    static let regionMinimumScore: Float = 0.5
    /// Ink run past a flagged end: `deltas[0]` profile above `runInk`, gaps up to `runGap` T, at most `runReach` T;
    /// the reach is the run (capped at the RF text edge) plus `runPad` T (train-fold CV).
    static let runInk = 0.02, runGap = 0.4, runReach = 3.0, runPad = 0.1

    /// `lines` with ends moved outward by `max(0, (offset + margin - lineEndExtension) * T)`.
    static func refined(_ lines: [PipelineLine], pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
                        layout: [PipelineLayoutRegion], forest: PipelineStyleForest,
                        classifier: PipelineLineEndClassifier? = .shared) -> [PipelineLine] {
        let regions = layout.filter { $0.score >= regionMinimumScore && ($0.kind == .text || $0.kind == .balloon) }
        return lines.map { line in
            guard let (start, end) = offsets(line, pixels: pixels, width: width, height: height, regions: regions,
                                             forest: forest, classifier: classifier) else { return line }
            let b = line.bounds
            let vertical = b.height >= b.width
            let thickness = Double(vertical ? b.width : b.height)
            let slack = margin - PipelineRemovalMask.lineEndExtension
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

    /// Predicted (start, end) offsets in thicknesses (positive = the lettering runs past the box). Where `classifier`
    /// flags a missing glyph inside a text region, the offset is at least the capped ink run + `runPad` - `margin`.
    static func offsets(_ line: PipelineLine, pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
                        regions: [PipelineLayoutRegion], forest: PipelineStyleForest,
                        classifier: PipelineLineEndClassifier? = nil) -> (Double, Double)? {
        let b = line.bounds
        let x0 = Double(b.minX), y0 = Double(b.minY), x1 = Double(b.maxX), y1 = Double(b.maxY)
        guard [x0, y0, x1, y1].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { return nil }
        let vertical = b.height >= b.width
        let thickness = vertical ? x1 - x0 : y1 - y0
        guard thickness > 0, thickness <= PipelineRemovalMask.maximumThickness else { return nil }
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
            // Two thresholds (`deltas`), counted without a per-row array.
            let low = deltas[0], high = deltas[1]
            var lowHits = 0, highHits = 0
            for cross in a..<c {
                let d = abs(Double(vertical ? gray(cross, along) : gray(along, cross)) - background)
                if d > low { lowHits += 1 }
                if d > high { highHits += 1 }
            }
            profiles[0][i] = Double(lowHits) / Double(c - a)
            profiles[1][i] = Double(highHits) / Double(c - a)
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
            func distance(_ kind: PipelineLayoutKind) -> Double {
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
        // Ink run outward from the rounded end, in thicknesses: the `deltas[0]` fraction per along position,
        // measured only for flagged ends (the feature profile keeps its 1.5 T reach and bin rounding).
        func run(_ which: Int) -> Double {
            let e = Int((which == 1 ? alongHigh : alongLow).rounded(.toNearestOrEven))
            let gap = runGap * thickness
            var last = -1, i = 0
            while Double(i) <= runReach * thickness {
                let along = which == 1 ? e + i : e - 1 - i
                guard along >= 0, along < alongLimit else { break }
                var hits = 0
                for cross in a..<c where abs(Double(vertical ? gray(cross, along) : gray(along, cross)) - background) > deltas[0] {
                    hits += 1
                }
                if Double(hits) / Double(c - a) > runInk {
                    last = i
                } else if Double(i - last) > gap {
                    break
                }
                i += 1
            }
            return Double(last + 1) / thickness
        }
        func offset(_ which: Int) -> Double {
            let x = features(which)
            let predicted = forest.logit(x)
            // distance(.text): 9 when no text region encloses the line; outside one the classifier mostly fires on
            // art and lines the GT does not hold, so it is not asked there.
            let edge = x[x.count - 3]
            guard let classifier, edge < 9, classifier.fires(x) else { return predicted }
            return max(predicted, min(run(which), max(edge, 0)) + runPad - margin)
        }
        return (offset(0), offset(1))
    }
}

/// Missing-glyph classifier of the line-end search (Resources/Translation/PipelineLineEnds.json, LightGBM fit on
/// TRAIN pages): fires when the raw score of the 45 `PipelineLineEnds` features reaches `threshold` (p >= 0.3).
/// Trees as flat arrays: `Float(x[f]) <= t` goes left, a negative child is leaf `-child - 1`.
struct PipelineLineEndClassifier: Decodable, Sendable {
    let features: Int
    let threshold: Double
    let trees: [PipelineOutlineWidthModel.Tree]

    func fires(_ x: [Double]) -> Bool {
        guard x.count == features else { return false }
        var total = 0.0
        for tree in trees {
            var node = 0
            while node >= 0 { node = Double(Float(x[tree.f[node]])) <= tree.t[node] ? tree.l[node] : tree.r[node] }
            total += tree.v[-node - 1]
        }
        return total >= threshold
    }

    static let shared: PipelineLineEndClassifier? = {
        var urls = [Bundle.main.url(forResource: "PipelineLineEnds", withExtension: "json")].compactMap { $0 }
        if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"] {
            urls.append(URL(fileURLWithPath: root).appendingPathComponent("Aidoku/Resources/Translation/PipelineLineEnds.json"))
        }
        return urls.lazy.compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(PipelineLineEndClassifier.self, from: $0) }
            .first { $0.features == featureCount }
    }()

    /// 38 profile bins + 7 geometry/region features (`PipelineLineEnds.offsets`).
    static let featureCount = 45
}
