import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Run after all plate/restored growth, before word repair and harmony. A
    /// later harmony font is not the peer size that constrained this display.
    @discardableResult
    static func capRotatedDisplayPeers(cards: inout [Card], cleanup: NativeSourceSurfaceGeometry.Geometry?,
                                       hiddenIDs: Set<String>, removedIDs: Set<String>) -> [String: [Double]] {
        guard cards.count <= 256 else { return [:] }
        func visible(_ card: Card) -> Bool {
            !card.item.keptLettering && !card.item.text.isEmpty &&
                !hiddenIDs.contains(card.item.id) && !removedIDs.contains(card.item.id)
        }
        func source(_ card: Card) -> (rect: CGRect, glyph: Double)? {
            let item = card.item
            guard item.sourceBounds.count == 4, item.sourceBounds.allSatisfy(\.isFinite),
                  cleanup != nil || (item.sourceFrame.count == 4 && item.sourceFrame.allSatisfy(\.isFinite)),
                  let rect = plateGrowthSourceRect(item: item, cleanup: cleanup), valid(rect) else { return nil }
            let estimate = Double(item.sourceFontSize ?? 0)
            let glyph = estimate.isFinite && estimate > 0 ? estimate : Double(min(rect.width, rect.height))
            return glyph.isFinite && glyph > 0 ? (rect, glyph) : nil
        }
        var changes: [String: [Double]] = [:]
        for index in cards.indices {
            let original = cards[index], font = Double(original.finalFontSize)
            guard visible(original), original.item.rotation.isFinite, original.item.rotation != 0,
                  original.rotatesSourcePanels, font.isFinite, font > 32, font <= 4096,
                  original.unitTextParts.isEmpty, original.item.typesettingText == nil,
                  original.style.horizontalAlignment == .center, !original.style.alignsToTop,
                  let own = source(original) else { continue }
            // Read current cards in source order: an earlier cap is visible to
            // later peers, just as the original post-growth node traversal was.
            let peers = cards.indices.compactMap { otherIndex -> Double? in
                guard otherIndex != index else { return nil }
                let other = cards[otherIndex], size = Double(other.finalFontSize)
                guard visible(other), other.item.fontScript == original.item.fontScript,
                      size.isFinite, size > 0, size <= 4096, let peer = source(other),
                      max(own.glyph, peer.glyph) / min(own.glyph, peer.glyph) <= 1.22 else { return nil }
                let a = own.rect, b = peer.rect
                let gap = max(a.minX - b.maxX, b.minX - a.maxX, a.minY - b.maxY, b.minY - a.maxY)
                return Double(gap) <= 3 * max(own.glyph, peer.glyph) ? size : nil
            }
            guard let smallest = peers.min() else { continue }
            let size = max(min(font, 31.75), floor(smallest * 1.2 * 4) / 4)
            guard size < font else { continue }
            let declaredRatio = Double(original.style.lineHeight) / font
            let ratio = declaredRatio.isFinite && declaredRatio > 0 ? declaredRatio : 1.2
            var proposed = original
            proposed.item.fontSize = CGFloat(size); proposed.item.lineHeight = CGFloat(size * ratio)
            proposed.style.fontSize = CGFloat(size); proposed.style.lineHeight = proposed.item.lineHeight
            if proposed.style.trackingScalesWithFont { proposed.style.tracking *= CGFloat(size / font) }
            proposed.finalFontSize = CGFloat(size)
            proposed.typography = remeasureTypography(proposed)
            // Smaller text must still fit its unchanged centred card. Controlled
            // children are excluded above; their font ownership is independent.
            guard proposed.typography.fits else { continue }
            cards[index] = proposed
            changes[original.item.id] = [font, size]
        }
        return changes
    }
}
