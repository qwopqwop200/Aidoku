import Foundation
import CoreText
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct NativeTextBoxReplacementTests {
    @Test
    func sourceTopGroupsKeepStaggeredAndKeptParagraphsIndependent() throws {
        func item(_ id: String, sourceFont: Double = 8, kept: Bool = false,
                  vertical: Bool = false, sourceVertical: Bool = true) throws -> NativeTranslationLayoutItem {
            let fields: [String: Any] = ["id": id, "text": "가나다", "x": 10, "y": 20,
                "width": 40, "height": 70, "fontSize": 8, "lineHeight": 10,
                "sourceFontSize": sourceFont, "sourceVertical": sourceVertical,
                "vertical": vertical, "keptLettering": kept, "sourceTextOnly": false, "rotation": -0.127,
                "sourceBounds": [0.1, 0.2, 0.1, 0.5], "sourceFrame": [0, 0, 200, 120]]
            return try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: fields))
        }
        let items = try [item("a"), item("b"), item("two-column", sourceFont: 14),
                         item("stagger"), item("kept", kept: true)]
        let owners = [CGRect(x: 10, y: 20, width: 10, height: 70),
                      CGRect(x: 35, y: 20, width: 10, height: 70),
                      CGRect(x: 60, y: 18, width: 20, height: 70),
                      CGRect(x: 90, y: 34, width: 10, height: 70),
                      CGRect(x: 115, y: 20, width: 10, height: 70)]
        #expect(NativeTranslationRenderer.sourceCaptionTopGroups(items: items, owners: owners) == [[0, 1, 2]])
        #expect(NativeTranslationRenderer.uprightTranslatedSourceColumn(items[0]))
        #expect(!NativeTranslationRenderer.uprightTranslatedSourceColumn(try item("target-vertical", vertical: true)))
        #expect(!NativeTranslationRenderer.uprightTranslatedSourceColumn(try item("source-horizontal", sourceVertical: false)))
        #expect(!NativeTranslationRenderer.uprightTranslatedSourceColumn(items[4]))
        #expect(NativeTranslationRenderer.sourceCaptionTopGroups(items: items, owners: []) == [])
    }

    @Test
    func relatedCaptionsShareActualFontAndFirstBaselineWithoutMergingText() throws {
        let size = CGSize(width: 200, height: 140)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: size, format: format).image { output in
            output.cgContext.setFillColor(UIColor.white.cgColor)
            output.cgContext.fill(CGRect(origin: .zero, size: size))
            output.cgContext.setFillColor(UIColor.black.cgColor)
            for x in [30, 90, 150] {
                output.cgContext.fill(CGRect(x: x, y: 30, width: 6, height: 50))
            }
        }
        let items = try (0..<3).map { index -> NativeTranslationLayoutItem in
            let font = [8.0, 8.25, 8.5][index]
            let fields: [String: Any] = ["id": "caption-\(index)", "text": "같은 문단 크기",
                "x": 20 + index * 60, "y": 28, "width": 40, "height": 82,
                "fontSize": font, "lineHeight": font * 1.2, "sourceFontSize": 8,
                "paddingTop": 2, "paddingBottom": 2, "paddingLeft": 2, "paddingRight": 2,
                "sourceVertical": true, "vertical": false, "sourceTextOnly": false,
                "rotation": index == 1 ? -0.127 : 0,
                "fontScript": "korean", "wrappingScript": "korean",
                "sourceBounds": [Double(30 + index * 60) / 200, 30.0 / 140, 6.0 / 200, 50.0 / 140],
                "sourceFrame": [0, 0, 200, 140]]
            return try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: fields))
        }
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
            viewport: size, items: items)
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: source,
            settings: ReaderTranslationSettings.defaultOverlay, collectDiagnostics: true)
        #expect(plan.cards.count == 3)
        #expect(Set(plan.cards.map { $0.item.id }) == Set(items.map(\.id)))
        #expect(Set(plan.cards.map { $0.style.fontSize }).count == 1)
        #expect(plan.cards.allSatisfy { $0.effectiveTextRotation == 0 && $0.typography.fits })
        let baselines = try plan.cards.map { card -> Double in
            let rows = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: card.typography,
                originalText: card.item.text, origin: card.textOrigin))
            let first = try #require(rows.first?["unsnappedBaseline"] as? [Double])
            return first[1]
        }
        #expect(try #require(baselines.max()) - #require(baselines.min()) < 0.000001)
        for density: CGFloat in [1, 2] {
            let pixels = CGSize(width: size.width * density, height: size.height * density)
            var budget = 32_000_000
            #expect(try NativeTranslationRenderer.stagedCaptionInkPreserved(cards: plan.cards,
                indices: Array(plan.cards.indices), bounds: CGRect(origin: .zero, size: size),
                pixels: pixels, sourceRect: layout.sourceRect, pdfDeviceScale: density,
                remainingSamples: &budget))
            #expect(budget < 32_000_000 && budget >= 0)
            var clipped = plan.cards
            let frame = clipped[1].item.rect
            // The unchanged panel rectangle cannot certify a newly clipped glyph.
            clipped[1].textBoxClip = [CGPoint(x: frame.minX, y: frame.minY),
                CGPoint(x: frame.minX + 1, y: frame.minY),
                CGPoint(x: frame.minX + 1, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)]
            #expect(try !NativeTranslationRenderer.stagedCaptionInkPreserved(cards: clipped,
                indices: Array(clipped.indices), bounds: CGRect(origin: .zero, size: size),
                pixels: pixels, sourceRect: layout.sourceRect, pdfDeviceScale: density,
                remainingSamples: &budget))
            var exhausted = 0
            #expect(try !NativeTranslationRenderer.stagedCaptionInkPreserved(cards: plan.cards,
                indices: Array(plan.cards.indices), bounds: CGRect(origin: .zero, size: size),
                pixels: pixels, sourceRect: layout.sourceRect, pdfDeviceScale: density,
                remainingSamples: &exhausted))
            #expect(exhausted == 0)
        }
    }

    @Test func exactKnownRowsPreserveScalarBoundariesAndUnknownEvidence() {
        for count in [0, 1, 15, 16, 17, 31, 32, 33, 48, 129] {
            let observed = (0..<count).map { UInt8(($0 * 73 + 254) % 256) }
            let modeled = (0..<count).map { UInt8(($0 * 41 + 255) % 256) }
            for permitsModel in [false, true] {
                let expected = zip(observed, modeled).map { a, b in
                    a == 255 || (permitsModel && b == 255) ? UInt8(255) : UInt8(0)
                }
                #expect(NativeTranslationRenderer.exactTextDomainKnownRow(
                    observed, modeled, permitsModel: permitsModel) == expected)
            }
            let empty = [UInt8](repeating: 0, count: count)
            let full = [UInt8](repeating: 255, count: count)
            #expect(NativeTranslationRenderer.exactTextDomainKnownRow(empty, full, permitsModel: false) == empty)
            #expect(NativeTranslationRenderer.exactTextDomainKnownRow(empty, full, permitsModel: true) == full)
            #expect(NativeTranslationRenderer.exactTextDomainKnownRow(full, empty, permitsModel: false) == full)
        }
    }

    @Test func exactOwnershipRejectsCanonicallyEquivalentDifferentUTF16() {
        let original = "e\u{301}가"
        let equivalent = "é가"
        #expect(original == equivalent)
        #expect(original.utf16.count != equivalent.utf16.count)
        let style = NativeTranslationTypography.Style(fontSize: 12, lineHeight: 16)
        let l = NativeTranslationTypography.layout(text: original, in: CGSize(width: 150, height: 80), style: style)
        #expect(NativeTranslationTypography.committedParagraphRawComplete(l, original: original))
        #expect(!NativeTranslationTypography.committedParagraphRawComplete(l, original: equivalent))
    }

    @Test func ownershipCursorRejectsMalformedValuesAndGeneratedBreakBoundaries() throws {
        typealias T = NativeTranslationTypography
        func r(_ x: Int, _ n: Int) -> NSRange { NSRange(location: x, length: n) }
        let style = T.Style(fontSize: 12, lineHeight: 16,
            optimizesKoreanWrapping: false, alignsToTop: true, strictLineBreak: true)
        var baseline = T.layout(text: "가\n나", in: CGSize(width: 120, height: 120), style: style)
        baseline.sourceUTF16Ownership = [r(0, 1), r(1, 0), r(1, 1)]
        #expect(T.sourceOwnershipCoverage(baseline, originalText: "가나")?.whole == true)
        #expect(T.committedParagraphRawComplete(baseline, original: "가나"))
        let malformed: [(String, [NSRange]?)] = [
            ("가나", [r(0, 1), r(0, 1), r(1, 1)]), // Generated LF falsely owns a duplicate.
            ("가나", [r(0, 2), r(0, 0), r(1, 1)]),
            ("가나", [r(1, 1), r(1, 0), r(0, 1)]),
            ("가다", [r(0, 1), r(1, 0), r(1, 1)]),
            ("가나", [r(0, 1), r(0, 0), r(1, 1)]), // Wrong generated LF cursor.
            ("가나", [r(0, 0), r(0, 1), r(1, 1)]),
            ("가나", nil), ("가나", []),
            ("가나", [r(0, 1), r(1, 0), r(2, 1)]),
            ("가나", [r(0, 1), r(1, -1), r(1, 1)]),
            ("가나", [r(0, 1), r(NSNotFound, 0), r(1, 1)])
        ]
        for (original, ledger) in malformed {
            var candidate = baseline
            candidate.sourceUTF16Ownership = ledger
            #expect(T.sourceOwnershipCoverage(candidate, originalText: original) == nil)
            #expect(!T.committedParagraphRawComplete(candidate, original: original))
            let rows = try #require(T.horizontalRowMetrics(layout: candidate, originalText: original))
            #expect(rows.allSatisfy { $0["sourceUTF16Range"] is NSNull })
            #expect(rows.first?["tokenCutAfterRowProxy"] is NSNull)
        }
        var empty = T.layout(text: "", in: CGSize(width: 120, height: 120), style: style)
        #expect(T.committedParagraphRawComplete(empty, original: ""))
        empty.sourceUTF16Ownership = [r(0, 0)]
        #expect(!T.committedParagraphRawComplete(empty, original: ""))
    }

    @Test func ownershipNormalizationIsCertifiedOnlyByTheActualProducer() throws {
        typealias T = NativeTranslationTypography
        var normal = T.Style(fontSize: 12, lineHeight: 16, optimizesKoreanWrapping: false)
        normal.horizontalWhitespace = .normal
        normal.horizontalWrapping = .keepAllWithEmergency
        for text in ["A  B", "😀  B", "a\u{301}  B", "A  B  C"] {
            let layout = T.layout(text: text, in: CGSize(width: 240, height: 180), style: normal)
            #expect(T.sourceOwnershipCoverage(layout, originalText: text)?.whole == true)
            #expect(layout.sourceOwnershipNormalization == .certifiedASCIISpaceCollapse)
        }
        var exact = normal
        exact.horizontalWhitespace = .preWrap
        var unmarked = T.layout(text: "A B", in: CGSize(width: 240, height: 180), style: exact)
        unmarked.sourceUTF16Ownership = [NSRange(location: 0, length: 1),
            NSRange(location: 1, length: 2), NSRange(location: 3, length: 1)]
        #expect(T.sourceOwnershipCoverage(unmarked, originalText: "A  B") == nil)
        for text in ["\u{200D}", "\u{FE0F}", "a\u{301}"] {
            let layout = T.layout(text: text, in: CGSize(width: 240, height: 180), style: exact)
            #expect(T.sourceOwnershipCoverage(layout, originalText: text)?.whole == true)
        }
        let partial = T.layout(text: " A  B ", in: CGSize(width: 240, height: 180), style: normal)
        #expect(T.sourceOwnershipCoverage(partial, originalText: " A  B ")?.whole == false)
    }

    @Test func solitaryParagraphRejectsUglyReflowAndKeepsStyleAnchorAndBacking() throws {
        let text = "작품명 「사냥」", size = CGSize(width: 120, height: 120)
        let balloon: [String: Any] = ["rect": [10.0/120, 10.0/120, 100.0/120, 100.0/120],
            "center": [0.5, 0.5], "spans": [10.0/120, 110.0/120, 10.0/120, 110.0/120],
            "contourVerified": true]
        let value: [String: Any] = ["id": "solo", "text": text, "x": 40, "y": 30,
            "width": 25.950100806451587, "height": 63.95734375000001,
            "fontSize": 11.5, "lineHeight": 13.5439453125, "sourceFontSize": 11.5,
            "fontScript": "korean", "wrappingScript": "korean",
            "sourceTextOnly": false, "paddingLeft": 2, "paddingRight": 2, "paddingTop": 2, "paddingBottom": 2,
            "sourceFrame": [0, 0, 120, 120], "sourceBounds": [44.0/120, 44.0/120, 10.0/120, 20.0/120],
            "balloonInterior": balloon]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let style = NativeTranslationTypography.Style(fontScript: "korean", prefersDominantKoreanScript: true,
            fontSize: 11.5, foreground: CGColor(gray: 0, alpha: 1),
            outline: CGColor(gray: 254.30965415943385/255, alpha: 1), outlineWidth: 0.5,
            tracking: -0.138, lineHeight: 13.5439453125,
            horizontalWrapping: .keepAllWithEmergency, horizontalAlignment: .center)
        let l = NativeTranslationTypography.layout(text: text, in: item.contentRect.size, style: style)
        let before = NativeTranslationRenderer.Card(item: item, typography: l, style: style,
            sourceBackgroundKind: "solid-text-box", drawsPanel: true, background: CGColor(gray: 1, alpha: 1),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 11.5)
        let bounds = CGRect(origin: .zero, size: size)
        let surface = try #require(NativeTextBoxContainment.known(item.balloonInterior, frame: bounds))
        var cards = [before], unknown: Set<String> = [], conditional: Set<String> = [], audit: [String: Int] = [:]
        let changed = try NativeTranslationRenderer.commitContourCohortsTiled(cards: &cards, items: [item],
            owners: [CGRect(x: 44, y: 44, width: 10, height: 20)], surfaces: [item.id: surface],
            bounds: bounds, sourceRect: bounds, pixels: CGSize(width: 240, height: 240), pdfDeviceScale: 1.75,
            verifiedOriginalStyle: [], allowsStyleUnknownTrials: true, unknownSourceStyleIDs: &unknown,
            allowsVerifiedBalloonInteriorModelTrials: true, conditionalGeometryIDs: &conditional,
            recordAudit: { audit = $0 })
        #expect(changed.isEmpty, "\(audit)")
        #expect(audit["committedSingleParagraphCards"] == nil)
        #expect(unknown.isEmpty && conditional.isEmpty)
        let after = try #require(cards.first)
        #expect(after.finalFontSize == before.finalFontSize && after.style.lineHeight == before.style.lineHeight)
        #expect(after.style.foreground == before.style.foreground && after.style.outline == before.style.outline)
        #expect(after.style.outlineWidth == before.style.outlineWidth && after.style.tracking == before.style.tracking)
        #expect(after.sourcePlateRect == before.sourcePlateRect && after.background == before.background)
        #expect(after.typography.lineCount == before.typography.lineCount)
        #expect(NativeTranslationTypography.committedParagraphRawComplete(after.typography, original: text))
        let oldRows = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: before.typography,
            originalText: text, origin: before.textOrigin))
        let newRows = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: after.typography,
            originalText: text, origin: after.textOrigin))
        #expect(oldRows.filter { $0["tokenCutAfterRowProxy"] as? Bool == true }.count == 2)
        #expect(newRows.filter { $0["tokenCutAfterRowProxy"] as? Bool == true }.count == 2)
        #expect(newRows.filter { $0["singleHangulLetterRow"] as? Bool == true }.count == 3)
        let oldAnchors = try #require(NativeTranslationTypography.committedRowAlignmentAnchors(layout: before.typography,
            alignment: .center, origin: before.textOrigin))
        let newAnchors = try #require(NativeTranslationTypography.committedRowAlignmentAnchors(layout: after.typography,
            alignment: .center, origin: after.textOrigin))
        let space = try #require(NativeTranslationRenderer.TextPaintDomain(rect: surface.rect,
            polygon: surface.polygon, within: bounds))
        let domain = try #require(NativeTranslationRenderer.cohortTextDomain(card: before,
            certifiedTextSpace: space, frames: [item.rect], protectedRects: [], minimumFontSize: 5,
            sourceStyleEvidence: "authored current model, not original GT"))
        let oldPlacement = try #require(NativeTranslationRenderer.cohortPlacement(index: 0, card: before,
            domain: domain, frame: before.item.rect, origin: before.textOrigin, style: before.style,
            layout: before.typography, baseline: true))
        let newPlacement = try #require(NativeTranslationRenderer.cohortPlacement(index: 0, card: after,
            domain: domain, frame: after.item.rect, origin: after.textOrigin, style: after.style,
            layout: after.typography))
        let rounding = try #require(NativeTranslationRenderer.cohortAlignmentRoundingBound(
            baseline: oldPlacement, candidate: newPlacement))
        #expect(abs(oldAnchors[0] - newAnchors[0]) <= rounding)
        #expect(rounding < 1.0/1024)
        let oldBaseline = try #require(oldRows[0]["unsnappedBaseline"] as? [Double])
        let newBaseline = try #require(newRows[0]["unsnappedBaseline"] as? [Double])
        // First-glyph X legitimately changes when centered rows reflow; the
        // producer-owned alignment anchor above is the preserved horizontal axis.
        #expect(abs(oldBaseline[1] - newBaseline[1]) < 1e-7)
    }

    @Test func solitaryParagraphRejectsAttachedPunctuationSplitWithoutStyleOrBackingChanges() throws {
        typealias T = NativeTranslationTypography
        typealias G = NativeParagraphReadabilityGuard
        let text = "하... 하지만... 보여지게 될 줄은 몰랐단 말이야..."
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        let balloon: [String: Any] = ["rect": [10.0/120, 10.0/120, 100.0/120, 100.0/120],
            "center": [0.5, 0.5], "spans": [10.0/120, 110.0/120, 10.0/120, 110.0/120],
            "contourVerified": true]
        let owner = CGRect(x: 60, y: 45, width: 10, height: 20)
        let value: [String: Any] = ["id": "safe-solo", "text": text, "x": 40, "y": 20,
            "width": 56.15625, "height": 83.234375, "fontSize": 10.75,
            "lineHeight": 12.66064453125, "sourceFontSize": 10.75,
            "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": false,
            "paddingLeft": 2, "paddingRight": 2, "paddingTop": 2, "paddingBottom": 2,
            "sourceFrame": [0, 0, 120, 120],
            "sourceBounds": [60.0/120, 45.0/120, 10.0/120, 20.0/120], "balloonInterior": balloon]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let style = T.Style(fontScript: "korean", prefersDominantKoreanScript: true,
            fontSize: 10.75, bold: true, foreground: CGColor(gray: 0, alpha: 1),
            outline: CGColor(red: 248.0/255, green: 246.0/255, blue: 245.0/255, alpha: 1),
            outlineWidth: 0.5, tracking: -0.129, lineHeight: 12.66064453125,
            horizontalWrapping: .keepAllWithEmergency, horizontalAlignment: .center)
        let baseline = T.layout(text: text, in: item.contentRect.size, style: style)
        let before = NativeTranslationRenderer.Card(item: item, typography: baseline, style: style,
            sourceBackgroundKind: "solid-text-box", drawsPanel: true, background: CGColor(gray: 1, alpha: 1),
            usesFallbackVeil: false, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 10.75)
        let surface = try #require(NativeTextBoxContainment.known(item.balloonInterior, frame: bounds))
        var cards = [before], unknown: Set<String> = [], conditional: Set<String> = [], audit: [String: Int] = [:]
        let changed = try NativeTranslationRenderer.commitContourCohortsTiled(cards: &cards, items: [item],
            owners: [owner], surfaces: [item.id: surface], bounds: bounds, sourceRect: bounds,
            pixels: CGSize(width: 240, height: 240), pdfDeviceScale: 1.75,
            verifiedOriginalStyle: [], allowsStyleUnknownTrials: true, unknownSourceStyleIDs: &unknown,
            allowsVerifiedBalloonInteriorModelTrials: true, conditionalGeometryIDs: &conditional,
            recordAudit: { audit = $0 })
        #expect(changed.isEmpty, "\(audit)")
        #expect(audit["committedSingleParagraphCards"] == nil)
        #expect(unknown.isEmpty && conditional.isEmpty)
        let after = try #require(cards.first)
        let old = try #require(G.observed(layout: baseline, original: text,
            width: item.contentRect.width, style: style))
        let new = try #require(G.observed(layout: after.typography, original: text,
            width: after.item.contentRect.width, style: after.style))
        #expect(old.cuts == 0 && new.cuts == 0)
        #expect(old.singletons == 1 && new.singletons == 1)
        #expect(new.noWorse(than: old) && new.meanNonfinalEmptySquared == old.meanNonfinalEmptySquared)
        #expect(new.attachedTerminalSplits == old.attachedTerminalSplits)
        var utf = 131_072, geometry = 131_072
        let frontier = T.committedParagraphFrontier(text: text, width: item.contentRect.width,
            style: style, utf16Work: &utf, geometryWork: &geometry, referenceLayout: baseline)
        #expect(frontier.complete && !frontier.programs.isEmpty)
        for program in frontier.programs {
            let layout = try #require(T.layoutCommittedParagraph(text: text, in: item.contentRect.size,
                style: style, program: program))
            let rejected = try #require(G.observed(layout: layout, original: text,
                width: item.contentRect.width, style: style))
            #expect(rejected.singletons == 0)
            #expect(rejected.attachedTerminalSplits > old.attachedTerminalSplits)
            #expect(!rejected.noWorse(than: old))
        }
        #expect(after.typography.lineCount == 5 && baseline.lineCount == 5)
        #expect(T.committedParagraphRawComplete(after.typography, original: text))
        #expect(after.finalFontSize == before.finalFontSize && after.style.bold == before.style.bold)
        #expect(after.style.lineHeight == before.style.lineHeight && after.style.tracking == before.style.tracking)
        #expect(after.style.foreground == before.style.foreground && after.style.outline == before.style.outline)
        #expect(after.style.outlineWidth == before.style.outlineWidth)
        #expect(after.sourcePlateRect == before.sourcePlateRect && after.background == before.background)
        let oldAnchors = try #require(T.committedRowAlignmentAnchors(layout: baseline,
            alignment: .center, origin: before.textOrigin))
        let newAnchors = try #require(T.committedRowAlignmentAnchors(layout: after.typography,
            alignment: .center, origin: after.textOrigin))
        #expect(abs(oldAnchors[0] - newAnchors[0]) < 1.0/1024)
        let oldRows = try #require(T.horizontalRowMetrics(layout: baseline, originalText: text, origin: before.textOrigin))
        let newRows = try #require(T.horizontalRowMetrics(layout: after.typography, originalText: text, origin: after.textOrigin))
        let oldBaseline = try #require(oldRows[0]["unsnappedBaseline"] as? [Double])
        let newBaseline = try #require(newRows[0]["unsnappedBaseline"] as? [Double])
        #expect(abs(oldBaseline[1] - newBaseline[1]) < 1e-7)
    }

    @Test func solitaryParagraphCommitsAttachmentSafeSingletonReflow() throws {
        typealias T = NativeTranslationTypography
        typealias G = NativeParagraphReadabilityGuard
        let text = "제대로 모두가 봐주어야 하니까"
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 120)
        let balloon: [String: Any] = ["rect": [10.0/120, 10.0/120, 100.0/120, 100.0/120],
            "center": [0.5, 0.5], "spans": [10.0/120, 110.0/120, 10.0/120, 110.0/120],
            "contourVerified": true]
        let owner = CGRect(x: 60, y: 45, width: 10, height: 20)
        let value: [String: Any] = ["id": "safe-solo", "text": text, "x": 40, "y": 20,
            "width": 41.351609442060102, "height": 76.421875, "fontSize": 11.75,
            "lineHeight": 13.83837890625, "sourceFontSize": 11.75,
            "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": false,
            "paddingLeft": 2, "paddingRight": 2, "paddingTop": 2, "paddingBottom": 2,
            "sourceFrame": [0, 0, 120, 120],
            "sourceBounds": [60.0/120, 45.0/120, 10.0/120, 20.0/120], "balloonInterior": balloon]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let style = T.Style(fontScript: "korean", prefersDominantKoreanScript: true,
            fontSize: 11.75, bold: true, foreground: CGColor(gray: 1, alpha: 1),
            outline: CGColor(red: 0.17852731873025046, green: 0.08375397769158674,
                blue: 0.066651848723619428, alpha: 1),
            outlineWidth: 0.5, tracking: -0.14100000000000001, lineHeight: 13.83837890625,
            horizontalWrapping: .keepAllWithEmergency, horizontalAlignment: .center)
        let baseline = T.layout(text: text, in: item.contentRect.size, style: style)
        let before = NativeTranslationRenderer.Card(item: item, typography: baseline, style: style,
            sourceBackgroundKind: "solid-text-box", drawsPanel: true, background: CGColor(red: 0.18, green: 0.08, blue: 0.07, alpha: 1),
            usesFallbackVeil: false, lightSurface: false, heavyStrokeWidth: 0, finalFontSize: 11.75)
        let surface = try #require(NativeTextBoxContainment.known(item.balloonInterior, frame: bounds))
        var cards = [before], unknown: Set<String> = [], conditional: Set<String> = [], audit: [String: Int] = [:]
        let changed = try NativeTranslationRenderer.commitContourCohortsTiled(cards: &cards, items: [item],
            owners: [owner], surfaces: [item.id: surface], bounds: bounds, sourceRect: bounds,
            pixels: CGSize(width: 240, height: 240), pdfDeviceScale: 1.75,
            verifiedOriginalStyle: [], allowsStyleUnknownTrials: true, unknownSourceStyleIDs: &unknown,
            allowsVerifiedBalloonInteriorModelTrials: true, conditionalGeometryIDs: &conditional,
            recordAudit: { audit = $0 })
        #expect(changed == [item.id], "\(audit)")
        #expect(audit["committedSingleParagraphCards"] == 1)
        #expect(unknown == [item.id] && conditional == [item.id]) // Original style/artwork GT remains unknown.
        let after = try #require(cards.first)
        let old = try #require(G.observed(layout: baseline, original: text,
            width: item.contentRect.width, style: style))
        let new = try #require(G.observed(layout: after.typography, original: text,
            width: after.item.contentRect.width, style: after.style))
        #expect(old.cuts == 1 && new.cuts == 1)
        #expect(old.singletons == 1 && new.singletons == 0)
        #expect(new.noWorse(than: old) && new.meanNonfinalEmptySquared < old.meanNonfinalEmptySquared)
        #expect(new.attachedTerminalSplits == old.attachedTerminalSplits)
        #expect(new.punctuationClusterSplits == 0 && old.punctuationClusterSplits == 0)
        #expect(after.typography.lineCount == 5 && baseline.lineCount == 5)
        #expect(T.committedParagraphRawComplete(after.typography, original: text))
        #expect(after.finalFontSize == before.finalFontSize && after.style.bold == before.style.bold)
        #expect(after.style.lineHeight == before.style.lineHeight && after.style.tracking == before.style.tracking)
        #expect(after.style.foreground == before.style.foreground && after.style.outline == before.style.outline)
        #expect(after.style.outlineWidth == before.style.outlineWidth)
        #expect(after.sourcePlateRect == before.sourcePlateRect && after.background == before.background)
        let oldAnchors = try #require(T.committedRowAlignmentAnchors(layout: baseline,
            alignment: .center, origin: before.textOrigin))
        let newAnchors = try #require(T.committedRowAlignmentAnchors(layout: after.typography,
            alignment: .center, origin: after.textOrigin))
        #expect(abs(oldAnchors[0] - newAnchors[0]) < 1.0/1024)
        let oldRows = try #require(T.horizontalRowMetrics(layout: baseline, originalText: text, origin: before.textOrigin))
        let newRows = try #require(T.horizontalRowMetrics(layout: after.typography, originalText: text, origin: after.textOrigin))
        let oldBaseline = try #require(oldRows[0]["unsnappedBaseline"] as? [Double])
        let newBaseline = try #require(newRows[0]["unsnappedBaseline"] as? [Double])
        #expect(abs(oldBaseline[1] - newBaseline[1]) < 1e-7)
    }

    @Test func cohortScratchAdmissionAccountsForWholeWorldAndStripeEvidence() throws {
        let largest = try #require(NativeTranslationRenderer.cohortTextScratchRequirement(
            pixels: CGSize(width: 3600, height: 2700)))
        #expect(largest == 43_776_000)
        #expect(largest > 32 * 1024 * 1024)
        #expect(largest <= NativeTranslationRenderer.cohortTextMaximumScratchBytes)
        let excessive = try #require(NativeTranslationRenderer.cohortTextScratchRequirement(
            pixels: CGSize(width: 16384, height: 732)))
        #expect(excessive > NativeTranslationRenderer.cohortTextMaximumScratchBytes)
        #expect(NativeTranslationRenderer.cohortTextScratchRequirement(pixels: CGSize(width: 100.5, height: 100)) == nil)
        #expect(NativeTranslationRenderer.cohortTextScratchRequirement(pixels: CGSize(width: CGFloat.nan, height: 100)) == nil)
    }

    @Test(arguments: [CGFloat(1), CGFloat(1.75), CGFloat(3)])
    func alignmentAnchorsUseProducerWidthNotTrailingAdvance(snap: CGFloat) throws {
        for alignment: NativeTranslationTypography.HorizontalAlignment in [.left, .center, .right] {
            var style = NativeTranslationTypography.Style(fontSize: 12, tracking: 1.2, lineHeight: 16,
                optimizesKoreanWrapping: false, alignsToTop: true)
            style.horizontalWhitespace = .preWrap
            style.horizontalWrapping = .normal
            style.horizontalAlignment = alignment
            let layout = NativeTranslationTypography.layout(text: "가나 마바   ",
                in: CGSize(width: 76, height: 100), style: style)
            let anchors = try #require(NativeTranslationTypography.committedRowAlignmentAnchors(layout: layout,
                alignment: alignment, pixelSnapScale: snap))
            let expected: CGFloat = alignment == .left ? 0 : alignment == .right ? 76 : 38
            #expect(anchors.count == 1)
            #expect(abs(anchors[0] - expected) < 0.02)
        }
    }

    @Test func committedParagraphRejectsMisleadingCutsWithLonelyQuote() throws {
        let text = "작품명 「사냥」"
        let size = CGSize(width: 21.950100806451587, height: 59.95734375000001)
        let style = NativeTranslationTypography.Style(fontScript: "korean", prefersDominantKoreanScript: true,
            fontSize: 11.5, foreground: CGColor(gray: 0, alpha: 1),
            outline: CGColor(gray: 254.30965415943385 / 255, alpha: 1), outlineWidth: 0.5,
            tracking: -0.138, lineHeight: 13.5439453125,
            horizontalWrapping: .keepAllWithEmergency, horizontalAlignment: .center)
        let reference = NativeTranslationTypography.layout(text: text, in: size, style: style)
        var utf = 131_072, geometry = 131_072
        let result = NativeTranslationTypography.committedParagraphCandidates(text: text, in: size,
            style: style, reference: reference, utf16Work: &utf, geometryWork: &geometry)
        let before = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: reference, originalText: text))
        #expect(result.complete && reference.fits)
        #expect(before.filter { $0["tokenCutAfterRowProxy"] as? Bool == true }.count == 2)
        #expect(before.filter { $0["singleHangulLetterRow"] as? Bool == true }.count == 3)
        #expect(result.layouts.isEmpty)
        let frontier = NativeTranslationTypography.committedParagraphFrontier(text: text, width: size.width,
            style: style, utf16Work: &utf, geometryWork: &geometry, referenceLayout: reference)
        #expect(frontier.complete && frontier.programs.count == 2)
        let beforeReadability = try #require(NativeParagraphReadabilityGuard.observed(
            layout: reference, original: text, width: size.width, style: style))
        for program in frontier.programs {
            let candidate = try #require(NativeTranslationTypography.layoutCommittedParagraph(
                text: text, in: size, style: style, program: program))
            let rows = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: candidate, originalText: text))
            #expect(candidate.fits && candidate.lineCount == reference.lineCount)
            #expect(candidate.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count))
            #expect(NativeTranslationTypography.committedParagraphRawComplete(candidate, original: text))
            #expect(rows.filter { $0["tokenCutAfterRowProxy"] as? Bool == true }.count == 1)
            #expect(rows.filter { $0["singleHangulLetterRow"] as? Bool == true }.count == 1)
            #expect(candidate.size.height == reference.size.height)
            let observed = try #require(NativeParagraphReadabilityGuard.observed(
                layout: candidate, original: text, width: size.width, style: style))
            #expect(observed.lonelyQuoteRows > beforeReadability.lonelyQuoteRows)
            #expect(observed.punctuationOnlyRows > beforeReadability.punctuationOnlyRows)
            #expect(observed.shortLastRows > beforeReadability.shortLastRows)
            #expect(!observed.noWorse(than: beforeReadability))
        }
    }

    @Test func committedAlignmentAnchorTracksCenterInsteadOfFirstGlyph() throws {
        let text = "가나다라마바사아자차카타파하가나다라마바사아자차카타파하"
        var style = NativeTranslationTypography.Style(fontSize: 12, lineHeight: 16,
            optimizesKoreanWrapping: false, alignsToTop: true)
        style.horizontalWhitespace = .preWrap
        style.horizontalWrapping = .keepAllWithEmergency
        style.horizontalAlignment = .center
        let widths: [CGFloat] = [76, 136]
        let anchors = try widths.map { width -> CGFloat in
            let l = NativeTranslationTypography.layout(text: text, in: CGSize(width: width, height: 300), style: style)
            let values = try #require(NativeTranslationTypography.committedRowAlignmentAnchors(layout: l,
                alignment: .center, origin: CGPoint(x: 110 - width / 2, y: 20)))
            return try #require(values.first)
        }
        #expect(abs(anchors[0] - anchors[1]) < 0.02)
        let l = NativeTranslationTypography.layout(text: text, in: CGSize(width: 76, height: 300), style: style)
        let original = try #require(NativeTranslationTypography.committedRowAlignmentAnchors(layout: l,
            alignment: .center, origin: CGPoint(x: 72, y: 20)))
        let moved = try #require(NativeTranslationTypography.committedRowAlignmentAnchors(layout: l,
            alignment: .center, origin: CGPoint(x: 96, y: 20)))
        #expect(abs(moved[0] - original[0] - 24) < 1e-7)
        #expect(NativeTranslationTypography.committedRowAlignmentAnchors(layout: l, alignment: .center,
            origin: CGPoint(x: CGFloat.nan, y: 0)) == nil)
    }

    @Test func keepAllAuthoredNewlinesUseProducerOwnership() throws {
        let text = "가나다라\n마바사아\n자차카타"
        var style = NativeTranslationTypography.Style(fontSize: 12, lineHeight: 16)
        style.horizontalWhitespace = .preWrap
        style.horizontalWrapping = .keepAllWithEmergency
        let l = NativeTranslationTypography.layout(text: text, in: CGSize(width: 28, height: 300), style: style)
        let ledger = try #require(l.sourceUTF16Ownership)
        #expect(ledger.count == l.shapedText.utf16.count)
        let owned = ledger.filter { $0.length > 0 }
        #expect(owned.map(\.location) == Array(0..<text.utf16.count))
        let rows = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: l, originalText: text))
        #expect(rows.allSatisfy { $0["sourceUTF16Range"] is [Int] })
        #expect(rows.dropLast().allSatisfy { $0["tokenCutAfterRowProxy"] is Bool })
        #expect(l.visibleUTF16Range.length == text.utf16.count && l.fits)
    }

    @Test func contourCohortCommitsAtomicallyAndKeepsBackingAndHierarchy() throws {
        let size = CGSize(width: 240, height: 180)
        func fixture(sourceOnly: Bool, unverified: Bool = false) throws -> NativeTranslationLayout {
            let items = try (0..<2).map { index -> NativeTranslationLayoutItem in
                let x = index == 0 ? 20.0 : 95.0
                let font = index == 0 ? 8.0 : 16.0
                let sourceBounds: [Double] = [(x + 13) / 240, 70.0 / 180, 44.0 / 240, 20.0 / 180]
                let balloon: [String: Any] = [
                    "rect": [10.0 / 240, 10.0 / 180, 170.0 / 240, 150.0 / 180],
                    "center": [95.0 / 240, 85.0 / 180],
                    "spans": [10.0 / 240, 180.0 / 240, 10.0 / 240, 180.0 / 240],
                    "contourVerified": !(unverified && index == 1)]
                let value: [String: Any] = ["id": index == 0 ? "a" : "b", "text": "가가",
                    "x": x, "y": 40, "width": 70, "height": 80,
                    "fontSize": font, "lineHeight": font * 1.4, "sourceFontSize": font,
                    "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": sourceOnly,
                    "balancedColumn": false, "paddingTop": 0, "paddingBottom": 0,
                    "paddingLeft": 0, "paddingRight": 0, "sourceFrame": [0, 0, 240, 180],
                    "sourceBounds": sourceBounds, "balloonInterior": balloon]
                return try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                    from: JSONSerialization.data(withJSONObject: value))
            }
            return NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
                viewport: size, items: items)
        }
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.colorMode = .white
        func prepare(_ layout: NativeTranslationLayout) throws -> NativeTranslationRenderer.PreparedRender {
            try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
                settings: settings, collectDiagnostics: true)
        }
        let baseline = try prepare(fixture(sourceOnly: true))
        let candidate = try prepare(fixture(sourceOnly: false))
        let data = try #require(candidate.diagnosticData)
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let observations = try #require(report["cards"] as? [[String: Any]])
        #expect(observations.count == 2 && observations.allSatisfy { $0["cohortLayoutChanged"] as? Bool == true })
        #expect(observations.allSatisfy { $0["cohortOriginalStyleUnknown"] as? Bool == true })
        #expect(candidate.cards.map { $0.item.id } == ["a", "b"])
        #expect(abs(candidate.cards[1].finalFontSize / candidate.cards[0].finalFontSize - 2) < 1e-7)
        for (before, after) in zip(baseline.cards, candidate.cards) {
            #expect(before.item.text == after.item.text)
            #expect(before.sourcePlateRect == after.sourcePlateRect && before.textBoxClip == after.textBoxClip)
            #expect(before.textBoxBackgroundClip == after.textBoxBackgroundClip && before.background == after.background)
            #expect(before.style.foreground == after.style.foreground && before.style.outline == after.style.outline)
            #expect(abs(before.style.outlineWidth / before.finalFontSize - after.style.outlineWidth / after.finalFontSize) < 1e-7)
            #expect(after.typography.fits && after.typography.visibleUTF16Range.length == after.item.text.utf16.count)
        }
        func backing(_ plan: NativeTranslationRenderer.PreparedRender, snap: CGFloat?) throws -> [UInt8] {
            let c = try #require(CGContext(data: nil, width: 480, height: 360, bitsPerComponent: 8,
                bytesPerRow: 1920, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            c.clear(CGRect(x: 0, y: 0, width: 480, height: 360))
            c.translateBy(x: 0, y: 360); c.scaleBy(x: 2, y: -2)
            NativeTranslationRenderer.withWorkerGraphicsContext(c) {
                for card in plan.cards {
                    NativeTranslationRenderer.draw(card, context: c, opacity: 1,
                        paintsText: false, paintsSourcePanels: false, pixelSnapScale: snap)
                }
            }
            let bytes = try #require(c.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: 480 * 360 * 4))
        }
        for snap: CGFloat? in [nil, 1.75] { #expect(try backing(baseline, snap: snap) == backing(candidate, snap: snap)) }
        let negative = try prepare(fixture(sourceOnly: false, unverified: true))
        #expect(negative.cards.allSatisfy { $0.textPaintDomain == nil })
    }

    @Test func tiledTextDomainCertificateSeparatesObservedModelAndUnknown() throws {
        let grid = NativeTranslationRenderer.TextDomainGrid(bounds: CGRect(x: 0, y: 0, width: 80, height: 60),
            width: 160, height: 120, pdfDeviceScale: 1.75)
        func certificate(mode: Int, clipped: Bool = false) throws -> NativeTranslationRenderer.TextDomainCertificate {
            var work = 1_000_000
            return try NativeTranslationRenderer.certifyTextDomainTiled(grid: grid, remainingWork: &work,
                maximumScratchBytes: 32 * 1024 * 1024, evidence: { _, tile in
                    (0..<tile.rowCount).map { _ in
                        let full = [UInt8](repeating: 255, count: grid.width)
                        let empty = [UInt8](repeating: 0, count: grid.width)
                        return .init(observedSafeAlpha: mode == 0 ? full : empty,
                            modelSafeAlpha: mode == 1 ? full : empty,
                            supportKnown: mode == 2 ? empty : full,
                            protectionAlpha: mode == 3 ? full : empty,
                            protectionKnown: mode == 2 ? empty : full,
                            peerUnionAlpha: mode == 4 ? full : empty, peerKnown: full,
                            ownBaselineAlpha: empty)
                    }
                }, paintRaw: { c, _ in
                    c.setFillColor(UIColor.black.cgColor)
                    c.fill(CGRect(x: 10.25, y: 20.5, width: 30, height: 12))
                }, paintCandidate: { c, _ in
                    if clipped { c.clip(to: CGRect(x: 0, y: 0, width: 15, height: 60)) }
                    c.setFillColor(UIColor.black.cgColor)
                    c.fill(CGRect(x: 10.25, y: 20.5, width: 30, height: 12))
                })
        }
        let observed = try certificate(mode: 0)
        #expect(observed.verdict == .observedPass && observed.lostAlphaPixels == 0)
        #expect(try certificate(mode: 1).verdict == .modelConditional)
        #expect(try certificate(mode: 2).verdict == .unknown)
        #expect(try certificate(mode: 3).verdict == .rejected)
        #expect(try certificate(mode: 4).verdict == .rejected)
        #expect(try certificate(mode: 0, clipped: true).verdict == .rejected)
    }

    @Test func cohortCallerDoesNotManufactureSpaceOrMergeOwners() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.colorMode = .white
        let size = CGSize(width: 400, height: 200)
        let a = try descriptor(id: "a", box: CGRect(x: 40, y: 40, width: 100, height: 70),
            source: CGRect(x: 40, y: 40, width: 100, height: 70), size: size)
        let b = try descriptor(id: "b", box: CGRect(x: 200, y: 40, width: 100, height: 70),
            source: CGRect(x: 200, y: 40, width: 100, height: 70), size: size)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
            viewport: size, items: [a, b])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: settings, collectDiagnostics: true)
        #expect(plan.cards.map { $0.item.id } == ["a", "b"])
        #expect(plan.cards.allSatisfy { $0.textPaintDomain == nil })
        let data = try #require(plan.diagnosticData)
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cards = try #require(report["cards"] as? [[String: Any]])
        #expect(cards.allSatisfy { $0["cohortLayoutChanged"] as? Bool == false })
    }

    @Test func keepAllEmergencyTransportsInputOwnershipAcrossGeneratedBreaks() throws {
        let text = "가나다라 마바사아 자차카타"
        var style = NativeTranslationTypography.Style(fontSize: 12, lineHeight: 16)
        style.horizontalWhitespace = .preWrap
        style.horizontalWrapping = .keepAllWithEmergency
        let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 28, height: 240), style: style)
        #expect(layout.shapedText != text)
        let ownership = try #require(layout.sourceUTF16Ownership)
        #expect(ownership.count == layout.shapedText.utf16.count)
        #expect(ownership.filter { $0.length > 0 }.map(\.location) == Array(0..<text.utf16.count))
        let rows = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: layout, originalText: text))
        #expect(rows.count > 1)
        #expect(rows.allSatisfy { $0["sourceUTF16Range"] is [Int] })
        #expect(rows.dropLast().allSatisfy { $0["tokenCutAfterRowProxy"] is Bool })
    }

    @Test func observedSourcePaintIsIndependentFromPanelBackground() throws {
        let canvas = CGSize(width: 400, height: 200)
        let c = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
            bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(NativeTranslationRenderer.color([227, 241, 236]))
        c.fill(CGRect(origin: .zero, size: canvas))
        c.textMatrix = .identity; c.textPosition = CGPoint(x: 85, y: 142)
        let attributes: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil),
            kCTForegroundColorAttributeName: NativeTranslationRenderer.color([255, 255, 255]),
            kCTStrokeColorAttributeName: NativeTranslationRenderer.color([230, 110, 20]),
            kCTStrokeWidthAttributeName: -5]
        CTLineDraw(CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "HHO" as CFString, attributes as CFDictionary)!), c)
        let source = try #require(c.makeImage())
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.colorMode = .white
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: fixture(),
            image: UIImage(cgImage: source), settings: settings, collectDiagnostics: true)
        let card = try #require(plan.cards.first)
        let ink = try #require(NativeTranslationRenderer.rgb(card.style.foreground))
        let stroke = try #require(NativeTranslationRenderer.rgb(card.style.outline))
        #expect(NativeTranslationRenderer.textBoxFillContrast(ink,
            panel: try #require(NativeTranslationRenderer.rgb(card.background))) >= 4.5)
        #expect(zip(stroke, [230.0, 110.0, 20.0]).allSatisfy { abs($0 - $1) <= 8 })
        #expect(stroke != NativeTranslationRenderer.rgb(card.background))
        let diagnosticData = try #require(plan.diagnosticData)
        let diagnostics = try #require(JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any])
        let cards = try #require(diagnostics["cards"] as? [[String: Any]])
        let observed = try #require(cards.first?["sourcePaintModel"] as? [String: Any])
        let forecast = try #require(cards.first?["sourcePaintPrediction"] as? [String: Any])
        let originalInk = try #require(NativeSourceColorSampler.rgb(forecast["foreground"]))
        #expect(zip(originalInk, [255.0, 255.0, 255.0]).allSatisfy { abs($0 - $1) <= 8 })
        #expect(forecast["readabilityColorOverride"] as? Bool == true)
        #expect(observed["sourceFullPenWidthPixels"] is NSNull)
        #expect(observed["weight"] is NSNull && observed["slant"] is NSNull)
    }

    @Test func generatedBreakOwnershipRequiresExactScalarTransport() throws {
        let source = "가가😀e\u{301} 나"
        let displayed = "가\n가😀\ne\u{301} 나"
        let ledger = try #require(NativeTranslationTypography.insertedLFOwnership(source: source, displayed: displayed))
        #expect(ledger.count == displayed.utf16.count)
        #expect(ledger.filter { $0.length == 0 }.map(\.location) == [1, 4])
        #expect(ledger.filter { $0.length == 1 }.map(\.location) == Array(0..<source.utf16.count))
        for invalid in ["가😀e\u{301} 나", "가가😀é 나", "가가😀e\u{301}나", "가가😀e\u{301} 다"] {
            #expect(NativeTranslationTypography.insertedLFOwnership(source: source, displayed: invalid) == nil)
        }
        #expect(NativeTranslationTypography.insertedLFOwnership(source: "가\n나", displayed: "가\n나") == nil)
        #expect(NativeTranslationTypography.insertedLFOwnership(source: "가\r\n나", displayed: "가\n나") == nil)
    }

    @Test(arguments: [CGFloat(1), CGFloat(1.75), CGFloat(3)])
    func independentTextDomainPreservesErasureAndSupportsNativePDF(deviceScale: CGFloat) throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.colorMode = .white
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: fixture(), image: nil, settings: settings)
        var card = try #require(plan.cards.first)
        let bounds = CGRect(origin: .zero, size: plan.layout.viewport)
        let originalBacking = card.sourcePlateRect
        card.item.x = 240; card.item.y = 40; card.item.width = 100; card.item.height = 70
        card.item.paddingLeft = 0; card.item.paddingRight = 0
        card.item.paddingTop = 0; card.item.paddingBottom = 0
        card.style.fontSize = 18; card.style.lineHeight = 22
        card.style.foreground = NativeTranslationRenderer.color([230, 110, 20])
        card.style.outline = NativeTranslationRenderer.color([255, 255, 255])
        card.style.outlineWidth = 2
        card.typography = NativeTranslationTypography.layout(text: card.item.text, in: card.item.contentRect.size, style: card.style)
        let domain = try #require(NativeTranslationRenderer.TextPaintDomain(rect: CGRect(x: 230, y: 30, width: 120, height: 100),
            polygon: [], within: bounds))
        let output = CGSize(width: 800, height: 400)
        func raster(_ value: NativeTranslationRenderer.Card, mode: Int) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8,
                bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.clear(CGRect(origin: .zero, size: output))
            context.translateBy(x: 0, y: 400); context.scaleBy(x: 2, y: -2)
            if mode == 3 {
                NativeTranslationRenderer.draw(value, context: context, opacity: 1,
                    paintsText: false, paintsSourcePanels: false, pixelSnapScale: deviceScale)
                NativeTranslationRenderer.draw(value, context: context, opacity: 1,
                    paintsBackground: false, paintsSourcePanels: false, pixelSnapScale: deviceScale)
            } else {
                NativeTranslationRenderer.draw(value, context: context, opacity: 1,
                    paintsBackground: mode != 0, paintsText: mode != 1,
                    paintsSourcePanels: false, pixelSnapScale: deviceScale)
            }
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: bytes, count: 800 * 400 * 4))
        }
        let oldText = try raster(card, mode: 0)
        #expect(stride(from: 3, to: oldText.count, by: 4).allSatisfy { oldText[$0] == 0 })
        let oldBacking = try raster(card, mode: 1)
        card.textPaintDomain = domain
        let expanded = try raster(card, mode: 0)
        #expect(stride(from: 3, to: expanded.count, by: 4).contains { expanded[$0] > 0 })
        #expect(try raster(card, mode: 1) == oldBacking)
        #expect(try raster(card, mode: 2) == raster(card, mode: 3))
        #expect(card.sourcePlateRect == originalBacking)
        #expect(NativeTranslationRenderer.finalPaintBounds(cards: [card], glossCards: [], gloss: .init(), settings: settings).contains(domain.rect))
        for y in 0..<400 { for x in 0..<800 where expanded[(y * 800 + x) * 4 + 3] > 0 {
            #expect(domain.rect.contains(CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)))
        } }
        let pdf = try NativeTranslationPDFCapture.captureDocument(bounds: bounds, pixels: output,
            deviceScale: deviceScale, alignsToLogicalBounds: true) { context in
            NativeTranslationRenderer.draw(card, context: context, opacity: 1,
                paintsBackground: false, paintsSourcePanels: false, pixelSnapScale: deviceScale)
        }
        let image = try NativeTranslationPDFCapture.rasterize(data: pdf.data, pixels: output)
        let rgba = try NativeSourcePixelReader.draw(image: image, x: 0, y: 0, sourceWidth: 800, sourceHeight: 400,
            width: 800, height: 400)
        #expect(stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] > 0 })
        #expect(NativeTranslationRenderer.TextPaintDomain(rect: CGRect(x: 390, y: 0, width: 20, height: 10), polygon: [], within: bounds) == nil)
        #expect(NativeTranslationRenderer.TextPaintDomain(rect: domain.rect,
            polygon: [CGPoint(x: CGFloat.nan, y: 0), .zero, CGPoint(x: 1, y: 1)], within: bounds) == nil)
    }

    @Test func committedRowMetricsUsePaintedBaselinesAndComposedCharacters() throws {
        let text = "A😀\ne\u{301}\n가"
        let style = NativeTranslationTypography.Style(fontSize: 12, lineHeight: 16,
            optimizesKoreanWrapping: false, alignsToTop: true, strictLineBreak: true)
        let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 120, height: 120), style: style)
        let before = layout.glyphBounds
        let origin = CGPoint(x: 17.25, y: 21.125)
        let rows = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: layout,
            originalText: text, origin: origin, pixelSnapScale: 1.75))
        #expect(rows.count == 3)
        #expect(rows.compactMap { $0["graphemeCount"] as? Int } == [2, 1, 1])
        #expect(rows.compactMap { $0["scalarCount"] as? Int } == [2, 2, 1])
        #expect(rows.compactMap { $0["singleHangulLetterRow"] as? Bool } == [false, false, true])
        #expect(rows.allSatisfy { $0["endsInsideSourceTokenProxy"] as? Bool == false })
        let runs = NativeTranslationTypography.diagnosticRuns(layout: layout)
        for (row, run) in zip(rows, runs) {
            let frame = try #require(run["frameSize"] as? [Double])
            let point = try #require(run["origin"] as? [Double])
            let offset = try #require(run["layoutOffset"] as? [Double])
            let shift = try #require(run["lineOffset"] as? [Double])
            let baseline = try #require(row["unsnappedBaseline"] as? [Double])
            #expect(abs(baseline[1] - (Double(origin.y) + frame[1] - point[1] + offset[1] + shift[1])) < 0.000001)
            let snapped = NativeTextPaintGeometry.paintOrigin(CGPoint(x: baseline[0], y: baseline[1]), deviceScale: 1.75)
            let actual = try #require(row["paintedBaseline"] as? [Double])
            #expect(actual == snapped.map { [Double($0.x), Double($0.y)] })
        }
        #expect(layout.glyphBounds == before)
        #expect(JSONSerialization.isValidJSONObject(rows))
    }

    @Test func rowWordCutsFollowVerifiedOwnershipAndLeaveUnknownUnmeasured() throws {
        let style = NativeTranslationTypography.Style(fontSize: 12, lineHeight: 16,
            optimizesKoreanWrapping: false, alignsToTop: true, strictLineBreak: true)
        let available = CGSize(width: 120, height: 120)
        var generated = NativeTranslationTypography.layout(text: "가\n나", in: available, style: style)
        generated.sourceUTF16Ownership = [NSRange(location: 0, length: 1),
            NSRange(location: 1, length: 0), NSRange(location: 1, length: 1)]
        let mapped = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: generated, originalText: "가나"))
        #expect(mapped.compactMap { $0["endsInsideSourceTokenProxy"] as? Bool } == [true, false])
        #expect(mapped.compactMap { $0["tokenCutAfterRowProxy"] as? Bool } == [true, false])
        generated.sourceUTF16Ownership = nil
        let unknown = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: generated, originalText: "가나"))
        #expect(unknown.allSatisfy { $0["endsInsideSourceTokenProxy"] is NSNull })
        let explicit = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: generated, originalText: "가\n나"))
        #expect(explicit.compactMap { $0["endsInsideSourceTokenProxy"] as? Bool } == [false, false])
        generated.sourceUTF16Ownership = [NSRange(location: 40, length: 1)]
        let invalid = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: generated, originalText: "가나"))
        #expect(invalid.allSatisfy { $0["endsInsideSourceTokenProxy"] is NSNull })
        var truncated = NativeTranslationTypography.layout(text: "가", in: available, style: style)
        truncated.sourceUTF16Ownership = [NSRange(location: 0, length: 1)]
        let truncatedRows = try #require(NativeTranslationTypography.horizontalRowMetrics(layout: truncated, originalText: "가나"))
        #expect(truncatedRows[0]["endsInsideSourceTokenProxy"] as? Bool == true)
        #expect(truncatedRows[0]["tokenCutAfterRowProxy"] as? Bool == false)
        let vertical = NativeTranslationTypography.layout(text: "가나", in: available,
            style: .init(fontSize: 12, vertical: true))
        #expect(NativeTranslationTypography.horizontalRowMetrics(layout: vertical, originalText: "가나") == nil)
    }

    @Test(arguments: [[240, 235, 220], [20, 30, 40], [115, 55, 135]])
    func replacementSamplesSurroundingsNotSourceInk(channels: [Int]) throws {
        let size = CGSize(width: 400, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            renderer.cgContext.setFillColor(NativeTranslationRenderer.color(channels.map { CGFloat($0) }))
            renderer.cgContext.fill(CGRect(origin: .zero, size: size))
            renderer.cgContext.setFillColor(UIColor.magenta.cgColor)
            renderer.cgContext.fill(CGRect(x: 80, y: 40, width: 80, height: 60))
        }
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.preserveSourceColors = true
        settings.inpaintingEnabled = true
        settings.opacity = 0.2
        var stages: [String] = []
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: fixture(), image: image,
            settings: settings, collectDiagnostics: true, recordStage: { stages.append($0) })
        let card = try #require(plan.cards.first)
        let rgb = try #require(card.background.components).prefix(3).map { Int(($0 * 255).rounded()) }
        #expect(rgb == channels)
        #expect(card.drawsPanel)
        #expect(card.sourceBackgroundKind == "solid-text-box")
        #expect(card.sourcePlateRect.contains(CGRect(x: 80, y: 40, width: 80, height: 60)))
        #expect(plan.restoration.patches.isEmpty && plan.sourcePatches.isEmpty)
        #expect(stages == ["native.solidTextBoxes"])
        #expect(!settings.usesSourceInpainting && settings.renderedBackgroundOpacity == 1)
        let rendered = try NativeTranslationRenderer.finishPreparedSynchronously(plan)
        #expect(rendered.renderedItemCount == 1)
        let pixel = try pixelRGB(rendered.image, x: 80, y: 40)
        #expect(zip(pixel, channels).allSatisfy { abs($0 - $1) <= 1 })
        #expect(try pixelRGB(rendered.image, x: 5, y: 5) == channels)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2), CGFloat(3)])
    func nativePDFSolidPanelMatchesBitmapEdges(deviceScale: CGFloat) throws {
        let size = CGSize(width: 64, height: 64)
        let output = CGSize(width: 256, height: 256)
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.colorMode = .white
        for origin: CGFloat in [10, 10.25] {
            let value: [String: Any] = [
                "id": "neutral-panel", "text": "A", "x": origin, "y": origin,
                "width": 12, "height": 8, "fontSize": 8, "lineHeight": 10,
                "fontScript": "latin", "wrappingScript": "latin", "sourceTextOnly": false,
                "sourceBounds": [origin / 64, origin / 64, 12.0 / 64, 8.0 / 64],
                "sourceFrame": [0, 0, 64, 64]
            ]
            let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: value))
            let layout = NativeTranslationLayout(imageSize: size,
                sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: [item])
            let bitmap = try NativeTranslationRenderer.renderSynchronously(
                layout: layout, image: nil, settings: settings,
                scale: 4, composeSource: false, outputPixelSize: output)
            let pdf = try NativeTranslationRenderer.renderPDFSynchronously(
                layout: layout, image: nil, settings: settings, scale: 4,
                outputPixelSize: output, collectDiagnostics: true, pdfDeviceScale: deviceScale)
            #expect(pdf.renderedItemCount == 1)
            #expect(pdf.sourcePatches.isEmpty && pdf.sourceRestorationRects.isEmpty)
            let data = try #require(pdf.diagnosticData)
            let diagnostic = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let cards = try #require(diagnostic["cards"] as? [[String: Any]])
            let saved = try #require(cards.first)
            #expect(saved["id"] as? String == "neutral-panel")
            let owner = try #require(saved["sourceOwner"] as? [NSNumber])
            let panel = try #require(saved["frame"] as? [NSNumber])
            #expect(owner.map(\.doubleValue) == [Double(origin), Double(origin), 12, 8])
            #expect(panel.map(\.doubleValue) == [Double(origin - 2), Double(origin - 2), 16, 12])
            let image = UIImage(cgImage: try NativeTranslationPDFCapture.rasterize(data: pdf.exportPDFData, pixels: output))
            let left = Int((origin - 2) * 4)
            let right = Int((origin + 14) * 4) - 1
            let y = Int((origin + 2) * 4)
            for x in [left, right] {
                #expect(try pixelRGB(bitmap.overlayImage, x: x, y: y) == [255, 255, 255])
                let actual = try pixelRGB(image, x: x, y: y)
                #expect(actual.allSatisfy { $0 >= 250 })
            }
            for x in [left - 2, right + 2] {
                #expect(try pixelRGB(image, x: x, y: y) == [0, 0, 0])
            }
        }
    }

    @Test(arguments: [false, true])
    func panelSamplingPreservesProjectedSourceGeometry(flat: Bool) throws {
        var bytes = Data()
        for y in 0..<12 {
            for x in 0..<16 {
                bytes.append(contentsOf: flat ? [73, 121, 39, 255] : [UInt8(x * 17), UInt8(y * 23), 31, 255])
            }
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let source = try #require(CGImage(width: 16, height: 12, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 64, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let frame = CGRect(x: -12, y: 7, width: 16, height: 12)
        let fields: [String: Any] = [
            "id": "neutral-sampling", "text": "A", "x": -7.25, "y": 11.75,
            "width": 4, "height": 2, "fontSize": 18, "lineHeight": 22,
            "fontScript": "latin", "wrappingScript": "latin", "sourceTextOnly": false,
            "sourceBounds": [4.75 / 16, 4.75 / 12, 4.0 / 16, 2.0 / 12],
            "sourceFrame": [-12, 7, 16, 12]
        ]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: fields))
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 16, height: 12),
            sourceRect: frame, viewport: frame.size, items: [item])
        let outer = CGRect(x: -10.25, y: 8.75, width: 10, height: 8)
        #expect(NativeTextBoxSourceProjection.project(outer, frame: frame, sourceSize: layout.imageSize)
            == CGRect(x: 1.75, y: 1.75, width: 10, height: 8))
        let reference = try #require(CGContext(data: nil, width: 96, height: 96,
            bitsPerComponent: 8, bytesPerRow: 384, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        reference.interpolationQuality = .low
        reference.draw(source, in: CGRect(x: -1.75 * 9.6, y: 96 - 10.25 * 12, width: 16 * 9.6, height: 12 * 12))
        let p = try #require(reference.data).assumingMemoryBound(to: UInt8.self)
        var bins: [Int: [[Double]]] = [:]
        var expectedBytes: [UInt8] = []
        for y in 0..<96 {
            for x in 0..<96 {
                let offset = (y * 96 + x) * 4
                expectedBytes += [p[offset + 2], p[offset + 1], p[offset], p[offset + 3]]
                let px = 1.75 + (Double(x) + 0.5) * 10 / 96
                let py = 1.75 + (Double(y) + 0.5) * 8 / 96
                if px >= 4.75 && px < 8.75 && py >= 4.75 && py < 6.75 { continue }
                let rgb = [Double(p[offset + 2]), Double(p[offset + 1]), Double(p[offset])]
                let key = Int(rgb[0]) / 32 * 64 + Int(rgb[1]) / 32 * 8 + Int(rgb[2]) / 32
                bins[key, default: []].append(rgb)
            }
        }
        let key = try #require(bins.keys.sorted().max { bins[$0]!.count < bins[$1]!.count })
        let bin = try #require(bins[key])
        // Independent CGContext capture still proves the projected pixels are
        // identical. Only the declared estimator changes: mode-bin median,
        // not the previous mean which mixes antialiased outline halos.
        let expected = (0..<3).map { channel in
            let values = bin.map { $0[channel] }.sorted()
            let middle = values.count / 2
            return (values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]).rounded()
        }
        let reader = NativeSourcePixelReader(image: source, preservesSamplingGeometry: true)
        defer { reader.release() }
        let sampledBytes = try reader.read(x: 1.75, y: 1.75, sourceWidth: 10, sourceHeight: 8, width: 96, height: 96)
        let differingPixels = (0..<(96 * 96)).filter { i in
            let start = i * 4
            return sampledBytes[start..<(start + 4)] != expectedBytes[start..<(start + 4)]
        }.count
        let sampled = try NativeTranslationRenderer.textBoxSurroundingColor(
            item: item, layout: layout, source: source, reader: reader, excluded: [])
        let actual = try #require(sampled)
        #expect(differingPixels == 0)
        #expect(actual == expected)
    }

    @Test func preparationRejectsOverflowingSourceScale() throws {
        let original = try fixture()
        let layout = NativeTranslationLayout(imageSize: original.imageSize,
            sourceRect: CGRect(x: 0, y: 0, width: 1e-308, height: original.sourceRect.height),
            viewport: original.viewport, items: original.items)
        do {
            _ = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
                settings: ReaderTranslationSettings.defaultOverlay)
            Issue.record("Overflowing source scale must reject before ROI projection")
        } catch NativeTranslationRenderer.RenderError.invalidGeometry {
            // Expected fail-closed entrypoint, before owner/ROI pixel conversion.
        }
    }

    @Test func sourceProjectionRejectsDerivedOverflowAndReconstructedSpan() {
        let size = CGSize(width: 64, height: 64)
        let large = CGFloat.greatestFiniteMagnitude
        let frame = CGRect(x: -0.49 * large, y: 0, width: large, height: 64)
        let owner = CGRect(x: frame.minX + large * 0.25, y: 10, width: large * 0.5, height: 20).intersection(frame)
        let margin = max(owner.width, owner.height) * 1.2
        let roi = owner.insetBy(dx: -margin, dy: -margin).intersection(frame)
        #expect(NativeTextBoxSourceProjection.project(roi, frame: frame, sourceSize: size) == nil)
        let roundedFrame = CGRect(x: 9_007_199_254_740_992, y: 0, width: 3, height: 64)
        let reconstructed = roundedFrame.intersection(roundedFrame)
        #expect(NativeTextBoxSourceProjection.project(reconstructed, frame: roundedFrame, sourceSize: size) == nil)
    }

    @Test func sourceProjectionPreservesOrdinarySamplingCoordinates() throws {
        let frame = CGRect(x: 12, y: -7, width: 430, height: 932)
        let roi = CGRect(x: 40, y: 50, width: 172, height: 142)
        let size = CGSize(width: 64, height: 64)
        let actual = try #require(NativeTextBoxSourceProjection.project(roi, frame: frame, sourceSize: size))
        let sx = size.width / frame.width, sy = size.height / frame.height
        #expect(actual == CGRect(x: (roi.minX - frame.minX) * sx, y: (roi.minY - frame.minY) * sy,
                                width: roi.width * sx, height: roi.height * sy))
        #expect(Int(min(320, max(8, ceil(actual.width)))) == 26)
        #expect(Int(min(320, max(8, ceil(actual.height)))) == 10)
    }

    @Test func hiddenOverlayDoesNotCoverOriginal() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.visible = false
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: fixture(), image: nil, settings: settings)
        #expect(plan.cards.isEmpty && plan.sourcePatches.isEmpty)
    }

    @Test func diagnosticsReportActualFittedPanelState() throws {
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: fixture(), image: nil,
            settings: ReaderTranslationSettings.defaultOverlay, collectDiagnostics: true)
        let data = try #require(plan.diagnosticData)
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(record["diagnosticsVersion"] as? Int == 2)
        let records = try #require(record["cards"] as? [[String: Any]])
        let saved = try #require(records.first)
        let card = try #require(plan.cards.first)
        #expect(saved["fontSize"] as? Double == Double(card.style.fontSize))
        #expect(saved["background"] as? [Double] == NativeTranslationRenderer.rgb(card.background))
        #expect(saved["foreground"] as? [Double] == NativeTranslationRenderer.rgb(card.style.foreground))
        #expect(saved["visibleUTF16Range"] as? [Int] ==
            [card.typography.visibleUTF16Range.location, card.typography.visibleUTF16Range.length])
        #expect(saved["shapedUTF16Length"] as? Int == card.typography.shapedText.utf16.count)
        #expect(saved["localGlyphBounds"] as? [[Double]] != nil)
        #expect(saved["fits"] as? Bool == card.typography.fits)
    }

    @Test func containmentDoesNotBridgeDisconnectedRows() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let surface = NativeTextBoxContainment.Surface(rect: bounds,
            spans: [(0, 30), (70, 100)], color: nil)
        #expect(!surface.certifiedSpans && surface.polygon.isEmpty)
        #expect(surface.inscribed(near: bounds, within: bounds) == nil)
        let frame = CGRect(x: 5, y: 5, width: 20, height: 20)
        #expect(surface.centered(frame: frame, owner: frame, within: bounds,
            otherOwners: [], otherTextFrames: [], pixelSize: CGSize(width: 1, height: 1)) == frame)
    }

    @Test func connectedConcaveSurfaceKeepsItsNarrowBands() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let surface = NativeTextBoxContainment.Surface(rect: bounds,
            spans: [(0, 100), (0, 30), (0, 30), (0, 100)], color: nil)
        #expect(surface.certifiedSpans && !surface.polygon.isEmpty)
        let fitted = try #require(surface.inscribed(near: bounds, within: bounds))
        #expect(fitted.minX >= 0 && fitted.maxX <= 30)
    }

    @Test func fullCapacityUsesSafePeerEdgeBeforeShrinking() throws {
        let surface = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 200, height: 100),
            spans: Array(repeating: (CGFloat.zero, CGFloat(40)), count: 6)
                + Array(repeating: (CGFloat.zero, CGFloat(200)), count: 4), color: nil)
        let wanted = CGRect(x: 80, y: 32.7, width: 100, height: 20)
        let right = CGRect(x: 150, y: 60, width: 30, height: 40)
        let left = CGRect(x: 0, y: 60, width: 50, height: 40)
        for peers in [[right], [right, left], [left, right]] {
            let fitted = try #require(surface.inscribed(near: wanted, within: surface.rect, protectedRects: peers))
            #expect(fitted == CGRect(x: 50, y: 60, width: 100, height: 20))
            #expect(peers.allSatisfy { !fitted.intersects($0) })
        }
        let blocked = try #require(surface.inscribed(near: wanted, within: surface.rect,
            protectedRects: [right, CGRect(x: 0, y: 60, width: 51, height: 40)]))
        #expect(abs(blocked.width - 38.6) < 1e-9)
    }

    @Test func centeringRejectsRawNegativeOwnerSize() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let surface = NativeTextBoxContainment.Surface(rect: bounds,
            spans: [(0, 100), (0, 100)], color: nil)
        let frame = CGRect(x: 10, y: 10, width: 20, height: 20)
        let invalidOwner = CGRect(x: 40, y: 40, width: -10, height: 10)
        #expect(surface.centered(frame: frame, owner: invalidOwner, within: bounds,
            otherOwners: [], otherTextFrames: [], pixelSize: CGSize(width: 1, height: 1)) == frame)
    }

    @Test(arguments: [false, true])
    func waistCapacityUsesFittedFontNotArea(explicitRows: Bool) throws {
        let size = CGSize(width: 100, height: 100)
        let bounds = CGRect(origin: .zero, size: size)
        let spans = Array(repeating: (CGFloat(40), CGFloat(60)), count: 3)
            + Array(repeating: (CGFloat.zero, CGFloat(100)), count: 3)
            + Array(repeating: (CGFloat(40), CGFloat(60)), count: 4)
        let surface = NativeTextBoxContainment.Surface(rect: bounds, spans: spans, color: nil)
        let text = explicitRows ? "가가\n가가\n가가\n가가" : "가가가가 가가가가"
        let value: [String: Any] = [
            "id": "neutral-waist", "text": text, "x": 10, "y": 10,
            "width": 80, "height": 80, "fontSize": 12, "lineHeight": 14.4,
            "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": false,
            "sourceBounds": [0.45, 0.45, 0.1, 0.1], "sourceFrame": [0, 0, 100, 100],
            "balloonInterior": ["rect": [0, 0, 1, 1], "center": [0.5, 0.5],
                "spans": spans.flatMap { [Double($0.0 / 100), Double($0.1 / 100)] }, "contourVerified": true]
        ]
        let requested = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: bounds, viewport: size, items: [requested])
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.colorMode = .white
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: settings, collectDiagnostics: true)
        let actual = try #require(plan.cards.first)
        var baseline = actual
        // This isolates the waist search with its authored available backing.
        // The final production erasure rectangle is no longer the layout envelope.
        baseline.sourcePlateOwnerRect = bounds
        baseline.straightenedPanelRect = bounds
        let oldFrame = try #require(surface.inscribed(near: requested.rect, within: baseline.sourcePlateRect))
        baseline.item.x = oldFrame.minX; baseline.item.y = oldFrame.minY
        baseline.item.width = oldFrame.width; baseline.item.height = oldFrame.height
        baseline.style.fontSize = requested.fontSize; baseline.style.lineHeight = requested.lineHeight
        baseline.style.tracking = -requested.fontSize * 0.012
        baseline.typography = NativeTranslationRenderer.fitted(text: text,
            size: baseline.item.contentRect.size, style: &baseline.style)
        baseline.finalFontSize = baseline.style.fontSize
        var cards = [baseline]
        let owner = CGRect(x: 45, y: 45, width: 10, height: 10)
        try NativeTranslationRenderer.improveWaistTextBoxes(cards: &cards, surfaces: [requested.id: surface],
            requested: [requested.id: requested], owners: [requested.id: owner],
            sourceRect: bounds, imageSize: size, pdfDeviceScale: 1)
        let improved = try #require(cards.first)
        #expect(improved.style.fontSize >= baseline.style.fontSize)
        #expect(improved.sourcePlateRect == baseline.sourcePlateRect)
        #expect(improved.typography.fits)
        #expect(improved.typography.visibleUTF16Range.length == text.utf16.count)
        var blocked = [baseline]
        try NativeTranslationRenderer.improveWaistTextBoxes(cards: &blocked, surfaces: [requested.id: surface],
            requested: [requested.id: requested], owners: [requested.id: owner,
                "neutral-peer": CGRect(x: 0, y: 30, width: 100, height: 30)],
            sourceRect: bounds, imageSize: size, pdfDeviceScale: 1)
        #expect(blocked[0].item.rect == baseline.item.rect)
        #expect(blocked[0].style.fontSize == baseline.style.fontSize)
        if !explicitRows {
            #expect(improved.style.fontSize > baseline.style.fontSize)
            #expect(improved.item.width == requested.width)
            #expect(actual.style.fontSize >= improved.style.fontSize)
        }
    }

    @Test(arguments: [45, 80])
    func failedMinimumFontUsesIntermediateWidthCapacity(characters: Int) throws {
        let size = CGSize(width: 100, height: 60)
        let bounds = CGRect(origin: .zero, size: size)
        let spans: [(CGFloat, CGFloat)] = [(0, 100), (20, 80), (20, 80), (20, 80), (20, 80), (38, 62)]
        let surface = NativeTextBoxContainment.Surface(rect: bounds, spans: spans, color: nil)
        let text = String(repeating: "가", count: characters)
        let value: [String: Any] = [
            "id": "neutral-capacity", "text": text, "x": 0.7, "y": 20,
            "width": 98.6, "height": 40, "fontSize": 5, "lineHeight": 6,
            "paddingLeft": 0, "paddingRight": 0, "paddingTop": 0, "paddingBottom": 0,
            "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": false,
            "sourceBounds": [0.42, 32.0 / 60, 0.16, 12.0 / 60], "sourceFrame": [0, 0, 100, 60],
            "balloonInterior": ["rect": [0, 0, 1, 1], "center": [0.5, 0.5],
                "spans": spans.flatMap { [Double($0.0 / 100), Double($0.1 / 100)] }, "contourVerified": true]
        ]
        let request = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(
            layout: NativeTranslationLayout(imageSize: size, sourceRect: bounds, viewport: size, items: [request]),
            image: nil, settings: ReaderTranslationSettings.defaultOverlay)
        var baseline = try #require(plan.cards.first)
        // Capacity recovery searches the authored envelope, independently of
        // the complete rectangle selected later for source erasure.
        baseline.sourcePlateOwnerRect = bounds
        baseline.straightenedPanelRect = bounds
        let oldFrame = try #require(surface.inscribed(near: request.rect, within: baseline.sourcePlateRect))
        baseline.item.x = oldFrame.minX; baseline.item.y = oldFrame.minY
        baseline.item.width = oldFrame.width; baseline.item.height = oldFrame.height
        baseline.style.fontSize = 5; baseline.style.lineHeight = 6; baseline.style.tracking = -0.06
        baseline.typography = NativeTranslationRenderer.fitted(text: text,
            size: baseline.item.contentRect.size, style: &baseline.style)
        baseline.finalFontSize = baseline.style.fontSize
        #expect(!baseline.typography.fits)
        var cards = [baseline], recovered: Set<String> = []
        let gains = try NativeTranslationRenderer.improveWaistTextBoxes(cards: &cards,
            surfaces: [request.id: surface], requested: [request.id: request], owners: [:],
            sourceRect: bounds, imageSize: size, pdfDeviceScale: 1,
            recordFitRecovery: { recovered.insert($0) })
        #expect(gains.isEmpty)
        #expect(cards[0].style.fontSize == 5)
        #expect(cards[0].sourcePlateRect == baseline.sourcePlateRect)
        if characters == 45 {
            #expect(cards[0].typography.fits)
            #expect(cards[0].typography.visibleUTF16Range.length == text.utf16.count)
            #expect(recovered == [request.id])
            #expect(cards[0].item.width < request.width)
            #expect(cards[0].item.height > baseline.item.height)
        } else {
            #expect(!cards[0].typography.fits)
            #expect(recovered.isEmpty)
            #expect(cards[0].item.rect == baseline.item.rect)
        }
    }

    @Test(arguments: [CGFloat(1), CGFloat(1.75), CGFloat(2)])
    func readabilityPeerInkChecksBothFinalAndRollbackStates(scale: CGFloat) throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        func card(_ id: String, x: CGFloat) throws -> NativeTranslationRenderer.Card {
            let value: [String: Any] = [
                "id": id, "text": "가", "x": Double(x), "y": 20,
                "width": 20, "height": 20, "fontSize": 10, "lineHeight": 12,
                "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": false,
                "sourceBounds": [0, 0, 1, 1], "sourceFrame": [0, 0, 100, 100]
            ]
            let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: value))
            let layout = NativeTranslationLayout(imageSize: bounds.size, sourceRect: bounds,
                viewport: bounds.size, items: [item])
            let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
                settings: ReaderTranslationSettings.defaultOverlay)
            let result = try #require(plan.cards.first)
            #expect(result.typography.fits)
            return result
        }
        let first = try card("neutral-first", x: 20)
        let peer = try card("neutral-peer", x: 60)
        let baseline = [first, peer]
        let pixels = CGSize(width: 100 * scale, height: 100 * scale)
        var colliding = baseline
        colliding[0].item.x = 60
        let rejected = try NativeTranslationRenderer.rejectNewReadabilityPeerInk(cards: &colliding,
            baseline: baseline, changed: [first.item.id], bounds: bounds, pixels: pixels,
            sourceRect: bounds, pdfDeviceScale: 1)
        #expect(rejected == [first.item.id])
        #expect(colliding[0].item.rect == first.item.rect)
        #expect(colliding[0].sourcePlateRect == first.sourcePlateRect)

        var rollback = baseline
        rollback[0].item.x = 60
        rollback[1].item.x = 80
        // Unsupported peer proposal must not hide its eventual baseline ink.
        rollback[1].style.outlineGlow = 1
        let rollbackRejected = try NativeTranslationRenderer.rejectNewReadabilityPeerInk(cards: &rollback,
            baseline: baseline, changed: Set(baseline.map { $0.item.id }), bounds: bounds, pixels: pixels,
            sourceRect: bounds, pdfDeviceScale: 1)
        #expect(rollbackRejected == Set(baseline.map { $0.item.id }))
        #expect(rollback.map { $0.item.rect } == baseline.map { $0.item.rect })

        var safe = baseline
        safe[0].item.x = 25
        #expect(try NativeTranslationRenderer.rejectNewReadabilityPeerInk(cards: &safe,
            baseline: baseline, changed: [first.item.id], bounds: bounds, pixels: pixels,
            sourceRect: bounds, pdfDeviceScale: 1).isEmpty)
        #expect(safe[0].item.x == 25)

        let alreadyOverlapping = [try card("neutral-first", x: 60), peer]
        var unchanged = alreadyOverlapping
        #expect(try NativeTranslationRenderer.rejectNewReadabilityPeerInk(cards: &unchanged,
            baseline: alreadyOverlapping, changed: [first.item.id], bounds: bounds, pixels: pixels,
            sourceRect: bounds, pdfDeviceScale: 1).isEmpty)
        #expect(unchanged.map { $0.item.rect } == alreadyOverlapping.map { $0.item.rect })

        let largeBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let largePixels = CGSize(width: 1000 * scale, height: 1000 * scale)
        var large = first
        large.sourcePlateOwnerRect = largeBounds
        large.textBoxClip = []; large.textBoxBackgroundClip = nil
        var reasons: [String: String] = [:]
        var lone = [large]
        lone[0].item.x = 25
        #expect(try NativeTranslationRenderer.rejectNewReadabilityPeerInk(cards: &lone,
            baseline: [large], changed: [large.item.id], bounds: largeBounds, pixels: largePixels,
            sourceRect: largeBounds, pdfDeviceScale: 1,
            recordRejection: { reasons[$0] = $1 }).isEmpty)
        #expect(reasons.isEmpty && lone[0].item.x == 25)

        var edge = peer
        edge.item.x = 990
        edge.sourcePlateOwnerRect = CGRect(x: 990, y: 0, width: 10, height: 1000)
        edge.textBoxClip = []; edge.textBoxBackgroundClip = nil
        let largeBaseline = [large, edge]
        var safeLarge = largeBaseline
        safeLarge[0].item.x = 25
        #expect(try NativeTranslationRenderer.rejectNewReadabilityPeerInk(cards: &safeLarge,
            baseline: largeBaseline, changed: [large.item.id], bounds: largeBounds, pixels: largePixels,
            sourceRect: largeBounds, pdfDeviceScale: 1,
            recordRejection: { reasons[$0] = $1 }).isEmpty)
        #expect(reasons.isEmpty && safeLarge[0].item.x == 25)

        var collidingLarge = largeBaseline
        collidingLarge[0].item.x = edge.item.x
        #expect(try NativeTranslationRenderer.rejectNewReadabilityPeerInk(cards: &collidingLarge,
            baseline: largeBaseline, changed: [large.item.id], bounds: largeBounds, pixels: largePixels,
            sourceRect: largeBounds, pdfDeviceScale: 1,
            recordRejection: { reasons[$0] = $1 }) == [large.item.id])
        #expect(reasons[large.item.id] == "collision")
        #expect(collidingLarge[0].item.rect == large.item.rect)
        #expect(collidingLarge[1].item.rect == edge.item.rect)
    }

    @Test(arguments: [false, true])
    func fittedButClippedTextCanRecoverAtSameFontWithoutChangingBacking(needsWiderCapacity: Bool) throws {
        let size = CGSize(width: 100, height: needsWiderCapacity ? 120 : 60)
        let bounds = CGRect(origin: .zero, size: size)
        let text = String(repeating: "가", count: needsWiderCapacity ? 14 : 3)
        let value: [String: Any] = [
            "id": "neutral-clip-fit", "text": text, "x": 5, "y": 5,
            "width": needsWiderCapacity ? 8 : 80, "height": needsWiderCapacity ? 110 : 40,
            "fontSize": 6, "lineHeight": 7.2, "paddingLeft": 0, "paddingRight": 0,
            "paddingTop": 0, "paddingBottom": 0, "fontScript": "korean", "wrappingScript": "korean",
            "sourceTextOnly": false, "sourceBounds": [0.05, 0.1, 0.5, 0.3],
            "sourceFrame": [0, 0, 100, Double(size.height)]
        ]
        let request = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout:
            NativeTranslationLayout(imageSize: size, sourceRect: bounds, viewport: size, items: [request]),
            image: nil, settings: ReaderTranslationSettings.defaultOverlay)
        var baseline = try #require(plan.cards.first)
        baseline.item = request
        baseline.sourcePlateOwnerRect = bounds
        baseline.straightenedPanelRect = bounds
        baseline.style.fontSize = 6; baseline.style.lineHeight = 7.2; baseline.style.tracking = -0.072
        baseline.typography = NativeTranslationRenderer.fitted(text: request.text,
            size: request.contentRect.size, style: &baseline.style)
        baseline.finalFontSize = baseline.style.fontSize
        let surfaceBounds = needsWiderCapacity ? CGRect(x: 0, y: 0, width: 100, height: 35) : bounds
        let surface = NativeTextBoxContainment.Surface(rect: surfaceBounds,
            spans: Array(repeating: (CGFloat(70), CGFloat(95)), count: 12), color: nil)
        baseline.textBoxClip = surface.polygon
        #expect(baseline.typography.fits)
        var budget = 8_000_000
        let before = try #require(NativeTranslationRenderer.finalTextClipAudit(baseline,
            pixelScale: CGSize(width: 1, height: 1), pdfDeviceScale: 1, remainingPixels: &budget))
        let beforeModes = try #require(before["modes"] as? [[String: Any]])
        #expect(beforeModes.allSatisfy { ($0["clipLossPixels"] as? Int ?? 0) > 0 })
        var cards = [baseline], recovered: Set<String> = []
        _ = try NativeTranslationRenderer.improveWaistTextBoxes(cards: &cards, surfaces: [request.id: surface],
            requested: [request.id: request], owners: [:], sourceRect: bounds, imageSize: size, pdfDeviceScale: 1,
            confirmedClipLossIDs: [request.id], onlyConfirmedClipLoss: true,
            recordInkRecovery: { recovered.insert($0) })
        #expect(recovered == [request.id])
        #expect(cards[0].sourcePlateRect == baseline.sourcePlateRect)
        #expect(cards[0].style.fontSize == baseline.style.fontSize)
        #expect(cards[0].typography.visibleUTF16Range == NSRange(location: 0, length: text.utf16.count))
        if needsWiderCapacity { #expect(cards[0].item.width > request.width) }
        let after = try #require(NativeTranslationRenderer.finalTextClipAudit(cards[0],
            pixelScale: CGSize(width: 1, height: 1), pdfDeviceScale: 1,
            remainingPixels: &budget, forceMeasurement: true))
        let afterModes = try #require(after["modes"] as? [[String: Any]])
        #expect(afterModes.allSatisfy { ($0["clipLossPixels"] as? Int) == 0 })
        var unchanged = [baseline]
        _ = try NativeTranslationRenderer.improveWaistTextBoxes(cards: &unchanged, surfaces: [request.id: surface],
            requested: [request.id: request], owners: [:], sourceRect: bounds, imageSize: size,
            pdfDeviceScale: 1, onlyConfirmedClipLoss: true)
        #expect(unchanged[0].item.rect == baseline.item.rect)
        var invalidRequest = request
        invalidRequest.fontSize = 1e19
        var invalidCards = [baseline], invalidRecovery: Set<String> = []
        _ = try NativeTranslationRenderer.improveWaistTextBoxes(cards: &invalidCards,
            surfaces: [request.id: surface], requested: [request.id: invalidRequest], owners: [:],
            sourceRect: bounds, imageSize: size, pdfDeviceScale: 1,
            confirmedClipLossIDs: [request.id], onlyConfirmedClipLoss: true,
            recordInkRecovery: { invalidRecovery.insert($0) })
        #expect(invalidRecovery.isEmpty)
        #expect(invalidCards[0].item.rect == baseline.item.rect)
    }

    @Test(arguments: [CGFloat(1), CGFloat(3)])
    func finalClipAuditMeasuresLostInkAndKeepsUnsupportedStatesExplicit(scale: CGFloat) throws {
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: fixture(), image: nil,
            settings: ReaderTranslationSettings.defaultOverlay)
        var card = try #require(plan.cards.first)
        var budget = 8_000_000
        #expect(NativeTranslationRenderer.finalTextClipAudit(card,
            pixelScale: CGSize(width: scale, height: scale), pdfDeviceScale: 1, remainingPixels: &budget) == nil)
        card.textBoxClip = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let report = try #require(NativeTranslationRenderer.finalTextClipAudit(card,
            pixelScale: CGSize(width: scale, height: scale), pdfDeviceScale: 1, remainingPixels: &budget))
        #expect(report["status"] as? String == "measured-within-allocation")
        let modes = try #require(report["modes"] as? [[String: Any]])
        #expect(modes.count == 2)
        for mode in modes {
            #expect((mode["rawOccupiedPixels"] as? Int ?? 0) > 0)
            #expect(mode["clipLossPixels"] as? Int == mode["rawOccupiedPixels"] as? Int)
            #expect((mode["clipLossAlpha"] as? Int ?? 0) > 0)
        }
        var emptyBudget = 0
        let unavailable = try #require(NativeTranslationRenderer.finalTextClipAudit(card,
            pixelScale: CGSize(width: scale, height: scale), pdfDeviceScale: 1, remainingPixels: &emptyBudget))
        #expect(unavailable["status"] as? String == "pixel-budget")
        #expect(unavailable["modes"] == nil)
    }

    @Test func omittedInputDiagnosticsExposeActualSeparatorWithoutChangingRendering() throws {
        let size = CGSize(width: 64, height: 40)
        let bounds = CGRect(origin: .zero, size: size)
        func item(_ id: String, x: CGFloat, ownerX: CGFloat) throws -> NativeTranslationLayoutItem {
            let value: [String: Any] = [
                "id": id, "text": "가가가", "x": x, "y": 10, "width": 18, "height": 19,
                "fontSize": 6.5, "lineHeight": 7.8,
                "paddingLeft": 2, "paddingRight": 2, "paddingTop": 2, "paddingBottom": 2,
                "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": false,
                "sourceBounds": [ownerX / 64, 0.25, 10.0 / 64, 0.45], "sourceFrame": [0, 0, 64, 40]
            ]
            return try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: value))
        }
        let first = try item("neutral-omitted", x: 26, ownerX: 10)
        let second = try item("neutral-peer", x: 28, ownerX: 32)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: bounds, viewport: size, items: [first, second])
        let plain = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: ReaderTranslationSettings.defaultOverlay, collectDiagnostics: false)
        let traced = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: ReaderTranslationSettings.defaultOverlay, collectDiagnostics: true)
        #expect(plain.cards.map { $0.item.id } == traced.cards.map { $0.item.id })
        #expect(plain.cards.map { $0.sourcePlateRect } == traced.cards.map { $0.sourcePlateRect })
        #expect(!traced.cards.contains { $0.item.id == first.id })
        let data = try #require(traced.diagnosticData)
        let diagnostics = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let omissions = try #require(diagnostics["omittedInputs"] as? [[String: Any]])
        let omission = try #require(omissions.first { $0["id"] as? String == first.id })
        #expect(omission["stage"] as? String == "text-space")
        #expect((omission["sourceOwner"] as? [Double]) == [10, 10, 10, 18])
        #expect((omission["separatedPanel"] as? [Double])?.count == 4)
        #expect(omission["sourceSurfacePolygon"] is NSNull)
        #expect(plain.diagnosticData == nil)
    }

    @Test func requestedFontRecoveryExceedsLegacyCeilingWithFrozenBacking() throws {
        let size = CGSize(width: 200, height: 120)
        let bounds = CGRect(origin: .zero, size: size)
        let text = "가가가 가가가"
        let value: [String: Any] = [
            "id": "neutral-request-font", "text": text, "x": 10, "y": 10,
            "width": 180, "height": 96, "fontSize": 16, "lineHeight": 19.2,
            "paddingLeft": 2, "paddingRight": 2, "paddingTop": 2, "paddingBottom": 2,
            "fontScript": "korean", "wrappingScript": "korean", "sourceTextOnly": false,
            "sourceBounds": [0.25, 0.25, 0.5, 0.5], "sourceFrame": [0, 0, 200, 120]
        ]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(
            layout: NativeTranslationLayout(imageSize: size, sourceRect: bounds, viewport: size, items: [item]),
            image: nil, settings: ReaderTranslationSettings.defaultOverlay)
        var baseline = try #require(plan.cards.first)
        baseline.style.fontSize = 6; baseline.style.lineHeight = 7.2; baseline.style.tracking = -0.072
        baseline.typography = NativeTranslationTypography.layout(text: text,
            in: baseline.item.contentRect.size, style: baseline.style)
        baseline.finalFontSize = 6
        #expect(baseline.typography.fits)
        let owner = CGRect(x: 50, y: 30, width: 100, height: 60)
        var ordinary = [baseline]
        #expect(try NativeTranslationRenderer.improveSmallTextBoxes(cards: &ordinary,
            owners: [item.id: owner], sourceRect: bounds, imageSize: size, pdfDeviceScale: 1) == [item.id])
        #expect(ordinary[0].style.fontSize <= 7.75)
        let approved = ordinary
        #expect(try NativeTranslationRenderer.improveSmallTextBoxes(cards: &ordinary,
            owners: [item.id: owner], sourceRect: bounds, imageSize: size, pdfDeviceScale: 1,
            recoverRequestedFont: true) == [item.id])
        #expect(ordinary[0].style.fontSize == 16)
        #expect(ordinary[0].typography.fits)
        #expect(ordinary[0].typography.visibleUTF16Range.length == text.utf16.count)
        #expect(ordinary[0].item.rect == approved[0].item.rect)
        #expect(ordinary[0].sourcePlateRect == approved[0].sourcePlateRect)
        #expect(ordinary[0].background == approved[0].background)
        #expect(try NativeTranslationRenderer.rejectNewReadabilityPeerInk(cards: &ordinary,
            baseline: approved, changed: [item.id], bounds: bounds, pixels: size,
            sourceRect: bounds, pdfDeviceScale: 1).isEmpty)
        var blocked = approved
        #expect(try NativeTranslationRenderer.improveSmallTextBoxes(cards: &blocked,
            owners: [item.id: owner, "neutral-peer": approved[0].item.rect],
            sourceRect: bounds, imageSize: size, pdfDeviceScale: 1,
            recoverRequestedFont: true).isEmpty)
        #expect(blocked[0].style.fontSize == approved[0].style.fontSize)
        #expect(blocked[0].typography.visibleUTF16Range == approved[0].typography.visibleUTF16Range)
    }

    @Test func requestedFontSearchPreservesBudgetAbstentionAndLegacyMode() throws {
        let input = neutralSmallTextInput()
        #expect(try #require(NativeSmallFontReadabilityPolicy.search(input)).style.fontSize <= 7.75)
        let aggressive = try #require(NativeSmallFontReadabilityPolicy.search(input, requestedFontSize: 16))
        #expect(aggressive.style.fontSize > 7.75 && aggressive.style.fontSize <= 16)
        #expect(aggressive.layout.visibleUTF16Range.length == input.text.utf16.count)
        #expect(NativeSmallFontReadabilityPolicy.search(input, pixelGuard: { _ in false },
            requestedFontSize: 16) == nil)
        var work = 1
        #expect(NativeSmallFontReadabilityPolicy.search(input, requestedFontSize: 16,
            spendShapeWork: {
                guard work > 0 else { return false }
                work -= 1
                return true
            }) == nil)
        #expect(work == 0)
        #expect(NativeSmallFontReadabilityPolicy.search(input, requestedFontSize: .infinity) == nil)
        #expect(NativeSmallFontReadabilityPolicy.search(input, requestedFontSize: input.style.fontSize) == nil)
    }

    @Test func smallTextGrowsWithoutChangingItsSourceBacking() throws {
        let original = try fixture(sourceTextOnly: false)
        var item = try #require(original.items.first)
        #expect(!item.sourceTextOnly)
        item.fontSize = 6; item.lineHeight = 7.2
        let layout = NativeTranslationLayout(imageSize: original.imageSize, sourceRect: original.sourceRect,
            viewport: original.viewport, items: [item])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: ReaderTranslationSettings.defaultOverlay, collectDiagnostics: true)
        let card = try #require(plan.cards.first)
        #expect(card.finalFontSize > 6 && card.finalFontSize <= 7.75)
        #expect(card.typography.fits)
        #expect(card.typography.visibleUTF16Range.length == item.text.utf16.count)
        #expect(card.item.rect == item.rect)
        #expect(card.sourcePlateRect.contains(item.rect))
    }

    @Test func smallSourceOnlyTextKeepsItsSizeAndBacking() throws {
        let original = try fixture()
        var item = try #require(original.items.first)
        #expect(item.sourceTextOnly)
        item.fontSize = 6; item.lineHeight = 7.2
        let layout = NativeTranslationLayout(imageSize: original.imageSize, sourceRect: original.sourceRect,
            viewport: original.viewport, items: [item])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: ReaderTranslationSettings.defaultOverlay, collectDiagnostics: true)
        let card = try #require(plan.cards.first)
        #expect(card.finalFontSize == 6)
        #expect(card.typography.fits)
        #expect(card.typography.visibleUTF16Range.length == item.text.utf16.count)
        #expect(card.item.rect == item.rect)
        #expect(card.sourcePlateRect.contains(item.rect))
    }

    @Test func smallTextSearchRejectsAVisibleForeignSentence() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                       CGPoint(x: 100, y: 80), CGPoint(x: 0, y: 80)]
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 6, vertical: false,
            foreground: UIColor.black.cgColor, tracking: -0.072, lineHeight: 7.2,
            horizontalWrapping: .keepAllWithEmergency)
        let input = NativeSmallFontReadabilityPolicy.Input(text: "안녕하세요", frame: frame,
            padding: [2, 2, 2, 2], style: style, paintPolygons: [polygon],
            foreignRects: [frame], ordinaryKoreanCaption: true)
        #expect(NativeSmallFontReadabilityPolicy.search(input) == nil)
    }

    @Test func smallTextSearchChecksTheBestCandidateFirst() throws {
        let input = neutralSmallTextInput()
        let expected = try #require(NativeSmallFontReadabilityPolicy.search(input))
        var calls = 0
        let actual = try #require(NativeSmallFontReadabilityPolicy.search(input, pixelGuard: { _ in
            calls += 1
            return true
        }))
        #expect(calls == 1)
        #expect(actual.style.fontSize == expected.style.fontSize)
        #expect(actual.style.lineHeight == expected.style.lineHeight)
        #expect(actual.padding == expected.padding && actual.rows == expected.rows)
        #expect(actual.glyphRect == expected.glyphRect)
    }

    @Test func smallTextSearchContinuesAfterPixelRejection() throws {
        var calls = 0
        let accepted = try #require(NativeSmallFontReadabilityPolicy.search(neutralSmallTextInput(), pixelGuard: { _ in
            calls += 1
            return calls > 1
        }))
        #expect(calls == 2)
        #expect(accepted.layout.fits)
        #expect(accepted.layout.visibleUTF16Range.length == neutralSmallTextInput().text.utf16.count)
        #expect(NativeSmallFontReadabilityPolicy.search(neutralSmallTextInput(), pixelGuard: { _ in false }) == nil)
    }

    @Test func smallTextSearchStopsWhenNoCandidateCanBeEvaluated() {
        var calls = 0
        #expect(NativeSmallFontReadabilityPolicy.search(neutralSmallTextInput(), pixelGuard: { _ in
            calls += 1
            return true
        }, canEvaluate: { false }) == nil)
        #expect(calls == 0)
        var remaining = 1
        #expect(NativeSmallFontReadabilityPolicy.search(neutralSmallTextInput(), pixelGuard: { _ in
            calls += 1
            remaining -= 1
            return false
        }, canEvaluate: { remaining > 0 }) == nil)
        #expect(calls == 1 && remaining == 0)
    }

    @Test func denseRequestedFontProbesRecoverNonmonotoneSamplingHole() throws {
        let seed = neutralSmallTextInput()
        let input = NativeSmallFontReadabilityPolicy.Input(text: "가가 가가", frame: seed.frame,
            padding: seed.padding, style: seed.style, paintPolygons: seed.paintPolygons,
            foreignRects: [], ordinaryKoreanCaption: true)
        let accept: (NativeSmallFontReadabilityPolicy.Proposal) -> Bool = { $0.style.fontSize == 13.75 }
        #expect(NativeSmallFontReadabilityPolicy.search(input, pixelGuard: accept, requestedFontSize: 16) == nil)
        var remaining = 131_072
        let dense = try #require(NativeSmallFontReadabilityPolicy.search(input, pixelGuard: accept,
            requestedFontSize: 16, spendShapeWork: {
                let work = max(1, input.text.utf16.count)
                guard work <= remaining else { return false }
                remaining -= work
                return true
            }, denseRequestedFonts: true))
        #expect(dense.style.fontSize == 13.75)
        #expect(dense.layout.fits)
        #expect(dense.layout.visibleUTF16Range == NSRange(location: 0, length: input.text.utf16.count))
        #expect(dense.cuts <= dense.baselineCuts && dense.singletons <= dense.baselineSingletons)
        #expect(remaining >= 0)
        #expect(NativeSmallFontReadabilityPolicy.search(input, pixelGuard: { _ in false },
            requestedFontSize: 16, denseRequestedFonts: true) == nil)
        #expect(NativeSmallFontReadabilityPolicy.search(input, requestedFontSize: 16,
            spendShapeWork: { false }, denseRequestedFonts: true) == nil)
        let legacy = try #require(NativeSmallFontReadabilityPolicy.search(input))
        let unchanged = try #require(NativeSmallFontReadabilityPolicy.search(input, denseRequestedFonts: false))
        #expect(legacy.style.fontSize == unchanged.style.fontSize && legacy.padding == unchanged.padding)
    }

    private func neutralSmallTextInput() -> NativeSmallFontReadabilityPolicy.Input {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                       CGPoint(x: 100, y: 80), CGPoint(x: 0, y: 80)]
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 6, vertical: false,
            foreground: UIColor.black.cgColor, tracking: -0.072, lineHeight: 7.2,
            horizontalWrapping: .keepAllWithEmergency)
        return .init(text: "오늘은 도서관에서 책을 읽어요", frame: frame,
            padding: [2, 2, 2, 2], style: style, paintPolygons: [polygon],
            foreignRects: [], ordinaryKoreanCaption: true)
    }

    @Test func legacySourcePreferencesCannotReactivateRepair() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.preserveSourceColors = true
        settings.inpaintingEnabled = true
        settings.opacity = 0.3
        var decoded = try JSONDecoder().decode(IPhoneOverlaySettings.self, from: JSONEncoder().encode(settings))
        decoded.enforceSourceReplacement()
        #expect(!decoded.inpaintingEnabled && !decoded.usesSourceInpainting)
        #expect(!decoded.preserveSourceColors && decoded.renderedBackgroundOpacity == 1)
    }

    @Test func pdfAndReplayUseTheSameSolidBoxPlan() throws {
        let settings = ReaderTranslationSettings.defaultOverlay
        let first = try NativeTranslationRenderer.renderSynchronously(layout: fixture(), image: nil,
            settings: settings, capturePDF: true)
        #expect(first.exportPDFData?.isEmpty == false)
        #expect(first.sourcePatches.isEmpty && first.sourceRestorationRects.isEmpty)
        let replay = try JSONDecoder().decode(NativeTranslationLayout.self, from: first.layoutData)
        let second = try NativeTranslationRenderer.renderSynchronously(layout: replay, image: nil,
            settings: settings, capturePDF: true)
        #expect(first.image.pngData() == second.image.pngData())
    }

    @Test func coloredBalloonWithoutMetadataKeepsPanelAndTextInside() throws {
        let size = CGSize(width: 240, height: 220)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            renderer.cgContext.setFillColor(UIColor.white.cgColor)
            renderer.cgContext.fill(CGRect(origin: .zero, size: size))
            renderer.cgContext.setFillColor(NativeTranslationRenderer.color([125, 145, 155]))
            renderer.cgContext.fillEllipse(in: CGRect(x: 60, y: 35, width: 120, height: 160))
            renderer.cgContext.setFillColor(UIColor.black.cgColor)
            renderer.cgContext.fill(CGRect(x: 100, y: 85, width: 40, height: 55))
        }
        let item = try descriptor(id: "ellipse", box: CGRect(x: 48, y: 45, width: 145, height: 145),
                                  source: CGRect(x: 100, y: 85, width: 40, height: 55), size: size)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: [item])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: image,
            settings: ReaderTranslationSettings.defaultOverlay)
        let card = try #require(plan.cards.first)
        #expect(!card.textBoxClip.isEmpty)
        #expect(card.typography.fits)
        #expect(card.item.rect.minX > item.rect.minX && card.item.rect.maxX < item.rect.maxX)
        let result = try NativeTranslationRenderer.finishPreparedSynchronously(plan)
        #expect(try pixelRGB(result.image, x: 52, y: 50) == [255, 255, 255])
        #expect(try pixelRGB(result.image, x: 65, y: 48) == [255, 255, 255])
    }

    @Test func touchingPanelsGetIndependentSpaceAndKeepTheirSources() throws {
        let size = CGSize(width: 300, height: 200)
        let firstSource = CGRect(x: 50, y: 60, width: 70, height: 75)
        let secondSource = CGRect(x: 135, y: 65, width: 60, height: 70)
        let first = try descriptor(id: "left", box: CGRect(x: 40, y: 45, width: 100, height: 110), source: firstSource, size: size)
        let second = try descriptor(id: "right", box: CGRect(x: 120, y: 45, width: 90, height: 110), source: secondSource, size: size)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: [first, second])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: ReaderTranslationSettings.defaultOverlay)
        #expect(plan.cards.count == 2)
        #expect(plan.cards[0].sourcePlateRect.maxX + 1 <= plan.cards[1].sourcePlateRect.minX)
        #expect(plan.cards[0].sourcePlateRect.contains(firstSource))
        #expect(plan.cards[1].sourcePlateRect.contains(secondSource))
        for card in plan.cards { #expect(card.typography.fits && card.sourcePlateRect.contains(card.item.rect)) }
        let reverse = NativeTextBoxContainment.separated(panels: [second.rect, first.rect],
            owners: [secondSource, firstSource], kept: [false, false])
        #expect(reverse[1].maxX + 1 <= reverse[0].minX)
    }

    @Test func outlinedBalloonOverArtworkKeepsItsRimAndCoversLettering() throws {
        let size = CGSize(width: 240, height: 220)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(NativeTranslationRenderer.color([75, 45, 35]))
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(NativeTranslationRenderer.color([100, 70, 55]))
            context.fill(CGRect(x: 0, y: 100, width: 240, height: 60))
            context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(8)
            context.strokeEllipse(in: CGRect(x: 40, y: 20, width: 160, height: 180))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 78, y: 55, width: 84, height: 110))
            context.setFillColor(UIColor.black.cgColor)
            for y in stride(from: 65, to: 160, by: 25) {
                context.fill(CGRect(x: 85, y: y, width: 70, height: 12))
            }
        }
        let item = try descriptor(id: "rim", box: CGRect(x: 28, y: 35, width: 182, height: 155),
            source: CGRect(x: 78, y: 55, width: 84, height: 110), size: size)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: [item])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: image,
            settings: ReaderTranslationSettings.defaultOverlay)
        let card = try #require(plan.cards.first)
        #expect(!card.textBoxClip.isEmpty && card.typography.fits)
        let result = try NativeTranslationRenderer.finishPreparedSynchronously(plan)
        #expect(try pixelRGB(result.image, x: 30, y: 40) == pixelRGB(image, x: 30, y: 40))
        #expect(try pixelRGB(result.image, x: 80, y: 60) != [255, 255, 255])
    }

    @Test func preservedLetteringIsNeverCoveredByItsNeighbor() {
        let sources = [CGRect(x: 40, y: 50, width: 70, height: 90), CGRect(x: 120, y: 60, width: 25, height: 60)]
        let result = NativeTextBoxContainment.separated(panels: [CGRect(x: 30, y: 40, width: 110, height: 110), sources[1]],
            owners: sources, kept: [false, true])
        #expect(result[0].maxX + 1 <= result[1].minX)
        #expect(result[1] == sources[1])
    }

    @Test func openArtworkAndInvalidContoursDoNotCertifyABalloon() throws {
        let pixel: [UInt8] = [125, 145, 155, 255]
        let rgba: [UInt8] = Array(repeating: pixel, count: 64 * 64).flatMap { $0 }
        #expect(try NativeTextBoxContainment.measured(rgba: rgba, width: 64, height: 64,
            roi: CGRect(x: 0, y: 0, width: 64, height: 64), owner: CGRect(x: 20, y: 20, width: 24, height: 24)) == nil)
        let invalid = NativeTranslationBalloonInterior(rect: [0, 0, 1, 1], center: [0.5, 0.5],
            spans: [0.2, 0.8, .nan, 0.8], contourVerified: true)
        #expect(NativeTextBoxContainment.known(invalid, frame: CGRect(x: 0, y: 0, width: 64, height: 64)) == nil)
    }

    @Test func partialSurfaceBoundsCannotTruncateAcceptedSourceOwner() {
        let panel = CGRect(x: 5, y: 5, width: 100, height: 40)
        let owner = CGRect(x: 10, y: 10, width: 90, height: 20)
        let partial = CGRect(x: 8, y: 8, width: 80, height: 30)
        #expect(NativeTextBoxContainment.sourcePreservingIntersection(panel: panel,
            surfaceBounds: partial, owner: owner) == panel)
        let complete = CGRect(x: 8, y: 8, width: 94, height: 25)
        #expect(NativeTextBoxContainment.sourcePreservingIntersection(panel: panel,
            surfaceBounds: complete, owner: owner) == panel.intersection(complete))
        #expect(NativeTextBoxContainment.sourcePreservingIntersection(panel: panel,
            surfaceBounds: .null, owner: owner) == panel)
    }

    @Test func fittedTextCentersIndependentlyOfCoveredSource() {
        let surface = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            spans: Array(repeating: (CGFloat(0), CGFloat(100)), count: 100), color: nil)
        let frame = CGRect(x: 10, y: 25, width: 40, height: 40)
        let owner = CGRect(x: 10, y: 25, width: 20, height: 40)
        let moved = surface.centered(frame: frame, owner: owner, within: surface.rect,
            otherOwners: [], otherTextFrames: [], pixelSize: CGSize(width: 1, height: 1))
        #expect(moved == CGRect(x: 30, y: 30, width: 40, height: 40))
        #expect(moved.size == frame.size)
        #expect(surface.rect.contains(owner) && surface.rect.contains(moved))
    }

    @Test func exportPaintSupportIncludesTheOpaqueBacking() throws {
        let size = CGSize(width: 400, height: 200)
        let item = try descriptor(id: "backing", box: CGRect(x: 100, y: 60, width: 60, height: 40),
            source: CGRect(x: 70, y: 40, width: 140, height: 90), size: size)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size),
            viewport: size, items: [item])
        let plan = try NativeTranslationRenderer.prepareRenderSynchronously(layout: layout, image: nil,
            settings: ReaderTranslationSettings.defaultOverlay)
        let card = try #require(plan.cards.first)
        #expect(card.sourcePlateRect.width > card.item.rect.width)
        let bounds = NativeTranslationRenderer.finalPaintBounds(cards: plan.cards, glossCards: [],
            gloss: .init(), settings: ReaderTranslationSettings.defaultOverlay)
        #expect(bounds.contains(card.sourcePlateRect))
    }

    @Test func centeredTextKeepsIndependentParagraphCell() {
        let surface = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 200, height: 100),
            spans: Array(repeating: (CGFloat(0), CGFloat(200)), count: 100), color: nil)
        let owner = CGRect(x: 20, y: 20, width: 30, height: 50)
        let peer = CGRect(x: 140, y: 20, width: 30, height: 50)
        let frame = CGRect(x: 10, y: 10, width: 50, height: 60)
        let moved = surface.centered(frame: frame, owner: owner, within: surface.rect,
            otherOwners: [peer], otherTextFrames: [peer], pixelSize: CGSize(width: 1, height: 1))
        #expect(moved.size == frame.size)
        #expect(moved.maxX < (owner.midX + peer.midX) / 2)
        #expect(!moved.intersects(peer))
    }

    @Test func sourceAnchoringMovesBackingAndTextWithoutDroppingSource() {
        let page = CGRect(x: 0, y: 0, width: 100, height: 100)
        let frame = CGRect(x: 10, y: 10, width: 40, height: 40)
        let panel = CGRect(x: 8, y: 8, width: 44, height: 44)
        let owner = CGRect(x: 25, y: 25, width: 20, height: 20)
        let delta = NativeTextBoxContainment.sourceAnchored(frame: frame, panel: panel, owner: owner,
            sourceFrame: page, otherOwners: [], otherTextFrames: [], otherPanels: [], imageSize: page.size)
        #expect(abs(delta.x - 5) < 1e-9 && abs(delta.y - 5) < 1e-9)
        #expect(panel.offsetBy(dx: delta.x, dy: delta.y).contains(owner))
        #expect(frame.offsetBy(dx: delta.x, dy: delta.y).size == frame.size)
    }

    private func descriptor(id: String, box: CGRect, source: CGRect, size: CGSize) throws -> NativeTranslationLayoutItem {
        let value: [String: Any] = ["id": id, "text": "번역문입니다", "x": box.minX, "y": box.minY,
            "width": box.width, "height": box.height, "fontSize": 18, "lineHeight": 22,
            "fontScript": "korean", "wrappingScript": "korean", "sourceFrame": [0, 0, size.width, size.height],
            "sourceBounds": [source.minX / size.width, source.minY / size.height, source.width / size.width, source.height / size.height]]
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func fixture(sourceTextOnly: Bool? = nil) throws -> NativeTranslationLayout {
        var descriptor: [String: Any] = ["id": "box", "text": "번역문", "x": 80, "y": 40,
            "width": 80, "height": 60, "fontSize": 18, "lineHeight": 22,
            "fontScript": "korean", "wrappingScript": "korean", "sourceBounds": [0.2, 0.2, 0.2, 0.3],
            "sourceFrame": [0, 0, 400, 200], "sourceColorEligible": true]
        if let sourceTextOnly { descriptor["sourceTextOnly"] = sourceTextOnly }
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: descriptor))
        return NativeTranslationLayout(imageSize: CGSize(width: 400, height: 200),
            sourceRect: CGRect(x: 0, y: 0, width: 400, height: 200), viewport: CGSize(width: 400, height: 200), items: [item])
    }

    private func pixelRGB(_ image: UIImage, x: Int, y: Int) throws -> [Int] {
        let cgImage = try #require(image.cgImage)
        let rgba = try NativeSourcePixelReader.draw(image: cgImage, x: Double(x), y: Double(y),
            sourceWidth: 1, sourceHeight: 1, width: 1, height: 1)
        return Array(rgba.prefix(3)).map(Int.init)
    }
}
