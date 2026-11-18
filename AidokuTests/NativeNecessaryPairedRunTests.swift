import CoreText
import CoreGraphics
import Foundation
import Testing
@testable import Aidoku
@Suite(.serialized)
struct NativeNecessaryPairedRunTests {
    private func layout(_ text:String,_ width:CGFloat)throws->NativeWholeWordWrap.Result {
        let font=CTFontCreateWithName("AppleSDGothicNeo-Regular"as CFString,19.838671875,nil)
        return try NativeWholeWordWrap.layout(text:text,font:font,size:19.838671875,width:width,necessaryCJK:true)
    }
    @Test func necessaryHomogeneousRunRetainsEveryOriginalUTF16Unit() throws {
        let text=String(repeating:"…",count:5),r=try layout(text,51.94653125)
        #expect(r.rows.map(\.ownedRange)==[NSRange(location:0,length:3),NSRange(location:3,length:2)])
        #expect(r.text==text && r.completeOwnership && r.unresolvedGlyphRanges.isEmpty)
        #expect(r.requiredWidth<=51.94653125+0.01 && r.requestedFontSize==19.838671875 && r.appliedTracking==0)
    }
    @Test func wideHomogeneousRunRemainsOneRow() throws {
        let r=try layout(String(repeating:"…",count:5),200)
        #expect(r.rows.map(\.ownedRange)==[NSRange(location:0,length:5)])
    }
    @Test func unrelatedTextAndExtendedGraphemesDoNotAcquireNecessaryBreaks() throws {
        for text in ["!!!!!","ABCDE","“……”","…\u{0301}…\u{0301}…\u{0301}","👨‍👩‍👧‍👦👨‍👩‍👧‍👦"] {
            let r=try layout(text,51.94653125)
            #expect(r.text==text && r.completeOwnership)
            var boundaries=Set([0]),cursor=0
            for c in text {cursor+=String(c).utf16.count;boundaries.insert(cursor)}
            #expect(r.rows.allSatisfy {boundaries.contains($0.ownedRange.location)&&boundaries.contains(NSMaxRange($0.ownedRange))})
        }
    }
    @Test func explicitNewlineIsOwnedWithoutChangingSource() throws {
        let text="……\n………",r=try layout(text,51.94653125)
        #expect(r.text==text && r.completeOwnership && r.rows.count==2)
        #expect(r.rows.map(\.ownedRange)==[NSRange(location:0,length:3),NSRange(location:3,length:3)])
    }
}
