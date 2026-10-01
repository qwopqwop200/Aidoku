import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeLightLetteringAdapterTests {
    @Test(arguments: ["plain", "frame", "foreign"])
    func restoredBackgroundImagesSkipLateSourceRestyling(mode: String) throws {
        let size = CGSize(width: 100, height: 80), frame = CGRect(origin: .zero, size: size)
        let rect = CGRect(x: 20, y: 16, width: 60, height: 48)
        let descriptor: [String: Any] = ["id": "pale", "text": "ABC", "x": 20, "y": 16, "width": 60, "height": 48,
            "fontSize": 18, "lineHeight": 22, "sourceColorEligible": true, "sourceTextOnly": false, "sourceFontSize": 24,
            "sourceBounds": [0.2,0.2,0.6,0.6], "sourceFrame": [0,0,100,80]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        var pixels = NativeRestorationPixels(width: 100, height: 80)
        pixels.rgba = [UInt8](repeating: 255, count: 100 * 80 * 4)
        for y in 0..<80 { for x in 0..<100 {
            let stripe = ((x - 23) % 12 + 12) % 12
            let v: UInt8 = x >= 23 && x < 77 && y >= 21 && y < 59 && stripe < 5 ? 245 : 20
            let at = (y * 100 + x) * 4
            pixels.rgba[at] = v; pixels.rgba[at + 1] = v; pixels.rgba[at + 2] = v
        } }
        let image = try #require(pixels.image())
        var panel = NativeTranslationSourceStylePostPolish.Panel(rect: rect, background: [250,250,250], coverage: [rect])
        if mode == "frame" { panel.sourceFrameImage = image; panel.sourceFrameLineCount = 1 }
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 18,
            foreground: NativeTranslationRenderer.color([30,30,30]), lineHeight: 22)
        let typography = NativeTranslationTypography.layout(text: "ABC", in: rect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style, sourcePanels: [panel],
            drawsPanel: false, background: NativeTranslationRenderer.color([250,250,250]), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 18)
        if mode == "foreign" { card.foreignFills = [.init(rect: CGRect(x: 21, y: 17, width: 2, height: 2), color: [245,230,215])] }
        var restoration = NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = .init(foreground: nil, background: nil, restored: false,
            sourceSample: ["foreground": [245.0,245,245]])
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: frame, viewport: size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        var cards = [card]
        NativeTranslationRenderer.applyLightLettering(cards: &cards, layout: layout, restoration: restoration, settings: settings, source: image)
        #expect(cards[0].item.rect == item.rect && cards[0].sourcePanels[0].rect == rect)
        if mode == "plain" {
            #expect(NativeTranslationRenderer.rgb(cards[0].style.foreground) == [245,245,245])
            #expect(cards[0].sourcePanels[0].background == [20,20,20])
            #expect(cards[0].lightLetteringRecord != nil)
        } else {
            #expect(NativeTranslationRenderer.rgb(cards[0].style.foreground) == [30,30,30])
            #expect(cards[0].sourcePanels[0].background == [250,250,250])
            #expect(cards[0].lightLetteringRecord == nil && cards[0].lightLetteringReject == nil)
        }
    }
}
