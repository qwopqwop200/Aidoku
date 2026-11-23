import CoreGraphics
@preconcurrency import CoreML
import Foundation

// S7: AOT-GAN 1024 FP16 restoration of the S6 removal mask, one prediction per page. The whole page
// is fitted into the 1024 canvas (global context keeps fills natural), and the bilinear upsampled
// prediction is written only at mask pixels; every other pixel is unchanged.

@available(iOS 18.0, macOS 15.0, *)
final class PipelineAOTModel: @unchecked Sendable {
    static let resourceName = "AOT-1024-FP16"
    static let side = 1024

    enum Failure: Error { case modelContract, maskSize, nonfinite }

    let model: MLModel
    /// Input tensors are reused, so predictions are serialized on this executor.
    let executor = PipelineSerialExecutor(label: "Aidoku.Pipeline.AOT")
    private let image: MLMultiArray
    private let mask: MLMultiArray
    private let provider: MLDictionaryFeatureProvider
    /// Preallocated `raw_rgb` backing: Core ML writes the prediction here (no per-page output allocation).
    private let output: MLMultiArray
    private let options = MLPredictionOptions()

    init(compiledURL: URL) throws {
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
#elseif os(iOS)
        // iPhone Neural Engine: 3.3x the GPU (332 vs 1098 ms per page), drift confined to erased pixels.
        configuration.computeUnits = .cpuAndNeuralEngine
#else
        configuration.computeUnits = .cpuAndGPU
#endif
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        image = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float16)
        mask = try MLMultiArray(shape: [1, 1, 1024, 1024], dataType: .float16)
        guard image.strides.map(\.intValue) == [3_145_728, 1_048_576, 1024, 1],
              mask.strides.map(\.intValue) == [1_048_576, 1_048_576, 1024, 1] else { throw Failure.modelContract }
        provider = try MLDictionaryFeatureProvider(dictionary: ["masked_image": image, "mask": mask])
        output = try MLMultiArray(shape: [1, 3, 1024, 1024], dataType: .float16)
        options.outputBackings = ["raw_rgb": output]
    }

    /// Downscaled model canvas of one page (instance-free, so it is built before an instance is held).
    struct Canvas: Sendable {
        var patch: Patch
        var rgba: [UInt8]
        var mask: [UInt8]
    }

    /// The page fitted into the model canvas, or nil for an empty `removal`.
    static func canvas(_ raster: PipelinePageRaster, removal: [UInt8]) throws -> Canvas? {
        guard removal.count == raster.width * raster.height else { throw Failure.maskSize }
        guard let patch = wholePage(removal, width: raster.width, height: raster.height) else { return nil }
        let cw = patch.size.0, ch = patch.size.1
        var canvas = [UInt8](repeating: 255, count: cw * ch * 4)
        var canvasMask = [UInt8](repeating: 0, count: cw * ch)
        downscale(raster.rgba, mask: removal, width: raster.width, patch: patch, pad: 0,
                  into: &canvas, canvasMask: &canvasMask, canvasWidth: cw)
        return Canvas(patch: patch, rgba: canvas, mask: canvasMask)
    }

    /// Synchronous restore of `removal` (page-sized, nonzero = erase); call through `executor`.
    func restoreImage(_ raster: PipelinePageRaster, removal: [UInt8]) throws -> CGImage {
        try restoreImage(raster, removal: removal, canvas: Self.canvas(raster, removal: removal))
    }

    /// Restore from a prebuilt `canvas` (nil: `removal` is empty); call through `executor`.
    func restoreImage(_ raster: PipelinePageRaster, removal: [UInt8], canvas: Canvas?) throws -> CGImage {
        guard removal.count == raster.width * raster.height else { throw Failure.maskSize }
        let width = raster.width, height = raster.height
        guard let prepared = canvas else {
            return try PipelinePageRaster.image(raster.rgba.withUnsafeBytes { Data($0) }, width: width, height: height)
        }
        let patch = prepared.patch
        let content = try predict(rgba: prepared.rgba, removal: prepared.mask, width: patch.size.0, height: patch.size.1)
        guard content == patch.size else { throw Failure.modelContract }
        // The page copy is made only now, so it is not resident while the prediction runs.
        var data = raster.rgba.withUnsafeBytes { Data($0) }
        try data.withUnsafeMutableBytes { bytes in
            try Self.scatter(into: bytes.bindMemory(to: UInt8.self), mask: removal, width: width, height: height,
                             raw: output, content: patch.size, region: patch.rect, origin: patch.origin)
        }
        return try PipelinePageRaster.image(data, width: width, height: height)
    }

    /// A page rect (x0, y0, x1, y1; exclusive) drawn at `origin` of the model canvas at `size`.
    struct Patch {
        var rect: (Int, Int, Int, Int)
        var origin: (Int, Int)
        var size: (Int, Int)
    }


    /// Integer-area downscale of `patch.rect` into the canvas (any-hit mask), edges replicated `pad` px.
    static func downscale(_ rgba: [UInt8], mask: [UInt8], width: Int, patch: Patch, pad: Int,
                          into canvas: inout [UInt8], canvasMask: inout [UInt8], canvasWidth: Int) {
        let (x0, y0, x1, y1) = patch.rect, (pw, ph) = patch.size, (ox, oy) = patch.origin
        let rw = x1 - x0, rh = y1 - y0
        // Disjoint canvas rows per lane; the union patch averages up to the whole page.
        canvas.withUnsafeMutableBufferPointer { canvasBuffer in canvasMask.withUnsafeMutableBufferPointer { maskBuffer in
        nonisolated(unsafe) let out = canvasBuffer.baseAddress!, outMask = maskBuffer.baseAddress!
        if (pw, ph) == (rw, rh) {
            // Native resolution: each area is one pixel, so canvas rows are page rows (the canvas
            // alpha is never read).
            mask.withUnsafeBufferPointer { maskPage in rgba.withUnsafeBufferPointer { page in
                for y in 0..<ph {
                    let p = (y0 + y) * width + x0, c = (oy + y) * canvasWidth + ox
                    (out + c * 4).update(from: page.baseAddress! + p * 4, count: pw * 4)
                    (outMask + c).update(from: maskPage.baseAddress! + p, count: pw)
                }
            } }
            return
        }
        // Column windows are shared by every row (same integer bounds as the per-pixel form).
        var spans = [(Int, Int)](repeating: (0, 0), count: pw)
        for x in 0..<pw { spans[x] = (x0 + x * rw / pw, x0 + min(rw, ((x + 1) * rw + pw - 1) / pw)) }
        let lanes = rh >= 256 ? 8 : 1
        mask.withUnsafeBufferPointer { maskPage in rgba.withUnsafeBufferPointer { page in spans.withUnsafeBufferPointer { spanBuffer in
        nonisolated(unsafe) let pixels = page.baseAddress!, masks = maskPage.baseAddress!, columns = spanBuffer.baseAddress!
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
        // Separable integer sums (exact): each canvas row first sums its page rows per column
        // (contiguous, vectorizable), then each canvas pixel sums its window of those columns.
        var columnSums = [Int32](repeating: 0, count: rw * 4)
        var columnHits = [UInt8](repeating: 0, count: rw)
        columnSums.withUnsafeMutableBufferPointer { sumBuffer in columnHits.withUnsafeMutableBufferPointer { hitBuffer in
        let sums = sumBuffer.baseAddress!, hits = hitBuffer.baseAddress!
        for y in (ph * lane / lanes)..<(ph * (lane + 1) / lanes) {
            let ya = y0 + y * rh / ph, yb = y0 + min(rh, ((y + 1) * rh + ph - 1) / ph)
            let first = pixels + (ya * width + x0) * 4, firstMask = masks + ya * width + x0
            for i in 0..<(rw * 4) { sums[i] = Int32(first[i]) }
            hits.update(from: firstMask, count: rw)
            for yy in (ya + 1)..<yb {
                let source = pixels + (yy * width + x0) * 4, sourceMask = masks + yy * width + x0
                for i in 0..<(rw * 4) { sums[i] &+= Int32(source[i]) }
                for i in 0..<rw { hits[i] |= sourceMask[i] }
            }
            let rowOut = (oy + y) * canvasWidth + ox
            for x in 0..<pw {
                let (xa, xb) = columns[x]
                var s0: Int32 = 0, s1: Int32 = 0, s2: Int32 = 0, hit: UInt8 = 0
                for xx in (xa - x0)..<(xb - x0) {
                    s0 &+= sums[xx * 4]; s1 &+= sums[xx * 4 + 1]; s2 &+= sums[xx * 4 + 2]
                    hit |= hits[xx]
                }
                let n = Int32((yb - ya) * (xb - xa)), c = rowOut + x
                out[c * 4] = UInt8((s0 + n / 2) / n)
                out[c * 4 + 1] = UInt8((s1 + n / 2) / n)
                out[c * 4 + 2] = UInt8((s2 + n / 2) / n)
                outMask[c] = hit
            }
        }
        } }
        }
        } } }
        } }
        for y in -pad..<(ph + pad) {
            // Interior rows only visit their side borders (sources are interior, so order is free).
            let inside = y >= 0 && y < ph
            for span in [-pad..<0, (inside ? pw : 0)..<(pw + pad)] {
                for x in span {
                    let c = (oy + y) * canvasWidth + ox + x
                    let s = (oy + min(ph - 1, max(0, y))) * canvasWidth + ox + min(pw - 1, max(0, x))
                    for k in 0..<4 { canvas[c * 4 + k] = canvas[s * 4 + k] }
                }
            }
        }
    }

    /// `mask.contains { $0 != 0 }`, 32 bytes per step.
    static func anyNonzero(_ mask: [UInt8]) -> Bool {
        mask.withUnsafeBytes { bytes in
            let count = bytes.count
            var index = 0
            while index + 32 <= count {
                let a = bytes.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                    | bytes.loadUnaligned(fromByteOffset: index + 8, as: UInt64.self)
                    | bytes.loadUnaligned(fromByteOffset: index + 16, as: UInt64.self)
                    | bytes.loadUnaligned(fromByteOffset: index + 24, as: UInt64.self)
                if a != 0 { return true }
                index += 32
            }
            while index < count { if bytes[index] != 0 { return true }; index += 1 }
            return false
        }
    }

    /// The whole page at the largest scale that fits the model side, or nil for an empty mask.
    static func wholePage(_ mask: [UInt8], width: Int, height: Int) -> Patch? {
        guard anyNonzero(mask) else { return nil }
        let scale = min(1, Double(side) / Double(max(width, height)))
        return Patch(rect: (0, 0, width, height), origin: (0, 0),
                     size: (min(side, max(1, Int(ceil(Double(width) * scale)))), min(side, max(1, Int(ceil(Double(height) * scale))))))
    }

    /// Fill + prediction into `output`. Returns the content size.
    private func predict(rgba: [UInt8], removal: [UInt8], width: Int, height: Int) throws -> (Int, Int) {
        let content = Self.fill(rgba: rgba, mask: removal, width: width, height: height, image: image, maskTensor: mask)
        let result = try autoreleasepool { try model.prediction(from: provider, options: options) }
        // Core ML may decline the backing (then the returned array holds the prediction).
        guard let raw = result.featureValue(for: "raw_rgb")?.multiArrayValue,
              raw.shape.map(\.intValue) == [1, 3, 1024, 1024], raw.dataType == .float16 else {
            throw Failure.modelContract
        }
        if raw.dataPointer != output.dataPointer {
            guard raw.strides == output.strides else { throw Failure.modelContract }
            output.dataPointer.copyMemory(from: raw.dataPointer, byteCount: 3 * Self.side * Self.side * 2)
        }
        return content
    }

    /// The tensor value of each byte level, kept (0..<256) then erased (`value * 0`: -0 below 128).
    private static let levels: [Float16] = (0..<512).map { index in
        let value = Float(index & 255) / Float(127.5) - Float(1)
        return Float16(value * (index < 256 ? 1 : 0))
    }

    /// Legacy `fillInputTensors` for a canvas that fits the model (masked RGB zeroed, edges
    /// extended). Returns the content size.
    static func fill(rgba: [UInt8], mask binaryMask: [UInt8], width: Int, height: Int,
                     image: MLMultiArray, maskTensor: MLMultiArray) -> (Int, Int) {
        precondition(width > 0 && height > 0 && width <= side && height <= side)
        let plane = side * side
        nonisolated(unsafe) let ip = image.dataPointer.assumingMemoryBound(to: Float16.self)
        nonisolated(unsafe) let mp = maskTensor.dataPointer.assumingMemoryBound(to: Float16.self)
        rgba.withUnsafeBufferPointer { pixelBuffer in
            binaryMask.withUnsafeBufferPointer { maskBuffer in
                nonisolated(unsafe) let pixels = pixelBuffer.baseAddress!
                nonisolated(unsafe) let masks = maskBuffer.baseAddress!
                let lanes = 8
                Self.levels.withUnsafeBufferPointer { levelBuffer in
                nonisolated(unsafe) let keptLevels = levelBuffer.baseAddress!, erasedLevels = keptLevels + 256
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    for y in (side * lane / lanes)..<(side * (lane + 1) / lanes) {
                        let row = min(y, height - 1) * width
                        for x in 0..<side {
                            let p = row + min(x, width - 1), t = y * side + x
                            let hit = x < width && y < height && masks[p] != 0
                            mp[t] = hit ? 1 : 0
                            let table = hit ? erasedLevels : keptLevels
                            for c in 0..<3 { ip[c * plane + t] = table[Int(pixels[p * 4 + c])] }
                        }
                    }
                }
                }
            }
        }
        return (width, height)
    }

    /// First nonzero index of `bytes[from..<to]` (or `to`), eight bytes per step over zero runs.
    @inline(__always) private static func skipZeros(_ bytes: UnsafePointer<UInt8>, from: Int, to: Int) -> Int {
        var index = from
        while index + 8 <= to && UnsafeRawPointer(bytes + index).loadUnaligned(as: UInt64.self) == 0 { index += 8 }
        while index < to && bytes[index] == 0 { index += 1 }
        return index
    }

    /// A prediction value as a [0, 1] level.
    @inline(__always) private static func sample(_ value: Float16) -> Double { Double((Float(value) + 1) / 2) }

    /// Bilinear restore of mask pixels only, within `region` (default: the page), read from the
    /// `content`-sized prediction at `origin`.
    static func scatter(into restored: UnsafeMutableBufferPointer<UInt8>, mask: [UInt8], width: Int, height: Int,
                        raw: MLMultiArray, content: (Int, Int), region: (Int, Int, Int, Int)? = nil,
                        origin: (Int, Int) = (0, 0)) throws {
        let (sw, sh) = content
        let (left, top, right, bottom) = region ?? (0, 0, width, height)
        let w = right - left, h = bottom - top
        let strides = raw.strides.map(\.intValue)
        let channel = strides[1], rowStride = strides[2], columnStride = strides[3]
        var taps = [(Int, Int, Double)](repeating: (0, 0, 0), count: w)
        for x in 0..<w {
            let sx = min(Float(sw - 1), max(0, (Float(x) + 0.5) * Float(sw) / Float(w) - 0.5))
            let x0 = Int(floor(sx)), x1 = min(sw - 1, x0 + 1)
            taps[x] = ((origin.0 + x0) * columnStride, (origin.0 + x1) * columnStride, Double(sx) - Double(x0))
        }
        nonisolated(unsafe) let values = UnsafePointer(raw.dataPointer.assumingMemoryBound(to: Float16.self))
        nonisolated(unsafe) let target = restored.baseAddress!
        var failed = false
        mask.withUnsafeBufferPointer { maskBuffer in
            taps.withUnsafeBufferPointer { tapBuffer in
                nonisolated(unsafe) let masks = maskBuffer.baseAddress!
                nonisolated(unsafe) let columns = tapBuffer.baseAddress!
                @Sendable func rows(_ firstRow: Int, _ lastRow: Int) -> Bool {
                    // Horizontal taps of a prediction row depend only on (row, x), and consecutive page
                    // rows share prediction rows: two cached rows (values + the row each x was made for).
                    let cache = UnsafeMutablePointer<Double>.allocate(capacity: 6 * w)
                    let stamps = UnsafeMutablePointer<Int>.allocate(capacity: 2 * w)
                    stamps.initialize(repeating: -1, count: 2 * w)
                    defer { cache.deallocate(); stamps.deallocate() }
                    var slotRows = (-1, -1)
                    for y in firstRow..<lastRow {
                        let row = (top + y) * width + left
                        var x = Self.skipZeros(masks + row, from: 0, to: w)
                        if x == w { continue }
                        let sy = min(Float(sh - 1), max(0, (Float(y) + 0.5) * Float(sh) / Float(h) - 0.5))
                        let y0 = Int(floor(sy)), y1 = min(sh - 1, y0 + 1), dy = Double(sy) - Double(y0)
                        let r0 = values + (origin.1 + y0) * rowStride, r1 = values + (origin.1 + y1) * rowStride
                        let ey = 1 - dy
                        let s0: Int
                        if slotRows.0 == y0 { s0 = 0 } else if slotRows.1 == y0 { s0 = 1 } else {
                            s0 = slotRows.0 == y1 ? 1 : 0
                            if s0 == 0 { slotRows.0 = y0 } else { slotRows.1 = y0 }
                        }
                        var s1 = s0
                        if y1 != y0 {
                            if slotRows.0 == y1 { s1 = 0 } else if slotRows.1 == y1 { s1 = 1 } else {
                                s1 = 1 - s0
                                if s1 == 0 { slotRows.0 = y1 } else { slotRows.1 = y1 }
                            }
                        }
                        let cache0 = cache + s0 * 3 * w, cache1 = cache + s1 * 3 * w
                        let stamps0 = stamps + s0 * w, stamps1 = stamps + s1 * w
                        while x < w {
                            if masks[row + x] == 0 { x = Self.skipZeros(masks + row, from: x, to: w); continue }
                            let (x0, x1, dx) = columns[x]
                            let ex = 1 - dx, o = (row + x) * 4
                            let upper = cache0 + x * 3, lower = cache1 + x * 3
                            if stamps0[x] != y0 {
                                for c in 0..<3 {
                                    let k = c * channel
                                    upper[c] = Self.sample(r0[k + x0]) * ex + Self.sample(r0[k + x1]) * dx
                                }
                                stamps0[x] = y0
                            }
                            if stamps1[x] != y1 {
                                for c in 0..<3 {
                                    let k = c * channel
                                    lower[c] = Self.sample(r1[k + x0]) * ex + Self.sample(r1[k + x1]) * dx
                                }
                                stamps1[x] = y1
                            }
                            for c in 0..<3 {
                                let selected = upper[c] * ey + lower[c] * dy
                                guard selected.isFinite else { return false }
                                target[o + c] = UInt8(floor(min(1, max(0, selected)) * 255 + 0.5))
                            }
                            target[o + 3] = 255
                            x += 1
                        }
                    }
                    return true
                }
                let lanes = h >= 64 ? 8 : 1
                let lock = NSLock()
                nonisolated(unsafe) var bad = false
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    if !rows(h * lane / lanes, h * (lane + 1) / lanes) { lock.lock(); bad = true; lock.unlock() }
                }
                failed = bad
            }
        }
        if failed { throw Failure.nonfinite }
    }
}

@available(iOS 18.0, macOS 15.0, *)
enum PipelineInpaint {
    /// Restores `mask` (page-size, nonzero = erase) with AOT. Pixels outside the mask are unchanged.
    static func restore(_ page: PipelinePage, mask: [UInt8], models: PipelineModels) async throws -> CGImage {
        guard PipelineAOTModel.anyNonzero(mask) else { return page.image }
        return try await restoreImage(PipelinePageRaster(page.image), mask: mask, models: models)
    }

    /// Restore of `raster` (see `PipelineAOTModel.restoreImage`) as an image, with one page copy.
    static func restoreImage(_ raster: PipelinePageRaster, mask: [UInt8], models: PipelineModels) async throws -> CGImage {
        guard mask.count == raster.width * raster.height else { throw PipelineAOTModel.Failure.maskSize }
        // The canvas is instance-free: building it before the hold keeps the instances on predictions.
        guard let canvas = try PipelineAOTModel.canvas(raster, removal: mask) else { return try raster.image() }
        return try await models.inpainters.with { model in
            try await model.executor.run { try model.restoreImage(raster, removal: mask, canvas: canvas) }
        }
    }
}
