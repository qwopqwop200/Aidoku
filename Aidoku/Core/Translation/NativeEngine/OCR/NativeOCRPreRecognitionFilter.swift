import Foundation

/// Numerical admission backend. The pre-rec caller supplies RF/DET signals;
/// the explicit post-rec caller may additionally supply recognition confidence.
/// Neither caller supplies text content, RGB, shape classes or geometry targets.
enum NativeOCRPreRecognitionFilter {
    typealias G = NativeOCRIndividualGeometryHypotheses
    enum Failure: Error { case invalidPolicy, invalidFeatures, invalidTree }
    enum Stage: Equatable, Sendable {
        case beforeRecognition, afterRecognition
        fileprivate var modelSchema: String {
            self == .beforeRecognition ? "pre-rec-numeric-signal-only-v1" : "post-rec-joint-signal-only-v1"
        }
        fileprivate var reportSchema: String {
            self == .beforeRecognition ? "native-pre-rec-signal-only-admission-v1" : "native-post-rec-joint-admission-v1"
        }
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static func named(_ value: String) -> Self { .init(stringValue: value) }
    }
    private static func keys(_ decoder: Decoder, _ expected: Set<String>) throws -> KeyedDecodingContainer<Key> {
        let c = try decoder.container(keyedBy: Key.self)
        guard Set(c.allKeys.map(\.stringValue)) == expected else { throw Failure.invalidPolicy }
        return c
    }
    private struct Node: Decodable, Sendable {
        let feature: Int
        let value: Double
        let threshold: Double
        let left: Int
        let right: Int
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            feature = try c.decode(Int.self, forKey: .named("feature"))
            if feature == -1 {
                guard Set(c.allKeys.map(\.stringValue)) == ["feature", "value"] else { throw Failure.invalidTree }
                value = try c.decode(Double.self, forKey: .named("value"))
                threshold = 0; left = 0; right = 0
                guard value.isFinite else { throw Failure.invalidTree }
            } else {
                guard Set(c.allKeys.map(\.stringValue)) == ["feature", "threshold", "left", "right"] else {
                    throw Failure.invalidTree
                }
                value = 0
                threshold = try c.decode(Double.self, forKey: .named("threshold"))
                left = try c.decode(Int.self, forKey: .named("left"))
                right = try c.decode(Int.self, forKey: .named("right"))
                guard feature >= 0, threshold.isFinite else { throw Failure.invalidTree }
            }
        }
    }
    private struct Boost: Decodable, Sendable {
        let schema: String
        let bias: Double
        let learningRate: Double
        let featureNames: [String]
        let trees: [[Node]]
        init(from decoder: Decoder) throws {
            let c = try keys(decoder, ["schema", "bias", "learningRate", "featureNames", "trees"])
            schema = try c.decode(String.self, forKey: .named("schema"))
            bias = try c.decode(Double.self, forKey: .named("bias"))
            learningRate = try c.decode(Double.self, forKey: .named("learningRate"))
            featureNames = try c.decode([String].self, forKey: .named("featureNames"))
            trees = try c.decode([[Node]].self, forKey: .named("trees"))
            guard schema == "numeric-hist-gradient-boost-v1", bias.isFinite,
                  learningRate.isFinite, learningRate > 0, learningRate <= 1,
                  !trees.isEmpty, trees.count <= 1024 else { throw Failure.invalidPolicy }
            var total = 0
            for tree in trees {
                guard !tree.isEmpty, tree.count <= 65_535 else { throw Failure.invalidTree }
                total += tree.count
                guard total <= 262_144 else { throw Failure.invalidTree }
                var seen = Set<Int>(), stack = [(0, 0)]
                while let (index, depth) = stack.popLast() {
                    guard tree.indices.contains(index), depth <= 32, seen.insert(index).inserted else {
                        throw Failure.invalidTree
                    }
                    let n = tree[index]
                    if n.feature >= 0 {
                        guard n.feature < featureNames.count else { throw Failure.invalidTree }
                        stack.append((n.right, depth + 1)); stack.append((n.left, depth + 1))
                    }
                }
                guard seen.count == tree.count else { throw Failure.invalidTree }
            }
        }
        func score(_ x: [Double]) -> Double {
            var result = bias
            for tree in trees {
                var index = 0
                while tree[index].feature >= 0 {
                    let n = tree[index]
                    index = x[n.feature] <= n.threshold ? n.left : n.right
                }
                result += learningRate * tree[index].value
            }
            return result
        }
    }
    private struct Wire: Decodable {
        let schema: String
        let model: Boost
        let threshold: Double
        let featureNames: [String]
        init(from decoder: Decoder) throws {
            let c = try keys(decoder, ["schema", "model", "threshold", "retainUnavailableEvidence", "featureNames", "geometryModified"])
            schema = try c.decode(String.self, forKey: .named("schema"))
            guard ["pre-rec-numeric-signal-only-v1", "post-rec-joint-signal-only-v1"].contains(schema),
                  try c.decode(Bool.self, forKey: .named("retainUnavailableEvidence")),
                  try !c.decode(Bool.self, forKey: .named("geometryModified")) else { throw Failure.invalidPolicy }
            model = try c.decode(Boost.self, forKey: .named("model"))
            threshold = try c.decode(Double.self, forKey: .named("threshold"))
            featureNames = try c.decode([String].self, forKey: .named("featureNames"))
            guard threshold.isFinite, model.featureNames == featureNames else { throw Failure.invalidPolicy }
        }
    }
    private struct Header: Decodable { let schema: String }
    private struct Ensemble: Decodable {
        let policies: [Wire]
        let featureNames: [String]
        init(from decoder: Decoder) throws {
            let c = try keys(decoder, ["schema", "policies", "featureNames", "retainUnavailableEvidence", "geometryModified"])
            guard try c.decode(String.self, forKey: .named("schema")) == "pre-rec-signal-ensemble-v1",
                  try c.decode(Bool.self, forKey: .named("retainUnavailableEvidence")),
                  try !c.decode(Bool.self, forKey: .named("geometryModified")) else { throw Failure.invalidPolicy }
            policies = try c.decode([Wire].self, forKey: .named("policies"))
            featureNames = try c.decode([String].self, forKey: .named("featureNames"))
            guard (2...8).contains(policies.count), policies.allSatisfy({ $0.featureNames == featureNames }) else {
                throw Failure.invalidFeatures
            }
        }
    }
    struct Model: Sendable {
        let stage: Stage
        let featureNames: [String]
        let threshold: Double
        private let boosts: [Boost]
        private let cutoffs: [Double]
        init(data: Data, expectedFeatureNames: [String], stage: Stage = .beforeRecognition) throws {
            guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
                  (1...512).contains(expectedFeatureNames.count),
                  Set(expectedFeatureNames).count == expectedFeatureNames.count else { throw Failure.invalidPolicy }
            // Decode original decimal tokens directly; NSNumber round trips can
            // change equality splits by an ULP.
            let decoder = JSONDecoder()
            if try decoder.decode(Header.self, from: data).schema == "pre-rec-signal-ensemble-v1" {
                guard stage == .beforeRecognition else { throw Failure.invalidPolicy }
                let p = try decoder.decode(Ensemble.self, from: data)
                guard p.featureNames == expectedFeatureNames,
                      p.policies.allSatisfy({ $0.schema == stage.modelSchema }) else { throw Failure.invalidFeatures }
                featureNames = p.featureNames; threshold = 0
                boosts = p.policies.map(\.model); cutoffs = p.policies.map(\.threshold)
            } else {
                let p = try decoder.decode(Wire.self, from: data)
                guard p.featureNames == expectedFeatureNames, p.schema == stage.modelSchema else { throw Failure.invalidFeatures }
                featureNames = p.featureNames; threshold = p.threshold; boosts = [p.model]; cutoffs = [p.threshold]
            }
            self.stage = stage
        }
        func score(features: [Double]) -> Double? {
            guard features.count == featureNames.count, features.allSatisfy(\.isFinite) else { return nil }
            let result: Double
            if boosts.count == 1 {
                // Preserve raw single-model scores for independent parity.
                result = boosts[0].score(features)
            } else {
                result = zip(boosts, cutoffs).map { $0.0.score(features) - $0.1 }.min()!
            }
            return result.isFinite ? result : nil
        }
    }
    struct Report: Codable, Sendable {
        let schema: String
        let inputCount: Int
        let keptIndices: [Int]
        let missingEvidenceKeptIndices: [Int]
        let scores: [Double?]
        let threshold: Double
        let recognizerCalls: Int
        let geometryModified: Bool
    }
    struct Result: Sendable { let output: G.Output; let report: Report }
    static func apply(_ input: G.Output, features: [[Double]], model: Model) throws -> Result {
        guard features.count == input.individuals.count,
              features.allSatisfy({ $0.count == model.featureNames.count }) else { throw Failure.invalidFeatures }
        var kept = [Int](), missing = [Int](), scores = [Double?]()
        for (index, row) in features.enumerated() {
            let score = model.score(features: row)
            scores.append(score)
            if let score {
                if score >= model.threshold { kept.append(index) }
            } else {
                kept.append(index); missing.append(index)
            }
        }
        return .init(output: G.selecting(input, indices: kept), report: .init(
            schema: model.stage.reportSchema, inputCount: features.count,
            keptIndices: kept, missingEvidenceKeptIndices: missing, scores: scores,
            threshold: model.threshold, recognizerCalls: 0, geometryModified: false))
    }
}
