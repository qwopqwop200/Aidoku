import CoreGraphics
import Foundation

/// Geometry-only final caption plate policy. Text shaping and source erasure
/// are fixed inputs; this stage may only trim/merge plates and translate ink.
enum NativeTranslationCaptionPanelPolish {
    typealias Panel = NativeTranslationSourceStylePostPolish.Panel
    struct Entry {
        let id: String
        let sourceTextOnly: Bool
        let rotation: Double
        let vertical: Bool
        let lettering: String?
        let wrappingScript: String
        let font: Double
        let frame: CGRect
        let sources: [CGRect]
        let balancedColumn: Bool
        let column: CGRect?
        let columnPaddingTop: Double
        var ink: CGRect
        var panels: [Panel]
        var backings: [NativePanelGeometry.Backing] = []
        var shift = CGPoint.zero
        var detached = false
        var isFlat = true
        var hasForeignFills = false
    }

    static func polish(_ input: [Entry], opacity: Double, kept: [CGRect],
                       readSource: ((CGRect, CGRect) -> (rgba: [UInt8], width: Int)?)? = nil) -> [Entry] {
        guard opacity == 1, input.count <= 256 else { return input }
        var entries = input
        func eligible(_ entry: Entry, piece: Bool = false) -> Bool {
            entry.isFlat && !entry.sourceTextOnly && entry.rotation == 0 && !entry.vertical &&
                (entry.lettering == nil || piece && entry.lettering == "piece") && entry.wrappingScript == "korean"
        }
        func plain(_ panel: Panel, owner: Entry) -> Bool {
            panel.isFlat && panel.sourceFrameImage == nil && !owner.hasForeignFills
        }
        func move(_ i: Int, _ dx: CGFloat, _ dy: CGFloat) {
            entries[i].ink = entries[i].ink.offsetBy(dx: dx, dy: dy)
            entries[i].shift.x += dx; entries[i].shift.y += dy
            entries[i].detached = true
        }
        for i in entries.indices {
            let e = entries[i]
            guard eligible(e), e.balancedColumn, let slot = e.column else { continue }
            let dy = slot.minY + e.columnPaddingTop - e.ink.minY, moved = e.ink.offsetBy(dx: 0, dy: dy)
            if abs(dy) < 0.25 || !contains(slot, moved) || entries.indices.contains(where: { $0 != i && hit(moved, pad(entries[$0].ink, 1)) }) ||
                kept.contains(where: { hit(moved, $0) }) || !e.panels.isEmpty && !e.panels.contains(where: { contains($0.rect, moved) }) { continue }
            move(i, 0, dy)
        }
        for i in entries.indices {
            let e = entries[i]
            guard eligible(e, piece: true), !e.panels.isEmpty, e.panels.allSatisfy({ $0.background.count == 3 && plain($0, owner: e) && (!$0.clipped || $0.captionUnionClipped) }) else { continue }
            let u = union(e.panels.map(\.rect)), main = e.panels.firstIndex(where: { !$0.sourceErasure }) ?? 0
            let color = e.panels[0].background
            if e.panels.contains(where: { zip($0.background, color).contains(where: { abs($0 - $1) > 24 }) }) { continue }
            let obstacles = entries.indices.filter { $0 != i }.flatMap { [pad(entries[$0].ink, 1)] + entries[$0].sources } + kept
            let required = pad(union([e.ink] + e.sources), 4)
            var target = u
            if obstacles.contains(where: { hit(u, $0) }) && contains(u, required) {
                target = CGRect(x: required.minX, y: u.minY, width: required.width, height: u.height)
            }
            if kept.contains(where: { hit(target, $0) }) {
                let bottom = max(e.ink.maxY + 2, e.sources.map { $0.maxY + 1 }.max() ?? -.infinity)
                if bottom < target.maxY { target.size.height = bottom - target.minY }
            }
            let clipped = e.panels.contains(where: \.clipped)
            if e.panels.count > 1 || clipped {
                let coverage = e.panels.flatMap { $0.coverage.isEmpty ? [$0.rect] : $0.coverage }
                if coverage.isEmpty || coverage.count > 64 || coverage.contains(where: { !valid($0) }) { continue }
                var blankKept: Set<Int> = []
                if let readSource {
                    for k in kept.indices where hit(target, kept[k]) {
                        let overlap = intersection(target, kept[k])
                        if min(overlap.width, overlap.height) > 6 { continue }
                        guard let pixels = readSource(pad(overlap, 1), e.frame), !pixels.rgba.isEmpty else { continue }
                        var low = [255, 255, 255], high = [0, 0, 0], safe = true
                        for at in stride(from: 0, to: pixels.rgba.count, by: 4) {
                            if at + 3 >= pixels.rgba.count || pixels.rgba[at + 3] < 250 { safe = false; break }
                            for c in 0..<3 {
                                let v = Int(pixels.rgba[at + c]); low[c] = min(low[c], v); high[c] = max(high[c], v)
                                if pixels.width > 0 && (at / 4 % pixels.width > 0 && abs(v - Int(pixels.rgba[at - 4 + c])) > 12 ||
                                    at >= pixels.width * 4 && abs(v - Int(pixels.rgba[at - pixels.width * 4 + c])) > 12) { safe = false }
                            }
                        }
                        if safe && (0..<3).allSatisfy({ high[$0] - low[$0] <= 48 }) { blankKept.insert(k) }
                    }
                }
                let blank = blankKept.map { kept[$0] }
                let addsCollision = obstacles.contains { obstacle in
                    if blank.contains(obstacle) { return false }
                    let existing = coverage.map { intersection($0, obstacle) }.filter { $0.width > 0 && $0.height > 0 }
                    return area(intersection(target, obstacle)) > coveredArea(existing) + 0.05
                }
                if area(target) > coveredArea(coverage) * 1.35 || !contains(e.frame, target) || addsCollision ||
                    kept.indices.contains(where: { hit(target, kept[$0]) && !blankKept.contains($0) }) { continue }
                var panel = e.panels[main]; panel.rect = target; panel.radius = 2; panel.coverage = [target]; panel.clipped = false
                entries[i].panels = [panel]; entries[i].detached = true
            } else if target != u { entries[i].panels[main].rect = target; entries[i].detached = true }
        }
        for i in entries.indices {
            let e = entries[i]
            guard eligible(e), !e.balancedColumn, e.panels.count == 1, plain(e.panels[0], owner: e),
                  !e.panels[0].clipped || e.panels[0].captionUnionClipped && coveredArea(e.panels[0].coverage) >= area(e.panels[0].rect) * 0.995 else { continue }
            let own = e.panels[0].rect, before = e.ink
            let obstacles = entries.indices.filter { $0 != i }.flatMap { [pad(entries[$0].ink, 1)] + entries[$0].panels.map(\.rect) } + kept
            let collisions = obstacles.filter { hit(before, $0) }
            if collisions.isEmpty { continue }
            var xs: [CGFloat] = [0], ys: [CGFloat] = [0]
            for o in collisions { xs += [o.minX - before.maxX - 0.75, o.maxX - before.minX + 0.75]; ys += [o.minY - before.maxY - 0.75, o.maxY - before.minY + 0.75] }
            let limit = CGFloat(min(24, max(4, e.font * 1.5)))
            func axis(_ values: [CGFloat]) -> [CGFloat] {
                var unique: [CGFloat] = []
                for value in values where abs(value) <= limit && !unique.contains(value) { unique.append(value) }
                return unique.enumerated().sorted { a, b in abs(a.element) == abs(b.element) ? a.offset < b.offset : abs(a.element) < abs(b.element) }.prefix(17).map(\.element)
            }
            var trials: [(dx: CGFloat, dy: CGFloat, d: CGFloat, order: Int)] = []
            for dx in axis(xs) { for dy in axis(ys) { let d = hypot(dx, dy); if d > 0 && d <= limit { trials.append((dx, dy, d, trials.count)) } } }
            trials.sort { $0.d == $1.d ? $0.order < $1.order : $0.d < $1.d }
            for trial in trials {
                let r = before.offsetBy(dx: trial.dx, dy: trial.dy)
                if obstacles.contains(where: { hit(r, $0) }) { continue }
                let grown = union([own, pad(r, 0.5)]), allowance = CGFloat(min(2, e.font * 0.25))
                if max(own.minX - grown.minX, own.minY - grown.minY, grown.maxX - own.maxX, grown.maxY - own.maxY) > allowance ||
                    !contains(e.frame, grown) || obstacles.contains(where: { area(intersection(grown, $0)) > area(intersection(own, $0)) + 0.01 }) { continue }
                entries[i].panels[0].rect = grown; entries[i].panels[0].coverage = [grown]; entries[i].panels[0].clipped = false; move(i, trial.dx, trial.dy); break
            }
        }
        // Frozen Typography740: remove a redundant clipped clone before
        // spacing can narrow the solid owner. Coverage is not its DOM box.
        for i in entries.indices {
            let e = entries[i]
            guard e.panels.count == 1, plain(e.panels[0], owner: e), !e.panels[0].clipped else { continue }
            let panel = e.panels[0]
            entries[i].backings.removeAll { contains(panel.rect, $0.frame) && $0.color == panel.background }
        }
        struct Card { let entry: Int; let base: CGRect; var rect: CGRect }
        var cards = entries.indices.filter { i in
            let e = entries[i]
            return e.isFlat && !e.sourceTextOnly && e.rotation == 0 && (e.lettering == nil || e.lettering == "piece") &&
                e.wrappingScript == "korean" && e.panels.count == 1 && plain(e.panels[0], owner: e) &&
                (!e.panels[0].clipped || e.panels[0].captionUnionClipped && coveredArea(e.panels[0].coverage) >= area(e.panels[0].rect) * 0.995)
        }.map { Card(entry: $0, base: entries[$0].panels[0].rect, rect: entries[$0].panels[0].rect) }
        cards = cards.enumerated().sorted { a, b in a.element.rect.minX == b.element.rect.minX ? a.offset < b.offset : a.element.rect.minX < b.element.rect.minX }.map(\.element)
        func overlapsY(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.5 }
        func commit(_ card: Card) { entries[card.entry].detached = true; entries[card.entry].panels[0].rect = card.rect; entries[card.entry].panels[0].coverage = [card.rect]; entries[card.entry].panels[0].clipped = false }
        for resolve in [false, true] {
            for i in cards.indices { for j in cards.indices where j > i {
                let a = cards[i], b = cards[j]
                if !overlapsY(a.rect, b.rect) || b.rect.minX - a.rect.maxX >= 1 || a.rect.minX >= b.rect.minX || a.rect.maxX >= b.rect.maxX { continue }
                let ar = pad(union([entries[a.entry].ink] + entries[a.entry].sources), 0.5)
                let br = pad(union([entries[b.entry].ink] + entries[b.entry].sources), 0.5)
                let right = max(a.rect.minX + 1, min(a.rect.maxX, ar.maxX)), left = min(b.rect.maxX - 1, max(b.rect.minX, br.minX))
                if right < a.rect.maxX { cards[i].rect.size.width = right - a.rect.minX; commit(cards[i]) }
                if left > b.rect.minX { cards[j].rect = CGRect(x: left, y: b.rect.minY, width: b.rect.maxX - left, height: b.rect.height); commit(cards[j]) }
                if !resolve || cards[j].rect.minX - cards[i].rect.maxX >= 1 { continue }
                let ae = entries[a.entry], be = entries[b.entry]
                if !eligible(ae) || !eligible(be) || ae.balancedColumn || be.balancedColumn { continue }
                var outerLeft = max(ae.frame.minX, a.base.minX - 3), outerRight = min(be.frame.maxX, b.base.maxX + 3)
                for k in cards.indices where k != i && k != j {
                    let other = cards[k]
                    if overlapsY(cards[i].rect, other.rect) && other.rect.minX < cards[i].rect.minX { outerLeft = max(outerLeft, other.rect.maxX + 1) }
                    if overlapsY(cards[j].rect, other.rect) && other.rect.maxX > cards[j].rect.maxX { outerRight = min(outerRight, other.rect.minX - 1) }
                }
                let ai = ae.ink, bi = be.ink, sourceA = union(ae.sources), sourceB = union(be.sources)
                let low = max(sourceA.maxX + 0.5, outerLeft + ai.width + 1), high = min(sourceB.minX - 1.5, outerRight - bi.width - 2)
                if low > high { continue }
                let seam = max(low, min(high, (cards[i].rect.maxX + cards[j].rect.minX - 1) / 2))
                let ad = min(0, seam - 0.5 - ai.maxX), bd = max(0, seam + 1.5 - bi.minX)
                if abs(ad) > min(8, ae.font) || abs(bd) > min(8, be.font) { continue }
                let an = ai.offsetBy(dx: ad, dy: 0), bn = bi.offsetBy(dx: bd, dy: 0)
                let ap = CGRect(x: min(cards[i].rect.minX, an.minX - 0.5), y: cards[i].rect.minY,
                    width: seam - min(cards[i].rect.minX, an.minX - 0.5), height: cards[i].rect.height)
                let bp = CGRect(x: seam + 1, y: cards[j].rect.minY, width: max(cards[j].rect.maxX, bn.maxX + 0.5) - seam - 1, height: cards[j].rect.height)
                let obstacles = entries.indices.filter { $0 != a.entry && $0 != b.entry }.flatMap { [pad(entries[$0].ink, 0.5)] + entries[$0].sources } + kept
                func safe(_ current: CGRect, _ ink: CGRect, _ plate: CGRect) -> Bool {
                    plate.minX >= outerLeft && plate.maxX <= outerRight && contains(plate, pad(ink, 0.5)) &&
                        !obstacles.contains(where: { hit(ink, $0) || area(intersection(plate, $0)) > area(intersection(current, $0)) + 0.05 })
                }
                if !safe(cards[i].rect, an, ap) || !safe(cards[j].rect, bn, bp) { continue }
                move(a.entry, ad, 0); move(b.entry, bd, 0); cards[i].rect = ap; cards[j].rect = bp; commit(cards[i]); commit(cards[j])
            } }
        }
        var groups: [[Int]] = []
        for i in cards.indices {
            if let last = groups.last?.last, overlapsY(cards[last].rect, cards[i].rect), cards[i].rect.minX - cards[last].rect.maxX <= 12 { groups[groups.count - 1].append(i) }
            else { groups.append([i]) }
        }
        struct State { let rect: CGRect; let dx: CGFloat; let card: Int; let parent: Int?; let cost: CGFloat }
        for group in groups {
            if group.count < 2 || group.count > 12 || group.contains(where: { !eligible(entries[cards[$0].entry], piece: true) || entries[cards[$0].entry].balancedColumn }) ||
                !group.indices.contains(where: { $0 > 0 && cards[group[$0]].rect.minX - cards[group[$0 - 1]].rect.maxX < 0.95 }) { continue }
            let owners = Set(group.map { cards[$0].entry })
            let obstacles = entries.indices.filter { !owners.contains($0) }.flatMap { [pad(entries[$0].ink, 0.5)] + entries[$0].sources + entries[$0].panels.map(\.rect) } + kept
            var allStates: [State] = [], states: [Int] = []
            for (index, cardIndex) in group.enumerated() {
                let c = cards[cardIndex], e = entries[c.entry], original = e.ink, limit = min(8, e.font)
                var next: [Int] = []
                for step in -Int(floor(limit * 4))...Int(floor(limit * 4)) {
                    let dx = CGFloat(step) / 4, moved = original.offsetBy(dx: dx, dy: 0), required = pad(union([moved] + e.sources), 0.5)
                    let r = CGRect(x: required.minX, y: c.rect.minY, width: required.width, height: c.rect.height)
                    if r.minX < max(e.frame.minX, c.base.minX - 3) || r.maxX > min(e.frame.maxX, c.base.maxX + 3) || !contains(r, pad(moved, 0.5)) ||
                        obstacles.contains(where: { hit(moved, $0) || area(intersection(r, $0)) > area(intersection(c.rect, $0)) + 0.05 }) { continue }
                    var parent: Int?
                    if index > 0 {
                        for state in states where allStates[state].rect.maxX + 1 <= r.minX {
                            if parent == nil || allStates[state].cost < allStates[parent!].cost { parent = state }
                        }
                        if parent == nil { continue }
                    }
                    allStates.append(State(rect: r, dx: dx, card: cardIndex, parent: parent, cost: (parent.map { allStates[$0].cost } ?? 0) + abs(dx)))
                    next.append(allStates.count - 1)
                }
                states = next
                if states.isEmpty { break }
            }
            guard var chosen = states.first else { continue }
            for candidate in states where allStates[candidate].cost < allStates[chosen].cost { chosen = candidate }
            var solution: [State] = []
            while true { let state = allStates[chosen]; solution.append(state); guard let parent = state.parent else { break }; chosen = parent }
            if solution.count != group.count { continue }
            for state in solution { move(cards[state.card].entry, state.dx, 0); cards[state.card].rect = state.rect; commit(cards[state.card]) }
        }
        return entries
    }

    static func hit(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0.25 && min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.25 }
    static func contains(_ a: CGRect, _ b: CGRect) -> Bool { b.minX >= a.minX - 0.25 && b.maxX <= a.maxX + 0.25 && b.minY >= a.minY - 0.25 && b.maxY <= a.maxY + 0.25 }
    static func pad(_ r: CGRect, _ p: CGFloat) -> CGRect { r.insetBy(dx: -p, dy: -p) }
    static func area(_ r: CGRect) -> CGFloat { max(0, r.width) * max(0, r.height) }
    static func intersection(_ a: CGRect, _ b: CGRect) -> CGRect {
        let l = max(a.minX, b.minX), t = max(a.minY, b.minY), r = min(a.maxX, b.maxX), bottom = min(a.maxY, b.maxY)
        return CGRect(x: l, y: t, width: max(0, r - l), height: max(0, bottom - t))
    }
    static func union(_ values: [CGRect]) -> CGRect {
        guard let first = values.first else { return CGRect(x: .infinity, y: .infinity, width: -.infinity, height: -.infinity) }
        return values.dropFirst().reduce(first) { CGRect(x: min($0.minX, $1.minX), y: min($0.minY, $1.minY),
            width: max($0.maxX, $1.maxX) - min($0.minX, $1.minX), height: max($0.maxY, $1.maxY) - min($0.minY, $1.minY)) }
    }
    static func valid(_ r: CGRect) -> Bool { [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) }
    static func coveredArea(_ values: [CGRect]) -> CGFloat {
        let xs = Set(values.flatMap { [$0.minX, $0.maxX] }).sorted()
        guard xs.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<xs.count {
            let spans = values.filter { $0.minX < xs[i] && $0.maxX > xs[i - 1] }.enumerated().sorted { a, b in
                a.element.minY == b.element.minY ? a.offset < b.offset : a.element.minY < b.element.minY
            }.map(\.element)
            var end = -CGFloat.infinity, height: CGFloat = 0
            for span in spans { height += max(0, span.maxY - max(span.minY, end)); end = max(end, span.maxY) }
            total += (xs[i] - xs[i - 1]) * height
        }
        return total
    }
}
