import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePanelCleanupGeometryTests {
    @Test func actualCompactionUsesNormalizedCleanupFrameWithoutChangingOCRDescriptor() throws {
        let originalFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let cleanupFrame = CGRect(x: 10, y: 20, width: 100, height: 80)
        let descriptor: [String: Any] = ["id": "cleanup", "text": "A", "x": 32, "y": 38, "width": 16, "height": 12,
            "fontSize": 8, "lineHeight": 10, "paddingTop": 0, "paddingRight": 0, "paddingBottom": 0, "paddingLeft": 0,
            "sourceBounds": [0.2, 0.2, 0.2, 0.2], "sourceFrame": [0, 0, 200, 100], "sourceFontSize": 3,
            "sourceColorEligible": true, "sourceTextOnly": false]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 8,
            foreground: NativeTranslationRenderer.color([20,20,20]), lineHeight: 10)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        let card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourcePanels: [.init(rect: originalFrame, background: [245,245,245], coverage: [originalFrame])], drawsPanel: false,
            background: NativeTranslationRenderer.color([245,245,245]), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 8)
        let layout = NativeTranslationLayout(imageSize: originalFrame.size, sourceRect: originalFrame,
            viewport: originalFrame.size, items: [item])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        var normalized = NativeTranslationRestoration.Result()
        normalized.cleanupGeometry = .init(frame: cleanupFrame, clip: originalFrame)
        var cards = [card]
        NativeTranslationRenderer.polishPanelGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: normalized, settings: settings, phase: .compactOnly)
        // Cleanup source [30,36,20,16] with 3px protection controls the exact
        // compact footprint. The original OCR frame would instead require
        // source [40,20,40,20], extending the panel up and to the right.
        #expect(cards[0].sourcePanels[0].rect == CGRect(x: 27, y: 33, width: 26, height: 22))
        #expect(cards[0].sourcePanels[0].coverage == [cards[0].sourcePanels[0].rect])
        #expect(cards[0].item.sourceFrame == [0,0,200,100] && layout.sourceRect == originalFrame)
        var fallback = [card]
        NativeTranslationRenderer.polishPanelGeometry(cards: &fallback, gloss: .init(), layout: layout,
            restoration: .init(), settings: settings, phase: .compactOnly)
        #expect(fallback[0].sourcePanels[0].rect.minY == 17)
        #expect(fallback[0].sourcePanels[0].rect.maxX == 83)
        #expect(fallback[0].sourcePanels[0].rect != cards[0].sourcePanels[0].rect)
    }
}
