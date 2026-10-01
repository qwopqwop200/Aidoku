import Foundation

enum NativeSlantedInkSafety {
    struct Audit {
        var survey = false
        var histogram: [Int]?
        var minimumContrast = Double.infinity
        var unsafeCount = 0
        var unsafeDim = 0
        var dim = 0
        var samples = 0
        var range: [Double]?
    }
    static func finish(audit: inout Audit, minimumContrast: Double, low: Double, high: Double,
                       unsafeCount: Int, unsafeDim: Int, dim: Int, samples: Int) -> Bool {
        audit.minimumContrast = minimumContrast; audit.unsafeCount = unsafeCount; audit.unsafeDim = unsafeDim
        audit.dim = dim; audit.samples = samples; audit.range = low.isFinite ? [low, high] : nil
        return unsafeCount == 0 && dim == 0 && minimumContrast.isFinite
    }
    static func luminance(_ rgb: [Double]) -> Double {
        0.2126 * NativeSlantedPixels.linear(rgb[0]) + 0.7152 * NativeSlantedPixels.linear(rgb[1]) + 0.0722 * NativeSlantedPixels.linear(rgb[2])
    }
    static func contrast(_ byte: UInt8, foreground: Double) -> Double {
        let q = Double(byte) / 255, bg = q >= foreground ? max(foreground, q - 1 / 510) : min(foreground, q + 1 / 510)
        return (max(bg, foreground) + 0.05) / (min(bg, foreground) + 0.05)
    }
    static func inkFits(proof: NativeSlantedRestoration.ProofRaster, rects: [[Double]], scale: Double,
                        foreground: [Double], audit: inout Audit) -> Bool {
        guard !rects.isEmpty, scale.isFinite, scale > 0 else { return false }
        let w = proof.width, h = proof.height, b = proof.box, fg = luminance(foreground)
        var samples = 0, minimum = Double.infinity, low = Double.infinity, high = -Double.infinity, unsafeCount = 0, unsafeDim = 0, dim = 0
        for r in rects {
            let l = Int(floor(b[0] + r[0] * scale)) - 1, t = Int(floor(b[1] + r[1] * scale)) - 1
            let right = Int(ceil(b[0] + r[2] * scale)) + 1, bottom = Int(ceil(b[1] + r[3] * scale)) + 1
            guard l >= 0, t >= 0, right <= w, bottom <= h else { return false }
            for y in t..<bottom { for x in l..<right {
                samples += 1; if samples > 262_144 { return false }
                let i = y * w + x; if proof.safe[i] == 0 && !audit.survey { return false }
                let value = contrast(proof.luminance[i], foreground: fg)
                if proof.safe[i] == 0 { unsafeCount += 1; if value < 4.5 { unsafeDim += 1 }; continue }
                low = min(low, Double(proof.luminance[i])); high = max(high, Double(proof.luminance[i]))
                if audit.histogram != nil { audit.histogram![Int(proof.luminance[i])] += 1 }
                if value < 4.5 { if !audit.survey { return false }; dim += 1; continue }
                minimum = min(minimum, value)
            } }
        }
        return finish(audit: &audit, minimumContrast: minimum, low: low, high: high, unsafeCount: unsafeCount, unsafeDim: unsafeDim, dim: dim, samples: samples)
    }
    static func rotatedPageInkFits(width w: Int, height h: Int, safe: [UInt8]?, luminance bytes: [UInt8]?, sx: Double, sy: Double,
                                   ox: Double, oy: Double, rects: [[Double]], node: [Double], angle: Double,
                                   toImage: (Double, Double) -> [Double], foreground: [Double], audit: inout Audit) -> Bool {
        guard let safe, let bytes, !rects.isEmpty, sx > 0, sy > 0 else { return false }
        let fg = luminance(foreground), c = cos(angle), s = sin(angle), cx = node[0] + node[2] / 2, cy = node[1] + node[3] / 2
        func page(_ lx: Double, _ ly: Double) -> [Double] {
            let dx = lx - node[2] / 2, dy = ly - node[3] / 2
            return [cx + dx * c - dy * s, cy + dx * s + dy * c]
        }
        let origin = toImage(cx, cy), unitX = toImage(cx + 1, cy), unitY = toImage(cx, cy + 1)
        let ax = [unitX[0] - origin[0], unitX[1] - origin[1]], ay = [unitY[0] - origin[0], unitY[1] - origin[1]]
        let det = ax[0] * ay[1] - ax[1] * ay[0]; guard abs(det) > 1e-9 else { return false }
        var samples = 0, minimum = Double.infinity, low = Double.infinity, high = -Double.infinity, unsafeCount = 0, unsafeDim = 0, dim = 0
        for r in rects {
            let corners = [[r[0], r[1]], [r[2], r[1]], [r[2], r[3]], [r[0], r[3]]].map { point -> [Double] in
                let p = page(point[0], point[1]), image = toImage(p[0], p[1]); return [(image[0] - ox) * sx, (image[1] - oy) * sy]
            }
            let l = Int(floor(corners.map { $0[0] }.min()!)) - 1, t = Int(floor(corners.map { $0[1] }.min()!)) - 1
            let right = Int(ceil(corners.map { $0[0] }.max()!)) + 1, bottom = Int(ceil(corners.map { $0[1] }.max()!)) + 1
            guard l >= 0, t >= 0, right <= w, bottom <= h else { return false }
            let margin = 1 / min(hypot(ax[0] * sx, ax[1] * sy), hypot(ay[0] * sx, ay[1] * sy))
            for y in t..<bottom { for x in l..<right {
                let ix = (Double(x) + 0.5) / sx + ox - origin[0], iy = (Double(y) + 0.5) / sy + oy - origin[1]
                let px = cx + (ix * ay[1] - iy * ay[0]) / det, py = cy + (iy * ax[0] - ix * ax[1]) / det
                let dx = px - cx, dy = py - cy, lx = dx * c + dy * s + node[2] / 2, ly = -dx * s + dy * c + node[3] / 2
                guard lx >= r[0] - margin, lx <= r[2] + margin, ly >= r[1] - margin, ly <= r[3] + margin else { continue }
                samples += 1; if samples > 262_144 { return false }
                let i = y * w + x; if safe[i] == 0 && !audit.survey { return false }
                let value = contrast(bytes[i], foreground: fg)
                if safe[i] == 0 { unsafeCount += 1; if value < 4.5 { unsafeDim += 1 }; continue }
                low = min(low, Double(bytes[i])); high = max(high, Double(bytes[i])); if audit.histogram != nil { audit.histogram![Int(bytes[i])] += 1 }
                if value < 4.5 { if !audit.survey { return false }; dim += 1; continue }; minimum = min(minimum, value)
            } }
        }
        return finish(audit: &audit, minimumContrast: minimum, low: low, high: high, unsafeCount: unsafeCount, unsafeDim: unsafeDim, dim: dim, samples: samples)
    }
    static func plateLeftoverInk(luminance: [UInt8]?, n: Int, inside: (Int) -> Bool,
                                palette: NativeRestorationPixels.Palette?) -> (area: Int, ink: Int)? {
        guard let luminance, let fg = palette?.verifiedForeground, let bg = palette?.verifiedBackground else { return nil }
        let f = self.luminance(fg.channels) * 255, b = self.luminance(bg.channels) * 255
        guard abs(f - b) >= 24 else { return nil }
        var area = 0, ink = 0
        for i in 0..<n where inside(i) { area += 1; if abs(Double(luminance[i]) - f) * 2 < abs(Double(luminance[i]) - b) { ink += 1 } }
        return area > 0 ? (area, ink) : nil
    }
    static func pushPull(values: inout [Float], known: [UInt8], width w: Int, height h: Int) -> Bool {
        let w2 = (w + 1) >> 1, h2 = (h + 1) >> 1
        if w <= 2 && h <= 2 || w2 * h2 >= w * h {
            var mean = [Double](repeating: 0, count: 3), count = 0
            for i in 0..<w * h where known[i] != 0 { count += 1; for c in 0..<3 { mean[c] += Double(values[i * 3 + c]) } }
            guard count > 0 else { return false }
            for i in 0..<w * h where known[i] == 0 { for c in 0..<3 { values[i * 3 + c] = Float(mean[c] / Double(count)) } }
            return true
        }
        var small = [Float](repeating: 0, count: w2 * h2 * 3), weight = [Float](repeating: 0, count: w2 * h2)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x; guard known[i] != 0 else { continue }
            let j = (y >> 1) * w2 + (x >> 1); weight[j] += 1
            for c in 0..<3 { small[j * 3 + c] = Float(Double(small[j * 3 + c]) + Double(values[i * 3 + c])) }
        } }
        var smallKnown = [UInt8](repeating: 0, count: w2 * h2)
        for j in 0..<w2 * h2 where weight[j] > 0 { smallKnown[j] = 1; for c in 0..<3 { small[j * 3 + c] = Float(Double(small[j * 3 + c]) / Double(weight[j])) } }
        guard pushPull(values: &small, known: smallKnown, width: w2, height: h2) else { return false }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x; guard known[i] == 0 else { continue }
            let sx = min(Double(w2 - 1), max(0, (Double(x) + 0.5) / 2 - 0.5)), sy = min(Double(h2 - 1), max(0, (Double(y) + 0.5) / 2 - 0.5))
            let x0 = Int(floor(sx)), y0 = Int(floor(sy)), x1 = min(w2 - 1, x0 + 1), y1 = min(h2 - 1, y0 + 1), fx = sx - floor(sx), fy = sy - floor(sy)
            for c in 0..<3 {
                values[i * 3 + c] = Float((Double(small[(y0 * w2 + x0) * 3 + c]) * (1 - fx) + Double(small[(y0 * w2 + x1) * 3 + c]) * fx) * (1 - fy) +
                    (Double(small[(y1 * w2 + x0) * 3 + c]) * (1 - fx) + Double(small[(y1 * w2 + x1) * 3 + c]) * fx) * fy)
            }
        } }
        return true
    }
}
