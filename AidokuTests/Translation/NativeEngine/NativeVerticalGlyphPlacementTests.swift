import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeVerticalGlyphPlacementTests {
    @Test(arguments: [false, true])
    func balancedCrossAxisKeepsIndependentInlineCentering(balanced: Bool) throws {
        // Actual frozen WK paddingbox100x160/padding3; primary font20/pitch24.
        let style = NativeTranslationTypography.Style(fontScript: "japanese", fontSize: 20,
            vertical: true, lineHeight: 24, alignsToTop: balanced)
        let shaped = NativeTranslationTypography.layout(text: "日本語の縦書き",
            in: CGSize(width: 94, height: 154), style: style)
        let first = try #require(shaped.rangeBounds.first)
        #expect(first == CGRect(x: balanced ? 72 : 37, y: 7.828125, width: 21, height: 20))
    }

    @Test func explicitVerticalParagraphsHaveNoExtraNaturalColumnSpacing() throws {
        let shaped = NativeTranslationTypography.layout(text: "天地\n玄黄\n宇宙",
            in: CGSize(width: 4.5, height: 13),
            style: .init(fontScript: "japanese", fontSize: 20, vertical: true, lineHeight: 24))
        #expect(shaped.lineCount == 6 && shaped.rangeBounds.count == 6)
        for row in 1..<shaped.rangeBounds.count {
            #expect(shaped.rangeBounds[row - 1].minX - shaped.rangeBounds[row].minX == 24)
        }
    }
}
