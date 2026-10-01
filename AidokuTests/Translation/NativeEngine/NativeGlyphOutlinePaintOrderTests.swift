import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor struct NativeGlyphOutlinePaintOrderTests {
    typealias Order = NativeTranslationTypography.OutlinePaintOrder
    private let fill = NativeTranslationRenderer.color([188, 80, 121])
    private let outline = NativeTranslationRenderer.color([230, 239, 243])

    private func pixels(size: CGSize, paint: (CGContext) -> Void) throws -> (bytes: [UInt8], width: Int) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            paint(renderer.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return (bytes, cgImage.width)
    }

    private func fillPixels(_ bytes: [UInt8]) -> Int {
        var count: Int = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let red: Int = Int(bytes[index])
            let green: Int = Int(bytes[index + 1])
            let blue: Int = Int(bytes[index + 2])
            let matchesRed: Bool = abs(red - 188) <= 3
            let matchesGreen: Bool = abs(green - 80) <= 3
            let matchesBlue: Bool = abs(blue - 121) <= 3
            if matchesRed && matchesGreen && matchesBlue { count += 1 }
        }
        return count
    }

    private func maximumInteriorWidth(_ bitmap: (bytes: [UInt8], width: Int)) -> Int {
        let rowBytes = bitmap.width * 4
        var widest: Int = 0
        for start in stride(from: 0, to: bitmap.bytes.count, by: rowBytes) {
            let row = Array(bitmap.bytes[start..<(start + rowBytes)])
            widest = max(widest, fillPixels(row))
        }
        return widest
    }

    @Test func standaloneStrokeFirstDefaultRetainsInteriorWhileNormalPaintNarrowsIt() throws {
        let style = NativeTranslationTypography.Style(fontName: "Helvetica-Bold", fontSize: 64,
            foreground: fill, outline: outline, outlineWidth: 6, tracking: 0, lineHeight: 80)
        #expect(style.outlinePaintOrder == .strokeThenFill)
        let size = CGSize(width: 120, height: 100)
        let layout = NativeTranslationTypography.layout(text: "H", in: size, style: style)
        let original = try pixels(size: size) { NativeTranslationTypography.draw(layout: layout, in: $0) }
        let strokeFirst = try pixels(size: size) {
            NativeTranslationTypography.draw(layout: layout, in: $0, outlinePaintOrder: .strokeThenFill)
        }
        let fillFirst = try pixels(size: size) {
            NativeTranslationTypography.draw(layout: layout, in: $0, outlinePaintOrder: .fillThenStroke)
        }
        let defaultUnchanged = original.bytes == strokeFirst.bytes
        #expect(defaultUnchanged)
        #expect(fillPixels(fillFirst.bytes) > 0)
        #expect(fillPixels(fillFirst.bytes) < fillPixels(strokeFirst.bytes))
        // A centered six-point stroke covers three points of each outer edge
        // when it paints last. Compare the actual interior, not the stroke box.
        #expect(maximumInteriorWidth(fillFirst) + 6 < maximumInteriorWidth(strokeFirst))
    }

    private func releasedPageFiveCard(order: Order, certified: Bool = true) throws -> NativeTranslationRenderer.Card {
        // Focused24 page 5, ID4: identical final typography/palette in the frozen
        // Web result, whose late rotated release retains paint-order: normal.
        let descriptor: [String: Any] = ["id": "4", "text": "스위츠", "typesettingText": "스위츠",
            "x": 59.31953125, "y": 261.296875, "width": 74.0953125, "height": 36.09375,
            "fontSize": 30.25, "lineHeight": 36.09912109375, "rotation": -0.13511210106706387,
            "fontScript": "korean", "wrappingScript": "korean", "sourceVertical": true,
            "sourceFontSize": 75.35483140580426, "sourceColorEligible": true,
            "sourceBounds": [0.1025, 0.12752858399296393, 0.2175, 0.3526824978012313],
            "sourceFrame": [0, 94.43125000000003, 430, 611.1374999999999]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 30.25,
            foreground: fill, outlinePaintOrder: order, tracking: 0, lineHeight: 36.09912109375,
            optimizesKoreanWrapping: false, horizontalScale: 0.9)
        var cards = [NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style),
            style: style, sourcePanels: [.init(rect: item.rect, background: [230, 239, 243], coverage: [item.rect])],
            drawsPanel: false, background: outline, usesFallbackVeil: false, lightSurface: true,
            heavyStrokeWidth: 0, finalFontSize: 30.25)]
        cards[0].rotatesSourcePanels = true
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let patch = try #require(context.makeImage())
        var restoration = NativeTranslationRestoration.Result()
        restoration.patches = [.init(image: patch, rect: item.rect, itemID: item.id)]
        restoration.appearances[item.id] = .init(foreground: fill, background: outline,
            restored: certified, erasureComplete: certified, sourceSample: ["background": [230.0, 239.0, 243.0]],
            sourceGlyphsVerified: certified)
        let frame = CGRect(x: 0, y: 0, width: 430, height: 800)
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true; settings.inpaintingEnabled = true
        NativeTranslationRenderer.releaseCertifiedPlates(cards: &cards, restoration: restoration,
            gloss: .init(), layout: layout, settings: settings)
        #expect(cards[0].glyphPlateReleased == certified)
        #expect(cards[0].style.outlinePaintOrder == order)
        #expect(cards[0].finalFontSize == 30.25)
        #expect(cards[0].item.rect == item.rect)
        #expect(cards[0].style.horizontalScale == 0.9)
        if certified {
            #expect(cards[0].sourcePanels.isEmpty)
            #expect(abs(cards[0].style.outlineWidth - 1.36125) < 1e-12)
        } else {
            #expect(cards[0].sourcePanels.count == 1)
            #expect(cards[0].style.outline == nil && cards[0].style.outlineWidth == 0)
        }
        return cards[0]
    }

    private func paintedCard(_ card: NativeTranslationRenderer.Card) throws -> [UInt8] {
        try pixels(size: CGSize(width: 120, height: 80)) { context in
            context.translateBy(x: -40, y: -240)
            NativeTranslationRenderer.draw(card, context: context, opacity: 1,
                paintsBackground: false, paintsSourcePanels: false)
        }.bytes
    }

    @Test func realSlantedCaptionRetainsNormalPaintAfterCertifiedPlateRelease() throws {
        let normal = try releasedPageFiveCard(order: .fillThenStroke)
        let explicitStrokeFirst = try releasedPageFiveCard(order: .strokeThenFill)
        let normalPixels = try paintedCard(normal)
        let strokeFirstPixels = try paintedCard(explicitStrokeFirst)
        #expect(fillPixels(normalPixels) > 0)
        #expect(fillPixels(normalPixels) < fillPixels(strokeFirstPixels))
        // Actual draw(card:) must transport its style to the painter; merely
        // storing the enum while using the painter's default fails this gate.
        let differsFromEarlierUnconditionalStrokeFirst = normalPixels != strokeFirstPixels
        #expect(differsFromEarlierUnconditionalStrokeFirst)
    }

    @Test(arguments: [Order.fillThenStroke, .strokeThenFill])
    func unverifiedPlateDoesNotCreateAnOutlineOrChangeInheritedOrder(order: Order) throws {
        _ = try releasedPageFiveCard(order: order, certified: false)
    }
}
