import CoreGraphics
import Foundation

extension NativeObservedRestoreState {
    func codecIslands() {
        if measuredHalo && foreground.maximum - foreground.minimum >= 24 {
            var islands: [Int] = []
            let halo = palette.stroke.map { $0.distance(background) >= 40 } ?? false
            let fgSpan = foreground.maximum - foreground.minimum
            for part in pixels.components(protectedInk) where part.points.count <= 16 {
                var legacy = part.points.count <= 4, owned = halo, nearby = false, contacts = 0, outline = 0
                var compatible = 0, inCore = true, neutral = false
                for i in part.points {
                    let x = i % pixels.width, y = i / pixels.width, rgb = pixels.color(i)
                    let span = rgb.maximum - rgb.minimum
                    let shade = zip(rgb.channels, foreground.channels).map(-)
                    if raw[i] != 0 { legacy = false }
                    if drawingSurface[i] != 0 || frameInk[i] != 0 { legacy = false; owned = false; break }
                    if (shade.max()! - shade.min()!) > 32 || !accepted.contains(where: {
                        CGFloat(x) > $0.rect.minX && CGFloat(x) < $0.rect.maxX - 1 &&
                            CGFloat(y) > $0.rect.minY && CGFloat(y) < $0.rect.maxY - 1
                    }) { legacy = false }
                    let hueError = zip(rgb.channels, foreground.channels).map {
                        abs(($0 - rgb.minimum) / max(1, span) - ($1 - foreground.minimum) / fgSpan)
                    }.max()!
                    let darkNeutral = span < 12 && rgb.maximum < background.minimum - 24
                    neutral = neutral || darkNeutral
                    if !darkNeutral && (span < 12 || hueError > 0.25) || CGFloat(x) < box.minX || CGFloat(x) >= box.maxX ||
                        CGFloat(y) < box.minY || CGFloat(y) >= box.maxY { owned = false }
                    if !accepted.contains(where: {
                        within(CGPoint(x: x, y: y), CGRect(x: $0.rect.minX, y: $0.rect.minY,
                            width: $0.rect.width - 1, height: $0.rect.height - 1), margin: 1)
                    }) { inCore = false }
                    if !owned { continue }
                    for j in pixels.neighbors(i) where protectedInk[j] == 0 {
                        contacts += 1
                        if mask[j] != 0 { compatible += 1; nearby = true }
                        else if palette.stroke.map({ pixels.color(j).distance($0) <= 32 }) == true { compatible += 1; outline += 1 }
                        else if palette.stroke.map({ Pixels.blend(pixels.color(j), from: foreground, to: $0) }) == true { compatible += 1 }
                    }
                }
                if owned && !nearby, let i = part.points.first {
                    nearby = pixels.indices(CGRect(x: i % pixels.width - 10, y: i / pixels.width - 10, width: 21, height: 21))
                        .contains { mask[$0] != 0 }
                }
                if legacy || owned && nearby && contacts >= 4 &&
                    (!neutral && inCore && Double(compatible) >= Double(contacts) * 0.6 ||
                     Double(compatible) >= Double(contacts) * 0.875 && Double(outline) >= max(2, Double(contacts) * (neutral ? 0.5 : 0.15))) {
                    islands.append(contentsOf: part.points)
                }
            }
            for i in islands { mask[i] = 1; protectedInk[i] = 0; seedRadius[i] = UInt8(radius) }
        }
        if options.readabilityGate && options.vertical && (!options.slantedOwnership || measuredHalo) &&
            box.height >= box.width && accepted.count >= 6 {
            let colors = [foreground, palette.stroke].compactMap { $0 }.filter { $0.maximum - $0.minimum >= 40 }
            var islands: [Int] = []
            for part in pixels.components(protectedInk) where !colors.isEmpty && part.points.count <= 96 {
                var owned = true, offHue = 0, tight = true
                for i in part.points {
                    let x = i % pixels.width, y = i / pixels.width, rgb = pixels.color(i)
                    if raw[i] != 0 || frameInk[i] != 0 || drawingSurface[i] != 0 || CGFloat(x) < box.minX || CGFloat(x) >= box.maxX ||
                        CGFloat(y) < box.minY || CGFloat(y) >= box.maxY { owned = false; break }
                    let span = rgb.maximum - rgb.minimum
                    if span < 12 || !colors.contains(where: { color in
                        let range = color.maximum - color.minimum
                        return zip(rgb.channels, color.channels).map { abs(($0 - rgb.minimum) / span - ($1 - color.minimum) / range) }.max()! <= 0.28
                    }) { offHue += 1 }
                    let nearby = pixels.indices(CGRect(x: x - radius, y: y - radius, width: radius * 2 + 1, height: radius * 2 + 1))
                        .contains { mask[$0] != 0 }
                    if !nearby { owned = false }
                    let close = pixels.indices(CGRect(x: x - 2, y: y - 2, width: 5, height: 5)).contains { mask[$0] != 0 }
                    tight = tight && close && accepted.contains {
                        CGFloat(x) > $0.rect.minX && CGFloat(x) < $0.rect.maxX - 1 && CGFloat(y) > $0.rect.minY && CGFloat(y) < $0.rect.maxY - 1
                    }
                }
                if owned && (Double(offHue) <= min(4, Double(part.points.count) * 0.25) || part.points.count <= 4 && tight) {
                    islands.append(contentsOf: part.points)
                }
            }
            for i in islands { mask[i] = 1; protectedInk[i] = 0; seedRadius[i] = UInt8(min(radius, 6)) }
        }
    }

    /// Freeze source masks while evaluating enclosed codec islands. No admitted
    /// island may recursively establish ownership of a neighbouring drawing.
    func enclosedResidualIslands() {
        guard options.readabilityGate && options.vertical && !options.slantedOwnership && unresolved > 0 && unresolved <= 32 &&
            ([foreground, palette.stroke].compactMap { $0 }.contains { $0.maximum - $0.minimum >= 40 } ||
             palette.stroke != nil && palette.strokeConfidence >= 0.6) else { return }
        let outlined = palette.stroke.map { palette.strokeConfidence >= 0.6 && $0.distance(foreground) >= 40 } ?? false
        var visited = [UInt8](repeating: 0, count: pixels.count), pending: [Int] = []
        for y in Int(ceil(box.minY))..<Int(floor(box.maxY)) { for x in Int(ceil(box.minX))..<Int(floor(box.maxX)) {
            let start = y * pixels.width + x
            guard visited[start] == 0, protectedInk[start] != 0, raw[start] == 0, frameInk[start] == 0, drawingSurface[start] == 0 else { continue }
            var island = [start], head = 0, valid = true, left = x, right = x, top = y, bottom = y
            visited[start] = 1
            while head < island.count {
                let i = island[head]; head += 1
                let cx = i % pixels.width, cy = i / pixels.width
                left = min(left, cx); right = max(right, cx); top = min(top, cy); bottom = max(bottom, cy)
                if raw[i] != 0 || frameInk[i] != 0 || drawingSurface[i] != 0 || CGFloat(cx) < box.minX - 2 || CGFloat(cx) >= box.maxX + 2 ||
                    CGFloat(cy) < box.minY - 2 || CGFloat(cy) >= box.maxY + 2 { valid = false }
                for j in pixels.neighbors(i) where protectedInk[j] != 0 && visited[j] == 0 { visited[j] = 1; island.append(j) }
                if island.count > 32 { valid = false; break }
            }
            guard valid, outlined || island.count <= 4, right - left <= 12, bottom - top <= 12 else { continue }
            let own = Set(island); var border = 0, owned = 0
            for i in island { for j in pixels.neighbors(i) where !own.contains(j) {
                border += 1; if frameInk[j] != 0 || drawingSurface[j] != 0 { valid = false }
                if mask[j] != 0 { owned += 1 }
            } }
            var widerBorder = 0, widerOwned = 0
            if valid && island.count <= 4 && Double(owned) / Double(border) >= 0.6 {
                var ring = Set<Int>()
                for i in island {
                    for j in pixels.indices(CGRect(x: i % pixels.width - 2, y: i / pixels.width - 2, width: 5, height: 5)) where !own.contains(j) {
                        ring.insert(j)
                    }
                }
                for j in ring {
                    widerBorder += 1; if mask[j] != 0 { widerOwned += 1 }
                    if frameInk[j] != 0 || drawingSurface[j] != 0 { valid = false }
                }
            }
            if valid && border > 0 && (Double(owned) / Double(border) >= 0.9 ||
                widerBorder > 0 && Double(widerOwned) / Double(widerBorder) >= 0.85) { pending.append(contentsOf: island) }
        } }
        for i in pending { mask[i] = 1; protectedInk[i] = 0 }
        if !pending.isEmpty { queueTail = NativeObservedRestorationHelpers.maskQueue(mask, queue: &queue, n: pixels.count); unresolved = pixels.indices(box).filter { protectedInk[$0] != 0 && frameInk[$0] == 0 }.count }
    }
}
