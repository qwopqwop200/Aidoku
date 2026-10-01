import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeKeepAllFlowTests {
    @Test func emergencyWordStartsAfterTheExistingSoftWrap() {
        let text = "부... 부탁드립니다……"
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 9.25,
            lineHeight: 11.03857421875, optimizesKoreanWrapping: false,
            balancesHorizontalLines: true, horizontalWrapping: .keepAllWithEmergency)
        let shaped = NativeTranslationTypography.layout(text: text,
            in: CGSize(width: 32.125, height: 100), style: style)
        #expect(shaped.lineCount == 3)
        #expect(shaped.shapedText == "부... \n부탁드립\n니다……")
        #expect(NativeTypographyPostPolish.profile(shaped, originalText: text).breaks == [9])
    }
    @Test func rawFlowKeepsWordBoundariesBeforeEmergencySplitting() {
        let text = "다음은 리제 씨의 처녀막 제거를 진행하겠습니다"
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 8.75,
            lineHeight: 10.44189453125, optimizesKoreanWrapping: false,
            balancesHorizontalLines: true, horizontalWrapping: .keepAllWithEmergency)
        let shaped = NativeTranslationTypography.layout(text: text,
            in: CGSize(width: 45.78125, height: 100), style: style)
        #expect(shaped.lineCount == 5)
        #expect(NativeTypographyPostPolish.profile(shaped, originalText: text).breaks == [24])
    }
    @Test func balanceSupportsMoreThanSixRawRows() {
        let text = "그대는 작은 글씨를 더 넓게 읽고 싶었지만 줄바꿈 규칙을 정확하게 이해하지 못한 것이랍니다 그래서 본 영애가 직접 조판을 검증하는 것이와요"
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 16,
            tracking: 0, lineHeight: 19.2, optimizesKoreanWrapping: false,
            balancesHorizontalLines: true, horizontalWrapping: .keepAllWithEmergency)
        let shaped = NativeTranslationTypography.layout(text: text,
            in: CGSize(width: 75, height: 500), style: style)
        #expect(shaped.lineCount == 15)
        #expect(shaped.shapedText.components(separatedBy: "\n").suffix(5) == ["그래서 ", "본 영애가 ", "직접 조판을 ", "검증하는 ", "것이와요"].suffix(5))
    }
    @Test func strictPunctuationCandidateUsesNormalWordBreaking() {
        let text = "부... 부탁드립니다……"
        var normal = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 9.25,
            lineHeight: 11.03857421875, optimizesKoreanWrapping: false, strictLineBreak: true)
        let expected = NativeTranslationTypography.layout(text: text, in: CGSize(width: 32.125, height: 100), style: normal)
        normal.horizontalWrapping = .keepAllWithEmergency
        normal.keepsWholeWords = true
        let candidate = NativeTranslationTypography.layout(text: text, in: CGSize(width: 32.125, height: 100), style: normal)
        #expect(candidate.shapedText == expected.shapedText)
        #expect(candidate.lineRanges == expected.lineRanges)
    }

}
