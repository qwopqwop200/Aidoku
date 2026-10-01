import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeVerticalLetterSpacingTests {
    @Test func lastJapanesePunctuationKeepsTheFrozenColumnRange() throws {
        let text = "日A本B語!の縦書き、です。"
        let shaped = NativeTranslationTypography.layout(text: text, in: CGSize(width: 14, height: 44),
            style: .init(fontScript: "japanese", fontSize: 20, vertical: true, lineHeight: 24))
        #expect(shaped.shapedText == text && shaped.lineCount == 8)
        #expect(shaped.rangeBounds.last == CGRect(x: -87, y: 21, width: 21, height: 20.75))
        #expect(ceil(try #require(NativeTranslationTypography.verticalLineAdvances(layout: shaped).last) * 64) / 64 == 39.53125)
    }
    @Test func latinPairsUseFrozenVerticalLetterSpacing() throws {
        let cases: [(String, CGFloat)] = [("AV", 34.09375), ("To", 29.28125), ("す。", 39.53125)]
        for (text, expected) in cases {
            let shaped = NativeTranslationTypography.layout(text: text, in: CGSize(width: 94, height: 154),
                style: .init(fontScript: "japanese", fontSize: 20, vertical: true, lineHeight: 24))
            #expect(shaped.shapedText == text && shaped.lineCount == 1)
            let advance = try #require(NativeTranslationTypography.verticalLineAdvances(layout: shaped).first)
            #expect(ceil(advance * 64) / 64 == expected)
        }
    }
    @Test func hardBreaksRetainLiteralRowsAndTerminalSpacing() {
        let text = "天地\n玄黄\n宇宙"
        let shaped = NativeTranslationTypography.layout(text: text, in: CGSize(width: 94, height: 154),
            style: .init(fontScript: "japanese", fontSize: 20, vertical: true, lineHeight: 24))
        #expect(shaped.shapedText == text)
        #expect(shaped.lineRanges == [.init(location: 0, length: 3), .init(location: 3, length: 3), .init(location: 6, length: 2)])
        #expect(NativeTranslationTypography.verticalLineAdvances(layout: shaped).map { ceil($0 * 64) / 64 } == [39.53125, 39.53125, 39.53125])
    }
}
