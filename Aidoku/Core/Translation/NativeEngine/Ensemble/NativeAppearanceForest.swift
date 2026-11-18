import Foundation

/// Portable selected sklearn heads. No training examples, page keys or Python.
struct NativeAppearanceForest: Decodable, Sendable {
    struct Node: Decodable, Sendable {
        let feature: Int
        let threshold: Double
        let left: Int
        let right: Int
        let missingLeft: Bool
        let leaf: Bool
        let values: [Double]
    }
    let kind: String
    let features: Int
    let classes: [Double]
    let baseline: [Double]
    let trees: [[Node]]
    let outputs: [Int]
    let float32Input: Bool
    private struct RootForestDecodingCache {
        let values: [NativeAppearanceForest]
    }
    private static let rootForestCacheKey = CodingUserInfoKey(rawValue: "aidoku.root-forest-typed-decode-v1")!
    private enum CodingKeys: String, CodingKey { case kind, features, classes, baseline, trees, outputs, float32Input }

    // Preserve the original memberwise construction used by predictTrees.
    init(
        kind: String, features: Int, classes: [Double], baseline: [Double],
        trees: [[Node]], outputs: [Int], float32Input: Bool
    ) {
        self.kind = kind
        self.features = features
        self.classes = classes
        self.baseline = baseline
        self.trees = trees
        self.outputs = outputs
        self.float32Input = float32Input
    }
    init(from decoder: Decoder) throws {
        if decoder.codingPath.count == 2, decoder.codingPath[0].stringValue == "forests",
            let index = decoder.codingPath[1].intValue,
            let cache = decoder.userInfo[Self.rootForestCacheKey] as? RootForestDecodingCache,
            cache.values.indices.contains(index)
        {
            self = cache.values[index]
            return
        }
        // Exactly the original synthesized field decoding for JSON, nested
        // forests, unsupported plist structures and every cache miss.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        features = try c.decode(Int.self, forKey: .features)
        classes = try c.decode([Double].self, forKey: .classes)
        baseline = try c.decode([Double].self, forKey: .baseline)
        trees = try c.decode([[Node]].self, forKey: .trees)
        outputs = try c.decode([Int].self, forKey: .outputs)
        float32Input = try c.decode(Bool.self, forKey: .float32Input)
    }

    /// Same original bytes feed both parsers: no JSON/plist reserialization.
    /// The typed forest cache is local to this decoder, never URL/global state.
    static func decodePreparedRoot<Model: Decodable>(_ type: Model.Type, from data: Data) throws -> Model? {
        guard data.starts(with: Data("bplist".utf8)), data.count <= 128 * 1_048_576 else { return nil }
        func build() throws -> Model? {
            let forests: [NativeAppearanceForest]? = data.withUnsafeBytes { bytes in
                guard var reader = BinaryForestReader(bytes) else { return nil }
                return reader.forests()
            }
            guard let forests else { return nil }
            let decoder = PropertyListDecoder()
            decoder.userInfo[rootForestCacheKey] = RootForestDecodingCache(values: forests)
            // Original Decodable still reads every non-forest field and nested
            // component from ORIGINAL data. Caller retains all old validation.
            return try decoder.decode(type, from: data)
        }
        #if canImport(ObjectiveC)
            return try autoreleasepool { try build() }
        #else
            return try build()
        #endif
    }
    /// Conservative bplist00 forest reader. Borrows ORIGINAL bytes only within
    /// withUnsafeBytes; no Foundation object graph or pointer escapes. Every
    /// unsupported type/layout/budget returns nil to the original decoder.
    private struct BinaryForestReader {
        let bytes: UnsafeRawBufferPointer
        let offsetSize: Int, refSize: Int, objects: Int, top: Int, table: Int
        var names = [Int: String]()
        var totalNodes = 0, totalValues = 0, totalOutputs = 0
        init?(_ bytes: UnsafeRawBufferPointer) {
            guard bytes.count >= 40, bytes.prefix(8).elementsEqual("bplist00".utf8) else { return nil }
            func u(_ at: Int, _ n: Int) -> UInt64? {
                guard n > 0, n <= 8, at >= 0, at <= bytes.count - n else { return nil }
                var value: UInt64 = 0
                for i in 0..<n { value = (value << 8) | UInt64(bytes[at + i]) }
                return value
            }
            let trailer = bytes.count - 32, os = Int(bytes[trailer + 6]), rs = Int(bytes[trailer + 7])
            guard (1...8).contains(os), (1...8).contains(rs),
                let nc = u(trailer + 8, 8), let n = Int(exactly: nc), n > 0, n <= bytes.count,
                let tc = u(trailer + 16, 8), let top = Int(exactly: tc), top < n,
                let oc = u(trailer + 24, 8), let table = Int(exactly: oc), table >= 8, table < trailer,
                n <= (trailer - table) / os
            else { return nil }
            // Monotone unique offsets are a conservative eligibility rule;
            // valid differently ordered object tables retain old decoding.
            var prior = 7
            for i in 0..<n {
                guard let raw = u(table + i * os, os), let off = Int(exactly: raw), off > prior, off < table else {
                    return nil
                }
                prior = off
            }
            self.bytes = bytes
            offsetSize = os
            refSize = rs
            objects = n
            self.top = top
            self.table = table
        }
        func u(_ at: Int, _ n: Int) -> UInt64? {
            guard n > 0, n <= 8, at >= 0, at <= bytes.count - n else { return nil }
            switch n {
            case 1: return UInt64(bytes[at])
            case 2: return UInt64(UInt16(bigEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
            case 4: return UInt64(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
            case 8: return UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt64.self))
            default:
                var value: UInt64 = 0
                for i in 0..<n { value = (value << 8) | UInt64(bytes[at + i]) }
                return value
            }
        }
        func span(_ id: Int) -> (start: Int, end: Int)? {
            guard id >= 0, id < objects, let raw = u(table + id * offsetSize, offsetSize), let start = Int(exactly: raw)
            else { return nil }
            let end: Int
            if id + 1 == objects {
                end = table
            } else {
                guard let raw = u(table + (id + 1) * offsetSize, offsetSize), let next = Int(exactly: raw) else {
                    return nil
                }
                end = next
            }
            guard start >= 8, start < end, end <= table else { return nil }
            return (start, end)
        }
        func ref(_ at: Int) -> Int? {
            guard let raw = u(at, refSize), let id = Int(exactly: raw), id < objects else { return nil }
            return id
        }
        func info(_ id: Int, _ tag: UInt8, _ limit: Int) -> (payload: Int, count: Int, end: Int)? {
            guard let s = span(id), bytes[s.start] >> 4 == tag else { return nil }
            let short = Int(bytes[s.start] & 15), count: Int, payload: Int
            if short < 15 {
                count = short
                payload = s.start + 1
            } else {
                guard s.start + 1 < s.end, bytes[s.start + 1] >> 4 == 1, bytes[s.start + 1] & 15 <= 3 else {
                    return nil
                }
                let size = 1 << Int(bytes[s.start + 1] & 15)
                guard s.start + 2 <= s.end - size, let raw = u(s.start + 2, size), let n = Int(exactly: raw) else {
                    return nil
                }
                count = n
                payload = s.start + 2 + size
            }
            guard count <= limit else { return nil }
            let scale = tag == 13 ? 2 * refSize : tag == 10 ? refSize : 1
            guard count <= (s.end - payload) / scale else { return nil }
            return (payload, count, s.end)
        }
        mutating func name(_ id: Int) -> String? {
            if let hit = names[id] { return hit }
            guard names.count < 256, let s = info(id, 5, 256),
                bytes[s.payload..<(s.payload + s.count)].allSatisfy({ $0 < 128 })
            else { return nil }
            let value = String(decoding: bytes[s.payload..<(s.payload + s.count)], as: UTF8.self)
            names[id] = value
            return value
        }
        mutating func dictionary(_ id: Int) -> [String: Int]? {
            guard let s = info(id, 13, 1024) else { return nil }
            var out = [String: Int]()
            for i in 0..<s.count {
                guard let k = ref(s.payload + i * refSize), let key = name(k), out[key] == nil,
                    let value = ref(s.payload + (s.count + i) * refSize)
                else { return nil }
                out[key] = value
            }
            return out
        }
        func integer(_ id: Int) -> Int? {
            guard let s = span(id), bytes[s.start] >> 4 == 1, bytes[s.start] & 15 <= 3 else { return nil }
            let n = 1 << Int(bytes[s.start] & 15)
            guard s.start + 1 <= s.end - n, let value = u(s.start + 1, n) else { return nil }
            return n == 8 ? Int(exactly: Int64(bitPattern: value)) : Int(exactly: value)
        }
        func boolean(_ id: Int) -> Bool? {
            guard let s = span(id) else { return nil }
            if bytes[s.start] == 8 { return false }
            if bytes[s.start] == 9 { return true }
            return nil
        }
        func double(_ id: Int) -> Double? {
            guard let s = span(id) else { return nil }
            let tag = bytes[s.start] >> 4, exp = Int(bytes[s.start] & 15)
            let value: Double
            if tag == 1, exp <= 3 {
                let n = 1 << exp
                guard s.start + 1 <= s.end - n, let raw = u(s.start + 1, n) else { return nil }
                value = n == 8 ? Double(Int64(bitPattern: raw)) : Double(raw)
            } else if tag == 2, (exp == 2 || exp == 3) {
                let n = 1 << exp
                guard s.start + 1 <= s.end - n, let raw = u(s.start + 1, n) else { return nil }
                value = n == 4 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw)
            } else {
                return nil
            }
            return value.isFinite ? value : nil
        }
        mutating func doubles(_ id: Int) -> [Double]? {
            guard let s = info(id, 10, 65536), totalValues <= 32_000_000 - s.count else { return nil }
            totalValues += s.count
            var out = [Double]()
            out.reserveCapacity(s.count)
            for i in 0..<s.count {
                guard let id = ref(s.payload + i * refSize), let x = double(id) else { return nil }
                out.append(x)
            }
            return out
        }
        mutating func integers(_ id: Int) -> [Int]? {
            guard let s = info(id, 10, 4096), totalOutputs <= 65_536 - s.count else { return nil }
            totalOutputs += s.count
            var out = [Int]()
            out.reserveCapacity(s.count)
            for i in 0..<s.count {
                guard let id = ref(s.payload + i * refSize), let x = integer(id) else { return nil }
                out.append(x)
            }
            return out
        }
        mutating func node(_ id: Int) -> Node? {
            guard let s = info(id, 13, 1024) else { return nil }
            var feature: Int?, threshold: Double?, left: Int?, right: Int?, missing: Bool?, leaf: Bool?,
                values: [Double]?
            var seen: UInt8 = 0
            for i in 0..<s.count {
                guard let k = ref(s.payload + i * refSize), let key = name(k),
                    let value = ref(s.payload + (s.count + i) * refSize)
                else { return nil }
                let bit: UInt8
                switch key {
                case "feature": bit = 1
                case "threshold": bit = 2
                case "left": bit = 4
                case "right": bit = 8
                case "missingLeft": bit = 16
                case "leaf": bit = 32
                case "values": bit = 64
                default: continue
                }
                guard seen & bit == 0 else { return nil }
                seen |= bit
                switch bit {
                case 1: feature = integer(value)
                case 2: threshold = double(value)
                case 4: left = integer(value)
                case 8: right = integer(value)
                case 16: missing = boolean(value)
                case 32: leaf = boolean(value)
                default: values = doubles(value)
                }
            }
            guard seen == 127, let feature, let threshold, let left, let right, let missing, let leaf, let values else {
                return nil
            }
            return Node(
                feature: feature, threshold: threshold, left: left, right: right, missingLeft: missing, leaf: leaf,
                values: values)
        }
        mutating func forest(_ id: Int) -> NativeAppearanceForest? {
            guard let row = dictionary(id), let k = row["kind"], let kind = name(k), let f = row["features"],
                let features = integer(f),
                let c = row["classes"], let classes = doubles(c), let b = row["baseline"], let baseline = doubles(b),
                let o = row["outputs"], let outputs = integers(o), let z = row["float32Input"],
                let float32 = boolean(z),
                let t = row["trees"], let ts = info(t, 10, 4096), ts.count > 0
            else { return nil }
            var trees = [[Node]]()
            trees.reserveCapacity(ts.count)
            for i in 0..<ts.count {
                guard let id = ref(ts.payload + i * refSize), let ns = info(id, 10, 1_000_000), ns.count > 0,
                    totalNodes <= 2_000_000 - ns.count
                else { return nil }
                totalNodes += ns.count
                var nodes = [Node]()
                nodes.reserveCapacity(ns.count)
                for j in 0..<ns.count {
                    guard let id = ref(ns.payload + j * refSize), let value = node(id) else { return nil }
                    nodes.append(value)
                }
                trees.append(nodes)
            }
            return NativeAppearanceForest(
                kind: kind, features: features, classes: classes, baseline: baseline, trees: trees, outputs: outputs,
                float32Input: float32)
        }
        mutating func forests() -> [NativeAppearanceForest]? {
            guard let root = dictionary(top), let k = root["kind"], name(k) == "forest", let f = root["forests"],
                let fs = info(f, 10, 4096), fs.count > 0
            else { return nil }
            var out = [NativeAppearanceForest]()
            for i in 0..<fs.count {
                guard let id = ref(fs.payload + i * refSize), let value = forest(id) else { return nil }
                out.append(value)
            }
            return out
        }
    }


    enum Failure: Error { case invalidModel, invalidFeatures }

    func predict(_ input: [Double]) throws -> [Double] {
        guard features > 0, features <= 4096, input.count == features,
              input.allSatisfy({ $0.isFinite || $0.isNaN }) else { throw Failure.invalidFeatures }
        guard !trees.isEmpty, trees.count <= 4096, outputs.count == trees.count,
              ["forest-probability", "forest-regression", "histogram-logit", "histogram-regression"].contains(kind)
        else { throw Failure.invalidModel }
        let histogram = kind.hasPrefix("histogram")
        var result = histogram ? baseline : [Double](repeating: 0, count: trees[0].first?.values.count ?? 0)
        guard !result.isEmpty, result.count <= 32, result.allSatisfy(\.isFinite) else { throw Failure.invalidModel }
        for (treeIndex, nodes) in trees.enumerated() {
            guard !nodes.isEmpty, nodes.count <= 1_000_000 else { throw Failure.invalidModel }
            var index = 0, steps = 0
            while true {
                guard nodes.indices.contains(index), steps < nodes.count else { throw Failure.invalidModel }
                steps += 1
                let node = nodes[index]
                if node.leaf {
                    guard node.values.allSatisfy(\.isFinite) else { throw Failure.invalidModel }
                    if histogram {
                        guard node.values.count == 1, result.indices.contains(outputs[treeIndex]) else { throw Failure.invalidModel }
                        result[outputs[treeIndex]] += node.values[0]
                    } else {
                        guard node.values.count == result.count else { throw Failure.invalidModel }
                        for i in result.indices { result[i] += node.values[i] / Double(trees.count) }
                    }
                    break
                }
                guard input.indices.contains(node.feature), node.threshold.isFinite else { throw Failure.invalidModel }
                let value = float32Input ? Double(Float(input[node.feature])) : input[node.feature]
                index = value.isNaN ? (node.missingLeft ? node.left : node.right) :
                    (value <= node.threshold ? node.left : node.right)
            }
        }
        if kind == "histogram-logit" {
            if result.count == 1 {
                let x = result[0]
                let probability = x >= 0 ? 1 / (1 + exp(-x)) : exp(x) / (1 + exp(x))
                return [1 - probability, probability]
            }
            let maximum = result.max()!
            let values = result.map { exp($0 - maximum) }, total = values.reduce(0, +)
            return values.map { $0 / total }
        }
        return result
    }

    struct Bundle: Decodable, Sendable {
        let schema: Int
        let sourceOnly: Bool
        let GTAtInference: Bool
        let heads: [String: NativeAppearanceForest]
        let sourceArtifacts: [String: String]
    }
}
