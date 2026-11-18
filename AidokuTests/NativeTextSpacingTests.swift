import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativeTextSpacingTests {
    private let size: CGFloat = 20
    private var font: CTFont { CTFontCreateWithName("Helvetica" as CFString, size, nil) }

    @Test func normalWidthUsesNativeFaceSpacing() throws {
        let text = "AVATAR Toffee"
        let result = try NativeWholeWordWrap.layout(text: text, font: font, size: size, width: 500)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.init(kCTFontAttributeName as String): font]))
        #expect(result.appliedTracking == 0)
        #expect(result.attributedText.attribute(.init(kCTKernAttributeName as String), at: 0, effectiveRange: nil) == nil)
        #expect(abs(result.rows[0].advance - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) < 0.001)
    }

    @Test func onlySmallOverflowReceivesBoundedTrackingWithoutLosingText() throws {
        let text = "MMMMMMMMMM"
        let native = try NativeWholeWordWrap.layout(text: text, font: font, size: size, width: 1000)
        let width = native.requiredWidth - 0.4
        let adjusted = try NativeWholeWordWrap.layout(text: text, font: font, size: size, width: width)
        #expect(adjusted.appliedTracking < 0 && adjusted.appliedTracking >= -size * 0.03)
        #expect(adjusted.requiredWidth <= width + 0.01)
        #expect(adjusted.requestedFontSize == size)
        #expect(adjusted.completeOwnership && adjusted.text == text)
        #expect(adjusted.rows.map(\.ownedRange) == native.rows.map(\.ownedRange))
        let impossible = try NativeWholeWordWrap.layout(text: text, font: font, size: size, width: native.requiredWidth / 2)
        #expect(impossible.appliedTracking == 0 && impossible.requiredWidth > native.requiredWidth / 2)
        let explicit = try NativeWholeWordWrap.layout(text: text, font: font, size: size, width: 1000, tracking: 0.5)
        #expect(explicit.appliedTracking == 0.5)
    }

    @Test func positionedInkLeavesClearanceForBothOutlinesAndFallbackGlyphs() throws {
        let wrapped = try NativeWholeWordWrap.layout(text: "Ágj\n한글Épq", font: font, size: size, width: 300)
        let outward: CGFloat = 5
        let plan = try NativeWholeWordGlyphPainter.position(wrapped, width: 300,
            minimumLineHeight: NativeTextSpacing.lineHeight(fontSize: size), outwardExtent: outward)
        #expect(plan.baselines.count == 2)
        let first = wrapped.rows[0], second = wrapped.rows[1]
        let bottom = plan.baselines[0].y - first.inkBounds.minY
        let top = plan.baselines[1].y - second.inkBounds.maxY
        #expect(top - bottom >= 2 * outward + size * NativeTextSpacing.rowBreathingEm - 0.001)
        #expect(wrapped.completeOwnership && wrapped.unresolvedGlyphRanges.isEmpty)
        let pitch = NativeTextSpacing.pitch(text: "Ágj한글Épq", font: font, fontSize: size, outwardExtent: outward)
        #expect(pitch >= NativeTextSpacing.lineHeight(fontSize: size))
        #expect(pitch >= max(0, first.inkBounds.maxY) + max(0, -first.inkBounds.minY) + 2 * outward + size * NativeTextSpacing.rowBreathingEm - 0.001)
    }

    @Test func frameRetainsNativeSpacingWhenItsActualInkFits() throws {
        let text = NSAttributedString(string: "AVATAR Toffee", attributes: [.init(kCTFontAttributeName as String): font])
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 300, height: 100), transform: nil)
        let frame = NativeTextSpacing.frame(text: text, path: path, width: 300, fontSize: size, attributes: nil)
        #expect(frame.tracking == 0)
        #expect(CTFrameGetVisibleStringRange(frame.value).length == text.length)
    }

    @Test func sameStyleDefaultsDoNotDependOnEarlierSourceLeadingOrFillColour() throws {
        let items: [[String: Any]] = [["fontSize": 20.0, "lineHeight": 21.0],
            ["fontSize": 20.0, "lineHeight": 60.0], ["fontSize": 30.0, "lineHeight": 70.0]]
        let result = NativeTextSpacing.defaults(items)
        #expect(result[0]["lineHeight"] as? Double == 24)
        #expect(result[1]["lineHeight"] as? Double == 24)
        #expect(result[2]["lineHeight"] as? Double == 36)
        let raw: [String: Any] = ["sourceFontSize": 20.0,
            "sourceAppearance": ["outline": ["present": true, "observedLayers": [["widthPx": 2.0], ["widthPx": 1.0]]]]]
        #expect(NativeTextSpacing.outwardExtent(raw: raw, fontSize: 20) == 7)
    }
    @Test func mixedFontRowsUseACommonBaselineGridWithoutChangingNativeRuns() throws {
        let rows = try NativeWholeWordWrap.layout(text: "Ágj\n한글Épq\nABC", font: font, size: size, width: 300)
        let plan = try NativeWholeWordGlyphPainter.position(rows, width: 300, minimumLineHeight: 24, outwardExtent: 4)
        #expect(plan.baselines.count == 3)
        #expect(abs((plan.baselines[1].y-plan.baselines[0].y) - (plan.baselines[2].y-plan.baselines[1].y)) < 0.001)
        #expect(plan.wrapped.completeOwnership && plan.wrapped.text == rows.text)
    }

    @Test func interiorPaddingReservesOutlineAndBreathingRoomWithoutCollapsing() throws {
        let outer = CGRect(x: 10, y: 20, width: 100, height: 80)
        let inset = NativeTextSpacing.contentRect(outer, fontSize: 20, outwardExtent: 5)
        #expect(inset != nil)
        #expect(abs((inset?.minX ?? 0) - outer.minX - 7.4) < 0.001)
        #expect(abs((inset?.maxY ?? 0) - outer.maxY + 7.4) < 0.001)
        #expect(NativeTextSpacing.contentRect(CGRect(x: 0, y: 0, width: 14, height: 10), fontSize: 20, outwardExtent: 5) == nil)
        #expect(NativeTextSpacing.padding(fontSize: 2) == 1)
        #expect(NativeTextSpacing.padding(fontSize: 200) == 8)
    }

    @Test func inkAlignmentKeepsAllTextAndCoreTextBaselineDifferences() throws {
        let text = NSAttributedString(string: "Ágj\n한글Épq", attributes: [.init(kCTFontAttributeName as String): font])
        let box = CGRect(x: 20, y: 30, width: 200, height: 180)
        let path = CGPath(rect: box, transform: nil)
        let normal = NativeTextSpacing.frame(text: text, path: path, width: box.width, fontSize: size, attributes: nil).value
        let aligned = NativeTextSpacing.frame(text: text, path: path, width: box.width, fontSize: size, attributes: nil, alignInk: true).value
        let ink = NativeTextSpacing.frameInkBounds(aligned), actual = CTFrameGetPath(aligned).boundingBoxOfPath
        #expect(abs(actual.minY+ink.midY-box.midY) < 0.01)
        #expect(CTFrameGetVisibleStringRange(aligned).length == text.length)
        let before = CTFrameGetLines(normal) as! [CTLine], after = CTFrameGetLines(aligned) as! [CTLine]
        #expect(before.count == after.count && after.count == 2)
        var originalOrigins = [CGPoint](repeating: .zero, count: before.count)
        var alignedOrigins = originalOrigins
        CTFrameGetLineOrigins(normal, CFRange(location: 0, length: 0), &originalOrigins)
        CTFrameGetLineOrigins(aligned, CFRange(location: 0, length: 0), &alignedOrigins)
        #expect(abs((originalOrigins[1].y-originalOrigins[0].y) - (alignedOrigins[1].y-alignedOrigins[0].y)) < 0.001)
        for i in before.indices {
            #expect(CTLineGetStringRange(before[i]).location == CTLineGetStringRange(after[i]).location)
            #expect(CTLineGetStringRange(before[i]).length == CTLineGetStringRange(after[i]).length)
        }
    }

    @Test func lineHeightScalesWithFontSizeAndUsesCommonStyleBands() throws {
        let small = NativeTextSpacing.baselineStep(fontSize: 20, bodyHeight: 20.1, leading: 0, outwardExtent: 2)
        let nearby = NativeTextSpacing.baselineStep(fontSize: 20, bodyHeight: 20.3, leading: 0, outwardExtent: 2)
        let large = NativeTextSpacing.baselineStep(fontSize: 40, bodyHeight: 40.2, leading: 0, outwardExtent: 4)
        #expect(abs(small - nearby) < 0.001)
        #expect(abs(large - small * 2) < 0.001)
        let tall = NativeTextSpacing.baselineStep(fontSize: 20, bodyHeight: 35, leading: 0, outwardExtent: 5)
        #expect(tall >= 35 + 10 + size * NativeTextSpacing.rowBreathingEm)
        #expect(tall > small)
    }

    @Test func normalGlyphContentDoesNotChangeTheSameFaceLineHeight() throws {
        let first = NativeTextSpacing.pitch(text: "ABC", font: font, fontSize: size, outwardExtent: 4)
        let second = NativeTextSpacing.pitch(text: "gjpq", font: font, fontSize: size, outwardExtent: 4)
        #expect(abs(first - second) < 0.001)
        let rows = try NativeWholeWordWrap.layout(text: "ABC\ngjpq\nABC", font: font, size: size, width: 300)
        let positioned = try NativeWholeWordGlyphPainter.position(rows, width: 300,
            minimumLineHeight: first, outwardExtent: 4)
        #expect(abs(positioned.baselines[1].y - positioned.baselines[0].y - first) < 0.001)
        #expect(abs(positioned.baselines[2].y - positioned.baselines[1].y - first) < 0.001)
    }

}
