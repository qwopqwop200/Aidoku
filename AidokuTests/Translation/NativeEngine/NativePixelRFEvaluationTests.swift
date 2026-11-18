import Foundation
import Testing
@testable import Aidoku

struct NativePixelRFEvaluationTests {
    @Test func packetAndTailKeepThresholdVotesExact() throws {
        let zero = [-1, 0, 0, 0, 0]
        let one = [-1, 0, 0, 0, 1]
        let split: [Any] = [0, 0.25, 1, 2, 0]
        let trees: [[[Any]]] = [[split, zero, one], [split, one, zero], [split, zero, one]]
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "featureCount": 35, "threshold": 0.5, "trees": trees,
            "sourceModelSHA256": String(repeating: "0", count: 64), "sourceFeatureVariant": "pixel-coarse-rf-v1"
        ])
        let forest = try NativePixelRFForest(data: data)
        for count in [67, 16_387, 32_769] {
            let values = (0..<count).flatMap { row in
                [row.isMultiple(of: 2) ? Float(0.25) : Float(0.25).nextUp] + [Float](repeating: 0, count: 34)
            }
            let matrix = NativePixelRFFeatures.Matrix(values: values, featureCount: 35, pixelCount: count)
            let probabilities = try forest.probabilities(matrix)
            let expected = (0..<count).map { (Float($0.isMultiple(of: 2) ? 1 : 2) / 3).bitPattern }
            #expect(probabilities.map(\.bitPattern) == expected)
            #expect(try forest.mask(matrix) == (0..<count).map { UInt8($0.isMultiple(of: 2) ? 0 : 255) })
        }
    }

    @Test func largePrimaryCropTilesMatchDenseProbabilitiesAndRejectInvalidRF() throws {
        let zero = [-1, 0, 0, 0, 0]
        let one = [-1, 0, 0, 0, 1]
        let local: [Any] = [0, 0.25, 1, 2, 0]
        let rf: [Any] = [61, 0.25, 1, 2, 0]
        let trees: [[[Any]]] = [[local, zero, one], [rf, zero, one]]
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "featureCount": 62, "threshold": 0.5, "trees": trees,
            "sourceModelSHA256": String(repeating: "0", count: 64), "sourceFeatureVariant": "pixel-full-rf-v2"
        ])
        let forest = try NativePixelRFForest(data: data)
        // Five tiles; the last has a partial packet and scalar tail.
        let width = 257
        let height = 257
        let count = width * height
        let rgb = (0..<(count * 3)).map { UInt8(truncatingIfNeeded: $0) }
        let mask = (0..<count).map { UInt8($0.isMultiple(of: 7) ? 255 : 0) }
        let coarse = [Float](repeating: 0, count: count * 4)
        var support = [Float](repeating: 0.25, count: count * 27)
        for row in stride(from: 1, to: count, by: 2) { support[row * 27 + 26] = Float(0.25).nextUp }
        func input(_ values: [Float]) -> NativePixelRFFeatures.Input {
            .init(width: width, height: height, rgb: rgb, nativeMask: mask, polygons: [],
                  fontPixels: 39, coarseRF: coarse, fullRF: values)
        }
        let dense = try forest.probabilities(NativePixelRFFeatures.extract(input(support)))
        #expect(Set(dense) == [0, 0.5, 1])
        #expect(try forest.cropProbabilities(input(support)).map(\.bitPattern) == dense.map(\.bitPattern))
        support[support.count - 1] = .nan
        #expect(throws: NativePixelRFFeatures.Failure.invalidInput) {
            try forest.cropProbabilities(input(support))
        }
    }

    @Test func oppositeClassFieldProjectsBothExistingDistanceChannels() {
        for (w, h) in [(1, 1), (1, 17), (20, 1), (16, 11), (11, 16)] {
            for alpha in [[UInt8](repeating: 0, count: w * h), [UInt8](repeating: 1, count: w * h),
                          (0..<(w * h)).map({ UInt8($0 % 9 < 4 ? 0 : $0 % 255 + 1) })] {
                let outside = NativePixelRFFeatures.distance(toNonzero: alpha, width: w, height: h)
                let inside = NativePixelRFFeatures.distance(toNonzero: alpha.map { $0 == 0 ? 1 : 0 }, width: w, height: h)
                let combined = NativePixelRFFeatures.oppositeClassDistance(alpha, width: w, height: h)
                #expect(alpha.indices.allSatisfy { combined[$0] == (alpha[$0] == 0 ? outside[$0] : inside[$0]) })
            }
        }
    }
}
