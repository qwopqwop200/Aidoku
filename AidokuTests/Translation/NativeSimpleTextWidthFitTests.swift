import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativeSimpleTextWidthFitTests {
    @Test func sharingTypesetterAcrossWidthTrialsPreservesStandaloneRowsAndColor() throws {
        let text = "기울어진 ...... 글줄\n\nAV e\u{301}♡"
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 19, nil)
        let color = CGColor(red: 0.3, green: 0.2, blue: 0.7, alpha: 0.9)
        let input = NativeSimpleTextLayout.TypesettingInput(text: text, font: font, size: 24, color: color)
        for width: CGFloat in [100, 35, 260, 100] {
            let shared = try NativeSimpleTextLayout.layout(input, width: width)
            let standalone = try NativeSimpleTextLayout.layout(text: text, font: font, size: 24, width: width, color: color)
            #expect(shared.attributedText.isEqual(to: standalone.attributedText))
            #expect(shared.rows.map(\.ownedRange) == standalone.rows.map(\.ownedRange))
            #expect(shared.rows.map(\.paintedRange) == standalone.rows.map(\.paintedRange))
            #expect(shared.rows.map(\.inkBounds) == standalone.rows.map(\.inkBounds))
            #expect(shared.rows.map(\.advance) == standalone.rows.map(\.advance))
            #expect(shared.unresolvedGlyphRanges == standalone.unresolvedGlyphRanges)
        }
    }

    @Test func fittingRepeatRunStaysWholeWithoutPreventingOverwideWrap() throws {
        let size: CGFloat = 24
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        let motif = "......"
        let footprint = try NativeSimpleTextLayout.layout(text: motif, font: font, size: size, width: 2_000).requiredWidth
        let prefix = "ABCDE"
        let text = prefix + motif + "FGHIJ\n***"
        let result = try NativeSimpleTextLayout.layout(text: text, font: font, size: size, width: footprint + 0.01)
        let runStart = prefix.utf16.count
        let runEnd = runStart + motif.utf16.count
        #expect(result.completeOwnership)
        #expect(result.rows.contains { $0.hardBreak })
        #expect(result.rows.allSatisfy { !(runStart + 1..<runEnd).contains(NSMaxRange($0.ownedRange)) })
        #expect(result.rows.allSatisfy { $0.overflow <= 0.01 })

        let overwide = try NativeSimpleTextLayout.layout(text: motif, font: font, size: size, width: footprint * 0.6)
        #expect(overwide.completeOwnership)
        #expect(overwide.rows.count > 1)
        #expect(overwide.rows.allSatisfy { $0.overflow <= 0.01 })
    }

    @Test func positionedHorizontalRowsPreserveCoreTextInkBounds() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
        let color = CGColor(gray: 0, alpha: 1)
        for simple in [true, false] {
            let initial = try NativeSimpleTextLayout.withEnabled(simple) {
                try NativeFinalTextFlow.horizontal(text: "기울어진 글줄!\n\nAV ﬁ e\u{301} 한글",
                    font: font, size: 24, width: 260, minimumLineHeight: 40, outwardExtent: 2, color: color)
            }
            let plan = try #require(initial)
            let centered = try #require(plan.centered(height: plan.size.height + 20))
            for positioned in [plan, plan.aligned(.left), plan.aligned(.right), centered] {
                let expected = positioned.lines.indices.reduce(CGRect.null) { outer, i in
                    let line = positioned.lines[i], baseline = positioned.baselines[i]
                    let path = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                    let box = CTLineGetImageBounds(line, nil).union(path)
                    #expect(positioned.glyphPathBounds(at: i) == path)
                    #expect(positioned.imageAndGlyphPathBounds(at: i) == box)
                    guard !box.isNull, !box.isEmpty else { return outer }
                    return outer.union(CGRect(x: baseline.x + box.minX, y: baseline.y - box.maxY,
                        width: box.width, height: box.height))
                }
                #expect(positioned.inkBounds == expected)
            }
        }
    }

    @Test func measuredWidthRetainsExactRowsAndActualCallerPitch() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
        let text = "좁은 원문 폭에서도 실제 단어 너비와 행간을 보존한다."
        let fit = try #require(try NativeSimpleTextLayout.fitSingleWidth(text:text,font:font,size:24,
            preferredOuterWidth:28,maximumOuterWidth:400,availableHeight:600,
            outwardExtent:4,padding:2,minimumLineHeight:80))
        #expect(fit.outerWidth > 28 && fit.outerWidth <= 400)
        #expect(fit.wrapped.completeOwnership && fit.wrapped.unresolvedGlyphRanges.isEmpty)
        #expect(fit.positioned.fillBounds.height + 12 <= 600.01)
        for i in fit.positioned.baselines.indices.dropFirst() {
            #expect(fit.positioned.baselines[i].y - fit.positioned.baselines[i-1].y >= 79.999)
        }
        let flow = try #require(try NativeFinalTextFlow.horizontalSingleWidth(fit,outwardExtent:4,padding:2))
        #expect(flow.complete && flow.visibleUTF16 == text.utf16.count)
        #expect(flow.ranges == fit.wrapped.rows.map(\.ownedRange))
        #expect(flow.baselines == fit.positioned.baselines && flow.size == fit.positioned.size)
    }

    @Test func noFeasibleWidthIsExplicitAndRollbackHasDistinctRenderIdentity() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
        let fit = try NativeSimpleTextLayout.fitSingleWidth(text:"가나다라마바사",font:font,size:24,
            preferredOuterWidth:20,maximumOuterWidth:30,availableHeight:3,
            outwardExtent:4,padding:2,minimumLineHeight:60)
        #expect(fit == nil)
        NativeSimpleTextLayout.withEnabled(true) {
            let selected = NativeSimpleTextLayout.withWidthFit(true) { NativeSimpleTextLayout.version }
            let rollback = NativeSimpleTextLayout.withWidthFit(false) { NativeSimpleTextLayout.version }
            #expect(selected != rollback)
            #expect(NativeSimpleTextLayout.withWidthFit(true) { NativeSimpleTextLayout.widthFitEnabled })
        }
        NativeSimpleTextLayout.withEnabled(false) {
            #expect(!NativeSimpleTextLayout.withWidthFit(true) { NativeSimpleTextLayout.widthFitEnabled })
        }
    }
}
