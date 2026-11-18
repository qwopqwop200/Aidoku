import Foundation
import Testing
@testable import Aidoku

/// Tiny synthetic property-list estimators only: no learned assets or runtime
/// stores. Batch results must preserve the scalar evaluator's exact bits/errors.
@Suite struct NativeFrozenPositiveBatchTests {
    private typealias Model = NativeFrozenSourceModel
    private enum ExpectedFailure { case features, model, forest }

    private func node(feature: Int = -1, threshold: Double = 0, left: Int = 0, right: Int = 0,
                      missingLeft: Bool = false, leaf: Bool, value: Double = 0) -> [String: Any] {
        ["feature": feature, "threshold": threshold, "left": left, "right": right,
         "missingLeft": missingLeft, "leaf": leaf, "values": leaf ? [value] : []]
    }

    private func model(float32: Bool = false, missingLeft: Bool = false,
                       mutate: ((inout [String: Any], inout [String: Any]) -> Void)? = nil) throws -> Model {
        var forest: [String: Any] = ["kind": "histogram-regression", "features": 2, "classes": [],
            "baseline": [0.15], "outputs": [0, 0], "float32Input": float32,
            "trees": [[node(feature: 0, threshold: 0.5, left: 1, right: 2, missingLeft: missingLeft, leaf: false),
                       node(leaf: true, value: -0.7), node(leaf: true, value: 0.9)],
                      [node(feature: 1, threshold: -0.25, left: 1, right: 2, missingLeft: !missingLeft, leaf: false),
                       node(leaf: true, value: 0.2), node(leaf: true, value: -0.4)]]]
        var root: [String: Any] = ["schema": 1, "kind": "forest", "featureCount": 2, "classes": [0.0, 1.0],
            "classGroups": [[0.0, 1.0]], "metadata": [:], "components": [], "weights": [],
            "symmetricTrees": [], "numericTrees": [], "treeOutputs": [], "coefficients": [],
            "intercept": [], "mean": [], "scale": 1.0, "bias": [], "link": "sigmoid"]
        mutate?(&root, &forest)
        root["forests"] = [forest]
        return try Model(data: PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0))
    }

    private var rows: [[Float]] {
        [[Float(0.5).nextDown, -0.25], [0.5, Float(-0.25).nextDown],
         [Float(0.5).nextUp, Float(-0.25).nextUp], [0, -0.0], [-0.0, 0],
         [.nan, 0], [0.5, .nan], [.nan, .nan], [.greatestFiniteMagnitude, -.greatestFiniteMagnitude]]
    }

    private func scalar(_ model: Model, rows: [[Float]], positions: [Int]? = nil) throws -> [Double] {
        try (positions ?? Array(rows.indices)).map { try model.predictProbability(rows[$0].map(Double.init))[1] }
    }

    private func sameBits(_ expected: [Double], _ observed: [Double]) {
        #expect(expected.map(\.bitPattern) == observed.map(\.bitPattern))
    }

    private func expectFailure(_ expected: ExpectedFailure, _ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Invalid input/model was accepted; expected \(String(describing: expected))")
        } catch let failure as Model.Failure {
            switch (expected, failure) {
            case (.features, .invalidFeatures), (.model, .invalidModel): return
            default: Issue.record("Wrong source-model error: \(String(describing: failure))")
            }
        } catch let failure as NativeAppearanceForest.Failure {
            switch (expected, failure) {
            case (.forest, .invalidModel): return
            default: Issue.record("Wrong forest error: \(String(describing: failure))")
            }
        } catch {
            Issue.record("Unexpected error type: \(String(reflecting: error))")
        }
    }

    @Test func batchPreservesScalarBitsForNaNTiesAndBothInputModes() throws {
        let sourceRows = rows, values = sourceRows.flatMap { $0 }
        for float32 in [false, true] {
            for missingLeft in [false, true] {
                let model = try model(float32: float32, missingLeft: missingLeft)
                let prepared = try #require(model.preparedPositiveProbabilities())
                let expected = try scalar(model, rows: sourceRows)
                sameBits(expected, try prepared(values, sourceRows.count, nil))
                sameBits(expected, try model.positiveProbabilities(values, rowCount: sourceRows.count))
                sameBits(expected, try prepared(values, sourceRows.count, nil))
            }
        }
    }

    @Test func selectedRowsKeepDuplicatesOrderEmptyAndUnselectedInfinity() throws {
        let sourceRows = rows, values = sourceRows.flatMap { $0 }, model = try model()
        let prepared = try #require(model.preparedPositiveProbabilities())
        for positions in [[], [8, 0, 8, 3, 1], Array(sourceRows.indices.reversed())] {
            let expected = try scalar(model, rows: sourceRows, positions: positions)
            sameBits(expected, try prepared(values, sourceRows.count, positions))
            sameBits(expected, try model.positiveProbabilities(values, rowCount: sourceRows.count, positions: positions))
        }
        sameBits([], try prepared([], 0, nil))
        for invalid: Float in [.infinity, -.infinity] {
            var changed = values
            changed[1] = invalid
            sameBits(try scalar(model, rows: sourceRows, positions: [1]), try prepared(changed, sourceRows.count, [1]))
            sameBits([], try prepared(changed, sourceRows.count, []))
        }
    }

    @Test func invalidInputsAndRawOverflowKeepExactErrorCases() throws {
        let model = try model(), values = rows.flatMap { $0 }, count = rows.count
        let prepared = try #require(model.preparedPositiveProbabilities())
        for positions in [[-1], [count], [0, count]] {
            expectFailure(.features) { _ = try prepared(values, count, positions) }
        }
        expectFailure(.features) { _ = try prepared(Array(values.dropLast()), count, nil) }
        expectFailure(.features) { _ = try prepared([], -1, nil) }
        expectFailure(.features) { _ = try prepared([], Int.max, nil) }
        for invalid: Float in [.infinity, -.infinity] {
            var changed = values
            changed[1] = invalid
            expectFailure(.features) { _ = try prepared(changed, count, nil) }
            expectFailure(.features) { _ = try model.positiveProbabilities(changed, rowCount: count) }
        }
        let overflowing = try self.model { _, forest in
            forest["baseline"] = [Double.greatestFiniteMagnitude]
            forest["outputs"] = [0]
            forest["trees"] = [[node(leaf: true, value: Double.greatestFiniteMagnitude)]]
        }
        let preparedOverflow = try #require(overflowing.preparedPositiveProbabilities())
        expectFailure(.model) { _ = try overflowing.predictProbability([0, 0]) }
        expectFailure(.model) { _ = try preparedOverflow([0, 0], 1, nil) }
        // Preserve row-order error precedence: row0 overflow precedes row1 Inf.
        expectFailure(.model) { _ = try preparedOverflow([0, 0, .infinity, 0], 2, nil) }
    }

    @Test func unsupportedValidStructuresRetainGenericScalarFallback() throws {
        let unsupported = [
            try model { root, forest in
                root["infiniteThresholds"] = true
                forest["trees"] = [[node(feature: 0, threshold: .infinity, left: 1, right: 2, leaf: false),
                                    node(leaf: true, value: -0.7), node(leaf: true, value: 0.9)]]
                forest["outputs"] = [0]
            },
            try model { root, forest in root["link"] = "identity"; forest["kind"] = "histogram-logit" },
            try model { _, forest in
                // Backward index edges are acyclic, but not eligible for the
                // strictly-forward execution cache. The generic path is valid.
                forest["trees"] = [[node(feature: 0, threshold: 0.5, left: 2, right: 1, leaf: false),
                                    node(leaf: true, value: 0.7),
                                    node(feature: 1, threshold: 0, left: 1, right: 1, leaf: false)]]
                forest["outputs"] = [0]
            }
        ]
        for model in unsupported {
            #expect(model.preparedPositiveProbabilities() == nil)
            sameBits(try scalar(model, rows: rows),
                try model.positiveProbabilities(rows.flatMap { $0 }, rowCount: rows.count))
        }
    }

    @Test func arbitraryLabelsAndMalformedUnreachedNodesKeepStructuralContract() throws {
        let arbitraryLabels = try model { root, _ in
            root["classes"] = [2.0, 7.0]
            root["classGroups"] = [[2.0, 7.0]]
        }
        #expect(arbitraryLabels.preparedPositiveProbabilities() != nil)
        sameBits([try arbitraryLabels.predictProbability([0.5, 0])[1]],
            try arbitraryLabels.positiveProbabilities([0.5, 0], rowCount: 1))
        let invalidUnreachedLeaf = try model { _, forest in
            forest["trees"] = [[node(feature: 0, threshold: 0.5, left: 1, right: 2, leaf: false),
                                node(leaf: true, value: 0.3), node(leaf: true, value: .infinity)]]
            forest["outputs"] = [0]
        }
        #expect(invalidUnreachedLeaf.preparedPositiveProbabilities() == nil)
        sameBits([try invalidUnreachedLeaf.predictProbability([0, 0])[1]],
            try invalidUnreachedLeaf.positiveProbabilities([0, 0], rowCount: 1))
        expectFailure(.forest) { _ = try invalidUnreachedLeaf.positiveProbabilities([1, 0], rowCount: 1) }
        let malformed = [
            try model { _, forest in
                forest["trees"] = [[node(feature: 0, threshold: 0.5, left: 0, right: 0, leaf: false)]]
                forest["outputs"] = [0]
            },
            try model { _, forest in
                forest["trees"] = [[node(feature: 2, threshold: 0.5, left: 1, right: 2, leaf: false),
                                    node(leaf: true), node(leaf: true)]]
                forest["outputs"] = [0]
            },
            try model { _, forest in
                forest["trees"] = [[node(feature: 0, threshold: .nan, left: 1, right: 2, leaf: false),
                                    node(leaf: true), node(leaf: true)]]
                forest["outputs"] = [0]
            }
        ]
        for model in malformed {
            #expect(model.preparedPositiveProbabilities() == nil)
            expectFailure(.forest) { _ = try model.positiveProbabilities([0, 0], rowCount: 1) }
        }
    }
}
