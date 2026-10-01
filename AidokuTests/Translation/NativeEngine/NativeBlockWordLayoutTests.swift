import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeBlockWordLayoutTests {
    private func item(text: String, width: CGFloat, font: CGFloat, padding: CGFloat = 0,
                      clips: Bool = false) throws -> NativeTranslationLayoutItem {
        let fields: [String: Any] = ["id": "fixed-rows", "text": text.replacingOccurrences(of: "\n", with: " "),
            "typesettingText": text, "typesettingQuoteMode": 0, "fontScript": "korean",
            "sourceBounds": [0, 0, 1, 1], "sourceFrame": [0, 0, width, 100],
            "x": 0, "y": 0, "width": width, "height": 100, "fontSize": font, "lineHeight": font * 1.2,
            "paddingTop": padding, "paddingRight": padding, "paddingBottom": padding, "paddingLeft": padding,
            "clipsText": clips]
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
    }
    private func shape(_ item: NativeTranslationLayoutItem, fixedRows: Bool) -> NativeTranslationTypography.Layout {
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: item.fontSize,
            lineHeight: item.lineHeight, optimizesKoreanWrapping: false, usesBlockWordLayout: fixedRows)
        return NativeTranslationTypography.layout(text: item.typesettingText ?? item.text,
            in: item.contentRect.size, style: style)
    }

    @Test func preservedWordRowsRejectCellsThatOnlyFitAfterRewrapping() throws {
        let candidate = try item(text: "안녕\n세상\n함께", width: 10.234375, font: 7)
        let preserved = shape(candidate, fixedRows: true), ordinary = shape(candidate, fixedRows: false)
        #expect(preserved.lineCount == 3 && ordinary.lineCount == 6)
        #expect(preserved.visibleUTF16Range.length == candidate.typesettingText?.utf16.count)
        #expect(!NativeTypographyPostPolish.contentFits(item: candidate, typography: preserved))
        let wider = try item(text: "안녕\n세상\n함께", width: 20, font: 7)
        #expect(NativeTypographyPostPolish.contentFits(item: wider, typography: shape(wider, fixedRows: true)))
    }

    @Test func scrollFitUsesTrackedAdvancesAndIntegerDimensions() throws {
        // Captured WK: used width83.5, text advance84.34575, scroll/client84.
        let candidate = try item(text: "달칵!", width: 83.5, font: 42.75)
        let shaped = shape(candidate, fixedRows: true)
        let metrics = try #require(NativeTypographyPostPolish.contentFitMetrics(item: candidate, typography: shaped))
        #expect(metrics.clientWidth == 84 && metrics.scrollWidth == 84)
        #expect(!shaped.fits && NativeTypographyPostPolish.contentFits(item: candidate, typography: shaped))
    }

    @Test func clippedSpanOverflowDoesNotInventTrailingHorizontalPadding() throws {
        // Captured WK: width46,padding3,nowrap text84.34575 -> scroll87.
        let candidate = try item(text: "달칵!", width: 46, font: 42.75, padding: 3, clips: true)
        let metrics = try #require(NativeTypographyPostPolish.contentFitMetrics(item: candidate,
            typography: shape(candidate, fixedRows: true)))
        #expect(metrics.clientWidth == 46 && metrics.scrollWidth == 87)
        #expect(!metrics.fits)
    }

    @Test(arguments: [[83.1, 1.0], [80.0, 0.0]])
    func packingPreservesItsOwnOnePixelScrollAllowance(_ values: [Double]) throws {
        // Actual WK client/scroll dimensions are 83/84 and 80/84. The packing
        // old-position gate allows one pixel; ordinary content fitting does not.
        let candidate = try item(text: "달칵!", width: CGFloat(values[0]), font: 42.75)
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: candidate.fontSize,
            lineHeight: candidate.lineHeight, optimizesKoreanWrapping: false, usesBlockWordLayout: true)
        let card = NativeTranslationRenderer.Card(item: candidate, typography: shape(candidate, fixedRows: true),
            style: style, drawsPanel: false, background: NativeTranslationRenderer.color([255, 255, 255]),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: candidate.fontSize)
        #expect(!NativeTranslationRenderer.cardContentFits(card))
        #expect(NativeTranslationRenderer.cardScrollFits(card, allowance: 1) == (values[1] == 1))
    }
}
