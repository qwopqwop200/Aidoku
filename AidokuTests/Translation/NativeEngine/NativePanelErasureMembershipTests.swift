import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePanelErasureMembershipTests {
    @Test(arguments: ["canvas-only", "inside", "early-certified"])
    func compactionRequiresTypographyOrMarginMembershipToDiscardOCRCoverage(_ proof: String) throws {
        let fields: [String: Any] = ["id": "membership", "text": "A B", "typesettingText": "A\nB",
            "typesettingPreformattedRows": true, "typesettingBlockDisplay": true,
            "x": 20, "y": 20, "width": 30, "height": 60, "fontSize": 8, "lineHeight": 28,
            "paddingTop": 0, "paddingRight": 0, "paddingBottom": 0, "paddingLeft": 0,
            "sourceBounds": [0.1,0.1,0.8,0.8], "sourceFrame": [0,0,100,100],
            "sourceColorEligible": true, "sourceTextOnly": false]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontSize: 8, foreground: NativeTranslationRenderer.color([20,20,20]),
            lineHeight: 28, optimizesKoreanWrapping: false, usesPreformattedBlockRows: true,
            blockWordLayoutUsesTopPadding: true)
        let typography = NativeTranslationTypography.layout(text: "A\nB", in: item.contentRect.size, style: style)
        let old = CGRect(x: 0, y: 0, width: 100, height: 100)
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourcePanels: [.init(rect: old, background: [240,240,240], coverage: [old])], drawsPanel: false,
            background: NativeTranslationRenderer.color([240,240,240]), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 8)
        card.earlyErasureCertified = proof == "early-certified"
        let layout = NativeTranslationLayout(imageSize: old.size, sourceRect: old, viewport: old.size, items: [item])
        // All three have an equally complete canvas. Only explicit typography
        // membership or the actual early certificate permits omitting source ink.
        let restoration = NativeTranslationRestoration.Result(appearances: [item.id:
            .init(foreground: nil, background: nil, restored: true, erasureComplete: true)])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        var cards = [card]
        NativeTranslationRenderer.polishPanelGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, phase: .compactOnly,
            restoredSourcePanelIDs: proof == "inside" ? [item.id] : [], rememberedPadding: [item.id: 3])
        let panel = cards[0].sourcePanels[0]
        if proof == "canvas-only" {
            #expect(panel.rect == CGRect(x: 7, y: 7, width: 86, height: 86))
            #expect(NativePanelGeometry.inside(CGRect(x: 10,y: 10,width: 80,height: 80), panel.rect))
        } else {
            #expect(panel.rect.minY == 17 && panel.rect.maxY == 79)
            #expect(panel.rect.width < 30)
        }
        #expect(cards[0].item.sourceBounds == item.sourceBounds && cards[0].item.sourceFrame == item.sourceFrame)
        #expect(cards[0].typography.shapedText == typography.shapedText)
    }
    @Test func capturedCard14RetainsSourceCoverageWhenItsCompleteCanvasHasNoTypographyFit() throws {
        let fields: [String: Any] = ["id": "14", "text": "제 미사용 애널의 용도를 써주셔서 기뻐요……",
            "fontScript": "korean", "wrappingScript": "korean",
            "x": 278.5625, "y": 359.03125, "width": 43.125, "height": 55.09375,
            "fontSize": 7.5, "lineHeight": 8.9501953125,
            "paddingTop": 14.828125, "paddingRight": 0, "paddingBottom": 2.828125, "paddingLeft": 0,
            "sourceBounds": [0.7142857142857143,0.5328305235137534,0.1105889724310777,0.20008873114463177],
            "sourceFrame": [0,212.30263157894737,390,275.39473684210526],
            "sourceFontSize": 9.560721641827598, "sourceVertical": true,
            "sourceColorEligible": true, "sourceTextOnly": false]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 7.5,
            foreground: NativeTranslationRenderer.color([171,171,200]), tracking: -0.09, lineHeight: 8.9501953125,
            optimizesKoreanWrapping: false, balancesHorizontalLines: true, horizontalWrapping: .keepAllWithEmergency)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        let panel = CGRect(x: 275.5625, y: 356.03125, width: 49.125, height: 61.078125)
        let card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourcePanels: [.init(rect: panel, background: [55,65,91], coverage: [panel])], drawsPanel: false,
            background: NativeTranslationRenderer.color([55,65,91]), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 7.5)
        let frame = CGRect(x: 0,y: 212.3529411764706,width: 390,height: 275.29411764705884)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 2380,height: 1680), sourceRect: frame,
            viewport: CGSize(width: 390,height: 700), items: [item])
        var restoration = NativeTranslationRestoration.Result(appearances: [item.id:
            .init(foreground: nil, background: nil, restored: true, erasureComplete: true)])
        restoration.cleanupGeometry = .init(frame: frame, clip: CGRect(x: 0,y: 0,width: 390,height: 700))
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        var cards = [card]
        NativeTranslationRenderer.polishPanelGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, phase: .compactOnly, rememberedPadding: [item.id: 3])
        #expect(cards[0].sourcePanels[0].rect == panel)
        var conflated = [card]
        NativeTranslationRenderer.polishPanelGeometry(cards: &conflated, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, phase: .compactOnly,
            restoredSourcePanelIDs: [item.id], rememberedPadding: [item.id: 3])
        // This incorrect membership is the exact pre-Packing BUILD41 mutation.
        #expect(conflated[0].sourcePanels[0].rect == CGRect(x: 276.984375,y: 372.578125,width: 47.703125,height: 40))
        #expect(cards[0].item.rect == card.item.rect && cards[0].typography.shapedText == card.typography.shapedText)
    }

}
