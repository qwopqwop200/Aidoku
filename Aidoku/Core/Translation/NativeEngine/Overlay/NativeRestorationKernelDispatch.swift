import Foundation
import CoreGraphics

extension NativeRestorationPixels {
    static func nativeHarmonicFill(_ p: Self, mask: [UInt8], blocked: [UInt8], seed: Self,
    accelerated: Bool, queue: [Int]) -> Self? {
        do {
            let input = try NativeKernelBuffer<UInt8>(values: (0..<p.rgba.count).map { index in
                mask[index / 4] != 0 ? seed.rgba[index] : p.rgba[index]
            })
            let queueBuffer = try NativeKernelBuffer<Int32>(values: queue.map(Int32.init))
            let blockedBuffer = try NativeKernelBuffer<UInt8>(values: blocked)
            let maskBuffer = try NativeKernelBuffer<UInt8>(values: mask)
            let work = try NativeKernelBuffer<Float>(count: p.count * 3)
            let links = try NativeKernelBuffer<UInt8>(count: queue.count)
            do {
                try NativeTranslationPixelKernels.harmonic_fill(
                p: input, w: Int32(p.width), n: Int32(p.count), queue: queueBuffer, tail: Int32(queue.count),
                blocked: blockedBuffer, paint: maskBuffer, accelerated: accelerated ? 1 : 0, work: work, links: links
                )
                let values = work.values
                var output = Self(width: p.width, height: p.height)
                for index in queue { output.paint(index, NativeRestorationRGB((0..<3).map { Double(values[index * 3 + $0]) })) }
                return output
            } catch { return nil }
        } catch { return nil }
    }

    static func nativeExemplarFill(_ p: Self, mask: [UInt8], blocked: [UInt8], palette: Palette, surface: Surface) -> Self? {
        do {
            let erased = mask.reduce(0) { $0 + Int($1) }
            guard erased >= 32, erased <= 32_000, p.count <= 131_072, p.width > 12, p.height > 12 else { return nil }
            let input = try NativeKernelBuffer<UInt8>(values: p.rgba)
            let maskBuffer = try NativeKernelBuffer<UInt8>(values: mask)
            let forbidden = try NativeKernelBuffer<UInt8>(values: blocked)
            let foreground = try NativeKernelBuffer<Double>(values: palette.foreground.channels)
            let coefficients = try NativeKernelBuffer<Double>(values: surface.coefficients.flatMap { $0 })
            let work = try NativeKernelBuffer<UInt8>(count: p.count * 4)
            let pending = try NativeKernelBuffer<UInt8>(count: p.count)
            let residual = try NativeKernelBuffer<Float>(count: p.count * 3)
            let filled = try NativeKernelBuffer<Float>(count: p.count * 3)
            let integral = try NativeKernelBuffer<Int32>(count: (p.width + 1) * (p.height + 1))
            let output = try NativeKernelBuffer<UInt8>(count: p.count * 4)
            let donors = try NativeKernelBuffer<Int32>(count: p.count)
            let cell = try NativeKernelBuffer<Double>(count: p.count)
            let gridX = try NativeKernelBuffer<Int32>(count: p.width)
            let gridY = try NativeKernelBuffer<Int32>(count: p.height)
            let stats = try NativeKernelBuffer<Double>(count: 7)
            do {
                let accepted = try NativeTranslationPixelKernels.exemplar_fill(
                rgba: input, w: Int32(p.width), h: Int32(p.height), mask: maskBuffer, forbidden: forbidden,
                fg: foreground, coeff: coefficients, erased: Int32(erased), work: work, pending: pending,
                residual: residual, filled: filled, integral: integral, output: output, donors: donors,
                cell: cell, grid_x: gridX, grid_y: gridY, stats: stats
                )
                guard accepted != 0 else { return nil }
                let values = filled.values, measurements = stats.values
                let squares = (0..<p.count).filter { mask[$0] != 0 }.reduce(0.0) { sum, index in
                    let value = Double(values[index * 3 + 1]); return sum + value * value
                }
                let ratio = sqrt((squares / Double(erased)) / (measurements[5] / measurements[6]))
                guard ratio >= 0.5, ratio <= 1.8 else { return nil }
                var result = Self(width: p.width, height: p.height); result.rgba = output.values
                return result
            } catch { return nil }
        } catch { return nil }
    }

    static func nativePixelClasses(_ p: Self, palette: Palette, tolerance: Double, separation: Double,
    matched: Bool, secondaryInk: NativeRestorationRGB? = nil) -> (raw: [UInt8], observed: [UInt8], protected: [UInt8])? {
        do {
            let input = try NativeKernelBuffer<UInt8>(values: p.rgba)
            let colors = try NativeKernelBuffer<Double>(values: palette.foreground.channels + palette.background.channels +
            (secondaryInk?.channels ?? [0, 0, 0]) + (palette.stroke?.channels ?? [0, 0, 0]))
            let raw = try NativeKernelBuffer<UInt8>(count: p.count), observed = try NativeKernelBuffer<UInt8>(count: p.count)
            let protected = try NativeKernelBuffer<UInt8>(count: p.count)
            let flags: Int32 = (secondaryInk != nil ? 1 : 0) | (palette.stroke != nil ? 2 : 0) | (matched ? 4 : 0) | (palette.background.minimum >= 140 ? 8 : 0)
            do {
                try NativeTranslationPixelKernels.pixel_classes(
                rgba: input, n: Int32(p.count), colors: colors, flags: flags, ink_tolerance: tolerance,
                halo_separation: max(32, separation * 0.55), raw: raw, observed: observed, protected: protected
                )
                return (raw.values, observed.values, protected.values)
            } catch { return nil }
        } catch { return nil }
    }
    static func nativeEnclosedPaper(_ p: Self, box: CGRect, auxiliary: [CGRect], excluded: [CGRect]) -> Self? {
        do {
            let input = try NativeKernelBuffer<UInt8>(values: p.rgba)
            let rects = try NativeKernelBuffer<Double>(values: (auxiliary + excluded).flatMap {
                [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)]
            })
            let paper = try NativeKernelBuffer<UInt8>(count: p.count), seen = try NativeKernelBuffer<UInt8>(count: p.count)
            let queue = try NativeKernelBuffer<Int32>(count: p.count), best = try NativeKernelBuffer<Int32>(count: p.count)
            let region = try NativeKernelBuffer<UInt8>(count: p.count), outside = try NativeKernelBuffer<UInt8>(count: p.count)
            let points = try NativeKernelBuffer<Int32>(count: p.count), meta = try NativeKernelBuffer<Int32>(count: p.count * 2)
            let output = try NativeKernelBuffer<UInt8>(count: p.count * 4), safe = try NativeKernelBuffer<UInt8>(count: p.count)
            let stats = try NativeKernelBuffer<Int32>(count: 3)
            do {
                let accepted = try NativeTranslationPixelKernels.enclosed_paper(
                rgba: input, w: Int32(p.width), h: Int32(p.height), l: Int32(max(0, floor(box.minX))),
                t: Int32(max(0, floor(box.minY))), r: Int32(min(Double(p.width), ceil(box.maxX))),
                bottom: Int32(min(Double(p.height), ceil(box.maxY))), rects: rects,
                aux_n: Int32(auxiliary.count), exc_n: Int32(excluded.count), paper: paper, seen: seen,
                q: queue, best: best, region: region, outside: outside, points: points, meta: meta,
                output: output, safe: safe, stats: stats
                )
                guard accepted != 0 else { return nil }
                var result = Self(width: p.width, height: p.height)
                result.rgba = output.values; result.layoutSafe = safe.values
                result.sourceErasureVerified = stats.values[2] == 0
                result.erasureComplete = stats.values[2] == 0
                result.glyphsVerified = true
                result.method = "enclosed-paper-ink"
                result.surfaceQuality = ["safe": false, "reason": "enclosed-paper-ink"]
                return result
            } catch { return nil }
        } catch { return nil }
    }

    static func nativeLocalComponentPaper(_ p: Self, box: CGRect, auxiliary: [CGRect], excluded: [CGRect]) -> Self? {
        do {
            guard box.minX >= 2, box.minY >= 2, box.width >= 3, box.height >= 3,
            box.maxX <= CGFloat(p.width - 2), box.maxY <= CGFloat(p.height - 2) else { return nil }
            struct Bin { var count = 0; var sum = [Double](repeating: 0, count: 3); let order: Int }
            var bins: [Int: Bin] = [:], order = 0
            let samples = p.indices(box)
            for index in samples {
                guard p.rgba[index * 4 + 3] >= 254 else { return nil }
                let key = Int(p.rgba[index * 4] >> 4) * 256 + Int(p.rgba[index * 4 + 1] >> 4) * 16 + Int(p.rgba[index * 4 + 2] >> 4)
                if bins[key] == nil { bins[key] = Bin(order: order); order += 1 }
                var bin = bins[key]!; bin.count += 1
                for channel in 0..<3 { bin.sum[channel] += Double(p.rgba[index * 4 + channel]) }
                bins[key] = bin
            }
            guard let best = bins.values.sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }).first,
            Double(best.count) >= Double(samples.count) * 0.18 else { return nil }
            let bg = try NativeKernelBuffer<Double>(values: best.sum.map { $0 / Double(best.count) })
            let input = try NativeKernelBuffer<UInt8>(values: p.rgba)
            var exclusion = [UInt8](repeating: 0, count: p.count)
            for rect in excluded { for index in p.indices(rect) { exclusion[index] = 1 } }
            let excludedBuffer = try NativeKernelBuffer<UInt8>(values: exclusion)
            let ink = try NativeKernelBuffer<UInt8>(count: p.count), seen = try NativeKernelBuffer<UInt8>(count: p.count)
            let safe = try NativeKernelBuffer<UInt8>(count: p.count), queue = try NativeKernelBuffer<Int32>(count: p.count)
            let paint = try NativeKernelBuffer<UInt8>(count: p.count), member = try NativeKernelBuffer<UInt8>(count: p.count)
            let output = try NativeKernelBuffer<UInt8>(count: p.count * 4)
            let capacity = max(64, p.count / 4)
            let parts = try NativeKernelBuffer<Int32>(count: capacity * 8), points = try NativeKernelBuffer<Int32>(count: p.count)
            let stats = try NativeKernelBuffer<Int32>(count: 4)
            do {
                let status = try NativeTranslationPixelKernels.local_components(
                rgba: input, w: Int32(p.width), h: Int32(p.height), l: Int32(floor(box.minX)), t: Int32(floor(box.minY)),
                right: Int32(ceil(box.maxX)), bottom: Int32(ceil(box.maxY)), bg: bg, bmax: Double(max(box.width, box.height)),
                excluded: excludedBuffer, ink: ink, seen: seen, safe: safe, q: queue, paint: paint,
                member: member, output: output, parts: parts, part_capacity: Int32(capacity), points: points, stats: stats
                )
                guard status == 1 else { return nil }
                let measurements = stats.values, safeValues = safe.values
                guard measurements[0] >= 8, measurements[1] >= 1, Double(measurements[0]) <= Double(samples.count) * 0.7,
                auxiliary.flatMap(p.indices).allSatisfy({ safeValues[$0] != 0 }) else { return nil }
                var result = Self(width: p.width, height: p.height)
                result.rgba = output.values; result.layoutSafe = safeValues
                result.sourceErasureVerified = measurements[2] == 0 && measurements[3] == 0
                result.erasureComplete = measurements[2] == 0 && measurements[3] == 0
                result.glyphsVerified = measurements[2] == 0
                result.observedBacking = NativeRestorationRGB(bg.values)
                result.method = "local-component-paper"
                result.surfaceQuality = ["safe": true, "reason": "local-component-paper", "rmse": 0, "outliers": 0,
                                         "coefficients": bg.values.map { [$0, 0, 0] }]
                return result
            } catch { return nil }
        } catch { return nil }
    }

}
