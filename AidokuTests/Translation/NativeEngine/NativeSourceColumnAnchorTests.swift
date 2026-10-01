import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourceColumnAnchorTests {
    @Test(arguments: [(0.1805678793256433, 261.03125), (0.17968056787932565, 260.796875)])
    func finalAnchorRetainsAuthoredColumnTopBeforeCSSQuantization(example: (Double, Double)) throws {
        // Captured frozen iOS columns share the authored top but anchor to
        // different source rows. DOM used coordinates differ from CSS top.
        let authoredTop = 262.03007518796994
        let descriptor: [String: Any] = ["id": "column-anchor", "text": "드디어 선생님이 왔다",
            "x": 117.140625, "y": 262.015625, "width": 24.765625, "height": 32,
            "paddingTop": 2, "paddingRight": 2, "paddingBottom": 2, "paddingLeft": 2,
            "fontSize": 7.02906976744186, "lineHeight": 9.375, "sourceVertical": true, "balancedColumn": true,
            "fontScript": "korean", "wrappingScript": "korean", "allowsAutomaticFontRecovery": false,
            "sourceBounds": [0.31109022556390975, example.0, 0.05043859649122807, 0.17346938775510204],
            "sourceFrame": [0, 212.30263157894737, 390, 275.39473684210526],
            "columnLayout": ["x": 117.15229935303374, "y": authoredTop, "width": 24.779047910473864,
                "height": 47.52819548872179, "fontSize": 7.02906976744186, "lineHeight": 9.375,
                "paddingTop": 2, "paddingRight": 2, "paddingBottom": 2, "paddingLeft": 2,
                "balancedColumn": true, "allowsAutomaticFontRecovery": false]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let frame = CGRect(x: 0, y: 212.30263157894737, width: 390, height: 275.39473684210526)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 3192, height: 2254), sourceRect: frame,
            viewport: CGSize(width: 390, height: 700), items: [item])
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: item.fontSize,
            tracking: -item.fontSize * 0.012, lineHeight: item.lineHeight, alignsToTop: true)
        let shaped = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: shaped, style: style,
            drawsPanel: false, background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: item.fontSize)
        // This final anchor belongs to a translated inpainted caption.
        card.sourceBackgroundKind = "inpainted"
        card.sourceColumnAuthoredTop = authoredTop
        var restoration = NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = .init(foreground: CGColor(gray: 0, alpha: 1), background: CGColor(gray: 1, alpha: 1),
            restored: true, erasureComplete: true)
        let originalBounds = NativeTranslationRenderer.cardPageLineRects(card)
        #expect(originalBounds.map(\.minY).min() == 263.015625)
        var cards = [card]
        NativeTranslationRenderer.polishFinalGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, anchorsOnly: true)
        #expect(Double(cards[0].item.y) == example.1)
        #expect(cards[0].item.sourceFrame == item.sourceFrame && cards[0].item.sourceBounds == item.sourceBounds)
        #expect(cards[0].style.fontSize == item.fontSize)
        let firstPosition = cards[0].item.rect
        NativeTranslationRenderer.polishFinalGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, anchorsOnly: true)
        #expect(cards[0].item.rect == firstPosition)
    }
}
