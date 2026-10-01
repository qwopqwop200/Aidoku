import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePlateGrowthScrollTests {
    private func card(text: String = "달칵!", width: CGFloat = 83.5, font: CGFloat = 42.75, scale: CGFloat = 1,
                      vertical: Bool = false, staleFont: CGFloat? = nil) throws -> NativeTranslationRenderer.Card {
        let fields: [String: Any] = ["id": "scroll-probe", "text": text, "typesettingText": text,
            "typesettingQuoteMode": 0, "fontScript": "korean", "wrappingScript": "korean",
            "sourceBounds": [0.0,0.0,0.5,0.5], "sourceFrame": [0,0,200,200],
            "x": 0, "y": 0, "width": width, "height": 100, "fontSize": staleFont ?? font,
            "lineHeight": (staleFont ?? font) * 1.2, "vertical": vertical]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
            vertical: vertical, lineHeight: font * 1.2,
            optimizesKoreanWrapping: false, horizontalScale: scale, usesBlockWordLayout: true)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        return NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            drawsPanel: false, background: NativeTranslationRenderer.color([255,255,255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
    }

    @Test func actualCardAcceptsIntegerScrollFitWhenGlyphInkOverflows() throws {
        // Same font/text/cell as the captured frozen WK contentFits probe:
        // width83.5, advance84.34575, integer scroll/client84.
        let card = try card()
        #expect(!card.typography.fits)
        let metrics = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(card))
        #expect(metrics.usesCSSLayout && metrics.clientWidth == 84 && metrics.scrollWidth == 84)
        #expect(metrics.fits)
        #expect(metrics.scrollWidth <= metrics.clientWidth + 0.5)
    }

    @Test func actualCardUsesCandidateStyleInsteadOfStaleItemFont() throws {
        let current = try card(), stale = try card(staleFont: 7)
        let expected = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(current))
        let actual = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(stale))
        #expect(actual.clientWidth == expected.clientWidth && actual.scrollWidth == expected.scrollWidth)
        #expect(actual.clientHeight == expected.clientHeight && actual.scrollHeight == expected.scrollHeight)
    }

    @Test func actualCondensedCardReportsUnscaledCSSClientWidth() throws {
        let physical = try card(width: 84 * 0.9, scale: 0.9)
        let metrics = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(physical))
        #expect(metrics.usesCSSLayout && metrics.clientWidth == 84)
        #expect(metrics.clientWidth != Double(physical.item.width))
    }

    @Test func verticalFallbackIsExplicitAndInvalidHorizontalScaleRejects() throws {
        let vertical = try card(vertical: true)
        let metrics = try #require(NativeTranslationRenderer.plateGrowthScrollMetrics(vertical))
        if let shared = NativeTypographyPostPolish.contentFitMetrics(item: vertical.item, typography: vertical.typography) {
            #expect(metrics.usesCSSLayout && metrics.clientWidth == Double(shared.clientWidth))
            #expect(metrics.scrollHeight == Double(shared.scrollHeight))
        } else {
            #expect(!metrics.usesCSSLayout && metrics.clientWidth == Double(vertical.item.width))
        }
        var invalid = try card()
        invalid.style.horizontalScale = 0
        #expect(NativeTranslationRenderer.plateGrowthScrollMetrics(invalid) == nil)
    }
    @Test func rawPlateProbeClearsStoredBlockStyleAndActuallyWraps() throws {
        var probe = try card(text: "안녕 세상 함께", width: 30, font: 14)
        probe.item.typesettingText = "안녕\n세상\n함께"
        probe.item.typesettingQuoteMode = 0
        probe.style.usesBlockWordLayout = true
        NativeTranslationRenderer.preparePlateGrowthText(item:&probe.item,style:&probe.style,
                                                         preservingControlledChildren:false)
        probe.typography = NativeTranslationRenderer.remeasureTypography(probe)
        #expect(probe.item.typesettingText == nil && probe.item.typesettingQuoteMode == nil)
        #expect(!probe.style.usesBlockWordLayout && probe.typography.lineCount > 1)
        #expect(probe.typography.visibleUTF16Range.length == probe.item.text.utf16.count)
    }

    @Test func roomProbePreservesOnlyChildrenWithIdenticalConcatenatedText() throws {
        var probe = try card(text: "안녕 세상 함께", width: 50,font: 14)
        probe.item.typesettingText = "안녕 \n세상 \n함께"
        probe.style.usesBlockWordLayout = true
        NativeTranslationRenderer.preparePlateGrowthText(item:&probe.item,style:&probe.style,
                                                         preservingControlledChildren:true)
        #expect(probe.style.usesBlockWordLayout && probe.item.typesettingText != nil)
        probe.typography = NativeTranslationRenderer.remeasureTypography(probe)
        #expect(probe.typography.lineCount == 3)
        probe.item.typesettingText = "다른\n문구"
        NativeTranslationRenderer.preparePlateGrowthText(item:&probe.item,style:&probe.style,
                                                         preservingControlledChildren:true)
        #expect(!probe.style.usesBlockWordLayout && probe.item.typesettingText == nil)
    }

}
