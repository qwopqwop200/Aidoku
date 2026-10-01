import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeLateKoreanAdapterTests {
    private func fixture(unit: Bool = false) throws -> (NativeTranslationRenderer.Card, NativeTranslationLayout, IPhoneOverlaySettings) {
        let frame: Double = unit ? 500 : 400
        var object: [String: Any] = ["id": "late-korean", "text": unit ? "가나다 라마바 사아자 차카타 파하가 나다라" : "카나반칙",
            "x": unit ? 180 : 170, "y": unit ? 120 : 130, "width": unit ? 80 : 15, "height": 120,
            "fontSize": unit ? 12 : 15, "lineHeight": unit ? 14.4 : 18, "fontScript": "korean", "wrappingScript": "korean",
            "allowsAutomaticFontRecovery": true, "sourceBounds": unit ? [0.34,0.2,0.2,0.48] : [0.425,0.325,0.0375,0.3],
            "sourceFrame": [0,0,frame,frame], "sourceFontSize": 24]
        if unit {
            object["unitMemberRects"] = [[0.34,0.2,0.2,0.14],[0.34,0.54,0.2,0.14]]
            object["balloonInterior"] = ["rect": [0,0,1,1], "center": [0.5,0.5], "spans": Array(repeating: [0.0,1.0], count: 32).flatMap { $0 }, "contourVerified": true] as [String: Any]
        }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: object))
        var style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: item.fontSize, lineHeight: item.lineHeight)
        style.optimizesKoreanWrapping = false; style.balancesHorizontalLines = false
        style.balancesExplicitParagraphs = false; style.keepsWholeWords = false
        let card = NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style), style: style,
            drawsPanel: false, background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: item.fontSize)
        let size = CGSize(width: frame, height: frame)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero,size: size), viewport: size, items: [item])
        let settings = IPhoneOverlaySettings(visible: true,mode: .translateOnly,colorMode: .white,opacity: 1,textPlacement: .replace,
            subtitlePosition: .bottom,subtitleMaxLines: 2,subtitleContextSentences: 0)
        return (card,layout,settings)
    }
    private func source(_ size: Int, gray: UInt8 = 255) throws -> CGImage {
        var pixels = NativeRestorationPixels(width: size,height: size)
        pixels.rgba = Array(repeating: [gray,gray,gray,255],count: pixels.count).flatMap { $0 }
        return try #require(pixels.image())
    }
    @Test func actualStackRepairJoinsSyllablesAndKeepsExistingOwnerGeometry() throws {
        var (card,layout,settings) = try fixture()
        let unshifted = card
        card.textShift = CGPoint(x: 10,y: 0)
        let before = NativeTranslationRenderer.stackRows(card,text: card.item.text)
        #expect(before.count >= 2)
        #expect(NativeKoreanStackRepair.kind(text: card.item.text,rows: before,unit: false,reduplication: { _ in false }) == "stack")
        let plate = CGRect(x: 30,y: 30,width: 340,height: 340)
        card.sourcePanels = [.init(rect: plate,background: [255,255,255],coverage: [plate])]
        var cards = [card]
        NativeTranslationRenderer.repairKoreanStacks(cards: &cards,gloss: .init(),layout: layout,restoration: .init(),source: try source(400),settings: settings)
        #expect(cards[0].stackRepair != nil)
        var control = [unshifted]
        control[0].sourcePanels = card.sourcePanels
        NativeTranslationRenderer.repairKoreanStacks(cards: &control,gloss: .init(),layout: layout,restoration: .init(),source: try source(400),settings: settings)
        #expect(control[0].stackRepair != nil)
        let shiftedInk = NativeTranslationRenderer.cardInkRect(cards[0])
        let controlInk = NativeTranslationRenderer.cardInkRect(control[0])
        #expect(abs(shiftedInk.midX-controlInk.midX-10) < 0.01)
        #expect(abs(shiftedInk.midY-controlInk.midY) < 0.01)
        let after = NativeTranslationRenderer.stackRows(cards[0],text: card.item.text)
        #expect(after.count < before.count)
        #expect(NativeKoreanStackRepair.kind(text: card.item.text,rows: after,unit: false,reduplication: { _ in false }) == nil)
        #expect(cards[0].sourcePanels[0].rect == plate)
        #expect(cards[0].sourcePanels[0].coverage == [plate])
        #expect(cards[0].sourcePlateRect == card.sourcePlateRect)
        #expect(cards[0].item.sourceBounds == card.item.sourceBounds)
    }
    @Test func actualStackRepairDeclinesArtworkOutsideItsOldSourceAndLettering() throws {
        var (card,layout,settings) = try fixture()
        let plate = CGRect(x: 30,y: 30,width: 340,height: 340)
        card.sourcePanels = [.init(rect: plate,background: [255,255,255],coverage: [plate])]
        var cards = [card]
        NativeTranslationRenderer.repairKoreanStacks(cards: &cards,gloss: .init(),layout: layout,restoration: .init(),source: try source(400,gray: 0),settings: settings)
        #expect(cards[0].stackRepair == nil)
        #expect(cards[0].stackRepairDeclined != nil)
        #expect(cards[0].item == card.item)
        #expect(cards[0].sourcePanels[0].rect == plate)
    }
    @Test func actualUnitPartsGrowWithCoreTextAndPreserveBothMemberReadingOrder() throws {
        var (card,layout,settings) = try fixture(unit: true)
        card.textShift = CGPoint(x: 10,y: -7)
        var cards = [card]
        let restoration = NativeTranslationRestoration.Result()
        let balloons = NativeTranslationRenderer.BalloonRelayoutContext(layout: layout,source: try source(500),restoration: restoration,cards: cards)
        NativeTranslationRenderer.splitBalloonUnitParts(cards: &cards,gloss: .init(),layout: layout,restoration: restoration,settings: settings,balloons: balloons)
        #expect(cards[0].unitParts != nil)
        #expect(cards[0].unitTextParts.count == 2)
        #expect(cards[0].textShift == .zero)
        let proofLines = cards[0].unitTextParts.flatMap { part in
            NativeTranslationTypography.captionLineMetrics(layout: part.typography).map { $0.rect.offsetBy(dx: part.frame.minX,dy: part.frame.minY) }
        }
        #expect(NativeTranslationRenderer.cardPageLineRects(cards[0]) == proofLines)
        for part in cards[0].unitTextParts { #expect(NativeTranslationRenderer.textPartFrame(part,card: cards[0]) == part.frame) }

        #expect(cards[0].finalFontSize > card.finalFontSize && cards[0].finalFontSize <= card.finalFontSize * 1.5)
        let text = cards[0].unitTextParts.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text == card.item.text)
        #expect(cards[0].unitTextParts[0].frame.midY < cards[0].unitTextParts[1].frame.midY)
        #expect(cards[0].unitTextParts.allSatisfy { $0.typography.fits && !$0.typography.rangeBounds.isEmpty })
        #expect(cards[0].item == card.item)
        #expect(cards[0].sourcePlateRect == card.sourcePlateRect)
    }
    @Test func actualUnitPartsRespectResidualSourceRiskAndTranslucency() throws {
        let (card,layout,settings) = try fixture(unit: true)
        var restoration = NativeTranslationRestoration.Result()
        restoration.unitResidueRiskIDs.insert(card.item.id)
        var risk = [card]
        let balloons = NativeTranslationRenderer.BalloonRelayoutContext(layout: layout,source: try source(500),restoration: restoration,cards: risk)
        NativeTranslationRenderer.splitBalloonUnitParts(cards: &risk,gloss: .init(),layout: layout,restoration: restoration,settings: settings,balloons: balloons)
        #expect(risk[0].unitTextParts.isEmpty && risk[0].unitParts == nil)
        #expect(risk[0].item == card.item && risk[0].style.fontSize == card.style.fontSize)
        var fadedSettings = settings
        fadedSettings.opacity = 0.5
        var faded = [card]
        NativeTranslationRenderer.splitBalloonUnitParts(cards: &faded,gloss: .init(),layout: layout,restoration: .init(),settings: fadedSettings,balloons: balloons)
        #expect(faded[0].unitTextParts.isEmpty && faded[0].unitParts == nil)
    }
}
