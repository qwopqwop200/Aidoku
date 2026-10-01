import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeLateBalloonCleanupFrameTests {
    private func fixture(offset: Double, unit: Bool = false, floor: Bool = false) throws -> (
        NativeTranslationLayout, NativeTranslationRenderer.Card, NativeTranslationRestoration.Result,
        NativeTranslationRenderer.BalloonRelayoutContext, IPhoneOverlaySettings) {
        let size = unit ? 500.0 : 200.0, font = floor ? 8.0 : 12.0
        let originalFrame = CGRect(x: 0, y: 0, width: size, height: size)
        let cleanupFrame = originalFrame.offsetBy(dx: 0, dy: offset)
        var object: [String: Any] = ["id": "late-normalized", "text": unit ? "가나다 라마바 사아자 차카타 파하가 나다라" : "ABC",
            "x": unit ? 180.0 : 30.0, "y": (unit ? 120.0 : floor ? 180.0 : 40.0) + offset,
            "width": unit ? 80.0 : 60.0, "height": unit ? 120.0 : floor ? 18.0 : 40.0,
            "fontSize": font, "lineHeight": font * 1.2, "sourceTextOnly": false,
            "fontScript": unit ? "korean" : "", "wrappingScript": unit ? "korean" : "latin",
            "sourceBounds": unit ? [0.34, 0.2, 0.2, 0.48] : [0.4, 0.4, 0.1, 0.1],
            "sourceFrame": [0, 0, size, size], "sourceFontSize": 24]
        object["balloonInterior"] = ["rect": unit ? [0.0, 0.0, 1.0, 1.0] : [0.2, 0.2, 0.6, 0.6],
            "center": [0.5, 0.5], "spans": Array(repeating: unit ? [0.0, 1.0] : [0.2, 0.8], count: 32).flatMap { $0 },
            "contourVerified": true] as [String: Any]
        if unit { object["unitMemberRects"] = [[0.34, 0.2, 0.2, 0.14], [0.34, 0.54, 0.2, 0.14]] }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: object))
        let layout = NativeTranslationLayout(imageSize: originalFrame.size, sourceRect: originalFrame,
            viewport: CGSize(width: size, height: size + offset * 2), items: [item])
        var style = NativeTranslationTypography.Style(fontScript: unit ? "korean" : "", fontSize: font, lineHeight: font * 1.2)
        style.optimizesKoreanWrapping = false; style.balancesHorizontalLines = false
        style.balancesExplicitParagraphs = false; style.keepsWholeWords = false
        var card = NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style), style: style,
            sourceBackgroundKind: "inpainted", drawsPanel: false, background: CGColor(gray: 1, alpha: 1),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
        card.cleanupSourceFrame = cleanupFrame
        var restoration = NativeTranslationRestoration.Result()
        restoration.cleanupGeometry = .init(frame: cleanupFrame, clip: CGRect(origin: .zero, size: layout.viewport))
        var pixels = NativeRestorationPixels(width: Int(size), height: Int(size))
        pixels.rgba = [UInt8](repeating: 255, count: pixels.count * 4)
        let image = try #require(pixels.image())
        let balloons = NativeTranslationRenderer.BalloonRelayoutContext(layout: layout, source: image, restoration: restoration, cards: [card])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        return (layout, card, restoration, balloons, settings)
    }

    @Test(arguments: [0.0, 240.0])
    func readableFloorChecksNormalizedPageBounds(offset: Double) throws {
        let (layout, card, restoration, _, settings) = try fixture(offset: offset, floor: true)
        var cards = [card]
        NativeTranslationRenderer.holdLateReadableFloor(cards: &cards, gloss: .init(), layout: layout, restoration: restoration, settings: settings)
        #expect(cards[0].style.fontSize == 8.5)
        #expect(cards[0].item.rect == card.item.rect)
        #expect(cards[0].item.sourceFrame == layout.items[0].sourceFrame)
    }

    @Test(arguments: [0.0, 240.0])
    func verifiedBodyCenterUsesStoredCleanupFrame(offset: Double) throws {
        let (layout, card, _, _, settings) = try fixture(offset: offset)
        var cards = [card]
        NativeTranslationRenderer.centerLateBalloonBodies(cards: &cards, gloss: .init(), layout: layout, settings: settings)
        let ink = NativeTranslationRenderer.cardInkRect(cards[0])
        #expect(abs(ink.midX - 100) < 1.0 / 64)
        #expect(abs(ink.midY - 100 - offset) < 1.0 / 64)
        #expect(cards[0].item.rect == card.item.rect)
    }

    @Test(arguments: [0.0, 240.0])
    func contourClippingUsesTheSameNormalizedSourceCoordinates(offset: Double) throws {
        let (layout, card, _, balloons, settings) = try fixture(offset: offset)
        var cards = [card]
        let panel = try #require(card.cleanupSourceFrame)
        cards[0].sourcePanels = [.init(rect: panel, background: [255,255,255], coverage: [panel])]
        NativeTranslationRenderer.clipLateBalloonPanels(cards: &cards, gloss: .init(), layout: layout, settings: settings, balloons: balloons)
        let next = cards[0].sourcePanels[0]
        #expect(next.balloonInteriorClipped != nil)
        #expect(next.coverage.allSatisfy { $0.minY >= offset && $0.maxY <= offset + 200 })
        #expect(next.coverage.contains { $0.contains(NativeTranslationRenderer.cardInkRect(cards[0])) })
    }

    @Test(arguments: [0.0, 240.0])
    func joinedPartsStayOnTheNormalizedMemberBodies(offset: Double) throws {
        let (layout, card, restoration, balloons, settings) = try fixture(offset: offset, unit: true)
        var cards = [card]
        NativeTranslationRenderer.splitBalloonUnitParts(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, balloons: balloons)
        #expect(cards[0].unitTextParts.count == 2)
        #expect(cards[0].unitTextParts.allSatisfy { $0.frame.midY >= offset && $0.frame.midY <= offset + 500 })
        #expect(cards[0].unitTextParts[0].frame.midY < cards[0].unitTextParts[1].frame.midY)
        #expect(cards[0].item == card.item)
    }

    @Test func replacingPreservedSpanTreeResetsOnlyRemovedChildMetadata() throws {
        var (layout, card, restoration, balloons, settings) = try fixture(offset: 240, unit: true)
        card.item.typesettingText = "가나다 라마바 \n사아자 차카타 \n파하가 나다라"
        card.item.typesettingQuoteMode = 1
        card.item.typesettingBlockDisplay = true
        card.item.typesettingPreservedBlockWrapper = true
        card.item.typesettingPreformattedRows = true
        card.style.usesPreformattedBlockRows = true
        card.item.captionFixedBoxReflowDisabled = true
        card.style.usesBlockWordLayout = true
        card.style.blockWordLayoutUsesTopPadding = true
        card.typography = NativeTranslationRenderer.remeasureTypography(card)
        var cards = [card]
        NativeTranslationRenderer.splitBalloonUnitParts(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, balloons: balloons)
        let next = cards[0]
        #expect(next.unitTextParts.count == 2)
        #expect(next.item.typesettingPreservedBlockWrapper == nil && next.item.typesettingText == nil)
        #expect(next.item.typesettingPreformattedRows == nil && !next.style.usesPreformattedBlockRows)
        #expect(next.unitTextParts.allSatisfy { !$0.style.usesPreformattedBlockRows })
        #expect(next.item.typesettingQuoteMode == nil && next.item.typesettingBlockDisplay == nil)
        #expect(!next.style.usesBlockWordLayout && !next.style.blockWordLayoutUsesTopPadding)
        #expect(next.unitTextParts.allSatisfy { !$0.style.usesBlockWordLayout && !$0.style.blockWordLayoutUsesTopPadding })
        #expect(next.item.captionFixedBoxReflowDisabled == true)
        #expect(next.item.sourceBounds == card.item.sourceBounds && next.item.sourceFrame == card.item.sourceFrame)
        // A rejected replacement leaves the old child tree and its marker intact.
        restoration.unitResidueRiskIDs.insert(card.item.id)
        var rejected = [card]
        NativeTranslationRenderer.splitBalloonUnitParts(cards: &rejected, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, balloons: balloons)
        #expect(rejected[0].item == card.item && rejected[0].unitTextParts.isEmpty)
        #expect(rejected[0].style.usesBlockWordLayout && rejected[0].style.blockWordLayoutUsesTopPadding)
        #expect(rejected[0].item.typesettingPreformattedRows == true && rejected[0].style.usesPreformattedBlockRows)
    }
}
