import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePolarityLegibilityTests {
    @Test func sampledLightInkTonesItsOwnHueWithoutReflowingAndRejectsSharedOwners() throws {
        let descriptor: [String: Any] = ["id": "polarity", "text": "ABC", "x": 10, "y": 10, "width": 100, "height": 40,
            "fontSize": 12, "lineHeight": 15, "sourceColorEligible": true,
            "sourceBounds": [0.1,0.1,0.5,0.2], "sourceFrame": [0,0,200,200]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let plate: [Double] = [210,125,65]
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 12,
            foreground: NativeTranslationRenderer.color([10,10,10]), lineHeight: 15)
        let typography = NativeTranslationTypography.layout(text: "ABC", in: item.contentRect.size, style: style)
        let card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style, clusterRGB: [10,10,10],
            sourcePanels: [.init(rect: item.rect, background: plate, coverage: [item.rect])],
            backings: [.init(frame: item.rect, coverage: [item.rect], color: plate)], drawsPanel: false,
            background: NativeTranslationRenderer.color(plate.map { CGFloat($0) }), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 12)
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        var restoration = NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = .init(foreground: nil, background: nil, restored: false, sourceSample: ["foreground": [245.0,245,235],
            "background": plate, "confidence": ["foreground": 0.8]])
        var cards = [card]
        NativeTranslationRenderer.preserveLetteringPolarity(cards: &cards, gloss: .init(), layout: layout, restoration: restoration, settings: settings)
        #expect(NativeTranslationRenderer.rgb(cards[0].style.foreground) == [255,255,255])
        #expect(cards[0].sourcePanels[0].background == [170,100,51])
        #expect(cards[0].backings[0].color == [170,100,51])
        #expect(cards[0].clusterRGB == nil && cards[0].polarityRecord != nil)
        #expect(cards[0].item.rect == card.item.rect && cards[0].style.fontSize == card.style.fontSize)
        var shared = [card]; shared[0].sourcePanels[0].hasForeignChildren = true
        NativeTranslationRenderer.preserveLetteringPolarity(cards: &shared, gloss: .init(), layout: layout, restoration: restoration, settings: settings)
        #expect(shared[0].polarityRejection == "shared" && shared[0].polarityRecord == nil)
        #expect(shared[0].sourcePanels[0].background == plate)
    }
}
