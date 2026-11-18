import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func paragraphIncompatibleLaterPanels(index: Int, cards: [Card], outputScale: CGFloat)
        -> [(index: Int, rect: CGRect)]? {
        guard cards.indices.contains(index), let fill = rgb(cards[index].style.foreground) else { return nil }
        let own = cards[index]
        var result: [(index: Int, rect: CGRect)] = []
        for peer in cards.indices where peer > index {
            let other = cards[peer]
            let frame = other.straightenedPanelRect ?? other.sourcePlateRect
            guard other.drawsPanel, other.sourceBackgroundKind == "solid-text-box",
                  other.item.rotation == 0 || other.straightenedPanelRect != nil,
                  other.background.alpha >= 0.999, !other.usesFallbackVeil, valid(frame) else { continue }
            guard let panel = rgb(other.background) else { return nil }
            let readable = textBoxFillContrast(fill, panel: panel) >= 4.5
                || textBoxOutlineSupportsForeground(fill, panel: panel, outline: rgb(own.style.outline),
                    visibleOutlinePixels: Double(own.style.outlineWidth * outputScale / 2),
                    opaqueStrokeThenFill: own.style.outlinePaintOrder == .strokeThenFill
                        && (own.style.outline?.alpha ?? 0) >= 0.999)
            if !readable { result.append((peer, frame)) }
        }
        return result
    }

    /// Move already shaped text, not source coverage. Admit only literal painted
    /// glyph contact improvements inside unchanged complete rectangular panels.
    static func separateParagraphInk(cards: inout [Card],
                                     surfaces: [String: NativeTextBoxContainment.Surface],
                                     keptOwners: [CGRect], outputScale: CGFloat,
                                     protectsPanelSupport: Bool = false,
                                     admitShift: ((Card, [Card]) throws -> NativeSourceBootstrapBirth.Admission?)? = nil) throws {
        guard cards.count <= 512 else { return }
        let gap = 1 / max(0.001, outputScale)
        var remaining = 1_048_576
        func glyphs(_ card: Card) -> [CGRect] {
            guard card.effectiveTextRotation == 0, card.unitTextParts.isEmpty,
                  card.textPaintDomain == nil else { return [] }
            return card.typography.glyphBounds.map {
                $0.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
                    .insetBy(dx: -card.style.outlineGlow, dy: -card.style.outlineGlow)
            }.filter(valid)
        }
        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let r = a.intersection(b)
            return valid(r) ? r.width * r.height : 0
        }
        func debt(_ a: [CGRect], _ b: [CGRect]) -> CGFloat {
            a.reduce(0) { sum, rect in sum + b.reduce(0) { $0 + overlap(rect, $1) } }
        }
        var painted = cards.map(glyphs)
        let order = cards.indices.sorted {
            let a = painted[$0].reduce(CGRect.null) { $0.union($1) }
            let b = painted[$1].reduce(CGRect.null) { $0.union($1) }
            return a.width * a.height < b.width * b.height
        }
        for index in order where !painted[index].isEmpty {
            try Task.checkCancellation()
            let original = cards[index], own = painted[index]
            let peers = cards.indices.filter { $0 != index }
            var obstacles = Dictionary(uniqueKeysWithValues: peers.map { ($0, painted[$0]) })
            if protectsPanelSupport, let later = paragraphIncompatibleLaterPanels(index: index, cards: cards, outputScale: outputScale) {
                for other in later { obstacles[other.index, default: []].append(other.rect) }
            }
            let bounds = own.reduce(CGRect.null) { $0.union($1) }
            let peerGlyphs = peers.reduce(0) { $0 + (obstacles[$1]?.count ?? 0) }
            guard peerGlyphs == 0 || own.count <= remaining / peerGlyphs else {
                cards[index].harmonyRecord["paragraphInkSeparationAudit"] = "work-budget-exhausted"
                continue
            }
            remaining -= own.count * peerGlyphs
            let previous = peers.map { debt(own, obstacles[$0] ?? []) }
            guard previous.contains(where: { $0 > 0.001 }) else { continue }
            var contacts: [CGPoint] = []
            for (position, peer) in peers.enumerated() where previous[position] > 0.001 {
                for a in own { for b in obstacles[peer] ?? [] where a.intersects(b) {
                    contacts.append(contentsOf: [
                        CGPoint(x: b.maxX - a.minX + gap, y: 0),
                        CGPoint(x: b.minX - a.maxX - gap, y: 0),
                        CGPoint(x: 0, y: b.maxY - a.minY + gap),
                        CGPoint(x: 0, y: b.minY - a.maxY - gap)
                    ])
                    if contacts.count >= 128 { break }
                }; if contacts.count >= 128 { break } }
                if contacts.count >= 128 { break }
            }
            contacts.sort { abs($0.x) + abs($0.y) * 3 < abs($1.x) + abs($1.y) * 3 }
            let oldKept = keptOwners.map { overlap(bounds, $0) }
            var bestShift: CGPoint?
            var bestGlyphs: [CGRect] = []
            var bestDebt = previous.reduce(0, +)
            var nativeRejections: [String: Int] = [:]
            for shift in contacts {
                let movedBounds = bounds.offsetBy(dx: shift.x, dy: shift.y)
                guard original.sourcePlateRect.contains(movedBounds.insetBy(dx: -gap, dy: -gap)),
                      surfaces[original.item.id].map({ $0.contains(movedBounds) }) ?? true,
                      zip(keptOwners, oldKept).allSatisfy({ overlap(movedBounds, $0.0) <= $0.1 + 1e-9 }) else { continue }
                let work = own.count * peerGlyphs
                guard work <= remaining else { break }
                remaining -= work
                let moved = own.map { $0.offsetBy(dx: shift.x, dy: shift.y) }
                let next = peers.map { debt(moved, obstacles[$0] ?? []) }
                guard zip(previous, next).allSatisfy({ $0.1 <= $0.0 + 1e-9 }),
                      next.reduce(0, +) < bestDebt - 0.001 else { continue }
                if let admitShift {
                    var candidate = original
                    candidate.textShift.x += shift.x; candidate.textShift.y += shift.y
                    guard let admission = try admitShift(candidate, cards.indices.filter { $0 != index }.map { cards[$0] }) else {
                        nativeRejections["work-limit-or-unknown", default: 0] += 1
                        continue
                    }
                    guard admission.accepted else {
                        nativeRejections[admission.reason, default: 0] += 1
                        continue
                    }
                }
                bestDebt = next.reduce(0, +); bestShift = shift; bestGlyphs = moved
                if bestDebt <= 0.001 { break }
            }
            if let shift = bestShift {
                cards[index].textShift.x += shift.x; cards[index].textShift.y += shift.y
                cards[index].harmonyRecord["paragraphInkSeparationShift"] = [Double(shift.x), Double(shift.y)]
                painted[index] = bestGlyphs
            }
            if admitShift != nil {
                cards[index].harmonyRecord["paragraphInkSeparationAudit"] = [
                    "accepted": bestShift != nil, "rejections": nativeRejections,
                    "protectsLaterLowContrastPanels": protectsPanelSupport,
                    "authority": "bounded raw/retained bitmap and PDF-snapped bitmap alpha; not serialized PDF",
                    "unknownIsPermission": false]
            }
        }
    }
}
