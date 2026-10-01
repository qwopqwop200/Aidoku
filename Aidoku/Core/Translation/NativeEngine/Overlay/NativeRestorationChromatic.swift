import CoreGraphics
import Foundation

extension NativeRestorationPixels {
    /// White/colored lettering is established by observed enclosing islands and halos.
    /// This route also repairs text over garments, masonry and drawing, preserving blocked art.
    static func chromatic(_ p: Self, box: CGRect, auxiliary: [CGRect], excluded: [CGRect],
                          fill: NativeRestorationRGB, stroke: NativeRestorationRGB?, background: NativeRestorationRGB?,
                          vertical: Bool, recovery: Bool, coreDistance: Double = .infinity,
                          darkOutlineVerified: Bool = true, glyphPixels: Double = 0) -> Self? {
        let outlined = fill.minimum >= 220 && stroke.map { $0.maximum - $0.minimum >= 60 || $0.maximum <= 60 } == true
        let darkFill = fill.maximum <= 80 && stroke.map { $0.minimum >= 230 } == true && darkOutlineVerified
        let foreground = outlined ? stroke! : fill
        let neutral = outlined && foreground.maximum <= 60 || darkFill
        let darkLimit = darkFill ? min(90, foreground.maximum + 32) : 90
        guard p.count >= 64, p.count <= 262_144,
              p.rgba.enumerated().allSatisfy({ $0.offset % 4 != 3 || $0.element >= 254 }),
              neutral || foreground.maximum - foreground.minimum >= (outlined ? 60 : 90),
              box.minX >= 2, box.minY >= 2, box.maxX <= CGFloat(p.width - 2), box.maxY <= CGFloat(p.height - 2) else { return nil }
        let hue = foreground.channels.map { ($0 - foreground.minimum) * 255 / (foreground.maximum - foreground.minimum) }
        func inside(_ index: Int) -> Bool {
            let point = CGPoint(x: index % p.width, y: index / p.width)
            return box.insetBy(dx: -1, dy: -1).contains(point) || auxiliary.contains { $0.contains(point) }
        }
        var raw = [UInt8](repeating: 0, count: p.count), mask = raw, blocked = raw
        for index in 0..<p.count {
            let color = p.color(index), span = color.maximum - color.minimum
            if neutral {
                if color.maximum <= darkLimit && span <= 35 { raw[index] = 1 }
            } else if color.distance(foreground) <= coreDistance, span >= 65,
                      zip(color.channels.map { ($0 - color.minimum) * 255 / span }, hue).map({ abs($0 - $1) }).max()! <= 28 {
                raw[index] = 1
            }
        }
        var holes = [Int](repeating: 0, count: p.count), holeGroups: [[Int]] = [[]], antialiased: [[Int]] = []
        if outlined {
            let limit = max(12, min(box.width, box.height))
            let open = raw.map { $0 == 0 ? UInt8(1) : 0 }
            for part in p.components(open, diagonal: false) {
                let rect = part.rect, l = rect.minX, r = rect.maxX - 1, t = rect.minY, d = rect.maxY - 1
                let edge = l == 0 || t == 0 || r == CGFloat(p.width - 1) || d == CGFloat(p.height - 1)
                let bright = part.points.filter { let color = p.color($0); return color.minimum >= 220 && color.maximum - color.minimum <= 35 }.count
                let pale = recovery ? part.points.filter { let color = p.color($0); return color.minimum >= 200 && color.maximum - color.minimum <= 45 }.count : 0
                let brightFill = Double(bright) >= max(3, Double(part.points.count) * 0.45) || recovery &&
                    Double(bright) >= max(3, Double(part.points.count) * 0.35) && Double(pale) >= Double(part.points.count) * 0.7
                let centerIndex = Int((t + d) / 2) * p.width + Int((l + r) / 2)
                let expandedOwn = recovery && (l + r) / 2 >= box.minX && (l + r) / 2 <= box.maxX &&
                    t < box.maxY && d > box.minY && t >= box.minY - 24 && d <= box.maxY + min(80, limit * 0.85) &&
                    !excluded.contains { $0.intersects(rect) }
                let own = inside(centerIndex) || expandedOwn
                guard !edge, part.points.count >= 3, r - l < limit * 2, d - t < limit * 2, own else { continue }
                if brightFill {
                    let id = holeGroups.count; holeGroups.append(part.points)
                    for index in part.points { holes[index] = id }
                } else if recovery {
                    var blended = 0, peak = 0.0
                    let delta = foreground.channels.map { 255 - $0 }, norm = max(1, delta.reduce(0) { $0 + $1 * $1 })
                    for index in part.points {
                        let color = p.color(index)
                        let factor = min(1, max(0, zip(zip(color.channels, foreground.channels), delta)
                            .reduce(0.0) { $0 + ($1.0.0 - $1.0.1) * $1.1 } / norm))
                        if zip(zip(color.channels, foreground.channels), delta).map({ abs($0.0.0 - $0.0.1 - factor * $0.1) }).max()! <= 18 { blended += 1 }
                        peak = max(peak, color.minimum)
                    }
                    if Double(blended) >= Double(part.points.count) * 0.65, peak >= (neutral ? 240 : 210),
                       neutral ? bright >= 3 : Double(max(bright, pale)) >= max(3, Double(part.points.count) * 0.15) {
                        antialiased.append(part.points)
                    }
                }
            }
            if holeGroups.count >= 5 {
                for group in antialiased { let id = holeGroups.count; holeGroups.append(group); for index in group { holes[index] = id } }
            }
        }
        if outlined && holeGroups.count >= 5 {
            var distance = [UInt8](repeating: 0, count: p.count), front: [Int] = []
            for index in 0..<p.count where holes[index] != 0 || raw[index] != 0 && inside(index) && p.color(index).distance(foreground) <= 32 {
                distance[index] = 1; front.append(index)
            }
            let ring = max(4, min(12, Int(ceil(min(box.width, box.height) * 0.16))))
            var head = 0
            while head < front.count {
                let index = front[head]; head += 1
                guard Int(distance[index]) <= ring else { continue }
                for next in p.neighbors(index, diagonal: false) where distance[next] == 0 && raw[next] != 0 {
                    distance[next] = distance[index] + 1; front.append(next)
                }
            }
            for part in p.components(raw, diagonal: false) where part.touchesEdge {
                for index in part.points where distance[index] == 0 {
                    raw[index] = 0
                    let color = p.color(index)
                    var clean = background.map { color.distance($0) <= 64 && color.distance(foreground) > 64 } ?? false
                    if clean, p.neighbors(index, diagonal: false).contains(where: { color.distance(p.color($0)) > 12 }) { clean = false }
                    blocked[index] = clean ? 0 : 1
                }
            }
        }
        struct Fragment { let points: [Int]; let radius: Int }
        struct Unresolved { let points: [Int]; let owned: Int }
        var fragments: [Fragment] = [], artSeeds: [Int] = [], unresolved: [Unresolved] = []
        var components = 0, cores = 0, unowned = 0, framePixels = 0, weakCores = 0
        for part in p.components(raw, diagonal: false) {
            let rect = part.rect, l = rect.minX, r = rect.maxX - 1, t = rect.minY, d = rect.maxY - 1
            let area = rect.width * rect.height, owned = part.points.filter(inside).count
            var border = 0, white = 0, enclosed = Set<Int>()
            for index in part.points {
                for next in [index - 1, index + 1, index - p.width, index + p.width] where next >= 0 && next < p.count && raw[next] == 0 {
                    if holes[next] != 0 { enclosed.insert(holes[next]) }
                    border += 1
                    let color = p.color(next)
                    var halo = color.minimum >= 230 && color.maximum - color.minimum <= 25
                    let direction = next - index
                    for step in 1...3 where !halo {
                        let probe = next + direction * step
                        if probe < 0 || probe >= p.count || raw[probe] != 0 { break }
                        let color = p.color(probe)
                        halo = color.minimum >= 238 && color.maximum - color.minimum <= 20
                    }
                    if halo { white += 1 }
                }
            }
            let whiteFraction = Double(white) / Double(max(1, border))
            let halo = outlined ? !enclosed.isEmpty || part.points.count <= 128 && border >= 12 && whiteFraction >= 0.65 : border >= 12 && whiteFraction >= 0.6
            let spill = min(recovery ? 80 : 8, min(box.width, box.height) * (recovery ? 0.85 : 0.25))
            let enclosedEdge = recovery && outlined && holeGroups.count >= 5 && !enclosed.isEmpty
            let terminal = enclosedEdge && vertical && t < box.maxY && t > box.maxY - min(box.width, box.height) * 0.5 &&
                (l + r) / 2 >= box.minX && (l + r) / 2 <= box.maxX
            let edgeGlyph = (whiteFraction >= 0.85 || enclosedEdge) && Double(owned) >= Double(part.points.count) * (terminal ? 0.2 : 0.5) &&
                l >= box.minX - spill && r <= box.maxX + spill && t >= box.minY - spill && d <= box.maxY + spill && !excluded.contains { $0.intersects(rect) }
            let enclosedStroke = recovery && outlined && !enclosed.isEmpty && whiteFraction >= 0.9
            let valid = !part.touchesEdge && halo && part.points.count >= 12 && min(r - l, d - t) >= 3 &&
                Double(part.points.count) >= area * 0.025 &&
                (Double(part.points.count) <= area * 0.95 || enclosedStroke || whiteFraction >= 0.9 && max(r - l, d - t) >= min(r - l, d - t) * 4) &&
                (Double(owned) >= Double(part.points.count) * 0.8 || edgeGlyph)
            if !valid && !part.touchesEdge && part.points.count <= (outlined ? 128 : 64) && owned == part.points.count {
                let radius = outlined ? 8 : darkFill && part.points.count <= 12 && whiteFraction >= 0.75 && glyphPixels > 0
                    ? max(3, min(8, Int(ceil(glyphPixels * 0.25)))) : 3
                fragments.append(Fragment(points: part.points, radius: radius))
            }
            let differentInk = recovery && outlined && holeGroups.count >= 5 && !halo && enclosed.isEmpty && whiteFraction < 0.1 &&
                part.points.allSatisfy { p.color($0).distance(foreground) > 48 }
            let crossing = differentInk || recovery && outlined && holeGroups.count >= 5 && !halo && enclosed.isEmpty && whiteFraction < 0.12 &&
                (Double(owned) < Double(part.points.count) * 0.95 ||
                 max(r - l, d - t) > min(box.width, box.height) * 0.75 && (l < box.minX - 2 || r > box.maxX + 2 || t < box.minY - 2 || d > box.maxY + 2) ||
                 max(r - l, d - t) > min(box.width, box.height) * 0.3 && max(r - l, d - t) >= max(1, min(r - l, d - t)) * 5 &&
                 (l < box.minX + 4 || r > box.maxX - 4 || t < box.minY + 4 || d > box.maxY - 4))
            if crossing {
                if fragments.last?.points == part.points { fragments.removeLast() }
                artSeeds.append(contentsOf: part.points)
            } else if !valid && !part.touchesEdge && Double(owned) >= Double(part.points.count) * 0.5 {
                unresolved.append(Unresolved(points: part.points, owned: owned))
            }
            if !valid {
                if crossing || Double(owned) < Double(part.points.count) * 0.5 || part.touchesEdge &&
                    (Double(part.points.count) < area * 0.1 || d < box.minY + box.height * 0.2 || t > box.minY + box.height * 0.8 ||
                     r < box.minX + box.width * 0.2 || l > box.minX + box.width * 0.8) { framePixels += owned }
                else { unowned += owned }
            }
            for index in part.points { if valid { mask[index] = 1 } else { blocked[index] = 1 } }
            if valid {
                components += 1; cores += part.points.count
                if !outlined && whiteFraction < 0.7 { weakCores += part.points.count }
                for id in enclosed { for index in holeGroups[id] { mask[index] = 1 } }
            }
        }
        if recovery && outlined && neutral && holeGroups.count >= 5 && !artSeeds.isEmpty {
            var connected = [UInt8](repeating: 0, count: p.count), front = artSeeds, head = 0
            for index in front { connected[index] = 1 }
            while head < front.count {
                let index = front[head]; head += 1
                for next in p.neighbors(index) where connected[next] == 0 && mask[next] == 0 && holes[next] == 0 && p.color(next).maximum <= 160 {
                    connected[next] = 1; front.append(next)
                }
            }
            for group in unresolved where group.points.allSatisfy({ connected[$0] != 0 }) {
                unowned -= group.owned; framePixels += group.owned
                fragments.removeAll { $0.points == group.points }
            }
        }
        guard components >= (outlined && holeGroups.count >= 5 ? 1 : 2), cores >= 32, Double(weakCores) <= Double(cores) * 0.2 else { return nil }
        let ownedMask = mask
        for fragment in fragments {
            let near = fragment.points.allSatisfy { index in
                let x = index % p.width, y = index / p.width
                for yy in max(1, y - fragment.radius)...min(p.height - 2, y + fragment.radius) {
                    for xx in max(1, x - fragment.radius)...min(p.width - 2, x + fragment.radius) where ownedMask[yy * p.width + xx] != 0 { return true }
                }
                return false
            }
            if near { for index in fragment.points { mask[index] = 1; blocked[index] = 0; unowned -= 1; cores += 1 } }
        }
        guard Double(unowned) <= max(3, Double(cores) * 0.002), Double(framePixels) <= Double(cores) * 0.5 else { return nil }
        // Exclusions constrain donors and the complete halo, not only component center tests.
        for rect in excluded { for index in p.indices(rect) { mask[index] = 0; blocked[index] = 1 } }
        var distance = [UInt8](repeating: 0, count: p.count), queue = (0..<p.count).filter { mask[$0] != 0 }, head = 0
        guard !queue.isEmpty else { return nil }
        let radius = max(4, min(20, Int(ceil(min(box.width, box.height) * 0.08))))
        while head < queue.count {
            let index = queue[head]; head += 1
            guard Int(distance[index]) < radius else { continue }
            for next in [index - 1, index + 1, index - p.width, index + p.width] {
                guard next >= 0, next < p.count else { continue }
                let x = next % p.width, y = next / p.width
                guard x >= 2, y >= 2, x < p.width - 2, y < p.height - 2, mask[next] == 0, blocked[next] == 0 else { continue }
                let color = p.color(next), span = color.maximum - color.minimum
                let fringe = span >= 15 && zip(color.channels.map { ($0 - color.minimum) * 255 / span }, hue).map({ abs($0 - $1) }).max()! <= 32
                if distance[index] >= 2 && !(color.minimum >= 200 && span <= 35) && !fringe { continue }
                mask[next] = 1; distance[next] = distance[index] + 1; queue.append(next)
            }
        }
        for _ in 0..<3 {
            let end = queue.count
            for k in 0..<end {
                for next in [queue[k] - 1, queue[k] + 1, queue[k] - p.width, queue[k] + p.width] {
                    guard next >= 0, next < p.count else { continue }
                    let x = next % p.width, y = next / p.width
                    guard x >= 2, y >= 2, x < p.width - 2, y < p.height - 2, mask[next] == 0, blocked[next] == 0 else { continue }
                    mask[next] = 1; queue.append(next)
                }
            }
        }
        guard let seed = donorFront(p, queue: queue, mask: mask, blocked: blocked) else { return nil }
        var output = harmonicFill(p, mask: mask, blocked: blocked, seed: seed, orderedQueue: queue)
        output.erasureComplete = true
        output.sourceErasureVerified = true
        output.glyphsVerified = true
        output.method = "chromatic-balloon-glyphs"
        output.surfaceQuality = ["safe": true, "reason": "chromatic-local-donors"]
        output.discoveredOutline = outlined ? stroke : nil
        output.observedFill = fill
        output.observedStroke = outlined ? stroke : nil
        output.sourceRemainingInk = unowned; output.sourceCorePixels = cores; output.sourceFramePixels = framePixels
        output.observedBacking = background
        output.layoutSafe = blocked.map { $0 == 0 ? UInt8(1) : 0 }
        return output
    }

    static func donorFront(_ original: Self, queue: [Int], mask: [UInt8], blocked: [UInt8]) -> Self? {
        var pixels = original, pending = mask, queued = mask.map { _ in UInt8(0) }, frontier: [Int] = []
        func donor(_ index: Int) -> Bool { index >= 0 && index < original.count && pending[index] == 0 && (blocked[index] == 0 || mask[index] != 0) }
        for index in queue where [index - 1, index + 1, index - original.width, index + original.width].contains(where: donor) {
            frontier.append(index); queued[index] = 1
        }
        while !frontier.isEmpty {
            var values = [Float](repeating: 0, count: frontier.count * 3)
            for (k, index) in frontier.enumerated() {
                let neighbors = [index - 1, index + 1, index - original.width, index + original.width].filter(donor)
                guard !neighbors.isEmpty else { return nil }
                for channel in 0..<3 {
                    values[k * 3 + channel] = Float(neighbors.reduce(0.0) { $0 + Double(pixels.rgba[$1 * 4 + channel]) } / Double(neighbors.count))
                }
            }
            for (k, index) in frontier.enumerated() {
                for channel in 0..<3 { pixels.rgba[index * 4 + channel] = clamp(Double(values[k * 3 + channel])) }
                pending[index] = 0
            }
            var next: [Int] = []
            for index in frontier {
                for neighbor in [index - 1, index + 1, index - original.width, index + original.width] where
                    neighbor >= 0 && neighbor < original.count && pending[neighbor] != 0 && queued[neighbor] == 0 {
                    queued[neighbor] = 1; next.append(neighbor)
                }
            }
            frontier = next
        }
        guard !pending.contains(1) else { return nil }
        return pixels
    }

    static func sampledChromatic(_ p: Self, box: CGRect, auxiliary: [CGRect], excluded: [CGRect], palette: Palette?, vertical: Bool) -> Self? {
        if let palette {
            let sourceInk = palette.sourceInk
            let resolvedOutline = palette.verifiedForeground != nil && palette.foreground.minimum >= 220 && palette.stroke != nil &&
                palette.foregroundConfidence >= 0.7 && palette.strokeConfidence >= 0.7 && sourceInk?["stroke"] == nil &&
                sourceInk.flatMap { rgb($0["foreground"]) }.map { $0.distance(palette.stroke!) <= 32 } == true
            let selectedFill = resolvedOutline ? palette.verifiedForeground : sourceInk.flatMap { rgb($0["foreground"]) } ?? palette.verifiedForeground
            guard let fill = selectedFill else { return nil }
            let stroke = resolvedOutline ? palette.stroke : sourceInk.flatMap { rgb($0["stroke"]) } ?? palette.stroke
            let evidence = sourceInk ?? palette.metadata
            let widths = evidence["widthEvidence"] as? [String: Any] ?? [:]
            let confidence = evidence["confidence"] as? [String: Any] ?? [:]
            let measuredDark = palette.metadata.isEmpty || ((confidence["stroke"] as? Double ?? 0) >= 0.6 &&
                (widths["method"] as? String ?? "").hasPrefix("outer stroke boundary"))
            let glyph = widths["glyphPixels"] as? Double ?? 0
            if let result = chromatic(p, box: box, auxiliary: auxiliary, excluded: excluded, fill: fill,
                                      stroke: stroke, background: palette.verifiedBackground, vertical: vertical, recovery: false,
                                      darkOutlineVerified: measuredDark, glyphPixels: glyph) { return result }
            if fill.maximum - fill.minimum >= 90, (stroke?.minimum ?? 0) >= 230,
               (confidence["foreground"] as? Double ?? palette.foregroundConfidence) >= 0.75,
               (confidence["stroke"] as? Double ?? palette.strokeConfidence) >= 0.7,
               let result = chromatic(p, box: box, auxiliary: auxiliary, excluded: excluded, fill: fill,
                                      stroke: stroke, background: palette.verifiedBackground, vertical: vertical, recovery: false,
                                      coreDistance: 48, darkOutlineVerified: measuredDark, glyphPixels: glyph) { return result }
        }
        return nil
    }

    static func outlineRecovery(_ p: Self, box: CGRect, auxiliary: [CGRect], excluded: [CGRect], palette: Palette?,
                                vertical: Bool, allowDiscovery: Bool = true) -> Self? {
        if let result = sampledChromatic(p, box: box, auxiliary: auxiliary, excluded: excluded, palette: palette, vertical: vertical) { return result }
        if let palette {
            let sourceInk = palette.sourceInk
            let ring = sourceInk.flatMap { rgb($0["stroke"]) } ?? palette.stroke ??
                sourceInk.flatMap { rgb($0["foreground"]) } ?? palette.verifiedForeground
            if let ring, ring.maximum - ring.minimum >= 60 {
                if let result = chromatic(p, box: box, auxiliary: auxiliary, excluded: excluded, fill: NativeRestorationRGB([255, 255, 255]),
                                          stroke: ring, background: palette.verifiedBackground, vertical: vertical, recovery: false) { return result }
            }
        }
        if allowDiscovery {
            struct Bin { var sums = [Double](repeating: 0, count: 3); var count = 0; let order: Int }
            var bins: [Int: Bin] = [:], order = 0
            for index in p.indices(box) {
                let x = index % p.width, y = index / p.width, color = p.color(index)
                guard x >= 2, y >= 2, x < p.width - 2, y < p.height - 2, color.maximum - color.minimum >= 90,
                      [index - 1, index + 1, index - p.width, index + p.width, index - 2, index + 2, index - 2 * p.width, index + 2 * p.width]
                        .contains(where: { $0 >= 0 && $0 < p.count && p.color($0).minimum >= 230 }) else { continue }
                let key = Int(p.rgba[index * 4] >> 5) * 64 + Int(p.rgba[index * 4 + 1] >> 5) * 8 + Int(p.rgba[index * 4 + 2] >> 5)
                if bins[key] == nil { bins[key] = Bin(order: order); order += 1 }
                var bin = bins[key]!; bin.count += 1
                for channel in 0..<3 { bin.sums[channel] += Double(p.rgba[index * 4 + channel]) }
                bins[key] = bin
            }
            let candidates = bins.values.filter { $0.count >= 24 }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }.prefix(2)
            for candidate in candidates {
                let stroke = NativeRestorationRGB(candidate.sums.map { floor($0 / Double(candidate.count) + 0.5) })
                for recovery in [false, true] {
                    if let result = chromatic(p, box: box, auxiliary: auxiliary, excluded: excluded, fill: NativeRestorationRGB([255, 255, 255]),
                                              stroke: stroke, background: palette?.verifiedBackground, vertical: vertical, recovery: recovery) { return result }
                }
            }
        }
        for recovery in [false, true] {
            if let result = chromatic(p, box: box, auxiliary: auxiliary, excluded: excluded, fill: NativeRestorationRGB([255, 255, 255]),
                                      stroke: NativeRestorationRGB([0, 0, 0]), background: palette?.verifiedBackground, vertical: vertical, recovery: recovery) { return result }
        }
        return nil
    }
}
