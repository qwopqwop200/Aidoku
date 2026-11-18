// Atomic cohort layout uses a separate text domain and immutable erasure backing.
import Foundation
import CoreGraphics
import UIKit

extension NativeTranslationRenderer {
    static func cohortBackingIsUpright(sourceRotation: CGFloat, textRotation: CGFloat,
        hasStraightenedBacking: Bool) -> Bool {
        sourceRotation.isFinite && textRotation.isFinite && textRotation == 0
            && (sourceRotation == 0 || hasStraightenedBacking)
    }

    /// One shared full-world raster and bounded evidence stripes, never a mask bank.
    /// The export policy can produce pages larger than the old 32 MiB admission.
    static let cohortTextMaximumScratchBytes = 48 * 1024 * 1024

    /// The painter narrows each glyph origin X to Float, then adds the
    /// producer's CGFloat alignment width. Bound those two conversions rather
    /// than permitting an arbitrary logical-pixel displacement.
    static func cohortAlignmentRoundingBound(baseline: CohortTextPlacement,
        candidate: CohortTextPlacement) -> CGFloat? {
        guard let oldPoint = baseline.rows.first?["paintedBaseline"] as? [Double],
              let newPoint = candidate.rows.first?["paintedBaseline"] as? [Double],
              oldPoint.count == 2, newPoint.count == 2,
              oldPoint.allSatisfy(\.isFinite), newPoint.allSatisfy(\.isFinite),
              let oldAnchor = baseline.horizontalAlignmentAnchor,
              let newAnchor = candidate.horizontalAlignmentAnchor else { return nil }
        let oldX = Float(oldPoint[0]), newX = Float(newPoint[0])
        guard oldX.isFinite, newX.isFinite, oldAnchor.isFinite, newAnchor.isFinite else { return nil }
        let narrowing = (CGFloat(oldX.ulp) + CGFloat(newX.ulp)) / 2
        let addition = 4 * max(abs(oldAnchor), abs(newAnchor), 1).ulp
        return narrowing + addition
    }

    static func paragraphWidthRaggedness(_ layout: NativeTranslationTypography.Layout, font: CGFloat) -> CGFloat? {
        guard font.isFinite, font > 0 else { return nil }
        // Existing production accessor reads CTLine advances, not owner or glyph bboxes.
        let widths = NativeTranslationTypography.lineAdvances(layout: layout)
        let count = widths.count
        guard count > 0, count == layout.lineCount,
              widths.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        guard count > 1 else { return nil }
        let target = widths.max()!
        // Native advance variance, normalized by fixed glyph size, NOT an expanding frame denominator.
        return widths.dropLast().reduce(0) { $0 + pow(($1 - target) / font, 2) } / CGFloat(count - 1)
    }

    static func cohortTextScratchRequirement(pixels: CGSize) -> Int? {
        guard pixels.width.isFinite, pixels.height.isFinite,
              pixels.width >= 1, pixels.height >= 1, pixels.width <= 32768, pixels.height <= 32768,
              pixels.width.rounded() == pixels.width, pixels.height.rounded() == pixels.height else { return nil }
        let width = Int(pixels.width), height = Int(pixels.height)
        return 4 * width * height + 20 * width * (min(64, height) + 4)
    }

    struct CohortCommitScalePlan {
        let observedRatiosUsed: Bool
        let profile: CohortScaleProfile?
        let anchorID: String
        let anchorFont: CGFloat
        let weights: [String: CGFloat]
        let floors: [String: CGFloat]
        let typographyDomains: [String: CohortTextDomain]
    }

    enum CohortCommitScaleError: String, Error {
        case memberIdentityInvalid, baselineFontInvalid, domainInvalid
        case observationOptInMissing, profileMissing, profileMismatch, profileActivationMismatch
        case baselineFontStateMismatch, typographyAnchorMismatch, unknownProfileShrink
        case fontFloorInvalid, proposedRatioMismatch
    }

    /// Same profile/anchor authority as the solver. Revalidate against actual
    /// current Card records before both search certification and atomic commit.
    /// Success here is ONLY a font-planning contract, never coverage permission.
    static func cohortCommitScalePlan(_ proposal: CohortTextProposal, baseline: [Card],
        domains: [String: CohortTextDomain], useObservedFamilyRatios: Bool = false
    ) -> Swift.Result<CohortCommitScalePlan, CohortCommitScaleError> {
        let placements = proposal.placements
        guard !placements.isEmpty, placements.count <= 4_096,
              Set(placements.map(\.id)).count == placements.count,
              Set(placements.map(\.cardIndex)).count == placements.count,
              placements.allSatisfy({ baseline.indices.contains($0.cardIndex)
                && baseline[$0.cardIndex].item.id == $0.id }) else { return .failure(.memberIdentityInvalid) }
        guard placements.allSatisfy({
            let c = baseline[$0.cardIndex]
            return c.finalFontSize.isFinite && c.finalFontSize > 0 && c.style.fontSize.isFinite && c.style.fontSize > 0
        }) else { return .failure(.baselineFontInvalid) }
        guard placements.allSatisfy({
            guard let d = domains[$0.id] else { return false }
            return d.spatialUnit.isFinite && d.spatialUnit > 0 && d.minimumFontSize.isFinite
                && d.minimumFontSize >= BrowserOverlayLayoutPlanner.minimumRenderedFontSize
        }) else { return .failure(.domainInvalid) }
        if proposal.observedRatiosUsed && !useObservedFamilyRatios { return .failure(.observationOptInMissing) }
        let members = placements.map { p -> CohortScaleMember in
            let c = baseline[p.cardIndex]
            return .init(id: p.id, forecast: domains[p.id]!.spatialUnit, translatedFont: c.style.fontSize,
                sourceVertical: c.item.sourceVertical, record: c.harmonyRecord["observedSourceLetteringScale"] as? [String: Any])
        }
        let fresh = cohortScaleProfile(members)
        if useObservedFamilyRatios && placements.count > 1 {
            guard let declared = proposal.scaleProfile, let fresh else { return .failure(.profileMissing) }
            guard declared.anchorID == fresh.anchorID, declared.anchorTranslatedFont == fresh.anchorTranslatedFont,
                  declared.family == fresh.family, declared.unknownReason == fresh.unknownReason,
                  declared.weights == fresh.weights, Set(declared.observations.keys) == Set(fresh.observations.keys),
                  members.allSatisfy({ member in
                      guard let a = declared.observations[member.id], let b = fresh.observations[member.id] else { return false }
                      return a.family == b.family && a.sourceVertical == b.sourceVertical
                          && a.logicalCrossSpan == b.logicalCrossSpan && a.unknownReason == b.unknownReason
                  }) else { return .failure(.profileMismatch) }
            guard proposal.observedRatiosUsed == fresh.observedComparable else { return .failure(.profileActivationMismatch) }
        }
        var planningDomains = domains
        let weights: [String: CGFloat], anchorID: String, anchorFont: CGFloat
        if proposal.observedRatiosUsed {
            guard let fresh, fresh.observedComparable else { return .failure(.profileMismatch) }
            guard placements.allSatisfy({ baseline[$0.cardIndex].finalFontSize == baseline[$0.cardIndex].style.fontSize }) else {
                return .failure(.baselineFontStateMismatch)
            }
            weights = fresh.weights; anchorID = fresh.anchorID; anchorFont = fresh.anchorTranslatedFont
            let proposedAnchors = placements.compactMap { p -> CGFloat? in
                let value = p.style.fontSize / weights[p.id]!
                return value.isFinite && value > 0 ? value : nil
            }
            guard proposedAnchors.count == placements.count,
                  proposedAnchors.allSatisfy({ abs($0 - proposedAnchors[0]) <= 1e-7 }) else {
                return .failure(.proposedRatioMismatch)
            }
            let observedAnchors = placements.compactMap { p -> (String, CohortTypographyAnchor)? in
                guard let a = cohortObservedTypographyAnchor(card: baseline[p.cardIndex], sourceFrame: domains[p.id]!.sourceFrame),
                      a.family == fresh.family else { return nil }
                return (p.id, a)
            }
            let allAnchors = observedAnchors.count == placements.count
                ? Dictionary(uniqueKeysWithValues: observedAnchors) : [:]
            guard Set(proposal.proposedTypographyAnchors.keys) == Set(allAnchors.keys),
                  allAnchors.allSatisfy({ id, value in
                      guard let proposed = proposal.proposedTypographyAnchors[id] else { return false }
                      return value.top == proposed.top && value.family == proposed.family && value.authority == proposed.authority
                  }) else { return .failure(.typographyAnchorMismatch) }
            for (id, a) in allAnchors { planningDomains[id]!.proposedTypographyAnchor = a }
            let prior = placements.compactMap { p -> CohortTextPlacement? in
                let c = baseline[p.cardIndex]
                return cohortPlacement(index: p.cardIndex, card: c, domain: planningDomains[p.id]!,
                    frame: c.item.rect, origin: c.textOrigin, style: c.style, layout: c.typography, baseline: true)
            }
            let bodyClearance = prior.count == placements.count ? cohortBodyClearance(prior, domains: planningDomains) : nil
            guard bodyClearance == proposal.proposedBodyClearance else { return .failure(.typographyAnchorMismatch) }
            if let bodyClearance {
                for p in placements { planningDomains[p.id]!.proposedBodyClearance = bodyClearance }
            }
        } else {
            guard proposal.proposedTypographyAnchors.isEmpty, proposal.proposedBodyClearance == nil else {
                return .failure(.typographyAnchorMismatch)
            }
            // Preserve the former commit upper-median forecast floor exactly in
            // algebra, without using a body span as an em-like scalar.
            let ordered = placements.sorted {
                let a = baseline[$0.cardIndex].finalFontSize / domains[$0.id]!.spatialUnit
                let b = baseline[$1.cardIndex].finalFontSize / domains[$1.id]!.spatialUnit
                return a == b ? $0.id < $1.id : a < b
            }
            let anchor = ordered[ordered.count / 2]
            anchorID = anchor.id; anchorFont = baseline[anchor.cardIndex].finalFontSize
            let unit = domains[anchor.id]!.spatialUnit
            weights = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, domains[$0.id]!.spatialUnit / unit) })
        }
        var floors: [String: CGFloat] = [:]
        for p in placements {
            let base = baseline[p.cardIndex].finalFontSize
            guard let weight = weights[p.id], weight.isFinite, weight > 0,
                  let floor = cohortSourceRelativeFloor(baselineFont: base, sourceProxy: weight, referenceScale: anchorFont),
                  floor.isFinite else { return .failure(.fontFloorInvalid) }
            floors[p.id] = max(domains[p.id]!.minimumFontSize, floor)
        }
        return .success(.init(observedRatiosUsed: proposal.observedRatiosUsed, profile: fresh,
            anchorID: anchorID, anchorFont: anchorFont, weights: weights, floors: floors, typographyDomains: planningDomains))
    }

    /// Solver and commit must evaluate observed hierarchy/top in the SAME
    /// frozen family domain. Unknown axes stay unknown, not successful zeros.
    static func cohortCommitObservedObjectiveRejection(_ proposal: CohortTextProposal, baseline: [Card],
        plan: CohortCommitScalePlan) -> String? {
        guard plan.observedRatiosUsed else { return nil }
        var prior: [CohortTextPlacement] = [], remainingUTF16 = 131_072
        for p in proposal.placements {
            let c = baseline[p.cardIndex], text = c.item.typesettingText ?? c.item.text
            let cost = text.utf16.count + c.typography.shapedText.utf16.count
            guard cost <= remainingUTF16 else { return "profileObjectiveWorkUnknown" }
            remainingUTF16 -= cost
            guard let d = plan.typographyDomains[p.id],
                  let b = cohortPlacement(index: p.cardIndex, card: c, domain: d, frame: c.item.rect,
                    origin: c.textOrigin, style: c.style, layout: c.typography, baseline: true) else {
                return "profileObjectiveBaselineUnknown"
            }
            prior.append(b)
        }
        let observedIDs = Set(prior.filter(\.baselineObserved).map(\.id))
        let observedEdges = proposal.relations.filter { observedIDs.contains($0.firstID) && observedIDs.contains($0.secondID) }
        let before = cohortObjective(prior, domains: plan.typographyDomains, relations: proposal.relations,
            observedRelations: observedEdges, hierarchyWeights: plan.weights, explicitHierarchy: true)
        let after = cohortObjective(proposal.placements, domains: plan.typographyDomains, relations: proposal.relations,
            observedRelations: observedEdges, hierarchyWeights: plan.weights, explicitHierarchy: true)
        func matches(_ a: [CGFloat?], _ b: [CGFloat?]) -> Bool {
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { x, y in
                switch (x, y) {
                case (nil, nil): return true
                case let (x?, y?): return x.isFinite && y.isFinite && abs(x - y) <= 1e-7
                default: return false
                }
            }
        }
        guard proposal.baselineKnownMask == before.map({ $0 != nil }) else { return "profileObjectiveKnownMaskMismatch" }
        guard matches(before, proposal.baselineObjective) else { return "profileObjectiveBaselineMismatch" }
        guard matches(after, proposal.candidateObjective) else { return "profileObjectiveCandidateMismatch" }
        guard cohortDominates(after, before, knownMask: proposal.baselineKnownMask) else { return "profileObjectiveParetoRejected" }
        return nil
    }

    enum CohortScaleRecordPhase: String { case proposed, committed }

    static func cohortCommitScaleRecord(_ plan: CohortCommitScalePlan, id: String, font: CGFloat,
        phase: CohortScaleRecordPhase) -> [String: Any] {
        ["phase": phase.rawValue, "authority": "translated-font group calibration; not source font GT",
         "observedRatiosUsed": plan.observedRatiosUsed, "observedComparable": plan.profile?.observedComparable ?? false,
         "method": plan.profile?.family as Any? ?? NSNull(),
         "observedMethod": plan.profile?.observations[id]?.family as Any? ?? NSNull(),
         "planningFamily": plan.observedRatiosUsed ? (plan.profile?.family ?? "unknown") : "legacy-forecast",
         "fallbackReason": plan.observedRatiosUsed ? NSNull() :
            (plan.profile?.unknownReason as Any? ?? "observed-family-planning-withheld"),
         "anchorID": plan.anchorID, "anchorTranslatedFont": Double(plan.anchorFont),
         "dimensionlessWeight": plan.weights[id].map(Double.init) as Any? ?? NSNull(),
         "observedLogicalCrossSpan": plan.profile?.observations[id]?.logicalCrossSpan.map(Double.init) as Any? ?? NSNull(),
         "minimumFont": plan.floors[id].map(Double.init) as Any? ?? NSNull(), "translatedFont": Double(font),
         "bodyTopClearance": plan.typographyDomains[id]?.proposedBodyClearance.map(Double.init) as Any? ?? NSNull(),
         "alignmentAuthority": plan.typographyDomains[id]?.proposedBodyClearance == nil
            ? "legacy font-normalized baseline proxy" : "native first-row body fill paths; not raster glyph GT",
         "typographyAnchor": plan.typographyDomains[id]?.proposedTypographyAnchor.map { Double($0.top) } as Any? ?? NSNull()]
    }

    /// Contours or immutable opaque rectangular backing. verifiedOriginalStyle MUST refer to observed source
    /// fill/stroke/relative-width/face evidence matching the current Card style.
    /// Unknown source style can enter explicitly labeled geometry trials, but is
    /// returned separately and never becomes an original-style quality approval.
    /// No contour, model color, or preservation flag manufactures style authority.
    static func commitContourCohortsTiled(cards: inout [Card], items: [NativeTranslationLayoutItem],
        owners: [CGRect], surfaces: [String: NativeTextBoxContainment.Surface],
        bounds: CGRect, sourceRect: CGRect, pixels: CGSize, pdfDeviceScale: CGFloat,
        verifiedOriginalStyle: Set<String>, allowsStyleUnknownTrials: Bool = false,
        unknownSourceStyleIDs: inout Set<String>,
        allowsVerifiedBalloonInteriorModelTrials: Bool = false,
        conditionalGeometryIDs: inout Set<String>,
        useObservedFamilyRatios: Bool = false,
        shapingPaddingScale: CGFloat = 1,
        widthStageCheckpoint: (([Card], Set<String>, Set<String>, Set<String>, [String: Int]) -> Void)? = nil,
        widthFinalArtifactAdmission: (([Card], [Card], Set<String>) throws -> Bool?)? = nil,
        recordAudit: (([String: Int]) -> Void)? = nil) throws -> Set<String> {
        var audit: [String: Int] = ["inputCards": cards.count, "observedFamilyOptIn": useObservedFamilyRatios ? 1 : 0]
        defer { recordAudit?(audit) }
        guard items.count == owners.count, valid(bounds), valid(sourceRect),
              pixels.width.isFinite, pixels.height.isFinite,
              pixels.width >= 1, pixels.height >= 1, pixels.width <= 32768, pixels.height <= 32768,
              pixels.width.rounded() == pixels.width, pixels.height.rounded() == pixels.height,
              pdfDeviceScale.isFinite, pdfDeviceScale > 0,
              Set(items.map(\.id)).count == items.count,
              Set(cards.map { $0.item.id }).count == cards.count else { audit["invalidInputs"] = 1; return [] }
        let grid = TextDomainGrid(bounds: bounds, width: Int(pixels.width), height: Int(pixels.height),
            pdfDeviceScale: pdfDeviceScale)
        let product = grid.width.multipliedReportingOverflow(by: grid.height)
        guard !product.overflow else { audit["gridOverflow"] = 1; return [] }
        // One full-world 4P arena, bounded tile evidence, no full-output mask bank.
        guard let scratch = cohortTextScratchRequirement(pixels: pixels), scratch <= cohortTextMaximumScratchBytes else {
            audit["pixelBudgetExcludedPages"] = 1; return []
        }
        let frozen = cards
        let lookup = Dictionary(uniqueKeysWithValues: items.indices.map { (items[$0].id, $0) })
        var domains: [String: CohortTextDomain] = [:]
        var spaces: [String: TextPaintDomain] = [:]
        var opaqueBackingIDs: Set<String> = []
        func logicalPolygon(_ input: [CGPoint]) -> [CGPoint] {
            // Geometry-only representation. NEVER replace the painter polygon:
            // Quartz alpha changed in the previously measured 192->4 case.
            func redundant(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
                (b.x-a.x)*(c.y-b.y) == (b.y-a.y)*(c.x-b.x)
                    && (b.x-a.x)*(b.x-c.x)+(b.y-a.y)*(b.y-c.y) <= 0
            }
            var stack: [CGPoint] = []
            for p in input where stack.last != p {
                while stack.count >= 2 && redundant(stack[stack.count-2], stack[stack.count-1], p) { stack.removeLast() }
                stack.append(p)
            }
            if stack.count > 1 && stack.first == stack.last { stack.removeLast() }
            while stack.count > 3 {
                if redundant(stack[stack.count-2], stack[stack.count-1], stack[0]) { stack.removeLast() }
                else if redundant(stack[stack.count-1], stack[0], stack[1]) { stack.removeFirst() }
                else { break }
            }
            return stack
        }
        for card in frozen {
            let id = card.item.id
            guard verifiedOriginalStyle.contains(id) || allowsStyleUnknownTrials, let index = lookup[id],
                  valid(owners[index]), sourceRect.contains(owners[index]), bounds.contains(owners[index]) else {
                audit["noVerifiedContourDomain", default: 0] += 1; continue
            }
            let space: TextPaintDomain
            var usesOpaqueBacking = false
            var frames = [card.item.rect]
            if let surface = surfaces[id], surface.certifiedSpans {
                let supplied = NativeTextBoxContainment.known(
                    items[index].balloonInterior ?? items[index].balloonUnit?.interior, frame: sourceRect)
                let sameSupplied = supplied.map { surface.rect == $0.rect && surface.polygon == $0.polygon } ?? false
                guard sameSupplied || allowsVerifiedBalloonInteriorModelTrials && surface.geometryObserved,
                      let contourSpace = TextPaintDomain(rect: surface.rect, polygon: surface.polygon, within: bounds) else {
                    audit["noVerifiedContourDomain", default: 0] += 1; continue
                }
                space = contourSpace
                if !sameSupplied { audit["observedGeometryModelDomains", default: 0] += 1 }
                if let other = surface.inscribed(near: card.item.rect, within: surface.rect), other != card.item.rect {
                    frames.append(other)
                }
            } else {
                // Search support only: one existing painted rectangle per ID, never
                // an enclosing group rectangle or evidence of a balloon/source style.
                // The unchanged solver associates geometric hypotheses, not speakers
                // or merged content. Singleton fallback domains get no solo trials.
                // Actual opaque coverage remains a whole-group raster obligation.
                let backing = card.straightenedPanelRect ?? card.sourcePlateRect
                guard card.sourceBackgroundKind == "solid-text-box", card.drawsPanel,
                      card.background.alpha == 1, !card.usesFallbackVeil,
                      !card.item.keptLettering, cohortBackingIsUpright(sourceRotation: card.item.rotation,
                        textRotation: card.effectiveTextRotation, hasStraightenedBacking: card.straightenedPanelRect != nil),
                      sourceRect.contains(backing), backing.contains(owners[index]),
                      let backingSpace = TextPaintDomain(rect: backing, polygon: [], within: bounds) else {
                    audit["noVerifiedContourDomain", default: 0] += 1; continue
                }
                space = backingSpace; usesOpaqueBacking = true
                // Every fallback shaping frame stays in this ID's backing,
                // even when the current text frame extends beyond its plate.
                frames = [backing]
                let retainedFrame = card.item.rect.intersection(backing)
                if valid(retainedFrame), retainedFrame != backing { frames.insert(retainedFrame, at: 0) }
            }
            let protected = items.indices.filter { $0 != index }.map { owners[$0] }.filter(valid)
            guard let domain = cohortTextDomain(card: card, certifiedTextSpace: space, frames: frames,
                protectedRects: protected, minimumFontSize: max(BrowserOverlayLayoutPlanner.minimumRenderedFontSize, card.finalFontSize * 0.8),
                sourceStyleEvidence: usesOpaqueBacking
                    ? "unknown original style; unobserved rectangular text domain within frozen opaque backing"
                    : verifiedOriginalStyle.contains(id)
                        ? "observed original style matched before cohort search"
                        : "unknown original style; frozen current paint model only") else {
                audit["invalidDomainAdapter", default: 0] += 1; continue
            }
            domains[id] = domain; spaces[id] = space
            if usesOpaqueBacking {
                opaqueBackingIDs.insert(id)
                audit["opaqueBackingRectangularDomains", default: 0] += 1
            }
        }
        audit["candidateDomains"] = domains.count
        guard !domains.isEmpty else { audit["insufficientDomainsPages"] = 1; return [] }
        // Internal SOURCE owners are not deleted; the group certificate proves
        // opaque coverage and restores barriers for every outside-group owner.
        let eligible = Set(domains.keys)
        for id in eligible {
            guard let card = frozen.first(where: { $0.item.id == id }), let space = spaces[id], let prior = domains[id] else { continue }
            let barriers = items.indices.filter { items[$0].keptLettering || !eligible.contains(items[$0].id) }
                .map { owners[$0] }.filter(valid)
            guard let rebuilt = cohortTextDomain(card: card, certifiedTextSpace: space, frames: prior.frames,
                protectedRects: barriers, minimumFontSize: prior.minimumFontSize,
                sourceStyleEvidence: prior.sourceStyleEvidence) else { domains[id] = nil; continue }
            domains[id] = CohortTextDomain(sourceFrame: rebuilt.sourceFrame,
                sourceFontProxy: rebuilt.sourceFontProxy, fontProxyProvenance: rebuilt.fontProxyProvenance,
                minimumFontSize: rebuilt.minimumFontSize, sourcePitchProxy: rebuilt.sourcePitchProxy,
                polygons: rebuilt.polygons.map(logicalPolygon), frames: rebuilt.frames,
                protectedRects: rebuilt.protectedRects, sourceStyleEvidence: rebuilt.sourceStyleEvidence,
                observedTypographyAnchor: rebuilt.observedTypographyAnchor)
        }
        // Finite, PAGE-SCALED allowances: two complete member sweeps per phase.
        // Search cannot consume the separately reserved commit phase.
        let tileCount = (grid.height + 63) / 64
        let sampled = grid.width * (grid.height + 4 * tileCount)
        let memberPasses = 2 * frozen.count
        let certificateAllowance = 12 * sampled * memberPasses
        let evidenceAllowance = 2 * sampled * (2 * frozen.count + items.count + 12) * memberPasses
        let callAllowance = 2 * tileCount * (2 * frozen.count + 3) * memberPasses
        var searchWork = certificateAllowance, commitWork = certificateAllowance
        var searchEvidence = evidenceAllowance, commitEvidence = evidenceAllowance
        var searchCalls = callAllowance, commitCalls = callAllowance
        var shaping = CohortTextBudget()
        shaping.groupCertificates = 2
        func candidate(_ proposal: CohortTextProposal, from baseline: [Card], phase: String = "paragraph",
            useObservedScale: Bool = false) -> [Card]? {
            audit["candidateGroupCalls", default: 0] += 1
            audit[phase + ".candidateGroupCalls", default: 0] += 1
            guard !proposal.placements.isEmpty,
                  Set(proposal.placements.map(\.cardIndex)).count == proposal.placements.count else { return nil }
            let plan: CohortCommitScalePlan
            switch cohortCommitScalePlan(proposal, baseline: baseline, domains: domains,
                useObservedFamilyRatios: useObservedScale) {
            case .success(let accepted): plan = accepted
            case .failure(let reason):
                audit[phase + ".scalePlan." + reason.rawValue, default: 0] += 1; return nil
            }
            if let reason = cohortCommitObservedObjectiveRejection(proposal, baseline: baseline, plan: plan) {
                audit[phase + "." + reason, default: 0] += 1; return nil
            }
            audit[phase + (plan.observedRatiosUsed ? ".comparableProfileContract" : ".legacyProfileContract"), default: 0] += 1
            let shrinks = proposal.placements.contains { $0.style.fontSize < baseline[$0.cardIndex].finalFontSize - 1e-7 }
            var fidelityAxes = [3, 4, 5]
            if proposal.placements.allSatisfy({ domains[$0.id]?.sourcePitchProxy != nil }) { fidelityAxes.append(6) }
            let fidelityImproves = fidelityAxes.contains { axis in
                guard proposal.baselineObjective.indices.contains(axis), proposal.candidateObjective.indices.contains(axis),
                      let b = proposal.baselineObjective[axis], let q = proposal.candidateObjective[axis],
                      b.isFinite, q.isFinite else { return false }
                return q < b - 1e-7
            }
            guard !shrinks || fidelityImproves else {
                audit["shrinkWithoutKnownFidelityImprovement", default: 0] += 1; return nil
            }
            var result = baseline
            for p in proposal.placements {
                guard baseline.indices.contains(p.cardIndex), baseline[p.cardIndex].item.id == p.id,
                      verifiedOriginalStyle.contains(p.id) || allowsStyleUnknownTrials, let space = spaces[p.id],
                      p.completenessDebt == 0, p.baselineObserved, p.rowGapProven,
                      baseline[p.cardIndex].item.typesettingText == nil ||
                        baseline[p.cardIndex].item.typesettingText == baseline[p.cardIndex].item.text,
                      NativeTranslationTypography.committedParagraphRawComplete(p.layout,
                        original: baseline[p.cardIndex].item.typesettingText ?? baseline[p.cardIndex].item.text),
                      NativeTranslationTypography.sourceOwnershipCoverage(p.layout,
                        originalText: baseline[p.cardIndex].item.typesettingText ?? baseline[p.cardIndex].item.text)?.whole == true,
                      domains[p.id] != nil, p.style.fontSize.isFinite else {
                    audit["candidateContractRejected", default: 0] += 1; return nil
                }
                guard let floor = plan.floors[p.id], p.style.fontSize >= floor else {
                    audit[phase + ".profileFontFloorRejected", default: 0] += 1
                    audit[phase + ".profileFontFloorRejected.id." + p.id, default: 0] += 1; return nil
                }
                var next = baseline[p.cardIndex]
                // CRITICAL: nil previously meant item.rect. Pin before moving text.
                next.sourcePlateOwnerRect = next.sourcePlateRect
                next.item.x = p.frame.minX; next.item.y = p.frame.minY
                next.item.width = p.frame.width; next.item.height = p.frame.height
                guard p.shapingPaddingScale.isFinite, (0.5...2).contains(p.shapingPaddingScale) else { return nil }
                next.item.paddingTop *= p.shapingPaddingScale; next.item.paddingBottom *= p.shapingPaddingScale
                next.item.paddingLeft *= p.shapingPaddingScale; next.item.paddingRight *= p.shapingPaddingScale
                next.harmonyRecord["cohortShapingPaddingScale"] = Double(p.shapingPaddingScale)
                next.typography = p.layout; next.style = p.style; next.finalFontSize = p.style.fontSize
                next.textShift = CGPoint(x: p.origin.x - next.item.contentRect.minX,
                    y: p.origin.y - next.item.contentRect.minY)
                next.textPaintDomain = space
                if proposal.scaleProfile != nil {
                    next.harmonyRecord["cohortSourceScalePlanning"] = cohortCommitScaleRecord(plan,
                        id: p.id, font: p.style.fontSize, phase: .proposed)
                }
                // All other item/source/owner/palette/backing/clip fields are copied.
                result[p.cardIndex] = next
            }
            return result
        }
        func approve(_ proposal: CohortTextProposal, baseline: [Card], proposed: [Card],
            certificateWork: inout Int, evidenceWork: inout Int, painterCalls: inout Int,
            observedWidthOnly: Bool = false) throws -> Bool {
            let ids = Set(proposal.placements.map(\.id))
            let barriers = items.indices.filter { items[$0].keptLettering || !ids.contains(items[$0].id) }
                .map { owners[$0] }.filter(valid)
            let groupOwners = items.indices.filter { ids.contains(items[$0].id) }.map { owners[$0] }
            guard groupOwners.allSatisfy({ valid($0) && sourceRect.contains($0) && bounds.contains($0) }) else { return false }
            for placement in proposal.placements {
                let index = placement.cardIndex
                let usesOpaqueBacking = opaqueBackingIDs.contains(placement.id)
                let drawCalls = frozen.count + proposed.count - 1 + 1
                let cost = 2 * sampled * (drawCalls + 10 + barriers.count + groupOwners.count)
                let calls = 2 * tileCount * (drawCalls + 3)
                guard cost <= evidenceWork, calls <= painterCalls else {
                    audit["evidenceOrPainterBudgetRejected", default: 0] += 1; return false
                }
                evidenceWork -= cost; painterCalls -= calls
                var rawCopy = proposed[index]
                guard let rawSpace = TextPaintDomain(rect: bounds, polygon: [], within: bounds) else { return false }
                rawCopy.textPaintDomain = rawSpace
                var ownerCoverage = true
                audit["wholeWorldCertificateCalls", default: 0] += 1
                let certificate = try certifyTextDomainTiled(grid: grid, remainingWork: &certificateWork,
                    maximumScratchBytes: cohortTextMaximumScratchBytes,
                    requiresPointwiseAlphaSafety: observedWidthOnly, evidence: { anchor, tile in
                        let snap: CGFloat? = anchor == .bitmap ? nil : pdfDeviceScale
                        let fill = try tile.alpha { c in
                            withWorkerGraphicsContext(c) {
                                c.clip(to: sourceRect)
                                for card in frozen where card.sourceBackgroundKind == "solid-text-box"
                                    && card.drawsPanel && card.background.alpha == 1 && !card.usesFallbackVeil {
                                    draw(card, context: c, opacity: 1, paintsBackground: true,
                                        paintsText: false, paintsSourcePanels: false, pixelSnapScale: snap)
                                }
                            }
                        }
                        let peer = try tile.alpha { c in
                            withWorkerGraphicsContext(c) {
                                c.clip(to: sourceRect)
                                for j in proposed.indices where j != index {
                                    draw(proposed[j], context: c, opacity: 1, paintsBackground: false,
                                        paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
                                }
                            }
                        }
                        let own = try tile.alpha { c in
                            withWorkerGraphicsContext(c) {
                                c.clip(to: sourceRect)
                                draw(baseline[index], context: c, opacity: 1, paintsBackground: false,
                                    paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
                            }
                        }
                        let model = try tile.alpha { c in
                            // The backing rectangle supplies no modeled empty-interior
                            // authority; only actual frozen opaque paint may certify it.
                            guard !usesOpaqueBacking else { return }
                            c.clip(to: sourceRect); c.addLines(between: spaces[placement.id]!.polygon); c.closePath()
                            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fillPath()
                        }
                        var protected = [UInt8](repeating: 0, count: tile.pixels)
                        for rect in barriers { tile.cells(rect) { protected[$0] = 255 } }
                        for rect in groupOwners { tile.cells(rect) { if fill[$0] != 255 { ownerCoverage = false } } }
                        // Immutable constant shared by rows; no borrowed arena bytes.
                        let peerKnownRow = [UInt8](repeating: 255, count: grid.width)
                        return (0..<tile.rowCount).map { row in
                            let range = (row + tile.halo) * grid.width..<(row + tile.halo + 1) * grid.width
                            let observed = Array(fill[range]), modeled = Array(model[range])
                            // ONLY verified balloon interior may supply this conditional
                            // conservative empty-interior cue. Open-background unknown
                            // never becomes known. This is MODEL, not observed/GT artwork.
                            let known = exactTextDomainKnownRow(observed, modeled,
                                permitsModel: allowsVerifiedBalloonInteriorModelTrials && !observedWidthOnly && !usesOpaqueBacking)
                            return TextDomainEvidenceRow(observedSafeAlpha: observed, modelSafeAlpha: modeled,
                                supportKnown: known, protectionAlpha: Array(protected[range]), protectionKnown: known,
                                peerUnionAlpha: Array(peer[range]), peerKnown: peerKnownRow,
                                ownBaselineAlpha: Array(own[range]))
                        }
                    }, paintRaw: { c, snap in
                        withWorkerGraphicsContext(c) {
                            // Raw ink outside SOURCE is not hidden by a source clip.
                            draw(rawCopy, context: c, opacity: 1, paintsBackground: false,
                                paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
                        }
                    }, paintCandidate: { c, snap in
                        withWorkerGraphicsContext(c) {
                            c.clip(to: sourceRect)
                            draw(proposed[index], context: c, opacity: 1, paintsBackground: false,
                                paintsText: true, paintsSourcePanels: false, pixelSnapScale: snap)
                        }
                    })
                let accepted = certificate.verdict == .observedPass ||
                    (allowsVerifiedBalloonInteriorModelTrials && !observedWidthOnly && !usesOpaqueBacking
                        && certificate.verdict == .modelConditional)
                audit["certificate." + certificate.reason, default: 0] += 1
                if let measured = certificate.measuredDeviceSamples {
                    audit["measuredDeviceSamples", default: 0] += measured
                }
                if let expected = certificate.expectedDeviceSamples {
                    audit["expectedDeviceSamples", default: 0] += expected
                }
                if certificate.measurementComplete == true { audit["fullyMeasuredCertificates", default: 0] += 1 }
                if certificate.measurementComplete == false { audit["partialRejectionCertificates", default: 0] += 1 }
                if certificate.measurementComplete == nil { audit["certificateCoverageUnreported", default: 0] += 1 }
                let ownerStatus = !ownerCoverage ? "deficit-witnessed"
                    : certificate.measurementComplete == true ? "verified" : "unknown"
                audit["sourceOwnerCoverage." + ownerStatus, default: 0] += 1
                if let measured = certificate.measuredDeviceSamples, let expected = certificate.expectedDeviceSamples {
                    audit["unmeasuredDeviceSamples", default: 0] += max(0, expected - measured)
                }
                if !ownerCoverage { audit["sourceOwnerOpaqueCoverageRejected", default: 0] += 1 }
                guard ownerCoverage, accepted else { return false }
            }
            return true
        }
        var changed: Set<String> = []
        for observedPass in (useObservedFamilyRatios ? [false, true] : [false]) {
            let passBaseline = cards
            var passBudget = observedPass ? CohortTextBudget() : shaping
            if observedPass { passBudget.groupCertificates = 2 }
            let phase = observedPass ? "observed" : "legacy"
            let proposals = try improveCohortTextBoxes(cards: passBaseline, domains: domains, budget: &passBudget,
                allowSourceRelativeShrink: true, useObservedFamilyRatios: observedPass,
                shapingPaddingScale: shapingPaddingScale) { proposal in
                guard let proposed = candidate(proposal, from: passBaseline, phase: "search",
                    useObservedScale: observedPass) else { return false }
                let approved = try approve(proposal, baseline: passBaseline, proposed: proposed,
                    certificateWork: &searchWork, evidenceWork: &searchEvidence, painterCalls: &searchCalls)
                audit[approved ? "search.pixelCertificatePassed" : "search.pixelCertificateRejected", default: 0] += 1
                return approved
            }
            if !observedPass { shaping = passBudget }
            audit["shapedCandidates", default: 0] += passBudget.shapedCandidates
            audit["unknownRowMeasurements", default: 0] += passBudget.unknownRowMeasurements
            audit["incompleteGroups", default: 0] += passBudget.incompleteGroups
            for (reason, count) in passBudget.reasonCounts {
                audit["solver." + reason, default: 0] += count
                if useObservedFamilyRatios { audit["solver." + phase + "." + reason] = count }
            }
            audit["certifiedSearchProposals", default: 0] += proposals.count
            for proposal in proposals {
            // Recertify against already committed earlier groups, not stale B peers.
            guard var proposed = candidate(proposal, from: cards, phase: "commit",
                useObservedScale: observedPass) else { continue }
            guard try approve(proposal, baseline: cards, proposed: proposed,
                certificateWork: &commitWork, evidenceWork: &commitEvidence, painterCalls: &commitCalls) else {
                audit["commit.pixelCertificateRejected", default: 0] += 1; continue
            }
            audit["commit.pixelCertificatePassed", default: 0] += 1
            for p in proposal.placements {
                // Only after real recertification against CURRENT peers.
                var record = proposed[p.cardIndex].harmonyRecord["cohortSourceScalePlanning"] as? [String: Any] ?? [:]
                record["phase"] = CohortScaleRecordPhase.committed.rawValue
                proposed[p.cardIndex].harmonyRecord["cohortSourceScalePlanning"] = record
            }
            cards = proposed // Single full-group assignment; rejection mutates nothing.
            changed.formUnion(proposal.placements.map(\.id))
            // Rectangular fallback has observed backing authority, never a
            // conditional balloon-interior model or original-source style approval.
            conditionalGeometryIDs.formUnion(proposal.placements.map(\.id).filter { !opaqueBackingIDs.contains($0) })
            unknownSourceStyleIDs.formUnion(proposal.placements.map(\.id).filter {
                opaqueBackingIDs.contains($0) || !verifiedOriginalStyle.contains($0)
            })
            }
        }
        // Typography groups are not a prerequisite for fixing a paragraph's
        // wrapping. Solo trials never change font, pitch, tracking or paint.
        // Both actual alignment anchor and first baseline remain frozen.
        var paragraphCertificates = 2 * frozen.count
        for index in cards.indices where !changed.contains(cards[index].item.id) {
            let card = cards[index], id = card.item.id
            guard !opaqueBackingIDs.contains(id), let domain = domains[id], !card.item.sourceTextOnly, !card.item.vertical,
                  card.item.rotation == 0, card.effectiveTextRotation == 0,
                  card.unitTextParts.isEmpty, !card.style.preservesBlockRows,
                  card.heavyStrokeWidth == 0, card.style.outlineGlow == 0,
                  let baseline = cohortPlacement(index: index, card: card, domain: domain,
                    frame: card.item.rect, origin: card.textOrigin, style: card.style,
                    layout: card.typography, baseline: true),
                  baseline.completenessDebt == 0, baseline.rowGapProven,
                  let anchor = baseline.horizontalAlignmentAnchor,
                  let cuts = baseline.cuts, let singletons = baseline.singletons,
                  cuts > 0 || singletons > 0 else { continue }
            audit["singleParagraphFlowEligible", default: 0] += 1
            let text = card.item.typesettingText ?? card.item.text
            let frontier = NativeTranslationTypography.committedParagraphCandidates(text: text,
                in: card.item.contentRect.size, style: card.style, reference: baseline.layout,
                utf16Work: &shaping.utf16Work, geometryWork: &shaping.geometryWork)
            guard frontier.complete else {
                audit["singleParagraphFrontierUnknown", default: 0] += 1; continue
            }
            let before = cohortObjective([baseline], domains: domains, relations: [], observedRelations: [])
            for layout in frontier.layouts {
                guard let initial = cohortPlacement(index: index, card: card, domain: domain,
                    frame: card.item.rect, origin: card.textOrigin, style: card.style, layout: layout),
                      let candidateAnchor = initial.horizontalAlignmentAnchor else {
                    audit["singleParagraphInitialPlacementRejected", default: 0] += 1; continue
                }
                let dx = anchor - candidateAnchor, dy = baseline.firstBaseline - initial.firstBaseline
                let origin = CGPoint(x: card.textOrigin.x + dx, y: card.textOrigin.y + dy)
                guard let placement = cohortPlacement(index: index, card: card, domain: domain,
                    frame: card.item.rect.offsetBy(dx: dx, dy: dy), origin: origin,
                    style: card.style, layout: layout),
                      let retainedAnchor = placement.horizontalAlignmentAnchor else {
                    audit["singleParagraphShiftedPlacementRejected", default: 0] += 1; continue
                }
                guard let rounding = cohortAlignmentRoundingBound(baseline: baseline, candidate: placement),
                      abs(retainedAnchor - anchor) <= rounding,
                      abs(placement.firstBaseline - baseline.firstBaseline) <= 1e-7 else {
                    audit["singleParagraphAnchorPrecisionRejected", default: 0] += 1; continue
                }
                let after = cohortObjective([placement], domains: domains, relations: [], observedRelations: [])
                guard cohortDominates(after, before, knownMask: before.map { $0 != nil }) else { continue }
                guard paragraphCertificates > 0 else {
                    audit["singleParagraphCertificateBudgetSkipped", default: 0] += 1; break
                }
                paragraphCertificates -= 1
                let proposal = CohortTextProposal(placements: [placement], relations: [],
                    baselineObjective: before, candidateObjective: after,
                    baselineKnownMask: before.map { $0 != nil }, unknownBaselineRelationCount: 0, fontChanges: [])
                guard let proposed = candidate(proposal, from: cards),
                      try approve(proposal, baseline: cards, proposed: proposed,
                        certificateWork: &commitWork, evidenceWork: &commitEvidence, painterCalls: &commitCalls) else {
                    audit["singleParagraphCertificateRejected", default: 0] += 1; continue
                }
                cards = proposed
                changed.insert(id); conditionalGeometryIDs.insert(id)
                if !verifiedOriginalStyle.contains(id) { unknownSourceStyleIDs.insert(id) }
                audit["committedSingleParagraphCards", default: 0] += 1
                break
            }
        }
        widthStageCheckpoint?(cards, changed, unknownSourceStyleIDs, conditionalGeometryIDs, audit)
        // Width frontier stays separate from the unchanged fixed-width/joint stages.
        // Fresh finite stage allowances; same font/style/pitch and per-ID anchors.
        // The complete current readability guard AND width-neutral variance must pass.
        var widthShaping = CohortTextBudget()
        var widthWork = 4 * certificateAllowance, widthEvidence = 4 * evidenceAllowance, widthCalls = 4 * callAllowance
        var widthCertificates = 8 * frozen.count
        for index in cards.indices {
            try Task.checkCancellation()
            let card = cards[index], id = card.item.id
            guard !opaqueBackingIDs.contains(id), let domain = domains[id], let surface = surfaces[id],
                  !card.item.sourceTextOnly, !card.item.vertical,
                  card.item.rotation == 0, card.effectiveTextRotation == 0,
                  card.unitTextParts.isEmpty, !card.style.preservesBlockRows,
                  card.heavyStrokeWidth == 0, card.style.outlineGlow == 0,
                  let baseline = cohortPlacement(index: index, card: card, domain: domain,
                    frame: card.item.rect, origin: card.textOrigin, style: card.style,
                    layout: card.typography, baseline: true),
                  baseline.completenessDebt == 0, baseline.rowGapProven,
                  let anchor = baseline.horizontalAlignmentAnchor,
                  let cuts = baseline.cuts, let singletons = baseline.singletons,
                  cuts > 0 || singletons > 0 else { continue }
            audit["paragraphWidthFlowEligible", default: 0] += 1
            let text = card.item.typesettingText ?? card.item.text
            // Reserve native provenance/run validation work before measuring.
            let baselineUnits = text.utf16.count.addingReportingOverflow(card.typography.shapedText.utf16.count)
            let baselineUTF = baselineUnits.partialValue.multipliedReportingOverflow(by: 2)
            guard !baselineUnits.overflow, !baselineUTF.overflow,
                  baselineUTF.partialValue <= widthShaping.utf16Work,
                  card.typography.lineCount >= 0, card.typography.lineCount <= widthShaping.geometryWork else {
                audit["paragraphWidthAttachmentBudgetUnknown", default: 0] += 1; continue
            }
            widthShaping.utf16Work -= baselineUTF.partialValue
            widthShaping.geometryWork -= card.typography.lineCount
            guard let baselineReadability = NativeParagraphReadabilityGuard.observed(
                layout: card.typography, original: text, width: card.item.contentRect.width, style: card.style) else {
                audit["paragraphWidthAttachmentBaselineUnknown", default: 0] += 1; continue
            }
            guard card.typography.lineCount <= widthShaping.geometryWork else {
                audit["paragraphWidthVarianceBudgetUnknown", default: 0] += 1; continue
            }
            widthShaping.geometryWork -= card.typography.lineCount
            guard let priorRaggedness = paragraphWidthRaggedness(card.typography, font: card.style.fontSize) else {
                audit["paragraphWidthRaggednessUnknown", default: 0] += 1; continue
            }
            // Wider frames must not leak into the joint solver or fixed-width frontier.
            var widthFrames = [card.item.rect]
            if let other = surface.inscribed(near: card.item.rect, within: surface.rect), other != card.item.rect {
                widthFrames.append(other)
            }
            for factor: CGFloat in [1.0625, 1.125, 1.1875, 1.25, 1.5, 2] {
                let width = min(surface.rect.width, card.item.width * factor)
                let wanted = CGRect(x: card.item.rect.midX - width / 2, y: card.item.rect.minY,
                    width: width, height: card.item.height)
                if width > card.item.width, let expanded = surface.inscribed(near: wanted, within: surface.rect),
                   expanded.width > card.item.width + 1e-7, !widthFrames.contains(expanded) { widthFrames.append(expanded) }
            }
            var trials: [(CGRect, CGPoint, NativeTranslationTypography.Layout, NativeTranslationTypography.Style)] = []
            for frame in widthFrames where frame.width > card.item.width + 1e-7 {
                do {
                    let work = text.utf16.count
                    guard trials.count < 21, work <= widthShaping.utf16Work, widthShaping.geometryWork > 0 else {
                        audit["paragraphWidthExpansionBudgetUnknown", default: 0] += 1; break
                    }
                    widthShaping.utf16Work -= work; widthShaping.geometryWork -= 1
                    var item = card.item
                    item.x = frame.minX; item.y = frame.minY; item.width = frame.width; item.height = frame.height
                    let trialStyle = card.style
                    let layout = NativeTranslationTypography.layout(text: text, in: item.contentRect.size, style: trialStyle)
                    audit["paragraphWidthNaturalWidthTrials", default: 0] += 1
                    trials.append((frame, item.contentRect.origin, layout, trialStyle))
                }
            }
            let before = cohortObjective([baseline], domains: domains, relations: [], observedRelations: [])
            for (frame, trialOrigin, layout, trialStyle) in trials {
                let candidateUnits = text.utf16.count.addingReportingOverflow(layout.shapedText.utf16.count)
                let candidateUTF = candidateUnits.partialValue.multipliedReportingOverflow(by: 2)
                guard !candidateUnits.overflow, !candidateUTF.overflow,
                      candidateUTF.partialValue <= widthShaping.utf16Work,
                      layout.lineCount >= 0, layout.lineCount <= widthShaping.geometryWork else {
                    audit["paragraphWidthAttachmentBudgetUnknown", default: 0] += 1; break
                }
                widthShaping.utf16Work -= candidateUTF.partialValue
                widthShaping.geometryWork -= layout.lineCount
                var wrappedItem = card.item
                wrappedItem.width = frame.width; wrappedItem.height = frame.height
                guard let candidateReadability = NativeParagraphReadabilityGuard.observed(
                    layout: layout, original: text, width: wrappedItem.contentRect.width, style: trialStyle) else {
                    audit["paragraphWidthAttachmentCandidateUnknown", default: 0] += 1; continue
                }
                audit["paragraphWidthAttachmentKnownComparisons", default: 0] += 1
                guard let initial = cohortPlacement(index: index, card: card, domain: domain,
                    frame: frame, origin: trialOrigin, style: trialStyle, layout: layout),
                      let candidateAnchor = initial.horizontalAlignmentAnchor else {
                    audit["paragraphWidthInitialPlacementRejected", default: 0] += 1; continue
                }
                let dx = anchor - candidateAnchor, dy = baseline.firstBaseline - initial.firstBaseline
                let origin = CGPoint(x: trialOrigin.x + dx, y: trialOrigin.y + dy)
                guard let placement = cohortPlacement(index: index, card: card, domain: domain,
                    frame: frame.offsetBy(dx: dx, dy: dy), origin: origin,
                    style: trialStyle, layout: layout),
                      let retainedAnchor = placement.horizontalAlignmentAnchor else {
                    audit["paragraphWidthShiftedPlacementRejected", default: 0] += 1; continue
                }
                guard let rounding = cohortAlignmentRoundingBound(baseline: baseline, candidate: placement),
                      abs(retainedAnchor - anchor) <= rounding,
                      abs(placement.firstBaseline - baseline.firstBaseline) <= 1e-7 else {
                    audit["paragraphWidthAnchorPrecisionRejected", default: 0] += 1; continue
                }
                guard layout.lineCount <= widthShaping.geometryWork else {
                    audit["paragraphWidthVarianceBudgetUnknown", default: 0] += 1; break
                }
                widthShaping.geometryWork -= layout.lineCount
                let raggedness = paragraphWidthRaggedness(layout, font: card.style.fontSize)
                guard raggedness != nil || layout.lineCount == 1 else {
                    audit["paragraphWidthRaggednessUnknown", default: 0] += 1; continue
                }
                guard raggedness.map({ $0 <= priorRaggedness + 1e-7 }) ?? true else {
                    audit["paragraphWidthRaggednessRejected", default: 0] += 1; continue
                }
                var after = cohortObjective([placement], domains: domains, relations: [], observedRelations: [])
                var comparedBefore = before
                if let raggedness {
                    comparedBefore.insert(priorRaggedness, at: comparedBefore.count - 1)
                    after.insert(raggedness, at: after.count - 1)
                }
                guard cohortDominates(after, comparedBefore, knownMask: comparedBefore.map { $0 != nil }) else {
                    if trialStyle.lineHeight != card.style.lineHeight { audit["paragraphWidthPitchObjectiveRejected", default: 0] += 1 }
                    continue
                }
                audit["paragraphWidthWidthNeutralDominatingCandidates", default: 0] += 1
                let fullGuardPass = candidateReadability.noWorse(than: baselineReadability)
                guard fullGuardPass else {
                    audit["paragraphWidthFullGuardRejected", default: 0] += 1
                    audit["paragraphWidthFullGuardRejected.id." + id, default: 0] += 1
                    continue
                }
                audit["paragraphWidthFullGuardPassed", default: 0] += 1
                guard widthCertificates > 0 else {
                    audit["paragraphWidthCertificateBudgetSkipped", default: 0] += 1; break
                }
                widthCertificates -= 1
                let proposal = CohortTextProposal(placements: [placement], relations: [],
                    baselineObjective: comparedBefore, candidateObjective: after,
                    baselineKnownMask: comparedBefore.map { $0 != nil }, unknownBaselineRelationCount: 0, fontChanges: [])
                guard var proposed = candidate(proposal, from: cards),
                      try approve(proposal, baseline: cards, proposed: proposed,
                        certificateWork: &widthWork, evidenceWork: &widthEvidence, painterCalls: &widthCalls, observedWidthOnly: true) else {
                    audit["paragraphWidthCertificateRejected", default: 0] += 1
                    continue
                }
                guard let widthIndex = proposed.firstIndex(where: { $0.item.id == id }) else { continue }
                proposed[widthIndex].harmonyRecord["widthRequiresRetainedArtifact"] = true
                guard let measuredPDF = try widthFinalArtifactAdmission?(cards, proposed, Set([id])) else {
                    audit["paragraphWidthPDFSupportUnknown", default: 0] += 1
                    continue
                }
                guard measuredPDF else {
                    audit["paragraphWidthPDFSupportRejected", default: 0] += 1
                    continue
                }
                audit["paragraphWidthPDFSupportPassed", default: 0] += 1
                cards = proposed
                changed.insert(id); conditionalGeometryIDs.insert(id)
                if !verifiedOriginalStyle.contains(id) { unknownSourceStyleIDs.insert(id) }
                audit["committedParagraphWidthCards", default: 0] += 1
                break
            }
        }
        audit["remainingWidthUTF16Work"] = widthShaping.utf16Work
        audit["remainingWidthGeometryWork"] = widthShaping.geometryWork
        audit["remainingParagraphUTF16Work"] = shaping.utf16Work
        audit["remainingParagraphGeometryWork"] = shaping.geometryWork
        // Source-top placement recovery. Frozen source bounding tops are an explicit
        // geometry proxy, never source glyph-body or font-em truth. No reshaping.
        // Existing source-neighbour edges supply association only, not semantics.
        let topBaseline = cards
        let topEligible = topBaseline.indices.filter { index in
            let c = topBaseline[index], i = c.item
            return domains[i.id] != nil && i.sourceVertical && !i.sourceTextOnly && !i.vertical
                && sourceTopIdentityEligible(i)
                && cohortBackingIsUpright(sourceRotation: i.rotation, textRotation: c.effectiveTextRotation,
                    hasStraightenedBacking: c.straightenedPanelRect != nil)
                && c.unitTextParts.isEmpty && !c.style.preservesBlockRows
                && c.heavyStrokeWidth == 0 && c.style.outlineGlow == 0
        }
        var topNeighbours: [Int: [Int]] = [:]
        var topComparisons = 4096
        var topExhausted = false
        for (offset, a) in topEligible.enumerated() {
            for b in topEligible.dropFirst(offset + 1) {
                guard topComparisons > 0 else { topExhausted = true; break }
                topComparisons -= 1
                let da = domains[topBaseline[a].item.id]!, db = domains[topBaseline[b].item.id]!
                // A bounded common-start band, independent of source font estimates.
                // Targets retain EVERY member's own source top, including stagger.
                guard abs(da.sourceFrame.minY - db.sourceFrame.minY) <= bounds.height * 0.02,
                      let confidence = cohortSpatialRelationConfidence(da.sourceFrame, unitA: da.spatialUnit,
                        db.sourceFrame, unitB: db.spatialUnit), confidence >= 0.55 else { continue }
                topNeighbours[a, default: []].append(b); topNeighbours[b, default: []].append(a)
            }
        }
        var topSeen: Set<Int> = []
        var topCertificateWork = certificateAllowance, topEvidenceWork = evidenceAllowance, topCalls = callAllowance
        var topUTF16 = 131072
        if !topExhausted {
            for seed in topEligible where !topSeen.contains(seed) {
                var group = [seed], cursor = 0
                topSeen.insert(seed)
                while cursor < group.count {
                    for peer in topNeighbours[group[cursor], default: []] where topSeen.insert(peer).inserted {
                        group.append(peer)
                    }
                    cursor += 1
                }
                group.sort()
                guard group.count > 1, group.count <= 32 else { continue }
                let ids = group.map { topBaseline[$0].item.id }
                func rejected(_ reason: String) {
                    audit["sourceTop." + reason, default: 0] += 1
                }
                let sourceTops = group.map { domains[topBaseline[$0].item.id]!.sourceFrame.minY }
                guard sourceTops.max()! - sourceTops.min()! <= bounds.height * 0.02 else {
                    rejected("transitiveTopBand"); continue
                }
                var offsets: [CGFloat] = []
                var tops: [CGFloat] = [], naturalClearances: [CGFloat] = []
                var validGroup = true
                for index in group {
                    let c = topBaseline[index], text = c.item.typesettingText ?? c.item.text
                    guard text.utf16.count <= topUTF16 else { validGroup = false; rejected("utf16Budget"); break }
                    guard text.utf16.count <= topUTF16 / 2 else { validGroup = false; rejected("naturalUTF16Budget"); break }
                    topUTF16 -= text.utf16.count * 2
                    guard let top = cohortFirstBodyTop(c.typography, original: text, origin: c.textOrigin, style: c.style) else {
                        validGroup = false; rejected("bodyTopUnknown"); break
                    }
                    guard let natural = sourceTopNaturalClearance(card: c, sourceFrame: domains[c.item.id]!.sourceFrame) else {
                        validGroup = false; rejected("naturalBodyTopUnknown"); break
                    }
                    naturalClearances.append(natural)
                    tops.append(top); offsets.append(top - domains[c.item.id]!.sourceFrame.minY)
                }
                guard validGroup, offsets.count == group.count else { continue }
                // Natural top-layout body margin supplies clearance. Incumbent
                // clearance is only a no-farther cap, never the source anchor.
                guard let clearance = sourceTopSharedClearance(sourceTops: sourceTops, bodyTops: tops,
                    naturalClearances: naturalClearances, band: bounds.height * 0.02) else { rejected("sourceDistance"); continue }
                guard offsets.contains(where: { $0 - clearance > bounds.height / CGFloat(grid.height) }) else {
                    rejected("noMeasuredDrift"); continue
                }
                var placements: [CohortTextPlacement] = []
                var proposed = cards
                for (slot, index) in group.enumerated() {
                    let c = cards[index], d = domains[c.item.id]!
                    let target = d.sourceFrame.minY + clearance
                    let delta = target - tops[slot]
                    guard abs(target - d.sourceFrame.minY) <= abs(offsets[slot]) + 1e-7 else {
                        validGroup = false; rejected("sourceDistance"); break
                    }
                    let origin = CGPoint(x: c.textOrigin.x, y: c.textOrigin.y + delta)
                    var rejection: String?
                    guard let placement = cohortPlacement(index: index, card: c, domain: d, frame: c.item.rect,
                        origin: origin, style: c.style, layout: c.typography, onRejection: { rejection = $0 }) else {
                        validGroup = false; rejected("placement." + (rejection ?? "unknown")); break
                    }
                    placements.append(placement)
                    var next = c
                    next.textShift.y += delta
                    proposed[index] = next
                }
                guard validGroup, placements.count == group.count else { continue }
                let proposal = CohortTextProposal(placements: placements, relations: [], baselineObjective: [],
                    candidateObjective: [], baselineKnownMask: [], unknownBaselineRelationCount: 0, fontChanges: [])
                guard try approve(proposal, baseline: cards, proposed: proposed,
                    certificateWork: &topCertificateWork, evidenceWork: &topEvidenceWork,
                    painterCalls: &topCalls, observedWidthOnly: true) else {
                    rejected("pointwiseAlphaCertificate"); continue
                }
                for index in group {
                    proposed[index].harmonyRecord["widthRequiresRetainedArtifact"] = true
                }
                // Existing actual ordered transparent-PDF admission and retained
                // artifact finalization, including peer and whole-world validation.
                guard let measured = try widthFinalArtifactAdmission?(cards, proposed, Set(ids)) else {
                    rejected("serializedPDFUnmeasured"); continue
                }
                guard measured else { rejected("serializedPDFRejected"); continue }
                cards = proposed
                changed.formUnion(ids)
                audit["sourceTop.committedGroups", default: 0] += 1

            }
        }
        audit["sourceTop.allocatedCertificateWork"] = certificateAllowance
        audit["sourceTop.allocatedEvidenceWork"] = evidenceAllowance
        audit["sourceTop.allocatedPainterCalls"] = callAllowance
        audit["sourceTop.chargedCertificateWork"] = certificateAllowance - topCertificateWork
        audit["sourceTop.chargedEvidenceWork"] = evidenceAllowance - topEvidenceWork
        audit["sourceTop.chargedPainterCalls"] = callAllowance - topCalls
        audit["sourceTop.chargedUTF16"] = 131072 - topUTF16
        audit["originalStages.chargedCertificateWork"] = 6 * certificateAllowance - searchWork - commitWork - widthWork
        audit["originalStages.chargedEvidenceWork"] = 6 * evidenceAllowance - searchEvidence - commitEvidence - widthEvidence
        audit["originalStages.chargedPainterCalls"] = 6 * callAllowance - searchCalls - commitCalls - widthCalls
        audit["allStages.chargedCertificateWork"] = 6 * certificateAllowance - searchWork - commitWork - widthWork
            + certificateAllowance - topCertificateWork
        audit["allStages.chargedEvidenceWork"] = 6 * evidenceAllowance - searchEvidence - commitEvidence - widthEvidence
            + evidenceAllowance - topEvidenceWork
        audit["allStages.chargedPainterCalls"] = 6 * callAllowance - searchCalls - commitCalls - widthCalls + callAllowance - topCalls

        audit["committedCards"] = changed.count
        return changed
    }
}

extension NativeTranslationRenderer {
    static func exactTextDomainKnownRow(_ observed: [UInt8], _ model: [UInt8], permitsModel: Bool) -> [UInt8] {
        precondition(observed.count == model.count)
        var output = [UInt8](repeating: 0, count: observed.count)
        observed.withUnsafeBufferPointer { o in
            model.withUnsafeBufferPointer { m in
                output.withUnsafeMutableBufferPointer { target in
                    var x = 0
                    let full = SIMD16<UInt8>(repeating: 255)
                    while x + 16 <= observed.count {
                        let a = UnsafeRawPointer(o.baseAddress!.advanced(by: x)).loadUnaligned(as: SIMD16<UInt8>.self)
                        var block = SIMD16<UInt8>.zero
                        block.replace(with: full, where: a .== full)
                        if permitsModel {
                            let b = UnsafeRawPointer(m.baseAddress!.advanced(by: x)).loadUnaligned(as: SIMD16<UInt8>.self)
                            block.replace(with: full, where: b .== full)
                        }
                        withUnsafeBytes(of: block) { bytes in
                            UnsafeMutableRawPointer(target.baseAddress!.advanced(by: x))
                                .copyMemory(from: bytes.baseAddress!, byteCount: 16)
                        }
                        x += 16
                    }
                    while x < observed.count {
                        target[x] = o[x] == 255 || (permitsModel && m[x] == 255) ? 255 : 0
                        x += 1
                    }
                }
            }
        }
        return output
    }
}
