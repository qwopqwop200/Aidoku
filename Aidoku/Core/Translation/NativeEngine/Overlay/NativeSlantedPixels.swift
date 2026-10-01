import Foundation

/// Rectification and projection keep their original tap and visiting order.
/// They operate on unpremultiplied RGBA bytes, independently of Core Graphics.
enum NativeSlantedPixels {
    static func linear(_ value: Double) -> Double {
        let v = value / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func resample(_ rgba: [UInt8], w: Int, h: Int, lw: Int, lh: Int,
                         cx: Double, cy: Double, c: Double, s: Double, ox: Double, oy: Double) -> [UInt8] {
        var local = [UInt8](repeating: 0, count: lw * lh * 4)
        for y in 0..<lh { for x in 0..<lw {
            let dx = Double(x) + 0.5 - ox, dy = Double(y) + 0.5 - oy
            let px = cx + dx * c - dy * s - 0.5, py = cy + dx * s + dy * c - 0.5
            let fx = floor(px), fy = floor(py), tx = px - fx, ty = py - fy
            let ix0 = Int(max(0, min(Double(w - 1), fx))), ix1 = Int(max(0, min(Double(w - 1), fx + 1)))
            let iy0 = Int(max(0, min(Double(h - 1), fy))), iy1 = Int(max(0, min(Double(h - 1), fy + 1)))
            let t00 = (iy0 * w + ix0) * 4, t01 = (iy0 * w + ix1) * 4
            let t10 = (iy1 * w + ix0) * 4, t11 = (iy1 * w + ix1) * 4
            let ux = 1 - tx, uy = 1 - ty, out = (y * lw + x) * 4
            for k in 0..<4 {
                local[out + k] = NativeRestorationPixels.clamp(0 + Double(rgba[t00 + k]) * ux * uy + Double(rgba[t01 + k]) * tx * uy +
                    Double(rgba[t10 + k]) * ux * ty + Double(rgba[t11 + k]) * tx * ty)
            }
        } }
        return local
    }

    static func compositeLuminance(_ restored: [UInt8], local: [UInt8], n: Int) -> [UInt8] {
        let table = (0...255).map { linear(Double($0)) }
        func of(_ v: Double) -> Double { v >= 0 && v <= 255 && floor(v) == v ? table[Int(v)] : linear(v) }
        var luminance = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let a = Double(restored[i * 4 + 3]) / 255
            let c0 = Double(restored[i * 4]) * a + Double(local[i * 4]) * (1 - a)
            let c1 = Double(restored[i * 4 + 1]) * a + Double(local[i * 4 + 1]) * (1 - a)
            let c2 = Double(restored[i * 4 + 2]) * a + Double(local[i * 4 + 2]) * (1 - a)
            luminance[i] = UInt8(min(255, max(0, floor(255 * (0.2126 * of(c0) + 0.7152 * of(c1) + 0.0722 * of(c2)) + 0.5))))
        }
        return luminance
    }

    static func projectOwned(_ restored: [UInt8], safe: [UInt8], output: inout [UInt8], w: Int, h: Int, lw: Int, lh: Int,
                             cx: Double, cy: Double, c: Double, s: Double, ox: Double, oy: Double) -> Int {
        var erased = 0
        for y in 0..<h { for x in 0..<w {
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            let lx = dx * c + dy * s + ox - 0.5, ly = -dx * s + dy * c + oy - 0.5
            let roundedX = floor(lx + 0.5), roundedY = floor(ly + 0.5)
            guard roundedX >= 1, roundedY >= 1, roundedX < Double(lw - 1), roundedY < Double(lh - 1) else { continue }
            let ix = Int(roundedX), iy = Int(roundedY)
            guard safe[iy * lw + ix] != 0 else { continue }
            let dst = (y * w + x) * 4, fx = Int(floor(lx)), fy = Int(floor(ly)), tx = lx - floor(lx), ty = ly - floor(ly)
            var weight = 0.0, c0 = 0.0, c1 = 0.0, c2 = 0.0
            for yy in 0..<2 { for xx in 0..<2 {
                let j = ((fy + yy) * lw + fx + xx) * 4
                guard restored[j + 3] != 0 else { continue }
                let a = (xx != 0 ? tx : 1 - tx) * (yy != 0 ? ty : 1 - ty)
                weight += a; c0 += Double(restored[j]) * a; c1 += Double(restored[j + 1]) * a; c2 += Double(restored[j + 2]) * a
            } }
            guard weight > 0 else { continue }
            output[dst] = NativeRestorationPixels.clamp(c0 / weight); output[dst + 1] = NativeRestorationPixels.clamp(c1 / weight)
            output[dst + 2] = NativeRestorationPixels.clamp(c2 / weight); output[dst + 3] = 255; erased += 1
        } }
        return erased
    }

    static func rampPixels(_ rgba: [UInt8], n: Int, axis: [Double], bg: [Double], scale: Double) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let r0 = Double(rgba[i * 4]) - bg[0], r1 = Double(rgba[i * 4 + 1]) - bg[1], r2 = Double(rgba[i * 4 + 2]) - bg[2]
            let t = (0 + axis[0] * r0 + axis[1] * r1 + axis[2] * r2) / scale
            if t > 0.06 && t < 1.6 && max(abs(r0 - axis[0] * t), abs(r1 - axis[1] * t), abs(r2 - axis[2] * t)) <= 20 { raw[i] = 1 }
        }
        return raw
    }

    static func fillHoles(_ rgba: [UInt8], output: inout [UInt8], w: Int, h: Int, axis: [Double], bg: [Double], scale: Double,
                          regions: [[Double]], cx: Double, cy: Double, c: Double, s: Double, ox: Double, oy: Double) -> Int {
        var holes: [(Int, Int)] = []
        guard w > 2, h > 2 else { return 0 }
        for y in 1..<h - 1 { for x in 1..<w - 1 {
            let i = y * w + x
            guard output[i * 4 + 3] == 0 else { continue }
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy, u = dx * c + dy * s + ox, v = -dx * s + dy * c + oy
            guard regions.contains(where: { u >= $0[0] && u <= $0[0] + $0[2] && v >= $0[1] && v <= $0[1] + $0[3] }) else { continue }
            let r0 = Double(rgba[i * 4]) - bg[0], r1 = Double(rgba[i * 4 + 1]) - bg[1], r2 = Double(rgba[i * 4 + 2]) - bg[2]
            let projection = (0 + axis[0] * r0 + axis[1] * r1 + axis[2] * r2) / scale
            let error = max(abs(r0 - axis[0] * projection), abs(r1 - axis[1] * projection), abs(r2 - axis[2] * projection))
            guard projection > 0.15, projection < 1.6, error <= 60 else { continue }
            var covered = 0, donor = -1
            for yy in y - 1...y + 1 { for xx in x - 1...x + 1 {
                let j = yy * w + xx; if output[j * 4 + 3] != 0 { covered += 1; donor = j }
            } }
            if covered >= 5 { holes.append((i, donor)) }
        } }
        for (i, donor) in holes { for k in 0..<4 { output[i * 4 + k] = output[donor * 4 + k] } }
        return holes.count
    }

    static func exposedInk(_ rgba: [UInt8], output: [UInt8], w: Int, h: Int, box: [Double],
                           cx: Double, cy: Double, c: Double, s: Double, foreground: [Double], background: [Double]) -> [Int] {
        var remaining: [Int] = []
        guard w > 2, h > 2 else { return remaining }
        for y in 1..<h - 1 { for x in 1..<w - 1 {
            let i = y * w + x; guard output[i * 4 + 3] == 0 else { continue }
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy, u = dx * c + dy * s, v = -dx * s + dy * c
            guard abs(u) <= box[2] / 2 + 2, abs(v) <= box[3] / 2 + 2,
                  distance(rgba, i, foreground) <= 36, distance(rgba, i, background) >= 40 else { continue }
            var adjacent = false
            for yy in y - 1...y + 1 where !adjacent { for xx in x - 1...x + 1 {
                if output[(yy * w + xx) * 4 + 3] != 0 { adjacent = true; break }
            } }
            if adjacent { remaining.append(i) }
        } }
        return remaining
    }

    static func layoutProof(_ rgba: [UInt8], output: [UInt8], w: Int, h: Int, safe: inout [UInt8], luminance: inout [UInt8],
                            lw: Int, lh: Int, cx: Double, cy: Double, c: Double, s: Double, ox: Double, oy: Double) {
        for y in 0..<lh { for x in 0..<lw {
            let dx = Double(x) + 0.5 - ox, dy = Double(y) + 0.5 - oy
            let px = cx + dx * c - dy * s - 0.5, py = cy + dx * s + dy * c - 0.5
            let flooredX = floor(px), flooredY = floor(py)
            guard flooredX >= 0, flooredY >= 0, flooredX + 1 < Double(w), flooredY + 1 < Double(h) else { continue }
            let fx = Int(flooredX), fy = Int(flooredY)
            let tx = px - floor(px), ty = py - floor(py)
            var owned = true, colors = [Double](repeating: 0, count: 3)
            for yy in 0..<2 { for xx in 0..<2 {
                let j = ((fy + yy) * w + fx + xx) * 4, opaque = output[j + 3] == 255
                if !opaque { owned = false }
                let weight = (xx != 0 ? tx : 1 - tx) * (yy != 0 ? ty : 1 - ty), source = opaque ? output : rgba
                for k in 0..<3 { colors[k] += Double(source[j + k]) * weight }
            } }
            let i = y * lw + x; if owned { safe[i] = 1 }
            luminance[i] = UInt8(min(255, max(0, floor(255 * (0.2126 * linear(colors[0]) + 0.7152 * linear(colors[1]) + 0.0722 * linear(colors[2])) + 0.5))))
        } }
    }

    static func distance(_ rgba: [UInt8], _ i: Int, _ color: [Double]) -> Double {
        max(abs(color[0] - Double(rgba[i * 4])), abs(color[1] - Double(rgba[i * 4 + 1])), abs(color[2] - Double(rgba[i * 4 + 2])))
    }
}
