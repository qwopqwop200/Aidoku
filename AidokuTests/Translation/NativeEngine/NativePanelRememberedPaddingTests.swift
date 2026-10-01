import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePanelRememberedPaddingTests {
    private var settings: IPhoneOverlaySettings {
        IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
    }

    private func card(_ fields: [String: Any], panel: CGRect,
                      preformatted: Bool = false) throws -> NativeTranslationRenderer.Card {
        var item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        item = NativeTranslationRenderer.usedLayoutItem(item)
        let style = NativeTranslationTypography.Style(fontScript: item.fontScript, fontSize: item.fontSize,
            foreground: NativeTranslationRenderer.color([47,72,121]), tracking: -item.fontSize * 0.012,
            lineHeight: item.lineHeight, optimizesKoreanWrapping: false,
            usesBlockWordLayout: !preformatted, usesPreformattedBlockRows: preformatted,
            blockWordLayoutUsesTopPadding: true)
        let typography = NativeTranslationTypography.layout(text: item.typesettingText ?? item.text,
            in: item.contentRect.size, style: style)
        return .init(item: item, typography: typography, style: style,
            sourcePanels: [.init(rect: panel, background: [241,178,154], coverage: [panel])],
            drawsPanel: false, background: NativeTranslationRenderer.color([241,178,154]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: item.fontSize)
    }

    @Test func realCard8CompactionUsesRememberedPaddingAfterCohortRaisesCSSPadding() throws {
        // BUILD38 real-comic-0001/card8 BEFORE compactOnly. The frozen
        // sourcePanelOriginalFrame is this stage, not captionPacking.beforePanels.
        let old = CGRect(x: 41.46875, y: 367.140625, width: 44.671875, height: 90.015625)
        let frame = CGRect(x: 0, y: 212.35294117647061, width: 390, height: 275.29411764705884)
        let source: [CGFloat] = [0.11403508771929824,0.5732031943212067,0.06704260651629072,0.3052351375332742]
        let fields: [String: Any] = ["id": "8", "text": "3학년이 되기 전에 처녀막 제거식을 하는 건 상식이지만…",
            "typesettingText": "3학년이 \n되기 전에 \n처녀막 \n제거식을 \n하는 건 \n상식이\n지만…",
            "typesettingQuoteMode": 0, "typesettingBlockDisplay": true, "fontScript": "korean",
            "x": 41.717640977443615, "y": 370.1597744360902, "width": 45.75657894736842, "height": 84.06015037593988,
            "fontSize": 8.75, "lineHeight": 10.44189453125,
            "paddingTop": 5.483444328594942, "paddingLeft": 3.44, "paddingRight": 3.44, "paddingBottom": 3.44,
            "sourceBounds": source, "sourceFrame": [0,212.30263157894737,390,275.39473684210526],
            "sourceFontSize": 9.274860321529518, "sourceVertical": true, "sourceColorEligible": true, "sourceTextOnly": false]
        var original = try card(fields, panel: old)
        original.textShift = CGPoint(x: -4.078125, y: 2.03125)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 2380, height: 1680), sourceRect: frame,
            viewport: CGSize(width: 390, height: 700), items: [original.item])
        var restoration = NativeTranslationRestoration.Result()
        restoration.cleanupGeometry = .init(frame: frame, clip: CGRect(x: 0, y: 0, width: 390, height: 700))
        var cards = [original]
        NativeTranslationRenderer.polishPanelGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, phase: .compactOnly, rememberedPadding: ["8": 3])
        // Literal frozen aidokuCompactPanel on the same before-stage inputs:
        // required fringe9.274860321529518 - remembered3, grid64 outward.
        let expected = CGRect(x: 41.46875, y: 367.140625, width: 38.4375, height: 90.015625)
        #expect(cards[0].sourcePanels[0].rect == expected)
        #expect(cards[0].sourcePanels[0].coverage == [expected])
        #expect(cards[0].item.paddingTop == original.item.paddingTop && original.item.paddingTop > 5)
        #expect(cards[0].item.sourceFrame == original.item.sourceFrame)
        #expect(cards[0].typography.shapedText == original.typography.shapedText && cards[0].finalFontSize == 8.75)
        #expect(cards[0].textShift == original.textShift)
        // A caller that transports CSS padding instead of remembered history
        // still yields a measurably wider plate; this is not palette tuning.
        var wrongHistory = [original]
        NativeTranslationRenderer.polishPanelGeometry(cards: &wrongHistory, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, phase: .compactOnly,
            rememberedPadding: ["8": original.item.paddingTop])
        #expect(wrongHistory[0].sourcePanels[0].rect.width > expected.width + 1)
    }

    @Test func actualCompactionKeepsSelectedPreformattedSpanBoxesAndTransportsRememberedPad() throws {
        let old = CGRect(x: 0, y: 0, width: 100, height: 100)
        let fields: [String: Any] = ["id": "spans", "text": "A B", "typesettingText": "A\nB",
            "typesettingPreformattedRows": true, "typesettingBlockDisplay": true, "fontScript": "",
            "x": 20, "y": 20, "width": 30, "height": 60, "fontSize": 8, "lineHeight": 28,
            "paddingTop": 0, "paddingRight": 0, "paddingBottom": 0, "paddingLeft": 0,
            "sourceBounds": [0.3,0.3,0.01,0.01], "sourceFrame": [0,0,100,100],
            "sourceColorEligible": true, "sourceTextOnly": false]
        let original = try card(fields, panel: old, preformatted: true)
        let selected = try #require(NativeTranslationRenderer.cardWholeRangeRect(original))
        let scalars = NativeTranslationRenderer.cardInkRect(original)
        #expect(selected.minY == 20 && selected.maxY == 76)
        #expect(scalars.minY > selected.minY && scalars.maxY < selected.maxY)
        let layout = NativeTranslationLayout(imageSize: old.size, sourceRect: old, viewport: old.size, items: [original.item])
        let restoration = NativeTranslationRestoration.Result(appearances: ["spans": .init(foreground: nil, background: nil, restored: true, erasureComplete: true)])
        var cards = [original]
        NativeTranslationRenderer.polishPanelGeometry(cards: &cards, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, phase: .compactOnly, rememberedPadding: ["spans": 3])
        #expect(cards[0].sourcePanels[0].rect.minY == 17 && cards[0].sourcePanels[0].rect.maxY == 79)
        var wider = [original]
        NativeTranslationRenderer.polishPanelGeometry(cards: &wider, gloss: .init(), layout: layout,
            restoration: restoration, settings: settings, phase: .compactOnly, rememberedPadding: ["spans": 6])
        #expect(wider[0].sourcePanels[0].rect.minY == 14 && wider[0].sourcePanels[0].rect.maxY == 82)
        #expect(wider[0].item.typesettingPreformattedRows == true && wider[0].item.typesettingQuoteMode == nil)
        #expect(wider[0].typography.shapedText == "A\nB")
    }
}
