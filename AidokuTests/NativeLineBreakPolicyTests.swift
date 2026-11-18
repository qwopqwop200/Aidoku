import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativeLineBreakPolicyTests {
    // These cases verify the optional lexical path, independent of the app default.
    private func legacyHorizontal(text: String, font: CTFont, size: CGFloat, width: CGFloat, minimumLineHeight: CGFloat,
                                  outwardExtent: CGFloat, color: CGColor,
                                  lineFactory: ((NSAttributedString) -> CTLine)? = nil) throws -> NativeFinalTextFlow.Plan? {
        try NativeSimpleTextLayout.withEnabled(false) {
            try NativeFinalTextFlow.horizontal(text: text, font: font, size: size, width: width,
                minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent, color: color, lineFactory: lineFactory)
        }
    }

    private func legacyCandidates(text: String, font: CTFont, size: CGFloat, width: CGFloat, maximumWidth: CGFloat,
                                  minimumLineHeight: CGFloat, outwardExtent: CGFloat, color: CGColor,
                                  allowRefinement: Bool = true) throws -> [NativeFinalTextFlow.Plan] {
        try NativeSimpleTextLayout.withEnabled(false) {
            try NativeFinalTextFlow.horizontalCandidates(text: text, font: font, size: size, width: width,
                maximumWidth: maximumWidth, minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent,
                color: color, allowRefinement: allowRefinement)
        }
    }

    @Test func jointTailProposalHandlesManyParagraphsWithoutDroppingNarrowerFits() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, 24, nil)
        let color = CGColor(gray: 0, alpha: 1)
        let block = ["아마먀의 몸… 점점 이상해지는 것 같아……윽",
            "이... 이용해 주셔서 고맙... 습니... 다",
            "하... 하지만 미래를 위한 중요한 검사니까 참아야 해",
            "제... 제대로 읽지 못해서 죄송... 합니다... 윽"].joined(separator: "\n")
        for repetitions in [1, 8] {
            let text = Array(repeating: block, count: repetitions).joined(separator: "\n")
            let pitch = NativeTextSpacing.pitch(text: text, font: font, fontSize: 24, outwardExtent: 5)
            let options = try legacyCandidates(text: text, font: font, size: 24,
                width: 80, maximumWidth: 120, minimumLineHeight: pitch, outwardExtent: 5, color: color)
            // Four tail repairs plus the initial plan remain available. The
            // measured lexical repair adds one same-row-count alternative
            // that joins words without discarding the narrower tail fit.
            try #require(options.count == 6)
            let best = try #require(options.first), baseline = try #require(options.last)
            #expect(best.quality?.softOrphans == 0)
            #expect(baseline.quality?.softOrphans == 4 * repetitions)
            let narrower = options[1]
            #expect(narrower.lines.count == options[2].lines.count)
            #expect(NativeRenderWrapQuality.wordCutOffsets(text, ranges: narrower.ranges).count == 0)
            #expect(NativeRenderWrapQuality.wordCutOffsets(text, ranges: options[2].ranges).count == 2 * repetitions)
            let limited = try legacyCandidates(text: text, font: font, size: 24,
                width: 80, maximumWidth: narrower.size.width, minimumLineHeight: pitch, outwardExtent: 5, color: color)
            #expect(limited.map(\.ranges) == options.dropFirst().map(\.ranges))
            #expect(limited.map(\.size) == options.dropFirst().map(\.size))
            let source = text as NSString
            for plan in options {
                #expect(plan.size.width <= 120)
                #expect(plan.ranges.map { source.substring(with: $0) }.joined() == text)
                #expect((plan.quality?.wordCuts ?? Int.max) <= (baseline.quality?.wordCuts ?? 0))
                #expect(plan.lines.count <= baseline.lines.count && plan.size.height <= baseline.size.height + 0.01)
            }
        }
    }

    @Test func paragraphTailRefinementRecalculatesAndKeepsEveryNarrowerFit() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, 24, nil)
        let color = CGColor(gray: 0, alpha: 1)
        for separator in ["\n", "\r\n", "\n\n"] {
            let text = "정신을 차렸을 때" + separator + "좋아...... 카메라 오케이... 음"
            let pitch = NativeTextSpacing.pitch(text: text, font: font, fontSize: 24, outwardExtent: 5)
            let options = try legacyCandidates(text: text, font: font, size: 24,
                width: 80, maximumWidth: 120, minimumLineHeight: pitch, outwardExtent: 5, color: color)
            try #require(options.count == 3)
            let best = try #require(options.first), baseline = try #require(options.last)
            #expect(best.quality?.softOrphans == 0 && baseline.quality?.softOrphans == 2)
            let middle = options[1]
            #expect(middle.quality?.softOrphans == 1)
            #expect(best.lines.count < middle.lines.count && middle.lines.count < baseline.lines.count)
            let admitted = options.first { $0.size.width <= middle.size.width + 0.01 }
            #expect(admitted?.ranges == middle.ranges && admitted?.size == middle.size)
            let limited = try legacyCandidates(text: text, font: font, size: 24,
                width: 80, maximumWidth: middle.size.width, minimumLineHeight: pitch, outwardExtent: 5, color: color)
            #expect(limited.count == 2 && limited.first?.ranges == middle.ranges)
            let source = text as NSString
            for plan in options {
                #expect(plan.ranges.map { source.substring(with: $0) }.joined() == text)
                #expect(plan.quality?.wordCuts == 0)
                for range in plan.ranges {
                    #expect(!source.substring(with: range).dropLast().contains(where: NativeLineBreakPolicy.isBreak))
                }
            }
        }
    }

    @Test func forbiddenWhitespaceKeepsCJKRescueEvidenceAtWiderWidths() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
        for text in ["……으… ……아……", "……으… ……아……\n다음 줄", "……으…  ……아……"] {
            for width: CGFloat in [100, 120, 140] {
                let result = try NativeWholeWordWrap.layout(text: text, font: font, size: 24,
                    width: width, necessaryCJK: true)
                #expect(result.requiredWidth <= width + 0.01)
                #expect(result.completeOwnership && result.unresolvedGlyphRanges.isEmpty)
                let source = text as NSString
                #expect(result.rows.map { source.substring(with: $0.ownedRange) }.joined() == text)
                let legal = NativeLineBreakPolicy.legalOffsets(text: text)
                for row in result.rows.dropLast() where !row.hardBreak {
                    #expect(legal.contains(NSMaxRange(row.ownedRange)))
                }
                for row in result.rows {
                    #expect(!source.substring(with: row.ownedRange).dropLast().contains("\n"))
                }
            }
        }
        let text = "우선 제일 먼저― ...길이를 재볼 것도 없네"
        let existingFit = try NativeWholeWordWrap.layout(text: text, font: font, size: 24,
            width: 140, necessaryCJK: false)
        let repaired = try NativeWholeWordWrap.layout(text: text, font: font, size: 24,
            width: 140, necessaryCJK: true)
        #expect(existingFit.requiredWidth <= 140.01)
        #expect(repaired.rows.map(\.ownedRange) == existingFit.rows.map(\.ownedRange))
        #expect(repaired.appliedTracking == existingFit.appliedTracking)
    }

    @Test func unfitWidthRecoversUsingMeasuredInkWithoutChangingTextOrFont() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, 24, nil)
        let color = CGColor(gray: 0, alpha: 1)
        for text in ["……으… ……아……", "'아아아아아악♡♡♡'", "……으… ……아……\n다음 줄"] {
            let original = try legacyHorizontal(text: text, font: font, size: 24,
                width: 80, minimumLineHeight: 40, outwardExtent: 5, color: color)
            #expect(original == nil)
            let candidates = try legacyCandidates(text: text, font: font, size: 24,
                width: 80, maximumWidth: 240, minimumLineHeight: 40, outwardExtent: 5, color: color)
            #expect(candidates.count == 1)
            let plan = try #require(candidates.first)
            #expect(plan.refinementOriginWidth == 80)
            #expect(plan.size.width > 80 && plan.size.width <= 240)
            let source = text as NSString
            #expect(plan.ranges.map { source.substring(with: $0) }.joined() == text)
            for range in plan.ranges {
                #expect(!source.substring(with: range).dropLast().contains("\n"))
            }
            let independent = try legacyHorizontal(text: text, font: font, size: 24,
                width: plan.size.width, minimumLineHeight: 40, outwardExtent: 5, color: color)
            #expect(independent?.ranges == plan.ranges && independent?.baselines == plan.baselines)
            let locked = try legacyCandidates(text: text, font: font, size: 24,
                width: 80, maximumWidth: 240, minimumLineHeight: 40, outwardExtent: 5, color: color,
                allowRefinement: false)
            #expect(locked.isEmpty)
            let limited = try legacyCandidates(text: text, font: font, size: 24,
                width: 80, maximumWidth: 80, minimumLineHeight: 40, outwardExtent: 5, color: color)
            #expect(limited.isEmpty)
        }
    }

    @Test func tailRefinementUsesTheExactAvailableCapacity() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, 24, nil)
        let text = "좋아...... 카메라 오케이... 음", color = CGColor(gray: 0, alpha: 1)
        let originalValue = try legacyHorizontal(text: text, font: font, size: 24, width: 80,
            minimumLineHeight: 40, outwardExtent: 5, color: color)
        let original = try #require(originalValue)
        let needed = try #require(original.quality?.nextTailWidth)
        let limited = try legacyCandidates(text: text, font: font, size: 24,
            width: 80, maximumWidth: needed - 0.01, minimumLineHeight: 40, outwardExtent: 5, color: color)
        let available = try legacyCandidates(text: text, font: font, size: 24,
            width: 80, maximumWidth: needed + 0.1, minimumLineHeight: 40, outwardExtent: 5, color: color)
        #expect(limited.count == 1 && limited.first?.ranges == original.ranges)
        #expect(available.count == 2)
        #expect(available.first?.size.width == needed)
        #expect(available.first?.quality?.softOrphans == 0)
        #expect((available.first?.lines.count ?? Int.max) < original.lines.count)
        #expect(available.last?.ranges == original.ranges && available.last?.baselines == original.baselines)
    }

    private enum RefinementFailure: Error { case rejected, baselineRejected }

    @Test func finalAdmissionFailureRetriesBaselineOnceAndPreservesCancellation() throws {
        var calls: [Bool] = []
        let result = try NativeFinalTextFlow.withRefinementFallback { enabled, record in
            calls.append(enabled)
            if enabled { record(); throw RefinementFailure.rejected }
            return "baseline"
        }
        #expect(result.value == "baseline" && result.usedBaselineRetry)
        #expect(calls == [true, false])

        calls = []
        do {
            let _: (value: Int, usedBaselineRetry: Bool) = try NativeFinalTextFlow.withRefinementFallback { enabled, _ in
                calls.append(enabled)
                throw RefinementFailure.rejected
            }
            Issue.record("A failure without a selected refinement must propagate")
        } catch RefinementFailure.rejected {}
        #expect(calls == [true])

        calls = []
        do {
            let _: (value: Int, usedBaselineRetry: Bool) = try NativeFinalTextFlow.withRefinementFallback { enabled, record in
                calls.append(enabled); record(); throw CancellationError()
            }
            Issue.record("Cancellation must propagate without repeating work")
        } catch is CancellationError {}
        #expect(calls == [true])

        calls = []
        do {
            let _: (value: Int, usedBaselineRetry: Bool) = try NativeFinalTextFlow.withRefinementFallback { enabled, record in
                calls.append(enabled)
                if enabled { record(); throw RefinementFailure.rejected }
                throw RefinementFailure.baselineRejected
            }
            Issue.record("The baseline failure must propagate after one retry")
        } catch RefinementFailure.baselineRejected {}
        #expect(calls == [true, false])

        calls = []
        let accepted = try NativeFinalTextFlow.withRefinementFallback { enabled, record in
            calls.append(enabled); record(); return "preferred"
        }
        #expect(accepted.value == "preferred" && !accepted.usedBaselineRetry)
        #expect(calls == [true])
    }

    @Test func boundedWidthLookaheadRemovesTinyTailAndKeepsOriginalFallback() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, 24, nil)
        let text = "정신을 차렸을 때", color = CGColor(gray: 0, alpha: 1)
        let pitch = NativeTextSpacing.pitch(text: text, font: font, fontSize: 24, outwardExtent: 5)
        let initialValue = try legacyHorizontal(text: text, font: font, size: 24, width: 80,
            minimumLineHeight: pitch, outwardExtent: 5, color: color)
        let initial = try #require(initialValue)
        let options = try legacyCandidates(text: text, font: font, size: 24,
            width: 80, maximumWidth: 105, minimumLineHeight: pitch, outwardExtent: 5, color: color)
        #expect(options.count == 2)
        let preferred = try #require(options.first), baseline = try #require(options.last)
        #expect(preferred.lines.count < initial.lines.count)
        #expect(preferred.quality?.softOrphans == 0)
        #expect(preferred.quality?.wordCuts == initial.quality?.wordCuts)
        #expect(preferred.size.width <= 105 && preferred.size.height <= initial.size.height + 0.01)
        #expect(preferred.refinementOriginWidth == 80)
        #expect(baseline.size == initial.size && baseline.ranges == initial.ranges && baseline.baselines == initial.baselines)
        #expect(baseline.refinementOriginWidth == nil)
        let source = text as NSString
        #expect(preferred.ranges.map { source.substring(with: $0) }.joined() == text)
        for line in preferred.lines {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                #expect(CTFontGetSize(attributes[kCTFontAttributeName] as! CTFont) == 24)
            }
        }
        let inset = CGFloat(5) + NativeTextSpacing.padding(fontSize: 24)
        let center = CGPoint(x: 80, y: 80)
        let peer = CGRect(x: center.x + (initial.size.width + 2 * inset) / 2 + 0.1, y: 0, width: 10, height: 200)
        let admitted = options.first { plan in
            let outer = CGSize(width: plan.size.width + 2 * inset, height: plan.size.height + 2 * inset)
            return !CGRect(x: center.x - outer.width / 2, y: center.y - outer.height / 2,
                width: outer.width, height: outer.height).intersects(peer)
        }
        #expect(admitted?.ranges == initial.ranges && admitted?.size == initial.size)
    }

    @Test func widthLookaheadRespectsLocksLimitsAndIntentionalNewlines() throws {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, 24, nil)
        let color = CGColor(gray: 0, alpha: 1)
        for (text, maximum, enabled) in [("정신을 차렸을 때", 80.0, true), ("정신을 차렸을 때", 120.0, false),
                                        ("정신을 차렸을\n때", 120.0, true), ("short text", 120.0, true)] {
            let plans = try legacyCandidates(text: text, font: font, size: 24,
                width: 80, maximumWidth: maximum, minimumLineHeight: 40, outwardExtent: 5, color: color,
                allowRefinement: enabled)
            #expect(plans.count == 1)
            let original = try legacyHorizontal(text: text, font: font, size: 24, width: 80,
                minimumLineHeight: 40, outwardExtent: 5, color: color)
            #expect(plans.first?.ranges == original?.ranges && plans.first?.size == original?.size)
            #expect(plans.first?.refinementOriginWidth == nil)
            #expect(plans.first?.ranges.map { (text as NSString).substring(with: $0) }.joined() == text)
        }
    }

    @Test func groupedNumeralsStayWholeWithoutJoiningIndependentNumbers() {
        for text in ["1'234", "1’234’567.89", "１２＇３４５", "1\u{2009}234", "12\u{2007}345",
                     "123\u{2009}456\u{2009}789.5", "1’234 kg", "3\u{2009}456e−2 m"] {
            let legal = NativeLineBreakPolicy.legalOffsets(text: text)
            var offset = 0
            for c in text.dropLast() {
                offset += String(c).utf16.count
                #expect(!legal.contains(offset), "Unexpected grouped-number break: \(text), UTF16 \(offset)")
            }
        }
        for (left, right) in [("1\u{2009}", "2345"), ("12\u{2009}", "34"), ("1 ", "2 3"), ("1234’", "567")] {
            #expect(NativeLineBreakPolicy.legalOffsets(text: left + right).contains(left.utf16.count))
        }
        let beforeClose = "‘1’234 ", afterClose = beforeClose + "’ "
        #expect(!NativeLineBreakPolicy.legalOffsets(text: beforeClose + "’next").contains(beforeClose.utf16.count))
        #expect(NativeLineBreakPolicy.legalOffsets(text: afterClose + "next").contains(afterClose.utf16.count))
    }

    @Test func unitGrammarKeepsPrefixesPowersAndCountersWithoutCapturingOrdinaryWords() {
        for unit in ["hPa", "kN", "N", "J", "Ω", "Ω", "m/s^2", "m/s^-2", "kg·m/s²", "µmol/L", "kN/mm²",
                     "N·m", "W/m²", "a.m.", "p.m.", "개월", "주일", "번째로", "개의", "개월은", "개를", "원까지"] {
            let text = "10 " + unit, legal = NativeLineBreakPolicy.legalOffsets(text: text)
            var offset = 0
            for c in text.dropLast() {
                offset += String(c).utf16.count
                #expect(!legal.contains(offset), "Unexpected unit break: \(text), UTF16 \(offset)")
            }
        }
        for word in ["hello", "next", "calendar", "개성", "주름", "시작", "시간표", "번역"] {
            #expect(NativeLineBreakPolicy.legalOffsets(text: "10 " + word).contains(3))
        }
        #expect(!NativeLineBreakPolicy.legalOffsets(text: "10개월전").contains(2))
        #expect(!NativeLineBreakPolicy.legalOffsets(text: "10년간격").contains(2))
    }

    @Test func directionalControlsCannotHideKinsokuOrCreateNewLexicalBoundaries() throws {
        for value: UInt32 in [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
            let scalar = try #require(UnicodeScalar(value))
            let mark = String(scalar)
            for (left, right) in [("(" + mark, "AB)"), ("AB", mark + ")"), ("10" + mark + " ", "kg"),
                                  ("USD" + mark + " ", "12"), ("l" + mark, "’ami"), ("l’" + mark, "ami")] {
                #expect(!NativeLineBreakPolicy.legalOffsets(text: left + right).contains(left.utf16.count))
            }
            #expect(NativeLineBreakPolicy.legalOffsets(text: "word " + mark + "next").contains("word ".utf16.count))
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let text = "(\u{200E}AB)\u{200F}"
        let result = try NativeWholeWordWrap.layoutCaption(text: text, font: font, size: 20, width: 40,
            color: CGColor(gray: 0, alpha: 1))
        #expect(Array(result.attributedText.string.utf16) == Array(text.utf16))
        #expect(result.completeOwnership)
        for row in result.rows {
            let visible = (text as NSString).substring(with: row.paintedRange).filter { !NativeLineBreakPolicy.isDirectionalControl($0) }
            #expect(visible.last != "(" && visible.first != ")")
        }
        for (text, offset) in [("AB\u{200E}\u{00AD}CD", 3), ("AB\u{00AD}\u{200E}CD", 2)] {
            let flow = try legacyHorizontal(text: text, font: font, size: 20, width: 40,
                minimumLineHeight: 24, outwardExtent: 0, color: CGColor(gray: 0, alpha: 1))
            #expect(flow?.discretionaryHyphenOffsets == [offset])
            #expect(flow?.ranges.map { (text as NSString).substring(with: $0) }.joined() == text)
        }
    }

    @Test func discretionaryHyphenUsesVisibleInkOnlyAtASelectedSoftBreak() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let text = "AB\u{00AD}CD", source = text as NSString
        let expected = CTLineCreateWithAttributedString(NSAttributedString(string: "AB\u{2010}", attributes: [
            .init(kCTFontAttributeName as String): font, .init(kCTKernAttributeName as String): 0.1
        ]))
        for width in [30.0, 40] {
            let result = try NativeWholeWordWrap.layout(text: text, font: font, size: 20, width: width, tracking: 0.1)
            #expect(result.completeOwnership && result.unresolvedGlyphRanges.isEmpty)
            #expect(result.text == text && result.attributedText.string == text)
            #expect(result.rows.map { source.substring(with: $0.ownedRange) }.joined() == text)
            #expect(result.rows.count == 2)
            #expect(result.rows.first?.discretionaryHyphen == true)
            #expect(abs((result.rows.first?.advance ?? 0) - CGFloat(CTLineGetTypographicBounds(expected, nil, nil, nil))) < 0.001)
            if width == 30 { #expect(result.requiredWidth > width) }
        }
        let wide = try NativeWholeWordWrap.layout(text: text, font: font, size: 20, width: 200)
        #expect(wide.rows.count == 1 && !wide.rows.contains(where: \.discretionaryHyphen))
        let wideRow = try #require(wide.rows.first)
        #expect(CTLineGetGlyphCount(wideRow.line) == 4)
        let flow = try legacyHorizontal(text: text, font: font, size: 20, width: 40,
            minimumLineHeight: 24, outwardExtent: 0, color: CGColor(gray: 0, alpha: 1))
        #expect(flow?.discretionaryHyphenOffsets == [2])
        for invalid in ["\u{00AD}AB", "AB\u{00AD}", "AB\u{00AD} CD"] {
            let result = try NativeWholeWordWrap.layout(text: invalid, font: font, size: 20, width: 200)
            #expect(result.completeOwnership && !result.rows.contains(where: \.discretionaryHyphen))
        }
    }

    @Test func lexicalDomainsRespectSharedKinsokuAndCoalesceWhitespaceRuns() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for text in ["10 kg", "alpha        beta", "그는 ( 안녕 )", "one\u{200B}two", "A\u{00A0}B C"] {
            let legal = NativeLineBreakPolicy.legalOffsets(text: text), source = text as NSString
            var seen = Set<[String]>()
            let stats = try NativeLexicalRowDomains.visit(text: text, font: font, size: 24, maximumWidth: 300,
                color: CGColor(gray: 0, alpha: 1), measurements: NativeScopedShapePlanCache.Measurements(enabled: true),
                minimumLineHeight: 30, maximumHeight: 1000, bestTier: { Int.max }) { proposal in
                let rows = proposal.result.rows
                #expect(rows.map { source.substring(with: $0.ownedRange) }.joined() == text)
                #expect(rows.dropLast().allSatisfy { legal.contains(NSMaxRange($0.ownedRange)) })
                #expect(seen.insert(rows.map { source.substring(with: $0.paintedRange) }).inserted)
            }
            if text == "10 kg" { #expect(stats.paths == 1) }
            if text == "alpha        beta" { #expect(stats.paths == 2) }
        }
    }

    @Test func overwideCompoundsAndPathsUseNaturalBreaksButPlainWordsStayIntact() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for (text, width) in [("well-known-self-contained", 110.0), ("https://example.com/alpha-beta", 150.0),
                              ("root/folder/file-name", 110.0), ("well‐known‐self‐contained", 110.0)] {
            let result = try NativeWholeWordWrap.layout(text: text, font: font, size: 20, width: width, necessaryCJK: true)
            #expect(result.completeOwnership && result.unresolvedGlyphRanges.isEmpty)
            #expect(result.rows.count > 1)
            #expect(result.requiredWidth <= width + 0.01)
            let source = text as NSString
            #expect(result.rows.map { source.substring(with: $0.ownedRange) }.joined() == text)
            #expect(result.rows.dropLast().allSatisfy {
                let last = source.substring(with: $0.paintedRange).last
                return last == "-" || last == "‐" || last == "/"
            })
        }
        for text in ["ThisIsAnUnbreakableLexicalUnit", "well\u{2011}known\u{2011}self\u{2011}contained"] {
            let result = try NativeWholeWordWrap.layout(text: text, font: font, size: 20, width: 110, necessaryCJK: true)
            #expect(result.completeOwnership)
            #expect(result.rows.count == 1)
            #expect(result.requiredWidth > 110)
        }
    }

    @Test func quotePairsSurviveLineBreaksAndResetAtEmptyParagraphs() {
        for separator in ["\n", "\r\n", "\u{2028}", "\u{0085}"] {
            for (open, close) in [("\"", "\""), ("＂", "＂"), ("'", "'"), ("‘", "’"), ("„", "“"), ("»", "«")] {
                let left = "彼は" + open + "はい" + separator + "そうだ"
                #expect(!NativeLineBreakPolicy.legalOffsets(text: left + close + "と言った").contains(left.utf16.count))
                let prefix = left + close
                #expect(NativeLineBreakPolicy.legalOffsets(text: prefix + "次").contains(prefix.utf16.count))
            }
        }
        for separator in ["\n\n", "\n \n", "\u{2029}"] {
            let prefix = "\"最初" + separator + "彼は\""
            #expect(!NativeLineBreakPolicy.legalOffsets(text: prefix + "次\"と言った").contains(prefix.utf16.count))
        }
    }

    @Test func extendedEastAsianScriptsCanWrapWithoutNormalizationOrLostMarks() throws {
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 24, nil)
        for text in ["ｶﾀｶﾅﾉﾌﾞﾝｼｮｳｦﾖﾐﾏｽ", String(repeating: "神﨑", count: 5), "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒ"] {
            let result = try NativeWholeWordWrap.layout(text: text, font: font, size: 24, width: 80, necessaryCJK: true)
            #expect(result.completeOwnership)
            #expect(result.unresolvedGlyphRanges.isEmpty)
            #expect(result.rows.count > 1)
            #expect(result.requiredWidth <= 80.01)
            let source = text as NSString
            #expect(result.rows.map { source.substring(with: $0.ownedRange) }.joined() == text)
            let legal = NativeLineBreakPolicy.legalOffsets(text: text)
            #expect(result.rows.dropLast().allSatisfy { legal.contains(NSMaxRange($0.ownedRange)) })
        }
    }

    @Test func drawnOutEndingsNeverBecomeOrphanRows() throws {
        for mark in ["─", "—", "―", "~", "〜", "～", "-"] {
            #expect(!NativeLineBreakPolicy.legalOffsets(text: "문장" + mark).contains("문장".utf16.count))
            #expect(!NativeLineBreakPolicy.legalOffsets(text: mark + "문장").contains(mark.utf16.count))
            #expect(!NativeLineBreakPolicy.legalOffsets(text: "문장 " + mark + "!").contains("문장 ".utf16.count))
        }
        #expect(NativeLineBreakPolicy.legalOffsets(text: "문장 — 다음").contains("문장 ".utf16.count))
        #expect(!NativeLineBreakPolicy.legalOffsets(text: "3~5 kg").contains(1))
        #expect(!NativeLineBreakPolicy.legalOffsets(text: "3~5 kg").contains(2))
        #expect(!NativeLineBreakPolicy.legalOffsets(text: "—— 다음").contains("—— ".utf16.count))
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 24, nil)
        for text in ["그렇군─", "그렇군—", "가나다~!"] {
            let result = try NativeWholeWordWrap.layout(text: text, font: font, size: 24, width: 80, necessaryCJK: true)
            #expect(result.completeOwnership)
            let source = text as NSString
            #expect(result.rows.allSatisfy { range in source.substring(with: range.paintedRange).contains(where: \.isLetter) })
        }
    }

    @Test func widthMeasurementReusePreservesGeometryAndTracking() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let color = CGColor(gray: 0, alpha: 1)
        let measurements = NativeScopedShapePlanCache.Measurements(enabled: true)
        for text in ["alpha alpha alpha alpha alpha", "彼は\"はい\"と言った", "é e\u{301} 👩🏽‍💻"] {
            for width in [90.0, 160, 240] {
                let uncached = try legacyHorizontal(text: text, font: font, size: 24,
                    width: width, minimumLineHeight: 32, outwardExtent: 5, color: color)
                let cached = try legacyHorizontal(text: text, font: font, size: 24,
                    width: width, minimumLineHeight: 32, outwardExtent: 5, color: color, lineFactory: measurements.line)
                #expect(uncached?.ranges == cached?.ranges)
                #expect(uncached?.baselines == cached?.baselines)
                #expect(uncached?.inkBounds == cached?.inkBounds)
                #expect(uncached?.appliedTracking == cached?.appliedTracking)
            }
        }
        #expect(measurements.hits > 0)
        #expect(measurements.peak <= 256)

        let tracked = try NativeWholeWordWrap.layout(text: "one two three", font: font, size: 24,
            width: 100, tracking: -0.25, color: color)
        let cache = NativeScopedShapePlanCache()
        let key = NativeScopedShapePlanCache.Key(owner: "owner", text: tracked.text, font: font,
            size: 24, pitch: 32, width: 100, maximumWidth: 100, color: color)
        for _ in 0..<2 {
            let proposals = cache.proposals(key: key) { _ in
                [NativeWholeWordWrap.Proposal(width: 100, result: tracked, singleLetterRows: 0, overflowRows: 0)]
            }
            #expect(proposals.first?.result.appliedTracking == -0.25)
            #expect(proposals.first?.result.rows.map(\.ownedRange) == tracked.rows.map(\.ownedRange))
        }
    }

    @Test func pairedQuotesUseContextAcrossCJKAndInteriorSpaces() {
        let forbidden: [(String, String)] = [
            ("彼は\"", "はい\"と言った"), ("He said:\"", "hello\"again"),
            ("彼は＂", "はい＂と言った"), ("彼は'", "はい'と言った"),
            ("\"hello ", "\"again"), ("彼は\"はい\"と\"", "いいえ\"と言った"),
            ("„Hallo", "“ Welt"), ("»Hallo", "« Welt"), ("l", "’ami"), ("l’", "ami")
        ]
        for (left, right) in forbidden {
            #expect(!NativeLineBreakPolicy.legalOffsets(text: left + right).contains(left.utf16.count))
        }
        for (left, right) in [("He said:", "\"hello\""), ("彼は", "\"はい\"と言った"),
                              ("\"hello \" ", "again"), ("don't ", "split"), ("彼は", "'はい'と言った")] {
            #expect(NativeLineBreakPolicy.legalOffsets(text: left + right).contains(left.utf16.count))
        }
    }

    @Test func finalPainterKeepsSharedRowsAndOriginalOffsets() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for text in ["alpha alpha alpha alpha alpha", "그는 (안녕!)이라고 말했다.", "무게 10 kg, 비용 ₩ 12,345.",
                     "「括弧」句読点。続きの文。", "first\u{000B}second\u{000C}third"] {
            let proposed = try NativeFinalTextFlow.horizontal(text: text, font: font, size: 24,
                width: 200, minimumLineHeight: 32, outwardExtent: 5, color: CGColor(gray: 0, alpha: 1))
            let plan = try #require(proposed)
            let centered = try #require(plan.centered(height: plan.size.height + 20))
            let source = text as NSString
            #expect(plan.complete && plan.visibleUTF16 == source.length)
            #expect(plan.ranges.map { source.substring(with: $0) }.joined() == text)
            #expect(plan.ranges == centered.ranges)
            #expect(CGRect(origin: .zero, size: centered.size).insetBy(dx: -0.01, dy: -0.01).contains(centered.inkBounds))
            let legal = NativeLineBreakPolicy.legalOffsets(text: text)
            for range in plan.ranges.dropLast() {
                #expect(legal.contains(NSMaxRange(range)) ||
                    (source.substring(with: range).last.map(NativeLineBreakPolicy.isBreak) ?? false))
            }
            #expect(plan.centered(height: max(0, plan.size.height - 1)) == nil)
        }
    }

    @Test func balancesAnAvoidableShortTailWithoutAddingRows() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let fourWords = NSAttributedString(string: "alpha alpha alpha alpha", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(fourWords), nil, nil, nil)) + 1
        let result = try NativeWholeWordWrap.layout(text: "alpha alpha alpha alpha alpha", font: font, size: 24, width: width)
        #expect(result.completeOwnership)
        #expect(result.rows.count == 2)
        #expect((result.rows.last?.occupiedWidth ?? 0) >= width * 0.35)
        #expect(result.requiredWidth <= width + 0.01)
    }

    @Test func preservesMandatoryControlBreaksAndDashRuns() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for separator in ["\u{000B}", "\u{000C}"] {
            let result = try NativeWholeWordWrap.layout(text: "first" + separator + "second", font: font, size: 24, width: 500)
            #expect(result.completeOwnership)
            #expect(result.rows.count == 2)
            #expect(result.rows.first?.hardBreak == true)
        }
        for pair in [("-", "-"), ("–", "–"), ("‐", "‐")] {
            #expect(!NativeLineBreakPolicy.legalOffsets(text: pair.0 + pair.1).contains(pair.0.utf16.count))
        }
    }

    @Test func broadPunctuationAndNumbersStayAttachedAcrossSpaces() {
        let forbidden:[(String,String)] = [("（ ","문장"),("문장 ","）"),("語","、"),("語","っ"),("語","ㇰ"),
            ("語","々"),("말","؟"),("10 ","kg"),("10 k","g"),("10","개를"),("USD ","12"),
            ("1.2","3e−4"),("—","—"),("A\u{2060}","B"),("A","\u{00A0}B"),("말","♡"),("글","²"),("Hallo","“"),("2026-","11-11"),("− ","12"),(".","5 kg")]
        for (left,right) in forbidden {
            let offsets=NativeLineBreakPolicy.legalOffsets(text:left+right)
            #expect(!offsets.contains(left.utf16.count), "Unexpected break between \(left) and \(right)")
        }
        #expect(NativeLineBreakPolicy.legalOffsets(text:"문장。다음").contains("문장。".utf16.count))
    }
    @Test func wrappingPreservesUnicodeAndForcedNewlinesWithoutSoftKinsokuFailures() throws {
        let font=CTFontCreateWithName("HiraginoSans-W3" as CFString,24,nil)
        for text in ["『（한국어）』 정말?! …… 다음 문장。", "１２３．４５％, 10 kg, 42개를 준비한다.",
                     "e\u{301}cole 👩🏽‍💻 🇰🇷 한글", "처음\r\n다음\u{0085}끝\u{2028}\n", " ", ""] {
            let legal=NativeLineBreakPolicy.legalOffsets(text:text)
            for width in [18.0,42,90,180] {
                for mode in 0..<3 {
                    let plan=try NativeWholeWordWrap.layout(text:text,font:font,size:24,width:width,
                        characterControl:mode==1,necessaryCJK:mode==2)
                    #expect(plan.completeOwnership)
                    for row in plan.rows.dropLast() where !row.hardBreak {
                        #expect(legal.contains(NSMaxRange(row.ownedRange)))
                    }
                    #expect(plan.rows.allSatisfy { $0.occupiedWidth <= max(width,plan.requiredWidth)+0.001 })
                }
            }
        }
    }
    @Test func punctuationInkStaysInsideMeasuredFootprintAndRowsDoNotOverlap() throws {
        let font=CTFontCreateWithName("TimesNewRomanPS-ItalicMT" as CFString,30,nil)
        for text in ["“italic f!”", "jazz?!", "e\u{301}\u{302}\u{303}cole…", "「括弧」句読点。"] {
            let wrapped=try NativeWholeWordWrap.layout(text:text,font:font,size:30,width:48,characterControl:true)
            let width=max(48,wrapped.requiredWidth)
            let positioned=try NativeWholeWordGlyphPainter.position(wrapped,width:width,minimumLineHeight:0)
            for (index,row) in wrapped.rows.enumerated() where row.hasInk {
                let p=positioned.baselines[index]
                #expect(p.x+row.inkBounds.minX >= -0.001)
                #expect(p.x+row.inkBounds.maxX <= width+0.001)
                #expect(p.y-row.inkBounds.maxY >= -0.001)
                if index>0 {
                    let previous=wrapped.rows[index-1]
                    if previous.hasInk {
                        #expect(p.y-row.inkBounds.maxY >= positioned.baselines[index-1].y-previous.inkBounds.minY-0.001)
                    }
                }
            }
        }
    }
}
