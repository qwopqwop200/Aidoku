import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourcePanelOverflowTests {
    @Test(arguments: [false, true])
    func onlyHiddenOwnerAddsTheIndependentBorderClip(hidden: Bool) throws {
        // Captured real25/card4 CSS box and export scale. The border shape
        // snaps to DPR3, while the requested image scale remains independent.
        let rect = CGRect(x: 344.6875, y: 223.640625, width: 37.625, height: 45.203125)
        let crop = rect.insetBy(dx: -2, dy: -2)
        let scale = CGFloat(3192) / 390
        let fields: [String: Any] = ["id": "owner", "text": "", "x": rect.minX, "y": rect.minY,
            "width": rect.width, "height": rect.height, "fontSize": 8.5, "lineHeight": 10.2,
            "sourceBounds": [0.1, 0.1, 0.1, 0.1], "sourceFrame": [0, 0, 390, 700]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontSize: 8.5,
            foreground: NativeTranslationRenderer.color([0, 0, 0]))
        let typography = NativeTranslationTypography.layout(text: "", in: item.contentRect.size, style: style)
        var panel = NativeTranslationSourceStylePostPolish.Panel(rect: rect, background: [154, 172, 191], coverage: [rect])
        panel.radius = 2; panel.overflowClip = hidden
        let card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourcePanels: [panel], drawsPanel: false, background: NativeTranslationRenderer.color([154, 172, 191]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 8.5)
        func pixels(_ paint: (CGContext) -> Void) throws -> [UInt8] {
            let width = Int(ceil(crop.width * scale)), height = Int(ceil(crop.height * scale))
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { memory in
                let context = try #require(CGContext(data: memory.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x: scale, y: scale); context.translateBy(x: -crop.minX, y: -crop.minY)
                paint(context)
            }
            return bytes
        }
        let actual = try pixels { context in
            NativeTranslationRenderer.draw(card, context: context, opacity: 1,
                paintsBackground: false, paintsText: false, paintsSourcePanels: true, pixelSnapScale: 3)
        }
        func reference(clip: Bool) throws -> [UInt8] {
            try pixels { context in
                if clip { context.clip(to: NativeTranslationPDFCapture.snappedRect(rect, deviceScale: 3)) }
                context.setFillColor(NativeTranslationRenderer.color([154, 172, 191]))
                context.addPath(NativeTranslationPDFCapture.roundedPath(rect, radius: 2, deviceScale: 3))
                context.fillPath()
            }
        }
        let expected = try reference(clip: hidden)
        let opposite = try reference(clip: !hidden)
        #expect(actual == expected)
        #expect(actual != opposite)
    }

    @Test func ownerOverflowStateSurvivesRootDetachAndGeometryCommit() throws {
        let fields: [String: Any] = ["id": "owner", "text": "AB", "x": 20, "y": 20,
            "width": 60, "height": 60, "fontSize": 8, "lineHeight": 10,
            "sourceFrame": [0, 0, 100, 100], "sourceBounds": [0.3, 0.3, 0.2, 0.2],
            "sourceTextOnly": false, "wrappingScript": "korean"]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontSize: 8, foreground: NativeTranslationRenderer.color([0, 0, 0]), lineHeight: 10)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourcePanels: [.init(rect: item.rect, background: [154, 172, 191], coverage: [item.rect])],
            drawsPanel: false, background: NativeTranslationRenderer.color([154, 172, 191]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 8)
        #expect(!card.sourcePanels[0].overflowClip)
        card.sourcePanels[0].overflowClip = true; card.captionParentPlate = true
        var cards = [card]
        NativeTranslationRenderer.appendTextToRoot(cards: &cards, index: 0)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 100, height: 100),
            sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100), viewport: CGSize(width: 100, height: 100), items: [item])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        NativeTranslationRenderer.polishCaptionPanels(cards: &cards, glossCards: [], gloss: .init(),
            layout: layout, settings: settings, source: nil)
        #expect(!cards[0].captionParentPlate && cards[0].sourcePanels[0].overflowClip)
    }
}
