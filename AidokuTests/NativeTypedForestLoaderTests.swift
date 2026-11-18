import Foundation
import Testing
@testable import Aidoku

/// Tiny constructed models only: no bundled model assets, image pipeline or caches.
struct NativeTypedForestLoaderTests {
    private func node(_ value: Double) -> [String: Any] {
        [
            "feature": -1, "threshold": -0.0, "left": -1, "right": -1,
            "missingLeft": false, "leaf": true, "values": [value]
        ]
    }
    private func root(_ value: Double = 0.25) -> [String: Any] {
        let forest: [String: Any] = [
            "kind": "forest-regression", "features": 1,
            "classes": [Double](), "baseline": [Double](), "trees": [[node(value)]],
            "outputs": [0], "float32Input": false
        ]
        return [
            "schema": 1, "kind": "forest", "featureCount": 1,
            "classes": [Double](), "classGroups": [[Double]](), "metadata": [String: String](),
            "components": [[String: Any]](), "weights": [Double](), "forests": [forest],
            "symmetricTrees": [[String: Any]](), "numericTrees": [[[String: Any]]](),
            "treeOutputs": [Int](), "coefficients": [[Double]](), "intercept": [Double](),
            "mean": [Double](), "scale": 1.0, "bias": [Double](), "link": "identity"
        ]
    }
    private func plist(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
    private func changingNode(_ key: String, to value: Any) -> [String: Any] {
        var r = root(), forests = r["forests"] as! [[String: Any]]
        var trees = forests[0]["trees"] as! [[[String: Any]]]
        trees[0][0][key] = value
        forests[0]["trees"] = trees
        r["forests"] = forests
        return r
    }
    private func prepared(_ data: Data) throws -> NativeFrozenSourceModel? {
        try NativeAppearanceForest.decodePreparedRoot(NativeFrozenSourceModel.self, from: data)
    }

    @Test func binaryParametersAndPrediction() throws {
        let data = try plist(root()), model = try NativeFrozenSourceModel(data: data)
        #expect(try prepared(data) != nil)
        #expect(try model.predict([0]) == [0.25])
        #expect(try model.predict([.nan]) == [0.25])
        #expect(model.forests[0].trees[0][0].threshold.bitPattern == (-0.0 as Double).bitPattern)
    }
    @Test func actualJSONRoutePreservesPrediction() throws {
        let data = try JSONSerialization.data(withJSONObject: root())
        #expect(try prepared(data) == nil)
        #expect(try NativeFrozenSourceModel(data: data).predict([0]) == [0.25])
    }
    @Test func branchThresholdAndMissingDirectionMatchOriginalDecoder() throws {
        var r = root(), forests = r["forests"] as! [[String: Any]]
        let branch: [String: Any] = [
            "feature": 0, "threshold": 0.5, "left": 1, "right": 2,
            "missingLeft": true, "leaf": false, "values": [0.0]
        ]
        forests[0]["trees"] = [[branch, node(0.25), node(0.75)]]
        r["forests"] = forests
        let data = try plist(r), model = try NativeFrozenSourceModel(data: data)
        // No userInfo cache: direct PropertyListDecoder follows the original
        // per-field Decodable path, independently of the prepared-root route.
        let reference = try PropertyListDecoder().decode(NativeFrozenSourceModel.self, from: data)
        for (value, expected) in [(0.5, 0.25), (0.5.nextDown, 0.25), (0.5.nextUp, 0.75), (.nan, 0.25)] {
            let actual = try model.predict([value]), original = try reference.predict([value])
            #expect(actual == [expected])
            #expect(actual.map(\.bitPattern) == original.map(\.bitPattern))
        }
    }
    @Test func integralRealFallsBackWithoutChangingAdmission() throws {
        let data = try plist(changingNode("feature", to: 0.0))
        #expect(try prepared(data) == nil)
        #expect(try NativeFrozenSourceModel(data: data).predict([0]) == [0.25])
    }
    @Test func corruptNumericAndBoolAreRejected() throws {
        for (key, value) in [
            ("feature", true as Any), ("feature", 0.5 as Any),
            ("threshold", true as Any), ("leaf", 1 as Any)
        ] {
            let data = try plist(changingNode(key, to: value))
            #expect(try prepared(data) == nil)
            #expect(throws: (any Error).self) { try NativeFrozenSourceModel(data: data) }
        }
    }
    @Test func nonfinitePreservesOldFallbackAndSchemaGuard() throws {
        let data = try plist(changingNode("threshold", to: Double.nan))
        #expect(try prepared(data) == nil)
        #expect(try NativeFrozenSourceModel(data: data).forests[0].trees[0][0].threshold.isNaN)
        var invalid = root()
        invalid["schema"] = 2
        for bytes in [try plist(invalid), try JSONSerialization.data(withJSONObject: invalid)] {
            #expect(throws: (any Error).self) { try NativeFrozenSourceModel(data: bytes) }
        }
        #expect(throws: (any Error).self) { try NativeFrozenSourceModel(data: Data("bplist00".utf8)) }
    }
    @Test func aliasesAndNestedComponentsDoNotMisbind() throws {
        var r = root(), forests = r["forests"] as! [[String: Any]]
        // Repeated Foundation objects serialize with shared references when
        // supported; expected values do not depend on physical object identity.
        let shared = node(0.25), tree = [shared, shared]
        forests[0]["trees"] = [tree, tree]
        forests[0]["outputs"] = [0, 0]
        r["forests"] = [forests[0], forests[0]]
        r["components"] = [root(0.875)]
        let model = try NativeFrozenSourceModel(data: plist(r))
        #expect(model.forests.count == 2)
        #expect(model.forests[1].trees[1][1].values == [0.25])
        #expect(try model.components[0].predict([0]) == [0.875])
    }
    @Test func nameAndCumulativeOutputBudgetsFallBack() throws {
        var r = root(), forests = r["forests"] as! [[String: Any]]
        for index in 0..<257 { forests[0]["extra-name-\(index)"] = index }
        r["forests"] = forests
        let names = try plist(r)
        #expect(try prepared(names) == nil)
        #expect(try NativeFrozenSourceModel(data: names).predict([0]) == [0.25])
        r = root()
        forests = r["forests"] as! [[String: Any]]
        forests[0]["outputs"] = [Int](repeating: 0, count: 4096)
        r["forests"] = Array(repeating: forests[0], count: 17)
        let outputs = try plist(r)
        #expect(try prepared(outputs) == nil)
        #expect(try NativeFrozenSourceModel(data: outputs).forests.count == 17)
    }
    @Test func concurrentDifferentRootsKeepDecoderLocalState() async throws {
        let a = try plist(root(0.25)), b = try plist(root(0.875))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                let data = index.isMultiple(of: 2) ? a : b
                let expected = index.isMultiple(of: 2) ? 0.25 : 0.875
                group.addTask {
                    let model = try NativeFrozenSourceModel(data: data)
                    #expect(try model.predict([0]) == [expected])
                }
            }
            try await group.waitForAll()
        }
    }
}
