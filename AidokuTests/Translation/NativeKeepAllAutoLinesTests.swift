import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeKeepAllAutoLinesTests {
    private func width(text:String,font:CGFloat,tracking:CGFloat) -> (NSRange)->CGFloat {
        let source=text as NSString,face=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,font,nil)
        return { range in
            let attributed=NSAttributedString(string:source.substring(with:range),attributes:[
                NSAttributedString.Key(kCTFontAttributeName as String):face,
                NSAttributedString.Key(kCTKernAttributeName as String):tracking])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed),nil,nil,nil))
        }
    }
    private func greedy(text:String,font:CGFloat,available:CGFloat) -> [NSRange]? {
        let source=text as NSString,measure=width(text:text,font:font,tracking:-font*0.012)
        return NativeKeepAllAutoLines.greedy(text:text,maximumWidth:available,width:measure,
            emergencyBreak:{ range,available in
                var end=range.location,chosen=0
                while end<NSMaxRange(range) {
                    end=NSMaxRange(source.rangeOfComposedCharacterSequence(at:end))
                    if measure(NSRange(location:range.location,length:end-range.location))>available { break }
                    chosen=end-range.location
                }
                return chosen
            })
    }
    @Test(arguments:[CGFloat(7.25),CGFloat(8.75)])
    func nextLongWordMovesBeforeEmergencyFitting(font:CGFloat) throws {
        // Actual real7/ID16: keep-all with anywhere moves the second word to
        // the next row before fitting its emergency prefix, despite spare
        // space on the first row. Literal fragments, not bounding-box unions.
        let text="부, 부탁드립니다♡"
        let ranges=try #require(greedy(text:text,font:font,available:30.015625))
        #expect(ranges==[NSRange(location:0,length:3),NSRange(location:3,length:4),NSRange(location:7,length:3)])
        #expect(ranges.map{(text as NSString).substring(with:$0)}==["부, ","부탁드립","니다♡"])
    }
    @Test func regularWordsRemainIntactUntilOnlyTheLongLastTokenNeedsEmergencyWrapping() throws {
        let text="다음은 리제 씨의 처녀막 제거를 진행하겠습니다"
        let ranges=try #require(greedy(text:text,font:8.75,available:45.78125))
        #expect(ranges==[NSRange(location:0,length:7),NSRange(location:7,length:7),NSRange(location:14,length:4),
            NSRange(location:18,length:6),NSRange(location:24,length:1)])
        #expect(ranges.map{(text as NSString).substring(with:$0)}==["다음은 리제 ","씨의 처녀막 ","제거를 ","진행하겠습니","다"])
    }
    @Test func balancedPipelineUsesTheActualOrdinaryBaseline() throws {
        let text="부... 부탁드립니다……",font:CGFloat=9.25,measure=width(text:text,font:font,tracking:-font*0.012)
        let auto=try #require(greedy(text:text,font:font,available:32.125))
        #expect(auto==[NSRange(location:0,length:5),NSRange(location:5,length:4),NSRange(location:9,length:4)])
        // The long second token has no regular fit, so balance retains this
        // source-greedy layout instead of CT's previous partial-line fill.
        let balanced=NativeKeepAllTextBalance.solve(text:text,originalAutoRanges:auto,maximumWidth:32.125,
            itemWidth:{Float(measure($0))})
        #expect(balanced==nil)
    }

    @Test(arguments: [CGFloat(0), CGFloat(1.0 / 128), CGFloat(1.0 / 64), CGFloat(1.0 / 32)])
    func layoutUnitAllowanceDoesNotHideRealOverflow(excess: CGFloat) throws {
        let text = "가나", width: CGFloat = 40
        let ranges = try #require(NativeKeepAllAutoLines.greedy(text: text, maximumWidth: width,
            width: { range in range.length == 2 ? width + excess : width / 2 },
            emergencyBreak: { _, _ in 1 }))
        if excess <= 1.0 / 64 {
            #expect(ranges == [NSRange(location: 0, length: 2)])
        } else {
            #expect(ranges == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)])
        }
    }

    @Test func subLayoutUnitWordExcessRetainsTheObservedCaptionRows() throws {
        // Actual frozen Web page1 region5: 41.583740px word in a 41.578125px
        // used content box. Its sub-layout-unit excess is not an emergency break.
        let text = "세계는 다시 돌아온 것이다……"
        let ranges = try #require(greedy(text: text, font: 9.75, available: 41.578125))
        let rows = ranges.map { (text as NSString).substring(with: $0) }
        #expect(rows == ["세계는 ", "다시 ", "돌아온 ", "것이다……"])
    }
}
