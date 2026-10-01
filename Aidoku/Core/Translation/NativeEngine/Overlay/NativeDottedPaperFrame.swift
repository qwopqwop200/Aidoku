import CoreGraphics
import Foundation

/// A disconnected source rim must connect two original frame anchors through a
/// single thin arc. Proximity alone cannot turn punctuation or ruby into frame.
enum NativeDottedPaperFrame {
    struct Protection {
        let mask: [UInt8]
        // The contour proof alone never establishes ownership of the erased text.
        var pageErasureVerified = false
    }

    static func permitsNarrowReflow(_ p: NativeRestorationPixels) -> Bool {
        guard p.width > 4, p.height > 4, p.width <= 65_536 / p.height,
              p.rgba.count == p.count * 4,
              let proof = p.dottedFrameProtection, proof.pageErasureVerified,
              p.preservedCore == 0, p.preservedPixels == 0,
              proof.mask.count == p.count, let safe = p.layoutSafe, safe.count == p.count,
              proof.mask.contains(1) else { return false }
        return proof.mask.indices.allSatisfy { proof.mask[$0] == 0 || (p.rgba[$0 * 4 + 3] == 0 && safe[$0] == 0) }
    }

    static func mask(_ p: NativeRestorationPixels, box: CGRect) -> [UInt8]? {
        guard p.width > 4, p.height > 4, p.count <= 65_536,
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.width >= 12, box.width <= 64, box.height >= box.width * 2, box.height <= box.width * 7,
              box.minX >= 3, box.minY >= 3, box.maxX <= CGFloat(p.width - 3), box.maxY <= CGFloat(p.height - 3) else { return nil }
        let ink = (0..<p.count).map { p.color($0).minimum < 230 ? UInt8(1) : 0 }
        let parts = p.components(ink)
        guard parts.count <= 128 else { return nil }
        let roots = parts.indices.filter { k in
            let part = parts[k]
            return part.rect.intersects(box.insetBy(dx: -2, dy: -2)) &&
                max(part.rect.width, part.rect.height) >= box.height * 0.25 &&
                part.points.contains { i in
                    let x = i % p.width, y = i / p.width
                    return x <= 1 || y <= 1 || x >= p.width - 2 || y >= p.height - 2
                }
        }
        guard roots.count == 2 else { return nil }
        var labels = [Int](repeating: -1, count: p.count)
        for k in parts.indices { for i in parts[k].points { labels[i] = k } }
        var adjacent = [Set<Int>](repeating: [], count: parts.count)
        // At most one missing light pixel separates adjacent antialiased dashes.
        // This bounded source-grid search costs at most 21 visits per ink pixel.
        for i in 0..<p.count where labels[i] >= 0 {
            let x = i % p.width, y = i / p.width, a = labels[i]
            for dy in -2...2 { for dx in -2...2 where dx * dx + dy * dy <= 5 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < p.width, yy < p.height else { continue }
                let b = labels[yy * p.width + xx]
                if b >= 0, b != a { adjacent[a].insert(b) }
            } }
        }
        var live: Set<Int> = [roots[0]], queue = [roots[0]], cursor = 0
        while cursor < queue.count {
            let a = queue[cursor]; cursor += 1
            for b in adjacent[a] where live.insert(b).inserted { queue.append(b) }
        }
        guard live.contains(roots[1]) else { return nil }
        let anchors = Set(roots)
        while true {
            let leaves = live.filter { !anchors.contains($0) && adjacent[$0].intersection(live).count < 2 }
            if leaves.isEmpty { break }
            live.subtract(leaves)
        }
        // A second path could be text joining a rim, so cycles always abstain.
        guard (14...64).contains(live.count), live.allSatisfy({
            adjacent[$0].intersection(live).count == (anchors.contains($0) ? 1 : 2)
        }) else { return nil }
        var path = [roots[0]], previous = -1
        while path.last != roots[1] {
            let next = adjacent[path.last!].intersection(live).filter { $0 != previous }
            guard next.count == 1, let value = next.first, !path.contains(value) else { return nil }
            previous = path.last!; path.append(value)
        }
        guard path.count == live.count else { return nil }
        var centers = path.map { k in
            CGPoint(x: Double(parts[k].points.reduce(0) { $0 + $1 % p.width }) / Double(parts[k].points.count),
                    y: Double(parts[k].points.reduce(0) { $0 + $1 / p.width }) / Double(parts[k].points.count))
        }
        for (index, neighbor) in [(0, 1), (path.count - 1, path.count - 2)] {
            let center = centers[neighbor]
            let closest = parts[path[index]].points.min { a, b in
                let ax = CGFloat(a % p.width) - center.x, ay = CGFloat(a / p.width) - center.y
                let bx = CGFloat(b % p.width) - center.x, by = CGFloat(b / p.width) - center.y
                return ax * ax + ay * ay < bx * bx + by * by
            }!
            centers[index] = CGPoint(x: closest % p.width, y: closest / p.width)
        }
        var sweep: CGFloat = 0, direction: CGFloat = 0
        for k in 1..<centers.count {
            let a = atan2(centers[k - 1].y - box.midY, centers[k - 1].x - box.midX)
            let b = atan2(centers[k].y - box.midY, centers[k].x - box.midX)
            let turn = atan2(sin(b - a), cos(b - a))
            if direction == 0 { direction = turn }
            guard abs(turn) <= .pi / 4, turn * direction > 0 else { return nil }
            sweep += turn
        }
        guard abs(sweep) >= .pi + 0.35, abs(sweep) <= .pi * 1.75 else { return nil }
        for k in 1..<(path.count - 1) {
            let center = centers[k], dx = centers[k + 1].x - centers[k - 1].x, dy = centers[k + 1].y - centers[k - 1].y
            let length = hypot(dx, dy)
            let radius = hypot((center.x - box.midX) / (box.width / 2), (center.y - box.midY) / (box.height / 2))
            guard length > 0, radius >= 0.75, radius <= 1.5 else { return nil }
            var low = CGFloat.infinity, high = -CGFloat.infinity
            for i in parts[path[k]].points {
                let normal = (-dy * CGFloat(i % p.width) + dx * CGFloat(i / p.width)) / length
                low = min(low, normal); high = max(high, normal)
                let color = p.color(i)
                guard p.rgba[i * 4 + 3] == 255, color.maximum - color.minimum <= 12 else { return nil }
            }
            // A glyph-shaped bridge has transverse strokes, unlike this rim.
            guard high - low <= 4 else { return nil }
        }
        var frame = [UInt8](repeating: 0, count: p.count)
        for k in path { for i in parts[k].points { frame[i] = 1 } }
        // Preserve only nearby antialias pixels whose nearest actual ink belongs
        // uniquely to this rim. A neighboring glyph never becomes frame by dilation.
        let core = frame
        for i in 0..<p.count where ink[i] == 0 && p.color(i).minimum < 255 {
            var nearestFrame = 6, nearestOther = 6
            let x = i % p.width, y = i / p.width
            for dy in -2...2 { for dx in -2...2 where dx * dx + dy * dy <= 5 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < p.width, yy < p.height else { continue }
                let j = yy * p.width + xx
                if core[j] != 0 { nearestFrame = min(nearestFrame, dx * dx + dy * dy) }
                else if ink[j] != 0 { nearestOther = min(nearestOther, dx * dx + dy * dy) }
            } }
            if nearestFrame < nearestOther { frame[i] = 1 }
        }
        return frame
    }

    static func protecting(_ p: NativeRestorationPixels, box: CGRect, vertical: Bool,
                           repaired: NativeRestorationPixels) -> NativeRestorationPixels {
        guard vertical, !repaired.erasureComplete, p.width == repaired.width, p.height == repaired.height,
              let frame = mask(p, box: box), var safe = repaired.layoutSafe, safe.count == p.count else { return repaired }
        var output = repaired, clippedInk = false
        for i in frame.indices where frame[i] != 0 {
            if output.rgba[i * 4 + 3] != 0 && output.color(i).distance(p.color(i)) > 24 { clippedInk = true }
            output.rgba[i * 4 + 3] = 0; safe[i] = 0
        }
        output.layoutSafe = safe
        output.dottedFrameProtection = Protection(mask: frame)
        if clippedInk {
            output.sourceErasureVerified = false; output.glyphsVerified = false; output.polygonGlyphsVerified = false
        }
        return output
    }
}
