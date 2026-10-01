// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

enum BrowserProgressiveImageOverlayPolicy {
    static func mergedItems(
        baseItems: [BrowserOverlayItem],
        replacementItems: [BrowserOverlayItem],
        successfulReplacementRects: [CGRect]
    ) -> [BrowserOverlayItem] {
        let replacementRegionIDs = Set(
            replacementItems.compactMap(\.stableRegionID)
        )
        let preserved = baseItems.filter { item in
            // Region identity is defined in source-pixel space, so it stays
            // stable when the same page-owned image moves in the viewport.
            // Prefer the newly projected item before applying the geometric
            // fallback. Otherwise an old and a new copy of the same region can
            // survive at different coordinates; the renderer then rejects
            // both occurrences as an ambiguous duplicate stable ID.
            if let stableRegionID = item.stableRegionID,
               replacementRegionIDs.contains(stableRegionID)
            {
                return false
            }
            return preservesBaseItem(
                itemRect: item.rect,
                successfulReplacementRects: successfulReplacementRects
            )
        }
        return preserved + replacementItems
    }

    static func preservesBaseItem(
        itemRect: CGRect,
        successfulReplacementRects: [CGRect]
    ) -> Bool {
        let center = CGPoint(x: itemRect.midX, y: itemRect.midY)
        return !successfulReplacementRects.contains { $0.contains(center) }
    }
}
