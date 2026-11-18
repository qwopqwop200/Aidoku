import Foundation

enum NeighborhoodFailure: Error { case mismatch(String) }
final class NeighborhoodCounter { var means = 0 }
struct NeighborhoodCurrentOps: NativeSegmentationFinalFeatures.ImageOperations {
    let counter: NeighborhoodCounter
    let actual = NativeSegmentationOpenCVOperations()
    func boxMean(_ values: [Float], width: Int, height: Int, size: Int) throws -> [Float] {
        counter.means += 1
        return try actual.boxMean(values, width: width, height: height, size: size)
    }
    func distance(_ nonzero: [UInt8], width: Int, height: Int, metric: NativeSegmentationFinalFeatures.DistanceMetric,
                  labels: Bool) throws -> (values: [Float], labels: [Int32]?) {
        try actual.distance(nonzero, width: width, height: height, metric: metric, labels: labels)
    }
    func fillExternalContours(_ mask: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        try actual.fillExternalContours(mask, width: width, height: height)
    }
}
struct NeighborhoodBaselineOps: BaselineFinalFeatures.ImageOperations {
    let actual = NativeSegmentationOpenCVOperations()
    func boxMean(_ values: [Float], width: Int, height: Int, size: Int) throws -> [Float] {
        try actual.boxMean(values, width: width, height: height, size: size)
    }
    func distance(_ nonzero: [UInt8], width: Int, height: Int, metric: BaselineFinalFeatures.DistanceMetric,
                  labels: Bool) throws -> (values: [Float], labels: [Int32]?) {
        let mapped: NativeSegmentationFinalFeatures.DistanceMetric
        switch metric { case .chebyshev: mapped = .chebyshev; case .manhattan: mapped = .manhattan; case .euclidean5: mapped = .euclidean5 }
        return try actual.distance(nonzero, width: width, height: height, metric: mapped, labels: labels)
    }
    func fillExternalContours(_ mask: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        try actual.fillExternalContours(mask, width: width, height: height)
    }
}

@main struct NativeSourceNeighborhoodReuseSmoke {
    static func equal(_ a: NativePixelRFFeatures.Matrix, _ b: NativePixelRFFeatures.Matrix) throws -> Int {
        guard a.featureCount == b.featureCount, a.pixelCount == b.pixelCount, a.values.count == b.values.count else {
            throw NeighborhoodFailure.mismatch("shape")
        }
        for i in a.values.indices where a.values[i].bitPattern != b.values[i].bitPattern {
            throw NeighborhoodFailure.mismatch("column \(i % a.featureCount), row \(i / a.featureCount)")
        }
        return a.values.count
    }
    static func main() throws {
        var cases = 0, scalars = 0, removedMeans = 0
        // Includes all alias windows, nearest-even rounding boundaries,
        // nonaliases, the cap and narrow/one-pixel source domains.
        let fonts: [Double] = [0.25, 1, 5, 6, 10, 14, 18, 22, 26, 30, 34, 38, 54, 58, 62, 70, 130, 514, 65534]
        for (w, h) in [(1, 1), (1, 7), (9, 1), (2, 2), (3, 5), (7, 11), (31, 17)] {
            let n = w * h
            let rgb = (0..<(n * 3)).map { UInt8(($0 * 73 + ($0 / 7) * 19) % 256) }
            let primary = (0..<n).map { Float(($0 * 17) % 101) / 100 }
            let base: [UInt8] = (0..<n).map { $0 % 5 == 0 ? 255 : 0 }
            let coarse = (0..<(n * 4)).map { Float($0 % 19) / 18 }
            let full = (0..<(n * 27)).map { Float(($0 * 3) % 37) / 36 }
            let boundary = primary.reversed().map { $0 }
            for font in fonts {
                let oldBase = try BaselineBoundaryFeatures.extract(rgb: rgb, probabilities: primary,
                    nativeMask: base, coarseRF: coarse, fullRF: full, width: w, height: h, fontPixels: font)
                let newBase = try NativePixelRFBoundaryFeatures.extract(rgb: rgb, probabilities: primary,
                    nativeMask: base, coarseRF: coarse, fullRF: full, width: w, height: h, fontPixels: font)
                scalars += try equal(oldBase, newBase)
                let oldNative = try BaselineBoundaryFeatures.extractEdgeContext(rgb: rgb, probabilities: primary,
                    nativeMask: base, coarseRF: coarse, fullRF: full, width: w, height: h, fontPixels: font)
                let newNative = try NativePixelRFBoundaryFeatures.extractEdgeContext(rgb: rgb, probabilities: primary,
                    nativeMask: base, coarseRF: coarse, fullRF: full, width: w, height: h, fontPixels: font)
                scalars += try equal(oldNative, newNative)
                let counter = NeighborhoodCounter(), operations = NeighborhoodCurrentOps(counter: counter)
                let old = try BaselineFinalFeatures.edgeContext(rgb: rgb, primary: primary, native: base, coarseRF: coarse,
                    fullRF: full, width: w, height: h, fontPixels: font, operations: NeighborhoodBaselineOps())
                let current = try NativeSegmentationFinalFeatures.edgeContext(rgb: rgb, primary: primary, native: base,
                    coarseRF: coarse, fullRF: full, width: w, height: h, fontPixels: font, operations: operations)
                scalars += try equal(old, current)
                let quarter = max(3, min(65, Int((max(1, font) * 0.25).rounded(.toNearestOrEven)) | 1))
                let expectedEdgeMeans = [3, 5, 9].contains(quarter) ? 8 : 10
                guard counter.means == expectedEdgeMeans else { throw NeighborhoodFailure.mismatch("edge mean count") }
                removedMeans += 10 - counter.means
                for positions in [Array(0..<n), Array((0..<n).reversed()).filter { $0 % 3 == 0 }, [0, 0], []] {
                    counter.means = 0
                    let oldContext = try BaselineFinalFeatures.context(edge: old, base: base, boundary: boundary,
                        width: w, height: h, fontPixels: font, positions: positions, operations: NeighborhoodBaselineOps())
                    let newContext = try NativeSegmentationFinalFeatures.context(edge: current, base: base, boundary: boundary,
                        width: w, height: h, fontPixels: font, positions: positions, operations: operations)
                    scalars += try equal(oldContext, newContext)
                    let expected = [3, 7, 15].contains(quarter) ? 6 : 8
                    guard counter.means == expected else { throw NeighborhoodFailure.mismatch("context mean count") }
                    removedMeans += 8 - counter.means
                }
                cases += 1
            }
        }
        var propagated = 0
        for font in [10.0, 70] {
            let quarter = max(3, min(65, Int((font * 0.25).rounded(.toNearestOrEven)) | 1))
            let means = [3, 5, 9].contains(quarter) ? 8 : 10
            for stop in 1...means {
                var calls = 0
                do {
                    _ = try NativePixelRFBoundaryFeatures.extractEdgeContext(rgb: [1, 2, 3], probabilities: [0.5],
                        nativeMask: [255], coarseRF: [Float](repeating: 0, count: 4), fullRF: [Float](repeating: 0, count: 27),
                        width: 1, height: 1, fontPixels: font, boxMean: { values, w, h, size in
                            calls += 1
                            if calls == stop { throw NeighborhoodFailure.mismatch("sentinel") }
                            return NativePixelRFFeatures.boxMean(values, width: w, height: h, size: size)
                        })
                    throw NeighborhoodFailure.mismatch("provider failure swallowed")
                } catch NeighborhoodFailure.mismatch("sentinel") {
                    guard calls == stop else { throw NeighborhoodFailure.mismatch("provider calls") }
                    propagated += 1
                }
            }
        }
        let receipt: [String: Any] = ["status": "PASS", "sourceCases": cases, "comparedFloat32Scalars": scalars,
            "removedMeanCalls": removedMeans, "positionModes": 4, "nativeAndOpenCV": true,
            "providerFailuresPropagated": propagated, "edgeIntermediateBytesRemovedPerPixel": 220,
            "scope": "Synthetic CPU feature matrices and exact provider-call counts; no image-quality or E2E claim"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self))
    }
}
