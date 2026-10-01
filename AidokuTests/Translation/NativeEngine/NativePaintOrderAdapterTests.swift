import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor struct NativePaintOrderAdapterTests {
    private let frame = CGRect(x: 0, y: 0, width: 200, height: 160)

    private var settings: IPhoneOverlaySettings {
        IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
    }

    private func card(_ id: String, rect: CGRect, text: String, opaque: Bool, top: Bool = false) throws -> NativeTranslationRenderer.Card {
        let descriptor: [String: Any] = ["id": id, "text": text,
            "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
            "fontSize": 12, "lineHeight": 15, "sourceBounds": [0.2, 0.2, 0.1, 0.1], "sourceFrame": [0, 0, 200, 160]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 12,
            foreground: NativeTranslationRenderer.color([0, 0, 0]), lineHeight: 15, alignsToTop: top)
        return NativeTranslationRenderer.Card(item: item,
            typography: NativeTranslationTypography.layout(text: text, in: item.contentRect.size, style: style),
            style: style, drawsPanel: opaque, background: NativeTranslationRenderer.color([255, 255, 255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 12)
    }

    private func layout(_ cards: [NativeTranslationRenderer.Card]) -> NativeTranslationLayout {
        .init(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: cards.map(\.item))
    }

    private func pixels(_ cards: [NativeTranslationRenderer.Card], in rect: CGRect) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: frame.size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(frame)
            NativeTranslationRenderer.drawPaintScene(cards: cards, gloss: .init(), settings: settings,
                context: renderer.cgContext, pixelSnapScale: nil)
        }
        let fullImage = try #require(rendered.cgImage)
        let region = rect.integral.intersection(frame)
        let image = try #require(fullImage.cropping(to: region))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func darkPixels(_ cards: [NativeTranslationRenderer.Card], in rect: CGRect) throws -> Int {
        let bytes = try pixels(cards, in: rect)
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index] < 100 && bytes[index + 1] < 100 && bytes[index + 2] < 100 { count += 1 }
        }
        return count
    }

    @Test func rootLetteringBecomesVisibleWithoutCoveringTheLaterCaptionsGlyphs() throws {
        let free = try card("free", rect: CGRect(x: 40, y: 60, width: 80, height: 30), text: "ABC", opaque: false)
        let covering = try card("cover", rect: CGRect(x: 10, y: 5, width: 160, height: 140), text: "X", opaque: true, top: true)
        var cards = [free, covering]
        let region = NativeTranslationRenderer.cardInkRect(free).insetBy(dx: -1, dy: -1)
        #expect(try darkPixels(cards, in: region) == 0)
        let sceneLayout = layout(cards)
        NativeTranslationRenderer.applyPaintOrderLifts(cards: &cards, gloss: .init(), layout: sceneLayout, settings: settings)
        #expect(cards[0].paintOrderLift != nil && cards[0].paintOrderLift != "blocked")
        #expect(cards[0].textZ == 3 && cards[1].textZ == 2)
        #expect(try darkPixels(cards, in: region) > 0)
        #expect(cards[0].item.rect == free.item.rect && cards[1].item.rect == covering.item.rect)
    }

    @Test func opaqueCaptionCannotLiftItsBackgroundOverExistingLettering() throws {
        let first = try card("first", rect: CGRect(x: 40, y: 50, width: 80, height: 60), text: "ABC", opaque: true)
        let later = try card("later", rect: CGRect(x: 30, y: 30, width: 100, height: 100), text: "X", opaque: true)
        var cards = [first, later]
        let sceneLayout = layout(cards)
        NativeTranslationRenderer.applyPaintOrderLifts(cards: &cards, gloss: .init(), layout: sceneLayout, settings: settings)
        #expect(cards[0].paintOrderLift == "blocked" && cards[0].textZ == 2)
        #expect(cards[1].textZ == 2)
    }

    @Test func lateRootAppendPaintsAfterPreviouslyLiftedTextAtTheSameZ() throws {
        let rect = CGRect(x: 40, y: 60, width: 80, height: 30)
        var late = try card("late", rect: rect, text: "ABC", opaque: false)
        late.style.foreground = NativeTranslationRenderer.color([255, 0, 0])
        late.typography = NativeTranslationTypography.layout(text: late.item.text, in: late.item.contentRect.size, style: late.style)
        late.textZ = 3; late.textRootOrder = 10
        var earlier = try card("earlier", rect: rect, text: "ABC", opaque: false)
        earlier.style.foreground = NativeTranslationRenderer.color([0, 0, 255])
        earlier.typography = NativeTranslationTypography.layout(text: earlier.item.text, in: earlier.item.contentRect.size, style: earlier.style)
        earlier.textZ = 3
        var referenceLate = late
        referenceLate.textRootOrder = nil
        // Appending to the DOM moves the root layer after an existing z=3
        // sibling, independent of the card's original source-array position.
        #expect(try pixels([late, earlier], in: frame) == pixels([earlier, referenceLate], in: frame))
        #expect(try pixels([late, earlier], in: frame) != pixels([referenceLate, earlier], in: frame))
    }

    @Test func releasedOwnerDoesNotRemoveItsIndependentArtworkCover() throws {
        var released = try card("released", rect: CGRect(x: 10, y: 5, width: 50, height: 30), text: "X", opaque: false)
        let region = CGRect(x: 40, y: 60, width: 80, height: 30)
        let bytes: [UInt8] = [0, 0, 0, 255]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        released.glyphCoverPatch = .init(image: image, rect: region)
        released.glyphCoverOwnerPanel = nil
        released.sourcePanels = []
        released.captionParentPlate = false
        released.glyphPlateReleased = true
        // A late release removes the readability owner, while the previously
        // inserted cover canvas remains connected in the original renderer.
        #expect(try darkPixels([released], in: region) == Int(region.width * region.height))
    }

    @Test func genuineParentKeepsItsChildLetteringInTheSamePaintLayer() throws {
        var child = try card("child", rect: CGRect(x: 40, y: 60, width: 80, height: 30), text: "ABC", opaque: false)
        child.captionParentPlate = true; child.sourcePanelZ = 2
        child.sourcePanels = [.init(rect: child.item.rect, background: [220, 240, 255], coverage: [child.item.rect])]
        let covering = try card("cover", rect: CGRect(x: 10, y: 5, width: 160, height: 140), text: "X", opaque: true, top: true)
        var cards = [child, covering]
        let sceneLayout = layout(cards)
        NativeTranslationRenderer.applyPaintOrderLifts(cards: &cards, gloss: .init(), layout: sceneLayout, settings: settings)
        #expect(cards[0].paintOrderLift == nil && cards[0].textZ == 2 && cards[0].sourcePanelZ == 2)
        #expect(try darkPixels(cards, in: NativeTranslationRenderer.cardInkRect(child).insetBy(dx: -1, dy: -1)) > 0)
        #expect(cards[0].sourcePanels[0].rect == child.item.rect)
    }

    @Test func detachedCaptionKeepsItsConnectedOwnersStoredPaintZ() throws {
        let region = CGRect(x: 40, y: 60, width: 80, height: 30)
        var first = try card("first", rect: region, text: "", opaque: false)
        first.sourcePanels = [.init(rect: region, background: [255, 0, 0], coverage: [region])]
        first.sourcePanelZ = 2
        var detached = try card("detached", rect: region, text: "", opaque: false)
        detached.sourcePanels = [.init(rect: region, background: [0, 0, 255], coverage: [region])]
        detached.sourcePanelZ = 2
        var cards = [first, detached]
        #expect(NativeTranslationRenderer.attachCaptionParent(cards: &cards, childIndex: 1, ownerIndex: 1, panelIndex: 0))
        NativeTranslationRenderer.appendTextToRoot(cards: &cards, index: 1)
        #expect(!cards[1].captionParentPlate && cards[1].sourcePanelZ == 2)
        // Root reparenting changes the text layer. The connected owner retains
        // its CSS z=2 and therefore still paints after the preceding red owner.
        let interior = region.insetBy(dx: 3, dy: 3)
        let actual = try pixels(cards, in: interior)
        let expected = try pixels([detached], in: interior)
        #expect(actual == expected)
        var formerOrder = cards
        formerOrder[1].sourcePanelZ = 1
        let formerPixels = try pixels(formerOrder, in: interior)
        #expect(actual != formerPixels)
    }

}
