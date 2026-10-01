import CoreGraphics
import Foundation

/// Test-only allowance for the declared native source sampler. It never applies
/// to translated glyphs, saved-page parity, source bytes, geometry, or layer order.
/// Full-size composition keeps every pixel outside source frames exact. Half-size
/// compatibility captures additionally admit the measured two-pixel filter support.
enum NativeSourceCanvasResamplingAcceptance {
    enum Mode { case sourceDraw, halfSizeCapture }
    struct Assessment {
        let accepted: Bool
        let report: [String: Any]
    }

    private struct Limits {
        let mean: Double
        let percentile95: Int
        let largeFraction: Double
        let alphaMassFraction: Double
        init(_ mode: Mode) {
            switch mode {
            case .sourceDraw: mean = 0.5; percentile95 = 3; largeFraction = 0.005; alphaMassFraction = 0.005
            case .halfSizeCapture: mean = 4; percentile95 = 12; largeFraction = 0.01; alphaMassFraction = 0.01
            }
        }
    }

    private struct Statistics {
        var count = 0
        var sums = [Int](repeating: 0, count: 4)
        var maximum = [Int](repeating: 0, count: 4)
        var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 4)
        var alphaReference = 0
        var alphaCandidate = 0
        var referenceBounds: CGRect?
        var candidateBounds: CGRect?
        var opaqueAlphaPreserved = true
        var premultiplicationValid = true

        mutating func add(_ reference: [UInt8], _ candidate: [UInt8], offset: Int, x: Int, y: Int) {
            count += 1
            for c in 0..<4 {
                let delta = abs(Int(reference[offset + c]) - Int(candidate[offset + c]))
                sums[c] += delta; maximum[c] = max(maximum[c], delta); histograms[c][delta] += 1
            }
            alphaReference += Int(reference[offset + 3]); alphaCandidate += Int(candidate[offset + 3])
            let pixel = CGRect(x: x, y: y, width: 1, height: 1)
            if reference[offset + 3] > 0 { referenceBounds = referenceBounds.map { $0.union(pixel) } ?? pixel }
            if candidate[offset + 3] > 0 { candidateBounds = candidateBounds.map { $0.union(pixel) } ?? pixel }
            // Preserve uniformly opaque captures without forbidding AA changes on
            // individual opaque pixels adjoining transparent source edges.
            premultiplicationValid = premultiplicationValid && (0..<3).allSatisfy { candidate[offset + $0] <= candidate[offset + 3] }
            if reference[offset + 3] != 255 { opaqueAlphaPreserved = false }
        }
        var means: [Double] { sums.map { Double($0) / Double(max(1, count)) } }
        var percentiles: [Int] {
            histograms.map { histogram in
                var total = 0
                let target = Int(ceil(Double(count) * 0.95))
                for (delta, frequency) in histogram.enumerated() {
                    total += frequency
                    if total >= target { return delta }
                }
                return 0
            }
        }
        var largeFractions: [Double] { histograms.map { Double($0[17...].reduce(0, +)) / Double(max(1, count)) } }
        var alphaMassFraction: Double {
            alphaReference > 0 ? abs(Double(alphaCandidate - alphaReference)) / Double(alphaReference)
                : (alphaCandidate == 0 ? 0 : .infinity)
        }
        func accepts(_ limits: Limits) -> Bool {
            count > 0 && means.allSatisfy { $0 <= limits.mean } && percentiles.allSatisfy { $0 <= limits.percentile95 }
                && maximum.allSatisfy { $0 <= 64 } && largeFractions.allSatisfy { $0 <= limits.largeFraction }
                && alphaMassFraction <= limits.alphaMassFraction && referenceBounds == candidateBounds
                && (!opaqueAlphaPreserved || maximum[3] == 0) && premultiplicationValid
        }
        var report: [String: Any] {
            ["pixels": count, "meanAbsoluteDeltaRGBA": means, "p95DeltaRGBA": percentiles,
             "maximumDeltaRGBA": maximum, "fractionAbove16RGBA": largeFractions,
             "relativeAlphaMassDelta": alphaMassFraction.isFinite ? alphaMassFraction : -1,
             "alphaSupportBoundsEqual": referenceBounds == candidateBounds,
             "opaqueAlphaExact": !opaqueAlphaPreserved || maximum[3] == 0,
             "premultiplicationValid": premultiplicationValid]
        }
    }

    static func assess(reference: Data, candidate: Data, width: Int, height: Int,
                       frames: [CGRect], outputScale: CGFloat, mode: Mode) -> Assessment {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 4_000_000, reference.count == width * height * 4, candidate.count == reference.count,
              !frames.isEmpty, outputScale.isFinite, outputScale > 0,
              frames.allSatisfy({ !$0.isEmpty && !$0.isNull && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) })
        else { return .init(accepted: false, report: ["accepted": false, "invalidGeometryOrBuffers": true]) }
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        let rects = frames.map { $0.applying(CGAffineTransform(scaleX: outputScale, y: outputScale)).integral }
        guard rects.allSatisfy({ page.contains($0) }) else {
            return .init(accepted: false, report: ["accepted": false, "sourceOutsidePage": true])
        }
        let reference = [UInt8](reference), candidate = [UInt8](candidate), limits = Limits(mode)
        var regions = [Statistics](repeating: Statistics(), count: rects.count)
        var outside = Statistics(), firstFringe = Statistics(), secondFringe = Statistics()
        for y in 0..<height { for x in 0..<width {
            let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5), offset = (y * width + x) * 4
            var inside = false
            for i in rects.indices where rects[i].contains(point) {
                regions[i].add(reference, candidate, offset: offset, x: x, y: y); inside = true
            }
            if inside { continue }
            if mode == .halfSizeCapture, rects.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) {
                firstFringe.add(reference, candidate, offset: offset, x: x, y: y)
            } else if mode == .halfSizeCapture, rects.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) {
                secondFringe.add(reference, candidate, offset: offset, x: x, y: y)
            } else { outside.add(reference, candidate, offset: offset, x: x, y: y) }
        } }
        let fringeAccepted = firstFringe.maximum.allSatisfy { $0 <= 32 } && secondFringe.maximum.allSatisfy { $0 <= 2 }
            && (!firstFringe.opaqueAlphaPreserved || firstFringe.maximum[3] == 0)
            && (!secondFringe.opaqueAlphaPreserved || secondFringe.maximum[3] == 0)
            && firstFringe.premultiplicationValid && secondFringe.premultiplicationValid
        let accepted = regions.allSatisfy { $0.accepts(limits) } && outside.maximum.allSatisfy { $0 == 0 } && fringeAccepted
        let thresholdReport: [String: Any] = ["mean": limits.mean, "p95": limits.percentile95, "maximum": 64,
            "fractionAbove16": limits.largeFraction, "relativeAlphaMass": limits.alphaMassFraction]
        return .init(accepted: accepted, report: ["accepted": accepted,
            "mode": mode == .sourceDraw ? "source-draw" : "half-size-native-capture",
            "sourceRegions": regions.map(\.report), "firstPhysicalPixelFringe": firstFringe.report,
            "secondPhysicalPixelFringe": secondFringe.report, "outsideFootprintExact": outside.maximum.allSatisfy { $0 == 0 },
            "limits": thresholdReport])
    }

    /// The same acceptance must reject wrong placement, missing source content,
    /// vertical inversion and alpha-only damage on each real captured fixture.
    static func negativeControls(reference: Data, candidate: Data, prefix: Data, width: Int, height: Int,
                                 frames: [CGRect], outputScale: CGFloat, mode: Mode) -> [String: Bool] {
        guard prefix.count == candidate.count, let final = frames.last else { return ["invalidControlInput": false] }
        let rect = final.applying(CGAffineTransform(scaleX: outputScale, y: outputScale)).integral
        let left = Int(rect.minX), right = Int(rect.maxX), top = Int(rect.minY), bottom = Int(rect.maxY)
        guard left >= 0, top >= 0, right <= width, bottom <= height else { return ["invalidControlGeometry": false] }
        let original = [UInt8](candidate), prefix = [UInt8](prefix)
        var results: [String: Bool] = [:]
        for control in ["sourceShiftRightOnePixel", "lostSourcePatch", "sourceFlippedVertically", "alphaChannelHalved"] {
            var changed = original
            for y in top..<bottom { for x in left..<right {
                let offset = (y * width + x) * 4
                if control == "alphaChannelHalved" { changed[offset + 3] /= 2; continue }
                let input: [UInt8]
                let source: Int
                if control == "lostSourcePatch" || (control == "sourceShiftRightOnePixel" && x == left) {
                    input = prefix; source = offset
                } else {
                    input = original
                    source = control == "sourceFlippedVertically" ? ((top + bottom - 1 - y) * width + x) * 4 : offset - 4
                }
                for c in 0..<4 { changed[offset + c] = input[source + c] }
            } }
            results[control] = !assess(reference: reference, candidate: Data(changed), width: width, height: height,
                frames: frames, outputScale: outputScale, mode: mode).accepted
        }
        return results
    }
}
