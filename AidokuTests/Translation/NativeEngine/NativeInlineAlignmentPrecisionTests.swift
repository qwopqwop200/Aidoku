import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativeInlineAlignmentPrecisionTests {
    @Test func capturedKeepAllRowUsesFloatAvailableSpaceBeforeHalving() throws {
        let style = NativeTranslationTypography.Style(fontName: "AppleSDGothicNeo-Bold", fontScript: "korean",
            fontSize: 8.75, tracking: -0.105, lineHeight: 10.44189453125,
            optimizesKoreanWrapping: false, balancesHorizontalLines: true,
            horizontalWrapping: .keepAllWithEmergency)
        let source = "아… 저기…… 그…… 한계……"
        let layout = NativeTranslationTypography.layout(text: source,
            in: CGSize(width: 36.296875, height: 49.15625), style: style)
        let rows = NativeTranslationTypography.diagnosticRuns(layout: layout)
        #expect(rows.count == 4)
        // Unchanged frozen iOS row origins. Only the first row was previously
        // centered on the adjacent Float despite an already-correct item width.
        let expected: [CGFloat] = [63.85655975341797, 56.39281463623047,
            60.12468719482422, 56.3928108215332]
        for (row, expectedX) in zip(rows, expected) {
            let origin = try #require(row["origin"] as? [Double])
            let offset = try #require(row["layoutOffset"] as? [Double])
            let movement = try #require(row["lineOffset"] as? [Double])
            let paint = try #require(NativeTextPaintGeometry.paintOrigin(CGPoint(
                x: 53.171875 + offset[0] + origin[0] + movement[0], y: 0), deviceScale: nil))
            #expect(paint.x == expectedX)
        }
        #expect(layout.shapedText == "아… \n저기…… \n그…… \n한계……")
        #expect(layout.visibleUTF16Range.length == source.utf16.count)
    }

    @Test func floatInlineAlignmentDoesNotCenterOverflowOrChangeLegacyPlacement() throws {
        let box = NativeTextPaintGeometry.FlexBox(origin: -3.015625, width: 36.296875)
        #expect(box.inlineCenteredLineOrigin(lineWidth: 36.296875) == box.origin)
        #expect(box.inlineCenteredLineOrigin(lineWidth: 37) == box.origin)
        #expect(box.inlineCenteredLineOrigin(lineWidth: .infinity) == nil)
        #expect(box.inlineCenteredLineOrigin(lineWidth: -1) == nil)
        let source = try #require(box.inlineCenteredLineOrigin(lineWidth: 14.92750072479248))
        let legacy = try #require(box.lineOrigin(lineWidth: 14.92750072479248))
        #expect(source == 7.669061660766602)
        #expect(legacy == 7.66906213760376)
        // The normal/block fallback still uses its established placement.
        #expect(source != legacy)
    }
}
