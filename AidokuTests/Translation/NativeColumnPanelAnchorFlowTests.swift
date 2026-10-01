import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeColumnPanelAnchorFlowTests {
    @Test(arguments: [false, true], [(0.1805678793256433, 261.03125), (0.17968056787932565, 260.796875)])
    func panelPolishAndFinalAnchorRetainOriginalColumnProvenance(originalBalanced: Bool, source: (Double, Double)) throws {
        let authoredTop = 262.03007518796994
        let descriptor: [String: Any] = ["id": "column-flow", "text": "드디어 선생님이 왔다", "sourceTextOnly": false,
            "x": 117.140625, "y": 262.015625, "width": 24.765625, "height": 32,
            "paddingTop": 2, "paddingRight": 2, "paddingBottom": 2, "paddingLeft": 2,
            "fontSize": 7.02906976744186, "lineHeight": 9.375, "sourceVertical": true, "balancedColumn": originalBalanced,
            "fontScript": "korean", "wrappingScript": "korean", "allowsAutomaticFontRecovery": false,
            "sourceBounds": [0.31109022556390975, source.0, 0.05043859649122807, 0.17346938775510204],
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
        // This is translated caption ink, not a kept source lettering node.
        // The slot admits an actual nonzero correction before anchoring.
        #expect(!card.item.sourceTextOnly)
        let slot = try #require(item.columnLayout).rect
        let ink = NativeTranslationRenderer.cardInkRect(card)
        let shift = slot.minY + 2 - ink.minY
        #expect(shift > 0.25)
        #expect(NativeTranslationCaptionPanelPolish.contains(slot, ink.offsetBy(dx: 0, dy: shift)))
        var cards = [card]
        var restoration = NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = .init(foreground: CGColor(gray: 0, alpha: 1), background: CGColor(gray: 1, alpha: 1),
            restored: true, erasureComplete: true)
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 2, subtitleContextSentences: 0)
        NativeTranslationRenderer.polishCaptionPanels(cards: &cards, glossCards: [], gloss: .init(),
            layout: layout, settings: settings, source: nil)
        // A recovered CSS block does not become an originally balanced item.
        // Genuine balanced items still move, retaining the authored CSS top.
        #expect(cards[0].item.balancedColumn == originalBalanced)
        if originalBalanced {
            #expect(cards[0].item.y > item.y + 0.25)
            let movedTop = try #require(cards[0].sourceColumnAuthoredTop)
            #expect(Double(movedTop) > authoredTop)
        } else {
            #expect(cards[0].item.rect == item.rect)
            let retainedTop = try #require(cards[0].sourceColumnAuthoredTop)
            // Compare the same concrete numeric type: Swift Testing's generic
            // optional CGFloat/Double equality misreports equal bit patterns.
            #expect(Double(retainedTop) == authoredTop)
        }
        NativeTranslationRenderer.polishFinalGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, anchorsOnly: true)
        #expect(Double(cards[0].item.y) == source.1)
        #expect(cards[0].item.sourceBounds == item.sourceBounds && cards[0].item.sourceFrame == item.sourceFrame)
        let anchored = cards[0].item.rect
        NativeTranslationRenderer.polishFinalGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, anchorsOnly: true)
        #expect(cards[0].item.rect == anchored)
    }
}
