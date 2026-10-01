import CoreGraphics
import Foundation

/// Source ownership and the final clipped image copy use the same reconstructed
/// kept boxes, regardless of whether their skipped layout payload has a card.
enum NativeKeptSourceRestoration {
    struct Kept {
        let id: String
        let rect: CGRect
        let sourceFontSize: Double?
    }
    struct Zone {
        let id: String
        let rect: CGRect
    }
    struct Selection {
        let pieces: [CGRect]
        let collisions: Set<String>
        let overlaps: Set<String>
        let restoredIDs: Set<String>
    }
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite)
            && rect.size.width > 0 && rect.size.height > 0
    }
    static func reconstructed(_ items: [NativeTranslationLayoutItem], cleanupFrame: CGRect? = nil) -> [Kept] {
        items.filter(\.keptLettering).compactMap { item in
            guard let rect = sourceRect(item, cleanupFrame: cleanupFrame), valid(rect) else { return nil }
            return Kept(id: item.id, rect: rect, sourceFontSize: item.sourceFontSize.flatMap {
                $0.isFinite && $0 > 0 ? Double($0) : nil
            })
        }
    }
    static func sourceRect(_ item: NativeTranslationLayoutItem, cleanupFrame: CGRect? = nil) -> CGRect? {
        let b = item.sourceBounds, f = item.sourceFrame
        guard b.count == 4, f.count == 4, b.allSatisfy(\.isFinite), f.allSatisfy(\.isFinite) else { return nil }
        let frame = cleanupFrame ?? CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        guard valid(frame), b[2] > 0, b[3] > 0 else { return nil }
        return CGRect(x: frame.minX + b[0] * frame.width, y: frame.minY + b[1] * frame.height,
                      width: b[2] * frame.width, height: b[3] * frame.height)
    }
    static func zones(kept: [Kept], painted: [CGRect]) -> [Zone] {
        guard kept.count <= 256 else { return [] }
        let cuts = painted.filter(valid).prefix(512)
        return kept.flatMap { item -> [Zone] in
            guard valid(item.rect) else { return [] }
            let glyph = item.sourceFontSize.flatMap { $0 > 0 ? $0 : nil } ?? Double(min(item.rect.width, item.rect.height))
            let pad = CGFloat(max(1, min(3, glyph * 0.15)))
            let left = item.rect.minX - pad, top = item.rect.minY - pad
            let right = item.rect.maxX + pad, bottom = item.rect.maxY + pad
            var pieces = [CGRect(x: left, y: top, width: right - left, height: bottom - top)]
            for cut in cuts {
                pieces = NativePanelGeometry.subtractRects(pieces, cut: cut)
                if pieces.count > 64 { break }
            }
            return pieces.filter { $0.width >= 0.5 && $0.height >= 0.5 }.map { Zone(id: item.id, rect: $0) }
        }
    }
    static func zones(items: [NativeTranslationLayoutItem], cleanupFrame: CGRect? = nil) -> [Zone] {
        let kept = reconstructed(items, cleanupFrame: cleanupFrame)
        let painted = items.filter { !$0.keptLettering }.compactMap { sourceRect($0, cleanupFrame: cleanupFrame) }
        return zones(kept: kept, painted: painted)
    }
    /// Glyph rectangles have already received the original 1.5-point margin.
    /// Effect zones always survive the kept-lettering collision decision.
    static func select(kept: [Kept], keptZones: [Zone], effectZones: [Zone], glyphLines: [CGRect],
        covers: [CGRect], image: CGRect, blankMargins: [CGRect] = []) -> Selection {
        let covers = covers.filter(valid)
        let collided = Set(kept.filter { item in
            let zones = keptZones.filter { $0.id == item.id }
            let overlap = glyphLines.reduce(CGFloat(0)) { sum, glyph in
                sum + zones.reduce(CGFloat(0)) { $0 + NativePanelGeometry.overlap(glyph, $1.rect) }
            }
            return overlap > item.rect.width * item.rect.height * 0.1
        }.map(\.id))
        let zones = keptZones.filter { zone in
            !collided.contains(zone.id) && covers.contains { NativePanelGeometry.intersects($0, zone.rect, tolerance: 0.25) }
        } + effectZones
        var pieces = zones.map(\.rect)
        for glyph in glyphLines where zones.contains(where: { NativePanelGeometry.intersects(glyph, $0.rect, tolerance: 0.25) }) {
            pieces = NativePanelGeometry.subtractRects(pieces, cut: glyph)
        }
        for blank in blankMargins { pieces = NativePanelGeometry.subtractRects(pieces, cut: blank) }
        pieces = pieces.compactMap { rect -> CGRect? in
            let l = max(rect.minX, image.minX), t = max(rect.minY, image.minY)
            let r = min(rect.maxX, image.maxX), b = min(rect.maxY, image.maxY)
            return r - l >= 0.5 && b - t >= 0.5 ? CGRect(x: l, y: t, width: r - l, height: b - t) : nil
        }
        var overlaps = collided
        overlaps.formUnion(zones.filter { zone in
            glyphLines.contains { NativePanelGeometry.intersects($0, zone.rect, tolerance: 0.25) }
        }.map(\.id))
        let emitted = !pieces.isEmpty && pieces.count <= 1024 && image.width > 0 && image.height > 0
        return Selection(pieces: emitted ? pieces : [], collisions: collided, overlaps: overlaps,
                         restoredIDs: emitted ? Set(zones.map(\.id)) : [])
    }
}
