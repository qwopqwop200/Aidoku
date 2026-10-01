import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeVerticalContentFitTests {
    @Test func rightToLeftColumnsOverflowLeftAndClippingKeepsLeadingPadding() throws {
        let padding = NativeVerticalContentFit.Padding(top: 3,right: 3,bottom: 3,left: 3)
        func metrics(_ balanced: Bool,_ clips: Bool,pitch: CGFloat = 24) throws -> NativeVerticalContentFit.Metrics {
            try #require(NativeVerticalContentFit.metrics(box: CGSize(width: 20,height: 50),padding: padding,
                columnCount: 4,fontSize: 20,lineHeight: pitch,inlineExtent: 44,alignsToRight: balanced,clips: clips))
        }
        #expect(try metrics(false,false) == .init(clientWidth: 20,clientHeight: 50,scrollWidth: 58,scrollHeight: 50))
        #expect(try metrics(false,false,pitch: 23.9999999).scrollWidth == 58)
        #expect(try metrics(false,true).scrollWidth == 61)
        #expect(try metrics(true,false).scrollWidth == 99)
        #expect(try metrics(true,true).scrollWidth == 102)
    }
    @Test func indivisibleVerticalRunHasDistinctClippedInlineOverflow() throws {
        let padding = NativeVerticalContentFit.Padding(top: 1,right: 2,bottom: 1,left: 2)
        func metrics(_ clips: Bool) throws -> NativeVerticalContentFit.Metrics {
            try #require(NativeVerticalContentFit.metrics(box: CGSize(width: 8.5,height: 15),padding: padding,
                columnCount: 7,fontSize: 20,lineHeight: 24,inlineExtent: 19.765625,alignsToRight: false,clips: clips))
        }
        #expect(try metrics(false) == .init(clientWidth: 9,clientHeight: 15,scrollWidth: 88,scrollHeight: 17))
        #expect(try metrics(true) == .init(clientWidth: 9,clientHeight: 15,scrollWidth: 90,scrollHeight: 22))
    }
    @Test func hardParagraphBreaksKeepIntrinsicInlineExtentWhileSoftWrapFillsIt() throws {
        let hard = try #require(NativeVerticalContentFit.inlineExtent(advances: [39.52,39.52,39.52],
            ranges: [.init(location: 0,length: 3),.init(location: 3,length: 3),.init(location: 6,length: 2)],
            text: "天地\n玄黄\n宇宙",contentHeight: 154))
        #expect(hard == 39.53125)
        let soft = try #require(NativeVerticalContentFit.inlineExtent(advances: [39.52,19.76],
            ranges: [.init(location: 0,length: 2),.init(location: 2,length: 1)],text: "天地玄",contentHeight: 44))
        #expect(soft == 44)
    }
}
