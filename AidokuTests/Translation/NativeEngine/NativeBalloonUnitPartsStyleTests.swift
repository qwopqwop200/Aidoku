import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeBalloonUnitPartsStyleTests {
    @Test(arguments: [false,true])
    func newDivInheritsWhitespaceButReplacesWrappingAndSpanModes(normal: Bool) {
        let parent = NativeTranslationTypography.Style(fontName:"Helvetica",fontScript:"word",fontSize:8,
            tracking:-0.08,lineHeight:10,horizontalScale:0.9,balancesHorizontalLines:true,
            keepsWholeWords:true,horizontalWrapping:.keepAllWithEmergency,
            horizontalWhitespace:normal ? .normal : .preWrap,usesBlockWordLayout:true,
            usesPreformattedBlockRows:true,blockWordLayoutUsesTopPadding:true)
        let child = NativeTranslationRenderer.unitPartTypographyStyle(parent:parent,font:10,pitch:12)
        #expect(child.horizontalWhitespace == parent.horizontalWhitespace)
        #expect(child.horizontalWrapping == .keepAll && !child.keepsWholeWords)
        #expect(!child.usesBlockWordLayout && !child.usesPreformattedBlockRows)
        #expect(!child.blockWordLayoutUsesTopPadding)
        #expect(child.balancesHorizontalLines && child.horizontalScale == 0.9)
        #expect(child.fontSize == 10 && child.lineHeight == 12 && child.tracking == -0.1)
    }

    @Test func firstPartTrailingSpaceFollowsInheritedWhitespace() throws {
        let parent = NativeTranslationTypography.Style(fontName:"Helvetica",fontScript:"word",fontSize:10,
            tracking:0,lineHeight:12,horizontalWrapping:.keepAllWithEmergency)
        var pre = NativeTranslationRenderer.unitPartTypographyStyle(parent:parent,font:10,pitch:12)
        pre.horizontalWhitespace = .preWrap
        var normal = pre; normal.horizontalWhitespace = .normal
        // Frozen11019 gives the first part a trailing space. Its new DIV
        // inherits pre-wrap or normal independently of keep-all/overflow-normal.
        let available = CGSize(width:100,height:40), text = "AB  "
        let kept = NativeTranslationTypography.layout(text:text,in:available,style:pre)
        let collapsed = NativeTranslationTypography.layout(text:text,in:available,style:normal)
        let keptRange = try #require(NativeTranslationTypography.wholeRangeBounds(layout:kept,style:pre,available:available))
        let collapsedRange = try #require(NativeTranslationTypography.wholeRangeBounds(layout:collapsed,style:normal,available:available))
        #expect(kept.lineCount == 1 && collapsed.lineCount == 1)
        #expect(keptRange.width > collapsedRange.width)
        #expect(kept.shapedText.hasSuffix("  "))
        #expect(!collapsed.shapedText.hasSuffix(" "))
    }
}
