import CryptoKit
import Dispatch
import Foundation

/// Immutable, portable global segmentation classifier. The model contains only
/// source-feature splits and calibrated votes, never examples or GT lookups.
struct NativePixelRFForest: Sendable {
    enum Failure: Error { case invalidModel, invalidFeatures }
    private struct Node: Decodable, Sendable {
        let feature: Int
        let threshold: Float
        let left: Int
        let right: Int
        let positive: Int
        private enum CodingKeys: String, CodingKey { case feature, threshold, left, right, positive }

        init(from decoder: Decoder) throws {
            if var values = try? decoder.unkeyedContainer() {
                feature = try values.decode(Int.self)
                threshold = try values.decode(Float.self)
                left = try values.decode(Int.self)
                right = try values.decode(Int.self)
                positive = try values.decode(Int.self)
                guard values.isAtEnd else { throw Failure.invalidModel }
            } else {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                feature = try values.decode(Int.self, forKey: .feature)
                threshold = try values.decode(Float.self, forKey: .threshold)
                left = try values.decode(Int.self, forKey: .left)
                right = try values.decode(Int.self, forKey: .right)
                positive = try values.decode(Int.self, forKey: .positive)
            }
        }
    }
    /// Execution-only packing after all original model validation succeeds.
    /// Leaf votes use feature -1 (zero) / -2 (one); children are then unused.
    private struct PackedNode: Sendable {
        let feature: Int32
        let threshold: Float
        let left: Int32
        let right: Int32
        init(feature: Int32, threshold: Float, left: Int32, right: Int32) {
            self.feature = feature
            self.threshold = threshold
            self.left = left
            self.right = right
        }

        init(_ node: Node, remap: [Int32]) {
            if node.feature < 0 {
                feature = -1 - Int32(node.positive)
                threshold = node.threshold
                // Legacy leaves allow arbitrary Int children; do not narrow
                // those semantically unused values or add a new rejection.
                left = 0; right = 0
            } else {
                // Validated feature/forward child indices are <=1_000_000.
                feature = Int32(node.feature); threshold = node.threshold
                left = remap[node.left]; right = remap[node.right]
            }
        }
    }
    /// Coalesce only duplicate terminal vote nodes. All split nodes and their
    /// original order remain, and the first original node always remains root0.
    private static func packTree(_ tree: [Node]) -> [PackedNode] {
        var remap = [Int32](repeating: 0, count: tree.count)
        var leafIndices = [Int32](repeating: -1, count: 2)
        var count: Int32 = 0
        for (index, node) in tree.enumerated() {
            if node.feature < 0, leafIndices[node.positive] >= 0 {
                remap[index] = leafIndices[node.positive]
            } else {
                remap[index] = count
                if node.feature < 0 { leafIndices[node.positive] = count }
                count += 1
            }
        }
        var result: [PackedNode] = []
        result.reserveCapacity(Int(count))
        for (index, node) in tree.enumerated() {
            // A duplicate leaf refers to a terminal already appended.
            if node.feature < 0, remap[index] != Int32(result.count) { continue }
            result.append(PackedNode(node, remap: remap))
        }
        return result
    }

    private struct Document: Decodable {
        let schema: Int
        let featureCount: Int
        let threshold: Float
        let trees: [[Node]]
        let sourceModelSHA256: String
        let sourceFeatureVariant: String
        let completion: Completion?
        let primarySourceModelSHA256: String?
        let boundaryEvidenceGate: BoundaryEvidenceGate?
    }
    struct BoundaryEvidenceGate: Decodable, Sendable {
        let primaryThreshold: Float
        let boundaryThreshold: Float
        let includeNativeSupport: Bool
        let colorCorroboration: ColorCorroboration?
        let chromaticOverride: ChromaticOverride?
        let uniformityGate: UniformityGate?
        let recoveryGate: RecoveryGate?
    }
    struct RecoveryGate: Decodable, Sendable {
        let primarySeedThreshold: Float
        let boundarySeedThreshold: Float
        let radius: Int
        let requireNativeSupport: Bool
        let maximumEdgeDistancePixels: Int
        let edgeContrastThreshold: Int
        let colorTolerance: Int
    }
    struct UniformityGate: Decodable, Sendable {
        let contrastThreshold: Int
        let distanceFontScale: Double
        let minimumDistancePixels: Int
        let maximumPrimaryProbability: Float
        let maximumBoundaryProbability: Float
        let preserveConsensusNeighbors: Bool
        let consensusRadius: Int
        let primarySeedThreshold: Float
        let boundarySeedThreshold: Float
    }
    struct ChromaticOverride: Decodable, Sendable {
        let minimumChroma: Int
        let primaryThreshold: Float
        let boundaryThreshold: Float
        let includeNativeSupport: Bool
        let colorCorroboration: ColorCorroboration?
    }
    struct ColorCorroboration: Decodable, Sendable {
        let radius: Int
        let tolerance: Int
        let primarySeedThreshold: Float
        let boundarySeedThreshold: Float
    }
    struct Completion: Decodable, Sendable {
        let unionNative: Bool
        let radiusFontScale: Double
        let minimumRadiusPixels: Int
        let maximumRadiusPixels: Int
        /// Weak support is added after stronger seeds have expanded. It never
        /// starts another expansion into uncertain background.
        let weakThreshold: Float?
        /// A missing kernel retains the historical square expansion.
        let kernel: String?
        /// Source-only probability floor for pixels reached by expansion.
        let fringeThreshold: Float?
    }
    let featureCount: Int
    let threshold: Float
    let sourceModelSHA256: String
    let sourceFeatureVariant: String
    let completion: Completion?
    let primarySourceModelSHA256: String?
    let boundaryEvidenceGate: BoundaryEvidenceGate?
    private let trees: [[PackedNode]]

    init(data: Data) throws {
        guard data.count <= 32 * 1_048_576 else { throw Failure.invalidModel }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schema == 1,
              (document.featureCount == 35 && document.sourceFeatureVariant == "pixel-coarse-rf-v1") ||
              (document.featureCount == 62 && document.sourceFeatureVariant == "pixel-full-rf-v2") ||
              (document.featureCount == 55 && document.sourceFeatureVariant == "pixel-boundary-full-rf-v1") ||
              (document.featureCount == 60 && document.sourceFeatureVariant == "pixel-boundary-rgb-edges-rf-v2"),
              document.threshold.isFinite, (0...1).contains(document.threshold),
              (1...256).contains(document.trees.count),
              document.sourceModelSHA256.count == 64,
              document.trees.reduce(0, { $0 + $1.count }) <= 1_000_000 else { throw Failure.invalidModel }
        for tree in document.trees {
            guard !tree.isEmpty else { throw Failure.invalidModel }
            for (index, node) in tree.enumerated() {
                if node.feature < 0 {
                    guard node.feature == -1, node.positive == 0 || node.positive == 1 else { throw Failure.invalidModel }
                } else {
                    guard node.feature < document.featureCount, node.threshold.isFinite,
                          node.left > index, node.right > index,
                          node.left < tree.count, node.right < tree.count else { throw Failure.invalidModel }
                }
            }
        }
        if let c = document.completion {
            guard c.radiusFontScale.isFinite, (0...0.25).contains(c.radiusFontScale),
                  c.minimumRadiusPixels >= 0, c.maximumRadiusPixels <= 16,
                  c.minimumRadiusPixels <= c.maximumRadiusPixels else { throw Failure.invalidModel }
            if let weak = c.weakThreshold {
                guard weak.isFinite, (0...document.threshold).contains(weak) else { throw Failure.invalidModel }
            }
            if let kernel = c.kernel {
                guard ["square", "ellipse", "cross"].contains(kernel) else { throw Failure.invalidModel }
            }
            if let fringe = c.fringeThreshold {
                guard fringe.isFinite, (0...(c.weakThreshold ?? document.threshold)).contains(fringe) else {
                    throw Failure.invalidModel
                }
            }
        }
        if let primary = document.primarySourceModelSHA256 {
            guard primary.count == 64 else { throw Failure.invalidModel }
        }
        if document.featureCount == 55 || document.featureCount == 60 {
            guard document.primarySourceModelSHA256 != nil else { throw Failure.invalidModel }
        }
        if let gate = document.boundaryEvidenceGate {
            guard document.featureCount == 55 || document.featureCount == 60,
                  gate.primaryThreshold.isFinite, (0...1).contains(gate.primaryThreshold),
                  gate.boundaryThreshold.isFinite, (0...1).contains(gate.boundaryThreshold) else {
                throw Failure.invalidModel
            }
            if let alternate = gate.chromaticOverride {
                guard (1...255).contains(alternate.minimumChroma),
                      alternate.primaryThreshold.isFinite, (0...1).contains(alternate.primaryThreshold),
                      alternate.boundaryThreshold.isFinite, (0...1).contains(alternate.boundaryThreshold) else {
                    throw Failure.invalidModel
                }
            }
            for color in [gate.colorCorroboration, gate.chromaticOverride?.colorCorroboration].compactMap({ $0 }) {
                guard (1...3).contains(color.radius), (0...255).contains(color.tolerance),
                      color.primarySeedThreshold.isFinite, color.primarySeedThreshold > 0,
                      color.primarySeedThreshold <= 1,
                      color.boundarySeedThreshold.isFinite, color.boundarySeedThreshold > 0,
                      color.boundarySeedThreshold <= 1 else { throw Failure.invalidModel }
            }
            if let uniform = gate.uniformityGate {
                guard (1...255).contains(uniform.contrastThreshold),
                      uniform.distanceFontScale.isFinite, (0...1).contains(uniform.distanceFontScale),
                      (1...64).contains(uniform.minimumDistancePixels),
                      uniform.maximumPrimaryProbability.isFinite, (0...1).contains(uniform.maximumPrimaryProbability),
                      uniform.maximumBoundaryProbability.isFinite, (0...1).contains(uniform.maximumBoundaryProbability),
                      (1...3).contains(uniform.consensusRadius),
                      uniform.primarySeedThreshold.isFinite, uniform.primarySeedThreshold > 0, uniform.primarySeedThreshold <= 1,
                      uniform.boundarySeedThreshold.isFinite, uniform.boundarySeedThreshold > 0, uniform.boundarySeedThreshold <= 1 else {
                    throw Failure.invalidModel
                }
            }
            if let recovery = gate.recoveryGate {
                guard recovery.primarySeedThreshold.isFinite, recovery.primarySeedThreshold > 0,
                      recovery.primarySeedThreshold <= 1,
                      recovery.boundarySeedThreshold.isFinite, (0...1).contains(recovery.boundarySeedThreshold),
                      (1...3).contains(recovery.radius), (-1...16).contains(recovery.maximumEdgeDistancePixels),
                      (1...255).contains(recovery.edgeContrastThreshold), (0...255).contains(recovery.colorTolerance) else {
                    throw Failure.invalidModel
                }
            }
        }
        featureCount = document.featureCount
        threshold = document.threshold
        sourceModelSHA256 = document.sourceModelSHA256
        sourceFeatureVariant = document.sourceFeatureVariant
        completion = document.completion
        primarySourceModelSHA256 = document.primarySourceModelSHA256
        boundaryEvidenceGate = document.boundaryEvidenceGate
        trees = document.trees.map(Self.packTree)
    }

    // This representation is generated from exactly one authenticated source forest.
    // The packer and the runtime pin its independent byte hash. A different tree format
    // or packing order requires a new header version and digest.
    static let primarySourceFileSHA256 = "8f5dba949b25c2cf54359bd8e4066c6423970980a0355887c83e150d82a0e617"
    private static let packedPrimarySHA256 = "58c1074e078f706e098d04960a897ca78ec74f9928b48ebc88e1232ca44a6984"
    private static let packedPrimaryBytes = 5_644_588

    static func primaryResource(in directory: URL) -> URL? {
        let json = directory.appendingPathComponent("primary-forest.json")
        if FileManager.default.fileExists(atPath: json.path) { return json }
        let packed = directory.appendingPathComponent("primary-forest.pr62")
        return FileManager.default.fileExists(atPath: packed.path) ? packed : nil
    }

    static func readPackedPrimary(at url: URL) throws -> Self? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let bytes = try file.read(upToCount: packedPrimaryBytes + 1),
              bytes.count == packedPrimaryBytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == packedPrimarySHA256
        else { return nil }
        let forest = try Self(verifiedPrimarySidecar: bytes)
        if ProcessInfo.processInfo.environment["AIDOKU_PRIMARY62_LOAD_RECEIPT"] == "1" {
            let receipt = "PRIMARY62_PACKED_LOAD sourceSHA256=\(primarySourceFileSHA256) packedSHA256=\(packedPrimarySHA256) bytes=\(packedPrimaryBytes)\n"
            FileHandle.standardError.write(Data(receipt.utf8))
        }
        return forest
    }

    private init(verifiedPrimarySidecar bytes: Data) throws {
        let header = Array("ADPR62".utf8) + [UInt8(0), 1]
        guard bytes.starts(with: header) else { throw Failure.invalidModel }
        let output: (Document, [[PackedNode]]) = try bytes.withUnsafeBytes { raw in
            var offset = 8
            func readWord() -> UInt32 {
                defer { offset += 4 }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard raw.count - offset >= 8 else { throw Failure.invalidModel }
            let metaLength = Int(readWord())
            let treeCount = Int(readWord())
            guard metaLength <= raw.count - offset, treeCount == 64 else { throw Failure.invalidModel }
            let meta = try JSONDecoder().decode(Document.self, from: bytes.subdata(in: offset..<(offset + metaLength)))
            offset += metaLength
            var forest: [[PackedNode]] = []
            forest.reserveCapacity(treeCount)
            for _ in 0..<treeCount {
                guard raw.count - offset >= 4 else { throw Failure.invalidModel }
                let nodes = Int(readWord())
                guard nodes > 0, nodes <= (raw.count - offset) / 16 else { throw Failure.invalidModel }
                var tree: [PackedNode] = []
                tree.reserveCapacity(nodes)
                for _ in 0..<nodes {
                    let feature = Int32(bitPattern: readWord())
                    let threshold = Float(bitPattern: readWord())
                    let left = Int32(bitPattern: readWord())
                    let right = Int32(bitPattern: readWord())
                    guard (-2..<62).contains(feature), threshold.isFinite,
                          (0..<nodes).contains(Int(left)), (0..<nodes).contains(Int(right)) else { throw Failure.invalidModel }
                    tree.append(PackedNode(feature: feature, threshold: threshold, left: left, right: right))
                }
                forest.append(tree)
            }
            guard offset == raw.count else { throw Failure.invalidModel }
            return (meta, forest)
        }
        let document = output.0
        featureCount = document.featureCount
        threshold = document.threshold
        sourceModelSHA256 = document.sourceModelSHA256
        sourceFeatureVariant = document.sourceFeatureVariant
        completion = document.completion
        primarySourceModelSHA256 = document.primarySourceModelSHA256
        boundaryEvidenceGate = document.boundaryEvidenceGate
        trees = output.1
    }

    /// Keep global crop statistics intact, but interleave the existing RF
    /// channels only a packet-aligned tile at a time on large primary crops.
    func cropProbabilities(_ input: NativePixelRFFeatures.Input) throws -> [Float] {
        let tileRows = 16_384
        // Keep the dense fast path until a whole number of tiles guarantees
        // a material backing reduction, rather than adding work on small crops.
        guard featureCount == 62, let full = input.fullRF,
              input.width > 0, input.height > 0, input.width <= 1_500_000 / input.height,
              input.width * input.height > 4 * tileRows else {
            return try probabilities(NativePixelRFFeatures.extract(input))
        }
        try Task.checkCancellation()
        let prefix = try NativePixelRFFeatures.extract(input, includeFullRF: false)
        var result: [Float] = []
        result.reserveCapacity(prefix.pixelCount)
        for start in stride(from: 0, to: prefix.pixelCount, by: tileRows) {
            try Task.checkCancellation()
            let count = min(tileRows, prefix.pixelCount - start)
            let values = [Float](unsafeUninitializedCapacity: count * 62) { buffer, initialized in
                let target = buffer.baseAddress!
                prefix.values.withUnsafeBufferPointer { local in
                    full.withUnsafeBufferPointer { rf in
                        for row in 0..<count {
                            let pixel = start + row
                            let destination = target + row * 62
                            destination.initialize(from: local.baseAddress! + pixel * 35, count: 35)
                            (destination + 35).initialize(from: rf.baseAddress! + pixel * 27, count: 27)
                        }
                    }
                }
                initialized = count * 62
            }
            let tile = NativePixelRFFeatures.Matrix(values: values, featureCount: 62, pixelCount: count)
            result.append(contentsOf: try probabilities(tile))
        }
        return result
    }

    // Both borrows outlive synchronous dispatch. Input is immutable; workers
    // write disjoint row ranges and visit the same trees in the same order.
    private struct EvaluationBuffers: @unchecked Sendable {
        let values: UnsafePointer<Float>
        let output: UnsafeMutablePointer<Float>
    }

    // All offsets fit in a 1024-row group. Node indices retain the validated model width.
    private struct Partition {
        let start: UInt16
        let end: UInt16
        let node: Int32
    }

    private func evaluateRows(_ start: Int, _ end: Int, buffers: EvaluationBuffers) {
        // Keep the existing packet evaluator for the legacy feature ABIs and small tails.
        guard featureCount == 62, end - start >= 1024 else {
            evaluatePackets(start, end, buffers: buffers)
            return
        }
        let tile = 1024
        var indices = [UInt16](repeating: 0, count: min(end - start, tile))
        var pending = [Partition]()
        pending.reserveCapacity(16)
        indices.withUnsafeMutableBufferPointer { members in
            let ids = members.baseAddress!
            for first in stride(from: start, to: end, by: tile) {
                let n = min(end - first, tile), rows = buffers.values + first * featureCount
                let output = buffers.output + first
                for tree in trees {
                    tree.withUnsafeBufferPointer { buffer in
                        let nodes = buffer.baseAddress!
                        for i in 0..<n { ids[i] = UInt16(i) }
                        var low = 0, high = n, node = nodes[0]
                        while true {
                            // Extremely unbalanced legal trees complete with the same scalar walk
                            // when the fixed worklist is full.
                            if node.feature >= 0, high - low > 8, pending.count < 16 {
                                var split = low, last = high
                                let feature = Int(node.feature)
                                while split < last {
                                    let row = ids[split]
                                    if rows[Int(row) * featureCount + feature] <= node.threshold {
                                        split += 1
                                    } else {
                                        last -= 1
                                        ids[split] = ids[last]
                                        ids[last] = row
                                    }
                                }
                                if split == low { node = nodes[Int(node.right)]; continue }
                                if split < high {
                                    pending.append(Partition(start: UInt16(split), end: UInt16(high), node: node.right))
                                    high = split
                                }
                                node = nodes[Int(node.left)]
                                continue
                            }
                            if node.feature == -2 {
                                for i in low..<high { output[Int(ids[i])] += 1 }
                            } else if node.feature >= 0 {
                                for i in low..<high {
                                    let row = Int(ids[i]), features = rows + row * featureCount
                                    var current = node
                                    while current.feature >= 0 {
                                        let next = features[Int(current.feature)] <= current.threshold ? current.left : current.right
                                        current = nodes[Int(next)]
                                    }
                                    output[row] += Float(-1 - current.feature)
                                }
                            }
                            guard let work = pending.popLast() else { break }
                            low = Int(work.start); high = Int(work.end); node = nodes[Int(work.node)]
                        }
                    }
                }
                for row in 0..<n { output[row] /= Float(trees.count) }
            }
        }
    }

    private func evaluatePackets(_ start: Int, _ end: Int, buffers: EvaluationBuffers) {
        let values = buffers.values, output = buffers.output
        for sample in stride(from: start, to: end, by: 64) {
            let stop = min(sample + 64, end)
            for tree in trees {
                tree.withUnsafeBufferPointer { nodes in
                    var rowIndex = sample
                    while rowIndex + 4 <= stop {
                        let row0 = values + rowIndex * featureCount
                        let row1 = row0 + featureCount, row2 = row1 + featureCount, row3 = row2 + featureCount
                        var n0 = nodes[0], n1 = nodes[0], n2 = nodes[0], n3 = nodes[0]
                        while n0.feature >= 0 || n1.feature >= 0 || n2.feature >= 0 || n3.feature >= 0 {
                            if n0.feature >= 0 { n0 = nodes[row0[Int(n0.feature)] <= n0.threshold ? Int(n0.left) : Int(n0.right)] }
                            if n1.feature >= 0 { n1 = nodes[row1[Int(n1.feature)] <= n1.threshold ? Int(n1.left) : Int(n1.right)] }
                            if n2.feature >= 0 { n2 = nodes[row2[Int(n2.feature)] <= n2.threshold ? Int(n2.left) : Int(n2.right)] }
                            if n3.feature >= 0 { n3 = nodes[row3[Int(n3.feature)] <= n3.threshold ? Int(n3.left) : Int(n3.right)] }
                        }
                        output[rowIndex] += Float(-Int(n0.feature) - 1)
                        output[rowIndex + 1] += Float(-Int(n1.feature) - 1)
                        output[rowIndex + 2] += Float(-Int(n2.feature) - 1)
                        output[rowIndex + 3] += Float(-Int(n3.feature) - 1)
                        rowIndex += 4
                    }
                    for rowIndex in rowIndex..<stop {
                        let row = values + rowIndex * featureCount
                        var node = nodes[0]
                        while node.feature >= 0 {
                            let index = row[Int(node.feature)] <= node.threshold ? Int(node.left) : Int(node.right)
                            node = nodes[index]
                        }
                        // Integers 0...256 are exact in Float32.
                        output[rowIndex] += Float(-Int(node.feature) - 1)
                    }
                }
            }
            for rowIndex in sample..<stop {
                output[rowIndex] /= Float(trees.count)
            }
        }
    }

    func probabilities(_ matrix: NativePixelRFFeatures.Matrix) throws -> [Float] {
        guard matrix.featureCount == featureCount, matrix.pixelCount > 0, matrix.pixelCount <= 1_500_000,
              matrix.values.count == matrix.pixelCount * featureCount,
              matrix.values.allSatisfy(\.isFinite) else { throw Failure.invalidFeatures }
        let batch = 16_384
        let workerLimit = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        var result = [Float](repeating: 0, count: matrix.pixelCount)
        try matrix.values.withUnsafeBufferPointer { values in
            try result.withUnsafeMutableBufferPointer { output in
                let buffers = EvaluationBuffers(values: values.baseAddress!, output: output.baseAddress!)
                for start in stride(from: 0, to: matrix.pixelCount, by: batch) {
                    try Task.checkCancellation()
                    let end = min(start + batch, matrix.pixelCount)
                    let workers = min(workerLimit, (end - start) / 2_048)
                    if workers >= 2 {
                        // Split on complete traversal packets while assigning the tail to the last worker.
                        let packets = (end - start) / 64
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            let lower = start + (worker * packets / workers) * 64
                            let upper = worker + 1 == workers ? end : start + ((worker + 1) * packets / workers) * 64
                            evaluateRows(lower, upper, buffers: buffers)
                        }
                    } else {
                        evaluateRows(start, end, buffers: buffers)
                    }
                }
            }
        }
        return result
    }

    func mask(_ matrix: NativePixelRFFeatures.Matrix) throws -> [UInt8] {
        try probabilities(matrix).map { $0 >= threshold ? 255 : 0 }
    }
}


