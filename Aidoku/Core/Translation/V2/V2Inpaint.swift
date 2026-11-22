import CoreGraphics
@preconcurrency import CoreML
import Foundation

// S7: AOT-GAN 1024 FP16 restoration of the S6 removal mask, one prediction per page. Mask regions
// are packed as a mosaic into the 1024 canvas (native resolution when they fit), and the bilinear
// upsampled prediction is written only at mask pixels; every other pixel is unchanged.

@available(iOS 18.0, macOS 15.0, *)
final class V2AOTModel: @unchecked Sendable {
    static let resourceName = "AOT-1024-FP16"
    static let side = 1024

    enum Failure: Error { case modelContract, maskSize, nonfinite }

    let model: MLModel
    /// Input tensors are reused, so predictions are serialized on this executor.
    let executor = V2SerialExecutor(label: "Aidoku.V2.AOT")
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

    /// Synchronous restore of `removal` (page-sized, nonzero = erase); call through `executor`.
    func restoreImage(_ raster: V2PageRaster, removal: [UInt8]) throws -> CGImage {
        guard removal.count == raster.width * raster.height else { throw Failure.maskSize }
        let width = raster.width, height = raster.height
        var data = raster.rgba.withUnsafeBytes { Data($0) }
        let patches = Self.mosaic(removal, width: width, height: height)
        guard let first = patches.first else { return try V2PageRaster.image(data, width: width, height: height) }
        // The single unpacked patch at the origin needs no `pad` border.
        let pad = first.origin == (0, 0) ? 0 : Self.pad
        let cw = patches.map { $0.origin.0 + $0.size.0 }.max()! + pad
        let ch = patches.map { $0.origin.1 + $0.size.1 }.max()! + pad
        var canvas = [UInt8](repeating: 255, count: cw * ch * 4)
        var canvasMask = [UInt8](repeating: 0, count: cw * ch)
        for patch in patches {
            Self.downscale(raster.rgba, mask: removal, width: width, patch: patch, pad: pad,
                           into: &canvas, canvasMask: &canvasMask, canvasWidth: cw)
        }
        let content = try predict(rgba: canvas, removal: canvasMask, width: cw, height: ch)
        guard content == (cw, ch) else { throw Failure.modelContract }
        try data.withUnsafeMutableBytes { bytes in
            for patch in patches {
                try Self.scatter(into: bytes.bindMemory(to: UInt8.self), mask: removal, width: width, height: height,
                                 raw: output, content: patch.size, region: patch.rect, origin: patch.origin)
            }
        }
        return try V2PageRaster.image(data, width: width, height: height)
    }

    /// A page rect (x0, y0, x1, y1; exclusive) drawn at `origin` of the model canvas at `size`.
    struct Patch {
        var rect: (Int, Int, Int, Int)
        var origin: (Int, Int)
        var size: (Int, Int)
    }

    /// Context margins tried, widest first, and the replicated border around each packed patch.
    static let margins = [384, 256, 160, 96, 64]
    static let pad = 16

    /// Integer-area downscale of `patch.rect` into the canvas (any-hit mask), edges replicated `pad` px.
    static func downscale(_ rgba: [UInt8], mask: [UInt8], width: Int, patch: Patch, pad: Int,
                          into canvas: inout [UInt8], canvasMask: inout [UInt8], canvasWidth: Int) {
        let (x0, y0, x1, y1) = patch.rect, (pw, ph) = patch.size, (ox, oy) = patch.origin
        let rw = x1 - x0, rh = y1 - y0
        // Disjoint canvas rows per lane; the union patch averages up to the whole page.
        canvas.withUnsafeMutableBufferPointer { canvasBuffer in canvasMask.withUnsafeMutableBufferPointer { maskBuffer in
        nonisolated(unsafe) let out = canvasBuffer.baseAddress!, outMask = maskBuffer.baseAddress!
        let lanes = rh >= 256 ? 8 : 1
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
        for y in (ph * lane / lanes)..<(ph * (lane + 1) / lanes) {
            let ya = y0 + y * rh / ph, yb = y0 + min(rh, ((y + 1) * rh + ph - 1) / ph)
            for x in 0..<pw {
                let xa = x0 + x * rw / pw, xb = x0 + min(rw, ((x + 1) * rw + pw - 1) / pw)
                var sums = (0, 0, 0), hit: UInt8 = 0
                for yy in ya..<yb {
                    for xx in xa..<xb {
                        let p = yy * width + xx
                        sums.0 += Int(rgba[p * 4]); sums.1 += Int(rgba[p * 4 + 1]); sums.2 += Int(rgba[p * 4 + 2])
                        hit |= mask[p]
                    }
                }
                let n = (yb - ya) * (xb - xa), c = (oy + y) * canvasWidth + ox + x
                out[c * 4] = UInt8((sums.0 + n / 2) / n)
                out[c * 4 + 1] = UInt8((sums.1 + n / 2) / n)
                out[c * 4 + 2] = UInt8((sums.2 + n / 2) / n)
                outMask[c] = hit
            }
        }
        }
        } }
        for y in -pad..<(ph + pad) {
            let inside = y >= 0 && y < ph
            for x in -pad..<(pw + pad) where !inside || x < 0 || x >= pw {
                let c = (oy + y) * canvasWidth + ox + x
                let s = (oy + min(ph - 1, max(0, y))) * canvasWidth + ox + min(pw - 1, max(0, x))
                for k in 0..<4 { canvas[c * 4 + k] = canvas[s * 4 + k] }
            }
        }
    }

    /// Merged 16-px mask cells plus a context margin, shelf-packed into one model side at native
    /// resolution (widest margin that fits), else at the largest 0.9-step scale, else the union.
    static func mosaic(_ mask: [UInt8], width: Int, height: Int) -> [Patch] {
        let cell = 16
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var occupied: [Int] = []
        var seen = [Bool](repeating: false, count: columns * rows)
        for y in 0..<height {
            let row = y * width, cellRow = (y / cell) * columns
            for x in 0..<width where mask[row + x] != 0 && !seen[cellRow + x / cell] {
                seen[cellRow + x / cell] = true
                occupied.append(cellRow + x / cell)
            }
        }
        guard !occupied.isEmpty else { return [] }
        func merged(_ margin: Int) -> [(Int, Int, Int, Int)] {
            var merged: [(Int, Int, Int, Int)] = []
            for c in occupied {
                let x = (c % columns) * cell, y = (c / columns) * cell
                var r = (max(0, x - margin), max(0, y - margin), min(width, x + cell + margin), min(height, y + cell + margin))
                while let i = merged.firstIndex(where: { r.0 < $0.2 && $0.0 < r.2 && r.1 < $0.3 && $0.1 < r.3 }) {
                    let m = merged.remove(at: i)
                    r = (min(m.0, r.0), min(m.1, r.1), max(m.2, r.2), max(m.3, r.3))
                }
                merged.append(r)
            }
            return merged
        }
        func size(_ r: (Int, Int, Int, Int), _ scale: Double) -> (Int, Int) {
            (min(side, max(1, Int(ceil(Double(r.2 - r.0) * scale)))), min(side, max(1, Int(ceil(Double(r.3 - r.1) * scale)))))
        }
        func pack(_ rects: [(Int, Int, Int, Int)], _ scale: Double) -> [Patch]? {
            var patches: [Patch] = []
            var x = 0, y = 0, shelf = 0
            for r in rects.sorted(by: { $0.3 - $0.1 > $1.3 - $1.1 }) {
                let s = size(r, scale), w = s.0 + 2 * pad, h = s.1 + 2 * pad
                if x + w > side { x = 0; y += shelf; shelf = 0 }
                guard y + h <= side, w <= side else { return nil }
                patches.append(Patch(rect: r, origin: (x + pad, y + pad), size: s))
                x += w; shelf = max(shelf, h)
            }
            return patches
        }
        for margin in margins {
            if let patches = pack(merged(margin), 1) { return patches }
        }
        let rects = merged(margins.last!)
        let union = rects.dropFirst().reduce(rects[0]) { (min($0.0, $1.0), min($0.1, $1.1), max($0.2, $1.2), max($0.3, $1.3)) }
        let unionScale = min(1, Double(side) / Double(max(union.2 - union.0, union.3 - union.1)))
        var scale = 0.9
        while scale > unionScale && rects.count > 1 {
            if let patches = pack(rects, scale) { return patches }
            scale *= 0.9
        }
        return [Patch(rect: union, origin: (0, 0), size: size(union, unionScale))]
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
                DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                    for y in (side * lane / lanes)..<(side * (lane + 1) / lanes) {
                        let row = min(y, height - 1) * width
                        for x in 0..<side {
                            let p = row + min(x, width - 1), t = y * side + x
                            let hit = x < width && y < height && masks[p] != 0
                            mp[t] = hit ? 1 : 0
                            for c in 0..<3 {
                                let value = Float(pixels[p * 4 + c]) / Float(127.5) - Float(1)
                                ip[c * plane + t] = Float16(value * (hit ? 0 : 1))
                            }
                        }
                    }
                }
            }
        }
        return (width, height)
    }

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
                    for y in firstRow..<lastRow {
                        let row = (top + y) * width + left
                        var first = 0
                        while first < w && masks[row + first] == 0 { first += 1 }
                        if first == w { continue }
                        let sy = min(Float(sh - 1), max(0, (Float(y) + 0.5) * Float(sh) / Float(h) - 0.5))
                        let y0 = Int(floor(sy)), y1 = min(sh - 1, y0 + 1), dy = Double(sy) - Double(y0)
                        let top0 = (origin.1 + y0) * rowStride, top1 = (origin.1 + y1) * rowStride
                        for x in first..<w where masks[row + x] != 0 {
                            let (x0, x1, dx) = columns[x]
                            for c in 0..<3 {
                                let base = values + c * channel
                                func sample(_ offset: Int) -> Double { Double((Float(base[offset]) + 1) / 2) }
                                let upper = sample(top0 + x0) * (1 - dx) + sample(top0 + x1) * dx
                                let lower = y1 == y0 ? upper : sample(top1 + x0) * (1 - dx) + sample(top1 + x1) * dx
                                let selected = upper * (1 - dy) + lower * dy
                                guard selected.isFinite else { return false }
                                target[(row + x) * 4 + c] = UInt8(floor(min(1, max(0, selected)) * 255 + 0.5))
                            }
                            target[(row + x) * 4 + 3] = 255
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
enum V2Inpaint {
    /// Restores `mask` (page-size, nonzero = erase) with AOT. Pixels outside the mask are unchanged.
    static func restore(_ page: V2Page, mask: [UInt8], models: V2Models) async throws -> CGImage {
        guard mask.contains(where: { $0 != 0 }) else { return page.image }
        return try await restoreImage(V2PageRaster(page.image), mask: mask, models: models)
    }

    /// Restore of `raster` (see `V2AOTModel.restoreImage`) as an image, with one page copy.
    static func restoreImage(_ raster: V2PageRaster, mask: [UInt8], models: V2Models) async throws -> CGImage {
        guard mask.count == raster.width * raster.height else { throw V2AOTModel.Failure.maskSize }
        guard mask.contains(where: { $0 != 0 }) else { return try raster.image() }
        return try await models.inpainters.with { model in
            try await model.executor.run { try model.restoreImage(raster, removal: mask) }
        }
    }
}
