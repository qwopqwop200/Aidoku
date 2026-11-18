import CoreGraphics
import Foundation

/// Full-query source evidence for segmentation, independent of accepted layout
/// classes. Source identities validate handoff; they never become model inputs.
struct NativePixelRFEvidence {
    enum Failure: Error { case incompleteQueries, invalidGeometry, sourceMismatch }
    struct Support {
        let coarse: [Float]
        let full: [Float]
        let ownerQueries: [Int]
        /// Preserve pre-Float16 owner affinity for the selected style policy.
        let affinityScores: [Float]
    }
    let width: Int
    let height: Int
    let imageIdentity: String
    private let masks: [NativeRFDETRClassEvidence]
    private let bank: NativeRFImmutableMaskBank?
    private let primitives: [NativeRFDETRLayoutPrimitive]
    private let classes: [[Float]]
    private let recent = RecentProjection()
    private let denominators: [Float]
    private let boxes: [(x: Range<Int>, y: Range<Int>)]
    private static let side = 162

    init(result: NativeRFDETRLayoutResult) throws {
        let side = Self.side
        let inventory = result.pixelInventory
        let bank = inventory.bank
        func validMask(_ query: NativeRFDETRClassEvidence) -> Bool {
            if let mask = query.mask {
                return mask.sourceWidth == result.sourceWidth && mask.sourceHeight == result.sourceHeight &&
                    mask.logits.count == side * side && mask.logits.allSatisfy(\.isFinite)
            }
            return bank?.width == result.sourceWidth && bank?.height == result.sourceHeight
        }
        let queries = inventory.queries.sorted { $0.queryID < $1.queryID }
        guard result.sourceWidth > 0, result.sourceHeight > 0,
              queries.count == 300, queries.enumerated().allSatisfy({ index, query in
                  query.queryID == index && query.logits.count == 5 && query.logits.allSatisfy(\.isFinite) &&
                  validMask(query) &&
                  query.normalizedBounds.origin.x.isFinite && query.normalizedBounds.origin.y.isFinite &&
                  query.normalizedBounds.width.isFinite && query.normalizedBounds.height.isFinite &&
                  query.normalizedBounds.width >= 0 && query.normalizedBounds.height >= 0
              }) else { throw Failure.incompleteQueries }
        self.bank = bank
        masks = queries
        primitives = result.primitives
        width = result.sourceWidth; height = result.sourceHeight; imageIdentity = result.imageIdentity
        classes = queries.map { $0.logits.map(Self.sigmoid) }
        let probabilities = classes
        denominators = (0..<5).map { c in max(1e-9, probabilities.reduce(Float(0)) { $0 + $1[c] }) }
        // Preserve the original center comparisons, including both rectangle edges.
        // Each accepted x/y interval is contiguous on the native grid.
        let centers = (0..<side).map { (Double($0) + 0.5) / Double(side) }
        boxes = queries.map { query -> (Range<Int>, Range<Int>) in
            let box = query.normalizedBounds
            let xs = centers.indices.filter { centers[$0] >= box.minX && centers[$0] <= box.maxX }
            let ys = centers.indices.filter { centers[$0] >= box.minY && centers[$0] <= box.maxY }
            return ((xs.first ?? 0)..<(xs.last.map { $0 + 1 } ?? 0),
                    (ys.first ?? 0)..<(ys.last.map { $0 + 1 } ?? 0))
        }
    }

    private func withMaskLogits<T>(_ query: NativeRFDETRClassEvidence, _ body: (UnsafeBufferPointer<Float>) -> T) -> T {
        if let mask = query.mask { return mask.logits.withUnsafeBufferPointer(body) }
        return bank!.withPlane(queryID: query.queryID, body)
    }

    private struct Projection {
        let x: Range<Int>
        let y: Range<Int>
        let coarseX: Range<Int>
        let coarseY: Range<Int>
        let fields: [ArraySlice<Float>]
        let coarse: [SIMD4<Float>]
        let ownerPixels: [Int]
        let affinity: [Float]
    }

    /// Owner preparation may run concurrently. Retain at most one native
    /// rectangle per evidence object. Expensive calculations run outside the lock.
    private final class RecentProjection {
        private let lock = NSLock()
        private var value: Projection?

        func covering(x: Range<Int>, y: Range<Int>, coarseX: Range<Int>, coarseY: Range<Int>) -> Projection? {
            lock.lock(); defer { lock.unlock() }
            guard let value, x.clamped(to: value.x) == x, y.clamped(to: value.y) == y,
                  coarseX.clamped(to: value.coarseX) == coarseX, coarseY.clamped(to: value.coarseY) == coarseY else { return nil }
            return value
        }

        func store(_ projection: Projection) {
            lock.lock(); defer { lock.unlock() }
            value = projection
        }
    }

    private func project(x: Range<Int>, y: Range<Int>, coarseX: Range<Int>, coarseY: Range<Int>,
                         ownerPixels: [Int]) -> (Projection, [Float]) {
        if let reused = recent.covering(x: x, y: y, coarseX: coarseX, coarseY: coarseY) {
            if ownerPixels == reused.ownerPixels { return (reused, reused.affinity) }
            // The summaries and nearest primitive evidence are independent of
            // ownership. A different polygon must earn its own query affinities.
            let affinity = masks.map { mask in
                withMaskLogits(mask) { input -> Float in
                    let source = input.baseAddress!
                    var total = Float(0)
                    for i in ownerPixels { total += Self.sigmoid(source[i]) }
                    return total / Float(ownerPixels.count)
                }
            }
            return (reused, affinity)
        }
        let (fields, affinity) = nativeFields(x: x, y: y, ownerPixels: ownerPixels)
        var coarse = [SIMD4<Float>](repeating: .zero, count: coarseX.count * coarseY.count)
        for primitive in primitives {
            guard let mask = primitive.mask else { continue }
            let channel = primitive.semanticClass.rawValue
            let confidence = Float((Double(primitive.confidence) * 255).rounded(.toNearestOrEven)) / 255
            for cy in coarseY {
                let row = (cy - coarseY.lowerBound) * coarseX.count
                for cx in coarseX where mask.logits[cy * Self.side + cx] > 0 {
                    let i = row + cx - coarseX.lowerBound
                    coarse[i][channel] = max(coarse[i][channel], confidence)
                }
            }
        }
        let result = Projection(x: x, y: y, coarseX: coarseX, coarseY: coarseY,
            fields: fields, coarse: coarse, ownerPixels: ownerPixels, affinity: affinity)
        recent.store(result)
        return (result, affinity)
    }

    /// Build only native cells needed by bilinear interpolation. Affinity still
    /// visits every owner cell in the original order, even outside the crop.
    private func nativeFields(x: Range<Int>, y: Range<Int>, ownerPixels: [Int]) -> (planes: [ArraySlice<Float>], affinity: [Float]) {
        let side = Self.side, width = x.count, cells = width * y.count
        let ownerOffsets = ownerPixels.map { pixel -> Int in
            let cx = pixel % side, cy = pixel / side
            return x.contains(cx) && y.contains(cy) ? (cy - y.lowerBound) * width + cx - x.lowerBound : -1
        }
        var fields = [Float](repeating: 0, count: 17 * cells)
        var probability = [Float](repeating: 0, count: cells)
        var affinity = [Float](repeating: 0, count: masks.count)
        fields.withUnsafeMutableBufferPointer { output in
            let planes = output.baseAddress!
            probability.withUnsafeMutableBufferPointer { buffer in
                let values = buffer.baseAddress!
                for q in masks.indices {
                    withMaskLogits(masks[q]) { mask in
                        let source = mask.baseAddress!
                        for cy in y {
                            let row = source + cy * side + x.lowerBound
                            let dest = values + (cy - y.lowerBound) * width
                            for cx in 0..<width { dest[cx] = Self.sigmoid(row[cx]) }
                        }
                        var total = Float(0)
                        for i in ownerOffsets.indices {
                            let offset = ownerOffsets[i]
                            total += offset >= 0 ? values[offset] : Self.sigmoid(source[ownerPixels[i]])
                        }
                        affinity[q] = total / Float(ownerPixels.count)
                    }
                    let box = boxes[q]
                    let xs = box.x.clamped(to: x), ys = box.y.clamped(to: y)
                    for c in 0..<5 {
                        let scalar = classes[q][c]
                        let peak = planes + c * 3 * cells, sum = peak + cells
                        for i in 0..<cells {
                            let weighted = values[i] * scalar
                            peak[i] = max(peak[i], weighted)
                            sum[i] += weighted
                        }
                        let confidence = sum + cells
                        for cy in ys {
                            let row = confidence + (cy - y.lowerBound) * width
                            for cx in xs { row[cx - x.lowerBound] = max(row[cx - x.lowerBound], scalar) }
                        }
                    }
                }
            }
            for c in 0..<5 {
                let sum = planes + (c * 3 + 1) * cells
                for i in 0..<cells { sum[i] /= denominators[c] }
            }
            for i in 0..<cells {
                let a = planes[i], b = planes[3 * cells + i], c = planes[6 * cells + i], d = planes[9 * cells + i]
                let ab = max(a, b), cd = max(c, d), top = max(ab, cd)
                let second = max(min(ab, cd), max(min(a, b), min(c, d)))
                planes[15 * cells + i] = top - second
                planes[16 * cells + i] = 4 * top * (1 - top)
            }
        }
        return ((0..<17).map { fields[($0 * cells)..<(($0 + 1) * cells)] }, affinity)
    }

    func support(crop: CGRect, polygons: [[CGPoint]], sourceIdentity: String) throws -> Support {
        guard sourceIdentity == imageIdentity else { throw Failure.sourceMismatch }
        guard crop.minX.isFinite, crop.minY.isFinite, crop.width.isFinite, crop.height.isFinite,
              crop.minX >= 0, crop.minY >= 0, crop.maxX <= CGFloat(width), crop.maxY <= CGFloat(height),
              crop.width > 0, crop.height > 0, crop == crop.integral,
              crop.width <= 1_500_000 / crop.height, !polygons.isEmpty,
              polygons.count <= 256, polygons.allSatisfy({ (3...16).contains($0.count) &&
                  $0.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) }) else { throw Failure.invalidGeometry }
        let side = Self.side, w = Int(crop.width), h = Int(crop.height)
        var owner = [UInt8](repeating: 0, count: side * side)
        for polygon in polygons {
            let native = polygon.map { point in CGPoint(
                x: (Double(point.x) * Double(side) / Double(width) - 0.5).rounded(.toNearestOrEven),
                y: (Double(point.y) * Double(side) / Double(height) - 0.5).rounded(.toNearestOrEven)) }
            let mask = NativeMainRemovalSourceFactory.NativeCurrentMaskCaller.raster(native, width: side, height: side)
            for i in owner.indices where mask[i] != 0 { owner[i] = 1 }
        }
        let pixels = owner.indices.filter { owner[$0] != 0 }
        guard !pixels.isEmpty else { throw Failure.invalidGeometry }
        // Preserve Float32 fractional coordinates and the distinct Double-based
        // nearest-cell rule for accepted primitive masks.
        func axis(_ index: Int, _ size: Int) -> (lo: Int, hi: Int, delta: Double, nearest: Int) {
            let f = min(Float(side - 1), max(0, (Float(index) + 0.5) * Float(side) / Float(size) - 0.5))
            let lo = Int(f)
            return (lo, min(side - 1, lo + 1), Double(f) - Double(lo),
                    min(side - 1, Int((Double(index) + 0.5) * Double(side) / Double(size))))
        }
        let originX = Int(crop.minX), originY = Int(crop.minY)
        let firstX = axis(originX, width), lastX = axis(originX + w - 1, width)
        let firstY = axis(originY, height), lastY = axis(originY + h - 1, height)
        let nativeX = firstX.lo..<(lastX.hi + 1), nativeY = firstY.lo..<(lastY.hi + 1)
        let (projection, affinity) = project(x: nativeX, y: nativeY,
            coarseX: firstX.nearest..<(lastX.nearest + 1), coarseY: firstY.nearest..<(lastY.nearest + 1), ownerPixels: pixels)
        let summaries = projection.fields
        var selected = [Int](), scores = [Float]()
        for c in 0..<5 {
            var best = 0
            for q in 1..<300 where classes[q][c] * affinity[q] > classes[best][c] * affinity[best] { best = q }
            selected.append(best); scores.append(classes[best][c] * affinity[best])
        }
        let channels = summaries.count + selected.count
        let quantizedScores = scores.map(Self.quantized)
        let coarseX = projection.coarseX, coarseY = projection.coarseY, nativeCoarse = projection.coarse
        var coarse = [Float](repeating: 0, count: w * h * 4)
        var full = [Float](repeating: 0, count: w * h * 27)
        try full.withUnsafeMutableBufferPointer { fullOut in
            try coarse.withUnsafeMutableBufferPointer { coarseOut in
                // Keep two exact Double horizontal rows across adjacent source rows.
                // Width tiling caps this scratch at 2 × 22 × 512 Doubles.
                for tileX in stride(from: 0, to: w, by: 512) {
                    let span = min(512, w - tileX)
                    let xs = (0..<span).map { axis(originX + tileX + $0, width) }
                    func fillHorizontal(_ y: Int, _ row: inout [Double]) {
                        for c in 0..<channels {
                            let isQueryMask = (15..<20).contains(c)
                            func fill(_ grid: UnsafeBufferPointer<Float>) {
                                let offset = isQueryMask ? y * side + nativeX.lowerBound :
                                    (y - projection.y.lowerBound) * projection.x.count + nativeX.lowerBound - projection.x.lowerBound
                                let start = grid.baseAddress! + offset
                                row.withUnsafeMutableBufferPointer { output in
                                    let dest = output.baseAddress! + c * span
                                    for x in 0..<span {
                                        let pos = xs[x]
                                        dest[x] = Double(start[pos.lo - nativeX.lowerBound]) * (1 - pos.delta) + Double(start[pos.hi - nativeX.lowerBound]) * pos.delta
                                    }
                                }
                            }
                            if isQueryMask { withMaskLogits(masks[selected[c - 15]], fill) }
                            else { summaries[c < 15 ? c : c - 5].withUnsafeBufferPointer(fill) }
                        }
                    }
                    var previousY = -1
                    var top = [Double](repeating: 0, count: channels * span), bottom = top
                    for y in 0..<h {
                        try Task.checkCancellation()
                        let pos = axis(originY + y, height)
                        if pos.lo != previousY {
                            if previousY >= 0 && previousY + 1 == pos.lo {
                                swap(&top, &bottom)
                            } else { fillHorizontal(pos.lo, &top) }
                            fillHorizontal(pos.hi, &bottom)
                            previousY = pos.lo
                        }
                        let line = fullOut.baseAddress! + (y * w + tileX) * 27
                        for x in 0..<span {
                            let coarseValue = nativeCoarse[(pos.nearest - coarseY.lowerBound) * coarseX.count + xs[x].nearest - coarseX.lowerBound]
                            let dest = coarseOut.baseAddress! + (y * w + tileX + x) * 4
                            for c in 0..<4 { dest[c] = coarseValue[c] }
                            let vals = line + x * 27
                            for c in 0..<5 { vals[16 + 2 * c] = quantizedScores[c] }
                        }
                        for c in 0..<channels {
                            let out = c < 15 ? c : c < 20 ? 15 + 2 * (c - 15) : c + 5
                            let sigmoid = c >= 15 && c < 20
                            let start = c * span
                            for x in 0..<span {
                                let value = Float(top[start + x] * (1 - pos.delta) + bottom[start + x] * pos.delta)
                                line[x * 27 + out] = Self.quantized(sigmoid ? Self.sigmoid(value) : value)
                            }
                        }
                    }
                }
            }
        }
        return Support(coarse: coarse, full: full, ownerQueries: selected, affinityScores: scores)
    }

    private static func quantized(_ value: Float) -> Float { Float(Float16(value)) }
    private static func sigmoid(_ value: Float) -> Float { 1 / (1 + exp(-min(80, max(-80, value)))) }
}
