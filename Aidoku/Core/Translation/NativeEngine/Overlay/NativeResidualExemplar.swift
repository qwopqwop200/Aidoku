import Foundation

extension NativeResidualProof {
    /// The original aidokuSourceExemplarFill Rust branch with its exact Float32
    /// texture ratio. The algorithm remains in kernels.rs; native memory replaces
    /// the WebAssembly heap without changing the donor/patch traversal.
    static func exemplarFill(rgba: [UInt8], width w: Int, height h: Int, mask: [UInt8],
                             blocked: [UInt8], foreground: [Double], surface: Surface) -> Exemplar? {
        guard w > 12, h > 12, w <= 131_072 / h, rgba.count == w * h * 4, mask.count == w * h,
              blocked.count == w * h, foreground.count >= 3, foreground.prefix(3).allSatisfy(\.isFinite),
              let coefficients = surface.coefficients, coefficients.count == 3,
              coefficients.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let n = w * h, erased = mask.reduce(0) { $0 + Int($1) }
        guard erased >= 32, erased <= 32_000 else { return nil }
        do {
            let input = try NativeKernelBuffer<UInt8>(values: rgba)
            let owned = try NativeKernelBuffer<UInt8>(values: mask)
            let forbidden = try NativeKernelBuffer<UInt8>(values: blocked)
            let fg = try NativeKernelBuffer<Double>(values: Array(foreground.prefix(3)))
            let coeff = try NativeKernelBuffer<Double>(values: coefficients.flatMap { $0 })
            let work = try NativeKernelBuffer<UInt8>(count: n * 4)
            let pending = try NativeKernelBuffer<UInt8>(count: n)
            let residual = try NativeKernelBuffer<Float>(count: n * 3)
            let filled = try NativeKernelBuffer<Float>(count: n * 3)
            let integral = try NativeKernelBuffer<Int32>(count: (w + 1) * (h + 1))
            let output = try NativeKernelBuffer<UInt8>(count: n * 4)
            let donors = try NativeKernelBuffer<Int32>(count: n)
            let cell = try NativeKernelBuffer<Double>(count: n)
            let gridX = try NativeKernelBuffer<Int32>(count: w)
            let gridY = try NativeKernelBuffer<Int32>(count: h)
            let stats = try NativeKernelBuffer<Double>(count: 7)
            let accepted = try NativeTranslationPixelKernels.exemplar_fill(
                rgba: input, w: Int32(w), h: Int32(h), mask: owned, forbidden: forbidden, fg: fg,
                coeff: coeff, erased: Int32(erased), work: work, pending: pending, residual: residual,
                filled: filled, integral: integral, output: output, donors: donors, cell: cell,
                grid_x: gridX, grid_y: gridY, stats: stats)
            if accepted == 0 { return nil }
            let values = filled.values, metrics = stats.values
            var squares = 0.0
            for i in 0..<n where mask[i] != 0 { squares += pow(Double(values[i * 3 + 1]), 2) }
            let ratio = sqrt((squares / Double(erased)) / (metrics[5] / metrics[6]))
            if ratio < 0.5 || ratio > 1.8 { return nil }
            return Exemplar(rgba: output.values, patches: metrics[0], maxError: metrics[1], textureRatio: ratio)
        } catch { return nil }
    }

    /// aidokuComponentExemplarFill. Four-neighbor components, stable raster
    /// order and the strict .65...1.5 texture ratio stay identical to the oracle.
    static func componentExemplarFill(rgba: [UInt8], width w: Int, height h: Int, mask: [UInt8],
                                      blocked: [UInt8], options: Options = Options()) -> Fill? {
        guard w > 0, h > 0, w <= 750_000 / h, rgba.count == w * h * 4,
              mask.count == w * h, blocked.count == w * h, let fg = options.sourceForeground else { return nil }
        let n = w * h
        struct Group { let points: [Int]; let l: Int; let t: Int; let r: Int; let b: Int }
        var seen = [UInt8](repeating: 0, count: n), groups: [Group] = []
        for start in 0..<n where mask[start] != 0 && seen[start] == 0 {
            var points = [start], l = w, t = h, r = 0, b = 0, head = 0
            seen[start] = 1
            while head < points.count {
                let i = points[head], x = i % w, y = i / w; head += 1
                l = min(l, x); r = max(r, x); t = min(t, y); b = max(b, y)
                let next = [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
                for j in next where j >= 0 && mask[j] != 0 && seen[j] == 0 { seen[j] = 1; points.append(j) }
            }
            if points.count > 32_000 || groups.count >= 32 { return nil }
            groups.append(Group(points: points, l: l, t: t, r: r, b: b))
        }
        if groups.isEmpty { return nil }
        var donorOptions = options; donorOptions.excludedMask = blocked
        let fallback = forcedDonorFill(rgba: rgba, width: w, height: h, mask: mask, options: donorOptions)
        let hasFallback = fallback?.rgba != nil
        var output = fallback?.rgba ?? rgba
        var patches = 0.0, maxError = 0.0, erased = 0, patchedPixels = 0, rayPixels = 0
        for g in groups {
            let l = max(0, g.l - 32), t = max(0, g.t - 32), r = min(w - 1, g.r + 32), b = min(h - 1, g.b + 32)
            let cw = r - l + 1, ch = b - t + 1, cn = cw * ch
            if cn > 131_072 || g.points.count < 32 {
                if !hasFallback { return nil }; rayPixels += g.points.count; continue
            }
            var crop = [UInt8](repeating: 0, count: cn * 4), target = [UInt8](repeating: 0, count: cn), forbidden = target
            for y in 0..<ch {
                for x in 0..<cw {
                    let i = (y + t) * w + x + l, j = y * cw + x
                    for c in 0..<4 { crop[j * 4 + c] = rgba[i * 4 + c] }
                    forbidden[j] = blocked[i] != 0 || mask[i] != 0 ? 1 : 0
                }
            }
            for i in g.points { let j = (i / w - t) * cw + i % w - l; target[j] = 1; forbidden[j] = 0 }
            guard let surface = sourceSurfaceQuality(rgba: crop, width: cw, height: ch, mask: target, blocked: forbidden),
                  let coefficients = surface.coefficients, coefficients.allSatisfy({ $0.allSatisfy(\.isFinite) }),
                  let filled = exemplarFill(rgba: crop, width: cw, height: ch, mask: target, blocked: forbidden,
                                            foreground: fg, surface: surface),
                  filled.maxError <= 18, filled.textureRatio >= 0.65, filled.textureRatio <= 1.5 else {
                if !hasFallback { return nil }; rayPixels += g.points.count; continue
            }
            patches += filled.patches; maxError = max(maxError, filled.maxError)
            for i in g.points {
                let j = (i / w - t) * cw + i % w - l
                for c in 0..<4 { output[i * 4 + c] = filled.rgba[j * 4 + c] }
                erased += 1; patchedPixels += 1
            }
        }
        if patchedPixels == 0 { return nil }
        erased += rayPixels
        var quality = Quality(); quality.safe = true; quality.erased = erased
        quality.components = groups.count; quality.patches = patches; quality.maxError = maxError
        quality.patchedPixels = patchedPixels; quality.rayPixels = rayPixels; quality.donorQuality = hasFallback ? fallback.map { [$0.quality] } : nil
        return Fill(rgba: output, method: "component-matched-patches", quality: quality)
    }
}
