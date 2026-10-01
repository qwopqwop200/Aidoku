import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite struct NativeSourceFrameLinesTests {
    @Test(arguments: [0.0, 10.0])
    func actualRendererRestoresCrossingRuleBelowGlyphsAndKeepsProvenance(_ cleanupOffsetY: Double) throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let cleanupFrame = frame.offsetBy(dx: 0, dy: cleanupOffsetY)
        let panel = CGRect(x: 25, y: 20 + cleanupOffsetY, width: 40, height: 35)
        let descriptor: [String: Any] = ["id": "frame", "text": "A", "x": 25, "y": 20 + cleanupOffsetY, "width": 40, "height": 35,
            "fontSize": 10, "lineHeight": 12, "sourceBounds": [0.3,0.3,0.3,0.3], "sourceFrame": [0,0,100,80]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "", fontSize: 10,
            foreground: NativeTranslationRenderer.color([20,20,20]), lineHeight: 12)
        let typography = NativeTranslationTypography.layout(text: "A", in: item.contentRect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            sourcePanels: [.init(rect: panel, background: [245,245,245], coverage: [panel])], drawsPanel: false,
            background: NativeTranslationRenderer.color([245,245,245]), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 10)
        card.cleanupSourceFrame = cleanupFrame
        var pixels = NativeRestorationPixels(width: 100, height: 80)
        for y in 0..<80 { for x in 0..<100 {
            let at = (y * 100 + x) * 4, value: UInt8 = y == 31 ? 20 : 245
            pixels.rgba[at] = value; pixels.rgba[at + 1] = value; pixels.rgba[at + 2] = value; pixels.rgba[at + 3] = 255
        } }
        let image = try #require(pixels.image())
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceColors = true
        var cards = [card]
        try NativeTranslationRenderer.restoreSourceFrameLines(cards: &cards, gloss: .init(), layout: layout, source: image, settings: settings)
        let layer = try #require(cards[0].sourcePanels[0].sourceFrameImage)
        #expect(cards[0].sourcePanels[0].sourceFrameLineCount > 0)
        #expect(layer.width == 40 && layer.height == 35)
        let raw = try #require(layer.dataProvider?.data) as Data
        #expect(raw[(11 * 40 + 1) * 4] == 20 && raw[(11 * 40 + 1) * 4 + 3] == 255)
        #expect(raw[3] == 0)
        cards[0].foreignFills = [.init(rect: panel, color: [220,40,40])]
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let painted = UIGraphicsImageRenderer(size: frame.size, format: format).image { context in
            NativeTranslationRenderer.draw(cards[0], context: context.cgContext, opacity: 1,
                paintsBackground: false, paintsText: false, paintsSourcePanels: true)
        }
        let paintedPixels = try #require(painted.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        let rule = (31 + Int(cleanupOffsetY)) * paintedPixels.bytesPerRow + 26 * 4
        let fill = (28 + Int(cleanupOffsetY)) * paintedPixels.bytesPerRow + 26 * 4
        #expect(Array(paintedPixels.bytes[rule..<(rule + 4)]) == [20,20,20,255])
        #expect(Array(paintedPixels.bytes[fill..<(fill + 4)]) == [220,40,40,255])
        #expect(paintedPixels.bytes[3] == 0)
        #expect(cards[0].item.sourceFrame == [0, 0, 100, 80] && layout.sourceRect == frame)
        var rotated = [card]; rotated[0].rotatesSourcePanels = true
        try NativeTranslationRenderer.restoreSourceFrameLines(cards: &rotated, gloss: .init(), layout: layout, source: image, settings: settings)
        #expect(rotated[0].sourcePanels[0].sourceFrameImage == nil)
    }

    @Test func oneSidedContourCannotBecomeAFrameAndBudgetIsShared() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80), panel = CGRect(x: 25, y: 20, width: 40, height: 35)
        let source = CGRect(x: 30, y: 24, width: 30, height: 24)
        var budget = 3_000
        guard let crop = NativeSourceFrameLines.crop(panel: panel, source: source, frame: frame, imageSize: frame.size, budget: &budget) else {
            Issue.record("Expected first crop"); return
        }
        #expect(budget == 144)
        #expect(NativeSourceFrameLines.crop(panel: panel, source: source, frame: frame, imageSize: frame.size, budget: &budget) == nil)
        var rgba = [UInt8](repeating: 245, count: crop.width * crop.height * 4)
        for y in 0..<crop.height { for x in 0..<crop.width {
            let at = (y * crop.width + x) * 4
            rgba[at + 3] = 255
            if y == 19 && x > 20 { for channel in 0..<3 { rgba[at + channel] = 20 } }
        } }
        #expect(NativeSourceFrameLines.restore(crop: crop, rgba: rgba, panel: panel, source: source, textBoxes: []) == nil)
    }
}
