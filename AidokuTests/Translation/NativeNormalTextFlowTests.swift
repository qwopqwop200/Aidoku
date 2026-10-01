import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeNormalTextFlowTests {
    private func flow(text: String, font: CGFloat, width: CGFloat, tracking: CGFloat? = nil,
                      balances: Bool = true) -> NativeNormalTextFlow.Result? {
        let source = text as NSString
        let face = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, font, nil)
        func measure(_ range: NSRange) -> CGFloat {
            let attributed = NSAttributedString(string: source.substring(with: range), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): face,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking ?? -font * 0.012])
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
        }
        return NativeNormalTextFlow.layout(text: text, maximumWidth: width, balances: balances, width: measure,
            emergencyBreak: { range, room in
                var end = range.location, chosen = 0
                while end < NSMaxRange(range) {
                    end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: end))
                    if measure(NSRange(location: range.location, length: end - range.location)) > room { break }
                    chosen = end - range.location
                }
                return chosen
            })
    }

    @Test(arguments: [2, 7]) func releasedColumnUsesNormalHangulOpportunities(id: Int) throws {
        let text = id == 2 ? "이제부터 나, 처녀를 잃게 되는 거야…" : "모... 모두가 보고 있는 앞에서 하는 건 싫은데……"
        let font: CGFloat = id == 2 ? 7.02906976744186 : 8.162790697674419
        let width: CGFloat = id == 2 ? 26.359375 : 26.5625
        // Genuine ordinary ranges are derived by the native helper, then tested
        // against captured nonempty WK fragments; they are never solver input.
        let automatic = try #require(flow(text: text, font: font, width: width, balances: false))
        let balanced = try #require(flow(text: text, font: font, width: width))
        let autoPairs = id == 2 ? [[0,5],[5,5],[10,5],[15,4],[19,2]] : [[0,6],[6,4],[10,5],[15,4],[19,5],[24,2],[26,3]]
        let balancedPairs = id == 2 ? [[0,3],[3,6],[9,4],[13,5],[18,3]] : [[0,6],[6,4],[10,3],[13,4],[17,5],[22,4],[26,3]]
        #expect(automatic.sourceRanges == autoPairs.map { NSRange(location: $0[0], length: $0[1]) })
        #expect(balanced.sourceRanges == balancedPairs.map { NSRange(location: $0[0], length: $0[1]) })
        #expect(balanced.autoRanges == automatic.sourceRanges)
        #expect(balanced.displayRows == (id == 2 ? ["이제부","터 나, 처","녀를 잃","게 되는","거야…"] : ["모... 모","두가 보","고 있","는 앞에","서 하는","건 싫은","데……"]))
    }

    @Test(arguments: [2, 7]) func coreUsesOnlyExplicitCollapsedWhitespaceProvenance(id: Int) {
        let text = id == 2 ? "이제부터 나, 처녀를 잃게 되는 거야…" : "모... 모두가 보고 있는 앞에서 하는 건 싫은데……"
        let font: CGFloat = id == 2 ? 7.02906976744186 : 8.162790697674419
        let size = CGSize(width: id == 2 ? 26.359375 : 26.5625, height: 100)
        var style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
            lineHeight: id == 2 ? 9.375 : 9.741143, optimizesKoreanWrapping: false,
            alignsToTop: true, balancesHorizontalLines: true,
            horizontalWrapping: .normal, horizontalWhitespace: .normal)
        let actual = NativeTranslationTypography.layout(text: text, in: size, style: style)
        let rows = id == 2 ? ["이제부","터 나, 처","녀를 잃","게 되는","거야…"] : ["모... 모","두가 보","고 있","는 앞에","서 하는","건 싫은","데……"]
        #expect(actual.shapedText == rows.joined(separator: "\n"))
        #expect(actual.lineCount == rows.count)
        #expect(actual.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count))
        // Merely Korean + normal wrapping cannot activate the collapsed bridge.
        style.horizontalWhitespace = .preWrap
        let initial = NativeTranslationTypography.layout(text: text, in: size, style: style)
        #expect(initial.shapedText != actual.shapedText)
    }

    @Test(arguments: ["공녀\t영식", "공녀\n영식", "공녀 שלום 영식", "공녀 \u{2067}영식\u{2069}"])
    func coreUnsupportedInputKeepsEstablishedShaping(text: String) {
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 16,
            optimizesKoreanWrapping: false, horizontalWrapping: .normal, horizontalWhitespace: .normal)
        let actual = NativeTranslationTypography.layout(text: text, in: CGSize(width: 1000, height: 100), style: style)
        #expect(actual.shapedText == text)
    }

    @Test func normalCollapsesOnlyAsciiSpaces() throws {
        let collapsed = try #require(flow(text: "   공녀  영식과   함께", font: 16, width: 65, tracking: 0))
        #expect(collapsed.displayRows == ["공녀 영식", "과 함께"])
        #expect(collapsed.sourceRanges == [NSRange(location: 0, length: 9), NSRange(location: 9, length: 6)])
        let nbsp = try #require(flow(text: "그대\u{00A0}공녀 그리고 영식", font: 16, width: 100, tracking: 0))
        #expect(nbsp.displayRows == ["그대\u{00A0}공녀", "그리고 영식"])
    }

    @Test func asciiSlashDoesNotAddAnIcuOnlyOpportunity() throws {
        let analysis = try #require(NativeNormalBreakOpportunities.analyze(text: "A/B—C-D 안녕･세계"))
        #expect(!analysis.paragraphs[0].softOffsets.contains(2))
        let result = try #require(flow(text: "A/B—C-D 안녕･세계", font: 16, width: 65, tracking: 0))
        #expect(result.displayRows == ["A/B—", "C-D 안", "녕･세계"])
    }

    @Test(arguments: ["공녀\t영식", "공녀\n영식", "공녀 שלום 영식", "공녀 \u{2067}영식\u{2069}"])
    func unsupportedInputRetainsCallerFallback(text: String) {
        #expect(flow(text: text, font: 16, width: 65) == nil)
    }
}
