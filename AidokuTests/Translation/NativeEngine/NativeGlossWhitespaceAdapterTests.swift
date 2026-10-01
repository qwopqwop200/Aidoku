import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeGlossWhitespaceAdapterTests {
    private func card(style: NativeTranslationTypography.Style) throws -> NativeTranslationRenderer.Card {
        let fields: [String: Any] = ["id":"gloss-whitespace","text":"old rows","x":0,"y":0,"width":200,"height":100,
            "fontSize":12,"lineHeight":16,"paddingTop":0,"paddingRight":0,"paddingBottom":0,"paddingLeft":0,
            "sourceBounds":[0,0,1,1],"sourceFrame":[0,0,200,100],"sourceTextOnly":false]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject:fields))
        return .init(item:item, typography:NativeTranslationTypography.layout(text:item.text,in:item.contentRect.size,style:style),
            style:style,drawsPanel:false,background:CGColor(gray:1,alpha:1),usesFallbackVeil:false,lightSurface:true,
            heavyStrokeWidth:0,finalFontSize:12)
    }

    @Test func rawNoteTextPreservesNonbreakingSpacesAndHardBreaks() {
        let text = " A\t B\nC\r\nD\u{00A0}E\u{3000}F "
        #expect(NativeTranslationRenderer.glossText(text,title:true) == text)
        #expect(NativeTranslationRenderer.glossText(text,title:false) == text)
    }

    @Test(arguments:[false,true]) func freshNoteReplacesPriorChildRowsAndUsesItsOwnWhitespace(title:Bool) throws {
        let source = NativeTranslationTypography.Style(fontSize:12,lineHeight:16,balancesHorizontalLines:true,
            horizontalWrapping:.keepAllWithEmergency,usesBlockWordLayout:true,usesPreformattedBlockRows:true,
            blockWordLayoutUsesTopPadding:true,outlineGlow:3)
        let style = NativeTranslationRenderer.glossStyle(card:try card(style:source),size:12,lineHeight:16,title:title)
        #expect(style.horizontalWhitespace == (title ? .preLine : .normal))
        #expect(!style.preservesBlockRows && !style.blockWordLayoutUsesTopPadding && style.koreanQuoteMode == 0)
        #expect(style.balancesHorizontalLines && style.outlineGlow == 0)
        let note = NativeTranslationRenderer.glossText("A   B\nC",title:title)
        let measured = NativeTranslationTypography.layout(text:note,in:CGSize(width:200,height:100),style:style)
        #expect(measured.lineCount == (title ? 2 : 1))
    }

    @Test(arguments:[0,1,2,3,4]) func overflowAdmissionComesFromLiveStyleRatherThanFontScript(mode:Int) throws {
        var source = NativeTranslationTypography.Style(fontScript:"korean",fontSize:12,lineHeight:16)
        source.horizontalWrapping = mode == 0 ? .keepAll : mode == 3 ? .keepAllWithEmergency : .normal
        source.keepsWholeWords = mode == 1; source.strictLineBreak = mode == 2
        let style = NativeTranslationRenderer.glossStyle(card:try card(style:source),size:12,lineHeight:16)
        #expect(style.horizontalWrapping == (mode >= 3 ? .keepAllWithEmergency : .keepAll))
        #expect(!style.keepsWholeWords && style.strictLineBreak == source.strictLineBreak)
    }
    @Test func preservedTitleRetainsCardWhitespacePaddingAndEmTracking() throws {
        let source = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 11.75,
            tracking: -11.75 * 0.012, lineHeight: 14.02197265625,
            optimizesKoreanWrapping: false, alignsToTop: false, balancesHorizontalLines: true,
            horizontalWrapping: .keepAllWithEmergency, horizontalWhitespace: .preWrap)
        let retained = NativeTranslationEffectGloss.RetainedTypography(sourceStyle: source,
            horizontalPadding: 12, verticalPadding: 12)
        let owner = try card(style: source)
        let inherited = NativeTranslationRenderer.glossStyle(card: owner, size: 14, lineHeight: 16.8,
            title: true, retained: retained)
        #expect(inherited.horizontalWhitespace == .preWrap)
        #expect(inherited.horizontalWrapping == .keepAllWithEmergency)
        #expect(!inherited.alignsToTop && inherited.balancesHorizontalLines)
        #expect(abs(inherited.tracking + 0.168) < 0.000001)
        #expect(retained.contentSize(width: 119, lineHeight: 16.8) == CGSize(width: 107, height: 39))
        let fresh = NativeTranslationRenderer.glossStyle(card: owner, size: 14, lineHeight: 16.8, title: true)
        #expect(fresh.horizontalWhitespace == .preLine && fresh.alignsToTop && fresh.tracking == 0)
    }

    @Test func preservedTitleMeasuresRecordedRangeRatherThanGlyphInk() throws {
        // Immutable current-Web page9 title candidate: outer119x51, padding6,
        // range63.224x34. The existing card retains two balanced rows at14pt.
        let source = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 11.75,
            tracking: -11.75 * 0.012, lineHeight: 14.02197265625,
            optimizesKoreanWrapping: false, alignsToTop: false, balancesHorizontalLines: true,
            horizontalWrapping: .keepAllWithEmergency, horizontalWhitespace: .preWrap)
        let retained = NativeTranslationEffectGloss.RetainedTypography(sourceStyle: source,
            horizontalPadding: 12, verticalPadding: 12)
        let style = retained.style(size: 14, lineHeight: 16.8)
        let size = retained.contentSize(width: 119, lineHeight: 16.8)
        let shaped = NativeTranslationTypography.layout(text: "태연하게 대단한 일을", in: size, style: style)
        let range = try #require(NativeTranslationTypography.wholeRangeBounds(layout: shaped, style: style, available: size))
        #expect(shaped.lineCount == 2)
        #expect(abs(range.width - 63.224) < 0.1)
        #expect(abs(range.height - 34) < 0.1)
        #expect(range.height > shaped.inkBounds.height)
        #expect(NativeTypographyPostPolish.profile(shaped, originalText: "태연하게 대단한 일을").breaks.isEmpty)
    }

    @Test func preservedTitleKeepsExplicitPixelTrackingAndGuardsInvalidSourceSize() {
        var source = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 11.75,
            tracking: -0.141, lineHeight: 14.02197265625)
        source.trackingScalesWithFont = false
        let fixed = NativeTranslationEffectGloss.RetainedTypography(sourceStyle: source,
            horizontalPadding: 12, verticalPadding: 12)
        #expect(fixed.style(size: 14, lineHeight: 16.8).tracking == -0.141)
        source.trackingScalesWithFont = true
        source.fontSize = 0
        let invalid = NativeTranslationEffectGloss.RetainedTypography(sourceStyle: source,
            horizontalPadding: 12, verticalPadding: 12)
        #expect(invalid.style(size: 14, lineHeight: 16.8).tracking == -0.141)
    }

}
