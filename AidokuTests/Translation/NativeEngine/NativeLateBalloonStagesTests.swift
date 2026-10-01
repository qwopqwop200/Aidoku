import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeLateBalloonStagesTests {
    private func fixture(font: Double = 12, contour: Bool = false) throws -> (NativeTranslationLayout, NativeTranslationRenderer.Card, IPhoneOverlaySettings) {
        var descriptor: [String: Any] = ["id": "balloon", "text": "ABC", "x": 30, "y": 40, "width": 60, "height": 40,
            "fontSize": font, "lineHeight": font * 1.2, "sourceColorEligible": true,
            "sourceBounds": [0.4,0.4,0.1,0.1], "sourceFrame": [0,0,200,200]]
        if contour { descriptor["balloonInterior"] = ["rect": [0.2,0.2,0.6,0.6], "center": [0.5,0.5], "spans": [0.2,0.8], "contourVerified": true] }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: font, foreground: NativeTranslationRenderer.color([20,20,20]), lineHeight: font * 1.2)
        let typography = NativeTranslationTypography.layout(text: "ABC", in: item.contentRect.size, style: style)
        let card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourceBackgroundKind: "inpainted", drawsPanel: false,
            background: NativeTranslationRenderer.color([255,255,255]), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        return (layout, card, settings)
    }

    @Test(arguments: [1.0, 0.9])
    func actualPlateFreeFloorKeepsLineCountAndOriginalSourceGeometry(scale: Double) throws {
        let (layout, initialCard, settings) = try fixture(font: 8)
        var card = initialCard
        card.style.horizontalScale = scale
        card.typography = NativeTranslationRenderer.remeasureTypography(card)
        // Eligibility is the live node state even when the original restoration
        // appearance was absent or incomplete.
        let restoration = NativeTranslationRestoration.Result()
        var cards = [card]
        NativeTranslationRenderer.holdLateReadableFloor(cards: &cards, gloss: .init(), layout: layout, restoration: restoration, settings: settings)
        #expect(cards[0].style.fontSize == 8.5 && cards[0].readableFloorHeld == [8,8.5])
        #expect(cards[0].item.rect == card.item.rect && cards[0].sourcePanels.isEmpty)
        #expect(cards[0].typography.lineCount == card.typography.lineCount)
        #expect(cards[0].style.horizontalScale == CGFloat(scale))
        var plated = [card]
        plated[0].sourcePanels = [.init(rect: card.item.rect, background: [255,255,255], coverage: [card.item.rect])]
        plated[0].captionParentPlate = true
        NativeTranslationRenderer.holdLateReadableFloor(cards: &plated, gloss: .init(), layout: layout, restoration: restoration, settings: settings)
        #expect(plated[0].style.fontSize == 8 && plated[0].readableFloorHeld == nil)
        plated[0].captionParentPlate = false
        NativeTranslationRenderer.holdLateReadableFloor(cards: &plated, gloss: .init(), layout: layout, restoration: restoration, settings: settings)
        #expect(plated[0].style.fontSize == 8.5 && plated[0].sourcePanels[0].rect == card.item.rect)
        var stale = [card]
        stale[0].sourceBackgroundKind = "readability-panel"
        NativeTranslationRenderer.holdLateReadableFloor(cards: &stale, gloss: .init(), layout: layout, restoration: restoration, settings: settings)
        #expect(stale[0].style.fontSize == 8 && stale[0].readableFloorHeld == nil)
    }

    @Test(arguments: [false, true])
    func actualBodyCenterMovesOnlyLetteringInsideVerifiedLobe(child: Bool) throws {
        let (layout, card, settings) = try fixture(contour: true)
        var cards = [card]
        let panel = child ? layout.sourceRect : card.item.rect
        cards[0].sourcePanels = [.init(rect: panel, background: [255,255,255], coverage: [panel])]
        cards[0].captionParentPlate = child
        NativeTranslationRenderer.centerLateBalloonBodies(cards: &cards, gloss: .init(), layout: layout, settings: settings)
        let ink = NativeTranslationRenderer.cardInkRect(cards[0])
        #expect(abs(ink.midX - 100) < 1.0 / 64 && abs(ink.midY - 100) < 1.0 / 64)
        #expect(cards[0].sourcePanels[0].rect == panel && cards[0].item.rect == card.item.rect)
        #expect(cards[0].balloonCenterShift != nil)
    }

    @Test func actualContourClipRetainsInkAndSharesTheObservedInterior() throws {
        let (layout, card, settings) = try fixture(contour: true)
        var cards = [card]
        cards[0].sourcePanels = [.init(rect: layout.sourceRect, background: [255,255,255], coverage: [layout.sourceRect])]
        var pixels = NativeRestorationPixels(width: 200, height: 200)
        pixels.rgba = [UInt8](repeating: 255, count: 200 * 200 * 4)
        let image = try #require(pixels.image())
        let context = NativeTranslationRenderer.BalloonRelayoutContext(layout: layout, source: image, restoration: .init(), cards: cards)
        NativeTranslationRenderer.clipLateBalloonPanels(cards: &cards, gloss: .init(), layout: layout, settings: settings, balloons: context)
        let panel = cards[0].sourcePanels[0]
        #expect(panel.balloonInteriorClipped != nil && panel.captionUnionClipped)
        let coverage = try #require(panel.coverage.first)
        #expect(coverage.width < layout.sourceRect.width && coverage.height < layout.sourceRect.height)
        #expect(coverage.contains(NativeTranslationRenderer.cardInkRect(cards[0])))
        #expect(context.interiors[card.item.id]?.native == true)
        #expect(context.estimator.remainingPixels == 3_000_000)
    }
}
