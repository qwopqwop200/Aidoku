import CoreGraphics
import Foundation

/// Ordered ownership and donor policies from the frozen source-panel pipeline.
/// Buffers use the same byte classes and queue visiting order as the pixel kernels.
enum NativeObservedRestorationHelpers {
    typealias Blend = (Double, Double, Double) -> Bool
    static func color(_ p: [UInt8], _ i: Int) -> [Double] {
        [Double(p[i * 4]), Double(p[i * 4 + 1]), Double(p[i * 4 + 2])]
    }
    static func distance(_ p: [Double], _ color: [Double]?) -> Double {
        guard let color, color.count == 3 else { return .infinity }
        return max(abs(p[0] - color[0]), abs(p[1] - color[1]), abs(p[2] - color[2]))
    }
    static func blend(end: [Double]?, start: [Double]?) -> Blend {
        guard let end, let start, end.count == 3, start.count == 3 else { return { _, _, _ in false } }
        let d = (0..<3).map { end[$0] - start[$0] }
        let length = 0 + d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
        guard length != 0 else { return { _, _, _ in false } }
        return { r, g, b in
            let t = max(0, min(1, (0 + (r - start[0]) * d[0] + (g - start[1]) * d[1] + (b - start[2]) * d[2]) / length))
            return max(abs(r - (start[0] + t * d[0])), abs(g - (start[1] + t * d[1])), abs(b - (start[2] + t * d[2]))) <= 24
        }
    }
    private static func indices(_ rect: CGRect, _ w: Int, _ h: Int, ceilStart: Bool = false) -> [Int] {
        let x0 = max(0, min(w, Int(ceilStart ? ceil(rect.minX) : floor(rect.minX))))
        let y0 = max(0, min(h, Int(ceilStart ? ceil(rect.minY) : floor(rect.minY))))
        let x1 = max(0, min(w, Int(ceil(rect.maxX)))), y1 = max(0, min(h, Int(ceil(rect.maxY))))
        guard x0 < x1, y0 < y1 else { return [] }
        return (y0..<y1).flatMap { y in (x0..<x1).map { y * w + $0 } }
    }
    private static func neighbors(_ i: Int, _ w: Int, _ h: Int, inset: Int = 0) -> [Int] {
        let x = i % w, y = i / w
        let l = max(inset, x - 1), r = min(w - 1 - inset, x + 1)
        let t = max(inset, y - 1), b = min(h - 1 - inset, y + 1)
        guard l <= r, t <= b else { return [] }
        return (t...b).flatMap { yy in (l...r).map { yy * w + $0 } }
    }
    static func restorationOpaque(_ p: [UInt8]) -> Bool {
        stride(from: 3, to: p.count, by: 4).allSatisfy { p[$0] >= 254 }
    }
    static func nextSeed(_ on: [UInt8], _ seen: [UInt8], from: Int, n: Int) -> Int {
        guard from < n else { return n }
        return (from..<n).first { on[$0] != 0 && seen[$0] == 0 } ?? n
    }
    static func maskQueue(_ mask: [UInt8], queue: inout [Int], n: Int) -> Int {
        var tail = 0
        for i in 0..<n where mask[i] != 0 { queue[tail] = i; tail += 1 }
        return tail
    }
    static func maskCount(_ mask: [UInt8], n: Int) -> Int { mask.prefix(n).reduce(0) { $0 + Int($1) } }
    static func countPreserved(_ mask: [UInt8], raw: [UInt8], n: Int) -> (pixels: Int, core: Int) {
        var pixels = 0, core = 0
        for i in 0..<n where mask[i] != 0 { pixels += 1; if raw[i] != 0 { core += 1 } }
        return (pixels, core)
    }
    static func countUnresolvedInk(_ protectedInk: [UInt8], frameInk: [UInt8], w: Int, box: CGRect) -> Int {
        indices(box, w, protectedInk.count / w).reduce(0) { $0 + (protectedInk[$1] != 0 && frameInk[$1] == 0 ? 1 : 0) }
    }
    static func preserveFrameFringe(_ p: [UInt8], w: Int, h: Int, box: CGRect, background: [Double], raw: [UInt8],
                                    mask: [UInt8], protectedInk: [UInt8], frameInk: inout [UInt8]) -> Int {
        var pending: [Int] = []
        for i in indices(box.intersection(CGRect(x: 1, y: 1, width: w - 2, height: h - 2)), w, h) {
            let x = Double(i % w), y = Double(i / w)
            if x >= box.minX + 3 && x < box.maxX - 3 && y >= box.minY + 3 && y < box.maxY - 3 { continue }
            if protectedInk[i] == 0 || raw[i] != 0 || mask[i] != 0 || frameInk[i] != 0 { continue }
            var support = 0, count = 0
            let rgb = color(p, i)
            for j in neighbors(i, w, h) where frameInk[j] != 0 && raw[j] != 0 && mask[j] == 0 {
                count += 1
                if blend(end: background, start: color(p, j))(rgb[0], rgb[1], rgb[2]) { support += 1 }
            }
            if count >= 2 && support >= 1 { pending.append(i) }
        }
        for i in pending { frameInk[i] = 1 }
        return pending.count
    }
    static func frameInterior(_ frameInk: [UInt8], w: Int, box: CGRect) -> (pixels: Int, area: Int) {
        let x0 = Int(ceil(box.minX + 3)), x1 = Int(floor(box.maxX - 3))
        let y0 = Int(ceil(box.minY + 3)), y1 = Int(floor(box.maxY - 3))
        guard x0 < x1, y0 < y1 else { return (0, 0) }
        var count = 0, area = 0
        for y in y0..<y1 { for x in x0..<x1 { area += 1; if frameInk[y * w + x] != 0 { count += 1 } } }
        return (count, area)
    }
    static func rectHasInk(_ protectedInk: [UInt8], frameInk: [UInt8], w: Int, rect: CGRect) -> Bool {
        indices(rect, w, protectedInk.count / w).contains { protectedInk[$0] != 0 || frameInk[$0] != 0 }
    }
    static func layoutSafe(_ protectedInk: [UInt8], drawingSurface: [UInt8]?, n: Int) -> [UInt8] {
        (0..<n).map { protectedInk[$0] == 0 && (drawingSurface?[$0] ?? 0) == 0 ? 1 : 0 }
    }
    static func surfacePlaneRGB(_ coefficients: [[Double]], x: Double, y: Double) -> [Double] {
        coefficients.map { max(0, min(255, $0[0] + $0[1] * x + $0[2] * y)) }
    }
    static func planeFill(_ mask: [UInt8], coefficients: [[Double]], w: Int, h: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where mask[i] != 0 {
            let rgb = surfacePlaneRGB(coefficients, x: Double(i % w) / Double(w), y: Double(i / w) / Double(h))
            for c in 0..<3 { output[i * 4 + c] = NativeRestorationPixels.clamp(rgb[c]) }
            output[i * 4 + 3] = 255
        }
        return output
    }
    static func floodComponent(_ on: [UInt8], seen: inout [UInt8], queue: inout [Int], start: Int, w: Int, h: Int,
                               bounds: inout [Int]) -> Int {
        var head = 0, tail = 1, x0 = w, y0 = h, x1 = 0, y1 = 0
        queue[0] = start; seen[start] = 1
        while head < tail {
            let i = queue[head]; head += 1
            x0 = min(x0, i % w); x1 = max(x1, i % w); y0 = min(y0, i / w); y1 = max(y1, i / w)
            for j in neighbors(i, w, h) where on[j] != 0 && seen[j] == 0 { seen[j] = 1; queue[tail] = j; tail += 1 }
        }
        bounds = [x0, y0, x1, y1]
        return tail
    }
    static func growDrawingSupport(_ p: [UInt8], w: Int, h: Int, threshold: Double, frameInk: inout [UInt8], raw: [UInt8],
                                   mask: inout [UInt8], seedRadius: inout [UInt8], protectedInk: inout [UInt8], queue: inout [Int]) -> [UInt8] {
        var support = [UInt8](repeating: 0, count: w * h), tail = 0, head = 0
        for i in 0..<(w * h) where frameInk[i] != 0 { support[i] = 1; queue[tail] = i; tail += 1 }
        while head < tail {
            let i = queue[head]; head += 1
            for j in neighbors(i, w, h) where support[j] == 0 && Double(max(p[j * 4], p[j * 4 + 1], p[j * 4 + 2])) <= threshold {
                support[j] = 1; queue[tail] = j; tail += 1
            }
        }
        for i in 0..<(w * h) where support[i] != 0 {
            mask[i] = 0; seedRadius[i] = 0
            if raw[i] != 0 { protectedInk[i] = 1; frameInk[i] = 1 }
        }
        return support
    }
    static func blockProtectedDonors(_ protectedInk: [UInt8], w: Int, h: Int, queue: inout [Int]) -> (blocked: [UInt8], distance: [UInt8]) {
        var blocked = protectedInk, distance = [UInt8](repeating: 0, count: w * h), tail = 0, head = 0
        for i in 0..<(w * h) where protectedInk[i] != 0 { queue[tail] = i; tail += 1 }
        while head < tail {
            let i = queue[head]; head += 1
            if distance[i] >= 8 { continue }
            for j in neighbors(i, w, h) where blocked[j] == 0 {
                blocked[j] = 1; distance[j] = distance[i] + 1; queue[tail] = j; tail += 1
            }
        }
        return (blocked, distance)
    }
    static func dilateOwnedMask(_ p: [UInt8], w: Int, h: Int, queue: inout [Int], tail initialTail: Int,
                                mask: inout [UInt8], distance: inout [UInt8], seedRadius: inout [UInt8], protectedInk: [UInt8],
                                drawingSurface: [UInt8]?, donorBlocked: inout [UInt8], donorDistance: [UInt8], protectArtMargin: Bool,
                                followHalo: Bool, preciseFringe: Bool, radius: Double, background: [Double],
                                strokeBackgroundBlend: Blend, flags: inout [UInt8], glyphMargin: Double = .infinity,
                                foreground: [Double]? = nil, owned: [CGRect] = []) -> Int {
        let n = w * h
        let delta = foreground.map { f in (0..<3).map { f[$0] - background[$0] } } ?? [0, 0, 0]
        let length = foreground == nil ? 0 : delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]
        var known = [UInt8](repeating: 0, count: n), art = known, visit = [Int](repeating: 0, count: n), stamp = 0
        var stack = [Int](repeating: 0, count: n), inside = known
        if glyphMargin.isFinite {
            for rect in owned {
                for i in indices(rect.insetBy(dx: -2, dy: -2), w, h, ceilStart: true) { inside[i] = 1 }
            }
        }
        func plain(_ j: Int) -> Bool {
            if known[j] != 0 { return known[j] == 1 }
            let rgb = color(p, j)
            var isPlain = self.distance(rgb, background) <= 24
            if !isPlain && length >= 1600 {
                let t = ((rgb[0] - background[0]) * delta[0] + (rgb[1] - background[1]) * delta[1]
                    + (rgb[2] - background[2]) * delta[2]) / length
                isPlain = t <= 0.5 && max(abs(rgb[0] - background[0] - t * delta[0]),
                    abs(rgb[1] - background[1] - t * delta[1]), abs(rgb[2] - background[2] - t * delta[2])) <= 24
            }
            known[j] = isPlain ? 1 : 2
            return isPlain
        }
        func artAt(_ j: Int) -> Bool {
            if art[j] != 0 { return art[j] == 1 }
            if plain(j) { return false }
            let reach = max(6, glyphMargin * 1.5)
            stamp += 1
            var top = 1, count = 0, x0 = w, y0 = h, x1 = 0, y1 = 0, long = false
            stack[0] = j; visit[j] = stamp
            while top > 0 && !long {
                top -= 1
                let i = stack[top], x = i % w, y = i / w
                stack[n - 1 - count] = i; count += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                if Double(max(x1 - x0, y1 - y0) + 1) >= reach || art[i] == 1 { long = true; break }
                for k in neighbors(i, w, h) where visit[k] != stamp && inside[k] == 0 && !plain(k) {
                    visit[k] = stamp; stack[top] = k; top += 1
                }
            }
            for c in 0..<count { art[stack[n - 1 - c]] = long ? 1 : 2 }
            return long
        }
        var head = 0, tail = initialTail
        while head < tail {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w, atLimit = distance[i] >= seedRadius[i]
            if atLimit && (!followHalo || Int(distance[i]) >= min(20, Int(seedRadius[i]) + (preciseFringe ? 12 : 8))) { continue }
            let wide = !atLimit && Double(distance[i]) >= glyphMargin
            for j in neighbors(i, w, h, inset: 1) {
                let xx = j % w, yy = j / w
                let ownedFringe = distance[i] < 2 && donorDistance[j] >= 3
                if mask[j] != 0 || protectedInk[j] != 0 || (drawingSurface?[j] ?? 0) != 0
                    || (protectArtMargin && donorBlocked[j] != 0 && !ownedFringe) { continue }
                if wide && inside[j] == 0 && artAt(j) { donorBlocked[j] = 1; continue }
                if atLimit {
                    if donorBlocked[j] != 0 { continue }
                    let rgb = color(p, j)
                    if self.distance(rgb, background) < (preciseFringe ? 8 : 12) || !strokeBackgroundBlend(rgb[0], rgb[1], rgb[2]) { continue }
                    flags[0] = 1
                }
                if xx != x && yy != y && Double(distance[i]) > radius - 2 { continue }
                mask[j] = 1; distance[j] = distance[i] &+ 1; seedRadius[j] = seedRadius[i]; queue[tail] = j; tail += 1
            }
        }
        return tail
    }
    static func followPlanarHalo(_ p: [UInt8], w: Int, h: Int, queue: inout [Int], tail initialTail: Int,
                                mask: inout [UInt8], distance: inout [UInt8], seedRadius: inout [UInt8], donorBlocked: [UInt8],
                                drawingSurface: [UInt8]?, coefficients: [[Double]], stroke: [Double]?, preciseFringe: Bool) -> Int {
        var head = 0, tail = initialTail
        while head < tail {
            let i = queue[head]; head += 1
            if Int(distance[i]) >= min(20, Int(seedRadius[i]) + (preciseFringe ? 12 : 8)) { continue }
            let x = i % w, y = i / w
            for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                if xx < 1 || yy < 1 || xx >= w - 1 || yy >= h - 1 { continue }
                let j = yy * w + xx
                if mask[j] != 0 || donorBlocked[j] != 0 || (drawingSurface?[j] ?? 0) != 0 { continue }
                let expected = coefficients.map { $0[0] + $0[1] * Double(xx) / Double(w) + $0[2] * Double(yy) / Double(h) }
                let rgb = color(p, j)
                if self.distance(rgb, expected) < (preciseFringe ? 8 : 18) || !blend(end: expected, start: stroke)(rgb[0], rgb[1], rgb[2]) { continue }
                mask[j] = 1; distance[j] = distance[i] &+ 1; seedRadius[j] = seedRadius[i]; queue[tail] = j; tail += 1
            }
        }
        return tail
    }
    static func expandPlanarRing(_ p: [UInt8], w: Int, h: Int, queue: inout [Int], priorTail: Int,
                                mask: inout [UInt8], distance: inout [UInt8], seedRadius: inout [UInt8], donorBlocked: [UInt8],
                                drawingSurface: [UInt8]?, rubyMargins: [[Double]], coefficients: [[Double]],
                                foreground: [Double], stroke: [Double]?) -> Int {
        var tail = priorTail
        for k in 0..<priorTail {
            let i = queue[k]
            if distance[i] < seedRadius[i] { continue }
            for j in neighbors(i, w, h, inset: 1) {
                let x = j % w, y = j / w
                if mask[j] != 0 || donorBlocked[j] != 0 || (drawingSurface?[j] ?? 0) != 0 { continue }
                if rubyMargins.contains(where: { Double(x) >= $0[0] && Double(x) <= $0[2] && Double(y) >= $0[1] && Double(y) <= $0[3] }) { continue }
                let expected = coefficients.map { $0[0] + $0[1] * Double(x) / Double(w) + $0[2] * Double(y) / Double(h) }
                let rgb = color(p, j)
                if self.distance(rgb, expected) < 4 || (!blend(end: expected, start: foreground)(rgb[0], rgb[1], rgb[2])
                    && !blend(end: expected, start: stroke)(rgb[0], rgb[1], rgb[2])) { continue }
                mask[j] = 1; distance[j] = distance[i] &+ 1; seedRadius[j] = seedRadius[i]; queue[tail] = j; tail += 1
            }
        }
        return tail
    }
    static func fillEnclosedHoles(_ p: [UInt8], w: Int, h: Int, box: CGRect, mask: inout [UInt8], queue: inout [Int],
                                  protectedInk: [UInt8], drawingSurface: [UInt8]?, stroke: [Double]?, background: [Double],
                                  inkStrokeBlend: Blend, strokeBackgroundBlend: Blend) -> Int {
        let n = w * h
        var exterior = [UInt8](repeating: 0, count: n), end = 0
        func visit(_ i: Int) {
            if mask[i] == 0 && exterior[i] == 0 { exterior[i] = 1; queue[end] = i; end += 1 }
        }
        for x in 0..<w { visit(x); visit((h - 1) * w + x) }
        for y in 0..<h { visit(y * w); visit(y * w + w - 1) }
        var head = 0
        while head < end {
            let i = queue[head]; head += 1
            if i % w > 0 { visit(i - 1) }; if i % w < w - 1 { visit(i + 1) }
            if i / w > 0 { visit(i - w) }; if i / w < h - 1 { visit(i + w) }
        }
        for start in 0..<n where mask[start] == 0 && exterior[start] == 0 {
            head = 0; end = 1
            var owned = true
            queue[0] = start; exterior[start] = 1
            while head < end {
                let i = queue[head]; head += 1
                let x = Double(i % w), y = Double(i / w), rgb = color(p, i)
                if x < box.minX || x > box.maxX || y < box.minY || y > box.maxY || protectedInk[i] != 0
                    || (drawingSurface?[i] ?? 0) != 0 || (distance(rgb, stroke) > 24 && distance(rgb, background) > 24
                    && !inkStrokeBlend(rgb[0], rgb[1], rgb[2]) && !strokeBackgroundBlend(rgb[0], rgb[1], rgb[2])) { owned = false }
                for j in [i - 1, i + 1, i - w, i + w] where j >= 0 && j < n && mask[j] == 0 && exterior[j] == 0 {
                    exterior[j] = 1; queue[end] = j; end += 1
                }
            }
            if owned && Double(end) <= box.width * box.height * 0.15 { for k in 0..<end { mask[queue[k]] = 1 } }
        }
        return maskQueue(mask, queue: &queue, n: n)
    }
}
