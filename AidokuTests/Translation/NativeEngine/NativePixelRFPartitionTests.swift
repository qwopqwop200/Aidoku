import Foundation
import Testing
@testable import Aidoku

struct NativePixelRFPartitionTests {
    private func primary(_ trees: [[[Any]]]) throws -> NativePixelRFForest {
        let model: [String: Any] = ["schema": 1, "featureCount": 62, "threshold": 0.5, "trees": trees,
            "sourceModelSHA256": String(repeating: "0", count: 64), "sourceFeatureVariant": "pixel-full-rf-v2"]
        return try NativePixelRFForest(data: JSONSerialization.data(withJSONObject: model))
    }

    @Test func exactSplitTiesAndInvalidUnusedFeature() throws {
        let zero: [Any] = [-1, 0, Int.min, Int.max, 0], one: [Any] = [-1, 0, Int.max, Int.min, 1]
        let a: [Any] = [0, 0.0, 1, 2, 0], b: [Any] = [61, 0.5, 1, 2, 0]
        let forest = try primary([[a, one, zero], [b, one, zero], [one]])
        let count = 16_385
        var features = [Float](repeating: 0, count: count * 62)
        let zeroNeighbors: [Float] = [-Float.leastNonzeroMagnitude, -0.0, .zero, .leastNonzeroMagnitude]
        let halfNeighbors: [Float] = [Float(0.5).nextDown, 0.5, Float(0.5).nextUp]
        var expected: [UInt32] = []
        for i in 0..<count {
            let f = zeroNeighbors[i % 4], g = halfNeighbors[i % 3]
            features[i * 62] = f
            features[i * 62 + 61] = g
            expected.append((Float(1 + (f <= 0 ? 1 : 0) + (g <= 0.5 ? 1 : 0)) / 3).bitPattern)
        }
        func matrix(_ values: [Float]) -> NativePixelRFFeatures.Matrix {
            .init(values: values, featureCount: 62, pixelCount: count)
        }
        #expect(try forest.probabilities(matrix(features)).map(\.bitPattern) == expected)
        for bad in [Float.nan, .signalingNaN, .infinity, -.infinity] {
            features[features.count - 2] = bad
            #expect(throws: NativePixelRFForest.Failure.invalidFeatures) { try forest.probabilities(matrix(features)) }
        }
    }

    @Test func deeplyUnbalancedPartitionsPreserveIndividualLeafVotes() throws {
        // Each split sends one row to the right and the rest deeper left.
        // Each deferred right branch has a known alternating vote.
        var tree: [[Any]] = (0..<1023).map { index in
            [0, Float(1022 - index) + 0.5, index + 1, index.isMultiple(of: 2) ? 1023 : 1024, 0]
        }
        tree += [[-1, 0, 0, 0, 0], [-1, 0, 0, 0, 1]]
        let forest = try primary([tree])
        for count in [1024, 1025, 16_385] {
            var features = [Float](repeating: 0, count: count * 62)
            for i in 0..<count { features[i * 62] = Float(i % 1024) }
            let actual = try forest.probabilities(.init(values: features, featureCount: 62, pixelCount: count))
            #expect(actual.indices.allSatisfy { i in
                let row = i % 1024
                let expected = Float(row > 0 && (1023 - row) % 2 == 1 ? 1 : 0)
                return actual[i].bitPattern == expected.bitPattern
            })
        }
    }
}
