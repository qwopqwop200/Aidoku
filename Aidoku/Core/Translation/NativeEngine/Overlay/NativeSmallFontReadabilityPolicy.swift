import Foundation
import CoreGraphics

/// Runtime-only, post-prepare fixed-frame search. No corpus identifiers or label access.
/// A returned proposal must pass the caller's final clipped-pixel check before commit.
enum NativeSmallFontReadabilityPolicy {
    struct Input {
        let text: String
        let frame: CGRect
        /// Left, top, right, bottom in the same native points as frame.
        let padding: [CGFloat]
        let style: NativeTranslationTypography.Style
        let paintPolygons: [[CGPoint]]
        /// Latest other sentence frames and source owners, not previous layout seeds.
        let foreignRects: [CGRect]
        let ordinaryKoreanCaption: Bool
    }

    struct Proposal {
        let style: NativeTranslationTypography.Style
        let padding: [CGFloat]
        let layout: NativeTranslationTypography.Layout
        let origin: CGPoint
        let rows: [String]
        let cuts: Int
        let singletons: Int
        let rowGap: CGFloat?
        let glyphRect: CGRect
        let rangeRect: CGRect
        let baselineCuts: Int
        let baselineSingletons: Int
        let trials: Int
    }

    /// Keep ranking metadata, not all candidate CoreText frames/glyph runs, alive.
    private struct Candidate {
        let ordinal: Int
        let style: NativeTranslationTypography.Style
        let padding: [CGFloat]
        let cuts: Int
        let singletons: Int
    }

    /// A false admission means no remaining candidate can be evaluated; the caller
    /// must supply a monotonic prerequisite, not a candidate-specific preference.
    static func search(_ input: Input, pixelGuard: ((Proposal) -> Bool)? = nil,
                       canEvaluate: (() -> Bool)? = nil, requestedFontSize: CGFloat? = nil,
                       spendShapeWork: (() -> Bool)? = nil,
                       denseRequestedFonts: Bool = false) -> Proposal? {
        guard canEvaluate?() ?? true else { return nil }
        let s = input.style, f = input.frame
        guard input.ordinaryKoreanCaption, !s.vertical, !s.preservesBlockRows,
              !s.keepsWholeWords, !s.strictLineBreak, s.outlineGlow == 0,
              s.horizontalWhitespace == .preWrap, s.fontSize > 0,
              s.fontSize.isFinite, s.lineHeight.isFinite, s.tracking.isFinite,
              f.width > 0, f.height > 0, !f.isInfinite, !f.isNull,
              input.padding.count == 4, input.padding.allSatisfy({ $0.isFinite && $0 >= 0 }),
              !input.paintPolygons.isEmpty, !input.text.isEmpty else { return nil }
        if let requestedFontSize {
            guard requestedFontSize.isFinite, requestedFontSize <= 2_048,
                  requestedFontSize > s.fontSize else { return nil }
        } else if s.fontSize >= 7.75 { return nil }
        guard spendShapeWork?() ?? true else { return nil }
        let baseline = measure(input.text, frame: f, padding: input.padding, style: s)
        guard baseline.layout.fits, baseline.layout.visibleUTF16Range.length == input.text.utf16.count,
              integrity(baseline.rows, input.text) else { return nil }
        let before = wordMetrics(baseline.rows)
        let ratio = s.lineHeight / s.fontSize
        let fonts: [CGFloat]
        if let requestedFontSize {
            // Bounded non-monotone probes, not binary-search assumptions about
            // wrapping, word integrity, row gaps or peer collision eligibility.
            fonts = Set([CGFloat(0.25), 0.5, 0.75, 1].map {
                floor((s.fontSize + (requestedFontSize - s.fontSize) * $0) * 4) / 4
            }).filter { $0 > s.fontSize && $0 <= requestedFontSize }.sorted(by: >)
        } else {
            fonts = Set([CGFloat(0.25), 0.5, 1, 1.5].map {
                (min(7.75, s.fontSize + $0) * 4).rounded() / 4
            }).filter { $0 > s.fontSize }.sorted(by: >)
        }
        var pads: [[CGFloat]] = []
        for factor: CGFloat in [1, 0.65, 0.35] {
            let pad = input.padding.map { max(0.7, $0 * factor) }
            if !pads.contains(pad) { pads.append(pad) }
        }
        let pitches = Set([ratio, max(1.1, ratio - 0.06), max(1.1, ratio - 0.12)]).sorted(by: >)
        // Never add more negative tracking than the production caption baseline.
        let trackingRatios = Set([s.tracking / s.fontSize, -0.008, 0]).sorted(by: >)
        var count = 0
        let searchedFonts: AnySequence<CGFloat>
        if denseRequestedFonts, let requestedFontSize {
            searchedFonts = AnySequence(stride(from: floor(requestedFontSize * 4) / 4,
                through: floor(s.fontSize * 4) / 4 + 0.25, by: CGFloat(-0.25)))
        } else {
            searchedFonts = AnySequence(fonts)
        }
        for font in searchedFonts {
            guard canEvaluate?() ?? true else { return nil }
            var ranked: [Candidate] = []
            var deferred: [Candidate] = []
            var zeroWinner: Candidate?
            let boundedFrontier = pads.count * pitches.count * trackingRatios.count * 2 <= 54
            for pad in pads {
                for pitch in pitches {
                    for tracking in trackingRatios {
                        for wrap in [NativeTranslationTypography.HorizontalWrapping.keepAll, .keepAllWithEmergency] {
                            var style = s
                            style.fontSize = font
                            style.lineHeight = font * pitch
                            style.tracking = font * tracking
                            style.horizontalWrapping = wrap
                            count += 1
                            guard spendShapeWork?() ?? true else { return nil }
                            // Retain the original logical budget/order; only skip native
                            // shaping after an admissible zero-error lower bound is beaten.
                            if boundedFrontier, let winner = zeroWinner,
                               style.lineHeight.isFinite, style.tracking.isFinite, pad.reduce(0, +).isFinite {
                                let optimistic = Candidate(ordinal: count, style: style, padding: pad,
                                    cuts: 0, singletons: 0)
                                if measurementRankBefore(winner, optimistic) {
                                    deferred.append(optimistic)
                                    continue
                                }
                            }
                            guard let proposal = validatedProposal(input, style: style, padding: pad,
                                baselineWords: before, trials: count) else { continue }
                            let measured = Candidate(ordinal: count, style: style, padding: pad,
                                cuts: proposal.cuts, singletons: proposal.singletons)
                            ranked.append(measured)
                            if boundedFrontier, measured.cuts == 0, measured.singletons == 0,
                               zeroWinner == nil || measurementRankBefore(measured, zeroWinner!) {
                                zeroWinner = measured
                            }
                        }
                    }
                }
            }
            // If raster rejects the apparent winner, resume the deferred frontier.
            // No-pruning cases keep the existing eager path and its final proof.
            if !deferred.isEmpty {
                switch resolveMeasurementFrontier(input, measured: ranked, deferred: deferred,
                    before: before, trials: count, pixelGuard: pixelGuard,
                    canEvaluate: canEvaluate, spendShapeWork: spendShapeWork) {
                case .accepted(let proposal): return proposal
                case .aborted: return nil
                case .exhausted: continue
                }
            }
            // Rank before spending the caller's bounded raster budget. Equal preferences
            // retain the earliest enumeration, just as the previous eager selection did.
            ranked.sort {
                if preferred($0, over: $1) { return true }
                if preferred($1, over: $0) { return false }
                return $0.ordinal < $1.ordinal
            }
            // Largest admissible font first. Smaller-font trials cannot win.
            for entry in ranked {
                guard canEvaluate?() ?? true else { return nil }
                guard spendShapeWork?() ?? true else { return nil }
                guard let best = validatedProposal(input, style: entry.style, padding: entry.padding,
                    baselineWords: before, trials: count),
                    best.cuts == entry.cuts, best.singletons == entry.singletons else { continue }
                guard pixelGuard?(best) ?? true else { continue }
                return Proposal(style: best.style, padding: best.padding, layout: best.layout, origin: best.origin,
                    rows: best.rows, cuts: best.cuts, singletons: best.singletons, rowGap: best.rowGap,
                    glyphRect: best.glyphRect, rangeRect: best.rangeRect, baselineCuts: before.0,
                    baselineSingletons: before.1, trials: count)
            }
        }
        return nil
    }

    private static func preferred(_ a: Candidate, over b: Candidate) -> Bool {
        let x: [CGFloat] = [-CGFloat(a.cuts), -CGFloat(a.singletons), a.style.lineHeight,
            a.padding.reduce(0, +), a.style.tracking, a.style.horizontalWrapping == .keepAll ? 1 : 0]
        let y: [CGFloat] = [-CGFloat(b.cuts), -CGFloat(b.singletons), b.style.lineHeight,
            b.padding.reduce(0, +), b.style.tracking, b.style.horizontalWrapping == .keepAll ? 1 : 0]
        for (left, right) in zip(x, y) where left != right { return left > right }
        return false
    }

    /// Rebuilt lazily with the same full geometry/integrity guards before rasterization.
    private static func validatedProposal(_ input: Input, style: NativeTranslationTypography.Style,
                                          padding pad: [CGFloat], baselineWords before: (Int, Int), trials: Int) -> Proposal? {
        let f = input.frame
        let measured = measure(input.text, frame: f, padding: pad, style: style)
        let layout = measured.layout
        guard layout.fits, layout.visibleUTF16Range.location == 0,
              layout.visibleUTF16Range.length == input.text.utf16.count,
              integrity(measured.rows, input.text) else { return nil }
        let words = wordMetrics(measured.rows)
        guard words.0 <= before.0, words.1 <= before.1 else { return nil }
        let gap = rowGap(layout, outline: input.style.outlineWidth)
        guard gap.proven, gap.value == nil || gap.value! >= 0.25 else { return nil }
        let origin = CGPoint(x: f.minX + pad[0], y: f.minY + pad[1])
        let glyph = layout.glyphBounds.reduce(CGRect.null) { $0.union($1) }
            .offsetBy(dx: origin.x, dy: origin.y)
        let range = layout.rangeBounds.reduce(CGRect.null) { $0.union($1) }
            .offsetBy(dx: origin.x, dy: origin.y)
        guard !glyph.isNull, f.contains(glyph), f.contains(range),
              covered(glyph, polygons: input.paintPolygons),
              covered(range, polygons: input.paintPolygons),
              !input.foreignRects.contains(where: {
                  let hit = glyph.intersection($0)
                  return !hit.isNull && hit.width > 0 && hit.height > 0
              }) else { return nil }
        return Proposal(style: style, padding: pad, layout: layout, origin: origin,
            rows: measured.rows, cuts: words.0, singletons: words.1, rowGap: gap.value,
            glyphRect: glyph, rangeRect: range, baselineCuts: before.0,
            baselineSingletons: before.1, trials: trials)
    }

    private static func measure(_ text: String, frame: CGRect, padding p: [CGFloat],
                                style: NativeTranslationTypography.Style) -> (layout: NativeTranslationTypography.Layout, rows: [String]) {
        let size = CGSize(width: frame.width - p[0] - p[2], height: frame.height - p[1] - p[3])
        let layout = NativeTranslationTypography.layout(text: text, in: size, style: style)
        let shaped = layout.shapedText as NSString
        let rows = layout.lineRanges.compactMap { r -> String? in
            guard r.location >= 0, r.length >= 0, NSMaxRange(r) <= shaped.length else { return nil }
            return shaped.substring(with: r)
        }
        return (layout, rows)
    }

    private static func integrity(_ rows: [String], _ text: String) -> Bool {
        func plain(_ value: String) -> [Unicode.Scalar] {
            value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        return plain(rows.joined()) == plain(text)
    }

    private static func wordMetrics(_ rows: [String]) -> (Int, Int) {
        func hangul(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return scalar.value >= 0xAC00 && scalar.value <= 0xD7A3
        }
        let words = rows.map { $0.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
        let cuts = zip(words, words.dropFirst()).filter {
            hangul($0.0.unicodeScalars.last) && hangul($0.1.unicodeScalars.first)
        }.count
        let singletons = words.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
            return trimmed.count == 1 && hangul(trimmed.first)
        }.count
        return (cuts, singletons)
    }

    private static func rowGap(_ layout: NativeTranslationTypography.Layout, outline: CGFloat)
        -> (value: CGFloat?, proven: Bool) {
        let metrics = NativeTranslationTypography.captionLineMetrics(layout: layout)
        let runs = NativeTranslationTypography.diagnosticRuns(layout: layout)
        var ink: [CGRect] = []
        for (i, row) in metrics.enumerated() {
            guard i < runs.count, let primary = runs[i]["primaryFont"] as? [String: Any],
                  let ascent = primary["rangeAscent"] as? Double else { continue }
            let baseline = row.rect.minY + CGFloat(ascent)
            ink.append(CGRect(x: row.rect.minX - outline / 2, y: baseline - row.ascent - outline / 2,
                width: row.rect.width + outline, height: row.ascent + row.descent + outline))
        }
        return (zip(ink, ink.dropFirst()).map { $1.minY - $0.maxY }.min(), ink.count == layout.lineCount)
    }

    private enum MeasurementFrontierResult {
        case exhausted, aborted, accepted(Proposal)
    }

    /// Same lexicographic preference and original ordinal tie, without temporary arrays.
    private static func measurementRankBefore(_ a: Candidate, _ b: Candidate) -> Bool {
        // Match preferred() even beyond CGFloat's exact-integer range; replacing
        // this with Int ordering would alter its original tie/ordinal semantics.
        let ac = -CGFloat(a.cuts), bc = -CGFloat(b.cuts)
        if ac != bc { return ac > bc }
        let asingle = -CGFloat(a.singletons), bsingle = -CGFloat(b.singletons)
        if asingle != bsingle { return asingle > bsingle }
        if a.style.lineHeight != b.style.lineHeight { return a.style.lineHeight > b.style.lineHeight }
        let ap = a.padding.reduce(0, +), bp = b.padding.reduce(0, +)
        if ap != bp { return ap > bp }
        if a.style.tracking != b.style.tracking { return a.style.tracking > b.style.tracking }
        let aw = a.style.horizontalWrapping == .keepAll, bw = b.style.horizontalWrapping == .keepAll
        if aw != bw { return aw }
        return a.ordinal < b.ordinal
    }

    /// Deferred entries have admissible zero lower bounds for cuts/singletons.
    /// Retain metadata only; freshly shape and certify every selected proposal.
    private static func resolveMeasurementFrontier(_ input: Input, measured: [Candidate], deferred: [Candidate],
                                                   before: (Int, Int), trials: Int,
                                                   pixelGuard: ((Proposal) -> Bool)?, canEvaluate: (() -> Bool)?,
                                                   spendShapeWork: (() -> Bool)?) -> MeasurementFrontierResult {
        let pending = deferred.sorted(by: measurementRankBefore)
        var cursor = 0, ranked = measured.sorted(by: measurementRankBefore)
        while cursor < pending.count || !ranked.isEmpty {
            if cursor < pending.count, ranked.isEmpty || measurementRankBefore(pending[cursor], ranked[0]) {
                let entry = pending[cursor]
                cursor += 1
                // Logical shape credit was already charged in original enumeration order.
                guard let proposal = validatedProposal(input, style: entry.style, padding: entry.padding,
                    baselineWords: before, trials: trials) else { continue }
                let candidate = Candidate(ordinal: entry.ordinal, style: entry.style, padding: entry.padding,
                    cuts: proposal.cuts, singletons: proposal.singletons)
                var lo = 0, hi = ranked.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if measurementRankBefore(candidate, ranked[mid]) { hi = mid } else { lo = mid + 1 }
                }
                ranked.insert(candidate, at: lo)
                continue
            }
            let entry = ranked.removeFirst()
            guard canEvaluate?() ?? true else { return .aborted }
            guard spendShapeWork?() ?? true else { return .aborted }
            guard let best = validatedProposal(input, style: entry.style, padding: entry.padding,
                baselineWords: before, trials: trials), best.cuts == entry.cuts,
                best.singletons == entry.singletons else { continue }
            guard pixelGuard?(best) ?? true else { continue }
            return .accepted(Proposal(style: best.style, padding: best.padding, layout: best.layout,
                origin: best.origin, rows: best.rows, cuts: best.cuts, singletons: best.singletons,
                rowGap: best.rowGap, glyphRect: best.glyphRect, rangeRect: best.rangeRect,
                baselineCuts: before.0, baselineSingletons: before.1, trials: trials))
        }
        return .exhausted
    }

    /// Exact scanline interval union for arbitrary runtime paint polygons.
    static func covered(_ rect: CGRect, polygons: [[CGPoint]]) -> Bool {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0,
              polygons.allSatisfy({ $0.count >= 3 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { return false }
        let epsilon: CGFloat = 1e-7
        var ys = [rect.minY + epsilon, rect.maxY - epsilon]
        for poly in polygons {
            for point in poly where point.y > rect.minY && point.y < rect.maxY {
                ys += [max(rect.minY + epsilon, point.y - epsilon), min(rect.maxY - epsilon, point.y + epsilon)]
            }
        }
        for y in ys {
            var spans: [(CGFloat, CGFloat)] = []
            for poly in polygons {
                var xs: [CGFloat] = []
                for i in poly.indices {
                    let a = poly[i], b = poly[(i + 1) % poly.count]
                    if a.y <= y && y < b.y || b.y <= y && y < a.y {
                        xs.append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
                    }
                }
                xs.sort()
                for i in stride(from: 0, to: xs.count - xs.count % 2, by: 2) { spans.append((xs[i], xs[i + 1])) }
            }
            spans.sort { $0.0 < $1.0 }
            var cursor = rect.minX
            for (left, right) in spans where right >= cursor {
                if left > cursor + epsilon { break }
                cursor = max(cursor, right)
            }
            if cursor < rect.maxX - epsilon { return false }
        }
        return true
    }
}
