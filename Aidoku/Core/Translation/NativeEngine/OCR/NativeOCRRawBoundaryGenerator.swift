import Foundation
import CoreFoundation
import CryptoKit

/// Pure source-only numeric inference. No model discovery, cache, OCR, pixels,
/// identifiers, row tables, GT, uncertainty gating or candidate selection.
enum NativeOCRRawBoundaryGenerator {
    static let schema = "raw-source-rf-det-pixel-canonical-v1"
    static let geometryABI = "raw-corner8-orthonormal-projected-spans-clamp32-logical-frame015-v1"
    static let pixelDecoderABI = "native-cgimage-opaque-srgb-white-rgba8-v2"
    static let featureCount = 422
    enum Failure: Error { case invalidBundle(String) }
    struct Frame: Sendable { let width: Double; let height: Double }
    struct Model: Sendable {
        let featureNames: [String]
        private let heads: [Head]
        /// A single self-contained bundle. Strict key allowlists reject accidental
        /// label/row tables and training metadata. Caller binds expected names to
        /// its 126+181+missingFraction+113+missingFraction extraction order.
        init(data: Data, expectedFeatureNames: [String]) throws {
            guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
                  expectedFeatureNames.count == featureCount,
                  Set(expectedFeatureNames).count == featureCount,
                  expectedFeatureNames.allSatisfy({ !$0.isEmpty }) else {
                throw Failure.invalidBundle("size/feature contract/root")
            }
            // Only these previously validated byte streams have a fixed field order.
            // Replacement resources continue through the complete strict decoder.
            if Self.isFrozenGeometry(data) {
                self.heads = try data.withUnsafeBytes { buffer in
                    var reader = FrozenReader(bytes: buffer.bindMemory(to: UInt8.self))
                    return try reader.heads(expectedFeatureNames: expectedFeatureNames)
                }
                self.featureNames = expectedFeatureNames
                return
            }
            // Both decoders read immutable bytes. Overlap the independent first
            // passes, then check their results in the original validation order.
            let decoded = NumericDecodeResult()
            let numericWork = DispatchGroup()
            numericWork.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try JSONDecoder().decode(NumericBundle.self, from: data) }
                decoded.store(result)
                numericWork.leave()
            }
            let structure = Result { try JSONSerialization.jsonObject(with: data) }
            numericWork.wait()
            guard let root = try structure.get() as? [String: Any] else {
                throw Failure.invalidBundle("size/feature contract/root")
            }
            try exact(root, ["schema", "featureNames", "pixelDecoderABI", "geometryABI", "heads", "labelOrRowTablesIncluded"])
            guard root["schema"] as? String == schema,
                  root["pixelDecoderABI"] as? String == pixelDecoderABI,
                  root["geometryABI"] as? String == geometryABI,
                  let labelFlag = root["labelOrRowTablesIncluded"] as? NSNumber,
                  CFGetTypeID(labelFlag) == CFBooleanGetTypeID(), !labelFlag.boolValue,
                  let names = root["featureNames"] as? [String], names == expectedFeatureNames,
                  let rawHeads = root["heads"] as? [[String: Any]], rawHeads.count == 8 else {
                throw Failure.invalidBundle("header")
            }
            self.featureNames = names
            // JSONSerialization/NSNumber can round decimal tokens differently
            // from the training decoder. At an equality split, even one ULP
            // changes the selected leaf. Decode numeric tokens directly as
            // Double, retaining the independent strict-key validation below.
            guard let result = decoded.load() else { throw Failure.invalidBundle("numeric decoder") }
            let numeric = try result.get()
            guard numeric.heads.count == rawHeads.count else { throw Failure.invalidBundle("head count") }
            self.heads = try zip(rawHeads, numeric.heads).map { try Head($0.0, numeric: $0.1, names: names) }
        }
        private static func isFrozenGeometry(_ data: Data) -> Bool {
            let digest: String
            switch data.count {
            case 23_382_051: digest = "3e3282ed5a91c2be87de7de721609832b98ce2eb03ece2938c24dfe7f2e608ae"
            case 24_343_967: digest = "e81499f93b44dedbf5534b7a878b8088887ae78b3ec97719a981446494fbf152"
            case 11_460_539: digest = "ad1a00276b9f83301a3abf9428e974c8179caa6eeb8ea209623a151730a8495f"
            default: return false
            }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == digest
        }
        /// Features remain Double: base126 values are promoted from Float32;
        /// provider values must follow the exported Python join without re-rounding.
        func residual(features: [Double]) -> [Double]? {
            guard features.count == featureCount, features.allSatisfy(\.isFinite) else { return nil }
            var result = [Double](); result.reserveCapacity(8)
            for head in heads {
                var value = head.bias
                for tree in head.trees {
                    var index = 0
                    while tree[index].feature >= 0 {
                        let node = tree[index]
                        index = features[node.feature] <= node.threshold ? node.left : node.right
                    }
                    value += head.learningRate * tree[index].value
                }
                guard value.isFinite else { return nil }; result.append(value)
            }
            return result
        }
    }
    private struct Node: Sendable {
        // A split uses its threshold, a leaf its value. Both retain all 64 bits.
        // The schema permits 422 features and at most 65,535 nodes in a tree.
        private let number: Double
        private let storedFeature: Int16
        private let storedLeft: UInt16
        private let storedRight: UInt16

        var feature: Int { Int(storedFeature) }
        var left: Int { Int(storedLeft) }
        var right: Int { Int(storedRight) }
        var threshold: Double { storedFeature >= 0 ? number : 0 }
        var value: Double { storedFeature < 0 ? number : 0 }

        init(leaf value: Double) {
            number = value
            storedFeature = -1
            storedLeft = 0
            storedRight = 0
        }

        init(feature: Int, threshold: Double, left: Int, right: Int) {
            number = threshold
            storedFeature = Int16(feature)
            storedLeft = UInt16(left)
            storedRight = UInt16(right)
        }
    }
    private struct NumericBundle: Decodable { let heads: [NumericHead] }
    private struct FrozenReader {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        private var next: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func takeComma() -> Bool {
            guard next == UInt8(ascii: ",") else { return false }
            index += 1
            return true
        }

        mutating func consume(_ literal: StaticString) throws {
            let count = literal.utf8CodeUnitCount
            guard let base = bytes.baseAddress, count <= bytes.count - index,
                  memcmp(base + index, literal.utf8Start, count) == 0 else {
                throw Failure.invalidBundle("frozen field")
            }
            index += count
        }

        mutating func advance(to delimiter: UInt8) throws {
            while index < bytes.count, bytes[index] != delimiter { index += 1 }
            guard index < bytes.count else { throw Failure.invalidBundle("frozen delimiter") }
        }

        mutating func double(endingAt delimiter: UInt8) throws -> Double {
            let start = index
            try advance(to: delimiter)
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw Failure.invalidBundle("frozen number")
            }
            return value
        }

        mutating func integer() throws -> Int {
            var value = 0
            let start = index
            while let digit = next, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) {
                // The validated schema limits the largest tree to 65,535 nodes.
                guard index - start < 5 else { throw Failure.invalidBundle("frozen integer") }
                value = value * 10 + Int(digit - UInt8(ascii: "0"))
                index += 1
            }
            guard index > start else { throw Failure.invalidBundle("frozen integer") }
            return value
        }

        mutating func heads(expectedFeatureNames: [String]) throws -> [Head] {
            try consume(#"{"schema":"raw-source-rf-det-pixel-canonical-v1","featureNames":"#)
            let start = index
            try advance(to: UInt8(ascii: "]"))
            let names = try JSONDecoder().decode([String].self, from: Data(bytes[start...index]))
            guard names == expectedFeatureNames else { throw Failure.invalidBundle("header") }
            try advance(to: UInt8(ascii: "{"))
            var heads = [Head]()
            repeat {
                try consume(#"{"schema":"numeric-hist-gradient-boost-v1","bias":"#)
                let bias = try double(endingAt: UInt8(ascii: ","))
                try consume(#","learningRate":"#)
                let learningRate = try double(endingAt: UInt8(ascii: ","))
                try advance(to: UInt8(ascii: "]"))
                try consume(#"],"trees":["#)
                var trees = [[Node]]()
                repeat {
                    try consume("[")
                    var nodes = [Node]()
                    repeat { nodes.append(try node()) } while takeComma()
                    try consume("]")
                    trees.append(nodes)
                } while takeComma()
                try consume("]}")
                heads.append(Head(bias: bias, learningRate: learningRate, trees: trees))
            } while takeComma()
            try consume(#"],"labelOrRowTablesIncluded":false}"#)
            return heads
        }

        mutating func node() throws -> Node {
            try consume(#"{"feature":"#)
            let node: Node
            if next == UInt8(ascii: "-") {
                try consume(#"-1,"value":"#)
                let value = try double(endingAt: UInt8(ascii: "}"))
                node = Node(leaf: value)
            } else {
                let feature = try integer()
                try consume(#","threshold":"#)
                let threshold = try double(endingAt: UInt8(ascii: ","))
                try consume(#","left":"#)
                let left = try integer()
                try consume(#","right":"#)
                let right = try integer()
                node = Node(feature: feature, threshold: threshold, left: left, right: right)
            }
            try consume("}")
            return node
        }
    }
    private final class NumericDecodeResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<NumericBundle, Error>?
        func store(_ result: Result<NumericBundle, Error>) {
            lock.lock(); defer { lock.unlock() }
            value = result
        }
        func load() -> Result<NumericBundle, Error>? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private struct NumericHead: Decodable {
        let bias: Double
        let learningRate: Double
        let trees: [[NumericNode]]
    }
    private struct NumericNode: Decodable {
        let feature: Int
        let threshold: Double?
        let left: Int?
        let right: Int?
        let value: Double?
    }
    private struct Head: Sendable {
        let bias: Double; let learningRate: Double; let trees: [[Node]]
        init(bias: Double, learningRate: Double, trees: [[Node]]) {
            self.bias = bias
            self.learningRate = learningRate
            self.trees = trees
        }
        init(_ raw: [String: Any], numeric: NumericHead, names: [String]) throws {
            try exact(raw, ["schema", "bias", "learningRate", "featureNames", "trees"])
            guard raw["schema"] as? String == "numeric-hist-gradient-boost-v1",
                  raw["featureNames"] as? [String] == names,
                  numeric.bias.isFinite, numeric.learningRate.isFinite, numeric.learningRate > 0,
                  let rawTrees = raw["trees"] as? [[[String: Any]]], rawTrees.count <= 8192,
                  rawTrees.count == numeric.trees.count else {
                throw Failure.invalidBundle("head")
            }
            var trees = [[Node]](), total = 0
            for (rawTree, numericTree) in zip(rawTrees, numeric.trees) {
                guard !rawTree.isEmpty, rawTree.count <= 65_535,
                      rawTree.count == numericTree.count else { throw Failure.invalidBundle("tree size") }
                total += rawTree.count
                guard total <= 1_048_576 else { throw Failure.invalidBundle("head node budget") }
                let nodes = try zip(rawTree, numericTree).map { raw, numeric -> Node in
                    let f = numeric.feature
                    guard integer(raw["feature"]) == f else { throw Failure.invalidBundle("feature") }
                    if f == -1 {
                        try exact(raw, ["feature", "value"])
                        guard let v = numeric.value, v.isFinite else { throw Failure.invalidBundle("leaf") }
                        return Node(leaf: v)
                    }
                    try exact(raw, ["feature", "threshold", "left", "right"])
                    guard f >= 0, f < featureCount, let threshold = numeric.threshold, threshold.isFinite,
                          let l = numeric.left, let r = numeric.right,
                          l >= 0, r >= 0, l < rawTree.count, r < rawTree.count else {
                        throw Failure.invalidBundle("split")
                    }
                    return Node(feature: f, threshold: threshold, left: l, right: r)
                }
                // Validate the entire graph, including reachability, unique parent,
                // cycles and bounded depth before any feature-dependent traversal.
                var visited = Set<Int>(), stack = [(0, 0)]
                while let (index, depth) = stack.popLast() {
                    guard depth <= 128, visited.insert(index).inserted else { throw Failure.invalidBundle("tree graph") }
                    let node = nodes[index]
                    if node.feature >= 0 { stack.append((node.right, depth + 1)); stack.append((node.left, depth + 1)) }
                }
                guard visited.count == nodes.count else { throw Failure.invalidBundle("unreachable node") }
                trees.append(nodes)
            }
            self.bias = numeric.bias; self.learningRate = numeric.learningRate; self.trees = trees
        }
    }
    private static func exact(_ raw: [String: Any], _ keys: Set<String>) throws {
        guard Set(raw.keys) == keys else { throw Failure.invalidBundle("unknown or missing keys") }
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func integer(_ raw: Any?) -> Int? {
        guard let d = number(raw), d.rounded(.towardZero) == d, d >= -1, d <= Double(Int32.max) else { return nil }
        return Int(d)
    }
    /// Python corner8_geometry.apply(gain=1,bound=32), with its logical frame
    /// guard. Return raw exactly for zero residual or rejected proposal; no clipping
    /// of individual corners to image bounds. Invalid API inputs abstain with nil.
    static func apply(rawQuad q: [[Double]], residual: [Double], frame: Frame) -> [[Double]]? {
        guard q.count == 4, q.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
              residual.count == 8, residual.allSatisfy(\.isFinite),
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        let z = residual.map { min(32, max(-32, $0)) }
        if z.allSatisfy({ $0 == 0 }) { return q }
        let dx = q[1][0] - q[0][0], dy = q[1][1] - q[0][1], length = hypot(dx, dy)
        guard length.isFinite, length > 0 else { return nil }
        let ux = dx / length, uy = dy / length
        var vx = -uy, vy = ux
        if vx * (q[3][0] - q[0][0]) + vy * (q[3][1] - q[0][1]) < 0 { vx = -vx; vy = -vy }
        let pu = q.map { $0[0] * ux + $0[1] * uy }, pv = q.map { $0[0] * vx + $0[1] * vy }
        let w = max(1e-9, pu.max()! - pu.min()!), h = max(1e-9, pv.max()! - pv.min()!)
        var result = [[Double]](); result.reserveCapacity(4)
        for i in 0..<4 {
            // Keep Python's left-to-right addition order (not a reconstructed rectangle).
            let x = (q[i][0] + (z[2 * i] * w) * ux) + (z[2 * i + 1] * h) * vx
            let y = (q[i][1] + (z[2 * i] * w) * uy) + (z[2 * i + 1] * h) * vy
            result.append([x, y])
        }
        return valid(result, frame: frame) ? result : q
    }
    static func valid(_ q: [[Double]], frame: Frame) -> Bool {
        guard q.count == 4, frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              q.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) &&
                  $0[0] >= -0.15 * frame.width - 1e-6 && $0[0] <= 1.15 * frame.width + 1e-6 &&
                  $0[1] >= -0.15 * frame.height - 1e-6 && $0[1] <= 1.15 * frame.height + 1e-6 }) else { return false }
        var edges = [[Double]]()
        for i in 0..<4 {
            let next = (i + 1) % 4
            let ex: Double = q[next][0] - q[i][0]
            let ey: Double = q[next][1] - q[i][1]
            edges.append([ex, ey])
        }
        var cross = [Double]()
        for i in 0..<4 {
            let next = (i + 1) % 4
            let left: Double = edges[i][0] * edges[next][1]
            let right: Double = edges[i][1] * edges[next][0]
            cross.append(left - right)
        }
        return cross.allSatisfy({ $0 > 1e-8 }) || cross.allSatisfy({ $0 < -1e-8 })
    }
}
