import Foundation

/// Source-only native17 cache ABI from the existing ALL300 RF output tensors.
/// No new inference, RGB, OCR, GT, query selection or raw-mask retention.
struct NativeRFDETRSourceSupportGrid: Sendable {
    static let schema = "rf-allquery-grid-cache-v1"
    static let queryCount = 300
    static let side = 162
    static let planeCount = 17
    static let classOrder = ["text", "soundEffect", "balloon", "frame", "unmappedClass4"]
    static let planeNames = classOrder.flatMap { cls in
        ["\(cls).maxMaskProbability", "\(cls).weightedMeanMaskProbability", "\(cls).maxBoxConfidence"]
    } + ["margin", "uncertainty"]
    /// Plane-major [17,162,162]. All arithmetic/reductions are Float32.
    let native17Fields: [Float]
    enum Failure: Error { case invalidEvidence }

    /// Boxes are normalized [cx,cy,width,height], logits are query-major five
    /// independent class logits. The callback is read exactly ONCE per mask
    /// cell, reusing all300 outputs, and is never retained or persisted.
    static func aggregate(boxes: [Float], logits: [Float],
                          maskLogit: (Int, Int, Int) throws -> Float) throws -> Self {
        try reduce(boxes: boxes, logits: logits) { accumulator in
            try accumulator.accumulate(rows: 0..<side, checkCancellation: true) { q, y, values in
                for x in 0..<side {
                    let value = try maskLogit(q, y, x)
                    guard value.isFinite else { throw Failure.invalidEvidence }
                    values[x] = sigmoid(value)
                }
            }
        }
    }

    /// The Core ML pointer is read-only until all row tiles join.
    private struct MaskTensor: @unchecked Sendable {
        let data: UnsafePointer<Float>
        let queryStride: Int
        let rowStride: Int
        let pixelStride: Int

        func readProbabilities(_ q: Int, _ y: Int, _ values: UnsafeMutablePointer<Float>) throws {
            let row = data + q * queryStride + y * rowStride
            if pixelStride == 1 {
                for x in 0..<side {
                    let value = row[x]
                    guard value.isFinite else { throw Failure.invalidEvidence }
                    values[x] = sigmoid(value)
                }
            } else {
                for x in 0..<side {
                    let value = row[x * pixelStride]
                    guard value.isFinite else { throw Failure.invalidEvidence }
                    values[x] = sigmoid(value)
                }
            }
        }
    }

    static func aggregate(boxes: [Float], logits: [Float], maskData: UnsafePointer<Float>,
                          queryStride: Int, rowStride: Int, pixelStride: Int) throws -> Self {
        let masks = MaskTensor(data: maskData, queryStride: queryStride, rowStride: rowStride, pixelStride: pixelStride)
        return try reduce(boxes: boxes, logits: logits) { accumulator in
            let rowsPerTile = 12, tilesPerPass = 3
            try withUnsafeTemporaryAllocation(of: Bool.self, capacity: tilesPerPass) { scratch in
                // One error flag per worker. The calling task checks flags and
                // observes its own cancellation after each synchronous join.
                nonisolated(unsafe) let invalid = scratch.baseAddress!
                invalid.initialize(repeating: false, count: tilesPerPass)
                for firstRow in stride(from: 0, to: side, by: rowsPerTile * tilesPerPass) {
                    try Task.checkCancellation()
                    let tiles = min(tilesPerPass, (side - firstRow + rowsPerTile - 1) / rowsPerTile)
                    DispatchQueue.concurrentPerform(iterations: tiles) { tile in
                        let start = firstRow + tile * rowsPerTile
                        do {
                            try accumulator.accumulate(rows: start..<min(start + rowsPerTile, side),
                                checkCancellation: false, fillProbabilities: masks.readProbabilities)
                        } catch { invalid[tile] = true }
                    }
                    if scratch.contains(true) { throw Failure.invalidEvidence }
                }
            }
            try Task.checkCancellation()
        }
    }

    // Each tile owns disjoint rows of every plane. Output storage is borrowed
    // for the synchronous reduction, and every output keeps its query order.
    private struct Accumulator: @unchecked Sendable {
        let planes: UnsafeMutablePointer<Float>
        let classes: [Float]
        let coverage: [(x: Range<Int>, y: Range<Int>)]

        func accumulate(rows: Range<Int>, checkCancellation: Bool,
                        fillProbabilities: (Int, Int, UnsafeMutablePointer<Float>) throws -> Void) throws {
            let cells = side * side
            try withUnsafeTemporaryAllocation(of: Float.self, capacity: side) { scratch in
                let values = scratch.baseAddress!
                for q in 0..<queryCount {
                    if checkCancellation { try Task.checkCancellation() }
                    let boxCoverage = coverage[q]
                    for y in rows {
                        let row = y * side
                        try fillProbabilities(q, y, values)
                        for cls in 0..<5 {
                            let probability = classes[q * 5 + cls]
                            let peak = planes + cls * 3 * cells + row
                            let sum = peak + cells
                            for x in 0..<side {
                                let weighted = values[x] * probability
                                peak[x] = max(peak[x], weighted)
                                sum[x] += weighted
                            }
                            if boxCoverage.y.contains(y) {
                                let box = sum + cells
                                for x in boxCoverage.x { box[x] = max(box[x], probability) }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func reduce(boxes: [Float], logits: [Float],
                               accumulate: (Accumulator) throws -> Void) throws -> Self {
        guard boxes.count == queryCount * 4, logits.count == queryCount * 5,
              boxes.allSatisfy(\.isFinite), logits.allSatisfy(\.isFinite) else { throw Failure.invalidEvidence }
        let cells = side * side
        let classes = logits.map(sigmoid)
        let denominator = (0..<5).map { cls in
            max(Float(1e-9), numpySum((0..<queryCount).map { classes[$0 * 5 + cls] }))
        }
        let centers = (0..<side).map { (Double($0) + 0.5) / Double(side) }
        var fields = [Float](repeating: 0, count: planeCount * cells)
        func covered(_ minimum: Double, _ maximum: Double) -> Range<Int> {
            guard let first = centers.firstIndex(where: { $0 >= minimum }),
                  let last = centers.lastIndex(where: { $0 <= maximum }), first <= last
            else { return 0..<0 }
            return first..<(last + 1)
        }
        // Float32 box endpoints, Float64 grid centers, exactly as prepare_rf.py.
        // Literal comparisons also preserve finite out-of-frame/negative-size boxes.
        let coverage = try (0..<queryCount).map { q in
            let cx = boxes[q * 4], cy = boxes[q * 4 + 1]
            let halfW = boxes[q * 4 + 2] / 2, halfH = boxes[q * 4 + 3] / 2
            let left = cx - halfW, top = cy - halfH, right = cx + halfW, bottom = cy + halfH
            guard left.isFinite, top.isFinite, right.isFinite, bottom.isFinite else { throw Failure.invalidEvidence }
            return (x: covered(Double(left), Double(right)), y: covered(Double(top), Double(bottom)))
        }
        try fields.withUnsafeMutableBufferPointer { storage in
            try accumulate(Accumulator(planes: storage.baseAddress!, classes: classes, coverage: coverage))
        }
        for cls in 0..<5 {
            let offset = (cls * 3 + 1) * cells
            for i in 0..<cells { fields[offset + i] /= denominator[cls] }
        }
        for i in 0..<cells {
            // Native first FOUR classes only; unmappedClass4 never votes here.
            var first = Float(0), second = Float(0)
            for cls in 0..<4 {
                let value = fields[cls * 3 * cells + i]
                if value >= first { second = first; first = value }
                else if value > second { second = value }
            }
            fields[15 * cells + i] = first - second
            fields[16 * cells + i] = (4 * first) * (1 - first)
        }
        guard fields.allSatisfy(\.isFinite) else { throw Failure.invalidEvidence }
        return .init(native17Fields: fields)
    }
    private static func sigmoid(_ raw: Float) -> Float {
        let clipped = min(Float(80), max(Float(-80), raw))
        let exponential: Float = exp(-clipped)
        return Float(1) / (Float(1) + exponential)
    }
    /// np.sum of the 300 strided class probabilities uses eight-accumulator
    /// pairwise Float32 reduction. It is distinct from the mask slow-axis sum.
    static func numpySum(_ values: [Float]) -> Float {
        func sum(_ start: Int, _ count: Int) -> Float {
            if count < 8 {
                var result = Float(-0.0)
                for i in start..<(start+count) { result += values[i] }
                return result
            }
            if count <= 128 {
                var r = Array(values[start..<(start+8)]), i = 8
                while i < count - count % 8 {
                    for k in 0..<8 { r[k] += values[start+i+k] }
                    i += 8
                }
                var result = ((r[0]+r[1])+(r[2]+r[3])) + ((r[4]+r[5])+(r[6]+r[7]))
                while i < count { result += values[start+i]; i += 1 }
                return result
            }
            var middle = count / 2
            middle -= middle % 8
            return sum(start, middle) + sum(start+middle, count-middle)
        }
        return sum(0, values.count)
    }
}
