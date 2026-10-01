import Foundation
import Testing
@testable import Aidoku

struct NativeKeepAllOverflowNormalTests {
    private func rows(_ text: String, width: CGFloat,
                      whitespace: NativeTranslationTypography.HorizontalWhitespace = .preWrap) -> [String] {
        let style = NativeTranslationTypography.Style(fontName: "AppleSDGothicNeo-Bold", fontScript: "korean", fontSize: 16,
            tracking: 0, lineHeight: 20, optimizesKoreanWrapping: false, balancesHorizontalLines: true,
            horizontalWrapping: .keepAll, horizontalWhitespace: whitespace)
        return NativeTranslationTypography.layout(text: text, in: CGSize(width: width, height: 600), style: style)
            .shapedText.components(separatedBy: "\n")
    }

    @Test func overflowNormalUsesFlexMinContentBeforeGreedyWrapping() {
        #expect(rows("끝까지함께읽는아주긴한국어단어 공녀 영식", width: 40) ==
            ["끝까지함께읽는아주긴한국어단어 ", "공녀 영식"])
    }

    @Test func nonbreakingAndIdeographicSpacingRemainLiteral() {
        #expect(rows("가\u{00A0}나 다 라", width: 40) == ["가\u{00A0}나 ", "다 라"])
        #expect(rows("가\u{3000}나 다 라", width: 40) == ["가\u{3000}", "나 다 ", "라"])
        #expect(rows("가\u{200B}나 다 라", width: 40) == ["가\u{200B}나 ", "다 라"])
    }

    @Test func firstLeadingAndRepeatedPreWrapSpacesArePreserved() {
        #expect(rows("  가 나  다  라", width: 40) == ["  가 ", "나  다  ", "라"])
    }

    @Test func normalKeepAllCollapsesOnlyAsciiSpaces() {
        #expect(rows("  가 나  다  라", width: 40, whitespace: .normal) == ["가 나", "다 라"])
        #expect(rows("가\u{00A0}나 다 라", width: 40, whitespace: .normal) == ["가\u{00A0}나", "다 라"])
        #expect(rows("가\u{3000}나 다 라", width: 40, whitespace: .normal) == ["가\u{3000}", "나 다", "라"])
    }

    @Test func balanceKeepsTheWebKitFifteenLineFlow() {
        let text = "그대는 작은 글씨를 더 넓게 읽고 싶었지만 줄바꿈 규칙을 정확하게 이해하지 못한 것이랍니다 그래서 본 영애가 직접 조판을 검증하는 것이와요"
        #expect(rows(text, width: 75) == ["그대는 작은 ", "글씨를 더 ", "넓게 읽고 ", "싶었지만 ", "줄바꿈 ", "규칙을 ", "정확하게 ", "이해하지 ", "못한 ", "것이랍니다 ", "그래서 ", "본 영애가 ", "직접 조판을 ", "검증하는 ", "것이와요"])
    }
}
