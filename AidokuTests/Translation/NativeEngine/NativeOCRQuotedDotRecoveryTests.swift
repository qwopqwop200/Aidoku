import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRQuotedDotRecoveryTests {
    private func fixture(dotShift: Int = 0, dotCount: Int = 6, extraSuffix: Bool = false) -> (NativeOCRRGBAFrame, NativeCoreMLRecognitionRegion, NativeCoreMLRecognizedRegion) {
        let width = 90, height = 260
        var bytes = [UInt8](repeating: 100, count: width * height * 4)
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            for row in y..<y+h { for col in x..<x+w {
                let offset = (row * width + col) * 4
                for channel in 0..<4 { bytes[offset + channel] = 255 }
            } }
        }
        fill(18, 15, 36, 3); fill(51, 15, 3, 12)
        fill(29, 35, 24, 26)
        fill(36, 78, 9, 4); fill(32, 85, 17, 19)
        for index in 0..<dotCount { fill(32, 117 + index * 14 + (index == 2 ? dotShift : 0), 5, 5) }
        fill(16, 207, 3, 13); fill(16, 217, 35, 3)
        if extraSuffix { fill(48, 195, 10, 8) }
        let frame = NativeOCRRGBAFrame(width: width, height: height, bytes: bytes)!
        let polygon = [CGPoint(x:10,y:0),CGPoint(x:75,y:0),CGPoint(x:75,y:240),CGPoint(x:10,y:240)]
        let region = NativeCoreMLRecognitionRegion(sourceIndex: 4, polygon: polygon)
        let read = NativeCoreMLRecognizedRegion(sourceIndex:4,polygon:polygon,text:"『あ588』",confidence:0.72)
        return (frame, region, read)
    }
    @Test func measuredCornersDotsAndTwoGlyphsRetainOriginalOwnership() throws {
        let (frame, region, read) = fixture()
        let proposal = try #require(NativeOCRQuotedDotRecovery.proposal(frame:frame,region:region,read:read))
        #expect(proposal.ellipsisCount == 2)
        #expect(proposal.crops[0].polygon != proposal.crops[1].polygon)
        let reads = proposal.crops.map { NativeCoreMLRecognizedRegion(sourceIndex:4,polygon:$0.polygon,text:"あう",confidence:0.99) }
        let result = try #require(NativeOCRQuotedDotRecovery.accepted(proposal:proposal,reads:reads))
        #expect(result.text == "「あう……」")
        #expect(result.polygon == region.polygon)
        #expect(result.sourceIndex == region.sourceIndex)
        let wrong = NativeCoreMLRecognizedRegion(sourceIndex:4,polygon:reads[1].polygon,text:"あ5",confidence:0.999)
        #expect(NativeOCRQuotedDotRecovery.accepted(proposal:proposal,reads:[reads[0],wrong]) == nil)
        let low = NativeCoreMLRecognizedRegion(sourceIndex:4,polygon:reads[1].polygon,text:"あう",confidence:0.94)
        #expect(NativeOCRQuotedDotRecovery.accepted(proposal:proposal,reads:[reads[0],low]) == nil)
        let digits = reads.map { NativeCoreMLRecognizedRegion(sourceIndex:4,polygon:$0.polygon,text:"12",confidence:0.999) }
        #expect(NativeOCRQuotedDotRecovery.accepted(proposal:proposal,reads:digits) == nil)
    }
    @Test func uncertainDotCountsPitchOrSuffixInkDoNotRecover() {
        for fixture in [fixture(dotShift:4),fixture(dotCount:5),fixture(extraSuffix:true)] {
            #expect(NativeOCRQuotedDotRecovery.proposal(frame:fixture.0,region:fixture.1,read:fixture.2) == nil)
        }
    }
    @Test func numberedLabelsRubySFXAndCorrectQuotesDoNotEnterRecovery() {
        let (_, region, _) = fixture()
        for text in ["123", "「123」", "あ588", "『あまり』", "「3年」", "あう", "English Series", "「あう……」"] {
            let read = NativeCoreMLRecognizedRegion(sourceIndex:4,polygon:region.polygon,text:text,confidence:0.7)
            #expect(!NativeOCRQuotedDotRecovery.eligible(read))
        }
        let frame = NativeOCRRGBAFrame(width:90,height:260,bytes:[UInt8](repeating:255,count:90*260*4))!
        let wrong = NativeCoreMLRecognizedRegion(sourceIndex:4,polygon:region.polygon,text:"『あ588』",confidence:0.72)
        #expect(NativeOCRQuotedDotRecovery.proposal(frame:frame,region:region,read:wrong) == nil)
    }
}
