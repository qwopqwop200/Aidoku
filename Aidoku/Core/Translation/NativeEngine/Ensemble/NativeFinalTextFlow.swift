import CoreGraphics
import CoreText
import Foundation

/// Final output consumes these exact measured rows, without a second breaker.
enum NativeFinalTextFlow {
    /// Measured positioning is supplied by the native caller's row certificate.
    /// The low-level flow module does not depend on page/source-style recovery.
    typealias RowPositioner = (NativeWholeWordWrap.Result, CGFloat) throws -> NativeWholeWordGlyphPainter.PositionedRows
    /// A blocked refinement must not discard independent improvements on the
    /// same page. Retry only the reported selected owner, then boundedly fall
    /// back for the remaining refinements. Cancellation always propagates.
    static func withOwnerRefinementFallback<Value>(
        rejectedOwners: (Error)->Set<String>?,
        recoverRefinement: ((Set<String>)->Bool)? = nil,
        _ attempt: (_ excluded:Set<String>, _ record:(String)->Void)throws->Value
    )throws->(value:Value,excludedOwners:Set<String>) {
        var excluded=Set<String>()
        let limit=recoverRefinement == nil ? 33:65
        for retry in 0...limit {
            var selected=Set<String>()
            do {return (try attempt(excluded,{selected.insert($0)}),excluded)}
            catch {
                guard !(error is CancellationError)else{throw error}
                try Task.checkCancellation()
                let available=selected.subtracting(excluded)
                guard !available.isEmpty,retry<limit else{throw error}
                let rejected=(rejectedOwners(error) ?? available).intersection(available)
                let responsible=rejected.isEmpty ? available:rejected
                if retry<limit-1,recoverRefinement?(responsible)==true {continue}
                if retry<limit-1,let owner=responsible.sorted().first {excluded.insert(owner)}
                else {excluded.formUnion(available)}
            }
        }
        preconditionFailure("Bounded refinement retry exhausted without a terminal attempt")
    }
    /// The final alpha/domain solver can reject a geometrically valid wider
    /// proposal. Retry the original algorithm once, only after a refinement was
    /// actually selected. Cancellation and failures without refinement propagate.
    static func withRefinementFallback<Value>(
        _ attempt: (_ allowRefinement: Bool, _ recordRefinement: () -> Void) throws -> Value
    ) throws -> (value: Value, usedBaselineRetry: Bool) {
        var selectedRefinement = false
        do {
            return (try attempt(true, { selectedRefinement = true }), false)
        } catch {
            guard selectedRefinement, !(error is CancellationError) else { throw error }
            try Task.checkCancellation()
            return (try attempt(false, {}), true)
        }
    }

    struct Quality {
        let softOrphans: Int
        let wordCuts: Int
        let tailWidthCandidates: [CGFloat]
        var nextTailWidth: CGFloat? { tailWidthCandidates.first }

        var audit: [String: Any] {
            ["softOrphans": softOrphans, "wordCuts": wordCuts,
             "nextTailWidthPixels": nextTailWidth.map { Double($0) as Any } ?? NSNull(),
             "tailWidthCandidatesPixels": tailWidthCandidates.map(Double.init)]
        }
    }

    struct Plan {
        struct RowBounds {
            let glyphPath: CGRect
            let imageAndGlyphPath: CGRect
        }

        let lines: [CTLine]
        let ranges: [NSRange]
        let baselines: [CGPoint] // local top-left coordinates
        let size: CGSize
        let visibleUTF16: Int
        let complete: Bool
        let appliedTracking: CGFloat
        let discretionaryHyphenOffsets: [Int]
        let quality: Quality?
        var refinementOriginWidth: CGFloat? = nil
        let verticalFrame: CTFrame?
        var horizontalRowBounds: [RowBounds]? = nil
        var contourWordDiagnostics: [String: Any]? = nil

        func glyphPathBounds(at index: Int) -> CGRect {
            horizontalRowBounds?[index].glyphPath ?? CTLineGetBoundsWithOptions(lines[index], [.useGlyphPathBounds])
        }

        func imageAndGlyphPathBounds(at index: Int) -> CGRect {
            horizontalRowBounds?[index].imageAndGlyphPath ?? CTLineGetImageBounds(lines[index], nil)
                .union(glyphPathBounds(at: index))
        }

        var inkBounds: CGRect {
            lines.indices.reduce(CGRect.null) { bounds, i in
                let ink = imageAndGlyphPathBounds(at: i)
                guard !ink.isNull, !ink.isEmpty else { return bounds }
                return bounds.union(CGRect(x: baselines[i].x + ink.minX, y: baselines[i].y - ink.maxY,
                    width: ink.width, height: ink.height))
            }
        }

        /// Horizontal rows are painted from explicit baselines, not a CTFrame.
        /// Paragraph attributes alone therefore cannot change their alignment.
        /// Keep default centered plans byte-for-byte and move only row origins
        /// for an explicit edge alignment, before domain and peer admission.
        func aligned(_ alignment: CTTextAlignment) -> Plan {
            guard verticalFrame == nil, alignment == .left || alignment == .right else { return self }
            let positions = lines.indices.map { index -> CGPoint in
                let bounds = imageAndGlyphPathBounds(at: index)
                guard !bounds.isNull, !bounds.isEmpty else { return baselines[index] }
                return CGPoint(x: alignment == .left ? -bounds.minX : size.width - bounds.maxX,
                    y: baselines[index].y)
            }
            return Plan(lines: lines, ranges: ranges, baselines: positions, size: size,
                visibleUTF16: visibleUTF16, complete: complete, appliedTracking: appliedTracking,
                discretionaryHyphenOffsets: discretionaryHyphenOffsets, quality: quality,
                refinementOriginWidth: refinementOriginWidth, verticalFrame: nil,
                horizontalRowBounds: horizontalRowBounds,
                contourWordDiagnostics: contourWordDiagnostics)
        }

        func centered(height: CGFloat, usingInkCapacity:Bool=false) -> Plan? {
            let ink = inkBounds
            // CT line boxes include transparent leading. Fixed-font capacity
            // can use the complete retained ink instead, while every caller
            // still owns actual effects/domain/peer admission after drawing.
            guard verticalFrame == nil, height.isFinite,
                  (usingInkCapacity ? (height>0 && !ink.isNull && !ink.isEmpty) : height >= size.height - 0.01),
                  ink.isNull || ink.height <= height + 0.01 else { return nil }
            let shift = ink.isNull ? 0 : height / 2 - ink.midY
            return Plan(lines: lines, ranges: ranges,
                baselines: baselines.map { CGPoint(x: $0.x, y: $0.y + shift) },
                size: CGSize(width: size.width, height: height), visibleUTF16: visibleUTF16,
                complete: complete, appliedTracking: appliedTracking,
                discretionaryHyphenOffsets: discretionaryHyphenOffsets, quality: quality,
                refinementOriginWidth: refinementOriginWidth, verticalFrame: nil,
                horizontalRowBounds: horizontalRowBounds,
                contourWordDiagnostics: contourWordDiagnostics)
        }

        func draw(in context: CGContext, box: CGRect, pageHeight: CGFloat) {
            if let verticalFrame {
                CTFrameDraw(verticalFrame, context)
            } else {
                for (line, baseline) in zip(lines, baselines) {
                    context.textPosition = CGPoint(x: box.minX + baseline.x,
                        y: pageHeight - box.minY - baseline.y)
                    CTLineDraw(line, context)
                }
            }
        }
    }

    static func horizontal(text: String, font: CTFont, size: CGFloat, width: CGFloat,
                           minimumLineHeight: CGFloat, outwardExtent: CGFloat, color: CGColor,
                           lineFactory: ((NSAttributedString) -> CTLine)? = nil) throws -> Plan? {
        if NativeSimpleTextLayout.enabled {
            return try horizontalPlan(NativeSimpleTextLayout.layout(text: text, font: font, size: size, width: width, color: color),
                width: width, minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent, lineFactory: lineFactory)
        }
        let wrapped = try NativeWholeWordWrap.layout(text: text, font: font, size: size,
            width: width, color: color, necessaryCJK: true, lineFactory: lineFactory)
        return try horizontalPlan(wrapped, width: width, minimumLineHeight: minimumLineHeight,
            outwardExtent: outwardExtent, lineFactory: lineFactory)
    }

    /// One immutable-width proposal after global shape selection. No tracking
    /// repair, wider word search, row-budget search or fallback recursion.
    static func horizontalFixedWidth(text:String,font:CTFont,size:CGFloat,width:CGFloat,
                                     minimumLineHeight:CGFloat,outwardExtent:CGFloat,color:CGColor,
                                     lineFactory:((NSAttributedString)->CTLine)?=nil,
                                     preferWholeWords:Bool=false,
                                     certifiedPositioner:RowPositioner?=nil)throws->Plan? {
        if NativeSimpleTextLayout.enabled {
            return try horizontalPlan(NativeSimpleTextLayout.layout(text: text, font: font, size: size, width: width, color: color),
                width: width, minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent,
                lineFactory: lineFactory, certifiedPositioner: certifiedPositioner)
        }
        var wrapped=try NativeWholeWordWrap.layoutInternal(text:text,font:font,size:size,width:width,
            captionBoundaryRules:false,tracking:0,color:color,necessaryCJK:true,lineFactory:lineFactory,
            preferWholeWords:preferWholeWords)
        if !preferWholeWords, NativeWholeWordWrap.initialWordObjectiveEnabled,
           wrapped.completeOwnership, wrapped.unresolvedGlyphRanges.isEmpty, wrapped.requiredWidth <= width + 0.01 {
            let candidate = try NativeWholeWordWrap.layout(text:text,font:font,size:size,width:width,
                color:color,necessaryCJK:true,lineFactory:lineFactory)
            if candidate.appliedTracking == 0, candidate.completeOwnership, candidate.unresolvedGlyphRanges.isEmpty,
               candidate.requiredWidth <= width + 0.01, candidate.rows.count <= wrapped.rows.count,
               candidate.bodyHeight <= wrapped.bodyHeight + 0.01,
               NativeRenderWrapQuality.wordCutOffsets(text,ranges:candidate.rows.map(\.ownedRange)).count <
                   NativeRenderWrapQuality.wordCutOffsets(text,ranges:wrapped.rows.map(\.ownedRange)).count {
                wrapped = candidate
            }
        }
        return try horizontalPlan(wrapped,width:width,minimumLineHeight:minimumLineHeight,
            outwardExtent:outwardExtent,lineFactory:lineFactory,certifiedPositioner:certifiedPositioner)
    }

    /// Explicit terminal contour alternative only. Reuse the ordinary centered
    /// row positioning and reject any change to the retained common pitch.
    static func horizontalContourWords(text:String,font:CTFont,size:CGFloat,width:CGFloat,
                                       minimumLineHeight:CGFloat,outwardExtent:CGFloat,
                                       policy:NativeTextExpansionPolicy,page:CGRect,anchor:CGRect,
                                       originalRanges:[NSRange],color:CGColor,
                                       lineFactory:((NSAttributedString)->CTLine)?=nil)throws->Plan? {
        if NativeSimpleTextLayout.enabled {
            return try horizontalPlan(NativeSimpleTextLayout.layout(text: text, font: font, size: size, width: width, color: color),
                width: width, minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent, lineFactory: lineFactory)
        }
        guard let proposal=try NativeContourWordWrap.layout(text:text,font:font,size:size,width:width,
            pitch:minimumLineHeight,outwardExtent:outwardExtent,policy:policy,page:page,anchor:anchor,
            originalRanges:originalRanges,color:color,lineFactory:lineFactory),
              var plan=try horizontalPlan(proposal.wrapped,width:width,minimumLineHeight:minimumLineHeight,
                  outwardExtent:outwardExtent,lineFactory:lineFactory,retainedPitch:minimumLineHeight),
              plan.appliedTracking == 0,
              plan.baselines.indices.dropFirst().allSatisfy({
                  abs(plan.baselines[$0].y-plan.baselines[$0-1].y-minimumLineHeight)<0.0001
              }) else{return nil}
        plan.contourWordDiagnostics=proposal.diagnostics
        return plan
    }

    /// Content widths only. Measuring a broken token is not another layout
    /// proposal; adapters add their own exact effect/padding reservation.
    static func terminalExteriorContentWidths(text: String, ranges: [NSRange], font: CTFont,
                                              current: CGFloat, maximum: CGFloat) -> [CGFloat] {
        guard !NativeSimpleTextLayout.enabled else { return [] }
        guard current.isFinite, maximum.isFinite, current > 0, maximum >= current,
              NativeRenderWrapQuality.wordCutOffsets(text, ranges: ranges).count > 0 else { return [] }
        let styled = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        let measured = NativeRenderWrapQuality.wordJoinWidths(styled, ranges: ranges, includeAttachedPunctuation: true)
            .filter { $0.isFinite && $0 > current + 0.01 && $0 <= maximum }
        var widths = [current]
        for width in [measured.first, measured.last].compactMap({ $0 }) {
            if !widths.contains(where: { abs($0 - width) <= 0.01 }) { widths.append(width) }
        }
        return Array(widths.prefix(3))
    }

    /// Consume the exact measured width-fit rows; no second wrapping pass.
    static func horizontalSingleWidth(_ fit: NativeSimpleTextLayout.SingleWidthFit,
                                      outwardExtent: CGFloat, padding: CGFloat) throws -> Plan? {
        try horizontalPlan(fit.wrapped, width: fit.outerWidth - 2 * (outwardExtent + padding),
            minimumLineHeight: 0, outwardExtent: outwardExtent, lineFactory: nil,
            certifiedPositioner: { _, _ in fit.positioned })
    }

    private static func horizontalPlan(_ wrapped: NativeWholeWordWrap.Result, width: CGFloat,
                                       minimumLineHeight: CGFloat, outwardExtent: CGFloat,
                                       lineFactory: ((NSAttributedString) -> CTLine)?,
                                       retainedPitch: CGFloat? = nil, certifiedPositioner:RowPositioner?=nil) throws -> Plan? {
        guard wrapped.completeOwnership, wrapped.unresolvedGlyphRanges.isEmpty,
              wrapped.requiredWidth <= width + 0.01 else { return nil }
        let positioned: NativeWholeWordGlyphPainter.PositionedRows
        if let certifiedPositioner {
            positioned = try certifiedPositioner(wrapped,width)
        } else if let retainedPitch {
            positioned = try NativeWholeWordGlyphPainter.positionRetainedPitch(wrapped, width: width,
                pitch: retainedPitch, outwardExtent: outwardExtent)
        } else {
            positioned = try NativeWholeWordGlyphPainter.position(wrapped, width: width,
                minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent)
        }
        return Plan(lines: wrapped.rows.map(\.line), ranges: wrapped.rows.map(\.ownedRange),
            baselines: positioned.baselines, size: positioned.size, visibleUTF16: wrapped.text.utf16.count,
            complete: true, appliedTracking: wrapped.appliedTracking,
            discretionaryHyphenOffsets: wrapped.rows.filter(\.discretionaryHyphen).map { NSMaxRange($0.paintedRange)-1 },
            quality: NativeSimpleTextLayout.enabled
                ? Quality(softOrphans: NativeRenderWrapQuality.shortTailOffsets(wrapped.text, ranges: wrapped.rows.map(\.ownedRange)).count,
                    wordCuts: NativeRenderWrapQuality.wordCutOffsets(wrapped.text, ranges: wrapped.rows.map(\.ownedRange)).count,
                    tailWidthCandidates: [])
                : quality(wrapped, width: width, lineFactory: lineFactory),
            verticalFrame: nil,
            horizontalRowBounds: wrapped.rows.map { row in
                // The wrapping pass already measured the glyph-path bounds of this CTLine.
                .init(glyphPath: row.inkBounds, imageAndGlyphPath: CTLineGetImageBounds(row.line, nil).union(row.inkBounds))
            })
    }

    /// Up to three improving tail lookaheads and one joint-tail proposal, plus
    /// bounded measured lexical/row-preserving repairs. Retain the identical
    /// initial plan and each accepted narrower fit. When the initial width
    /// cannot fit, try up to three exact measured-width repairs instead.
    /// Geometry/contour/peer admission remains the caller's responsibility for
    /// every candidate; rejecting refinement must never lose an existing fit.
    static func horizontalCandidates(text: String, font: CTFont, size: CGFloat, width: CGFloat,
                                     maximumWidth: CGFloat, minimumLineHeight: CGFloat,
                                     outwardExtent: CGFloat, color: CGColor, allowRefinement: Bool = true,
                                     preferCompactRefinement: Bool = false,
                                     lineFactory: ((NSAttributedString) -> CTLine)? = nil) throws -> [Plan] {
        if NativeSimpleTextLayout.enabled {
            let plan = try horizontal(text: text, font: font, size: size, width: width,
                minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent, color: color, lineFactory: lineFactory)
            return plan.map { [$0] } ?? []
        }
        func candidates(_ explore:Bool)throws->[Plan] {
            try horizontalCandidatesImpl(text:text,font:font,size:size,width:width,maximumWidth:maximumWidth,
                minimumLineHeight:minimumLineHeight,outwardExtent:outwardExtent,color:color,
                allowRefinement:allowRefinement,preferCompactRefinement:preferCompactRefinement,lineFactory:lineFactory,exploreBudget:explore)
        }
        let baseline=try candidates(false)
        guard allowRefinement,NativeWholeWordWrap.exploresCJKRowBudgets,let first=baseline.first else{return baseline}
        let oldCuts=NativeRenderWrapQuality.wordCutOffsets(text,ranges:first.ranges).count
        guard oldCuts>0 else{return baseline}
        let proposed=try candidates(true)
        guard let best=proposed.first,
              NativeRenderWrapQuality.wordCutOffsets(text,ranges:best.ranges).count<oldCuts else{return baseline}
        return proposed+baseline.filter {old in !proposed.contains {$0.ranges==old.ranges && $0.size==old.size}}
    }

    private static func horizontalCandidatesImpl(text:String,font:CTFont,size:CGFloat,width:CGFloat,
                                     maximumWidth:CGFloat,minimumLineHeight:CGFloat,outwardExtent:CGFloat,
                                     color:CGColor,allowRefinement:Bool,
                                     preferCompactRefinement:Bool,
                                     lineFactory:((NSAttributedString)->CTLine)?,exploreBudget:Bool)throws->[Plan] {
        var wrapped = try NativeWholeWordWrap.layout(text: text, font: font, size: size,
            width: width, color: color, necessaryCJK: true, lineFactory: lineFactory)
        let original = try horizontalPlan(wrapped, width: width, minimumLineHeight: minimumLineHeight,
            outwardExtent: outwardExtent, lineFactory: lineFactory)
        guard let initial = original else {
            guard allowRefinement, maximumWidth.isFinite, maximumWidth > width else { return [] }
            var measuredWidth = width
            for _ in 0..<3 {
                guard wrapped.completeOwnership, wrapped.unresolvedGlyphRanges.isEmpty,
                      wrapped.requiredWidth.isFinite, wrapped.requiredWidth > measuredWidth + 0.01 else { return [] }
                let next = wrapped.requiredWidth + 0.02
                guard next <= maximumWidth else { return [] }
                measuredWidth = next
                wrapped = try NativeWholeWordWrap.layout(text: text, font: font, size: size,
                    width: next, color: color, necessaryCJK: true, lineFactory: lineFactory)
                if var recovered = try horizontalPlan(wrapped, width: next, minimumLineHeight: minimumLineHeight,
                    outwardExtent: outwardExtent, lineFactory: lineFactory) {
                    recovered.refinementOriginWidth = width
                    return [recovered]
                }
            }
            return []
        }
        guard allowRefinement, maximumWidth.isFinite, maximumWidth >= width,
              let initialQuality = initial.quality else { return [initial] }
        var candidates = [initial]
        var attemptedWidths = Set<CGFloat>()
        // Each accepted step removes at least one tiny paragraph tail. Preserve
        // all narrower fits for contour/peer admission, and bound shaping and
        // admission work even for unusually many intentional paragraphs.
        for _ in 0..<min(3, initialQuality.softOrphans) {
            guard let previous = candidates.last, let before = previous.quality,
                  before.softOrphans > 0, let next = before.nextTailWidth,
                  next > previous.size.width + 0.01, next <= maximumWidth,
                  attemptedWidths.insert(next).inserted,
                  var refined = try horizontal(text: text, font: font, size: size, width: next,
                      minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent, color: color,
                      lineFactory: lineFactory),
                  let after = refined.quality, after.softOrphans < before.softOrphans,
                  after.wordCuts <= initialQuality.wordCuts, refined.lines.count <= previous.lines.count,
                  refined.size.height <= previous.size.height + 0.01 else { break }
            refined.refinementOriginWidth = width
            candidates.append(refined)
        }
        // A block can have more than three intentional paragraphs. One joint
        // proposal uses the largest measured tail width that capacity admits,
        // rather than growing the candidate list with the paragraph count.
        // Keep every prior narrower fit available for real geometry admission.
        if let previous = candidates.last, let before = previous.quality, before.softOrphans > 0,
           let joint = before.tailWidthCandidates.last(where: {
               $0 > previous.size.width + 0.01 && $0 <= maximumWidth && !attemptedWidths.contains($0)
           }),
           var refined = try horizontal(text: text, font: font, size: size, width: joint,
               minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent, color: color,
               lineFactory: lineFactory),
           let after = refined.quality, after.softOrphans < before.softOrphans,
           after.wordCuts <= initialQuality.wordCuts, refined.lines.count <= previous.lines.count,
           refined.size.height <= previous.size.height + 0.01 {
            refined.refinementOriginWidth = width
            candidates.append(refined)
        }
        // A legal CJK break can still split a lexical word. Existing tail-only
        // lookaheads never considered those words, even with ample capacity.
        let initialCuts=NativeRenderWrapQuality.wordCutOffsets(text,ranges:initial.ranges).count
        if preferCompactRefinement {
            let old=NativeRenderWrapQuality.evaluate(text,ranges:initial.ranges)
            let tails=NativeRenderWrapQuality.shortTailOffsets(text,ranges:initial.ranges).count
            let singles=NativeRenderWrapQuality.singleCharacterRows(text,ranges:initial.ranges)
            for next in NativeRenderWrapQuality.compactParagraphWidths(wrapped.attributedText,ranges:initial.ranges,
                currentWidth:width,maximumWidth:maximumWidth) where attemptedWidths.insert(next).inserted {
                guard var compact=try horizontal(text:text,font:font,size:size,width:next,
                    minimumLineHeight:minimumLineHeight,outwardExtent:outwardExtent,color:color,lineFactory:lineFactory),
                    compact.lines.count<initial.lines.count else{continue}
                let quality=NativeRenderWrapQuality.evaluate(text,ranges:compact.ranges)
                guard quality.illegal<=old.illegal,quality.orphans<=old.orphans,
                    NativeRenderWrapQuality.wordCutOffsets(text,ranges:compact.ranges).count<=initialCuts,
                    NativeRenderWrapQuality.shortTailOffsets(text,ranges:compact.ranges).count<=tails,
                    NativeRenderWrapQuality.singleCharacterRows(text,ranges:compact.ranges)<=singles else{continue}
                compact.refinementOriginWidth=width;candidates.append(compact)
            }
        }
        if preferCompactRefinement,
           let singleWidth=NativeRenderWrapQuality.compactLineWidth(wrapped.attributedText,ranges:initial.ranges,fontSize:size),
           singleWidth>width+0.01,singleWidth<=maximumWidth,
           var single=try horizontal(text:text,font:font,size:size,width:singleWidth,
                minimumLineHeight:minimumLineHeight,outwardExtent:outwardExtent,color:color,lineFactory:lineFactory),
           single.lines.count==1 {
            single.refinementOriginWidth=width;candidates.append(single)
        }
        if initialCuts>0 {
            let exact=NativeRenderWrapQuality.wordJoinWidths(wrapped.attributedText,ranges:initial.ranges)
                .filter {$0>width+0.01 && $0<=maximumWidth}
            let measured=Array(exact.prefix(3))+(exact.count>3 ? [exact.last!]:[])
            let attached=(preferCompactRefinement ? NativeRenderWrapQuality.wordJoinWidths(wrapped.attributedText,ranges:initial.ranges,includeAttachedPunctuation:true):[])
                .filter {$0>width+0.01 && $0<=maximumWidth}
            let allMeasured=Array(Set(measured+Array(attached.prefix(3))+(attached.count>3 ? [attached.last!]:[]))).sorted()
            let oldDefects=NativeRenderWrapQuality.evaluate(text,ranges:initial.ranges)
            let oldTails=NativeRenderWrapQuality.shortTailOffsets(text,ranges:initial.ranges).count
            let oldSingles=NativeRenderWrapQuality.singleCharacterRows(text,ranges:initial.ranges)
            for next in allMeasured where attemptedWidths.insert(next).inserted {
                guard var refined=try horizontal(text:text,font:font,size:size,width:next,
                    minimumLineHeight:minimumLineHeight,outwardExtent:outwardExtent,color:color,lineFactory:lineFactory),
                    refined.lines.count<=initial.lines.count,refined.size.height<=initial.size.height+0.01 else{continue}
                let defects=NativeRenderWrapQuality.evaluate(text,ranges:refined.ranges)
                guard defects.illegal<=oldDefects.illegal,defects.orphans<=oldDefects.orphans,
                    NativeRenderWrapQuality.shortTailOffsets(text,ranges:refined.ranges).count<=oldTails,
                    NativeRenderWrapQuality.singleCharacterRows(text,ranges:refined.ranges)<=oldSingles,
                    NativeRenderWrapQuality.wordCutOffsets(text,ranges:refined.ranges).count<initialCuts else{continue}
                refined.refinementOriginWidth=width;candidates.append(refined)
            }
            // A wider word can fit without collapsing the old column. Keep
            // hard paragraphs and original row counts as another real plan;
            // equal word quality prefers this stable-height alternative.
            let budgetWidths = exploreBudget
                ? [width]+allMeasured:allMeasured
            for next in budgetWidths {
                guard let budget=try NativeWholeWordWrap.layoutPreservingRows(text:text,font:font,size:size,width:next,
                    originalRanges:initial.ranges,color:color,lineFactory:lineFactory,exploreCJK:exploreBudget),
                    var refined=try horizontalPlan(budget,width:next,minimumLineHeight:minimumLineHeight,
                        outwardExtent:outwardExtent,lineFactory:lineFactory),
                    refined.lines.count==initial.lines.count,refined.size.height<=initial.size.height+0.01 else{continue}
                let defects=NativeRenderWrapQuality.evaluate(text,ranges:refined.ranges)
                guard defects.illegal<=oldDefects.illegal,defects.orphans<=oldDefects.orphans,
                    NativeRenderWrapQuality.shortTailOffsets(text,ranges:refined.ranges).count<=oldTails,
                    NativeRenderWrapQuality.singleCharacterRows(text,ranges:refined.ranges)<=oldSingles,
                    NativeRenderWrapQuality.wordCutOffsets(text,ranges:refined.ranges).count<initialCuts else{continue}
                refined.refinementOriginWidth=width;candidates.append(refined)
            }
        }
        let ordered=Array(candidates.reversed())
        let defects=ordered.map {plan -> Int in
            let quality=NativeRenderWrapQuality.evaluate(text,ranges:plan.ranges)
            return quality.orphans*100+quality.illegal
        }
        let tails=ordered.map {NativeRenderWrapQuality.shortTailOffsets(text,ranges:$0.ranges).count}
        let words=ordered.map {NativeRenderWrapQuality.wordCutOffsets(text,ranges:$0.ranges).count}
        var preferred=NativeRenderWrapQuality.preferredCandidateIndices(defects:defects,tails:tails,wordCuts:words)
        if preferCompactRefinement {
            preferred.sort {a,b in
                ordered[a].lines.count==ordered[b].lines.count ? a<b : ordered[a].lines.count<ordered[b].lines.count
            }
        }
        let chosen=Set(preferred)
        // Retain every prior fit for actual contour/peer admission and the
        // owner-specific fallback, even when a better wrap is preferred first.
        return preferred.map {ordered[$0]}+ordered.indices.filter {!chosen.contains($0)}.map {ordered[$0]}
    }

    private static func quality(_ result: NativeWholeWordWrap.Result, width: CGFloat,
                                lineFactory: ((NSAttributedString) -> CTLine)?) -> Quality {
        var before: [Int: Character] = [:], after: [Int: Character] = [:]
        for (range, character) in zip(result.graphemeRanges, result.text) {
            before[NSMaxRange(range)] = character
            after[range.location] = character
        }
        let wordCuts = result.rows.dropLast().filter { row in
            guard !row.hardBreak, let left = before[NSMaxRange(row.ownedRange)],
                  let right = after[NSMaxRange(row.ownedRange)] else { return false }
            return !NativeLineBreakPolicy.isSpace(left) && !NativeLineBreakPolicy.isSpace(right)
        }.count
        var orphans = 0, widths = Set<CGFloat>()
        for index in result.rows.indices.dropFirst() {
            let previous = result.rows[index-1], row = result.rows[index]
            guard !previous.hardBreak, index == result.rows.count-1 || row.hardBreak,
                  previous.hasInk, row.hasInk, row.occupiedWidth < width * 0.3,
                  previous.occupiedWidth > width * 0.65 else { continue }
            orphans += 1
            let range = NSRange(location: previous.paintedRange.location,
                length: NSMaxRange(row.paintedRange)-previous.paintedRange.location)
            var joined = result.attributedText.attributedSubstring(from: range)
            if result.appliedTracking != 0 {
                // Wider proposals begin with native tracking. Measure that face
                // rather than underestimating width using an earlier fit repair.
                let native = NSMutableAttributedString(attributedString: joined)
                native.removeAttribute(.init(kCTKernAttributeName as String), range: NSRange(location: 0, length: native.length))
                joined = native
            }
            let line = lineFactory?(joined) ?? CTLineCreateWithAttributedString(joined)
            let needed = NativeRenderWrapQuality.joinedLineWidth(line)
            if needed.isFinite && needed > width + 0.01 { widths.insert(needed) }
        }
        return Quality(softOrphans: orphans, wordCuts: wordCuts, tailWidthCandidates: widths.sorted())
    }

    static func vertical(frame: CTFrame, size: CGSize, expectedUTF16: Int) -> Plan {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
        let visible = CTFrameGetVisibleStringRange(frame)
        return Plan(lines: lines, ranges: lines.map { let r = CTLineGetStringRange($0)
            return NSRange(location: r.location, length: r.length) },
            baselines: origins.map { CGPoint(x: $0.x, y: size.height - $0.y) }, size: size,
            visibleUTF16: visible.length, complete: visible.location == 0 && visible.length == expectedUTF16,
            appliedTracking: 0, discretionaryHyphenOffsets: [], quality: nil, verticalFrame: frame)
    }
}
