import Foundation
import Testing
@testable import Aidoku

struct NativeVerticalGlyphOriginsTests {
    @Test(arguments: ["PingFang SC", "Hiragino Sans", "Times", "Helvetica", ".Helvetica NeueUI", "Courier"])
    func pinnedIOSMetricsPreserveFamilySpecificAdjustment(family: String) throws {
        let normalized = try #require(NativeVerticalGlyphOrigins.iosMetrics(ascent: 21.2, descent: 6.8,
            leading: 0, familyName: family))
        let expectedA: Float = ["Times", "Helvetica", ".Helvetica NeueUI"].contains(family) ? 27 : 22
        #expect(normalized.primary.ascent == expectedA)
        #expect(normalized.primary.descent == 7)
        #expect(normalized.leading == 0)
    }

    @Test func fixedCellUsesFlooredHalfLeadingAndSourceGlyphConversion() throws {
        let han = NativeVerticalGlyphOrigins.Metrics(ascent: 22, descent: 7)
        #expect(NativeVerticalGlyphOrigins.ideographicCellBaseline(cellRight: 74, pitch: 24, metrics: han) == 62.5)
        #expect(NativeVerticalGlyphOrigins.ideographicCellBaseline(cellRight: 74, pitch: 23, metrics: han) == 62.5)
        let japanese = NativeVerticalGlyphOrigins.Metrics(ascent: 10, descent: 2)
        #expect(NativeVerticalGlyphOrigins.ideographicCellBaseline(cellRight: 74, pitch: 10, metrics: japanese) == 69)
        #expect(NativeVerticalGlyphOrigins.ideographicCellBaseline(cellRight: 74, pitch: 11, metrics: japanese) == 69)
        let rounded = try #require(NativeVerticalGlyphOrigins.iosMetrics(ascent: 9.9999997, descent: 2,
            leading: 0, familyName: "Hiragino Sans"))
        #expect(rounded.primary.ascent == 10)
    }

    @Test func terminalSpacingUsesFullCSSInlineExtent() {
        #expect(NativeVerticalGlyphOrigins.centeredInlineShift(flexOrigin: 0, lineLogicalWidth: 154,
            cssContentRight: 147, hangingTrailingWidth: 0, conditionalHanging: false, nativeLineOrigin: 4) == -0.5)
        #expect(NativeVerticalGlyphOrigins.centeredInlineShift(flexOrigin: 1, lineLogicalWidth: 152,
            cssContentRight: 152, hangingTrailingWidth: 0, conditionalHanging: false, nativeLineOrigin: 1) == 0)
    }
}
