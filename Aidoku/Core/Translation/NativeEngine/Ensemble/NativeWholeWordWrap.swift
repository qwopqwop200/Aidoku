import CoreText
import CoreGraphics
import Foundation

/// Independent fill-body proposal. Does not fit fonts, clip, paint outlines, or
/// decide placement. All offsets refer to the ORIGINAL, unmodified UTF-16 string.
enum NativeWholeWordWrap {
    @TaskLocal private static var initialWordObjectiveOverride: Bool?
    static var initialWordObjectiveEnabled: Bool {
        initialWordObjectiveOverride ?? (ProcessInfo.processInfo.environment["AIDOKU_INITIAL_WORD_OBJECTIVE"] == "1")
    }
    static func withInitialWordObjective<Value>(_ enabled:Bool, operation:() throws -> Value) rethrows -> Value {
        try $initialWordObjectiveOverride.withValue(enabled,operation:operation)
    }
    static var exploresCJKRowBudgets:Bool {
        ProcessInfo.processInfo.environment["AIDOKU_ROW_BUDGET_CJK"] != "0"
    }
    struct Row {
        let ownedRange: NSRange
        let paintedRange: NSRange
        let line: CTLine
        let advance: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        let leading: CGFloat
        let inkBounds: CGRect
        let hardBreak: Bool
        let overflow: CGFloat
        let discretionaryHyphen: Bool
        var hasInk: Bool { !inkBounds.isNull && !inkBounds.isEmpty && !inkBounds.isInfinite }
        var leftExtent: CGFloat { min(0, hasInk ? inkBounds.minX : 0) }
        var rightExtent: CGFloat { max(advance, hasInk ? inkBounds.maxX : 0) }
        var occupiedWidth: CGFloat { rightExtent - leftExtent }
        var upperExtent: CGFloat { max(ascent, hasInk ? inkBounds.maxY : 0) }
        var lowerExtent: CGFloat { max(descent, hasInk ? -inkBounds.minY : 0) }
        func centeredBaselineX(width: CGFloat) -> CGFloat { (width - occupiedWidth) / 2 - leftExtent }
    }
    struct Result {
        let text: String
        let attributedText: NSAttributedString
        let rows: [Row]
        let graphemeRanges: [NSRange]
        let unresolvedGlyphRanges: [NSRange]
        let fallbackRanges: [NSRange]
        let completeOwnership: Bool
        let requiredWidth: CGFloat
        let bodyHeight: CGFloat
        let requestedFontName: String
        let requestedFontSize: CGFloat
        var appliedTracking: CGFloat = 0
    }
    enum Failure: Error { case invalidInput, noFittingLayout }
    /// Keep each original hard paragraph and row budget while redistributing
    /// whole lexical units. Extra width need not collapse an aligned column.
    static func layoutPreservingRows(text:String,font:CTFont,size:CGFloat,width:CGFloat,
                                     originalRanges:[NSRange],color:CGColor,
                                     lineFactory:((NSAttributedString)->CTLine)?=nil,exploreCJK:Bool=true)throws->Result? {
        let ns=text as NSString
        guard !originalRanges.isEmpty else{return nil}
        var counts:[Int:Int]=[:],cursor=0
        for range in originalRanges {
            guard range.location==cursor,range.length>0,NSMaxRange(range)<=ns.length else{return nil}
            counts[ns.paragraphRange(for:NSRange(location:range.location,length:0)).location,default:0]+=1
            cursor=NSMaxRange(range)
        }
        guard cursor==ns.length else{return nil}
        let baseline=try layoutInternal(text:text,font:font,size:size,width:width,captionBoundaryRules:false,
            tracking:0,color:color,characterControl:false,necessaryCJK:true,lineFactory:lineFactory,
            bindForbiddenWhitespace:false,paragraphRows:counts,rowBudgetBreaks:Set(originalRanges.map(NSMaxRange)))
        var result=baseline
        let oldRanges=baseline.rows.map(\.ownedRange)
        let oldCuts=NativeRenderWrapQuality.wordCutOffsets(text,ranges:oldRanges).count
        let existingFit=baseline.completeOwnership && baseline.unresolvedGlyphRanges.isEmpty &&
            baseline.requiredWidth<=width+0.01 && baseline.rows.count==originalRanges.count
        if exploresCJKRowBudgets,exploreCJK,oldCuts>0 || !existingFit {
            let proposed=try layoutInternal(text:text,font:font,size:size,width:width,captionBoundaryRules:false,
                tracking:0,color:color,characterControl:false,necessaryCJK:true,lineFactory:lineFactory,
                bindForbiddenWhitespace:false,paragraphRows:counts,rowBudgetBreaks:Set(originalRanges.map(NSMaxRange)),
                exploreRowBudgetCJK:true)
            let newRanges=proposed.rows.map(\.ownedRange)
            let oldQuality=NativeRenderWrapQuality.evaluate(text,ranges:oldRanges)
            let newQuality=NativeRenderWrapQuality.evaluate(text,ranges:newRanges)
            if proposed.completeOwnership,proposed.unresolvedGlyphRanges.isEmpty,proposed.requiredWidth<=width+0.01,
               proposed.rows.count==originalRanges.count,newQuality.illegal<=oldQuality.illegal,
               newQuality.orphans<=oldQuality.orphans,
               !existingFit || NativeRenderWrapQuality.wordCutOffsets(text,ranges:newRanges).count<oldCuts {
                result=proposed
            }
        }
        guard result.completeOwnership,result.unresolvedGlyphRanges.isEmpty,
              result.requiredWidth<=width+0.01,result.rows.count==originalRanges.count else{return nil}
        var actual:[Int:Int]=[:]
        for row in result.rows {
            actual[ns.paragraphRange(for:NSRange(location:row.ownedRange.location,length:0)).location,default:0]+=1
        }
        return actual==counts ? result:nil
    }
    /// Smallest measured width that keeps the original number of rows. This
    /// lets an aligned source cohort improve word boundaries without changing
    /// its height merely because translations have different lexical lengths.
    /// The caller still checks quality, effects and final pixel-domain fit.
    static func widthPreservingRows(text:String,font:CTFont,size:CGFloat,minimumWidth:CGFloat,
                                    maximumWidth:CGFloat,rows:Int,color:CGColor,
                                    lineFactory:((NSAttributedString)->CTLine)?=nil)throws->CGFloat? {
        guard rows>0,minimumWidth.isFinite,maximumWidth.isFinite,
              minimumWidth>0,maximumWidth>=minimumWidth else{return nil}
        func measure(_ width:CGFloat)throws->Result {
            try layout(text:text,font:font,size:size,width:width,color:color,necessaryCJK:true,lineFactory:lineFactory)
        }
        func complete(_ result:Result,_ width:CGFloat)->Bool {
            result.completeOwnership && result.unresolvedGlyphRanges.isEmpty && result.requiredWidth<=width+0.01
        }
        let initial=try measure(minimumWidth)
        if complete(initial,minimumWidth),initial.rows.count==rows {return minimumWidth}
        // Growing width cannot restore rows already removed at the minimum.
        if complete(initial,minimumWidth),initial.rows.count<rows {return nil}
        let upper=try measure(maximumWidth)
        guard complete(upper,maximumWidth),upper.rows.count<=rows else{return nil}
        var lower=minimumWidth,higher=maximumWidth,best:CGFloat?=upper.rows.count==rows ? maximumWidth:nil
        for _ in 0..<12 {
            let middle=(lower+higher)/2,value=try measure(middle)
            if !complete(value,middle) || value.rows.count>rows {lower=middle}
            else {
                higher=middle
                if value.rows.count==rows {best=middle}
            }
        }
        return best
    }
    /// The visible row fragment, while all ownership ranges retain the original
    /// UTF16 text. Shared by production shaping and styled corpus rendering.
    static func paintedFragment(_ attributed:NSAttributedString,range:NSRange,discretionaryHyphen:Bool)->NSAttributedString {
        let fragment=attributed.attributedSubstring(from:range)
        guard discretionaryHyphen else{return fragment}
        let decorated=NSMutableAttributedString(attributedString:fragment)
        decorated.replaceCharacters(in:NSRange(location:decorated.length-1,length:1),with:"\u{2010}")
        return decorated
    }

    static func layout(text:String,font:CTFont,size:CGFloat,width:CGFloat,
        tracking:CGFloat=0,color:CGColor=CGColor(gray:0,alpha:1),
        characterControl:Bool=false,necessaryCJK:Bool=false,
        lineFactory:((NSAttributedString)->CTLine)?=nil) throws -> Result {
        let initial = try layoutWithTracking(text:text,font:font,size:size,width:width,
            tracking:tracking,color:color,characterControl:characterControl,
            necessaryCJK:necessaryCJK,lineFactory:lineFactory)
        guard necessaryCJK, !characterControl, initial.completeOwnership,
              initial.unresolvedGlyphRanges.isEmpty, initial.requiredWidth > width + 0.01,
              text.contains(where: { NativeLineBreakPolicy.isSpace($0) && !NativeLineBreakPolicy.isBreak($0)
                  && $0 != "\u{00A0}" && $0 != "\u{202F}" }) else { return initial }
        // Preserve every existing fit, including its native font/tracking and
        // exact source rows. Only an unresolved overflow needs broader evidence.
        let repaired = try layoutWithTracking(text:text,font:font,size:size,width:width,
            tracking:tracking,color:color,characterControl:characterControl,
            necessaryCJK:necessaryCJK,lineFactory:lineFactory,bindForbiddenWhitespace:true)
        guard repaired.completeOwnership, repaired.unresolvedGlyphRanges.isEmpty,
              repaired.requiredWidth < initial.requiredWidth - 0.01 else { return initial }
        return repaired
    }
    private static func layoutWithTracking(text:String,font:CTFont,size:CGFloat,width:CGFloat,
        tracking:CGFloat=0,color:CGColor=CGColor(gray:0,alpha:1),
        characterControl:Bool=false,necessaryCJK:Bool=false,
        lineFactory:((NSAttributedString)->CTLine)?=nil, bindForbiddenWhitespace:Bool=false) throws -> Result {
        let initial = try layoutInternal(text:text,font:font,size:size,width:width,captionBoundaryRules:false,
            tracking:tracking,color:color,characterControl:characterControl,
            necessaryCJK:necessaryCJK,lineFactory:lineFactory,bindForbiddenWhitespace:bindForbiddenWhitespace)
        // Compare the word-first objective before global frame selection. A
        // later owner-only repair can no longer change a packed peer's shape.
        // Keep the existing complete proposal unless the same measured width,
        // font, tracking and row budget improve lexical cuts without overflow.
        if initialWordObjectiveEnabled,
           necessaryCJK, !characterControl, initial.completeOwnership,
           initial.unresolvedGlyphRanges.isEmpty, initial.requiredWidth <= width + 0.01,
           NativeRenderWrapQuality.wordCutOffsets(text, ranges: initial.rows.map(\.ownedRange)).count > 0 {
            do {
                let candidate = try layoutInternal(text:text,font:font,size:size,width:width,captionBoundaryRules:false,
                    tracking:tracking,color:color,characterControl:false,necessaryCJK:true,lineFactory:lineFactory,
                    bindForbiddenWhitespace:bindForbiddenWhitespace,preferWholeWords:true)
                if candidate.completeOwnership, candidate.unresolvedGlyphRanges.isEmpty,
                   candidate.requiredWidth <= width + 0.01, candidate.rows.count <= initial.rows.count,
                   candidate.bodyHeight <= initial.bodyHeight + 0.01,
                   NativeRenderWrapQuality.wordCutOffsets(text,ranges:candidate.rows.map(\.ownedRange)).count <
                       NativeRenderWrapQuality.wordCutOffsets(text,ranges:initial.rows.map(\.ownedRange)).count {
                    let before = NativeRenderWrapQuality.evaluate(text,ranges:initial.rows.map(\.ownedRange))
                    let after = NativeRenderWrapQuality.evaluate(text,ranges:candidate.rows.map(\.ownedRange))
                    if after.illegal <= before.illegal, after.orphans <= before.orphans { return candidate }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        guard tracking == 0, !characterControl, initial.completeOwnership,
              initial.unresolvedGlyphRanges.isEmpty, initial.requiredWidth > width + 0.01 else { return initial }
        let gaps = initial.rows.map { max(0, (text as NSString).substring(with: $0.paintedRange).count - 1) }.max() ?? 0
        guard gaps > 0, initial.requiredWidth - width <= size * NativeTextSpacing.maximumTrackingReduction * CGFloat(gaps) else {
            return initial
        }
        for fraction: CGFloat in [0.01, 0.02, NativeTextSpacing.maximumTrackingReduction] {
            let candidate = try layoutInternal(text:text,font:font,size:size,width:width,captionBoundaryRules:false,
                tracking:-size*fraction,color:color,characterControl:false,
                necessaryCJK:necessaryCJK,lineFactory:lineFactory,bindForbiddenWhitespace:bindForbiddenWhitespace)
            guard candidate.completeOwnership, candidate.unresolvedGlyphRanges.isEmpty,
                  candidate.rows.map(\.ownedRange) == initial.rows.map(\.ownedRange),
                  candidate.requiredWidth <= width + 0.01 else { continue }
            return candidate
        }
        return initial
    }
    static func layoutCaption(text:String,font:CTFont,size:CGFloat,width:CGFloat,color:CGColor) throws -> Result {
        try layoutInternal(text:text,font:font,size:size,width:width,captionBoundaryRules:true,
            color:color,characterControl:true)
    }
    static func layoutInternal(text: String, font: CTFont, size: CGFloat, width: CGFloat,
                       captionBoundaryRules: Bool, tracking: CGFloat = 0, color: CGColor = CGColor(gray: 0, alpha: 1),
                       characterControl: Bool = false, necessaryCJK: Bool = false, lineFactory: ((NSAttributedString) -> CTLine)? = nil,
                       bindForbiddenWhitespace: Bool = false,paragraphRows:[Int:Int]?=nil,
                       rowBudgetBreaks:Set<Int>=[],exploreRowBudgetCJK:Bool=false,preferWholeWords:Bool=false) throws -> Result {
        guard size.isFinite, size > 0, width.isFinite, width > 0, tracking.isFinite else {
            throw Failure.invalidInput
        }
        let primary = CTFontCreateCopyWithAttributes(font, size, nil, nil)
        let ns = text as NSString
        let attributed = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): primary,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        // Absence uses the face's own kerning; explicit zero overrides it.
        if tracking != 0 { attributed.addAttribute(.init(kCTKernAttributeName as String), value: tracking,
            range: NSRange(location: 0, length: ns.length)) }
        var graphemes: [NSRange] = [], fallback: [NSRange] = []
        var offset = 0
        for character in text {
            let fragment = String(character)
            let range = NSRange(location: offset, length: fragment.utf16.count)
            graphemes.append(range)
            // Resolve an entire extended grapheme; never split surrogate pairs,
            // decomposed Hangul, combining sequences, or an emoji ZWJ family.
            let face = CTFontCreateForString(primary, fragment as CFString,
                                            CFRange(location: 0, length: range.length))
            if CTFontCopyPostScriptName(face) != CTFontCopyPostScriptName(primary) {
                attributed.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: face, range: range)
                fallback.append(range)
            }
            offset += range.length
        }
        let characters = Array(text)
        let directionalControls = characters.map(NativeLineBreakPolicy.isDirectionalControl)
        var previousSemantic = [Int](repeating: -1, count: characters.count+1)
        var followingSemantic = [Int](repeating: characters.count, count: characters.count+1)
        for i in characters.indices { previousSemantic[i+1] = directionalControls[i] ? previousSemantic[i] : i }
        for i in characters.indices.reversed() { followingSemantic[i] = directionalControls[i] ? followingSemantic[i+1] : i }
        func isDiscretionaryHint(_ index: Int) -> Bool {
            guard index >= 0, index < characters.count, characters[index] == "\u{00AD}" else { return false }
            let before = previousSemantic[index], after = followingSemantic[index+1]
            return before >= 0 && after < characters.count &&
                (characters[before].isLetter || characters[before].isNumber) &&
                (characters[after].isLetter || characters[after].isNumber)
        }
        let boundaryIndex = Dictionary(uniqueKeysWithValues: graphemes.enumerated().map { ($0.element.location, $0.offset) } + [(ns.length, graphemes.count)])
        let breakFlags = characters.map { NativeLineBreakPolicy.isBreak($0) }
        let spaceFlags = characters.map { NativeLineBreakPolicy.isSpace($0) }
        var nextVisible = [Int](repeating: graphemes.count, count: graphemes.count + 1)
        var previousVisible = [Int](repeating: -1, count: graphemes.count + 1)
        var letterCounts = [Int](repeating: 0, count: graphemes.count + 1)
        for i in graphemes.indices {
            previousVisible[i+1] = !spaceFlags[i] && !breakFlags[i] ? i : previousVisible[i]
            letterCounts[i+1] = letterCounts[i] + (characters[i].isLetter ? 1 : 0)
        }
        for i in graphemes.indices.reversed() {
            nextVisible[i] = !spaceFlags[i] && !breakFlags[i] ? i : nextVisible[i+1]
        }
        func isBreak(_ range: NSRange) -> Bool { breakFlags[boundaryIndex[range.location]!] }
        func isSpace(_ range: NSRange) -> Bool { spaceFlags[boundaryIndex[range.location]!] }
        func trim(_ range: NSRange) -> NSRange {
            let start = boundaryIndex[range.location]!, end = boundaryIndex[NSMaxRange(range)]!
            let first = nextVisible[start], last = previousVisible[end]
            guard first < end && last >= first else { return NSRange(location: range.location, length: 0) }
            return NSRange(location: graphemes[first].location, length: NSMaxRange(graphemes[last]) - graphemes[first].location)
        }
        struct RowMeasurementKey: Hashable {
            let range: NSRange
            let hard: Bool
            let discretionaryHyphen: Bool
        }
        // Font/fallback attributes, text, tracking and width are immutable for
        // this invocation. Reuse complete measurements across DP passes and
        // reconstruction, not just CTLines whose metrics would be read again.
        // Bounds limit retained objects/UTF16 units, not opaque CoreText bytes.
        var measuredRows: [RowMeasurementKey: Row] = [:]
        var measuredUnits = 0
        func makeRow(_ range: NSRange, hard: Bool, discretionaryHyphen: Bool = false) -> Row {
            let key = RowMeasurementKey(range: range, hard: hard, discretionaryHyphen: discretionaryHyphen)
            if let measured = measuredRows[key] { return measured }
            let paint = trim(range)
            let fragment=paintedFragment(attributed,range:paint,discretionaryHyphen:discretionaryHyphen)
            let line = lineFactory?(fragment) ?? CTLineCreateWithAttributedString(fragment)
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
            if paint.length == 0 { a = CTFontGetAscent(primary); d = CTFontGetDescent(primary) }
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let row = Row(ownedRange: range, paintedRange: paint, line: line, advance: advance,
                       ascent: a, descent: d, leading: l, inkBounds: ink, hardBreak: hard,
                       overflow: max(0, max(advance, ink.maxX) - min(0, ink.minX) - width),
                       discretionaryHyphen: discretionaryHyphen)
            if range.length <= 2048, measuredRows.count < 256, measuredUnits + range.length <= 32768 {
                measuredRows[key] = row
                measuredUnits += range.length
            }
            return row
        }
        let legal = NativeLineBreakPolicy.legalOffsets(text: text)
        let semantic = NativeLineBreakPolicy.preferredOffsets(text: text).intersection(legal)
        let necessary = necessaryCJK ? NativeNecessaryCJKBreaks.propose(text:text,attributed:attributed,
            physicalWidth:width,lineFactory:lineFactory,legalOffsets:legal,
            bindForbiddenWhitespace:bindForbiddenWhitespace).offsets : Set<Int>()
        // Row-budget callers retain both their ordinary and exact DP unchanged.
        let wholeWordFirst = preferWholeWords && paragraphRows == nil
        var rows: [Row] = []
        var paragraphStart = 0
        func paragraph(end: Int, terminatorEnd: Int) throws {
            func oldWordCut(_ boundary:Int)->Bool {
                guard rowBudgetBreaks.contains(boundary),boundary<end,let k=boundaryIndex[boundary],
                      k>0,k<characters.count else{return false}
                return (characters[k-1].isLetter || characters[k-1].isNumber) &&
                    (characters[k].isLetter || characters[k].isNumber)
            }
            let members = Array(graphemes[boundaryIndex[paragraphStart]!..<boundaryIndex[end]!])
            let paragraphSemantics = semantic.filter { boundary in
                guard boundary > paragraphStart && boundary < end else { return false }
                // Separate an expressive tail only when both the complete
                // preceding utterance and the complete tail fit one row each.
                // A long paragraph must not gain a decorative extra row.
                if NativeLineBreakPolicy.isExpressiveTailBoundary(text: text, offset: boundary) {
                    return makeRow(NSRange(location: paragraphStart, length: boundary - paragraphStart), hard: false).occupiedWidth <= width &&
                        makeRow(NSRange(location: boundary, length: end - boundary), hard: false).occupiedWidth <= width
                }
                return true
            }
            let preferSemantic = !paragraphSemantics.isEmpty &&
                makeRow(NSRange(location: paragraphStart, length: end - paragraphStart), hard: false).occupiedWidth > width
            func semanticPenalty(_ range: NSRange) -> Double {
                guard preferSemantic else { return 0 }
                return Double(paragraphSemantics.filter { $0 > range.location && $0 < NSMaxRange(range) }.count) * 3
            }
            // A fixed row budget may require a different legal CJK cut even
            // when each individual word fits this width. Reusing only the old
            // cuts prevents the allocator from finding fewer total word cuts.
            // Keep ordinary wrapping and Latin words unchanged.
            let exploreBudget = paragraphRows?[paragraphStart] != nil && members.count <= 96 && exploreRowBudgetCJK
            let budgetCuts:Set<Int> = exploreBudget ? Set(members.dropLast().compactMap {range in
                let boundary=NSMaxRange(range)
                guard let k=boundaryIndex[boundary],k>0,k<characters.count,
                      characters[k-1].isLetter,characters[k].isLetter,
                      NativeNecessaryCJKBreaks.cjk(String(characters[k-1])) ||
                        NativeNecessaryCJKBreaks.cjk(String(characters[k])),
                      legal.contains(boundary) else{return nil}
                return boundary
            }):[]
            var ends: [Int] = []
            for (i, range) in members.enumerated() {
                if characterControl || paragraphSemantics.contains(NSMaxRange(range)) || necessary.contains(NSMaxRange(range)) || budgetCuts.contains(NSMaxRange(range)) || rowBudgetBreaks.contains(NSMaxRange(range)) ||
                    isDiscretionaryHint(boundaryIndex[range.location]!) ||
                    (isSpace(range) && (i + 1 == members.count || !isSpace(members[i+1]))) {
                    if NSMaxRange(range) < end && !legal.contains(NSMaxRange(range)) { continue }
                    ends.append(NSMaxRange(range))
                }
            }
            if ends.last != end { ends.append(end) }
            ends = ends.filter { $0 > paragraphStart }
            if ends.isEmpty {
                rows.append(makeRow(NSRange(location: paragraphStart, length: terminatorEnd - paragraphStart), hard: terminatorEnd > end))
                return
            }
            // Necessary narrow homogeneous paired-run fallback. The ordinary
            // complete native CTLine has actually overflowed, and its ordinary
            // legal endpoint graph has no internal boundary. Source text is
            // unchanged: these are original contiguous UTF16 ownership ranges.
            func necessaryPairedPieces() -> [NSRange]? {
                guard !captionBoundaryRules, !characterControl, paragraphRows == nil,
                      paragraphStart == 0, end == ns.length, terminatorEnd == end,
                      (2...32).contains(members.count),
                      let first = characters.first, NativeLineBreakPolicy.pairedRun.contains(first),
                      characters.allSatisfy({ $0 == first }),
                      !members.dropLast().contains(where: { legal.contains(NSMaxRange($0)) }),
                      makeRow(NSRange(location: 0, length: end), hard: false).occupiedWidth > width + 0.01 else { return nil }
                // At most two balanced native measurements; e.g. 3+2 and 2+3.
                // Do not insert scalar/newline characters or split a grapheme.
                let splits = Array(Set([(members.count + 1)/2, members.count/2])).sorted(by: >)
                var best: [NSRange]?, bestWidth = CGFloat.infinity
                for split in splits {
                    let boundary = members[split].location
                    let pieces = [NSRange(location: 0, length: boundary), NSRange(location: boundary, length: end-boundary)]
                    let measured = pieces.map { makeRow($0, hard: false).occupiedWidth }
                    guard measured.allSatisfy({ $0 <= width + 0.01 }) else { continue }
                    let widest = measured.max() ?? .infinity
                    if widest < bestWidth { best = pieces; bestWidth = widest }
                }
                return best
            }
            let starts = [paragraphStart] + ends
            let n = ends.count
            // Ordinary and fixed-row-budget wrapping optimize the same shaped
            // row objective. Only the graph traversal/row constraint differs;
            // keep readability and physical-fit decisions in this one place.
            func edgeScore(_ i: Int, _ j: Int, prefix: Double = 0) -> Double {
                let boundary = ends[j-1]
                let range = NSRange(location: starts[i], length: boundary - starts[i])
                let discretionary = boundary < end && isDiscretionaryHint(boundaryIndex[boundary]!-1)
                let row = makeRow(range, hard: false, discretionaryHyphen: discretionary)
                if wholeWordFirst {
                    if row.occupiedWidth > width { return .infinity }
                } else if row.overflow > 0.01 && j > i+1 { return .infinity }
                let ragged = pow(Double(max(0, width-row.occupiedWidth)/width), 2)
                let letters = letterCounts[boundaryIndex[NSMaxRange(row.paintedRange)]!] -
                    letterCounts[boundaryIndex[row.paintedRange.location]!]
                let singleton = letters == 1 && n > 1 ? 8.0 : 0
                let over = Double(row.overflow/width)
                let internalPenalty = necessary.contains(boundary) || budgetCuts.contains(boundary) ||
                    discretionary || oldWordCut(boundary) ? 4.0 : 0
                let k = boundaryIndex[boundary]!, before = previousSemantic[k], after = followingSemantic[k]
                let internalBreak: Double = captionBoundaryRules && characterControl && before >= 0 && after < characters.count &&
                    characters[before].isLetter && characters[after].isLetter ? 4 : 0
                // Relative shaped occupancy discourages isolated tails and
                // balances centered rows without language/length-specific rules.
                let tail = j == n && i > 0
                    ? pow(Double(max(0, 0.35 - row.occupiedWidth / width)), 2) * 16 : 0
                // Include the prefix here to preserve ordinary DP arithmetic
                // ordering, including ties between near-identical native widths.
                return prefix + internalPenalty + internalBreak + 1 + tail
                    + ragged + singleton + over * over * 100 + semanticPenalty(range)
            }
            var cost = [Double](repeating: .infinity, count: n+1)
            var previous = [Int](repeating: 0, count: n+1)
            var cuts = wholeWordFirst ? [Int](repeating: Int.max, count: n+1) : []
            if wholeWordFirst { cuts[0] = 0 }
            cost[0] = 0
            // DP over whole lexical units, bounded by paragraph length. Overwide
            // single units survive intact in legacy mode and declare requiredWidth
            // to the allocator. Whole-word-first admits only physically fitting edges.
            for j in 1...n {
                // Match wordCutOffsets: immediate original grapheme adjacency,
                // including digits, without skipping controls or whitespace.
                let k = boundaryIndex[ends[j-1]]!
                let wordCut = wholeWordFirst && ends[j-1] < end && k > 0 && k < characters.count &&
                    (characters[k-1].isLetter || characters[k-1].isNumber) &&
                    (characters[k].isLetter || characters[k].isNumber) ? 1 : 0
                for i in 0..<j {
                    // All remaining score terms are nonnegative. A candidate
                    // that cannot improve this endpoint needs no shaping.
                    if wholeWordFirst {
                        guard cost[i].isFinite else { continue }
                        let candidateCuts = cuts[i] + wordCut
                        if candidateCuts > cuts[j] || (candidateCuts == cuts[j] && cost[i] + 1 >= cost[j]) { continue }
                    } else if cost[i] + 1 >= cost[j] { continue }
                    let score = edgeScore(i, j, prefix: cost[i])
                    guard score.isFinite else { continue }
                    if wholeWordFirst {
                        let candidateCuts = cuts[i] + wordCut
                        if candidateCuts < cuts[j] || (candidateCuts == cuts[j] && score < cost[j]) {
                            cuts[j] = candidateCuts; cost[j] = score; previous[j] = i
                        }
                    } else if score < cost[j] { cost[j] = score; previous[j] = i }
                }
            }
            // Never reconstruct a fabricated zero-cut oversized row when no
            // fitting path exists in the existing bounded endpoint graph.
            if wholeWordFirst && !cost[n].isFinite {
                if let pieces = necessaryPairedPieces() {
                    rows.append(contentsOf: pieces.map { makeRow($0, hard: false) })
                    return
                }
                throw Failure.noFittingLayout
            }
            var pieces: [NSRange] = []
            var j = n
            while j > 0 {
                let i = previous[j]
                pieces.append(NSRange(location: starts[i], length: ends[j-1] - starts[i]))
                j = i
            }
            pieces.reverse()
            if pieces.count == 1, makeRow(pieces[0], hard: false).occupiedWidth > width + 0.01,
               let necessary = necessaryPairedPieces() { pieces = necessary }
            if let wanted=paragraphRows?[paragraphStart],wanted != pieces.count,
               wanted>0,wanted<=n,n<=256,wanted*n<=16_384 {
                // Constrain the lexical DP by the old paragraph's row budget.
                // The ordinary DP above remains unchanged for every old call.
                var exact=Array(repeating:Array(repeating:Double.infinity,count:n+1),count:wanted+1)
                var previousExact=Array(repeating:Array(repeating:-1,count:n+1),count:wanted+1)
                var edges:[Int:Double]=[:]
                func edge(_ i:Int,_ j:Int)->Double {
                    let key=i*(n+1)+j
                    if let cached=edges[key] {return cached}
                    let score = edgeScore(i, j)
                    edges[key]=score;return score
                }
                exact[0][0]=0
                for count in 1...wanted {
                    for endIndex in count...n {
                        for startIndex in (count-1)..<endIndex where exact[count-1][startIndex].isFinite {
                            let score=exact[count-1][startIndex]+edge(startIndex,endIndex)
                            if score<exact[count][endIndex] {
                                exact[count][endIndex]=score;previousExact[count][endIndex]=startIndex
                            }
                        }
                    }
                }
                if exact[wanted][n].isFinite {
                    var constrained:[NSRange]=[],endIndex=n
                    for count in stride(from:wanted,through:1,by:-1) {
                        let startIndex=previousExact[count][endIndex]
                        constrained.append(NSRange(location:starts[startIndex],length:ends[endIndex-1]-starts[startIndex]))
                        endIndex=startIndex
                    }
                    pieces=constrained.reversed()
                }
            }
            for (i, piece) in pieces.enumerated() {
                let last = i == pieces.count-1
                let owned = NSRange(location: piece.location, length: piece.length + (last ? terminatorEnd-end : 0))
                let discretionary = !last && isDiscretionaryHint(boundaryIndex[NSMaxRange(piece)]!-1)
                rows.append(makeRow(owned, hard: last && terminatorEnd > end, discretionaryHyphen: discretionary))
            }
        }
        for range in graphemes where isBreak(range) {
            try paragraph(end: range.location, terminatorEnd: NSMaxRange(range))
            paragraphStart = NSMaxRange(range)
        }
        if paragraphStart < ns.length { try paragraph(end: ns.length, terminatorEnd: ns.length) }
        // Empty input has zero rows; trailing newline remains owned by prior row.
        var cursor = 0
        var complete = true
        let boundaries = Set([0] + graphemes.map { NSMaxRange($0) })
        for row in rows {
            complete = complete && row.ownedRange.location == cursor && boundaries.contains(cursor)
                && boundaries.contains(NSMaxRange(row.ownedRange))
            cursor = NSMaxRange(row.ownedRange)
        }
        complete = complete && cursor == ns.length
        var missing: [NSRange] = graphemes.filter { range in
            ns.substring(with: range).unicodeScalars.contains { $0.properties.generalCategory == .unassigned }
        }
        for row in rows {
            for run in CTLineGetGlyphRuns(row.line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let actualFont = attributes[kCTFontAttributeName] as! CTFont
                let lastResort = (CTFontCopyPostScriptName(actualFont) as String).lowercased().contains("lastresort")
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for i in 0..<count where glyphs[i] == 0 || lastResort {
                    let index = row.paintedRange.location + indices[i]
                    if let range = graphemes.first(where: { NSLocationInRange(index, $0) }) {
                        let visible = (row.discretionaryHyphen && NSMaxRange(range) == NSMaxRange(row.paintedRange)) ||
                            ns.substring(with: range).unicodeScalars.contains {
                            !CharacterSet.controlCharacters.contains($0) && $0.value != 0x200d && !(0xfe00...0xfe0f).contains($0.value)
                        }
                        let unassigned = ns.substring(with: range).unicodeScalars.contains { $0.properties.generalCategory == .unassigned }
                        if (visible || unassigned) && !missing.contains(range) { missing.append(range) }
                    }
                }
            }
        }
        return Result(text: text, attributedText: attributed, rows: rows, graphemeRanges: graphemes,
                      unresolvedGlyphRanges: missing, fallbackRanges: fallback, completeOwnership: complete,
                      requiredWidth: rows.map { $0.occupiedWidth }.max() ?? 0,
                      bodyHeight: rows.reduce(0) { $0 + $1.upperExtent + $1.lowerExtent + max($1.leading, size*0.12) },
                      requestedFontName: CTFontCopyPostScriptName(primary) as String, requestedFontSize: size, appliedTracking: tracking)
    }
}
