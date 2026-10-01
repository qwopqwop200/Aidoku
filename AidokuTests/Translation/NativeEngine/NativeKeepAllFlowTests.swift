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

    @Test(arguments: ["가문의 번영과\n종의 존속을 꾀했다", "비술이라는 힘의\n유용성을 보여줌으로써"])
    func authoredParagraphsRetainIndependentKeepAllFlow(text: String) {
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 11.75,
            lineHeight: 14.02197265625, optimizesKoreanWrapping: false,
            balancesHorizontalLines: false, horizontalWrapping: .keepAllWithEmergency)
        let size = CGSize(width: 42, height: 300)
        let paragraphs = text.components(separatedBy: "\n").map {
            NativeTranslationTypography.layout(text: $0, in: size, style: style)
        }
        let combined = NativeTranslationTypography.layout(text: text, in: size, style: style)
        #expect(combined.shapedText == paragraphs.map(\.shapedText).joined(separator: "\n"))
        #expect(combined.lineCount == paragraphs.reduce(0) { $0 + $1.lineCount })
        #expect(combined.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count))
        #expect(combined.fits)
    }

    @Test func authoredParagraphWhitespaceAndRealEmergencyBreaksRemainIntact() {
        let text = "\n  가문의  번영과\n\n종의 매우긴단어를읽는다  \n"
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 12,
            lineHeight: 14.4, optimizesKoreanWrapping: false,
            balancesHorizontalLines: false, horizontalWrapping: .keepAllWithEmergency)
        let size = CGSize(width: 45, height: 500)
        let expected = text.components(separatedBy: "\n").map {
            NativeTranslationTypography.layout(text: $0, in: size, style: style).shapedText
        }.joined(separator: "\n")
        let actual = NativeTranslationTypography.layout(text: text, in: size, style: style)
        #expect(actual.shapedText == expected)
        #expect(actual.shapedText.hasPrefix("\n  "))
        #expect(actual.shapedText.hasSuffix("  \n"))
        #expect(actual.shapedText.contains("\n\n"))
        #expect(!NativeTypographyPostPolish.profile(actual, originalText: text).breaks.isEmpty)
    }


    @Test func captionRecoveryUsesTheBrowserInlineWidthAllowance() throws {
        let data = Data(#"""
        {
          "id": "inline-boundary",
          "text": "세계는 다시 돌아온 것이다……",
          "sourceBounds": [
            0,
            0,
            1,
            1
          ],
          "sourceFrame": [
            0,
            0,
            430,
            800
          ],
          "sourceColorEligible": true,
          "allowsAutomaticFontRecovery": true,
          "fontScript": "korean",
          "wrappingScript": "korean",
          "x": 319.6858638743455,
          "y": 573.3507853403141,
          "width": 51.21727748691103,
          "height": 69.22774869109946,
          "fontSize": 9,
          "lineHeight": 10.740234375,
          "paddingTop": 4.82,
          "paddingRight": 4.82,
          "paddingBottom": 4.82,
          "paddingLeft": 4.82
        }
        """#.utf8)
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: data)
        let size = CGSize(width: 430, height: 800)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
            viewport: size, items: [item])
        var settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        settings.preserveSourceBackgroundColor = true
        let session = NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: .init(),
            settings: settings, sourceImage: nil)
        let result = session.context.captionRecovering(item)
        #expect(result.fontSize == 9.75)
        #expect(result.rect == item.rect && result.text == item.text && result.sourceBounds == item.sourceBounds)
        let candidate = session.context.candidate(result)
        #expect(candidate.profile.lines == 4 && candidate.profile.breaks.isEmpty)
        #expect(session.context.contentFits(candidate))
    }
}
