import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

/// Source-preserving glossary whitespace and paragraph flow regression.
@Suite struct NativePreLineTextFlowTests {
    @Test func normalizationRetainsSourceOwnershipAndNonbreakingSpaces() throws {
        let actual=NativePreLineTextFlow.normalize("  A\t\tB \r\n  C\u{00A0}D  \n\n")
        #expect(actual.text == "A B\nC\u{00A0}D\n\n")
        #expect(actual.sourceUTF16.map(\.location) == [2,3,5,8,11,12,13,16,17])
        #expect(actual.sourceUTF16[1] == NSRange(location:3,length:2))
        // LF remains a source-owned forced break; DOM CR has no advance.
        #expect(NativePreLineTextFlow.normalize("A\rB").text == "AB")
        #expect(NativePreLineTextFlow.normalize("A\r\nB").text == "A\nB")
    }
    @Test func blankRowsAndOverflowModesMatchCapturedWebKit() throws {
        let font=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,16,nil)
        func width(_ text:String)->CGFloat {
            let attributed=NSMutableAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])
            NativeVisibleControlGlyphs.apply(to:attributed)
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed),nil,nil,nil))
        }
        let blanks=try #require(NativePreLineTextFlow.rows("\n가나다\n\n",width:100,overflowAnywhere:false,measure:width))
        #expect(blanks.map(\.text) == ["","가나다",""])
        let normal=try #require(NativePreLineTextFlow.rows("한줄매우긴제목단어\n둘째 제목",width:50,overflowAnywhere:false,measure:width))
        let anywhere=try #require(NativePreLineTextFlow.rows("한줄매우긴제목단어\n둘째 제목",width:50,overflowAnywhere:true,measure:width))
        #expect(normal.map(\.text) == ["한줄매우긴제목단어","둘째","제목"])
        #expect(anywhere.map(\.text) == ["한줄매","우긴제","목단어","둘째","제목"])
        let nbsp=try #require(NativePreLineTextFlow.rows("\u{00A0}가나다\u{00A0}",width:100,overflowAnywhere:false,measure:width))
        #expect(nbsp.map(\.text) == ["\u{00A0}가나다\u{00A0}"])
        #expect(nbsp[0].sourceUTF16.map(\.location) == [0,1,2,3,4])
        let control=try #require(NativeVisibleControlGlyphs.formFeeds(text:"가나다\u{000C}라마바",font:font).first)
        #expect(control.sourceUTF16 == 3 && control.glyph == 0 && control.advance > 0)
        let ff=try #require(NativePreLineTextFlow.rows("가나다\u{000C}라마바",width:50,overflowAnywhere:true,measure:width))
        #expect(ff.map(\.text) == ["가나다","\u{000C}라마","바"])
        let collapsed=try #require(NativePreLineTextFlow.rows("  A\t\tB \r\n  C\u{00A0}D  \n\n",width:100,
            overflowAnywhere:false,preservesLineBreaks:false,balances:true,measure:width))
        #expect(collapsed.map(\.text) == ["A B C\u{00A0}D"])
        #expect(collapsed[0].sourceUTF16.map(\.location) == [2,3,5,6,11,12,13])
        let balanced=try #require(NativePreLineTextFlow.rows("\n가나다\n\n",width:100,
            overflowAnywhere:false,preservesLineBreaks:true,balances:true,measure:width))
        #expect(balanced.map(\.text) == ["","가나다",""])
    }
}
