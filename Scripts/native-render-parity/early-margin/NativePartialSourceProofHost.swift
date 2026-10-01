import CoreGraphics
import Foundation

/// Bounded mask proofs for releasing an opaque caption at its original source
/// position. Unknown/invalid masks fail closed; matching colour is not proof.
enum NativePartialSourceProof {
    static func outlineSourceResolved(safe: [UInt8], width w: Int, height h: Int, core: [CGRect],
                                      erasureVerified: Bool, glyphsVerified: Bool, pixelRatio: Double) -> Bool {
        guard valid(safe, w, h), !core.isEmpty, core.allSatisfy(finite) else { return false }
        if erasureVerified { return true }
        if !glyphsVerified { return false }
        let px = pixelRatio.isNaN ? Double.nan : max(1, min(3, 1.5 * pixelRatio))
        for a in core {
            let l = max(0, Int(floor(a.origin.x))), t = max(0, Int(floor(a.origin.y)))
            let r = min(w, Int(ceil(a.origin.x + a.size.width))), b = min(h, Int(ceil(a.origin.y + a.size.height)))
            var all = 0, interior = 0
            if l < r && t < b { for y in t..<b { for x in l..<r where safe[y * w + x] == 0 {
                all += 1
                if Double(x) >= Double(l) + px && Double(x) < Double(r) - px && Double(y) >= Double(t) + px && Double(y) < Double(b) - px { interior += 1 }
            } } }
            if Double(interior) > min(8, Double((r - l) * (b - t)) * 0.003) || Double(all) > Double((r - l) * (b - t)) * 0.06 { return false }
        }
        return true
    }

    static func hasAttachedLeadingInk(safe: [UInt8], width w: Int, height h: Int, core: [CGRect], glyph: Double) -> Bool {
        guard valid(safe, w, h), glyph.isFinite, glyph > 0 else { return true }
        let radius = Int(max(4, min(64, ceil(glyph * 0.9)))), depth = max(2, glyph * 0.22)
        var budget = w * h * 2
        for r in core {
            if !finite(r) || r.width <= 0 || r.height <= 0 { return true }
            let edge = max(0, Int(ceil(r.maxX))), right = min(w, Int(ceil(Double(edge) + glyph * 1.5)))
            let top = max(0, Int(floor(r.minY))), bottom = min(h, Int(ceil(r.maxY)))
            budget -= max(0, bottom - top) * (max(0, right - edge) + radius * 2)
            if budget < 0 { return true }
            var first: [Int] = []
            if top < bottom { for y in top..<bottom {
                var x = edge
                while x < right && safe[y * w + x] != 0 { x += 1 }
                first.append(x)
            } }
            var runs: [(Int, Int)] = [], start = -1
            for y in 0...first.count {
                var before = 0, after = 0
                if max(0, y - radius) < y - 1 { for k in max(0, y - radius)..<(y - 1) { before = max(before, first[k]) } }
                if y + 2 < min(first.count, y + radius + 1) { for k in (y + 2)..<min(first.count, y + radius + 1) { after = max(after, first[k]) } }
                let protrudes = y < first.count && Double(first[y] - edge) <= glyph && Double(min(before, after) - first[y]) >= depth
                if protrudes && start < 0 { start = y }
                if !protrudes && start >= 0 {
                    let length = y - start
                    if length >= 2 && Double(length) <= glyph * 1.5 { runs.append((start, y)) }
                    start = -1
                }
            }
            if runs.count >= 2 { for i in 1..<runs.count {
                if Double(runs[i].0 - runs[i - 1].1) <= glyph * 2 && Double(runs[i].1 - runs[i].0 + runs[i - 1].1 - runs[i - 1].0) >= glyph * 0.5 { return true }
            } }
        }
        return false
    }

    static func hasLargePartialResidual(safe: [UInt8], width w: Int, height h: Int, core: [CGRect], glyph: Double, vertical: Bool) -> Bool {
        guard valid(safe, w, h), glyph.isFinite, glyph > 0, !core.isEmpty,
              core.allSatisfy({ finite($0) && $0.width > 0 && $0.height > 0 }) else { return true }
        let n = w * h
        struct Part { let label: Int; let l: Int; let t: Int; let r: Int; let b: Int; let count: Int; let edge: Bool; let barrier: Bool }
        var labels = [Int](repeating: 0, count: n), parts: [Part] = []
        func neighbors(_ i: Int) -> [Int] {
            let x = i % w, y = i / w
            return (max(0, y - 1)...min(h - 1, y + 1)).flatMap { yy in
                (max(0, x - 1)...min(w - 1, x + 1)).map { yy * w + $0 }
            }
        }
        for start in 0..<n where safe[start] == 0 && labels[start] == 0 {
            let label = parts.count + 1
            var queue = [start], head = 0, l = w, t = h, r = 0, b = 0, edge = false
            labels[start] = label
            while head < queue.count {
                let i = queue[head], x = i % w, y = i / w; head += 1
                l = min(l, x); r = max(r, x); t = min(t, y); b = max(b, y)
                edge = edge || x == 0 || y == 0 || x == w - 1 || y == h - 1
                for j in neighbors(i) where safe[j] == 0 && labels[j] == 0 { labels[j] = label; queue.append(j) }
            }
            parts.append(Part(label: label, l: l, t: t, r: r, b: b, count: queue.count, edge: edge,
                barrier: edge && Double(max(r - l + 1, b - t + 1)) > glyph * 2 && Double(queue.count) >= glyph * 2))
        }
        let candidates = parts.filter { p in !p.edge && Double(max(p.r - p.l + 1, p.b - p.t + 1)) >= glyph * 0.35 &&
            Double(max(p.r - p.l + 1, p.b - p.t + 1)) <= glyph * 2 && Double(p.count) >= glyph * glyph * 0.05 && core.contains { q in
                Double(p.r) >= Double(q.minX) - glyph && Double(p.l) <= Double(q.maxX) + glyph &&
                    Double(p.b) >= Double(q.minY) - glyph && Double(p.t) <= Double(q.maxY) + glyph
            } }
        if candidates.count < 2 { return false }
        if candidates.count > 256 { return true }
        let barriers = Set(parts.filter(\.barrier).map(\.label))
        var reachable = [UInt8](repeating: 0, count: n), queue: [Int] = [], seedBudget = n * 2, head = 0
        for q in core {
            let l = max(0, Int(floor(q.minX))), t = max(0, Int(floor(q.minY))), r = min(w, Int(ceil(q.maxX))), b = min(h, Int(ceil(q.maxY)))
            if l < r && t < b { for y in t..<b { for x in l..<r {
                seedBudget -= 1
                if seedBudget < 0 { return true }
                let i = y * w + x
                if reachable[i] == 0 && !barriers.contains(labels[i]) { reachable[i] = 1; queue.append(i) }
            } } }
        }
        while head < queue.count {
            let i = queue[head]; head += 1
            for j in neighbors(i) where reachable[j] == 0 && !barriers.contains(labels[j]) { reachable[j] = 1; queue.append(j) }
        }
        let visible = Set((0..<n).filter { reachable[$0] != 0 && labels[$0] != 0 }.map { labels[$0] })
        let lettering = candidates.filter { visible.contains($0.label) }
        for i in lettering.indices { for j in lettering.indices where j > i {
            let a = lettering[i], b = lettering[j]
            let aligned = vertical ? Double(min(a.r, b.r)) >= Double(max(a.l, b.l)) - glyph * 0.12 :
                Double(min(a.b, b.b)) >= Double(max(a.t, b.t)) - glyph * 0.12
            let gap = vertical ? max(a.t, b.t) - min(a.b, b.b) : max(a.l, b.l) - min(a.r, b.r)
            let span = vertical ? max(a.b, b.b) - min(a.t, b.t) + 1 : max(a.r, b.r) - min(a.l, b.l) + 1
            if aligned && Double(gap) <= glyph && Double(span) >= glyph * 0.75 && Double(a.count + b.count) >= glyph * glyph * 0.1 { return true }
        } }
        return false
    }
    private static func finite(_ r: CGRect) -> Bool { [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) }
    private static func valid(_ mask: [UInt8], _ w: Int, _ h: Int) -> Bool { w > 0 && h > 0 && w <= 262_144 / h && mask.count == w * h }
}

