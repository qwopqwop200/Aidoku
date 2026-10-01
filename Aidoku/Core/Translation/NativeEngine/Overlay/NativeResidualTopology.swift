import CoreGraphics
import Foundation

/// Frozen final-erasure topology gates. Safe bytes are truthy except the strict main-body gate.
enum NativeResidualTopology {
    private static func validSize(_ w: Int, _ h: Int, _ safe: [UInt8]) -> Bool {
        w > 0 && h > 0 && w <= 262_144 / h && safe.count == w * h
    }
    private static func rect(_ r: [Double]) -> Bool { r.count == 4 && r.allSatisfy(\.isFinite) }

    static func hasResidualLettering(safe: [UInt8], width w: Int, height h: Int, regions: [[Double]], glyphSize: Double) -> Bool {
        guard validSize(w, h, safe), !regions.isEmpty, regions.allSatisfy(rect), glyphSize.isFinite, glyphSize > 0 else { return true }
        var seen = [Bool](repeating: false, count: safe.count)
        let limit = max(12, glyphSize * 2)
        for start in safe.indices where safe[start] == 0 && !seen[start] {
            var queue = [start], head = 0, l = w, t = h, r = 0, b = 0
            seen[start] = true
            while head < queue.count {
                let i = queue[head], x = i % w, y = i / w; head += 1
                l = min(l, x); r = max(r, x); t = min(t, y); b = max(b, y)
                for yy in max(0, y - 1)...min(h - 1, y + 1) { for xx in max(0, x - 1)...min(w - 1, x + 1) {
                    let j = yy * w + xx
                    if safe[j] == 0 && !seen[j] { seen[j] = true; queue.append(j) }
                } }
            }
            if queue.count >= 2 && Double(max(r - l + 1, b - t + 1)) <= limit && regions.contains(where: {
                Double(r) >= $0[0] - glyphSize && Double(l) <= $0[0] + $0[2] + glyphSize &&
                Double(b) >= $0[1] - glyphSize && Double(t) <= $0[1] + $0[3] + glyphSize
            }) { return true }
        }
        return false
    }

    static func hasAttachedLeadingInk(safe: [UInt8], width w: Int, height h: Int, core: [[Double]], glyph: Double) -> Bool {
        guard validSize(w, h, safe), glyph.isFinite, glyph > 0 else { return true }
        let radius = Int(max(4, min(64, ceil(glyph * 0.9)))), depth = max(2, glyph * 0.22)
        var budget = Double(w * h * 2)
        for r in core {
            guard rect(r), r[2] > 0, r[3] > 0 else { return true }
            let edge = max(0, ceil(r[0] + r[2])), right = min(Double(w), ceil(edge + glyph * 1.5))
            let top = max(0, floor(r[1])), bottom = min(Double(h), ceil(r[1] + r[3]))
            budget -= max(0, bottom - top) * (max(0, right - edge) + Double(radius * 2))
            if budget < 0 { return true }
            var first: [Double] = []
            if top < bottom { for y in Int(top)..<Int(bottom) {
                var x = edge
                while x < right && safe[y * w + Int(x)] != 0 { x += 1 }
                first.append(x)
            } }
            var runs: [(Int, Int)] = [], start = -1
            for y in 0...first.count {
                var before = 0.0, after = 0.0
                if max(0, y - radius) < y - 1 { for k in max(0, y - radius)..<(y - 1) { before = max(before, first[k]) } }
                if y + 2 < min(first.count, y + radius + 1) { for k in (y + 2)..<min(first.count, y + radius + 1) { after = max(after, first[k]) } }
                let protrudes = y < first.count && first[y] - edge <= glyph && min(before, after) - first[y] >= depth
                if protrudes && start < 0 { start = y }
                if !protrudes && start >= 0 {
                    if y - start >= 2 && Double(y - start) <= glyph * 1.5 { runs.append((start, y)) }
                    start = -1
                }
            }
            if runs.count > 1 { for i in 1..<runs.count {
                if Double(runs[i].0 - runs[i - 1].1) <= glyph * 2 && Double(runs[i].1 - runs[i].0 + runs[i - 1].1 - runs[i - 1].0) >= glyph * 0.5 { return true }
            } }
        }
        return false
    }

    static func restoredErasureCovers(safe: [UInt8], width w: Int, height h: Int, regions: [[Double]], glyphSize: Double, core: [[Double]]) -> Bool {
        func valid(_ regions: [[Double]]) -> Bool {
            !regions.isEmpty && regions.allSatisfy { rect($0) && $0[2] > 0 && $0[3] > 0 && $0[0] >= 0 && $0[1] >= 0 && $0[0] + $0[2] <= Double(w) && $0[1] + $0[3] <= Double(h) }
        }
        guard validSize(w, h, safe), valid(regions), valid(core) else { return false }
        var budget = w * h * 2
        for r in core {
            let l = Int(floor(r[0])), t = Int(floor(r[1])), right = Int(ceil(r[0] + r[2])), bottom = Int(ceil(r[1] + r[3]))
            budget -= (right - l) * (bottom - t)
            if budget < 0 { return false }
            for y in t..<bottom { for x in l..<right { if safe[y * w + x] == 0 { return false } } }
        }
        return !hasResidualLettering(safe: safe, width: w, height: h, regions: regions, glyphSize: glyphSize)
    }

    static func mainbodyCellsClear(safe: [UInt8], width w: Int, height h: Int, regions: [[Double]]) -> Bool {
        guard validSize(w, h, safe), !regions.isEmpty else { return false }
        var budget = Double(w * h * 2)
        for r in regions {
            guard rect(r), r[2] > 0, r[3] > 0 else { return false }
            let l = floor(r[0]), t = floor(r[1]), right = ceil(r[0] + r[2]), bottom = ceil(r[1] + r[3])
            budget -= (right - l) * (bottom - t)
            guard l >= 0, t >= 0, right <= Double(w), bottom <= Double(h), budget >= 0 else { return false }
            for y in Int(t)..<Int(bottom) { for x in Int(l)..<Int(right) { if safe[y * w + x] != 1 { return false } } }
        }
        return true
    }

    struct Surface: Equatable {
        var width: Int
        var height: Int
        var rgba: [UInt8]
        var safe: [UInt8]
        var luminance: [UInt8]
        var surfaceRevision = 0
        var enclosedSpecks: Int?
        var coreClear: Bool?
        var innerCoreClear: Bool?
        var residualLettering: Bool?
    }
    struct SpeckUndo {
        fileprivate let previous: Surface
        func restore(_ surface: inout Surface) {
            let revision = surface.surfaceRevision + 1
            surface = previous
            surface.surfaceRevision = revision
            surface.enclosedSpecks = nil
        }
    }
    static func fillEnclosedSpecks(surface: inout Surface) -> SpeckUndo? {
        let w = surface.width, h = surface.height
        guard validSize(w, h, surface.safe), surface.rgba.count == w * h * 4 else { return nil }
        let safe = surface.safe, rgba = surface.rgba
        var seen = [Bool](repeating: false, count: safe.count), fills: [([Int], [UInt8])] = []
        for start in safe.indices where safe[start] == 0 && !seen[start] {
            var part = [start], head = 0, open = true; seen[start] = true
            while head < part.count {
                let x = part[head] % w, y = part[head] / w; head += 1
                for yy in (y - 1)...(y + 1) { for xx in (x - 1)...(x + 1) {
                    if xx < 0 || yy < 0 || xx >= w || yy >= h { open = false; continue }
                    let j = yy * w + xx
                    if safe[j] == 0 && !seen[j] { seen[j] = true; part.append(j) }
                } }
            }
            if !open || part.count > 4 { continue }
            var members: [Int] = [], ring = Set<Int>()
            for i in part {
                let x = i % w, y = i / w
                for yy in (y - 1)...(y + 1) { for xx in (x - 1)...(x + 1) {
                    let j = yy * w + xx
                    if safe[j] != 0 && ring.insert(j).inserted { members.append(j) }
                } }
            }
            if members.contains(where: { rgba[$0 * 4 + 3] != 255 }) { continue }
            let mean = (0..<3).map { c in members.reduce(0.0) { $0 + Double(rgba[$1 * 4 + c]) } / Double(members.count) }
            if members.contains(where: { i in (0..<3).contains { abs(Double(rgba[i * 4 + $0]) - mean[$0]) > 12 } }) { continue }
            fills.append((part, mean.map { UInt8($0.rounded(.toNearestOrAwayFromZero)) }))
        }
        if fills.isEmpty { return nil }
        let undo = SpeckUndo(previous: surface)
        func linear(_ byte: UInt8) -> Double {
            let v = Double(byte) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        for (part, rgb) in fills {
            let l = UInt8((255 * (0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2]))).rounded(.toNearestOrAwayFromZero))
            for i in part { for c in 0..<3 { surface.rgba[i * 4 + c] = rgb[c] }; surface.rgba[i * 4 + 3] = 255; surface.safe[i] = 1; if i < surface.luminance.count { surface.luminance[i] = l } }
        }
        surface.surfaceRevision += 1; surface.enclosedSpecks = fills.count
        surface.coreClear = nil; surface.innerCoreClear = nil; surface.residualLettering = nil
        return undo
    }

    static func hiddenForeignRepaint(width w: Int, height h: Int, imageSize: CGSize, frame: CGRect, cropOrigin: CGPoint,
                                     scale: CGSize, sourceFontSize: Double?, sourceBounds: [Double], auxiliaryInkRects: [[Double]],
                                     plate: CGRect, detachedProposal: Bool, rgba: [UInt8]) -> Int {
        guard w > 0, h > 0, w <= 262_144 / h, rgba.count == w * h * 4, frame.width > 0, frame.height > 0 else { return 0 }
        let iw = Double(imageSize.width), ih = Double(imageSize.height), sx = Double(scale.width), sy = Double(scale.height)
        let kx = iw / Double(frame.width) * sx, ky = ih / Double(frame.height) * sy
        let font = sourceFontSize.flatMap { $0.isNaN || $0 == 0 ? nil : $0 } ?? 8
        let glyph = max(4, font * kx), reach = max(3, glyph * 0.35)
        let x = Double(cropOrigin.x), y = Double(cropOrigin.y)
        let core = ([sourceBounds] + auxiliaryInkRects).filter(rect).map { a in
            [(a[0] * iw - x) * sx - reach, (a[1] * ih - y) * sy - reach,
             (a[0] + a[2]) * iw * sx - x * sx + reach, (a[1] + a[3]) * ih * sy - y * sy + reach]
        }
        let l0 = floor(((Double(plate.minX - frame.minX) * iw / Double(frame.width)) - x) * sx)
        let t0 = floor(((Double(plate.minY - frame.minY) * ih / Double(frame.height)) - y) * sy)
        let l = detachedProposal ? 0 : max(0, l0), t = detachedProposal ? 0 : max(0, t0)
        let r = detachedProposal ? Double(w) : min(Double(w), ceil(l0 + Double(plate.width) * kx + 1))
        let b = detachedProposal ? Double(h) : min(Double(h), ceil(t0 + Double(plate.height) * ky + 1))
        guard l.isFinite, t.isFinite, r.isFinite, b.isFinite, l < r, t < b else { return 0 }
        var count = 0
        for yy in Int(t)..<Int(b) { for xx in Int(l)..<Int(r) {
            if rgba[(yy * w + xx) * 4 + 3] == 0 { continue }
            if !core.contains(where: { Double(xx) + 0.5 >= $0[0] && Double(xx) + 0.5 <= $0[2] && Double(yy) + 0.5 >= $0[1] && Double(yy) + 0.5 <= $0[3] }) { count += 1 }
        } }
        return Double(count) > max(16, glyph * glyph * 0.1) ? count : 0
    }
}
