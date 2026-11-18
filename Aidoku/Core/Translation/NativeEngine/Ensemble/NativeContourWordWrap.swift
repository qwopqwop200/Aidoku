import CoreGraphics
import CoreText
import Foundation

/// A numerical, centre-only contour proposal. This is NOT an alpha, source-rim,
/// peer or physical-containment certificate; the caller must admit the raster.
enum NativeContourWordWrap {
    struct Proposal {
        let wrapped: NativeWholeWordWrap.Result
        let diagnostics: [String: Any]
    }

    private enum Limit: Error { case exhausted }
    private struct Cell {
        let cuts: Int
        let raggedness: Double
        let previous: Int
    }

    static func layout(text: String, font: CTFont, size: CGFloat, width: CGFloat,
                       pitch: CGFloat, outwardExtent: CGFloat,
                       policy: NativeTextExpansionPolicy, page: CGRect, anchor: CGRect,
                       originalRanges: [NSRange], color: CGColor,
                       lineFactory: ((NSAttributedString) -> CTLine)? = nil) throws -> Proposal? {
        func trace(_ reason:String,_ values:[String:Double]=[:]) {
            guard ProcessInfo.processInfo.environment["AIDOKU_TRACE_CONTOUR_WORDS"] == "1" else{return}
            var row:[String:Any]=["reason":reason]
            let fields=values.merging(["font":Double(size),"width":Double(width),"pitch":Double(pitch),
                "oldRows":Double(originalRanges.count),"anchorX":Double(anchor.midX),"anchorY":Double(anchor.midY)]){a,_ in a}
            for (key,value) in fields where value.isFinite {row[key]=value}
            guard let data=try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys) else{return}
            FileHandle.standardError.write(Data("CONTOUR_TRACE ".utf8)+data+Data([10]))
        }
        try Task.checkCancellation()
        guard !text.isEmpty, text.utf16.count <= 768, text.count <= 96,
              !text.contains(where: NativeLineBreakPolicy.isBreak), !text.contains("\u{00AD}"),
              [size, width, pitch, outwardExtent].allSatisfy(\.isFinite),
              size > 0, size <= 512, width > 0, width <= 32768,
              pitch > 0, pitch <= 4096, outwardExtent >= 0, outwardExtent <= 512,
              [page.minX, page.minY, page.width, page.height,
               anchor.minX, anchor.minY, anchor.width, anchor.height].allSatisfy(\.isFinite),
              page.origin == .zero, page.width > 0, page.height > 0,
              page.width <= 32768, page.height <= 32768, !anchor.isEmpty, page.contains(anchor),
              policy.valid, policy.insideBalloon,
              let maskRaw = policy.maskRectNormalized, let spans = policy.maskSpansNormalized,
              !originalRanges.isEmpty, originalRanges.count <= 24 else { trace("input");return nil }

        let ns = text as NSString
        let characters = Array(text)
        var boundaries = [0]
        for c in characters { boundaries.append(boundaries.last! + String(c).utf16.count) }
        let boundarySet = Set(boundaries)
        var cursor = 0
        for range in originalRanges {
            guard range.location == cursor, range.length > 0, range.length <= ns.length - cursor,
                  boundarySet.contains(cursor + range.length) else { trace("ownership");return nil }
            cursor += range.length
        }
        guard cursor == ns.length else { trace("ownership-end");return nil }
        let oldCuts = NativeRenderWrapQuality.wordCutOffsets(text, ranges: originalRanges).count
        guard oldCuts > 0 else { trace("no-word-cuts");return nil }

        var shapingCalls = 0, totalShapedUTF16 = 0
        var shapingExhausted = false
        let emptyLine = CTLineCreateWithAttributedString(NSAttributedString(string: ""))
        let makeLine: (NSAttributedString) -> CTLine = { fragment in
            guard shapingCalls < 4096, totalShapedUTF16 + fragment.length <= 131072 else {
                shapingExhausted = true
                return emptyLine
            }
            shapingCalls += 1; totalShapedUTF16 += fragment.length
            return lineFactory?(fragment) ?? CTLineCreateWithAttributedString(fragment)
        }
        // Reuse production fallback selection, colour and grapheme ownership.
        // No independent typesetter/font substitution/tracking policy lives here.
        let seed = try NativeWholeWordWrap.layoutInternal(text: text, font: font, size: size,
            width: width, captionBoundaryRules:false, color: color, necessaryCJK: true,
            lineFactory: makeLine, preferWholeWords: true)
        try Task.checkCancellation()
        guard !shapingExhausted, seed.completeOwnership, seed.unresolvedGlyphRanges.isEmpty else { trace("seed");return nil }
        let face = CTFontCreateCopyWithAttributes(font, size, nil, nil)
        let upper = max(CTFontGetAscent(face), seed.rows.map(\.upperExtent).max() ?? 0)
        let lower = max(CTFontGetDescent(face), seed.rows.map(\.lowerExtent).max() ?? 0)
        let leading = max(CTFontGetLeading(face), seed.rows.map(\.leading).max() ?? 0)
        // Retained replay/native terminal geometry is authoritative. The
        // natural baselineStep adds fresh breathing room and quantization;
        // applying it again silently imposes a different pitch contract.
        let requiredPitch = upper + lower + 2 * outwardExtent + 1
        guard [upper, lower, leading].allSatisfy(\.isFinite), upper + lower > 0,
              requiredPitch <= pitch + 0.01
        else { trace("pitch", ["upper": Double(upper), "lower": Double(lower),
            "leading": Double(leading), "requiredPitch": Double(requiredPitch)]); return nil }

        let legal = NativeLineBreakPolicy.legalOffsets(text: text)
        let mask = NativeTextExpansionPolicy.rect(maskRaw, page: page)
        let allowed = NativeTextExpansionPolicy.rect(policy.allowedRectNormalized, page: page).intersection(page)
        let bandHeight = mask.height / CGFloat(spans.count / 2)
        let reserve = outwardExtent + 2
        var shapes = [Int: NativeWholeWordWrap.Row]()
        var rejectedShapes = Set<Int>()
        var actualInks = [Int: CGRect]()
        var shapedUTF16 = 0, transitions = 0, intervalWork = 0
        var countsTried = [Int](), feasibleCounts = [Int](),capacityCounts=0, replanPasses=0, exactRejects=0

        func row(_ start: Int, _ end: Int) throws -> NativeWholeWordWrap.Row? {
            let key = start * (ns.length + 1) + end
            if let hit = shapes[key] { return hit }
            if rejectedShapes.contains(key) { return nil }
            try Task.checkCancellation()
            guard shapes.count + rejectedShapes.count < 4096,
                  shapedUTF16 + end - start <= 131072 else { throw Limit.exhausted }
            shapedUTF16 += end - start
            let range = NSRange(location: start, length: end - start)
            var a = boundaries.firstIndex(of: start)!, b = boundaries.firstIndex(of: end)!
            while a < b, NativeLineBreakPolicy.isSpace(characters[a]) { a += 1 }
            while b > a, NativeLineBreakPolicy.isSpace(characters[b - 1]) { b -= 1 }
            guard a < b else { rejectedShapes.insert(key); return nil }
            let paint = NSRange(location: boundaries[a], length: boundaries[b] - boundaries[a])
            let fragment = NativeWholeWordWrap.paintedFragment(seed.attributedText, range: paint, discretionaryHyphen: false)
            let line = makeLine(fragment)
            guard !shapingExhausted else { throw Limit.exhausted }
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            guard advance.isFinite, !ink.isNull, !ink.isInfinite,
                  ink.maxY <= upper + 0.01, -ink.minY <= lower + 0.01 else {
                rejectedShapes.insert(key); return nil
            }
            // Contextual shaping must not introduce an unresolved glyph that
            // was absent from the seed. Inspect the actual candidate CTLines.
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let actual = attributes[kCTFontAttributeName] else { rejectedShapes.insert(key); return nil }
                let actualFont = actual as! CTFont
                if (CTFontCopyPostScriptName(actualFont) as String).lowercased().contains("lastresort") {
                    rejectedShapes.insert(key); return nil
                }
                var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                if glyphs.contains(0) { rejectedShapes.insert(key); return nil }
            }
            let value = NativeWholeWordWrap.Row(ownedRange: range, paintedRange: paint, line: line,
                advance: advance, ascent: upper, descent: lower, leading: leading, inkBounds: ink,
                hardBreak: false, overflow: 0, discretionaryHyphen: false)
            let imageInk = CTLineGetImageBounds(line, nil).union(ink)
            guard !imageInk.isNull, !imageInk.isEmpty, !imageInk.isInfinite else {
                rejectedShapes.insert(key); return nil
            }
            actualInks[key] = imageInk
            shapes[key] = value
            return value
        }

        // Each touched mask band must contain the centre in ONE interval.
        // Taking minima of those containing intervals is their intersection,
        // never the bounding box/union of disconnected lobes.
        // A profile describes ink relative to each unchanged baseline.
        // Its whole-block union is centred on the original actual paint centre,
        // rather than centring transparent typographic ascent/descent slabs.
        func capacities(_ profile: [(CGFloat, CGFloat)]) throws -> [CGFloat]? {
            let count = profile.count
            let top = profile.indices.map { upper + CGFloat($0) * pitch - profile[$0].0 }.min()!
            let bottom = profile.indices.map { upper + CGFloat($0) * pitch + profile[$0].1 }.max()!
            let shift = anchor.midY - (top + bottom) / 2
            var result = [CGFloat]()
            for i in profile.indices {
                try Task.checkCancellation()
                let baseline = upper + CGFloat(i) * pitch + shift
                let y0 = baseline - profile[i].0 - reserve
                let y1 = baseline + profile[i].1 + reserve
                guard y0 >= mask.minY, y1 <= mask.maxY, y0 >= allowed.minY, y1 <= allowed.maxY else {
                    trace("capacity-y", ["rows": Double(count), "row": Double(i),
                        "top": Double(y0), "bottom": Double(y1)]); return nil
                }
                var half = min(anchor.midX - allowed.minX, allowed.maxX - anchor.midX)
                let first = max(0, Int(floor((y0 - mask.minY) / bandHeight)))
                let last = min(spans.count / 2 - 1, Int(ceil((y1 - mask.minY) / bandHeight)) - 1)
                guard first <= last else { return nil }
                for band in first...last {
                    let intervals = policy.maskIntervals(row: band)
                    intervalWork += intervals.count / 2
                    guard intervalWork <= 262144 else { throw Limit.exhausted }
                    var containing: CGFloat?
                    for k in stride(from: 0, to: intervals.count, by: 2) {
                        let left = CGFloat(intervals[k]) * page.width
                        let right = CGFloat(intervals[k + 1]) * page.width
                        if left <= anchor.midX, anchor.midX <= right {
                            containing = min(anchor.midX - left, right - anchor.midX)
                            break
                        }
                    }
                    guard let containing else {
                        trace("capacity-center-hole", ["rows": Double(count), "row": Double(i)]); return nil
                    }
                    half = min(half, containing)
                }
                let capacity = min(width, 2 * (half - reserve))
                guard capacity > 0 else {
                    trace("capacity-width", ["rows": Double(count), "row": Double(i)]); return nil
                }
                trace("capacity", ["rows": Double(count), "row": Double(i), "top": Double(y0),
                    "bottom": Double(y1), "capacity": Double(capacity), "inkShiftY": Double(shift)])
                result.append(capacity)
            }
            return result
        }

        func profile(_ rows: [NativeWholeWordWrap.Row]) -> [(CGFloat, CGFloat)] {
            rows.map { row in
                let ink = actualInks[row.ownedRange.location * (ns.length + 1) + NSMaxRange(row.ownedRange)]!
                return (ink.maxY, -ink.minY)
            }
        }

        func exactPartitionFits(_ rows: [NativeWholeWordWrap.Row], _ caps: [CGFloat]) throws -> Bool {
            // Independent complete-partition check, including horizontal image
            // overhangs and whole actual ink centring. Never certify a seed.
            let local = rows.enumerated().map { i, row -> CGRect in
                let ink = actualInks[row.ownedRange.location * (ns.length + 1) + NSMaxRange(row.ownedRange)]!
                return CGRect(x: row.centeredBaselineX(width: width) + ink.minX,
                    y: upper + CGFloat(i) * pitch - ink.maxY, width: ink.width, height: ink.height)
            }
            let block = local.reduce(CGRect.null) { $0.union($1) }
            let dx = anchor.midX - block.midX, dy = anchor.midY - block.midY
            for i in rows.indices {
                try Task.checkCancellation()
                guard rows[i].occupiedWidth <= caps[i] + 0.001 else { return false }
                let styled = local[i].offsetBy(dx: dx, dy: dy).insetBy(dx: -reserve, dy: -reserve)
                // Charge the exact policy scan against the SAME global budget.
                guard mask.contains(styled) else { return false }
                let first = max(0, Int(floor((styled.minY - mask.minY) / bandHeight)))
                let last = min(spans.count / 2 - 1, Int(ceil((styled.maxY - mask.minY) / bandHeight)) - 1)
                guard first <= last else { return false }
                for band in first...last {
                    intervalWork += policy.maskIntervals(row: band).count / 2
                    guard intervalWork <= 262144 else { throw Limit.exhausted }
                }
                guard policy.allows(styled, page: page) else { return false }
            }
            return true
        }

        let oldRows = originalRanges.count
        let maximum = min(24, oldRows + min(4, oldCuts))
        var counts = [oldRows]
        for delta in 1...max(2, min(4, oldCuts)) {
            if oldRows - delta >= max(1, oldRows - 2) { counts.append(oldRows - delta) }
            if oldRows + delta <= maximum { counts.append(oldRows + delta) }
        }
        // Profile iteration is deliberately approximate, not a partition
        // frontier or exact optimum claim. Every returned partition is checked
        // again using its OWN actual ink bands; failed profiles grant no paint.
        let seedInks = seed.rows.map { CTLineGetImageBounds($0.line, nil).union($0.inkBounds) }
            .filter { !$0.isNull && !$0.isEmpty && !$0.isInfinite }
        guard let seedTop = seedInks.map(\.maxY).max(),
              let seedBottom = seedInks.map({ -$0.minY }).max() else { trace("seed-ink"); return nil }
        var best: (rows: [NativeWholeWordWrap.Row], cuts: Int, score: Double, capacities: [CGFloat])?
        do {
            for count in counts where count <= characters.count {
                try Task.checkCancellation()
                countsTried.append(count)
                var inkProfile = [(CGFloat, CGFloat)](repeating: (seedTop, seedBottom), count: count)
                var lastRanges = [NSRange]()
                for pass in 0..<3 {
                    replanPasses += 1
                    guard let caps = try capacities(inkProfile) else { break }
                    capacityCounts += 1
                    let necessary = NativeNecessaryCJKBreaks.propose(text: text, attributed: seed.attributedText,
                        physicalWidth: caps.min()!, lineFactory: makeLine, legalOffsets: legal,
                        bindForbiddenWhitespace: true).offsets
                    try Task.checkCancellation()
                    guard !shapingExhausted else { throw Limit.exhausted }
                    let oldEnds = Set(originalRanges.map(NSMaxRange))
                    let ends = boundaries.dropFirst().filter { end in
                        if end == ns.length { return true }
                        guard legal.contains(end), let index = boundaries.firstIndex(of: end) else { return false }
                        let a = characters[index - 1], b = characters[index]
                        let internalWord = (a.isLetter || a.isNumber) && (b.isLetter || b.isNumber)
                        return !internalWord || necessary.contains(end) || oldEnds.contains(end)
                    }
                    let points = [0] + ends
                    guard count < points.count else { break }
                    let n = points.count
                    var layers = [[Cell?]](repeating: [Cell?](repeating: nil, count: n), count: count + 1)
                    layers[0][0] = Cell(cuts: 0, raggedness: 0, previous: -1)
                    for r in 0..<count {
                        try Task.checkCancellation()
                        for j in 1..<n {
                            let end = points[j]
                            if r == count - 1 && end != ns.length { continue }
                            if r < count - 1 && end == ns.length { continue }
                            for i in 0..<j {
                                guard let prior = layers[r][i] else { continue }
                                transitions += 1
                                guard transitions <= 262144 else { throw Limit.exhausted }
                                guard let shaped = try row(points[i], end), shaped.occupiedWidth <= caps[r] + 0.001 else { continue }
                                let index = boundaries.firstIndex(of: end)!
                                let cut: Int
                                if end < ns.length {
                                    let left = characters[index - 1], right = characters[index]
                                    cut = (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber) ? 1 : 0
                                } else { cut = 0 }
                                let cuts = prior.cuts + cut
                                guard cuts < oldCuts else { continue }
                                let slack = Double((caps[r] - shaped.occupiedWidth) / caps[r])
                                let score = prior.raggedness + slack * slack
                                if let incumbent = layers[r + 1][j],
                                   incumbent.cuts < cuts || (incumbent.cuts == cuts && incumbent.raggedness <= score) { continue }
                                layers[r + 1][j] = Cell(cuts: cuts, raggedness: score, previous: i)
                            }
                        }
                    }
                    guard let finish = layers[count][n - 1] else {
                        trace("dp-no-fit", ["rows": Double(count), "pass": Double(pass)]); break
                    }
                    var rows = [NativeWholeWordWrap.Row](), index = n - 1
                    for r in (1...count).reversed() {
                        let previous = layers[r][index]!.previous
                        guard let value = try row(points[previous], points[index]) else { throw Limit.exhausted }
                        rows.append(value); index = previous
                    }
                    rows.reverse()
                    let actualProfile = profile(rows)
                    if let exactCaps = try capacities(actualProfile), try exactPartitionFits(rows, exactCaps) {
                        feasibleCounts.append(count)
                        if best == nil || finish.cuts < best!.cuts ||
                            (finish.cuts == best!.cuts && finish.raggedness < best!.score) {
                            best = (rows, finish.cuts, finish.raggedness, exactCaps)
                        }
                        break
                    }
                    exactRejects += 1
                    trace("exact-partition-rejected", ["rows": Double(count), "pass": Double(pass)])
                    let ranges = rows.map(\.ownedRange)
                    if ranges == lastRanges { break }
                    lastRanges = ranges
                    inkProfile = actualProfile
                }
            }
        } catch Limit.exhausted { trace("budget",["transitions":Double(transitions),"shapedEdges":Double(shapes.count)]);return nil }
        try Task.checkCancellation()
        guard let best else { trace("no-improving-path",["countsTried":Double(countsTried.count),
            "countsWithCapacity":Double(capacityCounts),"shapedEdges":Double(shapes.count)]);return nil }
        trace("proposal",["rows":Double(best.rows.count),"cutsBefore":Double(oldCuts),"cutsAfter":Double(best.cuts)])
        let result = NativeWholeWordWrap.Result(text: text, attributedText: seed.attributedText,
            rows: best.rows, graphemeRanges: seed.graphemeRanges, unresolvedGlyphRanges: [],
            fallbackRanges: seed.fallbackRanges, completeOwnership: true,
            requiredWidth: best.rows.map(\.occupiedWidth).max() ?? 0,
            bodyHeight: upper + lower + CGFloat(best.rows.count - 1) * pitch,
            requestedFontName: seed.requestedFontName, requestedFontSize: size, appliedTracking: 0)
        return Proposal(wrapped: result, diagnostics: [
            "policy": "ink-centred-row-contour-v2", "physicalContainmentCertified": false,
            "endpointPolicy": "shared-legal-ordinary-production-necessary-cjk-and-inherited-grapheme-cuts",
            "maximumGraphemes": 96, "maximumRows": 24,
            "maximumReplansPerRowCount": 3, "profilePasses": replanPasses, "exactPartitionRejects": exactRejects,
            "exactPartitionInkBandsValidated": true, "retainedPitchRequiredPixels": Double(requiredPitch),
            "cutsBefore": oldCuts, "cutsAfter": best.cuts,
            "rowCountsTried": countsTried, "feasibleRowCounts": feasibleCounts,
            "rowCapacitiesPixels": best.capacities.map(Double.init),
            "commonUpperPixels": Double(upper), "commonLowerPixels": Double(lower),
            "pitchPixels": Double(pitch), "sideReservationPixels": Double(reserve),
            "shapedEdges": shapes.count + rejectedShapes.count, "shapedUTF16": shapedUTF16,
            "shapingCallsIncludingProductionSeed": shapingCalls, "totalShapedUTF16": totalShapedUTF16,
            "transitions": transitions, "maskIntervalWork": intervalWork,
            "shapeEdgeBudget": 4096, "transitionBudget": 262144, "budgetExhausted": false
        ])
    }
}
