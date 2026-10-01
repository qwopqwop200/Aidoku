import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourceHeadingChildrenTests {
    @Test(arguments: [false, true])
    func rebuiltHeadingDropsPackingWrapperButRetainsNodeDisplay(_ blockDisplay: Bool) throws {
        let raw = "【항목】 설명 문장이 길어서 아래에서 자연스럽게 감기는 검증 문구"
        let descriptor: [String: Any] = ["id": "heading-wrapper", "text": raw,
            "typesettingText": "【항목】\n설명 문장이 길어서 아래에서 자연스럽게 감기는 검증 문구",
            "typesettingQuoteMode": 0, "typesettingPreservedBlockWrapper": true, "typesettingPreformattedRows": true,
            "typesettingBlockDisplay": blockDisplay, "captionFixedBoxReflowDisabled": true,
            "x": 10, "y": 20, "width": 95, "height": 120, "fontSize": 12, "lineHeight": 14,
            "sourceFrame": [0,0,200,200], "sourceBounds": [0.1,0.1,0.5,0.5]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: descriptor))
        var style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 12, lineHeight: 14,
            optimizesKoreanWrapping: false, usesBlockWordLayout: true,
            blockWordLayoutUsesTopPadding: blockDisplay)
        style.keepsWholeWords = false
        style.usesPreformattedBlockRows = true
        var card = NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: item.typesettingText!, in: item.contentRect.size, style: style),
            style: style, drawsPanel: false, background: CGColor(gray: 1, alpha: 1),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 12)
        card.lineOffsets = [CGPoint(x: 5, y: 0)]
        let before = try #require(NativeTranslationRenderer.cardWholeRangeRect(card))
        let heading = "【항목】\n설명 문장이 길어서 아래에서 자연스럽게 감기는 검증 문구"
        NativeTranslationRenderer.replaceSourceHeadingChildren(&card, text: heading)
        card.typography = NativeTranslationRenderer.remeasureTypography(card)
        #expect(card.item.typesettingText == heading && card.item.typesettingQuoteMode == nil)
        #expect(card.item.typesettingPreservedBlockWrapper == nil && card.item.typesettingPreformattedRows == nil)
        #expect(!card.style.usesPreformattedBlockRows)
        #expect(!card.style.usesBlockWordLayout && !card.style.blockWordLayoutUsesTopPadding)
        #expect(card.lineOffsets.isEmpty)
        #expect(card.item.typesettingBlockDisplay == blockDisplay)
        #expect(card.item.captionFixedBoxReflowDisabled == true)
        #expect(card.item.sourceFrame == item.sourceFrame && card.item.sourceBounds == item.sourceBounds)
        // A Text node wraps its body instead of retaining the old overflowing row.
        #expect(card.typography.lineCount > 2)
        let after = try #require(NativeTranslationRenderer.cardWholeRangeRect(card))
        #expect(after.width < before.width)
        var expectedStyle = card.style
        expectedStyle.usesBlockWordLayout = false
        expectedStyle.alignsToTop = blockDisplay
        let expectedLayout = NativeTranslationTypography.layout(text: heading,
            in: card.textLayoutSize, style: expectedStyle)
        let plain = try #require(NativeTranslationTypography.wholeRangeBounds(layout: expectedLayout,
            style: expectedStyle, available: card.textLayoutSize))
        #expect(after == plain.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y))
    }
}
