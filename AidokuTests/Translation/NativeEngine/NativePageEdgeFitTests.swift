import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePageEdgeFitTests {
    @Test(arguments: [false, true])
    func balancedColumnHonorsTheExplicitAutomaticFontRecoverySetting(allowsRecovery: Bool) throws {
        let descriptor: [String: Any] = ["id": "column", "text": "ABCDEFGHIJ", "typesettingText": "ABCDEFGHIJ",
            "typesettingQuoteMode": 1, "x": 0, "y": 20, "width": 100, "height": 60,
            "fontSize": 30, "lineHeight": 36, "allowsAutomaticFontRecovery": allowsRecovery,
            "balancedColumn": true, "sourceBounds": [0, 0.2, 1, 0.6], "sourceFrame": [0, 0, 100, 100]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 30,
            lineHeight: 36, usesBlockWordLayout: true)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            captionParentPlate: true, drawsPanel: false, background: NativeTranslationRenderer.color([255, 255, 255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 30)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        card.cleanupSourceFrame = frame
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        #expect(NativeTranslationRenderer.cardInkRect(card).width > frame.width)
        var cards = [card]
        NativeTranslationRenderer.fitLatePageEdges(cards: &cards, gloss: .init(), layout: layout)
        if allowsRecovery {
            #expect(cards[0].style.fontSize < 30 && cards[0].edgeFit == "shrink")
        } else {
            #expect(cards[0].style.fontSize == 30 && cards[0].edgeFit == nil)
        }
        #expect(cards[0].item == item && cards[0].textShift == .zero)
    }

    @Test(arguments: ["free", "detached", "child"], [false, true])
    func actualManualTypeCanMoveOnlyWhenItHasNoOwningPlate(ownership: String, balancedColumn: Bool) throws {
        let cleanupOffset = balancedColumn ? 20.0 : 0.0
        let descriptor: [String: Any] = ["id": "edge", "text": "ABC", "x": -8 + cleanupOffset, "y": 20, "width": 40, "height": 30,
            "fontSize": 14, "lineHeight": 17, "allowsAutomaticFontRecovery": false, "balancedColumn": balancedColumn,
            "sourceBounds": [0,0.2,0.2,0.2], "sourceFrame": [0,0,100,100]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 14,
            foreground: NativeTranslationRenderer.color([20,20,20]), lineHeight: 17)
        let typography = NativeTranslationTypography.layout(text: "ABC", in: item.contentRect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            captionParentPlate: ownership == "child",
            sourcePanels: ownership != "free" ? [.init(rect: item.rect, background: [255,255,255], coverage: [item.rect])] : [],
            drawsPanel: false, background: NativeTranslationRenderer.color([255,255,255]), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 14)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        card.cleanupSourceFrame = frame.offsetBy(dx: cleanupOffset, dy: 0)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        #expect(NativeTranslationRenderer.cardInkRect(card).minX < cleanupOffset - 0.75)
        var cards = [card]
        NativeTranslationRenderer.fitLatePageEdges(cards: &cards, gloss: .init(), layout: layout)
        #expect(cards[0].style.fontSize == 14 && cards[0].item.rect == card.item.rect)
        if ownership == "child" {
            #expect(cards[0].textShift == .zero && cards[0].edgeFit == nil)
            #expect(cards[0].sourcePanels[0].rect == item.rect)
        } else {
            #expect(cards[0].textShift.x > 0 && cards[0].edgeFit == "shift")
            // CSS left assignment truncates to LayoutUnit; the boundary can
            // lie exactly one unit below the requested content edge.
            #expect(Double(NativeTranslationRenderer.cardInkRect(cards[0]).minX) >= cleanupOffset - 1.0 / 64)
            if ownership == "detached" { #expect(cards[0].sourcePanels[0].rect == item.rect) }
        }
        #expect(cards[0].item.sourceFrame == item.sourceFrame && layout.sourceRect == frame)
    }
}
