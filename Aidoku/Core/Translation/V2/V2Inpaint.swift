import CoreGraphics
@preconcurrency import CoreML
import Foundation

// S7: AOT-GAN 1024 FP16 restoration of the S6 removal mask.
//
// Transport arithmetic is the legacy NativeResidentAOT seam: integer-area
// downscale of the whole page into the top-left of a 1024 canvas (any-hit
// binary mask, masked RGB zeroed, edge-extended padding), one prediction,
// then clamped half-pixel bilinear upsampling of `raw_rgb` written ONLY at
// mask pixels. Every pixel outside the mask is byte-identical to the input.
// The legacy tensor caches, raw replay, prediction budget and alpha audit
// are not used by V2.

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
    /// Last restore's phase timings in ms (fill, predict, scatter); diagnostics only.
    private(set) var lastPhases: [Double] = [0, 0, 0]

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
    }

    /// Synchronous whole-page restore (legacy transport); call through `executor`.
    /// `removal` is page-sized, nonzero = erase.
    func restore(_ raster: V2PageRaster, removal: [UInt8]) throws -> V2PageRaster {
        guard removal.count == raster.width * raster.height else { throw Failure.maskSize }
        guard removal.contains(where: { $0 != 0 }) else { return raster }
        var restored = raster
        try restoreInPlace(&restored, removal: removal)
        return restored
    }

    /// Restores one raster (page or crop) in place; only nonzero `removal` pixels change.
    func restoreInPlace(_ raster: inout V2PageRaster, removal: [UInt8]) throws {
        let width = raster.width, height = raster.height
        let t0 = DispatchTime.now().uptimeNanoseconds
        let content = Self.fill(rgba: raster.rgba, mask: removal, width: width, height: height,
                                image: image, maskTensor: mask)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let output = try autoreleasepool { try model.prediction(from: provider) }
        let t2 = DispatchTime.now().uptimeNanoseconds
        defer {
            let t3 = DispatchTime.now().uptimeNanoseconds
            lastPhases = [Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6, Double(t3 - t2) / 1e6]
        }
        guard let raw = output.featureValue(for: "raw_rgb")?.multiArrayValue,
              raw.shape.map(\.intValue) == [1, 3, 1024, 1024], raw.dataType == .float16 else {
            throw Failure.modelContract
        }
        try raster.rgba.withUnsafeMutableBufferPointer { pixels in
            try Self.scatter(into: pixels, mask: removal, width: width, height: height, raw: raw, content: content)
        }
    }

    /// Restores one window of the page: crop, native-resolution AOT when the
    /// window fits 1024. Every mask pixel of the crop is a hole for the model;
    /// the caller writes back only `owned` pixels (nonzero).
    func restore(window: V2Inpaint.Window, page raster: V2PageRaster, removal: [UInt8]) throws
        -> (crop: V2PageRaster, owned: [UInt8]) {
        let r = window.rect
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height), page = raster.width
        var crop = V2PageRaster(width: w, height: h, rgba: [UInt8](repeating: 0, count: w * h * 4))
        var cropMask = [UInt8](repeating: 0, count: w * h)
        var owned = [UInt8](repeating: 0, count: w * h)
        raster.rgba.withUnsafeBufferPointer { source in
            crop.rgba.withUnsafeMutableBufferPointer { target in
                for y in 0..<h {
                    (target.baseAddress! + y * w * 4).update(from: source.baseAddress! + ((y0 + y) * page + x0) * 4, count: w * 4)
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w where removal[(y0 + y) * page + x0 + x] != 0 {
                cropMask[y * w + x] = 255
                let p = CGPoint(x: x0 + x, y: y0 + y)
                if window.owned.contains(where: { $0.contains(p) }) { owned[y * w + x] = 255 }
            }
        }
        try restoreInPlace(&crop, removal: cropMask)
        return (crop, owned)
    }

    /// Legacy `fillInputTensors` with 4-component input. Returns the content size.
    static func fill(rgba: [UInt8], mask binaryMask: [UInt8], width: Int, height: Int,
                     image: MLMultiArray, maskTensor: MLMultiArray) -> (Int, Int) {
        let plane = side * side
        let scale = min(1, Double(side) / Double(max(width, height)))
        let sw = min(side, max(1, Int(ceil(Double(width) * scale))))
        let sh = min(side, max(1, Int(ceil(Double(height) * scale))))
        let ip = image.dataPointer.assumingMemoryBound(to: Float16.self)
        let mp = maskTensor.dataPointer.assumingMemoryBound(to: Float16.self)
        let horizontal = (0..<sw).map { x in (x * width / sw, min(width, ((x + 1) * width + sw - 1) / sw)) }
        var bottom = [Float16](repeating: 0, count: sh < side ? sw * 3 : 0)
        rgba.withUnsafeBufferPointer { pixelBuffer in
            binaryMask.withUnsafeBufferPointer { maskBuffer in
                bottom.withUnsafeMutableBufferPointer { bottomBuffer in
                    nonisolated(unsafe) let pixels = pixelBuffer.baseAddress!
                    nonisolated(unsafe) let masks = maskBuffer.baseAddress!
                    nonisolated(unsafe) let saved = bottomBuffer.baseAddress
                    nonisolated(unsafe) let ip = ip
                    nonisolated(unsafe) let mp = mp
                    @Sendable func rows(_ first: Int, _ last: Int) {
                        for y in first..<last {
                            let y0 = y * height / sh, y1 = min(height, ((y + 1) * height + sh - 1) / sh)
                            let rowOffset = y * side
                            let saveBottom = y == sh - 1 && sh < side
                            var edge: (Float16, Float16, Float16) = (0, 0, 0)
                            for x in 0..<sw {
                                let (x0, x1) = horizontal[x]
                                var sums = (0, 0, 0)
                                var union: UInt8 = 0
                                for yy in y0..<y1 {
                                    for xx in x0..<x1 {
                                        let p = yy * width + xx
                                        let color = pixels + p * 4
                                        sums.0 &+= Int(color[0])
                                        sums.1 &+= Int(color[1])
                                        sums.2 &+= Int(color[2])
                                        union |= masks[p]
                                    }
                                }
                                let hit = union != 0
                                let count = Float((y1 - y0) * (x1 - x0)), p = rowOffset + x
                                let n0 = (Float(sums.0) / count) / Float(127.5) - Float(1)
                                let n1 = (Float(sums.1) / count) / Float(127.5) - Float(1)
                                let n2 = (Float(sums.2) / count) / Float(127.5) - Float(1)
                                mp[p] = hit ? 1 : 0
                                ip[p] = Float16(n0 * (hit ? 0 : 1))
                                ip[plane + p] = Float16(n1 * (hit ? 0 : 1))
                                ip[2 * plane + p] = Float16(n2 * (hit ? 0 : 1))
                                if saveBottom {
                                    saved![x] = Float16(n0); saved![sw + x] = Float16(n1); saved![2 * sw + x] = Float16(n2)
                                }
                                if x == sw - 1 { edge = (Float16(n0), Float16(n1), Float16(n2)) }
                            }
                            for x in sw..<side {
                                let p = rowOffset + x
                                mp[p] = 0
                                ip[p] = edge.0; ip[plane + p] = edge.1; ip[2 * plane + p] = edge.2
                            }
                        }
                    }
                    let lanes = 8
                    DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                        rows(sh * lane / lanes, sh * (lane + 1) / lanes)
                    }
                }
            }
        }
        for y in sh..<side {
            let rowOffset = y * side
            for x in 0..<side {
                let p = rowOffset + x, tx = min(x, sw - 1)
                mp[p] = 0
                ip[p] = bottom[tx]; ip[plane + p] = bottom[sw + tx]; ip[2 * plane + p] = bottom[2 * sw + tx]
            }
        }
        return (sw, sh)
    }

    /// Legacy `scatter`: bilinear restore of mask pixels only (RGBA, alpha untouched).
    static func scatter(into restored: UnsafeMutableBufferPointer<UInt8>, mask: [UInt8], width w: Int, height h: Int,
                        raw: MLMultiArray, content: (Int, Int)) throws {
        let (sw, sh) = content
        let strides = raw.strides.map(\.intValue), values = raw.dataPointer.assumingMemoryBound(to: Float16.self)
        func sample(_ c: Int, _ x: Int, _ y: Int) -> Double {
            Double((Float(values[c * strides[1] + y * strides[2] + x * strides[3]]) + 1) / 2)
        }
        for y in 0..<h {
            let row = y * w
            var first = 0
            while first < w && mask[row + first] == 0 { first += 1 }
            if first == w { continue }
            let sy = min(Float(sh - 1), max(0, (Float(y) + 0.5) * Float(sh) / Float(h) - 0.5))
            let y0 = Int(floor(sy)), y1 = min(sh - 1, y0 + 1), dy = Double(sy) - Double(y0)
            for x in first..<w where mask[row + x] != 0 {
                let sx = min(Float(sw - 1), max(0, (Float(x) + 0.5) * Float(sw) / Float(w) - 0.5))
                let x0 = Int(floor(sx)), x1 = min(sw - 1, x0 + 1), dx = Double(sx) - Double(x0)
                for c in 0..<3 {
                    let top = sample(c, x0, y0) * (1 - dx) + sample(c, x1, y0) * dx
                    let bottom = y1 == y0 ? top : sample(c, x0, y1) * (1 - dx) + sample(c, x1, y1) * dx
                    let selected = top * (1 - dy) + bottom * dy
                    guard selected.isFinite else { throw Failure.nonfinite }
                    restored[(row + x) * 4 + c] = UInt8(floor(min(1, max(0, selected)) * 255 + 0.5))
                }
                restored[(row + x) * 4 + 3] = 255
            }
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
enum V2Inpaint {
    /// One AOT prediction: a page window and the mask components it owns.
    struct Window: Sendable, Equatable {
        var rect: CGRect
        var owned: [CGRect]
    }

    /// wholePage: legacy transport (whole page downscaled into 1024).
    /// maskBounds: one prediction on the padded mask bounding box (less downscale, smaller fill/scatter).
    /// windows: native-resolution 1024 windows per mask cluster (several predictions).
    enum Mode: String, Sendable, CaseIterable { case wholePage, maskBounds, windows }

    /// Default restore mode for the pipeline.
    static let mode: Mode = .wholePage
    static let cell = 16
    static let contextPadding = 48

    /// Mask components (connected on a 16 px grid after `contextPadding`
    /// dilation) covered by native-resolution windows of at most 1024 px.
    /// Pages that fit 1024 always use one whole-page window.
    static func plan(mask: [UInt8], width: Int, height: Int) -> [Window] {
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        let side = V2AOTModel.side
        if width <= side && height <= side { return mask.contains { $0 != 0 } ? [Window(rect: page, owned: [page])] : [] }
        let gw = (width + cell - 1) / cell, gh = (height + cell - 1) / cell
        var occupied = [Bool](repeating: false, count: gw * gh)
        for y in 0..<height {
            let row = y * width, gy = y / cell
            for x in 0..<width where mask[row + x] != 0 { occupied[gy * gw + x / cell] = true }
        }
        let pad = (contextPadding + cell - 1) / cell
        var dilated = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw where occupied[gy * gw + gx] {
                for yy in max(0, gy - pad)...min(gh - 1, gy + pad) {
                    for xx in max(0, gx - pad)...min(gw - 1, gx + pad) { dilated[yy * gw + xx] = true }
                }
            }
        }
        // Connected components of the dilated grid; each keeps the bounds of its real mask cells.
        var label = [Int](repeating: -1, count: gw * gh)
        var components: [CGRect] = []
        for start in 0..<(gw * gh) where dilated[start] && label[start] < 0 {
            var stack = [start]
            label[start] = components.count
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            while let c = stack.popLast() {
                let cx = c % gw, cy = c / gw
                if occupied[c] { minX = min(minX, cx); minY = min(minY, cy); maxX = max(maxX, cx); maxY = max(maxY, cy) }
                for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
                where nx >= 0 && ny >= 0 && nx < gw && ny < gh && dilated[ny * gw + nx] && label[ny * gw + nx] < 0 {
                    label[ny * gw + nx] = components.count
                    stack.append(ny * gw + nx)
                }
            }
            guard maxX >= 0 else { continue }
            components.append(CGRect(x: minX * cell, y: minY * cell, width: (maxX - minX + 1) * cell,
                                     height: (maxY - minY + 1) * cell).intersection(page))
        }
        components.sort { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        var windows: [Window] = []
        var covered = [Bool](repeating: false, count: components.count)
        for (index, component) in components.enumerated() where !covered[index] {
            let padded = component.insetBy(dx: -CGFloat(contextPadding), dy: -CGFloat(contextPadding)).intersection(page)
            var rect: CGRect
            if padded.width <= CGFloat(side) && padded.height <= CGFloat(side) {
                // Widest native context: a 1024 window centered on the component.
                let w = min(CGFloat(side), page.width), h = min(CGFloat(side), page.height)
                let x = min(max(0, padded.midX - w / 2), page.width - w)
                let y = min(max(0, padded.midY - h / 2), page.height - h)
                rect = CGRect(x: x, y: y, width: w, height: h).integral.intersection(page)
            } else {
                rect = padded.integral
            }
            var owned: [CGRect] = []
            for other in index..<components.count where !covered[other] && rect.contains(components[other]) {
                covered[other] = true
                owned.append(components[other])
            }
            if owned.isEmpty { owned = [component]; covered[index] = true; rect = rect.union(component) }
            windows.append(Window(rect: rect, owned: owned))
        }
        return windows
    }

    /// One window: the mask bounding box padded by `boundsPadding`, clipped to the page.
    static let boundsPadding = 96

    static func boundsWindow(mask: [UInt8], width: Int, height: Int) -> Window? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            var first = -1, last = -1
            for x in 0..<width where mask[row + x] != 0 { if first < 0 { first = x }; last = x }
            guard first >= 0 else { continue }
            minX = min(minX, first); maxX = max(maxX, last); minY = min(minY, y); maxY = y
        }
        guard maxX >= 0 else { return nil }
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            .insetBy(dx: -CGFloat(boundsPadding), dy: -CGFloat(boundsPadding)).integral.intersection(page)
        return Window(rect: rect, owned: [rect])
    }

    /// Restores `mask` (page-size, nonzero = erase) with AOT. Pixels outside the mask are unchanged.
    static func restore(_ page: V2Page, mask: [UInt8], models: V2Models) async throws -> CGImage {
        guard mask.contains(where: { $0 != 0 }) else { return page.image }
        return try await restore(V2PageRaster(page.image), mask: mask, models: models).image()
    }

    static func restore(_ raster: V2PageRaster, mask: [UInt8], models: V2Models,
                        mode: Mode = V2Inpaint.mode) async throws -> V2PageRaster {
        guard mask.count == raster.width * raster.height else { throw V2AOTModel.Failure.maskSize }
        guard mask.contains(where: { $0 != 0 }) else { return raster }
        switch mode {
        case .wholePage:
            return try await models.inpainters.with { model in
                try await model.executor.run { try model.restore(raster, removal: mask) }
            }
        case .maskBounds, .windows:
            let windows = mode == .windows ? plan(mask: mask, width: raster.width, height: raster.height)
                : boundsWindow(mask: mask, width: raster.width, height: raster.height).map { [$0] } ?? []
            // Windows own disjoint mask pixels, so they run concurrently on the pool.
            let results = try await withThrowingTaskGroup(of: (Int, V2PageRaster, [UInt8]).self) { group in
                for (index, window) in windows.enumerated() {
                    group.addTask {
                        try await models.inpainters.with { model in
                            try await model.executor.run {
                                let result = try model.restore(window: window, page: raster, removal: mask)
                                return (index, result.crop, result.owned)
                            }
                        }
                    }
                }
                var collected: [(Int, V2PageRaster, [UInt8])] = []
                for try await item in group { collected.append(item) }
                return collected
            }
            var page = raster
            page.rgba.withUnsafeMutableBufferPointer { target in
                for (index, crop, owned) in results {
                    let r = windows[index].rect, x0 = Int(r.minX), y0 = Int(r.minY), w = crop.width
                    for y in 0..<crop.height {
                        for x in 0..<w where owned[y * w + x] != 0 {
                            let to = ((y0 + y) * raster.width + x0 + x) * 4, from = (y * w + x) * 4
                            for c in 0..<4 { target[to + c] = crop.rgba[from + c] }
                        }
                    }
                }
            }
            return page
        }
    }
}
