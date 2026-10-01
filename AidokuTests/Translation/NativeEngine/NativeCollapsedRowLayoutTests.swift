import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeCollapsedRowLayoutTests {
    private var style: NativeTranslationTypography.Style {
        var result = NativeTranslationTypography.Style(fontName: "AppleSDGothicNeo-Bold", fontScript: "korean",
            fontSize: 6.25, vertical: false, tracking: -0.075, lineHeight: 8, optimizesKoreanWrapping: false)
        result.usesBlockWordLayout = true
        return result
    }

    @Test(arguments: ["가야 할 ", "  가야  할  ", "가야\t할 \r"])
    func rawCollapsedWhitespaceKeepsItsIntrinsicBox(text: String) throws {
        let available = CGSize(width: 30, height: 30)
        let plain = NativeTranslationTypography.layout(text: "가야 할", in: available, style: style)
        let raw = NativeTranslationTypography.layout(text: text, in: available, style: style)
        #expect(raw.shapedText == plain.shapedText)
        #expect(raw.lineRanges == plain.lineRanges)
        #expect(raw.visibleUTF16Range.length == text.utf16.count)
        let rawLine = try #require(NativeTranslationTypography.captionLineMetrics(layout: raw).first)
        let plainLine = try #require(NativeTranslationTypography.captionLineMetrics(layout: plain).first)
        #expect(rawLine.rect.width == plainLine.rect.width)
        #expect(rawLine.rect.minX == plainLine.rect.minX - 1.0 / 128)
        let box = try #require(NativeTranslationTypography.wholeRangeBounds(layout: raw, style: style, available: available))
        // Captured WebKit: the raw row's child box is one LayoutUnit wider,
        // while its collapsed text advance remains unchanged.
        #expect(box.width == 17.578125)
        #expect(box.minX == 6.203125)
        let adjusted = NativeTranslationTypography.applyingLineOffsets(layout: raw, offsets: [.zero])
        #expect(NativeTranslationTypography.wholeRangeBounds(layout: adjusted, style: style, available: available) == box)
    }

    @Test func preformattedRowsKeepAuthoredSpacesOutsideCollapsedIntrinsicPolicy() throws {
        var pre = style
        pre.usesBlockWordLayout = false
        pre.usesPreformattedBlockRows = true
        let layout = NativeTranslationTypography.layout(text: "가야 할 ", in: CGSize(width: 30, height: 30), style: pre)
        #expect(layout.shapedText == "가야 할 ")
        #expect(NativeTranslationTypography.diagnosticRuns(layout: layout).allSatisfy { $0["blockRowIntrinsicWidth"] == nil })
        let line = try #require(NativeTranslationTypography.captionLineMetrics(layout: layout).first)
        #expect(line.rect.width > 19)
    }

    @Test func unsupportedBidirectionalOrClusteredRowsKeepExistingIntrinsicMeasurement() {
        for text in ["שלום ", "👨‍👩‍👧 ", "가야\u{00a0}할 ", "가야\u{3000}할 ", "가야\u{000c}할 "] {
            let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 100, height: 30), style: style)
            #expect(!layout.glyphBounds.isEmpty)
            #expect(NativeTranslationTypography.diagnosticRuns(layout: layout).allSatisfy { $0["blockRowIntrinsicWidth"] == nil })
        }
    }
}
