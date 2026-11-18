import Foundation

/// Actual individual geometry output construction, independent of recognition.
/// Keeps every supplied corrected output; optionally emits one immutable original
/// and one observed layout prior per source observation. Explicit v3 may also retain
/// source-derived axis/fragment/normal refinements. No grids, text, confidence or GT.
enum NativeOCRIndividualGeometryHypotheses {
    static let environmentKey = "AIDOKU_OCR_INDIVIDUAL_GEOMETRY_HYPOTHESES"
    static let producerEmissionEnvironmentKey = "AIDOKU_OCR_REFINEMENT_PROPOSAL_EMISSION"

    enum Mode: String, Codable, Sendable {
        case correctedOnly = "corrected-only"
        case sourceOriginalAndCorrectedV1 = "source-original-and-corrected-v1"
        case sourceOriginalLayoutAndCorrectedV2 = "source-original-layout-and-corrected-v2"
        case sourceOriginalLayoutRefinedAndCorrectedV3 = "source-original-layout-refined-and-corrected-v3"
    }

    static func mode(environment: [String: String] = ProcessInfo.processInfo.environment) -> Mode {
        Mode(rawValue: environment[environmentKey] ?? "") ?? .correctedOnly
    }

    struct Point: Codable, Equatable, Hashable, Sendable {
        let x: Double
        let y: Double
    }

    enum Origin: String, Codable, Sendable {
        case sourceOriginal, sourceLayout, sourceRefinement, corrected
    }

    /// A full geometry-output record, not a polygon borrowed from a decode/sampling crop.
    /// Parent/member mapping must be recorded by the producer; never guess it by overlap.
    struct Record: Codable, Equatable, Sendable {
        let requestID: String
        let sourceIndex: Int
        let sourceParent: Int
        let sourceMembers: Set<Int>
        let alternativeID: String
        let origin: Origin
        let originalDetectorIndex: Int?
        let polygon: [Point]
    }

    enum RefinementHead: String, Codable, Hashable, Sendable {
        case axis, fragment, normal, closedContour
    }

    /// One runtime producer result, with immutable parent/member proof in record.
    /// Axis/fragment/normal producers must retain their source/seed evidence separately.
    /// Computed geometry MUST NOT be mislabeled as an observed sourceLayout prior.
    struct Refinement: Codable, Equatable, Sendable {
        let head: RefinementHead
        let record: Record
    }

    /// Controls proposal materialization only. Callers must still compute and retain
    /// immutable refinements for 376 context, fragment paint groups and ID reservation.
    /// No environment lookup or default suppression: both emit calls opt in explicitly.
    struct ProducerEmissionPlan: Equatable, Sendable {
        enum Family: String, CaseIterable, Hashable, Sendable {
            case axis, dehalo, componentSpan
        }

        let contextOnly: Set<Family>

        init(contextOnly: Set<Family> = []) {
            self.contextOnly = contextOnly
        }

        static let sourceContextOnlyV1 = Self(contextOnly: [.axis, .dehalo, .componentSpan])

        func emits(_ refinement: Refinement) -> Bool {
            // Match the declared producer AND head; fragment and strict contour
            // outputs, unknown producers and all original/layout rows stay active.
            let producer = refinement.record.alternativeID.split(separator: "/").first
            let family: Family?
            switch (refinement.head, producer) {
            case (.axis, "owned-axis"): family = .axis
            case (.normal, "source-stroke-dehalo-v1"): family = .dehalo
            case (.closedContour, "source-closed-component-span-v1"): family = .componentSpan
            default: family = nil
            }
            return family.map { !contextOnly.contains($0) } ?? true
        }
    }

    /// Default-off runtime opt-in. Load once per operation and pass the SAME plan
    /// to baseline and final emit; never filter the actual refinement context array.
    /// Absent/unknown values fail open to the legacy producer inventory.
    static func producerEmissionPlan(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProducerEmissionPlan {
        environment[producerEmissionEnvironmentKey] == "source-context-only-v1" ? .sourceContextOnlyV1 : .init()
    }

    /// Source-layout measurements remain available to independent heads and
    /// canonical paint queries. Only the final proposal union may omit them.
    static func finalLayoutProposals(_ records: [Record],
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [Record] {
        environment["AIDOKU_OCR_LAYOUT_PROPOSAL_EMISSION"] == "context-only-v1" ? [] : records
    }

    struct Individual: Codable, Equatable, Sendable {
        let polygon: [Point]
        /// Exact source records sharing this output quad; not suppression/alias inventions.
        /// Their original point order and source/alternative identities remain immutable.
        let provenance: [Record]
        let refinements: [Refinement]
        let bboxConfidence: Double?

        init(polygon: [Point], provenance: [Record], refinements: [Refinement] = [], bboxConfidence: Double? = nil) {
            self.polygon = polygon
            self.provenance = provenance
            self.refinements = refinements
            self.bboxConfidence = bboxConfidence
        }

        private enum CodingKeys: String, CodingKey { case polygon, provenance, refinements, bboxConfidence }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            polygon = try c.decode([Point].self, forKey: .polygon)
            provenance = try c.decode([Record].self, forKey: .provenance)
            refinements = try c.decodeIfPresent([Refinement].self, forKey: .refinements) ?? []
            bboxConfidence = try c.decodeIfPresent(Double.self, forKey: .bboxConfidence)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(polygon, forKey: .polygon)
            try c.encode(provenance, forKey: .provenance)
            // Preserve the legacy individual JSON shape exactly when no refinements exist.
            if !refinements.isEmpty { try c.encode(refinements, forKey: .refinements) }
            try c.encodeIfPresent(bboxConfidence, forKey: .bboxConfidence)
        }
    }

    enum Outcome: String, Codable, Sendable {
        case emittedOriginal, exactQuadAlreadyEmitted, duplicateOriginalObservation
        case correctedOnly, invalidOriginal, conflictingOriginalObservation
        case emittedLayout, exactLayoutQuadAlreadyEmitted, duplicateLayoutObservation
        case layoutModeDisabled, invalidLayout, conflictingLayoutObservation
        case emittedRefinement, exactRefinementQuadAlreadyEmitted, duplicateRefinementObservation
        case refinementModeDisabled, invalidRefinement, unboundRefinement, conflictingRefinementObservation
        case refinementContextOnly
    }

    struct Event: Codable, Sendable {
        let alternativeID: String
        let originalDetectorIndex: Int?
        let outcome: Outcome
        var refinementHead: RefinementHead? = nil
    }

    struct Counts: Codable, Sendable {
        let correctedInput: Int
        let originalInput: Int
        let emittedIndividuals: Int
        let addedOriginalIndividuals: Int
        let exactQuadDeduplicatedOriginals: Int
        let duplicateOriginalObservations: Int
        let rejectedOriginals: Int
        var layoutInput: Int = 0
        var addedLayoutIndividuals: Int = 0
        var exactQuadDeduplicatedLayouts: Int = 0
        var duplicateLayoutObservations: Int = 0
        var rejectedLayouts: Int = 0
        var ignoredLayouts: Int = 0
        var refinementInput: Int = 0
        var addedRefinementIndividuals: Int = 0
        var exactQuadDeduplicatedRefinements: Int = 0
        var duplicateRefinementObservations: Int = 0
        var rejectedRefinements: Int = 0
        var ignoredRefinements: Int = 0

        fileprivate func withEmittedIndividuals(_ count: Int) -> Counts {
            Counts(correctedInput: correctedInput, originalInput: originalInput, emittedIndividuals: count,
                   addedOriginalIndividuals: addedOriginalIndividuals,
                   exactQuadDeduplicatedOriginals: exactQuadDeduplicatedOriginals,
                   duplicateOriginalObservations: duplicateOriginalObservations, rejectedOriginals: rejectedOriginals,
                   layoutInput: layoutInput, addedLayoutIndividuals: addedLayoutIndividuals,
                   exactQuadDeduplicatedLayouts: exactQuadDeduplicatedLayouts,
                   duplicateLayoutObservations: duplicateLayoutObservations, rejectedLayouts: rejectedLayouts,
                   ignoredLayouts: ignoredLayouts, refinementInput: refinementInput,
                   addedRefinementIndividuals: addedRefinementIndividuals,
                   exactQuadDeduplicatedRefinements: exactQuadDeduplicatedRefinements,
                   duplicateRefinementObservations: duplicateRefinementObservations,
                   rejectedRefinements: rejectedRefinements, ignoredRefinements: ignoredRefinements)
        }
    }

    struct Output: Codable, Sendable {
        let mode: Mode
        /// This IS the output array to serialize as runtime individual geometry rows.
        /// Evaluate ONLY these emitted polygons, never a separate raw/proposal bank.
        let individuals: [Individual]
        let counts: Counts
        let events: [Event]
    }

    /// Score admission is separate from geometry construction and preserves
    /// every retained polygon, source identity and refinement verbatim.
    static func admitting(_ input: Output, bboxScores: [Double], threshold: Double) -> Output {
        precondition(bboxScores.count == input.individuals.count)
        let kept = zip(input.individuals, bboxScores).compactMap { row, score -> Individual? in
            guard score.isFinite, score >= threshold else { return nil }
            return .init(polygon: row.polygon, provenance: row.provenance,
                         refinements: row.refinements, bboxConfidence: score)
        }
        return .init(mode: input.mode, individuals: kept,
                     counts: input.counts.withEmittedIndividuals(kept.count), events: input.events)
    }

    /// Retains original rows without rewriting polygons or inventing provenance.
    static func selecting(_ input: Output, indices: [Int]) -> Output {
        .init(mode: input.mode, individuals: indices.map { input.individuals[$0] },
              counts: input.counts.withEmittedIndividuals(indices.count), events: input.events)
    }

    private struct SourceKey: Hashable {
        let requestID: String
        let detectorIndex: Int
    }

    private struct LayoutSourceKey: Hashable {
        let requestID: String
        let index: Int
        let isOriginalDetector: Bool
    }

    private static func layoutSourceKey(_ record: Record) -> LayoutSourceKey {
        // A declared original observation cannot be multiplied with synthetic IDs.
        // Derived/group observations use their actual producer sourceIndex instead.
        LayoutSourceKey(requestID: record.requestID,
                        index: record.originalDetectorIndex ?? record.sourceIndex,
                        isOriginalDetector: record.originalDetectorIndex != nil)
    }

    private struct RefinementSourceKey: Hashable {
        let source: LayoutSourceKey
        let head: RefinementHead
    }

    /// Frozen integration API: old modes ignore refinements; v3 extends actual v2 output.
    /// At most ONE runtime refinement per explicit sourceParent owner / producer head.
    /// Emits concrete individual output rows, not an unselected proposal bank.
    static func emit(requestID: String, corrected: [Record], originals: [Record],
                     layout: [Record] = [], refinements: [Refinement] = [],
                     mode: Mode = .correctedOnly,
                     emissionPlan: ProducerEmissionPlan = .init()) -> Output {
        let base = emitLayout(requestID: requestID, corrected: corrected, originals: originals, layout: layout,
                              mode: mode == .sourceOriginalLayoutRefinedAndCorrectedV3 ?
                                .sourceOriginalLayoutAndCorrectedV2 : mode)
        var emitted = base.individuals
        var events = base.events
        var added = 0, deduplicated = 0, duplicates = 0, rejected = 0, ignored = 0
        func event(_ refinement: Refinement, _ outcome: Outcome) {
            events.append(Event(alternativeID: refinement.record.alternativeID,
                                originalDetectorIndex: refinement.record.originalDetectorIndex,
                                outcome: outcome, refinementHead: refinement.head))
        }
        func output() -> Output {
            var counts = base.counts
            counts.refinementInput = refinements.count
            counts.addedRefinementIndividuals = added
            counts.exactQuadDeduplicatedRefinements = deduplicated
            counts.duplicateRefinementObservations = duplicates
            counts.rejectedRefinements = rejected
            counts.ignoredRefinements = ignored
            return Output(mode: mode, individuals: emitted,
                          counts: counts.withEmittedIndividuals(emitted.count), events: events)
        }
        guard mode == .sourceOriginalLayoutRefinedAndCorrectedV3 else {
            refinements.forEach { event($0, .refinementModeDisabled) }
            ignored = refinements.count
            return output()
        }
        // Immutable source records bind the parent and every claimed member. This is
        // an equality/provenance check, NOT nearest-overlap inference or seed certification.
        let inventory = base.individuals.flatMap(\.provenance).filter {
            $0.requestID == requestID && $0.origin != .sourceRefinement &&
                $0.sourceIndex >= 0 && $0.sourceParent >= 0 && !$0.sourceMembers.isEmpty &&
                $0.sourceMembers.allSatisfy { $0 >= 0 }
        }
        let members = inventory.reduce(into: Set<Int>()) { $0.formUnion($1.sourceMembers) }
        var firstBySourceHead: [RefinementSourceKey: Refinement] = [:]
        var conflicts = Set<RefinementSourceKey>()
        var alternatives: [String: Refinement] = [:]
        var conflictingIDs = Set<String>()
        let reservedIDs = Set(base.individuals.flatMap(\.provenance).map(\.alternativeID))
        for refinement in refinements where refinement.record.requestID == requestID {
            let record = refinement.record
            let key = RefinementSourceKey(source: LayoutSourceKey(requestID: record.requestID,
                                                         index: record.sourceParent, isOriginalDetector: false),
                                          head: refinement.head)
            if let previous = firstBySourceHead[key], !sameOriginal(previous.record, record) { conflicts.insert(key) }
            firstBySourceHead[key] = refinement
            if let previous = alternatives[record.alternativeID],
               previous.head != refinement.head || !sameOriginal(previous.record, record) {
                conflictingIDs.insert(record.alternativeID)
            }
            alternatives[record.alternativeID] = refinement
        }
        var processed = Set<RefinementSourceKey>()
        for refinement in refinements {
            let record = refinement.record
            guard record.origin == .sourceRefinement, !requestID.isEmpty, record.requestID == requestID,
                  !record.alternativeID.isEmpty, record.sourceIndex >= 0, record.sourceParent >= 0,
                  !record.sourceMembers.isEmpty, record.sourceMembers.allSatisfy({ $0 >= 0 }),
                  record.originalDetectorIndex.map({ $0 >= 0 && record.sourceMembers.contains($0) }) ?? true,
                  validQuad(record.polygon) else {
                rejected += 1; event(refinement, .invalidRefinement); continue
            }
            let key = RefinementSourceKey(source: LayoutSourceKey(requestID: record.requestID,
                                                         index: record.sourceParent, isOriginalDetector: false),
                                          head: refinement.head)
            guard !conflicts.contains(key), !conflictingIDs.contains(record.alternativeID),
                  !reservedIDs.contains(record.alternativeID) else {
                rejected += 1; event(refinement, .conflictingRefinementObservation); continue
            }
            guard record.sourceMembers.isSubset(of: members), inventory.contains(where: {
                $0.sourceIndex == record.sourceIndex && $0.sourceParent == record.sourceParent &&
                    $0.sourceMembers.isSubset(of: record.sourceMembers) &&
                    (record.originalDetectorIndex == nil || $0.originalDetectorIndex == record.originalDetectorIndex)
            }) else {
                rejected += 1; event(refinement, .unboundRefinement); continue
            }
            guard processed.insert(key).inserted else {
                duplicates += 1; event(refinement, .duplicateRefinementObservation); continue
            }
            // Validate bindings/conflicts as before, but skip row/provenance allocation.
            // Never mutate the supplied refinements: they remain producer context.
            guard emissionPlan.emits(refinement) else {
                ignored += 1; event(refinement, .refinementContextOnly); continue
            }
            if let existing = emitted.firstIndex(where: { individual in
                individual.provenance.contains {
                    $0.requestID == record.requestID && $0.sourceParent == record.sourceParent &&
                        $0.sourceMembers == record.sourceMembers
                } && equalQuad(individual.polygon, record.polygon)
            }) {
                let previous = emitted[existing]
                emitted[existing] = Individual(polygon: previous.polygon,
                                               provenance: previous.provenance + [record],
                                               refinements: previous.refinements + [refinement])
                deduplicated += 1; event(refinement, .exactRefinementQuadAlreadyEmitted)
            } else {
                emitted.append(Individual(polygon: record.polygon, provenance: [record], refinements: [refinement]))
                added += 1; event(refinement, .emittedRefinement)
            }
        }
        return output()
    }

    /// The v2 layout input is ONE actual stored localization/layout quad per source
    /// observation (originalDetectorIndex when declared, else sourceIndex), e.g. the
    /// model grouping prior before late correction.
    /// Caller certifies producer provenance. Never supply fitted envelopes, sampling
    /// crops or multiple coordinate guesses. Legacy modes ignore this new input.
    private static func emitLayout(requestID: String, corrected: [Record], originals: [Record],
                                   layout: [Record], mode: Mode) -> Output {
        // Layout conflicts must NEVER remove a previously emitted corrected/original row.
        let base = emitOriginals(requestID: requestID, corrected: corrected, originals: originals,
                                 mode: mode == .correctedOnly ? .correctedOnly : .sourceOriginalAndCorrectedV1)
        var emitted = base.individuals
        var events = base.events
        var added = 0, deduplicated = 0, duplicates = 0, rejected = 0, ignored = 0
        func event(_ record: Record, _ outcome: Outcome) {
            events.append(Event(alternativeID: record.alternativeID,
                                originalDetectorIndex: record.originalDetectorIndex, outcome: outcome))
        }
        func output() -> Output {
            Output(mode: mode, individuals: emitted,
                   counts: Counts(correctedInput: base.counts.correctedInput,
                                  originalInput: base.counts.originalInput,
                                  emittedIndividuals: emitted.count,
                                  addedOriginalIndividuals: base.counts.addedOriginalIndividuals,
                                  exactQuadDeduplicatedOriginals: base.counts.exactQuadDeduplicatedOriginals,
                                  duplicateOriginalObservations: base.counts.duplicateOriginalObservations,
                                  rejectedOriginals: base.counts.rejectedOriginals,
                                  layoutInput: layout.count, addedLayoutIndividuals: added,
                                  exactQuadDeduplicatedLayouts: deduplicated,
                                  duplicateLayoutObservations: duplicates, rejectedLayouts: rejected,
                                  ignoredLayouts: ignored), events: events)
        }
        guard mode == .sourceOriginalLayoutAndCorrectedV2 else {
            layout.forEach { event($0, .layoutModeDisabled) }
            ignored = layout.count
            return output()
        }
        var firstBySource: [LayoutSourceKey: Record] = [:]
        var conflictSources = Set<LayoutSourceKey>()
        var firstByAlternative: [String: Record] = [:]
        var conflictAlternatives = Set<String>()
        // Include retained source records in the identity check, but never change them.
        for record in base.individuals.flatMap(\.provenance) + layout where record.requestID == requestID {
            if let previous = firstByAlternative[record.alternativeID], !sameOriginal(previous, record) {
                conflictAlternatives.insert(record.alternativeID)
            }
            firstByAlternative[record.alternativeID] = record
        }
        for record in layout where record.requestID == requestID {
            let key = layoutSourceKey(record)
            if let previous = firstBySource[key], !sameOriginal(previous, record) { conflictSources.insert(key) }
            firstBySource[key] = record
        }
        var processed = Set<LayoutSourceKey>()
        for record in layout {
            guard record.origin == .sourceLayout, !requestID.isEmpty, record.requestID == requestID,
                  !record.alternativeID.isEmpty, record.sourceIndex >= 0, record.sourceParent >= 0,
                  !record.sourceMembers.isEmpty, record.sourceMembers.allSatisfy({ $0 >= 0 }),
                  record.originalDetectorIndex.map({ $0 >= 0 && record.sourceMembers.contains($0) }) ?? true,
                  validQuad(record.polygon) else {
                rejected += 1; event(record, .invalidLayout); continue
            }
            let key = layoutSourceKey(record)
            guard !conflictSources.contains(key), !conflictAlternatives.contains(record.alternativeID) else {
                rejected += 1; event(record, .conflictingLayoutObservation); continue
            }
            guard processed.insert(key).inserted else {
                duplicates += 1; event(record, .duplicateLayoutObservation); continue
            }
            if let existing = emitted.firstIndex(where: { individual in
                individual.provenance.contains {
                    $0.requestID == record.requestID && $0.sourceParent == record.sourceParent &&
                        $0.sourceMembers == record.sourceMembers
                } && equalQuad(individual.polygon, record.polygon)
            }) {
                let previous = emitted[existing]
                emitted[existing] = Individual(polygon: previous.polygon, provenance: previous.provenance + [record])
                deduplicated += 1; event(record, .exactLayoutQuadAlreadyEmitted)
            } else {
                emitted.append(Individual(polygon: record.polygon, provenance: [record]))
                added += 1; event(record, .emittedLayout)
            }
        }
        return output()
    }

    /// Original validity checks certify a stored original source record, not its content.
    /// Corrected records are never dropped, reshaped, ranked or re-ordered. Exact quad
    /// dedup only avoids ADDING an original identical to an emitted same-lineage quad;
    /// preexisting duplicate corrected records remain intact to preserve the baseline.
    private static func emitOriginals(requestID: String, corrected: [Record], originals: [Record], mode: Mode) -> Output {
        var emitted = corrected.map { Individual(polygon: $0.polygon, provenance: [$0]) }
        var events: [Event] = []
        var added = 0, deduplicated = 0, duplicates = 0, rejected = 0
        func event(_ record: Record, _ outcome: Outcome) {
            events.append(Event(alternativeID: record.alternativeID,
                                originalDetectorIndex: record.originalDetectorIndex, outcome: outcome))
        }
        guard mode == .sourceOriginalAndCorrectedV1 else {
            originals.forEach { event($0, .correctedOnly) }
            return Output(mode: mode, individuals: emitted,
                          counts: Counts(correctedInput: corrected.count, originalInput: originals.count,
                                         emittedIndividuals: emitted.count, addedOriginalIndividuals: 0,
                                         exactQuadDeduplicatedOriginals: 0, duplicateOriginalObservations: 0,
                                         rejectedOriginals: 0), events: events)
        }
        var firstBySource: [SourceKey: Record] = [:]
        var firstByAlternative: [String: Record] = [:]
        var conflictAlternatives = Set<String>()
        for record in corrected + originals where record.requestID == requestID {
            if let previous = firstByAlternative[record.alternativeID], !sameOriginal(previous, record) {
                conflictAlternatives.insert(record.alternativeID)
            }
            firstByAlternative[record.alternativeID] = record
        }
        var conflictSources = Set<SourceKey>()
        // One stored original per detector observation. A grid or a second contradictory
        // original for the same observation cannot silently become another hypothesis.
        for record in originals {
            guard let index = record.originalDetectorIndex else { continue }
            let key = SourceKey(requestID: record.requestID, detectorIndex: index)
            if let previous = firstBySource[key], !sameOriginal(previous, record) { conflictSources.insert(key) }
            firstBySource[key] = record
        }
        var processedSources = Set<SourceKey>()
        for record in originals {
            guard record.origin == .sourceOriginal, !requestID.isEmpty, record.requestID == requestID,
                  !record.alternativeID.isEmpty, record.sourceIndex >= 0, record.sourceParent >= 0,
                  let index = record.originalDetectorIndex, index >= 0,
                  record.sourceMembers == Set([index]), validQuad(record.polygon) else {
                rejected += 1; event(record, .invalidOriginal); continue
            }
            let key = SourceKey(requestID: record.requestID, detectorIndex: index)
            guard !conflictSources.contains(key), !conflictAlternatives.contains(record.alternativeID) else {
                rejected += 1; event(record, .conflictingOriginalObservation); continue
            }
            guard processedSources.insert(key).inserted else {
                duplicates += 1; event(record, .duplicateOriginalObservation); continue
            }
            if let existing = emitted.firstIndex(where: { individual in
                individual.provenance.contains {
                    $0.requestID == record.requestID && $0.sourceParent == record.sourceParent &&
                        $0.sourceMembers == record.sourceMembers
                } && equalQuad(individual.polygon, record.polygon)
            }) {
                let previous = emitted[existing]
                emitted[existing] = Individual(polygon: previous.polygon, provenance: previous.provenance + [record])
                deduplicated += 1; event(record, .exactQuadAlreadyEmitted)
            } else {
                emitted.append(Individual(polygon: record.polygon, provenance: [record]))
                added += 1; event(record, .emittedOriginal)
            }
        }
        return Output(mode: mode, individuals: emitted,
                      counts: Counts(correctedInput: corrected.count, originalInput: originals.count,
                                     emittedIndividuals: emitted.count, addedOriginalIndividuals: added,
                                     exactQuadDeduplicatedOriginals: deduplicated,
                                     duplicateOriginalObservations: duplicates, rejectedOriginals: rejected), events: events)
    }

    private static func sameOriginal(_ a: Record, _ b: Record) -> Bool {
        // Identical raw observation repeated by a caller may have another wrapper ID;
        // it remains ONE source original. Conflicting parent/member/geometry is invalid.
        a.requestID == b.requestID && a.sourceIndex == b.sourceIndex &&
            a.sourceParent == b.sourceParent && a.sourceMembers == b.sourceMembers &&
            a.origin == b.origin && a.originalDetectorIndex == b.originalDetectorIndex &&
            equalQuad(a.polygon, b.polygon)
    }

    /// Equality is EXACT, with only winding/cyclic start normalization. No rounding,
    /// IoU tolerance or area/shape score can erase a near-threshold geometry hypothesis.
    private static func equalQuad(_ a: [Point], _ b: [Point]) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        for start in 0..<4 {
            if (0..<4).allSatisfy({ a[$0] == b[(start + $0) % 4] }) { return true }
            if (0..<4).allSatisfy({ a[$0] == b[(start - $0 + 4) % 4] }) { return true }
        }
        return false
    }

    private static func validQuad(_ points: [Point]) -> Bool {
        guard points.count == 4,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e7 && abs($0.y) <= 1e7 }) else { return false }
        let turns = (0..<4).map { i -> Double in
            let a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }
}

// Preserve the v2 counts JSON shape when no refinement input exists, while allowing
// older frozen outputs (without layout/refinement counters) to decode for comparison.
extension NativeOCRIndividualGeometryHypotheses.Counts {
    private enum CodingKeys: String, CodingKey {
        case correctedInput, originalInput, emittedIndividuals, addedOriginalIndividuals
        case exactQuadDeduplicatedOriginals, duplicateOriginalObservations, rejectedOriginals
        case layoutInput, addedLayoutIndividuals, exactQuadDeduplicatedLayouts
        case duplicateLayoutObservations, rejectedLayouts, ignoredLayouts
        case refinementInput, addedRefinementIndividuals, exactQuadDeduplicatedRefinements
        case duplicateRefinementObservations, rejectedRefinements, ignoredRefinements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(correctedInput: try c.decode(Int.self, forKey: .correctedInput),
                  originalInput: try c.decode(Int.self, forKey: .originalInput),
                  emittedIndividuals: try c.decode(Int.self, forKey: .emittedIndividuals),
                  addedOriginalIndividuals: try c.decode(Int.self, forKey: .addedOriginalIndividuals),
                  exactQuadDeduplicatedOriginals: try c.decode(Int.self, forKey: .exactQuadDeduplicatedOriginals),
                  duplicateOriginalObservations: try c.decode(Int.self, forKey: .duplicateOriginalObservations),
                  rejectedOriginals: try c.decode(Int.self, forKey: .rejectedOriginals),
                  layoutInput: try c.decodeIfPresent(Int.self, forKey: .layoutInput) ?? 0,
                  addedLayoutIndividuals: try c.decodeIfPresent(Int.self, forKey: .addedLayoutIndividuals) ?? 0,
                  exactQuadDeduplicatedLayouts: try c.decodeIfPresent(Int.self, forKey: .exactQuadDeduplicatedLayouts) ?? 0,
                  duplicateLayoutObservations: try c.decodeIfPresent(Int.self, forKey: .duplicateLayoutObservations) ?? 0,
                  rejectedLayouts: try c.decodeIfPresent(Int.self, forKey: .rejectedLayouts) ?? 0,
                  ignoredLayouts: try c.decodeIfPresent(Int.self, forKey: .ignoredLayouts) ?? 0,
                  refinementInput: try c.decodeIfPresent(Int.self, forKey: .refinementInput) ?? 0,
                  addedRefinementIndividuals: try c.decodeIfPresent(Int.self, forKey: .addedRefinementIndividuals) ?? 0,
                  exactQuadDeduplicatedRefinements: try c.decodeIfPresent(Int.self, forKey: .exactQuadDeduplicatedRefinements) ?? 0,
                  duplicateRefinementObservations: try c.decodeIfPresent(Int.self, forKey: .duplicateRefinementObservations) ?? 0,
                  rejectedRefinements: try c.decodeIfPresent(Int.self, forKey: .rejectedRefinements) ?? 0,
                  ignoredRefinements: try c.decodeIfPresent(Int.self, forKey: .ignoredRefinements) ?? 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(correctedInput, forKey: .correctedInput)
        try c.encode(originalInput, forKey: .originalInput)
        try c.encode(emittedIndividuals, forKey: .emittedIndividuals)
        try c.encode(addedOriginalIndividuals, forKey: .addedOriginalIndividuals)
        try c.encode(exactQuadDeduplicatedOriginals, forKey: .exactQuadDeduplicatedOriginals)
        try c.encode(duplicateOriginalObservations, forKey: .duplicateOriginalObservations)
        try c.encode(rejectedOriginals, forKey: .rejectedOriginals)
        try c.encode(layoutInput, forKey: .layoutInput)
        try c.encode(addedLayoutIndividuals, forKey: .addedLayoutIndividuals)
        try c.encode(exactQuadDeduplicatedLayouts, forKey: .exactQuadDeduplicatedLayouts)
        try c.encode(duplicateLayoutObservations, forKey: .duplicateLayoutObservations)
        try c.encode(rejectedLayouts, forKey: .rejectedLayouts)
        try c.encode(ignoredLayouts, forKey: .ignoredLayouts)
        if refinementInput != 0 || addedRefinementIndividuals != 0 || exactQuadDeduplicatedRefinements != 0 ||
            duplicateRefinementObservations != 0 || rejectedRefinements != 0 || ignoredRefinements != 0 {
            try c.encode(refinementInput, forKey: .refinementInput)
            try c.encode(addedRefinementIndividuals, forKey: .addedRefinementIndividuals)
            try c.encode(exactQuadDeduplicatedRefinements, forKey: .exactQuadDeduplicatedRefinements)
            try c.encode(duplicateRefinementObservations, forKey: .duplicateRefinementObservations)
            try c.encode(rejectedRefinements, forKey: .rejectedRefinements)
            try c.encode(ignoredRefinements, forKey: .ignoredRefinements)
        }
    }
}
