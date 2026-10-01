import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeWidePlateOverflowTests {
    private func card(text: String = "달칵!", width: CGFloat = 83.5, font: CGFloat = 42.75, scale: CGFloat = 1,
                      vertical: Bool = false, staleFont: CGFloat? = nil, sourceGlyph: CGFloat? = nil) throws -> NativeTranslationRenderer.Card {
        var fields: [String: Any] = ["id": "scroll-probe", "text": text, "typesettingText": text,
            "typesettingQuoteMode": 0, "fontScript": "korean", "wrappingScript": "korean",
            "sourceBounds": [0.0,0.0,0.5,0.5], "sourceFrame": [0,0,200,200],
            "x": 0, "y": 0, "width": width, "height": 100, "fontSize": staleFont ?? font,
            "lineHeight": (staleFont ?? font) * 1.2, "vertical": vertical]
        if let sourceGlyph { fields["sourceFontSize"] = sourceGlyph }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
            vertical: vertical, lineHeight: font * 1.2,
            optimizesKoreanWrapping: false, horizontalScale: scale, usesBlockWordLayout: true)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        return NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            drawsPanel: false, background: NativeTranslationRenderer.color([255,255,255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
    }
@Test(arguments:[0,1,2])
    func acceptedWideGrowthClearsOnlyItsActualParentOverflow(relation: Int) throws {
        var value = try card(text: "AB CD", width: 80, font: 10)
        value.sourcePanels = [.init(rect: value.item.rect, background: [255,255,255], coverage: [value.item.rect])]
        value.sourcePanels[0].overflowClip = true
        value.captionParentPlate = relation != 2
        value.captionParentOwner = .init(cardIndex: relation == 1 ? 7 : 3, panelIndex: 0)
        let original = value
        NativeTranslationRenderer.releaseWidePlateOverflow(&value, cardIndex: 3, panelIndex: 0)
        #expect(value.sourcePanels[0].overflowClip == (relation != 0))
        #expect(original.sourcePanels[0].overflowClip)
        #expect(value.sourcePanels[0].rect == original.sourcePanels[0].rect)
        #expect(value.captionParentOwner == original.captionParentOwner)
    }
}
