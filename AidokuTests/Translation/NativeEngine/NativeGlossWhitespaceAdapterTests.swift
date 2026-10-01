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
}
