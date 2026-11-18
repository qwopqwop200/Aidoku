import Foundation

/// Persistent production-source regression using tiny synthetic estimators only.
/// No packaged learned head or corpus is read.
@main
enum NativeBinaryPositiveBatchSmoke {
    static func node(feature: Int = -1, threshold: Double = 0, left: Int = 0, right: Int = 0,
                     missingLeft: Bool = false, leaf: Bool, value: Double = 0) -> [String: Any] {
        ["feature": feature, "threshold": threshold, "left": left, "right": right,
         "missingLeft": missingLeft, "leaf": leaf, "values": leaf ? [value] : []]
    }
    static func model(float32: Bool = false, missingLeft: Bool = false,
                      mutate: ((inout [String: Any], inout [String: Any]) -> Void)? = nil) throws -> NativeFrozenSourceModel {
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
        return try NativeFrozenSourceModel(data: PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0))
    }
    static func same(_ left: [Double], _ right: [Double]) {
        precondition(left.map(\.bitPattern) == right.map(\.bitPattern), "Probability Float64 raw bits changed")
    }
    static func main() throws {
        var comparisons = 0, rejections = 0, fallbackCases = 0
        let rows: [[Float]] = [[Float(0.5).nextDown, -0.25], [0.5, Float(-0.25).nextDown],
            [Float(0.5).nextUp, Float(-0.25).nextUp], [0, -0.0], [-0.0, 0], [.nan, 0],
            [0.5, .nan], [.nan, .nan], [.greatestFiniteMagnitude, -.greatestFiniteMagnitude]]
        let values = rows.flatMap { $0 }
        for float32 in [false, true] { for missingLeft in [false, true] {
            let m = try model(float32: float32, missingLeft: missingLeft)
            guard let prepared = m.preparedPositiveProbabilities() else { preconditionFailure("Supported synthetic structure rejected") }
            func reference(_ selected: [Int]?) throws -> [Double] {
                try (selected ?? Array(rows.indices)).map { try m.predictProbability(rows[$0].map(Double.init))[1] }
            }
            for selected: [Int]? in [nil, [], [8, 0, 8, 3, 1], Array(rows.indices.reversed())] {
                let expected = try reference(selected)
                same(expected, try prepared(values, rows.count, selected))
                same(expected, try m.positiveProbabilities(values, rowCount: rows.count, positions: selected))
                same(expected, try prepared(values, rows.count, selected)) // Reused immutable closure.
                comparisons += 3
            }
            same([], try prepared([], 0, nil)); comparisons += 1
            for invalid in [Float.infinity, -Float.infinity] {
                var bad = values; bad[1] = invalid
                do { _ = try prepared(bad, rows.count, nil); preconditionFailure("Inf input accepted") }
                catch NativeFrozenSourceModel.Failure.invalidFeatures { rejections += 1 }
                // An unselected invalid row must remain unobserved, as before.
                same(try reference([1]), try prepared(bad, rows.count, [1])); comparisons += 1
                same([], try prepared(bad, rows.count, [])); comparisons += 1
            }
            for invalidPositions in [[-1], [rows.count], [0, rows.count]] {
                do { _ = try prepared(values, rows.count, invalidPositions); preconditionFailure("Invalid position accepted") }
                catch NativeFrozenSourceModel.Failure.invalidFeatures { rejections += 1 }
            }
            do { _ = try prepared(Array(values.dropLast()), rows.count, nil); preconditionFailure("Wrong matrix shape accepted") }
            catch NativeFrozenSourceModel.Failure.invalidFeatures { rejections += 1 }
        } }
        // Labels are not source-model IDs: the structural batch contract uses
        // one two-lane class group, regardless of its literal numeric labels.
        let arbitraryLabels = try model { root, _ in root["classes"] = [2.0, 7.0]; root["classGroups"] = [[2.0, 7.0]] }
        precondition(arbitraryLabels.preparedPositiveProbabilities() != nil)
        same(try arbitraryLabels.predictProbability([0.5, 0])[1...1].map { $0 },
             try arbitraryLabels.positiveProbabilities([0.5, 0], rowCount: 1)); comparisons += 1
        // Finite parameters can still overflow their ordered raw sum.
        let overflowing = try model { _, forest in
            forest["baseline"] = [Double.greatestFiniteMagnitude]
            forest["outputs"] = [0]
            forest["trees"] = [[node(leaf: true, value: Double.greatestFiniteMagnitude)]]
        }
        guard let preparedOverflow = overflowing.preparedPositiveProbabilities() else { preconditionFailure("Overflow fixture eligibility") }
        do { _ = try overflowing.predictProbability([0, 0]); preconditionFailure("Scalar overflow accepted") }
        catch NativeFrozenSourceModel.Failure.invalidModel { rejections += 1 }
        do { _ = try preparedOverflow([0, 0], 1, nil); preconditionFailure("Batch overflow accepted") }
        catch NativeFrozenSourceModel.Failure.invalidModel { rejections += 1 }
        do { _ = try preparedOverflow([0, 0, .infinity, 0], 2, nil); preconditionFailure("Row-order error fixture accepted") }
        catch NativeFrozenSourceModel.Failure.invalidModel { rejections += 1 }
        let unreachableInvalidLeaf = try model { _, forest in
            forest["trees"] = [[node(feature: 0, threshold: 0.5, left: 1, right: 2, leaf: false),
                                node(leaf: true, value: 0.3), node(leaf: true, value: .infinity)]]
            forest["outputs"] = [0]
        }
        precondition(unreachableInvalidLeaf.preparedPositiveProbabilities() == nil)
        same(try unreachableInvalidLeaf.predictProbability([0, 0])[1...1].map { $0 },
             try unreachableInvalidLeaf.positiveProbabilities([0, 0], rowCount: 1)); comparisons += 1
        do { _ = try unreachableInvalidLeaf.positiveProbabilities([1, 0], rowCount: 1); preconditionFailure("Reached invalid leaf accepted") }
        catch { rejections += 1 }
        let unsupported: [NativeFrozenSourceModel] = [
            try model { root, forest in
                root["infiniteThresholds"] = true
                forest["trees"] = [[node(feature: 0, threshold: .infinity, left: 1, right: 2, leaf: false),
                                    node(leaf: true, value: -0.7), node(leaf: true, value: 0.9)]]
                forest["outputs"] = [0]
            },
            try model { root, forest in root["link"] = "identity"; forest["kind"] = "histogram-logit" },
            try model { _, forest in
                forest["trees"] = [[node(feature: 0, threshold: 0.5, left: 2, right: 1, leaf: false),
                                    node(leaf: true, value: 0.7),
                                    node(feature: 1, threshold: 0, left: 1, right: 1, leaf: false)]]
                forest["outputs"] = [0]
            }
        ]
        for m in unsupported {
            precondition(m.preparedPositiveProbabilities() == nil)
            same(try rows.map { try m.predictProbability($0.map(Double.init))[1] },
                 try m.positiveProbabilities(values, rowCount: rows.count))
            fallbackCases += 1
        }
        for mutation: (inout [String: Any], inout [String: Any]) -> Void in [
            { _, forest in forest["trees"] = [[node(feature: 0, threshold: 0.5, left: 0, right: 0, leaf: false)]]; forest["outputs"] = [0] },
            { _, forest in forest["trees"] = [[node(feature: 2, threshold: 0.5, left: 1, right: 2, leaf: false), node(leaf: true), node(leaf: true)]]; forest["outputs"] = [0] },
            { _, forest in forest["trees"] = [[node(feature: 0, threshold: .nan, left: 1, right: 2, leaf: false), node(leaf: true), node(leaf: true)]]; forest["outputs"] = [0] }
        ] {
            let m = try model(mutate: mutation)
            precondition(m.preparedPositiveProbabilities() == nil)
            do { _ = try m.positiveProbabilities([0, 0], rowCount: 1); preconditionFailure("Malformed model accepted") }
            catch { rejections += 1 }
        }
        print(String(data: try JSONSerialization.data(withJSONObject: ["passed": true, "exactProbabilityComparisons": comparisons,
            "rejections": rejections, "unsupportedValidFallbackCases": fallbackCases,
            "learnedModelsRead": 0, "corpusFilesRead": 0, "benchmark": false], options: [.sortedKeys]), encoding: .utf8)!)
    }
}
