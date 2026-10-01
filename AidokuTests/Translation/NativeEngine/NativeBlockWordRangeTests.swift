import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeBlockWordRangeTests {
    @Test func nowrapRowsCollapseOnlyCSSAsciiWhitespace() {
        #expect(NativeTranslationTypography.blockWordText("  안녕\t\t 세상!  \n 다\u{00a0}라 \r") == "안녕 세상!\n다\u{00a0}라")
    }

    @Test func collapsedPaintingRetainsSourceWordBreakOffsets() {
        let text = "안녕, 세상! 함께 출발하자."
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 8.75,
            lineHeight: 10.5, optimizesKoreanWrapping: false, usesBlockWordLayout: true)
        let shaped = NativeTranslationTypography.layout(text: "안녕, \n세상! 함께 \n출발하자.",
            in: CGSize(width: 60, height: 100), style: style)
        let profile = NativeTypographyPostPolish.profile(shaped, originalText: text)
        #expect(profile.breaks.isEmpty)
        #expect(NativeTranslationTypography.wordFlow(layout: shaped, originalText: text).wordSplits == 0)
        #expect(shaped.shapedText == "안녕,\n세상! 함께\n출발하자.")
    }

    @Test func fullPreservedWrapperRangeIncludesItsBlockWidth() throws {
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 8.75,
            lineHeight: 10.5, optimizesKoreanWrapping: false, usesBlockWordLayout: true)
        let available = CGSize(width: 23.1328125, height: 150)
        let shaped = NativeTranslationTypography.layout(text: "드디어 \n선생\n님이 \n왔다", in: available, style: style)
        let whole = try #require(NativeTranslationTypography.wholeRangeBounds(layout: shaped,
            style: style, available: available, preservesBlockWrapper: true))
        #expect(whole.minX == 0 && whole.width == 23.125)
        #expect(shaped.lineCount == 4)
        let scalar = shaped.rangeBounds.reduce(CGRect.null) { $0.union($1) }
        #expect(scalar.width < whole.width)
    }

    @Test func blockDisplayUsesRaisedPaddingWithoutSecondFlexCentering() throws {
        let available = CGSize(width: 107, height: 190)
        var style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 28.25,
            lineHeight: 33.71240234375, optimizesKoreanWrapping: false, usesBlockWordLayout: true,
            blockWordLayoutUsesTopPadding: true)
        let block = NativeTranslationTypography.layout(text: "안녕, \n세상! \n함께 \n출발하자.", in: available, style: style)
        style.blockWordLayoutUsesTopPadding = false
        let flex = NativeTranslationTypography.layout(text: block.shapedText, in: available, style: style)
        let topBlock = try #require(block.rangeBounds.first), topFlex = try #require(flex.rangeBounds.first)
        #expect(abs(topFlex.minY - topBlock.minY - (190 - 4 * 33) / 2) < 0.00001)
    }
    @Test(arguments: [false, true])
    func preservedRowsKeepTheirActualParentDisplayOverflow(block: Bool) throws {
        // Actual frozen WK 23.1328125x22 box, four rows at font8.75/pitch10.5:
        // direct block children scroll40; flex full-width wrapper scroll31.
        let fields: [String: Any] = ["id": "display-overflow", "text": "드디어 선생 님이 왔다",
            "typesettingText": "드디어 \n선생\n님이 \n왔다", "typesettingQuoteMode": 0,
            "typesettingBlockDisplay": block, "fontScript": "korean",
            "sourceBounds": [0,0,1,1], "sourceFrame": [0,0,23.1328125,22],
            "x": 0, "y": 0, "width": 23.1328125, "height": 22,
            "fontSize": 8.75, "lineHeight": 10.5,
            "paddingTop": 0, "paddingRight": 0, "paddingBottom": 0, "paddingLeft": 0]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 8.75,
            lineHeight: 10.5, optimizesKoreanWrapping: false, usesBlockWordLayout: true,
            blockWordLayoutUsesTopPadding: block)
        let shape = NativeTranslationTypography.layout(text: item.typesettingText!, in: item.contentRect.size, style: style)
        let metrics = try #require(NativeTypographyPostPolish.contentFitMetrics(item: item, typography: shape))
        #expect(metrics.clientHeight == 22 && metrics.scrollHeight == (block ? 40 : 31))
    }

    @Test(arguments: [false, true])
    func nowrapHorizontalOverflowIsIndependentOfParentDisplay(block: Bool) throws {
        let fields: [String: Any] = ["id": "nowrap-overflow", "text": "달칵!",
            "typesettingText": "달칵!", "typesettingQuoteMode": 0, "typesettingBlockDisplay": block,
            "fontScript": "korean", "sourceBounds": [0,0,1,1], "sourceFrame": [0,0,46,100],
            "x": 0, "y": 0, "width": 46, "height": 100, "fontSize": 42.75, "lineHeight": 51.01611328125,
            "paddingTop": 3, "paddingRight": 3, "paddingBottom": 3, "paddingLeft": 3, "clipsText": true]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: item.fontSize,
            lineHeight: item.lineHeight, optimizesKoreanWrapping: false, usesBlockWordLayout: true,
            blockWordLayoutUsesTopPadding: block)
        let shaped = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        let metrics = try #require(NativeTypographyPostPolish.contentFitMetrics(item: item, typography: shaped))
        #expect(metrics.clientWidth == 46 && metrics.scrollWidth == 87)
    }

    @Test func recreatingWordSpansRemovesSelectedWrapperProvenance() throws {
        let fields: [String: Any] = ["id": "fresh-spans", "text": "안녕 세상",
            "typesettingPreservedBlockWrapper": true, "typesettingBlockDisplay": false,
            "fontScript": "korean", "sourceBounds": [0,0,1,1], "sourceFrame": [0,0,40,100],
            "x": 0, "y": 0, "width": 40, "height": 100, "fontSize": 8.75, "lineHeight": 10.5,
            "paddingTop": 3, "paddingRight": 3, "paddingBottom": 3, "paddingLeft": 3]
        let old = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let fresh = NativeTypographyPostPolish.replacingWithBlockWords(old,
            lines: ["안녕 ", "세상"], quoteMode: 0)
        #expect(fresh.typesettingPreservedBlockWrapper == nil && fresh.typesettingBlockDisplay == true)
        #expect(fresh.paddingTop == 39.5 && fresh.typesettingText == "안녕 \n세상")
    }

    private func policyContext(text: String, rows: String, width: CGFloat) throws -> (NativeTypographyPostPolish.Context, NativeTranslationLayoutItem) {
        let fields: [String: Any] = ["id": "cohort-children", "text": text,
            "typesettingText": rows, "typesettingQuoteMode": 0, "typesettingBlockDisplay": true,
            "captionFixedBoxReflowDisabled": false, "fontScript": "korean", "wrappingScript": "korean",
            "sourceBounds": [0,0,1,1], "sourceFrame": [0,0,width,100],
            "x": 0, "y": 0, "width": width, "height": 100, "fontSize": 8.75, "lineHeight": 10.5,
            "paddingTop": 3, "paddingRight": 0, "paddingBottom": 0, "paddingLeft": 0]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let layout = NativeTranslationLayout(imageSize: CGSize(width: width, height: 100),
            sourceRect: CGRect(x: 0,y: 0,width: width,height: 100), viewport: CGSize(width: width,height: 100), items: [item])
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        return (NativeTypographyPostPolish.rendererGrowthSession(layout: layout,
            restoration: .init(), settings: settings, sourceImage: nil).context, item)
    }

    @Test func cohortFontProbePreservesChildrenWithoutInventingWordAwareMarker() throws {
        let (context, item) = try policyContext(text: "안녕 세상 함께", rows: "안녕 \n세상 \n함께", width: 100)
        // Wider than8em: wordLines() is unavailable, so a successful font probe
        // retains cloned children without becoming a fresh word-aware producer.
        let accepted = context.cohort(item, target: 9, others: [])
        #expect(accepted.fontSize == 9 && accepted.typesettingText == item.typesettingText)
        #expect(accepted.captionFixedBoxReflowDisabled == false)
    }

    @Test func repairProcessesRecoveryChildrenThatHaveNoWordAwareMarker() throws {
        let (context, item) = try policyContext(text: "드디어 선생님이 왔다", rows: "드디어 \n선생\n님이 \n왔다", width: 40)
        let original = context.candidate(item)
        let accepted = context.repaired(item, others: [])
        #expect(original.profile.breaks.count > 0)
        #expect(accepted.captionFixedBoxReflowDisabled == true)
        #expect(context.candidate(accepted).profile.breaks.count < original.profile.breaks.count)
    }

    @Test func autoHeightUsesLineFlowInsteadOfSuggestedFontExtent() throws {
        let text = "안녕\n세상\n함께\n출발\n가자\n우리\n친구"
        let fields: [String: Any] = ["id": "auto-height", "text": text, "fontScript": "korean",
            "sourceBounds": [0,0,1,1], "sourceFrame": [0,0,26.5625,100],
            "x": 0, "y": 0, "width": 26.5625, "height": 100,
            "fontSize": 8.162790697674419, "lineHeight": 9.741142805232558,
            "paddingTop": 2, "paddingRight": 2, "paddingBottom": 2, "paddingLeft": 2]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: item.fontSize,
            lineHeight: item.lineHeight, optimizesKoreanWrapping: false)
        let shaped = NativeTranslationTypography.layout(text: text, in: item.contentRect.size, style: style)
        #expect(shaped.lineCount == 7)
        #expect(NativeTypographyPostPolish.blockAutoHeight(item: item, typography: shaped) == 67)
    }

}
