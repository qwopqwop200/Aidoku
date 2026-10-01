import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeVerticalPaintLayoutTests {
    @Test(arguments: [CGFloat(-1), CGFloat(0), CGFloat(1)])
    func physicalContainmentUsesCorrectedGlyphPositions(tracking: CGFloat) throws {
        #if os(iOS)
        let text = "天"
        let style = NativeTranslationTypography.Style(fontName: "PingFangSC-Semibold", fontScript: "han",
            fontSize: 20, vertical: true, tracking: tracking, lineHeight: 24, optimizesKoreanWrapping: false)
        let broad = NativeTranslationTypography.layout(text: text, in: CGSize(width: 100, height: 154), style: style)
        let broadInk = broad.glyphBounds.reduce(CGRect.null) { $0.union($1) }
        #expect(!broadInk.isNull)
        let boundary = max(1, 2 * (broadInk.maxX - 50) - 1)
        var accepted = false, rejected = false
        for step in -48...48 {
            let available = CGSize(width: boundary + CGFloat(step) / 64, height: 154)
            let layout = NativeTranslationTypography.layout(text: text, in: available, style: style)
            let rows = NativeTranslationTypography.diagnosticRuns(layout: layout)
            #expect(rows.count == 1)
            _ = try #require(rows.first?["verticalPaintOffset"])
            let ink = layout.glyphBounds.reduce(CGRect.null) { $0.union($1) }
            let physicallyContained = layout.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count) &&
                ink.width <= available.width + 0.5 && ink.height <= available.height + 0.5 &&
                CGRect(origin: .zero, size: available).insetBy(dx: -0.5, dy: -0.5).contains(ink)
            #expect(layout.fits == physicallyContained)
            #expect(layout.size == ink.size)
            #expect(layout.inkBounds == ink)
            accepted = accepted || physicallyContained
            rejected = rejected || !physicallyContained
        }
        #expect(accepted && rejected)
        #endif
    }

    @Test(arguments: [CGFloat(-1), CGFloat(0), CGFloat(1)])
    func sourceDerivedPaintOffsetsPreserveSelectionGeometry(tracking: CGFloat) throws {
        let style = NativeTranslationTypography.Style(fontName: "PingFangSC-Semibold", fontScript: "han",
            fontSize: 20, vertical: true, tracking: tracking, lineHeight: 24, optimizesKoreanWrapping: false)
        let layout = NativeTranslationTypography.layout(text: "天地玄黄宇宙洪荒", in: CGSize(width: 94, height: 154), style: style)
        var outlined = style
        outlined.outline = CGColor(gray: 1, alpha: 1)
        outlined.outlineWidth = 1
        let fallback = NativeTranslationTypography.layout(text: "天地玄黄宇宙洪荒", in: CGSize(width: 94, height: 154), style: outlined)
        #expect(layout.rangeBounds == fallback.rangeBounds)
        #expect(layout.lineRanges == fallback.lineRanges)
        let rows = NativeTranslationTypography.diagnosticRuns(layout: layout)
        #if os(iOS)
        #expect(rows.count == (tracking < 0 ? 1 : 2))
        for row in rows {
            let offset = try #require(row["verticalPaintOffset"] as? [Double])
            #expect(offset == [0.5, tracking > 0 ? -0.5 : 0])
        }
        #else
        #expect(rows.allSatisfy { $0["verticalPaintOffset"] == nil })
        #endif
        #expect(NativeTranslationTypography.diagnosticRuns(layout: fallback).allSatisfy { $0["verticalPaintOffset"] == nil })
    }
}
