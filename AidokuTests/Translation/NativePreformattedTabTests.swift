import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

struct NativePreformattedTabTests {
    private func shape(_ text: String) -> (NativeTranslationTypography.Layout,CGRect?) {
        let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:8.75,lineHeight:10.5,
            optimizesKoreanWrapping:false,usesPreformattedBlockRows:true,
            blockWordLayoutUsesTopPadding:true,horizontalAlignment:.left)
        let available=CGSize(width:85,height:150)
        let layout=NativeTranslationTypography.layout(text:text,in:available,style:style)
        return (layout,NativeTranslationTypography.wholeRangeBounds(layout:layout,style:style,available:available))
    }
    @Test func preservedTabsAndNBSPKeepRawTextAndWholeSpanRange() {
        let text="  가\t 나  \n다\u{00a0}라 "
        let (layout,whole)=shape(text)
        #expect(layout.shapedText==text)
        #expect(layout.lineRanges==[NSRange(location:0,length:9),NSRange(location:9,length:4)])
        #expect(whole==CGRect(x:26.3125,y:-1,width:32.359375,height:21))
    }
    @Test func repeatedTabsUseSpaceGridWithoutAccumulatingLetterSpacing() {
        let text="\t\t가", (layout,whole)=shape(text)
        #expect(layout.shapedText==text)
        #expect(layout.lineRanges==[NSRange(location:0,length:3)])
        #expect(whole==CGRect(x:20.40625,y:-1,width:44.1875,height:11))
    }
    @Test func frozenRecognizableTabGapUsesHalfSpaceRatherThanHalfZero() {
        // The first gap is between half-space and half-zero; the second is
        // shorter than half-space. These actual WK cases choose different stops.
        let (first,firstRange)=shape("    가\t나")
        let (second,secondRange)=shape("        \t가")
        #expect(first.shapedText=="    가\t나")
        #expect(second.shapedText=="        \t가")
        #expect(firstRange==CGRect(x:29.609375,y:-1,width:25.78125,height:11))
        #expect(secondRange==CGRect(x:20.40625,y:-1,width:44.1875,height:11))
    }
}
