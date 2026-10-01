import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor struct NativeSourcePanelOutlineOrderTests {
    private typealias Order = NativeTranslationTypography.OutlinePaintOrder

    // Frozen caption-palette producer first rejects item.rotation, then assigns
    // paintOrder='normal'. Its later rotated release changes stroke, not order.
    @Test(arguments: [0, 1, 2, 3])
    func actualPaletteProducerResetsOnlyUprightCardsAndRotatedReleaseInheritsIt(_ scenario: Int) throws {
        let rotation = scenario >= 2 ? 0.1 : 0.0
        let order: Order = scenario.isMultiple(of: 2) ? .strokeThenFill : .fillThenStroke
        let payload: [String: Any] = [
            "id": "outline", "text": "TEST", "x": 30, "y": 40, "width": 120, "height": 42,
            "fontSize": 20, "lineHeight": 24, "rotation": rotation,
            "fontScript": "latin", "wrappingScript": "latin", "sourceColorEligible": true,
            "sourceBounds": [0.15, 0.2, 0.6, 0.21], "sourceFrame": [0, 0, 200, 200]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: data)
        let fill = CGColor(gray: 0.1, alpha: 1), outline = CGColor(gray: 1, alpha: 1)
        let style = NativeTranslationTypography.Style(fontName: "Helvetica", fontScript: "latin", fontSize: 20,
            foreground: fill, outline: outline, outlineWidth: 1,
            outlinePaintOrder: order, tracking: 0, lineHeight: 24)
        var cards = [NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style),
            style: style, drawsPanel: false, background: outline, usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 20)]
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true; settings.inpaintingEnabled = true
        var restoration = NativeTranslationRestoration.Result()
        restoration.appearances[item.id] = .init(foreground: fill, background: outline, restored: false,
            erasureComplete: true, sourceSample: ["foreground": [25.0, 25.0, 25.0], "background": [255.0, 255.0, 255.0]],
            sourceGlyphsVerified: true)

        NativeTranslationRenderer.prepareSourcePanels(cards: &cards, restoration: restoration,
            layout: layout, settings: settings)
        let expected: Order = rotation == 0 ? .fillThenStroke : order
        #expect(cards[0].style.outlinePaintOrder == expected)
        #expect(cards[0].item.rect == item.rect && cards[0].item.rotation == item.rotation)
        #expect(cards[0].finalFontSize == 20)
        guard rotation != 0 else { return }
        #expect(cards[0].rotatesSourcePanels && !cards[0].sourcePanels.isEmpty)

        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        restoration.patches = [.init(image: image, rect: item.rect, itemID: item.id)]
        NativeTranslationRenderer.releaseCertifiedPlates(cards: &cards, restoration: restoration,
            gloss: .init(), layout: layout, settings: settings)
        #expect(cards[0].glyphPlateReleased && cards[0].sourcePanels.isEmpty)
        #expect(cards[0].style.outlinePaintOrder == order)
        #expect(abs(cards[0].style.outlineWidth - 0.9) < 1e-12)
        #expect(cards[0].item.rect == item.rect && cards[0].finalFontSize == 20)
    }
}
