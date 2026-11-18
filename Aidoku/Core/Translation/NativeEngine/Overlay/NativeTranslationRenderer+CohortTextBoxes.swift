import CoreGraphics
import CoreText
import Foundation

extension NativeTranslationRenderer {
    /// Caller-certified text space, NOT erasure space. Coordinates and source font
    /// proxies must already be converted to the same native page units as Card.
    struct CohortTextDomain {
        let sourceFrame: CGRect
        let sourceFontProxy: CGFloat
        let fontProxyProvenance: String
        /// Caller-declared no-over-shrink floor; never below the existing renderer floor.
        let minimumFontSize: CGFloat
        let sourcePitchProxy: CGFloat?
        let polygons: [[CGPoint]]
        let frames: [CGRect]
        let protectedRects: [CGRect]
        /// Unknown source paint is not upgraded to measured by this search.
        let sourceStyleEvidence: String
        /// Immutable forecast units for spatial reasoning; never a measured ink span.
        var spatialUnit: CGFloat { sourceFontProxy }
        var observedTypographyAnchor: CohortTypographyAnchor? = nil
        /// Search-only, activated atomically for a comparable whole group.
        var proposedTypographyAnchor: CohortTypographyAnchor? = nil
        var proposedBodyClearance: CGFloat? = nil
        var typographyFrame: CGRect {
            guard let top = proposedTypographyAnchor?.top else { return sourceFrame }
            return CGRect(x: sourceFrame.minX, y: top, width: sourceFrame.width, height: sourceFrame.maxY - top)
        }
    }

    struct CohortTypographyAnchor {
        let top: CGFloat
        let family: String
        let authority: String
    }

    /// Actual first-row alphabetic/numeric fill paths. Logical geometry only:
    /// antialiasing/snapping can differ; final paint certificates remain mandatory.
    static func cohortFirstBodyTop(_ layout: NativeTranslationTypography.Layout, original: String,
        origin: CGPoint, style: NativeTranslationTypography.Style) -> CGFloat? {
        guard !style.vertical, style.horizontalScale == 1, style.outlineGlow == 0,
              original.utf16.count <= 8_192, layout.shapedText.utf16.count <= 16_384,
              NativeTranslationTypography.committedParagraphRawComplete(layout, original: original),
              let row = NativeTranslationTypography.diagnosticRuns(layout: layout).first,
              let metric = NativeTranslationTypography.horizontalRowMetrics(layout: layout, originalText: original, origin: origin)?.first,
              let baseline = metric["unsnappedBaseline"] as? [Double], baseline.count == 2,
              baseline.allSatisfy(\.isFinite), let runs = row["runs"] as? [[String: Any]], !runs.isEmpty,
              runs.count <= 128, let rowRange = row["range"] as? [Int], rowRange.count == 2 else { return nil }
        let text = layout.shapedText as NSString
        guard rowRange[0] >= 0, rowRange[1] > 0, rowRange[0] <= text.length,
              rowRange[1] <= text.length - rowRange[0] else { return nil }
        var ranges: [NSRange] = [], remaining = 4_096, top: CGFloat?
        for run in runs {
            guard let name = run["fontName"] as? String, let size = run["fontSize"] as? Double,
                  size.isFinite, size > 0, let matrix = run["textMatrix"] as? [Double], matrix == [1, 0, 0, 1, 0, 0],
                  let glyphs = run["glyphs"] as? [Int], let positions = run["positions"] as? [[Double]],
                  let indices = run["stringIndices"] as? [Int], glyphs.count == positions.count,
                  glyphs.count == indices.count, glyphs.count <= remaining,
                  let range = run["range"] as? [Int], range.count == 2,
                  range[0] >= rowRange[0], range[1] >= 0, range[0] <= rowRange[0] + rowRange[1],
                  range[1] <= rowRange[0] + rowRange[1] - range[0] else { return nil }
            remaining -= glyphs.count; ranges.append(NSRange(location: range[0], length: range[1]))
            let font = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
            guard name != "LastResort", CTFontGetMatrix(font) == .identity,
                  !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return nil }
            for i in glyphs.indices {
                guard positions[i].count == 2, positions[i].allSatisfy(\.isFinite), (0...65_535).contains(glyphs[i]),
                      indices[i] >= range[0], indices[i] < range[0] + range[1] else { return nil }
                let cluster = text.substring(with: text.rangeOfComposedCharacterSequence(at: indices[i]))
                guard cluster.unicodeScalars.contains(where: { $0.properties.isAlphabetic || $0.properties.numericType != nil }) else { continue }
                guard glyphs[i] != 0, let path = CTFontCreatePathForGlyph(font, CGGlyph(glyphs[i]), nil), !path.isEmpty else { return nil }
                let box = path.boundingBoxOfPath
                let y = CGFloat(baseline[1] - positions[i][1]) - box.maxY
                guard box.width > 0, box.height > 0, y.isFinite else { return nil }
                top = min(top ?? y, y)
            }
        }
        var cursor = rowRange[0]
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            guard r.location == cursor else { return nil }; cursor += r.length
        }
        return cursor == rowRange[0] + rowRange[1] ? top : nil
    }

    static func cohortBodyClearance(_ baseline: [CohortTextPlacement], domains: [String: CohortTextDomain]) -> CGFloat? {
        guard baseline.count > 1 else { return nil }
        let gaps = baseline.compactMap { p -> CGFloat? in
            guard let top = p.firstBodyFillTop, let source = domains[p.id]?.proposedTypographyAnchor?.top,
                  top.isFinite, source.isFinite else { return nil }
            return top - source
        }.sorted()
        return gaps.count == baseline.count ? gaps[gaps.count / 2] : nil
    }

    struct CohortScaleMember {
        let id: String
        let forecast: CGFloat
        let translatedFont: CGFloat
        let sourceVertical: Bool
        let record: [String: Any]?
    }

    struct CohortScaleObservation {
        let family: String?
        let sourceVertical: Bool?
        let logicalCrossSpan: CGFloat?
        let unknownReason: String?
    }

    /// Proposal authority only. Neither the observation nor this calibration is
    /// source font-size GT or a full-group paint/coverage certificate.
    struct CohortScaleProfile {
        let observations: [String: CohortScaleObservation]
        let weights: [String: CGFloat]
        let anchorID: String
        let anchorTranslatedFont: CGFloat
        let family: String?
        let unknownReason: String?
        var observedComparable: Bool { unknownReason == nil }
        var provenance: String {
            if let unknownReason { return "proposed legacy forecast ratios; whole-group observed unknown: \(unknownReason)" }
            return "proposed dimensionless \(family ?? "unknown") ratios; translated-font anchor \(anchorID); not source em/GT"
        }
    }

    static func cohortScaleObservation(_ member: CohortScaleMember) -> CohortScaleObservation {
        let r = member.record
        let family = r?["method"] as? String, direction = r?["sourceVertical"] as? Bool
        let raw = r?["logicalCrossSpan"] as? Double
        let span = raw.flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
        var reason: String?
        if r?["supported"] as? Bool != true { reason = r?["unknownReason"] as? String ?? "measurement-unavailable" }
        else if let unknown = r?["unknownReason"] as? String { reason = unknown }
        else if r?["confidence"] as? Double == nil { reason = "measurement-quality-unavailable" }
        else if let confidence = r?["confidence"] as? Double, !confidence.isFinite || confidence < 0.5 || confidence > 1 {
            reason = "measurement-quality-unsupported"
        }
        else if r?["logicalUnits"] as? String != "logical-page-units" || span == nil { reason = "logical-transport-unknown" }
        else if direction != member.sourceVertical { reason = "source-direction-unknown-or-mismatch" }
        else if family == nil { reason = "measurement-family-unavailable" }
        return .init(family: family, sourceVertical: direction, logicalCrossSpan: span, unknownReason: reason)
    }

    /// Freeze membership before calling. Missing/mixed evidence never drops a
    /// member, treats unknown as zero, or normalizes a surviving subset.
    static func cohortScaleProfile(_ members: [CohortScaleMember]) -> CohortScaleProfile? {
        guard members.count > 1, members.count <= 4_096,
              Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ $0.forecast.isFinite && $0.forecast > 0
                && $0.translatedFont.isFinite && $0.translatedFont > 0 }) else { return nil }
        let observations = Dictionary(uniqueKeysWithValues: members.map { ($0.id, cohortScaleObservation($0)) })
        var reason = members.compactMap { observations[$0.id]!.unknownReason }.first
        let families = Set(members.compactMap { observations[$0.id]!.family })
        let directions = Set(members.map(\.sourceVertical))
        if reason == nil && families.count != 1 { reason = "mixed-measurement-families" }
        if reason == nil && directions.count != 1 { reason = "mixed-source-directions" }
        // v1 stroke envelopes lack independent repeated-body evidence. Retain
        // their records, but do not rehabilitate them as v2 glyph-body measures.
        let bodyFamily = "owned-core-fill-repeated-glyph-body-cross-span-v2"
        if reason == nil && families.first != bodyFamily { reason = "uncalibrated-measurement-family" }
        let values = Dictionary(uniqueKeysWithValues: members.map {
            ($0.id, reason == nil ? observations[$0.id]!.logicalCrossSpan! : $0.forecast)
        })
        let ordered = members.sorted {
            let a = $0.translatedFont / values[$0.id]!, b = $1.translatedFont / values[$1.id]!
            return a == b ? $0.id < $1.id : a < b
        }
        // An actual member's translated style is the anchor, not a font average,
        // page median or conversion from ink width to em. Upper median retains
        // the legacy no-shrink reference, while explicit 2x ratios stay 2x.
        let anchor = ordered[ordered.count / 2], anchorValue = values[anchor.id]!
        let weights = values.mapValues { $0 / anchorValue }
        guard weights.values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return .init(observations: observations, weights: weights, anchorID: anchor.id,
            anchorTranslatedFont: anchor.translatedFont, family: reason == nil ? bodyFamily : nil, unknownReason: reason)
    }

    static func cohortScaleFontFrontier(_ profile: CohortScaleProfile,
        floors: [String: CGFloat]) -> [[String: CGFloat]]? {
        guard Set(floors.keys) == Set(profile.weights.keys),
              floors.values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let lower = floors.map { $0.value / profile.weights[$0.key]! }.max()!
        var anchors = [profile.anchorTranslatedFont, profile.anchorTranslatedFont * 1.1, profile.anchorTranslatedFont * 0.9]
        if !anchors.contains(where: { $0 >= lower }) { anchors.append(lower) }
        return anchors.filter { $0 >= lower }.map { anchor in profile.weights.mapValues { $0 * anchor } }
    }

    static func cohortImmutableSourceFrame(_ bounds: [CGFloat], mapping: [CGFloat]) -> CGRect? {
        guard bounds.count == 4, mapping.count == 4,
              bounds.allSatisfy(\.isFinite), mapping.allSatisfy(\.isFinite),
              bounds[2] > 0, bounds[3] > 0, mapping[2] > 0, mapping[3] > 0 else { return nil }
        let r = CGRect(x: mapping[0] + bounds[0] * mapping[2], y: mapping[1] + bounds[1] * mapping[3],
            width: bounds[2] * mapping[2], height: bounds[3] * mapping[3])
        return r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite ? r : nil
    }

    static func cohortLegacyFontProxy(forecast: CGFloat?, requested: CGFloat) -> (value: CGFloat, provenance: String)? {
        if let forecast, forecast.isFinite, forecast > 0 {
            return (forecast, "immutable saved sourceFontSize forecast; measurements retained separately, not absolute em")
        }
        guard requested.isFinite, requested > 0 else { return nil }
        return (requested, "requested font fallback estimate; source forecast unavailable; measurements retained separately")
    }

    static func cohortSpatialRelationConfidence(_ a: CGRect, unitA: CGFloat, _ b: CGRect, unitB: CGFloat) -> CGFloat? {
        guard cohortValidRect(a), cohortValidRect(b), unitA.isFinite, unitA > 0, unitB.isFinite, unitB > 0 else { return nil }
        let unit = max(unitA, unitB)
        let top = abs(a.minY - b.minY) / unit
        let gap = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)) / unit
        let hierarchy = abs(log(unitA / unitB))
        let confidence = exp(-top / 2 - gap / 8 - hierarchy / 2)
        return confidence.isFinite ? confidence : nil
    }

    static func cohortObservedTypographyAnchor(card: Card, sourceFrame: CGRect) -> CohortTypographyAnchor? {
        let observation = cohortScaleObservation(.init(id: card.item.id, forecast: 1, translatedFont: 1,
            sourceVertical: card.item.sourceVertical,
            record: card.harmonyRecord["observedSourceLetteringScale"] as? [String: Any]))
        guard uprightTranslatedSourceColumn(card.item), observation.unknownReason == nil,
              let family = observation.family,
              let top = card.harmonyRecord["sourceTopObservedInkAnchor"] as? Double,
              top.isFinite, CGFloat(top) >= sourceFrame.minY, CGFloat(top) < sourceFrame.maxY else { return nil }
        return .init(top: CGFloat(top), family: family,
            authority: "observed owned ink start transported with measurement family; not exact first baseline")
    }

    /// Integration adapter for the caller's independently certified text space.
    /// item.sourceFrame is the mapping viewport, NOT this paragraph's bounds.
    /// Do not intersect textSpace or frames with sourcePlateRect/backing here.
    static func cohortTextDomain(card: Card, certifiedTextSpace: TextPaintDomain,
        frames: [CGRect], protectedRects: [CGRect], minimumFontSize: CGFloat,
        sourcePitchProxy: CGFloat? = nil, sourceStyleEvidence: String = "unknown") -> CohortTextDomain? {
        let item = card.item, bounds = item.sourceBounds, mapping = item.sourceFrame
        guard bounds.count == 4, mapping.count == 4,
              bounds.allSatisfy(\.isFinite), mapping.allSatisfy(\.isFinite),
              mapping[2] > 0, mapping[3] > 0, bounds[2] > 0, bounds[3] > 0,
              !frames.isEmpty, frames.count <= 8, frames.allSatisfy(cohortValidRect),
              minimumFontSize.isFinite, minimumFontSize >= BrowserOverlayLayoutPlanner.minimumRenderedFontSize else { return nil }
        let source = CGRect(x: mapping[0] + bounds[0] * mapping[2], y: mapping[1] + bounds[1] * mapping[3],
            width: bounds[2] * mapping[2], height: bounds[3] * mapping[3])
        guard cohortValidRect(source) else { return nil }
        // Absolute legacy planning MUST NOT consume any measurement family.
        // Observations remain untouched on Card and are read group-wise below.
        guard let selection = cohortLegacyFontProxy(forecast: item.sourceFontSize, requested: item.fontSize) else { return nil }
        let proxy = selection.value
        let space = certifiedTextSpace.rect
        let polygon = certifiedTextSpace.polygon.isEmpty
            ? [CGPoint(x: space.minX, y: space.minY), CGPoint(x: space.maxX, y: space.minY),
               CGPoint(x: space.maxX, y: space.maxY), CGPoint(x: space.minX, y: space.maxY)]
            : certifiedTextSpace.polygon
        return .init(sourceFrame: source, sourceFontProxy: proxy,
            fontProxyProvenance: selection.provenance,
            minimumFontSize: minimumFontSize, sourcePitchProxy: sourcePitchProxy, polygons: [polygon],
            frames: frames, protectedRects: protectedRects, sourceStyleEvidence: sourceStyleEvidence,
            observedTypographyAnchor: cohortObservedTypographyAnchor(card: card, sourceFrame: source))
    }

    struct CohortTextPlacement {
        let cardIndex: Int
        let id: String
        let frame: CGRect
        let origin: CGPoint
        let style: NativeTranslationTypography.Style
        let layout: NativeTranslationTypography.Layout
        let rows: [[String: Any]]
        let cuts: Int?
        let singletons: Int?
        let completenessDebt: Int
        let baselineObserved: Bool
        let rowGap: CGFloat?
        let rowGapProven: Bool
        let firstBaseline: CGFloat
        let firstBaselineX: CGFloat
        var horizontalAlignmentAnchor: CGFloat? = nil
        let sourceTopPadding: CGFloat
        let sourceStartPadding: CGFloat
        var sourceEndPadding: CGFloat = 0
        let pitchReferenceRatio: CGFloat
        var fontProxyProvenance: String
        let sourceStyleEvidence: String
        let preservedStyleModelProvenance: String
        var shapingPaddingScale: CGFloat = 1
        var firstBodyFillTop: CGFloat? = nil
    }

    struct CohortTextRelation {
        let firstID: String
        let secondID: String
        /// Geometric hypothesis only; not semantic or manually certified grouping.
        let confidence: CGFloat
    }

    struct CohortTextProposal {
        /// Original card indices/IDs stay distinct and in original array order.
        let placements: [CohortTextPlacement]
        let relations: [CohortTextRelation]
        /// Nil is unknown, never a zero-cost quality observation.
        let baselineObjective: [CGFloat?]
        let candidateObjective: [CGFloat?]
        /// Frozen from baseline observations; candidate missing known values fails.
        let baselineKnownMask: [Bool]
        let unknownBaselineRelationCount: Int
        let fontChanges: [CohortFontChange]
        var scaleProfile: CohortScaleProfile? = nil
        var observedRatiosUsed: Bool = false
        var proposedTypographyAnchors: [String: CohortTypographyAnchor] = [:]
        var proposedBodyClearance: CGFloat? = nil
    }

    struct CohortFontChange {
        let id: String
        let baseline: CGFloat
        let proposed: CGFloat
        let retainedRatio: CGFloat
        let shrunk: Bool
        let evidence: String
    }

    /// Caller opt-in floor only. Source-relative permission is evaluated with
    /// the actual group's proxy scales below; this does not itself approve shrink.
    static func cohortBoundedShrinkFloor(baselineFont: CGFloat) -> CGFloat? {
        guard baselineFont.isFinite, baselineFont > 0 else { return nil }
        return max(BrowserOverlayLayoutPlanner.minimumRenderedFontSize, baselineFont * 0.8)
    }

    static func cohortSourceRelativeFloor(baselineFont: CGFloat, sourceProxy: CGFloat,
        referenceScale: CGFloat) -> CGFloat? {
        guard let bounded = cohortBoundedShrinkFloor(baselineFont: baselineFont),
              sourceProxy.isFinite, sourceProxy > 0, referenceScale.isFinite, referenceScale > 0 else { return nil }
        // Bounded group shrink is a proposal, never a quality admission. The
        // final known-fidelity/Pareto/raw certificate gates still have to pass.
        return max(bounded, min(baselineFont, sourceProxy * referenceScale * 0.8))
    }

    static func cohortClearedPaintedPitch(current: CGFloat, observedGap: CGFloat,
        minimumGap: CGFloat = 0.25) -> CGFloat? {
        guard current.isFinite, current > 0, observedGap.isFinite,
              minimumGap.isFinite, minimumGap >= 0 else { return nil }
        let pitch = ceil(current + max(0, minimumGap - observedGap))
        return pitch.isFinite && pitch > 0 ? pitch : nil
    }

    struct CohortTextBudget {
        var utf16Work = 131_072
        var geometryWork = 131_072
        var relationComparisons = 4_096
        var groupCertificates = 32
        var shapedCandidates = 0
        var unknownRowMeasurements = 0
        var incompleteGroups = 0
        /// Fixed stage labels only: no words, per-card payloads or pixel artifacts.
        var reasonCounts: [String: Int] = [:]
        mutating func record(_ reason: String, count: Int = 1) {
            reasonCounts[reason, default: 0] += count
        }
    }

    /// Proposal-only API. Never updates Card, item identity/text, backing, palette
    /// or clip fields. Main must separately install text placement and certify
    /// full raw/clipped ink, both paint anchors, row gaps, peers, artwork/KEPT,
    /// contrast and frozen erasure coverage for the ENTIRE group before commit.
    /// A true certificate means all these checks were measured, not unknown.
    static func improveCohortTextBoxes(
        cards: [Card], domains: [String: CohortTextDomain], budget: inout CohortTextBudget,
        allowSourceRelativeShrink: Bool = false,
        useObservedFamilyRatios: Bool = false,
        shapingPaddingScale: CGFloat = 1,
        certifyGroup: (CohortTextProposal) throws -> Bool
    ) throws -> [CohortTextProposal] {
        // These are shape/capacity bounds, not font success criteria. No binary
        // search or monotonic wrapping assumption. Excess frames are not hidden:
        // the caller supplies a deterministically ordered, bounded frontier.
        let beamWidth = 8, maximumFrames = 8
        budget.record("inputCards", count: cards.count)
        guard shapingPaddingScale.isFinite, (0.5...2).contains(shapingPaddingScale) else {
            budget.record("invalidShapingPaddingScale"); return []
        }
        let eligible = cards.indices.filter { index in
            let c = cards[index], i = c.item
            guard let d = domains[i.id] else { budget.record("domainMissing"); return false }
            let accepted = !i.sourceTextOnly && !i.vertical
                && cohortBackingIsUpright(sourceRotation: i.rotation, textRotation: c.effectiveTextRotation,
                    hasStraightenedBacking: c.straightenedPanelRect != nil) && c.unitTextParts.isEmpty
                && !c.style.preservesBlockRows && c.heavyStrokeWidth == 0
                && c.style.outlineGlow == 0
                && c.style.fontSize.isFinite && c.style.fontSize > 0
                && c.style.lineHeight.isFinite && c.style.lineHeight > 0
                && d.sourceFontProxy.isFinite && d.sourceFontProxy > 0
                && d.minimumFontSize.isFinite && d.minimumFontSize >= BrowserOverlayLayoutPlanner.minimumRenderedFontSize
                && (d.sourcePitchProxy == nil || (d.sourcePitchProxy!.isFinite && d.sourcePitchProxy! > 0))
                && cohortValidRect(d.sourceFrame) && !d.frames.isEmpty
                && d.frames.count <= maximumFrames && !d.polygons.isEmpty
                && d.polygons.allSatisfy { $0.count >= 3 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }
                && d.protectedRects.allSatisfy(cohortValidRect)
            budget.record(accepted ? "eligibleCards" : "eligibilityRejected")
            return accepted
        }
        guard Set(cards.map { $0.item.id }).count == cards.count else { return [] }
        let relationFrames = Dictionary(uniqueKeysWithValues: eligible.map { index in
            let i = cards[index].item
            return (i.id, cohortImmutableSourceFrame(i.sourceBounds, mapping: i.sourceFrame) ?? domains[i.id]!.sourceFrame)
        })
        var adjacency: [Int: [Int]] = [:], relations: [CohortTextRelation] = []
        // Do not emit partially discovered groups after exhausting relation work.
        for (offset, a) in eligible.enumerated() {
            for b in eligible.dropFirst(offset + 1) {
                try Task.checkCancellation()
                guard budget.relationComparisons > 0 else {
                    budget.record("relationBudgetExhausted"); budget.incompleteGroups += 1; return []
                }
                budget.relationComparisons -= 1
                budget.record("relationsTested")
                let da = domains[cards[a].item.id]!, db = domains[cards[b].item.id]!
                let fa = relationFrames[cards[a].item.id]!, fb = relationFrames[cards[b].item.id]!
                guard let confidence = cohortSpatialRelationConfidence(fa, unitA: da.spatialUnit, fb, unitB: db.spatialUnit),
                      confidence >= 0.55 else { continue }
                budget.record("relationsAccepted")
                adjacency[a, default: []].append(b); adjacency[b, default: []].append(a)
                relations.append(.init(firstID: cards[a].item.id, secondID: cards[b].item.id, confidence: confidence))
            }
        }
        let frozenDomains = domains
        var visited: Set<Int> = [], result: [CohortTextProposal] = []
        for seed in eligible where !visited.contains(seed) {
            var domains = frozenDomains
            var group = [seed], cursor = 0
            visited.insert(seed)
            while cursor < group.count {
                for peer in adjacency[group[cursor], default: []] where visited.insert(peer).inserted { group.append(peer) }
                cursor += 1
            }
            group.sort()
            guard group.count > 1 else { budget.record("singletonGroups"); continue }
            budget.record("groups")
            var baseline: [CohortTextPlacement] = []
            for index in group {
                let c = cards[index], d = domains[c.item.id]!
                guard let p = cohortPlacement(index: index, card: c, domain: d, frame: c.item.rect,
                    origin: c.textOrigin, style: c.style, layout: c.typography, baseline: true) else {
                    budget.record("baselineRejected"); budget.unknownRowMeasurements += 1; break
                }
                baseline.append(p)
                if p.cuts == nil || !p.baselineObserved { budget.unknownRowMeasurements += 1 }
            }
            guard baseline.count == group.count else { continue }
            guard baseline.allSatisfy({ $0.horizontalAlignmentAnchor != nil }) else {
                budget.record("baselineAlignmentUnknown"); continue
            }
            guard let profile = cohortScaleProfile(baseline.map { p in
                let c = cards[p.cardIndex]
                return CohortScaleMember(id: p.id, forecast: domains[p.id]!.spatialUnit,
                    translatedFont: p.style.fontSize, sourceVertical: c.item.sourceVertical,
                    record: c.harmonyRecord["observedSourceLetteringScale"] as? [String: Any])
            }) else { budget.record("scaleProfileInvalid"); continue }
            let observedRatiosUsed = useObservedFamilyRatios && profile.observedComparable
            budget.record(profile.observedComparable ? "observedFamilyComparableGroups" : "observedFamilyUnknownGroups")
            // The caller has already run the unchanged legacy pass. Spend the
            // second pass only on a complete comparable measurement family.
            if useObservedFamilyRatios && !profile.observedComparable {
                budget.record("observedFamilySecondPassWithheld")
                continue
            }
            if !useObservedFamilyRatios { budget.record("observedFamilyPlanningWithheld") }
            // Commit may rebuild Domain through its legacy initializer. Recover
            // observations from the same frozen Card, never from display colours.
            let anchors = group.compactMap { index -> (String, CohortTypographyAnchor)? in
                let c = cards[index], d = domains[c.item.id]!
                guard let a = cohortObservedTypographyAnchor(card: c, sourceFrame: d.sourceFrame),
                      a.family == profile.family else { return nil }
                return (c.item.id, a)
            }
            if observedRatiosUsed && anchors.count == group.count {
                for (id, anchor) in anchors { domains[id]!.proposedTypographyAnchor = anchor }
                budget.record("comparableObservedTypographyAnchorsUsed")
            } else { budget.record("observedTypographyAnchorsWithheldGroups") }
            if observedRatiosUsed, let clearance = cohortBodyClearance(baseline, domains: domains) {
                for p in baseline { domains[p.id]!.proposedBodyClearance = clearance }
                budget.record("bodyTopAlignmentGroups")
            }
            // Group-level fallback, never a per-card ink/forecast mixture.
            // Dimensional source units remain confined to spatial/pitch geometry.
            let fontWeights = Dictionary(uniqueKeysWithValues: baseline.map {
                ($0.id, observedRatiosUsed ? profile.weights[$0.id]! : domains[$0.id]!.spatialUnit)
            })
            // Unsupported observations retain the established forecast-based
            // search. Enabling observed families must not disable that path.
            let canShrink = allowSourceRelativeShrink
            let scales = baseline.map { $0.style.fontSize / fontWeights[$0.id]! }.sorted()
            let referenceScale = observedRatiosUsed ? profile.anchorTranslatedFont
                : scales[canShrink ? (scales.count - 1) / 2 : scales.count / 2]
            let hierarchyWeights: [String: CGFloat]? = useObservedFamilyRatios
                ? (observedRatiosUsed ? fontWeights : nil) : fontWeights
            let followsSourceTop = group.allSatisfy { uprightTranslatedSourceColumn(cards[$0].item) }
            var residuals: [CGFloat] = []
            if followsSourceTop {
                // Measure translated-font top alignment rather than inheriting
                // an incumbent's centering slack as original source fidelity.
                for member in baseline {
                    let c = cards[member.cardIndex], text = c.item.typesettingText ?? c.item.text
                    let work = max(1, text.utf16.count)
                    guard work <= budget.utf16Work else { budget.record("sourceTopReferenceBudgetExhausted"); break }
                    budget.utf16Work -= work; budget.shapedCandidates += 1
                    var topStyle = member.style
                    topStyle.alignsToTop = true
                    let topLayout = NativeTranslationTypography.layout(text: text,
                        in: c.item.contentRect.size, style: topStyle)
                    guard let rows = NativeTranslationTypography.horizontalRowMetrics(layout: topLayout, originalText: text),
                          let first = rows.first?["unsnappedBaseline"] as? [Double],
                          first.count == 2, first[1].isFinite else {
                        budget.record("sourceTopReferenceUnknown"); break
                    }
                    residuals.append(CGFloat(first[1]) / member.style.fontSize)
                }
                guard residuals.count == baseline.count else { continue }
            } else {
                residuals = baseline.map {
                    ($0.firstBaseline - domains[$0.id]!.typographyFrame.minY - $0.sourceTopPadding) / $0.style.fontSize
                }
            }
            residuals.sort()
            let referenceBaselineRatio = residuals[residuals.count / 2]
            let starts = baseline.map {
                ($0.horizontalAlignmentAnchor! - cohortSourceHorizontalAnchor($0, domain: domains[$0.id]!))
                    / domains[$0.id]!.spatialUnit
            }.sorted()
            let referenceStartRatio = starts[starts.count / 2]
            let ids = Set(baseline.map(\.id))
            let groupRelations = relations.filter { ids.contains($0.firstID) && ids.contains($0.secondID) }
            let observedRelations = cohortObservedRelations(groupRelations, baseline: baseline)
            let before = cohortObjective(baseline, domains: domains, relations: groupRelations,
                observedRelations: observedRelations, hierarchyWeights: hierarchyWeights, explicitHierarchy: true)
            if group.contains(where: { domains[cards[$0].item.id]?.sourcePitchProxy == nil }) {
                budget.record("sourcePitchUnmeasuredGroups")
            }
            let knownMask = before.map { $0 != nil }
            var best: CohortTextProposal?
            var exhausted = false
            // An already over-shrunk member can pull the reference scale below
            // another member's allowed floor. Include the exact intersection
            // lower bound instead of trying three inadmissible recipes and
            // abandoning a jointly feasible group without shaping any text.
            let minimumSharedScale = group.map { index -> CGFloat in
                let c = cards[index], d = domains[c.item.id]!
                let hasSourceProxy = c.item.sourceFontSize.map { $0.isFinite && $0 > 0 } == true
                let sourceFloor = canShrink && hasSourceProxy
                    ? cohortSourceRelativeFloor(baselineFont: c.style.fontSize,
                        sourceProxy: fontWeights[c.item.id]!, referenceScale: referenceScale) ?? c.style.fontSize
                    : c.style.fontSize
                return max(d.minimumFontSize, sourceFloor) / fontWeights[c.item.id]!
            }.max()!
            var sharedScales = [referenceScale, referenceScale * 1.1, referenceScale * 0.9]
            // A numerically admissible recipe may still fail Korean wrapping.
            // Try the exact joint floor in a comparable-family trial even when
            // a larger recipe passes the FONT floor; never lower that floor.
            if (observedRatiosUsed || !sharedScales.contains(where: { $0 >= minimumSharedScale })),
               !sharedScales.contains(where: { abs($0 - minimumSharedScale) <= 1e-7 }) {
                sharedScales.append(minimumSharedScale)
                budget.record("sharedScaleFloorFrontierAdded")
            }
            recipeLoop: for sharedScale in sharedScales {
                for pitchFactor: CGFloat in [1, 1.08] {
                    var beam: [[CohortTextPlacement]] = [[]]
                    for index in group {
                        try Task.checkCancellation()
                        let c = cards[index], d = domains[c.item.id]!
                        let text = c.item.typesettingText ?? c.item.text
                        let font = fontWeights[c.item.id]! * sharedScale
                        let hasSourceProxy = c.item.sourceFontSize.map { $0.isFinite && $0 > 0 } == true
                        let sourceFloor = canShrink && hasSourceProxy
                            ? cohortSourceRelativeFloor(baselineFont: c.style.fontSize,
                                sourceProxy: fontWeights[c.item.id]!, referenceScale: referenceScale) ?? c.style.fontSize
                            : c.style.fontSize
                        guard font.isFinite, font >= max(d.minimumFontSize, sourceFloor),
                              font <= 2_048 else { budget.record("fontFloorRejected"); beam = []; break }
                        var alternatives: [CohortTextPlacement] = []
                        for frame in d.frames where cohortValidRect(frame) {
                            let work = max(1, text.utf16.count)
                            guard work <= budget.utf16Work else {
                                budget.record("utfBudgetExhausted"); exhausted = true; break recipeLoop
                            }
                            budget.utf16Work -= work; budget.shapedCandidates += 1
                            var style = c.style
                            style.fontSize = font
                            if observedRatiosUsed, d.proposedBodyClearance != nil {
                                style.alignsToTop = true
                            }
                            let pitch = d.sourcePitchProxy.map { $0 / d.spatialUnit }
                                ?? (c.style.lineHeight / c.style.fontSize)
                            style.lineHeight = font * pitch * pitchFactor
                            style.outlineWidth = c.style.outlineWidth * font / c.style.fontSize
                            if style.trackingScalesWithFont { style.tracking *= font / c.style.fontSize }
                            // Copy all face/weight/paint/slant-related state; no black/white style inference.
                            var item = c.item
                            item.x = frame.minX; item.y = frame.minY
                            item.width = frame.width; item.height = frame.height
                            // Text capacity only; opaque erasure backing never changes.
                            item.paddingTop *= shapingPaddingScale; item.paddingBottom *= shapingPaddingScale
                            item.paddingLeft *= shapingPaddingScale; item.paddingRight *= shapingPaddingScale
                            guard cohortValidRect(item.contentRect) else { continue }
                            var referenceLayout = NativeTranslationTypography.layout(text: text, in: item.contentRect.size, style: style)
                            // A font-relative pitch alone can never clear a thick
                            // outline. Derive candidate pitch from observed native
                            // row ink, then re-shape; retain all subsequent fit,
                            // ownership, fidelity and whole-group paint gates.
                            for _ in 0..<2 {
                                let clearance = cohortRowGap(referenceLayout, outline: style.outlineWidth)
                                guard clearance.proven, let gap = clearance.value, gap < 0.25 else { break }
                                guard work <= budget.utf16Work else {
                                    budget.record("rowClearanceUTFBudgetSkipped"); break
                                }
                                budget.utf16Work -= work; budget.shapedCandidates += 1
                                // The native row painter floors its pitch. A
                                // fractional correction can therefore leave
                                // the exact same overlapping rows after both
                                // retries. Advance to a reachable painted pitch.
                                guard let clearedPitch = cohortClearedPaintedPitch(current: style.lineHeight,
                                    observedGap: gap) else { budget.record("invalidRowClearancePitch"); break }
                                style.lineHeight = clearedPitch
                                referenceLayout = NativeTranslationTypography.layout(text: text,
                                    in: item.contentRect.size, style: style)
                                budget.record("observedRowClearanceReflows")
                            }
                            // Protect an ordinary atomic group's minimum work from
                            // optional paragraph search. Reservations are restored,
                            // not minted; all actual work still uses this same ledger.
                            let laterUTF = group.filter { $0 > index }.reduce(0) {
                                $0 + (cards[$1].item.typesettingText ?? cards[$1].item.text).utf16.count
                            }
                            let reservedUTF = min(budget.utf16Work, laterUTF + work * 3)
                            let minimumSupport = group.reduce(0) { total, member in
                                let vertices = domains[cards[member].item.id]!.polygons.reduce(0) { $0 + $1.count }
                                let cost = vertices.multipliedReportingOverflow(by: max(2, vertices * 2 + 2))
                                let sum = total.addingReportingOverflow(cost.overflow ? Int.max : cost.partialValue)
                                return sum.overflow ? Int.max : sum.partialValue
                            }
                            let reservedGeometry = min(budget.geometryWork, minimumSupport)
                            budget.utf16Work -= reservedUTF; budget.geometryWork -= reservedGeometry
                            let paragraph = NativeTranslationTypography.committedParagraphCandidates(text: text,
                                in: item.contentRect.size, style: style, reference: referenceLayout,
                                utf16Work: &budget.utf16Work, geometryWork: &budget.geometryWork)
                            budget.utf16Work += reservedUTF; budget.geometryWork += reservedGeometry
                            budget.record(paragraph.complete ? "paragraphFrontierComplete" : "paragraphFrontierUnknown")
                            // Ordinary ALWAYS first; comparable-family trials keep
                            // three already-charged paragraph alternatives. A single
                            // raggedness-ranked recipe can isolate a short Korean word
                            // even though another complete recipe avoids that row.
                            // unknown/incomplete frontier never removes that fallback.
                            var layouts = [referenceLayout]
                            if paragraph.complete {
                                layouts.append(contentsOf: paragraph.layouts.prefix(observedRatiosUsed ? 3 : 1))
                            }
                            let origin = item.contentRect.origin
                            for layout in layouts {
                            var initialRejection: String?
                            let initialCandidate = cohortPlacement(index: index, card: c, domain: d, frame: frame,
                                origin: origin, style: style, layout: layout,
                                onRejection: { initialRejection = $0 })
                            if let initialRejection { budget.record("placement." + initialRejection) }
                            guard let initial = initialCandidate else {
                                budget.record("initialPlacementRejected"); budget.unknownRowMeasurements += 1; continue
                            }
                            // At most four anchored placements per shaped frame. Both
                            // references remain relative to this member's own source,
                            // never a global absolute X/Y baseline across paragraphs.
                            let idealDx = cohortSourceHorizontalAnchor(initial, domain: d)
                                + referenceStartRatio * d.spatialUnit - initial.horizontalAlignmentAnchor!
                            let idealDy: CGFloat
                            if let clearance = d.proposedBodyClearance, let top = d.proposedTypographyAnchor?.top,
                               let body = initial.firstBodyFillTop {
                                idealDy = top + clearance - body
                            } else {
                                idealDy = d.typographyFrame.minY + c.item.paddingTop
                                    + referenceBaselineRatio * font - initial.firstBaseline
                            }
                            let xs: [CGFloat] = abs(idealDx) <= 1e-7 ? [0] : [0, idealDx]
                            let ys: [CGFloat] = abs(idealDy) <= 1e-7 ? [0] : [0, idealDy]
                            for dy in ys { for dx in xs {
                                budget.record("anchorPlacements")
                                // Align painted text inside its fixed shaping
                                // capacity. Moving the entire capacity rectangle
                                // would reject a safe anchor shift merely because
                                // unused blank rows leave the certified domain.
                                let movedFrame = frame
                                let movedOrigin = CGPoint(x: origin.x + dx, y: origin.y + dy)
                                let placed: CohortTextPlacement?
                                if dx == 0 && dy == 0 { placed = initial }
                                else {
                                    guard work <= budget.utf16Work else {
                                        budget.record("anchorUTFBudgetSkipped"); continue
                                    }
                                    budget.utf16Work -= work
                                    placed = cohortPlacement(index: index, card: c, domain: d, frame: movedFrame,
                                        origin: movedOrigin, style: style, layout: layout)
                                }
                                guard var placed else { budget.record("placementRejected"); continue }
                                placed.shapingPaddingScale = shapingPaddingScale
                                placed.fontProxyProvenance = observedRatiosUsed ? profile.provenance
                                    : d.fontProxyProvenance + "; proposed legacy plan; observed family "
                                        + (profile.unknownReason ?? "comparable but planning withheld")
                                let prior = baseline.first { $0.cardIndex == index }!
                                if observedRatiosUsed && placed.layout.lineCount > prior.layout.lineCount {
                                    budget.record("observedFamilyAddedRowsRejected")
                                    continue
                                }
                                guard prior.cuts.map({ placed.cuts! <= $0 }) ?? (prior.completenessDebt > 0),
                                      prior.singletons.map({ placed.singletons! <= $0 }) ?? (prior.completenessDebt > 0) else {
                                    budget.record("wrapRejected")
                                    budget.record("wrapRejected.id." + c.item.id)
                                    if let old = prior.cuts, let new = placed.cuts, new > old {
                                        budget.record("wrapRejected.tokenCuts.\(old)-to-\(new)")
                                    }
                                    if let old = prior.singletons, let new = placed.singletons, new > old {
                                        budget.record("wrapRejected.singletons.\(old)-to-\(new)")
                                    }
                                    continue
                                }
                                guard !d.protectedRects.contains(where: { cohortOverlap(movedFrame, $0) }) else {
                                    budget.record("protectionRejected"); continue
                                }
                                if let source = d.proposedTypographyAnchor?.top,
                                   let clearance = d.proposedBodyClearance,
                                   let oldTop = prior.firstBodyFillTop,
                                   let newTop = placed.firstBodyFillTop,
                                   abs(newTop - source - clearance) > abs(oldTop - source - clearance) + 1e-7 {
                                    budget.record("bodyMemberSourceDistancePrefilterRejected")
                                    continue
                                }
                                // Exact polygon support is checked once per member
                                // of a full Pareto candidate, not twice per speculative
                                // member before an atomic group can be assembled.
                                alternatives.append(placed)
                            }}
                            }
                        }
                        var expanded: [[CohortTextPlacement]] = []
                        for partial in beam {
                            for next in alternatives {
                                // Search frames may share unused space. Source
                                // backing and paragraph capacity are not painted
                                // text; reject actual stroke-inclusive glyph
                                // contacts instead, before the pixel certificate.
                                var collision = false
                                for previous in partial {
                                    guard let intersects = cohortPaintedGlyphOverlap(previous, next,
                                        remainingWork: &budget.geometryWork) else {
                                        budget.record("glyphContactMeasurementUnknown"); collision = true; break
                                    }
                                    if intersects { collision = true; break }
                                }
                                guard !collision else { continue }
                                // Source horizontal order survives width redistribution; never merge identities.
                                guard partial.allSatisfy({ prior in
                                    let dx = d.sourceFrame.midX - domains[prior.id]!.sourceFrame.midX
                                    guard let nextAnchor = next.horizontalAlignmentAnchor,
                                          let priorAnchor = prior.horizontalAlignmentAnchor else { return false }
                                    return dx == 0 || (nextAnchor - priorAnchor) * dx > 0
                                }) else { continue }
                                expanded.append(partial + [next])
                            }
                        }
                        if let first = expanded.first {
                            let partialIDs = Set(first.map(\.id))
                            let partialRelations = groupRelations.filter {
                                partialIDs.contains($0.firstID) && partialIDs.contains($0.secondID)
                            }
                            let partialBaseline = baseline.filter { partialIDs.contains($0.id) }
                            let partialObserved = cohortObservedRelations(partialRelations, baseline: partialBaseline)
                            let mask = cohortObjective(partialBaseline, domains: domains, relations: partialRelations,
                                observedRelations: partialObserved, hierarchyWeights: hierarchyWeights,
                                explicitHierarchy: true).map { $0 != nil }
                            beam = Array(expanded.sorted {
                                cohortLexicographic(cohortObjective($0, domains: domains, relations: partialRelations,
                                    observedRelations: partialObserved, hierarchyWeights: hierarchyWeights,
                                    explicitHierarchy: true), cohortObjective($1, domains: domains,
                                    relations: partialRelations, observedRelations: partialObserved,
                                    hierarchyWeights: hierarchyWeights, explicitHierarchy: true), knownMask: mask)
                            }.prefix(beamWidth))
                        } else { beam = [] }
                        if beam.isEmpty { budget.record("beamEmpty"); break }
                    }
                    for placements in beam where placements.count == group.count {
                        budget.record("fullCandidates")
                        let after = cohortObjective(placements, domains: domains, relations: groupRelations,
                            observedRelations: observedRelations, hierarchyWeights: hierarchyWeights, explicitHierarchy: true)
                        if domains[placements[0].id]?.proposedBodyClearance != nil,
                           let oldBody = before[4], let newBody = after[4] {
                            budget.record(newBody > oldBody + 1e-7 ? "bodyObjectiveWorsened"
                                : newBody < oldBody - 1e-7 ? "bodyObjectiveImproved" : "bodyObjectiveUnchanged")
                            for p in placements {
                                guard let old = baseline.first(where: { $0.id == p.id }),
                                      let source = domains[p.id]?.proposedTypographyAnchor?.top,
                                      let clearance = domains[p.id]?.proposedBodyClearance,
                                      let oldTop = old.firstBodyFillTop, let newTop = p.firstBodyFillTop else { continue }
                                if abs(newTop - source - clearance) < abs(oldTop - source - clearance) - 1e-7 {
                                    budget.record("bodyMemberSourceDistanceImproved")
                                    budget.record("bodyMemberSourceDistanceImproved.id." + p.id)
                                } else if abs(newTop - source - clearance) > abs(oldTop - source - clearance) + 1e-7 {
                                    budget.record("bodyMemberSourceDistanceWorsened")
                                    budget.record("bodyMemberSourceDistanceWorsened.id." + p.id)
                                }
                            }
                        }
                        let changes = placements.map { p in
                            let base = cards[p.cardIndex].style.fontSize
                            return CohortFontChange(id: p.id, baseline: base, proposed: p.style.fontSize,
                                retainedRatio: p.style.fontSize / base, shrunk: p.style.fontSize < base - 1e-7,
                                evidence: p.fontProxyProvenance)
                        }
                        if changes.contains(where: \.shrunk) {
                            // Shrink needs known source fidelity improvement; current-model
                            // pitch is not source evidence when any source pitch is unknown.
                            var fidelityAxes = [3, 4, 5]
                            if group.allSatisfy({ domains[cards[$0].item.id]?.sourcePitchProxy != nil }) {
                                fidelityAxes.append(6)
                            }
                            let fidelityImproved = fidelityAxes.contains { axis in
                                guard knownMask[axis], let x = after[axis], let y = before[axis] else { return false }
                                return x.isFinite && y.isFinite && x < y - 1e-7
                            }
                            guard canShrink, fidelityImproved,
                                  changes.allSatisfy({ $0.retainedRatio >= 0.8 - 1e-7 }) else {
                                budget.record("shrinkRejected"); continue
                            }
                        }
                        // Pareto admission: not independent font gain or fit-only success.
                        guard cohortDominates(after, before, knownMask: knownMask) else {
                            budget.record("paretoRejected")
                            let axes = ["completeness", "tokenCuts", "singletons", "hierarchy", "baseline", "start", "pitch"]
                            for axis in axes.indices where knownMask[axis] {
                                if let x = after[axis], let y = before[axis], x.isFinite, y.isFinite, x > y + 1e-7 {
                                    budget.record("paretoRejected.worsened." + axes[axis])
                                }
                            }
                            continue
                        }
                        if let reason = cohortAnchorOnlyRejection(placements, baseline: baseline, domains: domains,
                            observedRelations: observedRelations, before: before, after: after) {
                            budget.record(reason); continue
                        }
                        guard best == nil || cohortLexicographic(after, best!.candidateObjective, knownMask: knownMask) else {
                            budget.record("rankRejected"); continue
                        }
                        var supported = true
                        for placement in placements {
                            let polygons = domains[placement.id]!.polygons
                            let vertices = polygons.reduce(0) { $0 + $1.count }
                            let cost = vertices.multipliedReportingOverflow(by: max(2, vertices * 2 + 2))
                            guard !cost.overflow, cost.partialValue <= budget.geometryWork else {
                                budget.record("geometryBudgetExhausted"); exhausted = true; break recipeLoop
                            }
                            budget.geometryWork -= cost.partialValue
                            budget.record("supportChecks")
                            guard NativeSmallFontReadabilityPolicy.covered(placement.frame, polygons: polygons) else {
                                budget.record("supportRejected"); supported = false; break
                            }
                        }
                        guard supported else { continue }
                        let proposal = CohortTextProposal(placements: placements, relations: groupRelations,
                            baselineObjective: before, candidateObjective: after, baselineKnownMask: knownMask,
                            unknownBaselineRelationCount: groupRelations.count - observedRelations.count, fontChanges: changes,
                            scaleProfile: profile, observedRatiosUsed: observedRatiosUsed,
                            proposedTypographyAnchors: Dictionary(uniqueKeysWithValues: placements.compactMap { p in
                                domains[p.id]?.proposedTypographyAnchor.map { (p.id, $0) }
                            }), proposedBodyClearance: domains[placements[0].id]?.proposedBodyClearance)
                        guard budget.groupCertificates > 0 else {
                            budget.record("certificateBudgetExhausted"); exhausted = true; break recipeLoop
                        }
                        budget.groupCertificates -= 1
                        budget.record("certificatesTried")
                        if try certifyGroup(proposal) { best = proposal }
                        else { budget.record("certificateRejected") }
                    }
                }
            }
            if exhausted { budget.incompleteGroups += 1 }
            // A previously certified whole group remains valid if later search exhausts.
            if let best { budget.record("groupsCertified"); result.append(best) }
        }
        return result
    }

    /// Additional admission only, not a weaker Pareto objective. Quantization-only
    /// alignment (including common font growth) cannot buy source-origin drift.
    /// This is a source-rectangle MODEL, not original glyph/baseline ground truth.
    static func cohortAnchorOnlyRejection(_ placements: [CohortTextPlacement], baseline: [CohortTextPlacement],
        domains: [String: CohortTextDomain], observedRelations: [CohortTextRelation],
        before: [CGFloat?], after: [CGFloat?]) -> String? {
        let prior = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        if placements.allSatisfy({ domains[$0.id]?.proposedBodyClearance != nil }) {
            // Pair residuals alone cancel rigid drift. Preserve each member's
            // own source distance on BOTH axes; never buy X drift with Y gain.
            for p in placements {
                guard let b = prior[p.id], let d = domains[p.id], let source = d.proposedTypographyAnchor?.top,
                      let clearance = d.proposedBodyClearance, let oldY = b.firstBodyFillTop,
                      let newY = p.firstBodyFillTop, let oldX = b.horizontalAlignmentAnchor,
                      let newX = p.horizontalAlignmentAnchor else { return "bodySourceAnchorUnknownRejected" }
                let targetX = cohortSourceHorizontalAnchor(b, domain: d)
                guard abs(newY - source - clearance) <= abs(oldY - source - clearance) + 1e-7,
                      abs(newX - targetX) <= abs(oldX - targetX) + 1 / 64 else {
                    return "bodySourceAnchorDriftRejected"
                }
            }
            return nil // Exact body-source guard above, not a baseline waiver.
        }
        // Pair residuals cancel a common translation. Check that bypass before
        // hierarchy/pitch/significant-residual early returns. Origins detect the
        // rigid operation; measured paint anchors, not origins, measure its harm.
        // The fixed baseline ascent is a source-bbox MODEL, not source glyph GT.
        if placements.count > 1, placements.count == baseline.count,
           let first = placements.first, let firstPrior = prior[first.id] {
            let dx = first.origin.x - firstPrior.origin.x
            let dy = first.origin.y - firstPrior.origin.y
            let rigid = (abs(dx) > 1e-7 || abs(dy) > 1e-7) && placements.allSatisfy { p in
                guard let b = prior[p.id] else { return false }
                return abs(p.origin.x - b.origin.x - dx) <= 1e-7
                    && abs(p.origin.y - b.origin.y - dy) <= 1e-7
            }
            if rigid {
                var allFarther = true
                for p in placements {
                    guard let b = prior[p.id], let d = domains[p.id],
                          b.baselineObserved, p.baselineObserved,
                          let oldX = b.horizontalAlignmentAnchor, let newX = p.horizontalAlignmentAnchor else {
                        return "rigidSourceAnchorUnknownRejected"
                    }
                    let targetX = cohortSourceHorizontalAnchor(b, domain: d)
                    let targetY = d.typographyFrame.minY + b.sourceTopPadding + b.firstBaseline - b.origin.y
                    let oldDistance = hypot(oldX - targetX, b.firstBaseline - targetY)
                    let newDistance = hypot(newX - targetX, p.firstBaseline - targetY)
                    guard oldDistance.isFinite, newDistance.isFinite else { return "rigidSourceAnchorUnknownRejected" }
                    allFarther = allFarther && newDistance > oldDistance + 1 / 64
                }
                if allFarther { return "rigidSourceAnchorDriftRejected" }
            }
        }
        guard placements.allSatisfy({ p in
            guard let b = prior[p.id] else { return false }
            return p.cuts == b.cuts && p.singletons == b.singletons && p.completenessDebt == b.completenessDebt
        }) else { return nil }
        if let b = before[3], let a = after[3], a < b - 1e-7 { return nil }
        if placements.allSatisfy({ domains[$0.id]?.sourcePitchProxy != nil }),
           let b = before[6], let a = after[6], a < b - 1e-7 { return nil }
        let candidates = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        var yTolerance: CGFloat = 0, xTolerance: CGFloat = 0, weight: CGFloat = 0
        for edge in observedRelations {
            guard let a = prior[edge.firstID], let b = prior[edge.secondID],
                  let nextA = candidates[edge.firstID], let nextB = candidates[edge.secondID] else {
                return "anchorOnlyUnknownRejected"
            }
            let reciprocalFonts = 1 / min(a.style.fontSize, nextA.style.fontSize)
                + 1 / min(b.style.fontSize, nextB.style.fontSize)
            // ceil(ascent/descent), floor(pitch/half-leading): conservative 2pt
            // per-member unsnapped allowance; LayoutUnit adds <1/64pt. Device
            // painted snapping is deliberately left to the caller's two-anchor proof.
            yTolerance += edge.confidence * (2 + 1 / 64) * reciprocalFonts
            guard let domainA = domains[a.id], let domainB = domains[b.id] else { return "anchorOnlyUnknownRejected" }
            xTolerance += edge.confidence * (1 / 64) * (1 / domainA.spatialUnit + 1 / domainB.spatialUnit)
            weight += edge.confidence
        }
        guard weight > 0 else { return "anchorOnlyUnknownRejected" }
        let significantY = before[4].flatMap { b in after[4].map { b - $0 > yTolerance / weight + 1e-7 } } ?? false
        let significantX = before[5].flatMap { b in after[5].map { b - $0 > xTolerance / weight + 1e-7 } } ?? false
        if significantX || significantY { return nil }
        var nearer = false
        for p in placements {
            guard let b = prior[p.id], let d = domains[p.id], b.baselineObserved, p.baselineObserved,
                  let oldX = b.horizontalAlignmentAnchor, let newX = p.horizontalAlignmentAnchor else {
                return "anchorOnlyUnknownRejected"
            }
            let targetX = cohortSourceHorizontalAnchor(b, domain: d)
            let targetY = d.typographyFrame.minY + b.sourceTopPadding + b.firstBaseline - b.origin.y
            let old = hypot(oldX - targetX, b.firstBaseline - targetY) / d.spatialUnit
            let new = hypot(newX - targetX, p.firstBaseline - targetY) / d.spatialUnit
            guard old.isFinite, new.isFinite, new <= old + 1e-7 else { return "anchorOnlySourceDriftRejected" }
            nearer = nearer || new < old - 1e-7
        }
        return nearer ? nil : "anchorOnlyQuantizationRejected"
    }

    static func cohortPlacement(index: Int, card: Card, domain: CohortTextDomain,
        frame: CGRect, origin: CGPoint, style: NativeTranslationTypography.Style,
        layout unownedLayout: NativeTranslationTypography.Layout, baseline isBaseline: Bool = false,
        onRejection: ((String) -> Void)? = nil) -> CohortTextPlacement? {
        let text = card.item.typesettingText ?? card.item.text
        var layout = unownedLayout
        // Some keep-all adapters return the final frame without transporting
        // their insertion ledger. Reuse the production EXACT proof on a value
        // copy: no shaping, whitespace normalization or painter changes here.
        if layout.sourceUTF16Ownership == nil, !layout.shapedText.utf16.elementsEqual(text.utf16),
           let ownership = NativeTranslationTypography.insertedLFOwnership(source: text, displayed: layout.shapedText) {
            layout.sourceUTF16Ownership = ownership
        }
        let measuredRows = NativeTranslationTypography.horizontalRowMetrics(layout: layout, originalText: text, origin: origin)
        let rows = measuredRows ?? []
        // Verify all non-whitespace scalars survive actual final rows, not just fits.
        let shaped = layout.shapedText as NSString
        var joined = ""
        for range in layout.lineRanges {
            guard range.location >= 0, range.length >= 0, range.location <= shaped.length,
                  range.length <= shaped.length - range.location else { return nil }
            joined += shaped.substring(with: range)
        }
        func scalars(_ value: String) -> [Unicode.Scalar] { value.unicodeScalars.filter { !$0.properties.isWhitespace } }
        // Completeness is an exact source/display ownership proof, not the
        // paragraph advance-capacity flag. Outlined ink may occupy independently
        // allocated padding; the actual ink/range frame and domain gates below
        // still reject every overflow. Never alter Layout.fits to admit it.
        let full = NativeTranslationTypography.committedParagraphRawComplete(layout, original: text)
            && cohortOwnershipIsComplete(layout, originalText: text)
            && scalars(joined) == scalars(text) && !text.isEmpty && !layout.lineRanges.isEmpty
        let knownWords = !rows.isEmpty && rows.count == layout.lineRanges.count
            && rows.allSatisfy { $0["tokenCutAfterRowProxy"] is Bool && $0["singleHangulLetterRow"] is Bool }
        let observedBaseline = rows.first?["unsnappedBaseline"] as? [Double]
        let observed = observedBaseline?.count == 2 && observedBaseline!.allSatisfy(\.isFinite)
        let horizontalAnchor = NativeTranslationTypography.committedRowAlignmentAnchors(layout: layout,
            alignment: style.horizontalAlignment, origin: origin)?.first
        // Fallback is a MODEL search anchor only; residual objectives remain nil.
        let anchor = observed ? observedBaseline! : [Double(origin.x), Double(origin.y + style.fontSize)]
        guard isBaseline || (full && knownWords && observed && horizontalAnchor != nil) else {
            onRejection?(!full ? "incompleteText" : !knownWords ? "unknownRows" : "unknownAnchor")
            return nil
        }
        let ink = layout.inkBounds.offsetBy(dx: origin.x, dy: origin.y)
        let range = layout.rangeBounds.reduce(CGRect.null) { $0.union($1) }.offsetBy(dx: origin.x, dy: origin.y)
        let gap = cohortRowGap(layout, outline: style.outlineWidth)
        guard isBaseline || (gap.proven && (gap.value == nil || gap.value! >= 0.25)) else {
            onRejection?(gap.proven ? "rowOverlap" : "unknownRowClearance"); return nil
        }
        guard isBaseline || (cohortValidRect(ink) && frame.contains(ink) && cohortValidRect(range) && frame.contains(range)) else {
            onRejection?("inkOutsideCapacity"); return nil
        }
        return .init(cardIndex: index, id: card.item.id, frame: frame, origin: origin, style: style, layout: layout,
            rows: rows, cuts: knownWords ? rows.filter { ($0["tokenCutAfterRowProxy"] as? Bool) == true }.count : nil,
            singletons: knownWords ? rows.filter { ($0["singleHangulLetterRow"] as? Bool) == true }.count : nil,
            completenessDebt: full ? 0 : 1, baselineObserved: observed,
            rowGap: gap.value, rowGapProven: gap.proven,
            firstBaseline: CGFloat(anchor[1]), firstBaselineX: CGFloat(anchor[0]),
            horizontalAlignmentAnchor: horizontalAnchor,
            sourceTopPadding: card.item.paddingTop, sourceStartPadding: card.item.paddingLeft,
            sourceEndPadding: card.item.paddingRight,
            pitchReferenceRatio: domain.sourcePitchProxy.map { $0 / domain.spatialUnit }
                ?? (card.style.lineHeight / card.style.fontSize),
            fontProxyProvenance: domain.fontProxyProvenance,
            sourceStyleEvidence: domain.sourceStyleEvidence,
            preservedStyleModelProvenance: "frozen current style model; not original-source paint truth",
            firstBodyFillTop: domain.observedTypographyAnchor == nil ? nil
                : cohortFirstBodyTop(layout, original: text, origin: origin, style: style))
    }

    static func cohortSourceHorizontalAnchor(_ placement: CohortTextPlacement, domain: CohortTextDomain) -> CGFloat {
        switch placement.style.horizontalAlignment {
        case .left: return domain.sourceFrame.minX + placement.sourceStartPadding
        case .center: return domain.sourceFrame.midX
        case .right: return domain.sourceFrame.maxX - placement.sourceEndPadding
        }
    }

    private static func cohortObservedRelations(_ relations: [CohortTextRelation], baseline: [CohortTextPlacement]) -> [CohortTextRelation] {
        let observed = Set(baseline.filter(\.baselineObserved).map(\.id))
        return relations.filter { observed.contains($0.firstID) && observed.contains($0.secondID) }
    }

    static func cohortObjective(_ placements: [CohortTextPlacement], domains: [String: CohortTextDomain],
        relations: [CohortTextRelation], observedRelations: [CohortTextRelation],
        hierarchyWeights: [String: CGFloat]? = nil, explicitHierarchy: Bool = false) -> [CGFloat?] {
        let members = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        func pairError(_ edges: [CohortTextRelation], requiresObserved: Bool,
                       value: (CohortTextPlacement) -> CGFloat?) -> CGFloat? {
            guard !edges.isEmpty else { return nil }
            var error: CGFloat = 0, weight: CGFloat = 0
            for edge in edges {
                guard let a = members[edge.firstID], let b = members[edge.secondID],
                      !requiresObserved || (a.baselineObserved && b.baselineObserved) else { return nil }
                guard let x = value(a), let y = value(b), x.isFinite, y.isFinite else { return nil }
                error += edge.confidence * abs(x - y); weight += edge.confidence
            }
            return weight > 0 ? error / weight : nil
        }
        let hierarchy = pairError(relations, requiresObserved: false) {
            let unit = explicitHierarchy ? hierarchyWeights?[$0.id] : domains[$0.id]?.sourceFontProxy
            guard let unit, unit.isFinite, unit > 0 else { return nil }
            return log($0.style.fontSize / unit)
        }
        // Only the frozen baseline-observed edges participate. Unknown edges are
        // recorded in the proposal, not dynamically skipped or assigned zero.
        let bodyMode = placements.allSatisfy { domains[$0.id]?.proposedBodyClearance != nil }
        let frozenUnit = placements.map { domains[$0.id]!.spatialUnit }.reduce(0, +) / CGFloat(max(1, placements.count))
        let baselineError = pairError(observedRelations, requiresObserved: true) {
            let d = domains[$0.id]!
            if bodyMode {
                guard let body = $0.firstBodyFillTop, let source = d.proposedTypographyAnchor?.top,
                      let clearance = d.proposedBodyClearance else { return nil }
                return (body - source - clearance) / frozenUnit
            }
            return ($0.firstBaseline - d.typographyFrame.minY - $0.sourceTopPadding) / $0.style.fontSize
        }
        let startError = pairError(observedRelations, requiresObserved: true) {
            guard let anchor = $0.horizontalAlignmentAnchor else { return nil }
            let domain = domains[$0.id]!
            return (anchor - cohortSourceHorizontalAnchor($0, domain: domain)) / domain.spatialUnit
        }
        // Preserving a broken incumbent pitch is not original-source fidelity.
        // Keep source-pitch error unknown for the entire frozen group when any
        // source pitch is unavailable; don't manufacture a zero or skip members.
        let pitchError: CGFloat? = placements.allSatisfy({ domains[$0.id]?.sourcePitchProxy != nil })
            ? placements.reduce(CGFloat(0)) { total, p in
            total + abs(log((p.style.lineHeight / p.style.fontSize) / p.pitchReferenceRatio))
        } : nil
        return [CGFloat(placements.reduce(0) { $0 + $1.completenessDebt }),
            placements.allSatisfy { $0.cuts != nil } ? CGFloat(placements.reduce(0) { $0 + $1.cuts! }) : nil,
            placements.allSatisfy { $0.singletons != nil } ? CGFloat(placements.reduce(0) { $0 + $1.singletons! }) : nil,
            hierarchy, baselineError, startError, pitchError,
            1 / (placements.map { $0.style.fontSize }.min() ?? 1)]
    }

    static func cohortDominates(_ a: [CGFloat?], _ b: [CGFloat?], knownMask: [Bool]) -> Bool {
        guard a.count == b.count, a.count == knownMask.count, !a.isEmpty,
              knownMask == b.map({ $0 != nil }), a[0] == 0 else { return false }
        var qualityImproved = false
        // Inverse minimum font remains recorded and a ranking tie-break, not a
        // Pareto veto against source-faithful bounded joint normalization.
        for index in knownMask.indices.filter({ knownMask[$0] && $0 < a.count - 1 }) {
            guard let x = a[index], let y = b[index], x.isFinite, y.isFinite, x <= y + 1e-7 else { return false }
            // Last axis is readability floor/tie-break only, never sole admission.
            if x < y - 1e-7 { qualityImproved = true }
        }
        return qualityImproved
    }

    private static func cohortLexicographic(_ a: [CGFloat?], _ b: [CGFloat?], knownMask: [Bool]) -> Bool {
        guard a.count == b.count, a.count == knownMask.count else { return false }
        for index in knownMask.indices.filter({ knownMask[$0] }) {
            guard let x = a[index], let y = b[index], x.isFinite, y.isFinite else { return false }
            if abs(x - y) > 1e-7 { return x < y }
        }
        return false
    }

    /// Same native caption/run geometry used by the existing readability guard.
    /// No baseline-to-baseline pitch substitution for actual outline ink clearance.
    static func cohortRowGap(_ layout: NativeTranslationTypography.Layout, outline: CGFloat)
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
        return (zip(ink, ink.dropFirst()).map { $1.minY - $0.maxY }.min(), !ink.isEmpty && ink.count == layout.lineCount)
    }

    /// Generated soft LF owns a zero-length original boundary. Require a full
    /// ordered ownership union, INCLUDING input whitespace, not just visible ink.
    private static func cohortOwnershipIsComplete(_ layout: NativeTranslationTypography.Layout, originalText: String) -> Bool {
        NativeTranslationTypography.sourceOwnershipCoverage(layout, originalText: originalText)?.whole == true
    }

    private static func cohortValidRect(_ r: CGRect) -> Bool {
        !r.isNull && !r.isInfinite && r.minX.isFinite && r.minY.isFinite
            && r.width.isFinite && r.height.isFinite && r.width > 0 && r.height > 0
    }

    private static func cohortOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let hit = a.intersection(b)
        return !hit.isNull && hit.width > 0 && hit.height > 0
    }

    private static func cohortPaintedGlyphOverlap(_ a: CohortTextPlacement, _ b: CohortTextPlacement,
        remainingWork: inout Int) -> Bool? {
        let left = a.layout.glyphBounds.map { $0.offsetBy(dx: a.origin.x, dy: a.origin.y) }
        let right = b.layout.glyphBounds.map { $0.offsetBy(dx: b.origin.x, dy: b.origin.y) }
        guard !left.isEmpty, !right.isEmpty, left.allSatisfy(cohortValidRect),
              right.allSatisfy(cohortValidRect) else { return nil }
        let lb = left.reduce(CGRect.null) { $0.union($1) }
        let rb = right.reduce(CGRect.null) { $0.union($1) }
        guard cohortOverlap(lb, rb) else { return false }
        let cost = left.count.multipliedReportingOverflow(by: right.count)
        guard !cost.overflow, cost.partialValue <= remainingWork else { return nil }
        remainingWork -= cost.partialValue
        return left.contains { glyph in right.contains { cohortOverlap(glyph, $0) } }
    }
}

extension NativeTranslationRenderer {
    static func sourceTopIdentityEligible(_ item: NativeTranslationLayoutItem) -> Bool {
        item.balloonInterior == nil && item.balloonUnit == nil
    }

    /// Target-typography margin measured with the current font, width, pitch and
    /// wrapping. The probe is never installed as the committed layout. Source
    /// bounding top is a geometry proxy, not original body-ink or font-em truth.
    static func sourceTopNaturalClearance(card: Card, sourceFrame: CGRect) -> CGFloat? {
        let text = card.item.typesettingText ?? card.item.text
        guard !card.style.vertical, !card.style.preservesBlockRows else { return nil }
        var style = card.style
        style.alignsToTop = true
        var probe = NativeTranslationTypography.layout(text: text, in: card.item.contentRect.size, style: style)
        if probe.sourceUTF16Ownership == nil, !probe.shapedText.utf16.elementsEqual(text.utf16),
           let ownership = NativeTranslationTypography.insertedLFOwnership(source: text, displayed: probe.shapedText) {
            probe.sourceUTF16Ownership = ownership
        }
        guard probe.shapedText.utf16.elementsEqual(card.typography.shapedText.utf16),
              probe.lineRanges == card.typography.lineRanges,
              NativeTranslationTypography.sourceOwnershipCoverage(probe, originalText: text)?.whole == true,
              let top = cohortFirstBodyTop(probe, original: text,
                origin: CGPoint(x: sourceFrame.minX + card.item.paddingLeft,
                    y: sourceFrame.minY + card.item.paddingTop), style: style) else { return nil }
        let clearance = top - sourceFrame.minY
        return clearance.isFinite && clearance >= 0 ? clearance : nil
    }

    static func sourceTopSharedClearance(sourceTops: [CGFloat], bodyTops: [CGFloat],
        naturalClearances: [CGFloat], band: CGFloat) -> CGFloat? {
        guard sourceTops.count > 1, sourceTops.count <= 32, sourceTops.count == bodyTops.count,
              naturalClearances.count == sourceTops.count,
              band.isFinite, band >= 0, sourceTops.allSatisfy(\.isFinite), bodyTops.allSatisfy(\.isFinite),
              naturalClearances.allSatisfy({ $0.isFinite && $0 >= 0 }),
              sourceTops.max()! - sourceTops.min()! <= band else { return nil }
        let offsets = zip(bodyTops, sourceTops).map { $0 - $1 }
        let natural = naturalClearances.sorted()[naturalClearances.count / 2]
        let clearance = min(natural, max(0, offsets.min()!))
        return offsets.allSatisfy({ clearance <= abs($0) + 1e-7 }) ? clearance : nil
    }
}
