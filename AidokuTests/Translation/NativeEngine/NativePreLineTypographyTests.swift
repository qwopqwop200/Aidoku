import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativePreLineTypographyTests {
    private func style(whitespace: NativeTranslationTypography.HorizontalWhitespace = .preLine,
                       wrapping: NativeTranslationTypography.HorizontalWrapping = .keepAll) -> NativeTranslationTypography.Style {
        .init(fontName: "AppleSDGothicNeo-Bold", fontScript: "korean", fontSize: 16, tracking: 0, lineHeight: 20,
            optimizesKoreanWrapping: false, alignsToTop: true, horizontalWrapping: wrapping,
            horizontalWhitespace: whitespace, horizontalAlignment: .left)
    }

    @Test func forcedEmptyParagraphsRetainTheirOriginalLfOwnership() throws {
        let source = "\n가\n\n"
        let layout = NativeTranslationTypography.layout(text: source, in: CGSize(width: 100, height: 100), style: style())
        #expect(layout.lineCount == 3 && layout.shapedText == source)
        #expect(layout.visibleUTF16Range == NSRange(location: 0, length: 4))
        #expect(try #require(layout.sourceUTF16Ownership) == (0..<4).map { NSRange(location: $0, length: 1) })
    }

    @Test func collapsedSegmentsKeepNbspAndExactSourcePositions() throws {
        let source = " A \r\n \tB\u{00A0} C "
        let layout = NativeTranslationTypography.layout(text: source, in: CGSize(width: 200, height: 100), style: style())
        #expect(layout.shapedText == "A\nB\u{00A0} C" && layout.lineCount == 2)
        #expect(try #require(layout.sourceUTF16Ownership).map(\.location) == [1,4,7,8,9,10])
        #expect(layout.visibleUTF16Range.length == source.utf16.count)
    }

    @Test func visibleFormFeedParticipatesInActualShapingAndPaintedInk() throws {
        let source = "가나다\u{000C}라마바"
        let layout = NativeTranslationTypography.layout(text: source, in: CGSize(width: 50, height: 100),
            style: style(wrapping: .keepAllWithEmergency))
        #expect(layout.shapedText == "가나다\n\u{000C}라마\n바" && layout.lineCount == 3)
        #expect(layout.glyphBounds.count == 7)
        let ownership = try #require(layout.sourceUTF16Ownership)
        #expect(ownership[4] == NSRange(location: 3, length: 1))
        #expect(ownership.filter { $0.length > 0 }.map(\.location) == Array(0..<7))
    }

    @Test func normalEffectCollapsesForcedLfWithoutChangingTheSource() {
        let source = "가\n\n나"
        let layout = NativeTranslationTypography.layout(text: source, in: CGSize(width: 100, height: 100),
            style: style(whitespace: .normal, wrapping: .keepAllWithEmergency))
        #expect(layout.shapedText == "가 나" && layout.lineCount == 1)
        #expect(layout.sourceUTF16Ownership == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 2), NSRange(location: 3, length: 1)])
        #expect(layout.visibleUTF16Range.length == source.utf16.count)
    }
}
