import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Frozen Typography 74–84 first accommodates CSS scroll overflow, then
    /// the selected contents' complete line stack, and retains the first line.
    static func reshapeCaptionLineSpacing(_ card: Card, pitch: CGFloat, firstTop: CGFloat) -> Card? {
        var candidate = card
        candidate.style.lineHeight = pitch
        candidate.item.lineHeight = pitch
        candidate.typography = remeasureTypography(candidate)
        guard let overflow = NativeTypographyPostPolish.contentFitMetrics(
            item: candidate.item, typography: candidate.typography) else { return nil }
        candidate.item.height = max(candidate.item.height, CGFloat(overflow.scrollHeight))
        candidate.item.height = usedLayoutItem(candidate.item).height
        candidate.typography = remeasureTypography(candidate)
        guard let stack = cardWholeRangeRect(candidate) else { return nil }
        candidate.item.height = max(candidate.item.height,
            stack.height + candidate.item.cssPaddingTop + candidate.item.cssPaddingBottom)
        candidate.item.height = usedLayoutItem(candidate.item).height
        candidate.typography = remeasureTypography(candidate)
        guard let first = cardPageLineRects(candidate).first else { return nil }
        let authoredTop = (candidate.sourceColumnAuthoredTop ?? candidate.item.y) + firstTop - first.minY
        if candidate.sourceColumnAuthoredTop != nil { candidate.sourceColumnAuthoredTop = authoredTop }
        candidate.item.y = authoredTop
        candidate.item.y = usedLayoutItem(candidate.item).y
        return candidate
    }
}
