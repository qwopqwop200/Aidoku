import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativeKeepAllInlineWidthTests {
    private func style(tracking: CGFloat = -0.099) -> NativeTranslationTypography.Style {
        NativeTranslationTypography.Style(fontName: "AppleSDGothicNeo-Bold", fontScript: "korean",
            fontSize: 8.25, tracking: tracking, lineHeight: 9.845215,
            optimizesKoreanWrapping: false, balancesHorizontalLines: true,
            horizontalWrapping: .keepAllWithEmergency)
    }

    private func x(_ row: [String: Any]) throws -> CGFloat {
        let origin = try #require(row["origin"] as? [Double])
        let offset = try #require(row["layoutOffset"] as? [Double])
        let movement = try #require(row["lineOffset"] as? [Double])
        return CGFloat(offset[0] + origin[0] + movement[0])
    }

    @Test func capturedSoftRowsUseWordItemWidthsBeforeCentering() throws {
        let text = "내가 갔다는 걸 모두에게 확실히 증명받아야 하니까... 웃는 얼굴로 부탁하는 게 당연한 거...겠지."
        let layout = NativeTranslationTypography.layout(text: text,
            in: CGSize(width: 59.375, height: 76.328125), style: style())
        let rows = NativeTranslationTypography.diagnosticRuns(layout: layout)
        #expect(rows.count == 7)
        // Actual frozen iOS glyph origins. The preceding spaces belong to
        // soft breaks; only the final row is an authored paragraph end.
        let expected: [CGFloat] = [16.645626068115234, 14.162378311157227,
            22.234996795654297, 18.242006301879883, 14.162378311157227,
            24.718250274658203, 25.328754425048828]
        for (row, expectedX) in zip(rows, expected) {
            let point = try #require(NativeTextPaintGeometry.paintOrigin(
                CGPoint(x: 10.140625 + x(row), y: 0), deviceScale: nil))
            #expect(point.x == expectedX)
        }
        #expect(layout.visibleUTF16Range.length == text.utf16.count)
        #expect(rows.last?["text"] as? String == "거...겠지.")
    }

    @Test(arguments: [CGFloat(-0.099), 0, 0.1])
    func naturalKerningWidthNeverReplacesPaintedGlyphs(tracking: CGFloat) throws {
        let text = "AV To"
        var ordinary = style(tracking: tracking)
        ordinary.horizontalWrapping = .normal
        ordinary.balancesHorizontalLines = false
        let original = NativeTranslationTypography.layout(text: text, in: CGSize(width: 200, height: 40), style: ordinary)
        let measured = NativeTranslationTypography.layout(text: text, in: CGSize(width: 200, height: 40), style: style(tracking: tracking))
        let oldRows = NativeTranslationTypography.diagnosticRuns(layout: original)
        let newRows = NativeTranslationTypography.diagnosticRuns(layout: measured)
        #expect(oldRows.count == 1 && newRows.count == 1)
        let oldRuns = try #require(oldRows.first?["runs"] as? [[String: Any]])
        let newRuns = try #require(newRows.first?["runs"] as? [[String: Any]])
        #expect((oldRuns as NSArray).isEqual(to: newRuns))
        #expect(original.shapedText == measured.shapedText)
        #expect(original.lineRanges == measured.lineRanges)
        if tracking == 0 {
            // Natural AV kerning and explicit kern-zero paint differ. Until
            // paint shares that policy, its existing alignment must survive.
            #expect(try x(oldRows[0]) == x(newRows[0]))
        }
    }

    @Test func normalAndPreformattedModesRetainTheirExistingAlignment() throws {
        let text = "거...겠지."
        for preformatted in [false, true] {
            var control = style()
            control.horizontalWrapping = .normal
            control.balancesHorizontalLines = false
            control.usesPreformattedBlockRows = preformatted
            let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 59.375, height: 40), style: control)
            let row = try #require(NativeTranslationTypography.diagnosticRuns(layout: layout).first)
            let anchor = try #require(NativeTextPaintGeometry.paintOrigin(CGPoint(x: 10.140625 + x(row), y: 0), deviceScale: nil))
            #expect(anchor.x == 25.328750610351562)
        }
    }

    @Test func mixedFontFallbackRetainsItsExistingAlignment() throws {
        var ordinary = style()
        ordinary.fontName = "Helvetica"
        ordinary.fontScript = ""
        ordinary.horizontalWrapping = .normal
        ordinary.balancesHorizontalLines = false
        var candidate = ordinary
        candidate.horizontalWrapping = .keepAllWithEmergency
        let old = NativeTranslationTypography.layout(text: "A천", in: CGSize(width: 200, height: 40), style: ordinary)
        let new = NativeTranslationTypography.layout(text: "A천", in: CGSize(width: 200, height: 40), style: candidate)
        let oldRow = try #require(NativeTranslationTypography.diagnosticRuns(layout: old).first)
        let newRow = try #require(NativeTranslationTypography.diagnosticRuns(layout: new).first)
        let runs = try #require(newRow["runs"] as? [[String: Any]])
        #expect(Set(runs.compactMap { $0["fontName"] as? String }).count > 1)
        #expect(try x(oldRow) == x(newRow))
        #expect((oldRow["runs"] as? NSArray)?.isEqual(to: runs) == true)
    }

    @Test(arguments: [" 가야", "가야 ", "가야  할", "가야\t할", "가야\n할", "가야\u{00a0}할", "가야\u{000c}할", "שלום", "👨‍👩‍👧"])
    func unsupportedWhitespaceAndClustersPreserveCompleteSource(text: String) {
        let layout = NativeTranslationTypography.layout(text: text,
            in: CGSize(width: 200, height: 80), style: style())
        #expect(layout.visibleUTF16Range.length == text.utf16.count)
        #expect(!layout.glyphBounds.isEmpty)
        #expect(!NativeTranslationTypography.diagnosticRuns(layout: layout).isEmpty)
    }

    @Test func recordedAuthoredParagraphKeepsItsLaterSoftSpaceHanging() throws {
        let text = "가문의 번영과\n종의 존속을 꾀했다"
        let paragraphStyle = NativeTranslationTypography.Style(fontName: "AppleSDGothicNeo-Bold", fontScript: "korean",
            fontSize: 11.75, tracking: -0.141, lineHeight: 14.02197265625,
            optimizesKoreanWrapping: false, balancesHorizontalLines: false,
            horizontalWrapping: .keepAllWithEmergency)
        let layout = NativeTranslationTypography.layout(text: text,
            in: CGSize(width: 42.015625, height: 127.1875), style: paragraphStyle)
        let rows = NativeTranslationTypography.diagnosticRuns(layout: layout)
        #expect(rows.map { $0["text"] as? String } == ["가문의 \n", "번영과\n", "종의 \n", "존속을 \n", "꾀했다"])
        #expect(layout.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count))
        // Frozen page 11 has identical origins for its three three-Hangul rows.
        // The fourth shaped range ends at 18, which is the original text length,
        // but its space is a soft wrap before 꾀했다, not a paragraph end.
        let expected: [CGFloat] = [65.50493621826172, 65.50493621826172,
            70.51631164550781, 65.50493621826172, 65.50493621826172]
        #expect(rows.count == expected.count)
        for (row, expectedX) in zip(rows, expected) {
            let origin = try x(row)
            let point = try #require(NativeTextPaintGeometry.paintOrigin(
                CGPoint(x: 59.53125 + origin, y: 0), deviceScale: nil))
            #expect(point.x == expectedX)
        }
    }

    @Test(arguments: ["가문의 \n번영과", "가문의  \n번영과 ", "가문의 \n\n번영과", " 가문의 \n번영과"])
    func authoredSpacesAndEmptyParagraphsRetainForcedBreakAlignment(text: String) throws {
        var ordinary = style()
        ordinary.balancesHorizontalLines = false
        ordinary.horizontalWrapping = .normal
        var keepAll = ordinary
        keepAll.horizontalWrapping = .keepAllWithEmergency
        let size = CGSize(width: 200, height: 100)
        let control = NativeTranslationTypography.layout(text: text, in: size, style: ordinary)
        let actual = NativeTranslationTypography.layout(text: text, in: size, style: keepAll)
        let oldRows = NativeTranslationTypography.diagnosticRuns(layout: control)
        let newRows = NativeTranslationTypography.diagnosticRuns(layout: actual)
        #expect(actual.shapedText == text && actual.shapedText == control.shapedText)
        #expect(actual.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count))
        #expect(oldRows.count == newRows.count)
        for (before, after) in zip(oldRows, newRows) {
            let oldX = try x(before), newX = try x(after)
            #expect(oldX == newX)
            #expect((before["runs"] as? NSArray)?.isEqual(to: after["runs"] as? [Any] ?? []) == true)
        }
    }
}
