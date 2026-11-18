import Foundation

/// Frozen source-support v2 admission, before query/record materialization.
/// The full raw DET/CC/RF inventory remains immutable context. No OCR, GT,
/// source IDs, page routing or geometry tables are accepted by this model.
enum NativeOCRRawSourceAdmission {
    enum Failure: Error { case invalidData, invalidSchema, invalidFeatures, invalidNode, limitsExceeded }
    private static let maximumBytes = 1_048_576
    private static let maximumTrees = 128
    private static let maximumNodes = 4096
    private static let maximumDepth = 8
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static func named(_ name: String) -> Self { .init(stringValue: name) }
    }
    /// Array indirection permits an immutable recursive value, without shared
    /// mutable class nodes. Depth/node bounds are enforced during decoding.
    private struct TreeNode: Decodable, Sendable {
        let value: Double?
        let feature: Int
        let threshold: Double
        let children: [TreeNode]
        let nodeCount: Int
        init(from decoder: Decoder) throws {
            guard decoder.codingPath.count <= maximumDepth + 1 else { throw Failure.limitsExceeded }
            let c = try decoder.container(keyedBy: Key.self)
            let names = Set(c.allKeys.map(\.stringValue))
            if names == ["value"] {
                let v = try c.decode(Double.self, forKey: .named("value"))
                guard v.isFinite else { throw Failure.invalidNode }
                value = v; feature = -1; threshold = 0; children = []; nodeCount = 1
            } else {
                guard names == ["feature", "threshold", "left", "right"] else { throw Failure.invalidNode }
                let f = try c.decode(Int.self, forKey: .named("feature"))
                let t = try c.decode(Double.self, forKey: .named("threshold"))
                guard (0..<156).contains(f), t.isFinite else { throw Failure.invalidNode }
                let left = try c.decode(TreeNode.self, forKey: .named("left"))
                let right = try c.decode(TreeNode.self, forKey: .named("right"))
                value = nil; feature = f; threshold = t; children = [left, right]
                nodeCount = 1 + left.nodeCount + right.nodeCount
                guard nodeCount <= maximumNodes else { throw Failure.limitsExceeded }
            }
        }
        func score(_ x: [Double]) -> Double {
            if let value { return value }
            // Frozen ABI is STRICT <, including threshold-equality cases.
            return children[x[feature] < threshold ? 0 : 1].score(x)
        }
    }
    private struct WireModel: Decodable {
        let initial: Double
        let rate: Double
        let trees: [TreeNode]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            guard Set(c.allKeys.map(\.stringValue)) == ["schema", "initial", "rate", "trees", "featureNames"],
                  try c.decode(String.self, forKey: .named("schema")) == "source-physical-geometry-quality-boost-v1" else {
                throw Failure.invalidSchema
            }
            let names = try c.decode([String].self, forKey: .named("featureNames"))
            guard names == NativeOCRSourceSupportFeatures155.featureNames + ["missingFeatureFraction"] else {
                throw Failure.invalidFeatures
            }
            initial = try c.decode(Double.self, forKey: .named("initial"))
            rate = try c.decode(Double.self, forKey: .named("rate"))
            guard initial.isFinite, rate.isFinite, rate > 0, rate <= 1 else { throw Failure.invalidData }
            var container = try c.nestedUnkeyedContainer(forKey: .named("trees"))
            var parsed = [TreeNode](), nodes = 0
            while !container.isAtEnd {
                guard parsed.count < maximumTrees else { throw Failure.limitsExceeded }
                let node = try container.decode(TreeNode.self)
                nodes += node.nodeCount
                guard nodes <= maximumNodes else { throw Failure.limitsExceeded }
                parsed.append(node)
            }
            guard !parsed.isEmpty else { throw Failure.limitsExceeded }
            trees = parsed
        }
    }
    struct Model: Sendable {
        private let initial: Double
        private let rate: Double
        private let trees: [TreeNode]
        init(data: Data) throws {
            guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.limitsExceeded }
            let decoder = JSONDecoder()
            // Decode original bytes directly: never JSONSerialization -> JSON.
            let model = try decoder.decode(WireModel.self, from: data)
            initial = model.initial; rate = model.rate; trees = model.trees
        }
        func score(rawFeatures: [Float]) -> Double? {
            guard rawFeatures.count == 155 else { return nil }
            let missing = rawFeatures.filter { !$0.isFinite }.count
            let x = rawFeatures.map { $0.isFinite ? Double($0) : 0 } + [Double(missing) / 155]
            var result = initial
            for tree in trees { result += rate * tree.score(x) }
            return result.isFinite ? result : nil
        }
        /// Whole missing RF/private-CC or malformed vectors fail open. Legitimate
        /// boundary42...154 NaNs retain the frozen missing-fraction ABI.
        func keep(rawFeatures: [Float]) -> Bool {
            guard rawFeatures.count == 155, rawFeatures.prefix(42).allSatisfy(\.isFinite) else { return true }
            // Convert Float32 to Double before comparisons; changing these to
            // Float literals changes threshold-equality semantics.
            let x = rawFeatures.map(Double.init)
            guard x[5] >= 0.5, let score = score(rawFeatures: rawFeatures) else { return true }
            if score >= 0.0528098767924664 { return true }
            let privateInk = x[0] >= 0.9 && x[1] >= 0.5 && x[2] >= 0.98
                && x[3] >= 0.95 && x[4] == 0 && x[6] >= 0.1
            let strongRFSource = x[0] >= 0.8 && x[1] >= 0.5 && x[2] >= 0.95
                && x[3] >= 0.95 && x[6] >= 0.5
            return privateInk || strongRFSource
        }
    }
}
