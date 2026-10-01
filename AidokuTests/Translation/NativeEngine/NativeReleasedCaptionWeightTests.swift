import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor struct NativeReleasedCaptionWeightTests {
    private let frame = CGRect(x: 0, y: 0, width: 180, height: 100)

    private func card() throws -> NativeTranslationRenderer.Card {
        let descriptor: [String: Any] = ["id": "caption", "text": "앗군, 다녀왔어!",
            "x": 15, "y": 20, "width": 150, "height": 60,
            "fontSize": 14.5, "lineHeight": 17.303711, "fontScript": "korean",
            "sourceBounds": [0.1, 0.2, 0.8, 0.6], "sourceFrame": [0, 0, 180, 100]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 14.5,
            foreground: NativeTranslationRenderer.color([3, 3, 3]), lineHeight: 17.303711)
        return .init(item: item,
            typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style),
            style: style, sourcePanels: [.init(rect: item.rect, background: [255, 255, 255], coverage: [item.rect])],
            drawsPanel: false, background: NativeTranslationRenderer.color([255, 255, 255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0.65, finalFontSize: 14.5)
    }

    private func paintedBytes(_ card: NativeTranslationRenderer.Card) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(frame)
            NativeTranslationRenderer.draw(card, context: renderer.cgContext, opacity: 1,
                paintsBackground: false, paintsSourcePanels: false)
        }
        return try #require(image.cgImage?.dataProvider?.data) as Data
    }

    @Test(arguments: [false, true], [false, true])
    func certifiedReleaseReplacesEarlierHeavyStrokeWithoutChangingUnreleasedText(certified: Bool, preserveFill: Bool) throws {
        let original = try card()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in }
        let patchImage = try #require(blank.cgImage)
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image: patchImage, rect: original.item.rect, itemID: original.item.id)]
        let sample: [String: Any] = ["foreground": [3.0, 3.0, 3.0], "background": [255.0, 255.0, 255.0],
            "confidence": ["foreground": preserveFill ? 1.0 : 0.0, "background": 1.0]]
        restoration.appearances[original.item.id] = .init(foreground: original.style.foreground,
            background: original.background, restored: certified, erasureComplete: certified,
            sourceSample: sample, restorationMethod: "observed-palette", sourceGlyphsVerified: certified)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame,
            viewport: frame.size, items: [original.item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true; settings.inpaintingEnabled = true
        var cards = [original]
        NativeTranslationRenderer.releaseCertifiedPlates(cards: &cards, restoration: restoration,
            gloss: .init(), layout: layout, settings: settings)
        let result = try #require(cards.first)
        #expect(result.glyphPlateReleased == certified)
        #expect(result.item.rect == original.item.rect)
        #expect(result.finalFontSize == original.finalFontSize)
        if certified {
            #expect(result.sourcePanels.isEmpty)
            #expect(result.heavyStrokeWidth == 0)
            #expect((result.style.outline == nil) == preserveFill)
            #expect((result.style.outlineWidth == 0) == preserveFill)
            var expected = result
            expected.heavyStrokeWidth = 0
            let matchesReleasedPaint = try paintedBytes(result) == paintedBytes(expected)
            #expect(matchesReleasedPaint)
            if preserveFill {
                var stale = result
                stale.heavyStrokeWidth = original.heavyStrokeWidth
                let differsFromStaleWeight = try paintedBytes(result) != paintedBytes(stale)
                #expect(differsFromStaleWeight)
            }
        } else {
            #expect(result.sourcePanels.count == original.sourcePanels.count)
            #expect(result.heavyStrokeWidth == original.heavyStrokeWidth)
            let retainsOriginalPaint = try paintedBytes(result) == paintedBytes(original)
            #expect(retainsOriginalPaint)
        }
    }
}
