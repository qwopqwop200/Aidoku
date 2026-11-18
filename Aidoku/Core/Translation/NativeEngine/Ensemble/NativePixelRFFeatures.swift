import CoreGraphics
import Foundation

/// Source-only feature contract for the calibrated segmentation forest.
/// Geometry supplies localization seeds, never a final mask clip.
enum NativePixelRFFeatures {
    static let samplingPolicyVersion = "primary62-adaptive-odd-half-even-4ulp-v2"
    enum Failure: Error { case invalidInput, workBudget }
    /// Stabilize the bounded SAMPLING window, not font observations or source
    /// geometry. Decimal metadata re-entry may move an exact half by one ULP.
    static func adaptiveWindow(fontPixels: Double) throws -> Int {
        guard fontPixels.isFinite, fontPixels > 0 else { throw Failure.invalidInput }
        let value = min(65, max(3, fontPixels * 0.25))
        let half = (value * 2).rounded(.toNearestOrEven) * 0.5
        let tolerance = 4 * max(value.ulp, half.ulp)
        let stable = abs(value - half) <= tolerance ? half : value
        // Clamp in Double first so even huge finite font scalars cannot trap
        // in Int conversion. Existing limits and odd-window semantics remain.
        return Int(stable.rounded(.toNearestOrEven)) | 1
    }
    struct Input {
        let width: Int
        let height: Int
        let rgb: [UInt8]
        let nativeMask: [UInt8]
        let polygons: [[CGPoint]]
        let fontPixels: Double
        /// Pixel-interleaved native text/SFX/balloon/frame support, [0,1].
        let coarseRF: [Float]
        /// Optional pixel-interleaved 27-channel all-query RF evidence.
        let fullRF: [Float]?
    }
    struct Matrix {
        let values: [Float]
        let featureCount: Int
        let pixelCount: Int
    }

    static func extract(_ input: Input, includeFullRF: Bool = true) throws -> Matrix {
        let w = input.width, h = input.height
        guard w > 0, h > 0, w <= 1_500_000 / h else { throw Failure.workBudget }
        let n = w * h
        guard input.rgb.count == n * 3, input.nativeMask.count == n,
              input.coarseRF.count == n * 4, input.fontPixels.isFinite, input.fontPixels > 0,
              input.polygons.count <= 256,
              input.polygons.allSatisfy({ (3...16).contains($0.count) && $0.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) }),
              input.coarseRF.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              input.fullRF.map({ $0.count == n * 27 && $0.allSatisfy(\.isFinite) }) ?? true else { throw Failure.invalidInput }
        let fullRF = includeFullRF ? input.fullRF : nil
        let featureCount = fullRF == nil ? 35 : 62
        var result = [Float](repeating: 0, count: n * featureCount)
        var colors = [SIMD4<UInt8>](repeating: .zero, count: n)
        var moments = [SIMD2<Float>](repeating: .zero, count: n)
        var owned = [UInt8](repeating: 0, count: n)
        for polygon in input.polygons {
            let raster = NativeMainRemovalSourceFactory.NativeCurrentMaskCaller.raster(polygon, width: w, height: h)
            for i in 0..<n where raster[i] != 0 { owned[i] = 1 }
        }
        for i in 0..<n {
            let r = Float(input.rgb[i * 3]), g = Float(input.rgb[i * 3 + 1]), b = Float(input.rgb[i * 3 + 2])
            let base = Float(input.nativeMask[i] == 0 ? 0 : 1)
            colors[i] = SIMD4(input.rgb[i * 3], input.rgb[i * 3 + 1], input.rgb[i * 3 + 2], input.nativeMask[i] == 0 ? 0 : 1)
            let rg = r * 0.2126 + g * 0.7152
            let luminance = rg + b * 0.0722
            moments[i] = SIMD2(luminance, luminance * luminance)
            let offset = i * featureCount
            result[offset] = r / 255; result[offset + 1] = g / 255; result[offset + 2] = b / 255
            result[offset + 3] = luminance / 255
            result[offset + 4] = (max(r, max(g, b)) - min(r, min(g, b))) / 255
            result[offset + 5] = base; result[offset + 6] = Float(owned[i])
        }
        let adaptive = try adaptiveWindow(fontPixels: input.fontPixels)
        let windows = [3, 9, 21, adaptive]
        for (window, size) in windows.enumerated() {
            let start = 7 + window * 5
            if let same = windows[..<window].firstIndex(of: size) {
                for i in 0..<n {
                    let offset = i * featureCount
                    for c in 0..<5 { result[offset + start + c] = result[offset + 7 + same * 5 + c] }
                }
                continue
            }
            windowFeatures(colors: colors, moments: moments, width: w, height: h, size: size,
                           feature: start, stride: featureCount, result: &result)
        }
        do {
            let nativeDistance = oppositeClassDistance(input.nativeMask, width: w, height: h)
            for i in 0..<n {
                let offset = i * featureCount
                result[offset + 27] = Float(min(32, input.nativeMask[i] == 0 ? nativeDistance[i] : 0)) / 32
                result[offset + 28] = Float(min(32, input.nativeMask[i] == 0 ? 0 : nativeDistance[i])) / 32
            }
        }
        let ownerDistance = distance(toNonzero: owned, width: w, height: h)
        let font = Float(max(1, input.fontPixels))
        var histogram = [Int](repeating: 0, count: 3 * 256)
        var sampleCount = 0
        func sample(_ i: Int) {
            for c in 0..<3 { histogram[c * 256 + Int(input.rgb[i * 3 + c])] += 1 }
            sampleCount += 1
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, distance = ownerDistance[i]
                // A radius-two square contains the Manhattan radius-two diamond
                // and is contained in the radius-four diamond.
                if distance == 0 || distance > 4 { continue }
                if distance <= 2 { sample(i); continue }
                search: for yy in max(0, y - 2)...min(h - 1, y + 2) {
                    for xx in max(0, x - 2)...min(w - 1, x + 2) where owned[yy * w + xx] != 0 {
                        sample(i)
                        break search
                    }
                }
            }
        }
        if sampleCount == 0 { for i in 0..<n { sample(i) } }
        let background = (0..<3).map { channel -> Float in
            let lower = (sampleCount - 1) / 2, upper = sampleCount / 2
            var a = -1, b = -1, sum = 0
            for value in 0..<256 {
                sum += histogram[channel * 256 + value]
                if a < 0 && sum > lower { a = value }
                if sum > upper { b = value; break }
            }
            return Float(a + b) / 2
        }
        for i in 0..<n {
            let offset = i * featureCount
            result[offset + 29] = min(Float(ownerDistance[i]) / font, 1)
            result[offset + 30] = max(abs(Float(colors[i][0]) - background[0]),
                max(abs(Float(colors[i][1]) - background[1]), abs(Float(colors[i][2]) - background[2]))) / 255
            for c in 0..<4 { result[offset + 31 + c] = input.coarseRF[i * 4 + c] }
            if let full = fullRF {
                for c in 0..<27 { result[offset + 35 + c] = full[i * 27 + c] }
            }
        }
        return Matrix(values: result, featureCount: featureCount, pixelCount: n)
    }

    // The RGB and binary-mask lanes accumulate integral values (at most
    // 255 * 65 * 65) exactly in Float. The luminance moments retain their
    // individual Double add/subtract order and Float output rounding.
    private static func windowFeatures(colors: [SIMD4<UInt8>], moments: [SIMD2<Float>],
                                       width w: Int, height h: Int, size: Int, feature: Int,
                                       stride: Int, result: inout [Float]) {
        let radius = size / 2, capacity = min(h, 2 * radius + 2)
        let scale = 1.0 / Double(size * size)
        // Slice very wide rows to cap the two sliding windows' row backing
        // at 2,048 * 66 * 32 bytes. Carry each row's horizontal sums across
        // slices so its floating-point operations keep the scalar order.
        let span = min(w, 2_048)
        var carry = [SIMD4<Float>](repeating: .zero, count: w > span ? h : 0)
        var momentCarry = [SIMD2<Double>](repeating: .zero, count: carry.count)
        var rows = [SIMD4<Float>](repeating: .zero, count: capacity * span)
        var momentRows = [SIMD2<Double>](repeating: .zero, count: capacity * span)
        var sums = [SIMD4<Float>](repeating: .zero, count: span)
        var momentSums = [SIMD2<Double>](repeating: .zero, count: span)
        for left in Swift.stride(from: 0, to: w, by: span) {
            let count = min(span, w - left)
            func fill(_ y: Int) {
                let row = y * w, slot = (y % capacity) * span
                var rgb = SIMD4<Float>.zero, lm = SIMD2<Double>.zero
                if left == 0 {
                    for dx in -radius...radius {
                        let p = row + min(w - 1, max(0, dx))
                        rgb += SIMD4<Float>(colors[p])
                        lm += SIMD2<Double>(moments[p])
                    }
                } else {
                    rgb = carry[y]
                    lm = momentCarry[y]
                }
                for column in 0..<count {
                    let x = left + column
                    rows[slot + column] = rgb
                    momentRows[slot + column] = lm
                    let drop = row + max(0, x - radius), add = row + min(w - 1, x + radius + 1)
                    rgb -= SIMD4<Float>(colors[drop])
                    rgb += SIMD4<Float>(colors[add])
                    lm -= SIMD2<Double>(moments[drop])
                    lm += SIMD2<Double>(moments[add])
                }
                if left + count < w {
                    carry[y] = rgb
                    momentCarry[y] = lm
                }
            }
            for x in 0..<count { sums[x] = .zero; momentSums[x] = .zero }
            for y in 0...min(h - 1, radius) { fill(y) }
            for dy in -radius...radius {
                let slot = min(h - 1, max(0, dy)) * span
                for x in 0..<count {
                    sums[x] += rows[slot + x]
                    momentSums[x] += momentRows[slot + x]
                }
            }
            for y in 0..<h {
                let next = y + radius + 1
                if next < h { fill(next) }
                let drop = (max(0, y - radius) % capacity) * span
                let add = (min(h - 1, next) % capacity) * span
                for x in 0..<count {
                    let p = y * w + left + x, offset = p * stride + feature
                    let mean = SIMD4<Float>(SIMD4<Double>(sums[x]) * scale)
                    let m = SIMD2<Float>(momentSums[x] * scale)
                    let difference = (SIMD4<Float>(colors[p]) - mean) / 255
                    result[offset] = difference.x
                    result[offset + 1] = difference.y
                    result[offset + 2] = difference.z
                    result[offset + 3] = sqrt(max(0, m.y - m.x * m.x)) / 128
                    result[offset + 4] = mean.w
                    sums[x] -= rows[drop + x]
                    sums[x] += rows[add + x]
                    momentSums[x] -= momentRows[drop + x]
                    momentSums[x] += momentRows[add + x]
                }
            }
        }
    }

    /// Double-precision sums, Float32 means, replicated border; matches the
    /// OpenCV CV_32F normalized box filter without allocating padded images.
    static func boxMean(_ input: [Float], width w: Int, height h: Int, size: Int) -> [Float] {
        let radius = size / 2
        // Vertical sliding sums only need the leaving and entering rows and
        // those between them. Each real row is filtered once before use.
        let rowCapacity = min(h, 2 * radius + 2)
        var horizontal = [Double](repeating: 0, count: w * rowCapacity)
        func makeRow(_ y: Int) {
            var sum = 0.0
            let slot = (y % rowCapacity) * w
            for dx in -radius...radius { sum += Double(input[y * w + min(w - 1, max(0, dx))]) }
            for x in 0..<w {
                horizontal[slot + x] = sum
                sum -= Double(input[y * w + max(0, x - radius)])
                sum += Double(input[y * w + min(w - 1, x + radius + 1)])
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        let scale = 1.0 / Double(size * size)
        // Interleave independent columns without reordering any column's arithmetic.
        var sums = [Double](repeating: 0, count: w)
        for y in 0...min(h - 1, radius) { makeRow(y) }
        for dy in -radius...radius {
            let row = min(h - 1, max(0, dy)) * w
            for x in 0..<w { sums[x] += horizontal[row + x] }
        }
        for y in 0..<h {
            let row = y * w
            let next = y + radius + 1
            if next < h { makeRow(next) }
            let removed = (max(0, y - radius) % rowCapacity) * w
            let added = (min(h - 1, next) % rowCapacity) * w
            for x in 0..<w {
                output[row + x] = Float(sums[x] * scale)
                sums[x] -= horizontal[removed + x]
                sums[x] += horizontal[added + x]
            }
        }
        return output
    }

    static func distance(toNonzero input: [UInt8], width w: Int, height h: Int) -> [Int] {
        let infinity = 65534
        var d = input.map { $0 == 0 ? infinity : 0 }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }
                if y > 0 { d[i] = min(d[i], d[i - w] + 1) }
            }
        }
        for y in (0..<h).reversed() {
            for x in (0..<w).reversed() {
                let i = y * w + x
                if x + 1 < w { d[i] = min(d[i], d[i + 1] + 1) }
                if y + 1 < h { d[i] = min(d[i], d[i + w] + 1) }
            }
        }
        return d
    }

    /// Exact nearest opposite-binary-class Manhattan distance for BOTH classes.
    /// In-image four-neighbour class contacts seed both sides at distance one.
    /// Every nearest boundary belongs to the pixel's own class; crossing the
    /// boundary cannot improve on that nearer seed. Constant masks retain65534.
    static func oppositeClassDistance(_ input: [UInt8], width w: Int, height h: Int) -> [Int] {
        var d = [Int](repeating: 65534, count: input.count)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let zero = input[i] == 0
                if x > 0, (input[i - 1] == 0) != zero { d[i] = 1; d[i - 1] = 1 }
                if y > 0, (input[i - w] == 0) != zero { d[i] = 1; d[i - w] = 1 }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }
                if y > 0 { d[i] = min(d[i], d[i - w] + 1) }
            }
        }
        for y in (0..<h).reversed() {
            for x in (0..<w).reversed() {
                let i = y * w + x
                if x + 1 < w { d[i] = min(d[i], d[i + 1] + 1) }
                if y + 1 < h { d[i] = min(d[i], d[i + w] + 1) }
            }
        }
        return d
    }

}

