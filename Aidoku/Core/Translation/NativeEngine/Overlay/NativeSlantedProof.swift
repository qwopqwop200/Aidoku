import Foundation

enum NativeSlantedProof {
    typealias Pixels = NativeRestorationPixels
    typealias RGB = NativeRestorationRGB
    static func surfaceFits(_ result: Pixels, palette: Pixels.Palette?) -> Bool {
        guard let q = result.surfaceQuality, q["safe"] as? Bool == true else { return false }
        func number(_ key: String) -> Double { (q[key] as? NSNumber)?.doubleValue ?? .nan }
        let reason = q["reason"] as? String
        if reason == "smooth" {
            let outlined = palette.map { p in
                p.verifiedForeground.map { $0.maximum - $0.minimum >= 100 } == true && p.foregroundConfidence >= 0.9 && p.strokeConfidence >= 0.85
            } == true
            return number("rmse") <= 8 && number("outliers") <= 0.025 ||
                number("samples") >= 128 && number("rmse") <= 10 && number("outliers") <= 0.01 ||
                outlined && number("samples") >= 128 && number("rmse") <= 12 && number("outliers") <= 0.05
        }
        if reason == "locally-smooth" { return number("localRMSE") <= 1.5 && number("edgeFraction") <= 0.015 }
        return ["periodic", "exemplar-texture", "flat-glyph-boundary"].contains(reason ?? "")
    }

    static func flatGlyphs(_ p: Pixels, box b: [Double], palette: Pixels.Palette?) -> Pixels? {
        guard let fg = palette?.verifiedForeground, let bg = palette?.verifiedBackground, p.count <= 262_144 else { return nil }
        let delta = zip(fg.channels, bg.channels).map(-), norm = delta.reduce(0) { $0 + $1 * $1 }
        guard norm >= 3600 else { return nil }
        var raw = [UInt8](repeating: 0, count: p.count), core = raw, mask = raw
        for i in 0..<p.count {
            let residual = zip(p.color(i).channels, bg.channels).map(-)
            let t = (0 + delta[0] * residual[0] + delta[1] * residual[1] + delta[2] * residual[2]) / norm
            let error = (0..<3).map { abs(residual[$0] - delta[$0] * t) }.max()!
            if t > 0.05 && t < 1.15 && error <= 12 { raw[i] = 1 }
            if p.color(i).distance(fg) <= 24 { core[i] = 1 }
        }
        var components = 0, owned = 0
        for part in p.components(raw) {
            let l = Double(part.rect.minX), t = Double(part.rect.minY), r = Double(part.rect.maxX - 1), d = Double(part.rect.maxY - 1)
            let strong = part.points.reduce(0) { $0 + Int(core[$1]) }
            guard strong >= 2, l >= b[0] - 1, t >= b[1] - 1, r <= b[0] + b[2] + 1, d <= b[1] + b[3] + 1,
                  l >= 2, t >= 2, r < Double(p.width - 2), d < Double(p.height - 2), r - l <= b[2] * 0.96,
                  d - t <= b[3] * 0.96, Double(part.points.count) <= (r - l + 1) * (d - t + 1) * 0.88 else { continue }
            var donors = 0, agree = 0
            for i in part.points { for j in [i - 1, i + 1, i - p.width, i + p.width] where raw[j] == 0 {
                donors += 1; if p.color(j).distance(bg) <= 16 { agree += 1 }
            } }
            guard donors >= 6, Double(agree) >= Double(donors) * 0.97 else { continue }
            components += 1; owned += strong; for i in part.points { mask[i] = 1 }
        }
        guard components >= 2, owned >= 8 else { return nil }
        var surface = 0, total = 0
        for y in Int(ceil(b[1]))..<Int(ceil(b[1] + b[3])) { for x in Int(ceil(b[0]))..<Int(ceil(b[0] + b[2])) {
            let i = y * p.width + x; total += 1
            if mask[i] != 0 || p.color(i).distance(bg) <= 16 { surface += 1 }
        } }
        guard Double(surface) >= Double(total) * 0.96 else { return nil }
        var output = Pixels(width: p.width, height: p.height), safe = mask
        for i in 0..<p.count {
            if mask[i] != 0 { output.paint(i, bg) }
            if mask[i] != 0 || p.color(i).distance(bg) <= 16 { safe[i] = 1 }
        }
        output.layoutSafe = safe; output.method = "flat-glyph-boundary"; output.observedFill = fg; output.observedBacking = bg
        output.surfaceQuality = ["safe": true, "reason": "flat-glyph-boundary"]
        return output
    }

    static func residualInk(_ p: Pixels, box b: [Double], result: Pixels) -> Bool {
        guard let fg = result.observedFill, let bg = result.observedBacking else { return true }
        let tolerance = min(32, fg.distance(bg) * 0.3), axis = zip(fg.channels, bg.channels).map(-)
        let scale = max(1, axis.reduce(0) { $0 + $1 * $1 })
        var raw = [UInt8](repeating: 0, count: p.count), core = raw
        for i in 0..<p.count {
            let residual = zip(p.color(i).channels, bg.channels).map(-)
            let projection = (0 + axis[0] * residual[0] + axis[1] * residual[1] + axis[2] * residual[2]) / scale
            if projection > 0.08 && projection < 1.2 && (0..<3).map({ abs(residual[$0] - axis[$0] * projection) }).max()! <= 24 { raw[i] = 1 }
            if result.rgba[i * 4 + 3] == 0 && p.color(i).distance(fg) <= tolerance { core[i] = 1 }
        }
        for part in p.components(raw) {
            let l = Double(part.rect.minX), t = Double(part.rect.minY), r = Double(part.rect.maxX - 1), d = Double(part.rect.maxY - 1)
            let inside = part.points.filter { i in
                let x = Double(i % p.width), y = Double(i / p.width)
                return core[i] != 0 && x >= b[0] - 3 && x <= b[0] + b[2] + 3 && y >= b[1] - 3 && y <= b[1] + b[3] + 3
            }.count
            let contained = l >= b[0] - 3 && r <= b[0] + b[2] + 3 && t >= b[1] - 3 && d <= b[1] + b[3] + 3
            let line = max(r - l + 1, d - t + 1) > min(r - l + 1, d - t + 1) * 12
            if inside >= 3 && !line && (contained || Double(inside) > Double(part.points.count) * 0.5) &&
                (l > 2 && t > 2 && r < Double(p.width - 3) && d < Double(p.height - 3) || Double(inside) > Double(part.points.count) * 0.7) { return true }
        }
        return false
    }

    static func erasureOffQuad(rgba: [UInt8], width: Int, height: Int, ox: Double, oy: Double, scale: Double,
                               quad: [Double], angle: Double, auxiliary: [[Double]]) -> (erased: Int, off: Int) {
        let c = cos(angle), s = sin(angle), cx = quad[0] + quad[2] / 2, cy = quad[1] + quad[3] / 2
        let margin = max(2, min(8, min(quad[2], quad[3]) * 0.15))
        var erased = 0, off = 0
        for y in 0..<height { for x in 0..<width {
            guard rgba[(y * width + x) * 4 + 3] != 0 else { continue }; erased += 1
            let px = (Double(x) + 0.5) / scale + ox, py = (Double(y) + 0.5) / scale + oy, dx = px - cx, dy = py - cy
            if max(abs(dx * c + dy * s) - quad[2] / 2, abs(-dx * s + dy * c) - quad[3] / 2) <= margin { continue }
            if auxiliary.contains(where: { px >= $0[0] - margin && px <= $0[0] + $0[2] + margin && py >= $0[1] - margin && py <= $0[1] + $0[3] + margin }) { continue }
            off += 1
        } }
        return (erased, off)
    }

    static func pageErasureInQuad(original: Pixels, result: Pixels, sx: Double, sy: Double, ox: Double, oy: Double,
                                  quad: [Double], angle: Double, auxiliary: [[Double]], palette: Pixels.Palette?) -> (result: Pixels, dropped: Int)? {
        guard let initialSafe = result.layoutSafe, initialSafe.count == original.count, sx > 0, sy > 0,
              quad.count == 4, quad.allSatisfy(\.isFinite), let fg = palette?.verifiedForeground, let bg = palette?.verifiedBackground else { return nil }
        var output = result, safe = initialSafe, changed = [UInt8](repeating: 0, count: original.count)
        for i in 0..<original.count where output.rgba[i * 4 + 3] != 0 && output.color(i).distance(original.color(i)) > 24 { changed[i] = 1 }
        let c = cos(angle), s = sin(angle), cx = quad[0] + quad[2] / 2, cy = quad[1] + quad[3] / 2
        let margin = max(2, min(8, min(quad[2], quad[3]) * 0.15))
        func coordinates(_ i: Int) -> (Double, Double, Double, Double) {
            let px = (Double(i % original.width) + 0.5) / sx + ox, py = (Double(i / original.width) + 0.5) / sy + oy
            return (px, py, px - cx, py - cy)
        }
        func on(_ i: Int) -> Bool {
            let (px, py, dx, dy) = coordinates(i)
            return max(abs(dx * c + dy * s) - quad[2] / 2, abs(-dx * s + dy * c) - quad[3] / 2) <= margin ||
                auxiliary.contains { px >= $0[0] - margin && px <= $0[0] + $0[2] + margin && py >= $0[1] - margin && py <= $0[1] + $0[3] + margin }
        }
        var inside = 0, outside = 0
        for part in original.components(changed) {
            let count = part.points.filter(on).count
            if count == part.points.count { inside += count; continue }
            if count > 0 { return nil }; outside += part.points.count
            for i in part.points {
                output.rgba[i * 4 + 3] = 0
                for j in original.neighbors(i) { safe[j] = 0 }; safe[i] = 0
            }
        }
        guard inside > 0, outside <= inside else { return nil }
        var residual = 0
        for i in 0..<original.count where changed[i] == 0 {
            let (_, _, dx, dy) = coordinates(i)
            if max(abs(dx * c + dy * s) - quad[2] / 2, abs(-dx * s + dy * c) - quad[3] / 2) > -1 { continue }
            if original.color(i).distance(fg) <= 36 && original.color(i).distance(bg) >= 40 { residual += 1 }
        }
        guard Double(residual) <= max(8, Double(inside) * 0.03) else { return nil }
        output.layoutSafe = safe; return (output, outside)
    }
}
