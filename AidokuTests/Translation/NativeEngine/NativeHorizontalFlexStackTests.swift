import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeHorizontalFlexStackTests {
    private static var primaryBaselineCases: [[Double]] {
        // The same iOS 26.5 runtime measured the 20pt primary face at18/6;
        // macOS measured18.000036/6.000012. Primary ceiled metrics therefore
        // give24pt versus26pt line boxes against the same23pt CSS pitch.
        #if os(iOS)
        return [[8.75, -1.0], [9.0, -1.0], [9.25, -1.0], [20.0, -1.0]]
        #else
        return [[8.75, -1.0], [9.0, -1.0], [9.25, -1.0], [20.0, -2.0]]
        #endif
    }

    @Test(arguments: primaryBaselineCases)
    func primaryLineBaselineDoesNotDependOnCoreTextLeading(values: [Double]) throws {
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: values[0],
            lineHeight: values[0] * 1.193359375, optimizesKoreanWrapping: false, alignsToTop: true)
        let layout = NativeTranslationTypography.layout(text: "가\n나\n다",
            in: CGSize(width: 100, height: 100), style: style)
        let first = try #require(layout.rangeBounds.first)
        #expect(layout.lineCount == 3)
        #expect(abs(first.minY - values[1]) < 0.00001)
        let rowTops = layout.rangeBounds.map(\.minY)
        #expect(abs(rowTops[1] - rowTops[0] - floor(style.lineHeight)) < 0.00001)
        #expect(abs(rowTops[2] - rowTops[1] - floor(style.lineHeight)) < 0.00001)
    }

    @Test(arguments: [[53.359375, 7.0, 3.0, 16.171875], [65.390625, 8.0, 2.0, 24.6875],
                      [5.015625, 7.0, 3.0, -7.984375], [40.015625, 10.0, 2.0, 10.0]])
    func centeredStackDividesFixedLayoutUnits(values: [Double]) throws {
        let text=Array(repeating:"가",count:Int(values[2])).joined(separator:"\n")
        var style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:6,
            lineHeight:values[1],optimizesKoreanWrapping:false,usesBlockWordLayout:true)
        let available=CGSize(width:40,height:values[0])
        let centered=NativeTranslationTypography.layout(text:text,in:available,style:style)
        style.alignsToTop=true
        let top=NativeTranslationTypography.layout(text:text,in:available,style:style)
        #expect(centered.lineCount==Int(values[2]) && top.lineCount==centered.lineCount)
        let a=try #require(centered.rangeBounds.first),b=try #require(top.rangeBounds.first)
        #expect(abs(a.minY-b.minY-values[3])<0.00001)
        #expect(a.width==b.width && a.height==b.height)
    }
}
