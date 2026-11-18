import Foundation

/// Uniform RF-only boundary evidence. No OCR, RGB, IDs, absolute-box features,
/// ownership inference or candidate selection. Feature order matches profiles.py.
enum NativeOCRRFBoundaryProfiles {
    static let featureCount = 113
    static let featureNames: [String] = {
        let sides = ["edge01", "edge12", "edge23", "edge30"]
        let classes = ["text", "soundEffect", "textOrSoundEffect"]
        let stats = ["insideMean", "outsideMean", "insideMinusOutside", "insideSupportHalf", "outsideSupportHalf",
                     "outsideSupportMassFraction", "insideOutsideAgreement"]
        var names = sides.flatMap { side in classes.flatMap { cls in stats.map { "\(side).\(cls).\($0)" } } }
        for side in sides {
            for stat in ["insideEvidenceMargin", "outsideEvidenceMargin", "insideWeightedMeanAgreement",
                         "outsideWeightedMeanAgreement", "validSampleFraction"] { names.append("\(side).\(stat)") }
        }
        for cls in classes {
            for stat in ["minimumBoundaryDrop", "meanBoundaryDrop", "maximumOutsideMassFraction"] {
                names.append("allSides.\(cls).\(stat)")
            }
        }
        return names
    }()

    /// Prepare ONCE per source, not per candidate: validates real arrays once.
    /// Missing/invalid means leave only their eight features unavailable; maxima
    /// remain usable. Missing optional data never masquerades as another plane.
    struct PreparedGrid: Sendable {
        fileprivate let grid: NativeRFDETRSemanticGrid
        let weightedMeanAvailable: Bool
        init?(grid: NativeRFDETRSemanticGrid) {
            guard grid.isValid else { return nil }
            self.grid = grid
            weightedMeanAvailable = grid.hasValidWeightedMeanProbabilities
        }
    }

    struct Result: Sendable {
        let features: [Float]
        /// Per-feature finite-value availability; NaN is always explicit missing.
        let featureAvailable: [Bool]
        let available: Bool
        let weightedMeanAvailable: Bool
        let validSampleFractions: [Float]
        /// Flat [4 sides, 2 outside/inside, 16 positions, 2 text/SFX], depth mean.
        /// Float32 here; Python's optional compact profile storage uses Float16.
        let profiles: [Float]
    }

    private static func missing() -> Result {
        .init(features: [Float](repeating: .nan, count: featureCount),
              featureAvailable: [Bool](repeating: false, count: featureCount), available: false,
              weightedMeanAvailable: false, validSampleFractions: [Float](repeating: 0, count: 4),
              profiles: [Float](repeating: .nan, count: 4 * 2 * 16 * 2))
    }

    static func extract(polygon: [[Double]], grid: NativeRFDETRSemanticGrid?) -> Result {
        guard let grid, let prepared = PreparedGrid(grid: grid) else { return missing() }
        return extract(polygon: polygon, prepared: prepared)
    }

    /// 16 midpoint samples per actual quad edge; 2%, 6%, 12% inward/outward
    /// bilinear depths. Outside-frame samples abstain, never clamp to edge data.
    static func extract(polygon: [[Double]], prepared: PreparedGrid) -> Result {
        guard polygon.count == 4, polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return missing() }
        let grid = prepared.grid, cells = grid.side * grid.side
        let width = Double(grid.width), height = Double(grid.height)
        let depths = [-0.02, -0.06, -0.12, 0.02, 0.06, 0.12]
        // Fields: text max, SFX max, their max, max(balloon/frame), max(text/SFX weighted mean).
        var fields = Array(repeating: Array(repeating: [Double](repeating: .nan, count: 96), count: 5), count: 4)
        var validCounts = [Int](repeating: 0, count: 4)
        func sample(_ values: [Float], _ semantic: Int, _ x0: Int, _ y0: Int,
                    _ x1: Int, _ y1: Int, _ dx: Double, _ dy: Double) -> Double {
            let offset = semantic * cells
            return (Double(values[offset + y0 * 162 + x0]) * (1-dx) + Double(values[offset + y0 * 162 + x1]) * dx) * (1-dy)
                + (Double(values[offset + y1 * 162 + x0]) * (1-dx) + Double(values[offset + y1 * 162 + x1]) * dx) * dy
        }
        for side in 0..<4 {
            for position in 0..<16 {
                let t = (Double(position) + 0.5) / 16
                for depthIndex in 0..<6 {
                    let d = depths[depthIndex]
                    let u: Double, v: Double
                    switch side {
                    case 0: u = t; v = d
                    case 1: u = 1-d; v = t
                    case 2: u = 1-t; v = 1-d
                    default: u = d; v = 1-t
                    }
                    // Keep Python's operation order in Double before Float32 ABI.
                    let x = polygon[0][0]*(1-u)*(1-v) + polygon[1][0]*u*(1-v)
                        + polygon[2][0]*u*v + polygon[3][0]*(1-u)*v
                    let y = polygon[0][1]*(1-u)*(1-v) + polygon[1][1]*u*(1-v)
                        + polygon[2][1]*u*v + polygon[3][1]*(1-u)*v
                    guard x.isFinite, y.isFinite, x >= 0, x <= width, y >= 0, y <= height else { continue }
                    validCounts[side] += 1
                    let gx = min(161, max(0, x*162/width-0.5)), gy = min(161, max(0, y*162/height-0.5))
                    let x0 = Int(gx), y0 = Int(gy), x1 = min(161, x0+1), y1 = min(161, y0+1)
                    let dx = gx-Double(x0), dy = gy-Double(y0), slot = position*6+depthIndex
                    let text = sample(grid.probabilities, 0, x0, y0, x1, y1, dx, dy)
                    let sfx = sample(grid.probabilities, 1, x0, y0, x1, y1, dx, dy)
                    fields[side][0][slot] = text; fields[side][1][slot] = sfx
                    fields[side][2][slot] = max(text, sfx)
                    fields[side][3][slot] = max(sample(grid.probabilities, 2, x0, y0, x1, y1, dx, dy),
                                                sample(grid.probabilities, 3, x0, y0, x1, y1, dx, dy))
                    if prepared.weightedMeanAvailable, let means = grid.weightedMeanProbabilities {
                        fields[side][4][slot] = max(sample(means, 0, x0, y0, x1, y1, dx, dy),
                                                   sample(means, 1, x0, y0, x1, y1, dx, dy))
                    }
                }
            }
        }
        func mean(_ values: [Double]) -> Double {
            var sum = 0.0, count = 0
            for value in values where value.isFinite { sum += value; count += 1 }
            return count > 0 ? sum / Double(count) : .nan
        }
        func half(_ values: [Double], inside: Bool) -> [Double] {
            var result = [Double](); result.reserveCapacity(48)
            for position in 0..<16 {
                for depth in (inside ? 3..<6 : 0..<3) { result.append(values[position*6+depth]) }
            }
            return result
        }
        var features = [Double](), drops = [[Double]](repeating: [], count: 3), masses = drops
        features.reserveCapacity(featureCount)
        for side in 0..<4 {
            for cls in 0..<3 {
                let ins = half(fields[side][cls], inside: true), out = half(fields[side][cls], inside: false)
                let im = mean(ins), om = mean(out), total = im+om
                let insideSupport = mean(ins.map { $0.isFinite ? ($0 >= 0.5 ? 1 : 0) : .nan })
                let outsideSupport = mean(out.map { $0.isFinite ? ($0 >= 0.5 ? 1 : 0) : .nan })
                let fraction: Double = total.isFinite ? (total > 1e-8 ? om/total : 0) : .nan
                let agreement = mean(zip(ins, out).map { 1-abs($0-$1) })
                features += [im, om, im-om, insideSupport, outsideSupport, fraction, agreement]
                drops[cls].append(im-om); masses[cls].append(fraction)
            }
        }
        let validFractions = validCounts.map { Float($0)/96 }
        for side in 0..<4 {
            let margin = zip(fields[side][2], fields[side][3]).map(-)
            let agreement = zip(fields[side][2], fields[side][4]).map { 1-abs($0-$1) }
            features += [mean(half(margin, inside: true)), mean(half(margin, inside: false)),
                         mean(half(agreement, inside: true)), mean(half(agreement, inside: false)), Double(validFractions[side])]
        }
        for cls in 0..<3 {
            features += [drops[cls].filter(\.isFinite).min() ?? .nan, mean(drops[cls]), masses[cls].filter(\.isFinite).max() ?? .nan]
        }
        var profiles = [Float](); profiles.reserveCapacity(256)
        for side in 0..<4 {
            for inside in [false, true] {
                for position in 0..<16 {
                    for cls in 0..<2 {
                        let start = position*6 + (inside ? 3 : 0)
                        profiles.append(Float(mean(Array(fields[side][cls][start..<(start+3)]))))
                    }
                }
            }
        }
        let output = features.map { $0.isFinite ? Float($0) : Float.nan }
        return .init(features: output, featureAvailable: output.map(\.isFinite), available: true,
                     weightedMeanAvailable: prepared.weightedMeanAvailable, validSampleFractions: validFractions, profiles: profiles)
    }
}
