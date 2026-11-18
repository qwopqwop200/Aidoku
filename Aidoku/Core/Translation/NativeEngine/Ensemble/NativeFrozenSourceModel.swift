import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Frozen numeric operators shared by macOS and iOS. No Python or platform backend.
/// Inputs are estimator-space features; graph-owned normalization/link policies are
/// preserved in metadata and must be applied by the graph, exactly once.
struct NativeFrozenSourceModel: Decodable, Sendable {
    enum Failure: Error { case invalidModel, invalidFeatures, notClassifier, notForest, unknownHead(String) }
    enum Value: Decodable, Sendable {
        case number(Double), string(String), bool(Bool), array([Value]), object([String: Value]), null
        var foundationValue: Any {
            switch self {
            case .number(let value): return value
            case .string(let value): return value
            case .bool(let value): return value
            case .array(let values): return values.map { $0.foundationValue }
            case .object(let values): return values.mapValues { $0.foundationValue }
            case .null: return NSNull()
            }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([Value].self) { self = .array(v) }
            else { self = .object(try c.decode([String: Value].self)) }
        }
    }
    var metadataFoundation: [String: Any] { metadata.mapValues { $0.foundationValue } }

    struct SymmetricTree: Decodable, Sendable {
        let features: [Int]
        let borders: [Double]
        let nanRight: [Bool]
        let leaves: [[Double]]
    }
    struct NumericNode: Decodable, Sendable {
        let feature: Int
        let threshold: Double
        let left: Int
        let right: Int
        let missingLeft: Bool
        let missingZero: Bool
        let missingNaN: Bool
        let value: Double?
    }
    let schema: Int
    let kind: String
    let featureCount: Int
    let classes: [Double]
    let classGroups: [[Double]]
    let metadata: [String: Value]
    let components: [NativeFrozenSourceModel]
    let weights: [Double]
    let infiniteThresholds: Bool?
    let forests: [NativeAppearanceForest]
    let symmetricTrees: [SymmetricTree]
    let numericTrees: [[NumericNode]]
    let treeOutputs: [Int]
    let coefficients: [[Double]]
    let intercept: [Double]
    let mean: [Double]
    let scale: Double
    let bias: [Double]
    let link: String

    init(data: Data) throws {
        if data.starts(with: Data("bplist".utf8)) {
            if let prepared = try NativeAppearanceForest.decodePreparedRoot(Self.self, from: data) {
                self = prepared
            } else {
                self = try PropertyListDecoder().decode(Self.self, from: data)
            }
        } else {
            self = try JSONDecoder().decode(Self.self, from: data)
        }
        guard schema == 1, featureCount > 0, featureCount <= 100_000,
              ["forest", "catboost", "lightgbm", "linear", "pca", "scaler", "blend"].contains(kind),
              ["identity", "sigmoid", "softmax", "exp"].contains(link), scale.isFinite,
              classes.allSatisfy(\.isFinite), bias.allSatisfy(\.isFinite), intercept.allSatisfy(\.isFinite)
        else { throw Failure.invalidModel }
    }

    private func check(_ vector: [Double]) throws {
        guard vector.count == featureCount, vector.allSatisfy({ $0.isFinite || $0.isNaN }) else {
            throw Failure.invalidFeatures
        }
    }

    private func linked(_ raw: [Double]) throws -> [Double] {
        guard !raw.isEmpty, raw.allSatisfy(\.isFinite) else { throw Failure.invalidModel }
        switch link {
        case "sigmoid":
            guard raw.count == 1 else { throw Failure.invalidModel }
            let x = raw[0], p = x >= 0 ? 1 / (1 + exp(-x)) : exp(x) / (1 + exp(x))
            return [1 - p, p]
        case "softmax":
            let maximum = raw.max()!, values = raw.map { exp($0 - maximum) }
            let total = values.reduce(0, +)
            return values.map { $0 / total }
        case "exp": return raw.map { exp($0) }
        default: return raw
        }
    }

    // The reused primitive requires finite thresholds. sklearn missing-only
    // splits can legitimately carry infinity, so only those incompatible heads
    // use this exact IEEE comparison traversal (parameters remain untouched).
    private func predictForest(_ forest: NativeAppearanceForest, _ vector: [Double]) throws -> [Double] {
        guard infiniteThresholds == true else { return try forest.predict(vector) }
        let histogram = forest.kind.hasPrefix("histogram")
        var result = histogram ? forest.baseline : [Double](repeating: 0, count: forest.trees.first?.first?.values.count ?? 0)
        guard !result.isEmpty, forest.outputs.count == forest.trees.count else { throw Failure.invalidModel }
        for (t, nodes) in forest.trees.enumerated() {
            var index = 0, steps = 0
            while true {
                guard nodes.indices.contains(index), steps < nodes.count else { throw Failure.invalidModel }
                steps += 1
                let node = nodes[index]
                if node.leaf {
                    guard node.values.allSatisfy(\.isFinite) else { throw Failure.invalidModel }
                    if histogram {
                        guard node.values.count == 1, result.indices.contains(forest.outputs[t]) else { throw Failure.invalidModel }
                        result[forest.outputs[t]] += node.values[0]
                    } else {
                        guard node.values.count == result.count else { throw Failure.invalidModel }
                        for i in result.indices { result[i] += node.values[i] / Double(forest.trees.count) }
                    }
                    break
                }
                guard vector.indices.contains(node.feature), !node.threshold.isNaN else { throw Failure.invalidModel }
                let value = forest.float32Input ? Double(Float(vector[node.feature])) : vector[node.feature]
                index = value.isNaN ? (node.missingLeft ? node.left : node.right)
                    : (value <= node.threshold ? node.left : node.right)
            }
        }
        return result
    }

    private func evaluate(_ vector: [Double]) throws -> [Double] {
        try check(vector)
        switch kind {
        case "blend":
            guard !components.isEmpty, components.count == weights.count,
                  weights.allSatisfy(\.isFinite), abs(weights.reduce(0, +) - 1) < 1e-12 else {
                throw Failure.invalidModel
            }
            var result: [Double] = []
            for (i, model) in components.enumerated() {
                let values = try model.predictProbability(vector)
                if result.isEmpty { result = [Double](repeating: 0, count: values.count) }
                guard values.count == result.count else { throw Failure.invalidModel }
                for j in result.indices { result[j] += weights[i] * values[j] }
            }
            return result
        case "forest":
            guard !forests.isEmpty else { throw Failure.invalidModel }
            return try linked(forests.flatMap { try predictForest($0, vector) })
        case "linear", "pca":
            guard !coefficients.isEmpty, intercept.count == coefficients.count,
                  mean.isEmpty || mean.count == vector.count else { throw Failure.invalidModel }
            return try coefficients.enumerated().map { row, weights in
                guard weights.count == vector.count, weights.allSatisfy(\.isFinite) else { throw Failure.invalidModel }
                var value = intercept[row]
                for i in vector.indices { value += weights[i] * (vector[i] - (mean.isEmpty ? 0 : mean[i])) }
                return value
            }
        case "scaler":
            guard mean.count == vector.count, coefficients.count == 1,
                  coefficients[0].count == vector.count else { throw Failure.invalidModel }
            return vector.indices.map { (vector[$0] - mean[$0]) / coefficients[0][$0] }
        case "catboost":
            guard !bias.isEmpty, !symmetricTrees.isEmpty else { throw Failure.invalidModel }
            var result = [Double](repeating: 0, count: bias.count)
            for tree in symmetricTrees {
                guard tree.features.count < 24, tree.features.count == tree.borders.count,
                      tree.nanRight.count == tree.features.count,
                      tree.leaves.count == 1 << tree.features.count else { throw Failure.invalidModel }
                var leaf = 0
                for i in tree.features.indices {
                    guard vector.indices.contains(tree.features[i]) else { throw Failure.invalidModel }
                    // CatBoost quantizes numerical input to float32 before comparing borders.
                    let value = Double(Float(vector[tree.features[i]]))
                    if value.isNaN ? tree.nanRight[i] : value > tree.borders[i] { leaf |= 1 << i }
                }
                guard tree.leaves[leaf].count == result.count else { throw Failure.invalidModel }
                for i in result.indices { result[i] += tree.leaves[leaf][i] }
            }
            return try linked(result.indices.map { result[$0] * scale + bias[$0] })
        case "lightgbm":
            guard !bias.isEmpty, !numericTrees.isEmpty, treeOutputs.count == numericTrees.count else {
                throw Failure.invalidModel
            }
            var result = bias
            for (t, nodes) in numericTrees.enumerated() {
                guard result.indices.contains(treeOutputs[t]) else { throw Failure.invalidModel }
                var index = 0, steps = 0
                while true {
                    guard nodes.indices.contains(index), steps < nodes.count else { throw Failure.invalidModel }
                    steps += 1
                    let node = nodes[index]
                    if let value = node.value { result[treeOutputs[t]] += value; break }
                    guard vector.indices.contains(node.feature) else { throw Failure.invalidModel }
                    var value = vector[node.feature]
                    if (node.missingNaN && value.isNaN) ||
                        (node.missingZero && (value.isNaN || abs(value) <= 1e-35)) {
                        index = node.missingLeft ? node.left : node.right
                    } else {
                        if value.isNaN { value = 0 }
                        index = value <= node.threshold ? node.left : node.right
                    }
                }
            }
            return try linked(result.map { $0 * scale })
        default: throw Failure.invalidModel
        }
    }

    /// Estimator semantics: labels for classifiers; one or more numerical outputs otherwise.
    func predict(_ vector: [Double]) throws -> [Double] {
        let values = try evaluate(vector)
        guard !classGroups.isEmpty else { return values }
        var offset = 0
        return try classGroups.map { labels in
            guard !labels.isEmpty, offset + labels.count <= values.count else { throw Failure.invalidModel }
            let start = offset
            offset += labels.count
            var best = 0
            for i in 1..<labels.count where values[start + i] > values[start + best] { best = i }
            return labels[best]
        }
    }

    /// Multioutput probabilities concatenate groups in classGroups order.
    func predictProbability(_ vector: [Double]) throws -> [Double] {
        guard !classGroups.isEmpty else { throw Failure.notClassifier }
        return try evaluate(vector)
    }
    func predict(_ matrix: [[Double]]) throws -> [[Double]] { try matrix.map { try predict($0) } }
    func predictProbability(_ matrix: [[Double]]) throws -> [[Double]] {
        try matrix.map { try predictProbability($0) }
    }

    /// Selected row-major Float32 features, useful for pixel classifiers.
    /// Positions address input rows; nil retains every row in source order.
    func positiveProbabilities(_ values: [Float], rowCount: Int, positions: [Int]? = nil) throws -> [Double] {
        guard classGroups.count == 1, classGroups[0].count == 2,
              rowCount >= 0, rowCount <= Int.max / featureCount,
              values.count == rowCount * featureCount else { throw Failure.invalidFeatures }
        if let prepared = preparedPositiveProbabilities() {
            return try prepared(values, rowCount, positions)
        }
        return try (positions ?? Array(0..<rowCount)).map { row in
            guard row >= 0, row < rowCount else { throw Failure.invalidFeatures }
            let offset = row * featureCount
            return try predictProbability(values[offset..<(offset + featureCount)].map(Double.init))[1]
        }
    }

    /// Per-estimator outputs for graph-owned forest quantiles (tree-major, output-minor).
    func predictTrees(_ vector: [Double]) throws -> [[Double]] {
        try check(vector)
        guard kind == "forest", forests.allSatisfy({ $0.kind.hasPrefix("forest-") }),
              let first = forests.first else { throw Failure.notForest }
        return try first.trees.indices.map { t in
            try forests.flatMap { forest in
                guard forest.trees.count == first.trees.count else { throw Failure.invalidModel }
                let single = NativeAppearanceForest(kind: forest.kind, features: forest.features,
                    classes: forest.classes, baseline: [], trees: [forest.trees[t]], outputs: [0],
                    float32Input: forest.float32Input)
                return try predictForest(single, vector)
            }
        }
    }

    struct Registry: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            let asset: String
            let sha256: String
            let kind: String
            let featureCount: Int
        }
        let schema: Int
        let sourceOnly: Bool
        let GTAtInference: Bool
        let heads: [String: Entry]
        let metadata: [String: Value]?
        let sourceArtifacts: [String: String]?
        let provenanceStatus: String?
        let metadataAsset: String?
        let metadataSHA256: String?
        var metadataTreeFoundation: [String: Any] {
            get throws {
                if let tree = metadata?["tree"]?.foundationValue as? [String: Any] { return tree }
                guard let directory, let asset = metadataAsset, let expected = metadataSHA256,
                      !asset.contains(".."), !asset.hasPrefix("/") else { throw Failure.invalidModel }
                let data = try Data(contentsOf: directory.appendingPathComponent(asset))
                guard NativeFrozenSourceSHA256.hex(data) == expected else { throw Failure.invalidModel }
                let full = try JSONDecoder().decode(Self.self, from: data)
                guard full.schema == schema, full.sourceOnly, !full.GTAtInference,
                      full.sourceArtifacts == sourceArtifacts,
                      let tree = full.metadata?["tree"]?.foundationValue as? [String: Any] else { throw Failure.invalidModel }
                return tree
            }
        }
        private var directory: URL?
        private enum CodingKeys: String, CodingKey { case schema, sourceOnly, GTAtInference, heads, metadata, sourceArtifacts, provenanceStatus, metadataAsset, metadataSHA256 }
        init(directory: URL, includeMetadata: Bool = false) throws {
            let index = directory.appendingPathComponent("registry-index.json")
            let path = FileManager.default.fileExists(atPath: index.path)
                ? index : directory.appendingPathComponent("registry.json")
            var document = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
            guard document.schema == 1, document.sourceOnly, !document.GTAtInference else { throw Failure.invalidModel }
            if includeMetadata, let asset = document.metadataAsset, let expected = document.metadataSHA256 {
                guard !asset.contains(".."), !asset.hasPrefix("/") else { throw Failure.invalidModel }
                let data = try Data(contentsOf: directory.appendingPathComponent(asset))
                guard NativeFrozenSourceSHA256.hex(data) == expected else { throw Failure.invalidModel }
                let full = try JSONDecoder().decode(Self.self, from: data)
                guard full.schema == document.schema, full.sourceOnly, !full.GTAtInference,
                      full.sourceArtifacts == document.sourceArtifacts, full.metadata?["tree"] != nil else {
                    throw Failure.invalidModel
                }
                document = full
            }
            self = document
            self.directory = directory
        }
        func model(_ id: String) throws -> NativeFrozenSourceModel {
            guard let entry = heads[id], let directory else { throw Failure.unknownHead(id) }
            guard !entry.asset.contains(".."), !entry.asset.hasPrefix("/") else { throw Failure.invalidModel }
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.asset))
            guard NativeFrozenSourceSHA256.hex(data) == entry.sha256 else { throw Failure.invalidModel }
            let model = try NativeFrozenSourceModel(data: data)
            guard model.featureCount == entry.featureCount, model.kind == entry.kind else { throw Failure.invalidModel }
            return model
        }
    }
}

/// Standard SHA-256: accelerated when available, portable fallback otherwise.
enum NativeFrozenSourceSHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
    private static func rotate(_ x: UInt32, _ bits: UInt32) -> UInt32 { (x >> bits) | (x << (32 - bits)) }
    static func hex(_ data: Data) -> String {
#if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
        let count = data.count
        let bitCount = UInt64(count) * 8
        let paddedCount = ((count + 9 + 63) / 64) * 64
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var words = [UInt32](repeating: 0, count: 64)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        // Virtual padding avoids copying entire mapped tensor files for hashing.
        func byte(_ index: Int) -> UInt32 {
            if index < count { return UInt32(bytes[index]) }
            if index == count { return 0x80 }
            if index >= paddedCount - 8 {
                return UInt32(UInt8(truncatingIfNeeded: bitCount >> ((paddedCount - 1 - index) * 8)))
            }
            return 0
        }
        for block in stride(from: 0, to: paddedCount, by: 64) {
            for i in 0..<16 {
                let j = block + i * 4
                words[i] = byte(j) << 24 | byte(j + 1) << 16 | byte(j + 2) << 8 | byte(j + 3)
            }
            for i in 16..<64 {
                let x = words[i - 15], y = words[i - 2]
                let s0 = rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)
                let s1 = rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10)
                words[i] = words[i - 16] &+ s0 &+ words[i - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ choice &+ constants[i] &+ words[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ s0 &+ majority
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
        }
        return state.map { String(format: "%08x", $0) }.joined()
#endif
    }
}

extension NativeFrozenSourceModel {
    typealias PreparedPositiveBatch = @Sendable ([Float], Int, [Int]?) throws -> [Double]
    /// An execution cache over unchanged immutable parameters, never a new head.
    /// Unsupported structures keep the existing generic evaluator unchanged.
    private struct BinaryPositiveBatchKernel: Sendable {
        let featureCount: Int
        private let forest: NativeAppearanceForest

        fileprivate init?(model: NativeFrozenSourceModel) {
            guard model.schema == 1, model.kind == "forest", model.link == "sigmoid",
                  model.classGroups.count == 1, model.classGroups[0].count == 2,
                  model.infiniteThresholds != true, model.forests.count == 1,
                  model.featureCount > 0, model.featureCount <= 4096 else { return nil }
            let forest = model.forests[0]
            guard forest.kind == "histogram-regression", forest.features == model.featureCount,
                  forest.baseline.count == 1, forest.baseline[0].isFinite,
                  !forest.trees.isEmpty, forest.trees.count <= 4096,
                  forest.outputs.count == forest.trees.count,
                  forest.outputs.allSatisfy({ $0 == 0 }) else { return nil }
            // Strictly forward child edges prove bounded termination and prevent
            // cycles. Valid but differently ordered trees use the generic path.
            for nodes in forest.trees {
                guard !nodes.isEmpty, nodes.count <= 1_000_000 else { return nil }
                for (index, node) in nodes.enumerated() {
                    if node.leaf {
                        guard node.values.count == 1, node.values[0].isFinite else { return nil }
                    } else {
                        guard (0..<model.featureCount).contains(node.feature), node.threshold.isFinite,
                              node.left > index, node.right > index,
                              node.left < nodes.count, node.right < nodes.count else { return nil }
                    }
                }
            }
            featureCount = model.featureCount
            self.forest = forest
        }

        func evaluate(_ values: [Float], rowCount: Int, positions: [Int]?) throws -> [Double] {
            guard rowCount >= 0, rowCount <= Int.max / featureCount,
                  values.count == rowCount * featureCount else { throw Failure.invalidFeatures }
            let outputCount = positions?.count ?? rowCount
            var output = [Double](); output.reserveCapacity(outputCount)
            // The existing selected-pixel adapter already reuses one vector.
            // Keep that conversion/order and fuse input validation into it,
            // rather than rescanning the full vector in two generic evaluators.
            var vector = [Double](repeating: 0, count: featureCount)
            for ordinal in 0..<outputCount {
                let row = positions?[ordinal] ?? ordinal
                guard row >= 0, row < rowCount else { throw Failure.invalidFeatures }
                let offset = row * featureCount
                for column in 0..<featureCount {
                    let value = Double(values[offset + column])
                    guard value.isFinite || value.isNaN else { throw Failure.invalidFeatures }
                    vector[column] = value
                }
                var raw = forest.baseline[0]
                for nodes in forest.trees {
                    var index = 0
                    while !nodes[index].leaf {
                        let node = nodes[index]
                        let value = forest.float32Input ? Double(Float(vector[node.feature])) : vector[node.feature]
                        index = value.isNaN ? (node.missingLeft ? node.left : node.right)
                            : (value <= node.threshold ? node.left : node.right)
                    }
                    // Preserve original tree order and Double addition. No
                    // reassociation, float accumulation, vectorization or FMA.
                    raw += nodes[index].values[0]
                }
                guard raw.isFinite else { throw Failure.invalidModel }
                // Exact original linked(.sigmoid) positive lane; avoid only
                // temporary raw/flatMap/[1-p,p] arrays, not its arithmetic.
                let probability = raw >= 0 ? 1 / (1 + exp(-raw)) : exp(raw) / (1 + exp(raw))
                output.append(probability)
            }
            return output
        }
    }

    /// Preparation is optional and validates immutable structure once. The
    /// selected-pixel adapter caches this same generic batch seam at init.
    func preparedPositiveProbabilities() -> PreparedPositiveBatch? {
        guard let kernel = BinaryPositiveBatchKernel(model: self) else { return nil }
        return { values, rowCount, positions in
            try kernel.evaluate(values, rowCount: rowCount, positions: positions)
        }
    }
}
