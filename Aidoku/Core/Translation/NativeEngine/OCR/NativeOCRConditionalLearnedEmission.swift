import Foundation

/// Compute all heads, paint seeds, and reservation banks before output admission.
/// This helper controls only emitted rows. It never mutates those context banks.
enum NativeOCRConditionalLearnedEmission {
    enum Mode: String, Codable { case disabled, reciprocalComputedHeads = "reciprocal-computed-heads" }
    enum Head: String, Codable, Hashable, Sendable {
        case legacy = "learned-boundary", v2 = "learned-boundary-v2", head376 = "learned-boundary-376"
    }
    struct Point: Codable, Hashable, Sendable { let x: Double; let y: Double }
    typealias Quad = [Point]
    struct Decision: Decodable {
        let head: Head
        let outputAlternativeID: String?
        let inputQuad: Quad
        let chosenQuad: Quad
    }
    struct Row: Decodable {
        let polygon: Quad
        let provenanceAlternativeIDs: [String]
    }
    struct Observation: Decodable { let polygon: Quad; let confidence: Double }
    struct Configuration {
        let mode: Mode
        let agreement: Double
        let observationOverlap: Double
        let detectorFloor: Double
        let recognitionFloor: Double
        init(mode: Mode = .disabled, agreement: Double = 0.9,
             observationOverlap: Double = 0.8, detectorFloor: Double = 0.07,
             recognitionFloor: Double = 0) {
            self.mode = mode; self.agreement = agreement
            self.observationOverlap = observationOverlap; self.detectorFloor = detectorFloor
            self.recognitionFloor = recognitionFloor
        }
    }
    struct Result { let keptIndices: [Int]; let suppressedIndices: [Int] }
    /// Inject NativeOCRGeometryDeduplication.polygonIoU through a Point bridge.
    /// Rows must be the same canonical merged inventory as the unmodified emitter.
    static func select(rows: [Row], decisions: [Decision], detectors: [Observation],
                       recognition: [Observation], protectedPolygons: [Quad] = [], configuration c: Configuration,
                       polygonIoU: (Quad, Quad) -> Double) -> Result {
        guard c.mode == .reciprocalComputedHeads else {
            return .init(keptIndices: Array(rows.indices), suppressedIndices: [])
        }
        let protectedKeys = Set(protectedPolygons.compactMap(canonical))
        var byOutput: [String: [Int]] = [:]
        var byInput: [Quad: [Int]] = [:]
        for (i, d) in decisions.enumerated() {
            guard let input = canonical(d.inputQuad), canonical(d.chosenQuad) != nil else { continue }
            byInput[input, default: []].append(i)
            if let id = d.outputAlternativeID { byOutput[id, default: []].append(i) }
        }
        func confidence(_ observations: [Observation], on q: Quad) -> Double {
            observations.filter { $0.confidence.isFinite && polygonIoU(q, $0.polygon) >= c.observationOverlap }
                .map(\.confidence).max() ?? 0
        }
        var kept: [Int] = [], suppressed: [Int] = []
        for (i, row) in rows.enumerated() {
            // Exact dedup may merge provenance: never delete an original/layout/paint row.
            let ids = row.provenanceAlternativeIDs
            let pureHeads = !ids.isEmpty && ids.allSatisfy {
                Head(rawValue: String($0.split(separator: "/").first ?? "")) != nil
            }
            let uniqueJoins = ids.allSatisfy { byOutput[$0]?.count == 1 }
            guard pureHeads, uniqueJoins, let first = ids.first,
                  let di = byOutput[first]?.first,
                  let rowKey = canonical(row.polygon), !protectedKeys.contains(rowKey)
                  else { kept.append(i); continue }
            let decision = decisions[di]
            guard let input = canonical(decision.inputQuad), let peers = byInput[input],
                  polygonIoU(row.polygon, decision.inputQuad) >= c.agreement,
                  confidence(detectors, on: decision.inputQuad) >= c.detectorFloor,
                  confidence(recognition, on: decision.inputQuad) >= c.recognitionFloor,
                  peers.contains(where: {
                      decisions[$0].head != decision.head && polygonIoU(row.polygon, decisions[$0].chosenQuad) >= c.agreement
                  }) else { kept.append(i); continue }
            suppressed.append(i)
        }
        return .init(keptIndices: kept, suppressedIndices: suppressed)
    }
    /// Call BEFORE G.emit, AFTER all paint scopes/seeds/reservations are finalized.
    /// computedLearnedRecords contains only the records otherwise eligible for emission.
    /// observedSourceRecords is raw + corrected + layout + paint + other emitted producers.
    /// Decisions always describe ALL computed heads, including non-emitted unchanged heads.
    static func suppressedAlternativeIDs(computedLearnedRecords: [Row], observedSourceRecords: [Row],
                                         decisions: [Decision], detectors: [Observation],
                                         recognition: [Observation] = [], configuration: Configuration,
                                         polygonIoU: (Quad, Quad) -> Double) -> Set<String> {
        let result = select(rows: computedLearnedRecords, decisions: decisions, detectors: detectors,
                            recognition: recognition, protectedPolygons: observedSourceRecords.map(\.polygon),
                            configuration: configuration, polygonIoU: polygonIoU)
        return Set(result.suppressedIndices.flatMap { computedLearnedRecords[$0].provenanceAlternativeIDs })
    }
    /// Preserve every computed context bank; only omit redundant output records.
    static func emittedRecords(_ records: [NativeOCRIndividualGeometryHypotheses.Record],
                               observed: [NativeOCRIndividualGeometryHypotheses.Record],
                               decisions: [Decision], detectors: [Observation],
                               environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [NativeOCRIndividualGeometryHypotheses.Record] {
        guard environment["AIDOKU_OCR_LEARNED_PROPOSAL_EMISSION"] == "reciprocal-computed-heads-v1" else { return records }
        func quad(_ record: NativeOCRIndividualGeometryHypotheses.Record) -> Quad {
            record.polygon.map { .init(x: $0.x, y: $0.y) }
        }
        var keys: [Quad] = [], grouped: [Quad: [String]] = [:]
        for record in records {
            guard let key = canonical(quad(record)) else { continue }
            if grouped[key] == nil { keys.append(key) }
            grouped[key, default: []].append(record.alternativeID)
        }
        let rows = keys.map { Row(polygon: $0, provenanceAlternativeIDs: grouped[$0] ?? []) }
        let protected = observed.map { Row(polygon: quad($0), provenanceAlternativeIDs: [$0.alternativeID]) }
        let suppressed = suppressedAlternativeIDs(computedLearnedRecords: rows, observedSourceRecords: protected,
            decisions: decisions, detectors: detectors,
            configuration: .init(mode: .reciprocalComputedHeads, agreement: 0.9)) { a, b in
                NativeOCRGeometryDeduplication.polygonIoU(a.map { .init(x: $0.x, y: $0.y) },
                    b.map { .init(x: $0.x, y: $0.y) })
            }
        return records.filter { !suppressed.contains($0.alternativeID) }
    }

    // MARK: - V2: decide before constructing alternative output Records

    enum CanonicalMode: String, Codable, Sendable {
        case disabled
        case sourceFirst = "source-first-v2"
        case conservative = "canonical-source-emission-v2"
        case aggressive = "canonical-source-emission-v2-aggressive"
    }
    enum SourceStage: String, Codable, Sendable { case original, corrected, layout, other }
    /// Lightweight geometry/binding only. Keep the full source/evidence bank alive.
    struct SourceDraft: Codable, Sendable {
        let stage: SourceStage
        let polygon: Quad
        var eligibleForEmission: Bool = true
    }
    /// One entry for EVERY computed decision, including unchanged/non-emitted heads.
    /// sourceInputIndex is an input-array binding, never inferred text membership.
    struct HeadDraft: Codable, Sendable {
        let sourceInputIndex: Int
        let head: Head
        let inputQuad: Quad
        let chosenQuad: Quad
        let outputAlternativeID: String?
        var eligibleForEmission: Bool = true
        var hasOutput: Bool { eligibleForEmission && outputAlternativeID?.isEmpty == false }
    }
    struct CanonicalConfiguration: Sendable {
        var mode: CanonicalMode = .disabled
        /// True only AFTER all immutable head/context/paint/reservation evidence is
        /// frozen independently of emitted Record arrays. Otherwise fail open.
        var contextBanksFrozen: Bool = false
        var agreement: Double { mode == .aggressive ? 0.9 : 0.98 }
        var observationOverlap: Double { mode == .aggressive ? 0.5 : 0.8 }
    }
    struct MaterializationSkip: Codable, Equatable, Sendable {
        let inputIndex: Int
        let representativeSourceIndex: Int?
        let representativeHeadIndex: Int?
        let polygonIoU: Double
        let reason: String
    }
    struct MaterializationPlan: Codable, Sendable {
        let mode: CanonicalMode
        let enabled: Bool
        let sourceInputCount: Int
        let headDecisionCount: Int
        let sourceIndicesToEmit: [Int]
        let headIndicesToEmit: [Int]
        /// Preserve these descriptors/decisions for ranking, paint seeds, 376 and
        /// reservations even when their full output Record constructor is skipped.
        let contextSourceIndices: [Int]
        let contextHeadIndices: [Int]
        let skippedSources: [MaterializationSkip]
        let skippedHeads: [MaterializationSkip]
        var possibleHeadRecordConstructorsAvoided: Int { skippedHeads.count }
        /// A source may already be materialized in the immutable input bank.
        /// This counts output offers, NOT allocations of that input bank.
        var sourceOutputOffersAvoided: Int { skippedSources.count }
        var modelCallsAvoided: Int { 0 }
        var pixelQueriesAvoided: Int { 0 }
    }

    static let canonicalEnvironmentKey = "AIDOKU_OCR_LEARNED_PROPOSAL_EMISSION"
    static func canonicalConfiguration(contextBanksFrozen: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CanonicalConfiguration {
        // V1 stays on its existing path. Unknown/unset modes cannot suppress.
        let mode = environment[canonicalEnvironmentKey].flatMap(CanonicalMode.init(rawValue:)) ?? .disabled
        return .init(mode: mode, contextBanksFrozen: contextBanksFrozen)
    }

    /// No G.Record arrays enter this API: invocation precedes output factories.
    /// This does NOT authorize dropping head computations or any immutable context.
    static func materializationPlan(sources: [SourceDraft], heads: [HeadDraft],
        detectors: [Observation], recognition: [Observation], configuration c: CanonicalConfiguration,
        polygonIoU: (Quad, Quad) -> Double) -> MaterializationPlan {
        var sourceKept = Set(sources.indices.filter { sources[$0].eligibleForEmission })
        var headKept = Set(heads.indices.filter { heads[$0].hasOutput })
        var sourceSkips: [MaterializationSkip] = [], headSkips: [MaterializationSkip] = []
        func result(_ enabled: Bool) -> MaterializationPlan {
            .init(mode: c.mode, enabled: enabled, sourceInputCount: sources.count, headDecisionCount: heads.count,
                sourceIndicesToEmit: sourceKept.sorted(), headIndicesToEmit: headKept.sorted(),
                contextSourceIndices: Array(sources.indices), contextHeadIndices: Array(heads.indices),
                skippedSources: sourceSkips, skippedHeads: headSkips)
        }
        guard c.mode != .disabled, c.contextBanksFrozen else { return result(false) }
        if c.mode == .sourceFirst {
            return sourceFirstMaterializationPlan(sources:sources,heads:heads,detectors:detectors,
                recognition:recognition,polygonIoU:polygonIoU)
        }
        func valid(_ q: Quad) -> Bool { validMaterializationQuad(q) }
        func overlap(_ a: Quad, _ b: Quad) -> Double {
            guard valid(a), valid(b) else { return 0 }
            let value = polygonIoU(a,b)
            return value.isFinite && (0...1).contains(value) ? value : 0
        }
        let detectorEvidence = detectors.filter { valid($0.polygon) && $0.confidence.isFinite
            && $0.confidence >= 0.085 && $0.confidence <= 1 }
        let recognitionEvidence = recognition.filter { valid($0.polygon) && $0.confidence.isFinite
            && $0.confidence >= 0.45 && $0.confidence <= 1 }
        func positiveContext(_ q: Quad) -> Bool {
            detectorEvidence.contains { overlap(q,$0.polygon) >= c.observationOverlap }
                && recognitionEvidence.contains { overlap(q,$0.polygon) >= c.observationOverlap }
        }
        func coversObservedSupport(_ candidate: Quad, _ representative: Quad) -> Bool {
            guard positiveContext(candidate), positiveContext(representative) else { return false }
            let a = materializationArea(candidate), b = materializationArea(representative)
            for observation in detectorEvidence + recognitionEvidence {
                let area = materializationArea(observation.polygon)
                let first = overlap(candidate,observation.polygon), second = overlap(representative,observation.polygon)
                let candidateCoverage = first*(a+area)/(1+first)/area
                let retainedCoverage = second*(b+area)/(1+second)/area
                // Protect every directly observed glyph envelope, not just its
                // max confidence or a chosen ancestry/source-parent association.
                if candidateCoverage > retainedCoverage + 1e-12 { return false }
                if c.mode == .conservative && first > second + 1e-12 { return false }
            }
            return true
        }
        var bySource: [Int:[Int]] = [:], idCounts: [String:Int] = [:]
        for i in heads.indices {
            bySource[heads[i].sourceInputIndex,default:[]].append(i)
            if heads[i].hasOutput, let id = heads[i].outputAlternativeID { idCounts[id,default:0] += 1 }
        }
        let allHeads = Set([Head.legacy, .v2, .head376])
        func complete(_ source: Int) -> [Int]? {
            guard sources.indices.contains(source), valid(sources[source].polygon), let group = bySource[source],
                  group.count == 3, Set(group.map { heads[$0].head }) == allHeads,
                  group.allSatisfy({ i in
                      canonical(heads[i].inputQuad) == canonical(sources[source].polygon)
                          && valid(heads[i].chosenQuad)
                          && (!heads[i].hasOutput || idCounts[heads[i].outputAlternativeID!] == 1)
                  }) else { return nil }
            return group
        }
        func mutuallyAgree(_ group: [Int], on representative: Quad) -> Bool {
            guard group.allSatisfy({ overlap(heads[$0].chosenQuad,representative) >= c.agreement }) else { return false }
            for i in group { for j in group where j > i {
                if overlap(heads[i].chosenQuad,heads[j].chosenQuad) < c.agreement { return false }
            }}
            return true
        }
        // Exact observed-output duplicates avoid an additional offer, while the
        // original/current bank and its separate glyph observations remain intact.
        let observed = sources.indices.filter { sourceKept.contains($0)
            && [.original,.corrected].contains(sources[$0].stage) && valid(sources[$0].polygon) }
        func priority(_ index: Int) -> Int { sources[index].stage == .corrected ? 0 : 1 }
        var exactSources: [Quad:Int] = [:]
        for i in observed.sorted(by: { priority($0) == priority($1) ? $0 < $1 : priority($0) < priority($1) }) {
            let key = canonical(sources[i].polygon)!
            if let j = exactSources[key] {
                sourceKept.remove(i)
                sourceSkips.append(.init(inputIndex:i,representativeSourceIndex:j,representativeHeadIndex:nil,
                    polygonIoU:1,reason:"exact-observed-output-duplicate"))
            } else { exactSources[key] = i }
        }
        // Aggressive raw/current canonicalization requires UNIQUE RECIPROCAL
        // physical matches and all-head/observed support, never equal parent IDs.
        if c.mode == .aggressive {
            let raw = observed.filter { sourceKept.contains($0) && sources[$0].stage == .original }
            let current = observed.filter { sourceKept.contains($0) && sources[$0].stage == .corrected }
            func uniqueBest(_ i: Int, in candidates: [Int]) -> Int? {
                var best: Int?, score = 0.0, tied = false
                for j in candidates {
                    let value = overlap(sources[i].polygon,sources[j].polygon)
                    if value > score { best = j; score = value; tied = false }
                    else if value == score { tied = true }
                }
                return score >= c.agreement && !tied ? best : nil
            }
            for i in raw {
                guard !sourceSkips.contains(where: { $0.representativeSourceIndex == i }),
                      let j = uniqueBest(i,in:current), uniqueBest(j,in:raw) == i,
                      let a = complete(i), let b = complete(j),
                      mutuallyAgree(a+b,on:sources[j].polygon),
                      coversObservedSupport(sources[i].polygon,sources[j].polygon) else { continue }
                sourceKept.remove(i)
                sourceSkips.append(.init(inputIndex:i,representativeSourceIndex:j,representativeHeadIndex:nil,
                    polygonIoU:overlap(sources[i].polygon,sources[j].polygon),reason:"reciprocal-observed-source-support"))
            }
        }
        // Use only FINAL scheduled source outputs as possible direct witnesses.
        // In particular, never suppress a head against a deleted raw-source row.
        var scheduledSources: [Quad:Int] = [:]
        for i in sourceKept.sorted() where valid(sources[i].polygon) {
            let key = canonical(sources[i].polygon)!
            if scheduledSources[key] == nil { scheduledSources[key] = i }
        }
        for source in sources.indices {
            let group = bySource[source] ?? []
            // A duplicate/foreign/partial head binding is ambiguous: fail open.
            guard let completeGroup = complete(source) else { continue }
            let preferred: Head?
            switch sources[source].stage {
            case .original: preferred = .legacy
            case .corrected: preferred = .v2
            case .layout: preferred = .head376
            case .other: preferred = nil
            }
            let order = group.sorted {
                let a = heads[$0].head == preferred ? 0 : 1, b = heads[$1].head == preferred ? 0 : 1
                return a == b ? $0 < $1 : a < b
            }
            var retainedHead: [Int] = []
            for i in order where heads[i].hasOutput {
                let candidate = heads[i].chosenQuad, key = canonical(candidate)!
                if let j = scheduledSources[key] {
                    headKept.remove(i)
                    headSkips.append(.init(inputIndex:i,representativeSourceIndex:j,representativeHeadIndex:nil,
                        polygonIoU:1,reason:"exact-source-geometry"))
                    continue
                }
                if let j = retainedHead.first(where: { canonical(heads[$0].chosenQuad) == key }) {
                    headKept.remove(i)
                    headSkips.append(.init(inputIndex:i,representativeSourceIndex:nil,representativeHeadIndex:j,
                        polygonIoU:1,reason:"exact-computed-head-geometry"))
                    continue
                }
                if preferred != nil {
                    let sourceWitness = sourceKept.contains(source) ? source : sourceSkips.first(where: {
                        $0.inputIndex == source
                    })?.representativeSourceIndex
                    if let j = sourceWitness, sourceKept.contains(j),
                       mutuallyAgree(completeGroup,on:sources[j].polygon),
                       coversObservedSupport(candidate,sources[j].polygon) {
                        headKept.remove(i)
                        headSkips.append(.init(inputIndex:i,representativeSourceIndex:j,representativeHeadIndex:nil,
                            polygonIoU:overlap(candidate,sources[j].polygon),reason:"canonical-source-observed-support"))
                        continue
                    }
                    if let j = retainedHead.first(where: {
                        mutuallyAgree(completeGroup,on:heads[$0].chosenQuad)
                            && coversObservedSupport(candidate,heads[$0].chosenQuad)
                    }) {
                        headKept.remove(i)
                        headSkips.append(.init(inputIndex:i,representativeSourceIndex:nil,representativeHeadIndex:j,
                            polygonIoU:overlap(candidate,heads[j].chosenQuad),reason:"canonical-computed-head-observed-support"))
                        continue
                    }
                }
                retainedHead.append(i)
            }
        }
        return result(true)
    }

    /// Experimental producer fanout cap. Raw observations are mandatory fallbacks;
    /// one body and at most one observed-support completion are scheduled per raw
    /// physical star. Membership is NOT inferred from sourceParent/queryParent.
    private static func sourceFirstMaterializationPlan(sources: [SourceDraft], heads: [HeadDraft],
        detectors: [Observation], recognition: [Observation], polygonIoU: (Quad,Quad)->Double) -> MaterializationPlan {
        let raw = sources.indices.filter { sources[$0].eligibleForEmission && sources[$0].stage == .original
            && validMaterializationQuad(sources[$0].polygon) }
        var keptSources = Set(sources.indices.filter { sources[$0].eligibleForEmission })
        var keptHeads = Set(heads.indices.filter { heads[$0].hasOutput })
        var sourceSkips:[MaterializationSkip] = [], headSkips:[MaterializationSkip] = []
        func result() -> MaterializationPlan {
            .init(mode:.sourceFirst,enabled:!raw.isEmpty,sourceInputCount:sources.count,headDecisionCount:heads.count,
                sourceIndicesToEmit:keptSources.sorted(),headIndicesToEmit:keptHeads.sorted(),
                contextSourceIndices:Array(sources.indices),contextHeadIndices:Array(heads.indices),
                skippedSources:sourceSkips,skippedHeads:headSkips)
        }
        guard !raw.isEmpty else { return result() }
        func overlap(_ a:Quad,_ b:Quad)->Double {
            guard validMaterializationQuad(a),validMaterializationQuad(b) else {return 0}
            let x=polygonIoU(a,b);return x.isFinite && (0...1).contains(x) ? x : 0
        }
        let det=detectors.filter {validMaterializationQuad($0.polygon) && $0.confidence.isFinite
            && $0.confidence>=0.085 && $0.confidence<=1}
        let rec=recognition.filter {validMaterializationQuad($0.polygon) && $0.confidence.isFinite
            && $0.confidence>=0.45 && $0.confidence<=1}
        let observations=det+rec
        func coverage(_ q:Quad,_ observation:Quad)->Double {
            let u=overlap(q,observation),a=materializationArea(q),b=materializationArea(observation)
            return b>0 ? min(1,max(0,u*(a+b)/(1+u)/b)) : 0
        }
        func rawMatch(_ source:Int)->Int? {
            guard sources.indices.contains(source),validMaterializationQuad(sources[source].polygon),
                  sources[source].stage != .other else {return nil}
            if raw.contains(source) {return source}
            var best:Int?,value=0.0,tied=false
            for r in raw {
                let x=overlap(sources[source].polygon,sources[r].polygon)
                if x>value {best=r;value=x;tied=false} else if x==value {tied=true}
            }
            return value>=0.5 && !tied ? best : nil
        }
        struct Offer {let source:Int?;let head:Int?;let polygon:Quad}
        var pools:[Int:[Offer]] = [:]
        // Current/layout are computation context, not independent source roots.
        // If their physical association is ambiguous or absent, keep them.
        for s in sources.indices where sources[s].eligibleForEmission
            && sources[s].stage != .original && sources[s].stage != .other {
            if let r=rawMatch(s) {pools[r,default:[]].append(.init(source:s,head:nil,polygon:sources[s].polygon))}
        }
        var idCounts:[String:Int] = [:]
        for h in heads where h.hasOutput {idCounts[h.outputAlternativeID!,default:0]+=1}
        for i in heads.indices where heads[i].hasOutput {
            let h=heads[i]
            guard sources.indices.contains(h.sourceInputIndex),
                  canonical(h.inputQuad)==canonical(sources[h.sourceInputIndex].polygon),
                  validMaterializationQuad(h.chosenQuad),idCounts[h.outputAlternativeID!]==1,
                  let r=rawMatch(h.sourceInputIndex),overlap(h.chosenQuad,sources[r].polygon)>=0.5 else {continue}
            pools[r,default:[]].append(.init(source:nil,head:i,polygon:h.chosenQuad))
        }
        for r in raw {
            let pool=pools[r] ?? []
            guard !pool.isEmpty else {continue}
            func score(_ offer:Offer)->Double {
                let detector=det.map{overlap(offer.polygon,$0.polygon)*$0.confidence}.max() ?? 0
                let recognized=rec.map{overlap(offer.polygon,$0.polygon)*$0.confidence}.max() ?? 0
                let agreement=pool.reduce(0.0){$0+overlap(offer.polygon,$1.polygon)}/Double(pool.count)
                return detector+2*recognized+0.25*agreement
            }
            let scores=pool.map(score)
            let ranked=pool.indices.sorted {a,b in
                let x=scores[a],y=scores[b]
                return x==y ? a<b : x>y
            }
            let body=ranked[0]
            var selected = Set<Int>()
            if canonical(pool[body].polygon) != canonical(sources[r].polygon) {selected.insert(body)}
            // A single common completion fallback, driven by directly observed
            // support NOT already covered by raw+body. No GT or per-example list.
            func completionGain(_ offer:Offer)->Double {
                observations.reduce(0.0) {sum,obs in
                    let covered=max(coverage(sources[r].polygon,obs.polygon),coverage(pool[body].polygon,obs.polygon))
                    return sum+max(0,coverage(offer.polygon,obs.polygon)-covered)*obs.confidence
                }
            }
            let gains=pool.map(completionGain)
            if let complete=ranked.first(where: {gains[$0]>0.025}) {
                // Choose the largest observed support gain, not merely first rank.
                let best=ranked.max {a,b in
                    let x=gains[a],y=gains[b]
                    return x==y ? ranked.firstIndex(of:a)!>ranked.firstIndex(of:b)! : x<y
                } ?? complete
                if !selected.contains(best),canonical(pool[best].polygon) != canonical(sources[r].polygon) {
                    selected.insert(best)
                }
            }
            for i in pool.indices where !selected.contains(i) {
                if let s=pool[i].source {
                    keptSources.remove(s)
                    sourceSkips.append(.init(inputIndex:s,representativeSourceIndex:r,representativeHeadIndex:nil,
                        polygonIoU:overlap(pool[i].polygon,sources[r].polygon),reason:"source-first-raw-fallback-and-body-budget"))
                }
                if let h=pool[i].head {
                    keptHeads.remove(h)
                    headSkips.append(.init(inputIndex:h,representativeSourceIndex:r,representativeHeadIndex:nil,
                        polygonIoU:overlap(pool[i].polygon,sources[r].polygon),reason:"source-first-raw-fallback-and-body-budget"))
                }
            }
        }
        return result()
    }

    // MARK: - Source-first, on-demand recovery BEFORE learned corrections

    struct RecoverySource: Codable, Sendable {
        /// Actual RAW observed detector geometry; never a learned/corrected/layout
        /// query substituted through empty sourceMembers or a virtual parent ID.
        let polygon: Quad
        let detectorConfidence: Double
        let bboxConfidence: Double?
    }
    struct RecoveryCandidate: Codable, Sendable {
        let polygon: Quad
        /// Actual DB mean on this geometry. nil requests a cheap confidence probe,
        /// NOT all-head computation or a new source-pixel query root.
        let bboxConfidence: Double?
    }
    enum SupportKind: String, Codable, Sendable { case recognition, rfMask, physicalGlyph }
    struct RecoverySupport: Codable, Sendable {
        let polygon: Quad
        let confidence: Double
        let kind: SupportKind
    }
    struct ConfidenceProbe: Codable, Equatable, Sendable {
        let rawSourceInputIndex: Int
        /// nil: measure this raw source; non-nil: existing canonical candidate.
        let canonicalCandidateIndex: Int?
    }
    struct HeadRecoveryRequest: Codable, Equatable, Sendable {
        let rawSourceInputIndex: Int
        let head: Head
        let uncoveredSupportIndices: [Int]
        let reason: String
    }
    struct RecoveryPlan: Codable, Sendable {
        let enabled: Bool
        let rawSourceCount: Int
        let canonicalCandidateCount: Int
        let rawFallbackSourceIndices: [Int]
        let headRequests: [HeadRecoveryRequest]
        let confidenceProbes: [ConfidenceProbe]
        let contextRawSourceIndices: [Int]
        var maximumLearnedHeadInvocations: Int { headRequests.count }
        var canonicalConfidenceProbeIndices: [Int] {
            Set(confidenceProbes.compactMap(\.canonicalCandidateIndex)).sorted()
        }
        var rawConfidenceProbeIndices: [Int] {
            confidenceProbes.filter { $0.canonicalCandidateIndex == nil }.map(\.rawSourceInputIndex)
        }
        var schedulesAlternativePixelRoots: Bool { false }
    }
    /// Optional bridge for callers already holding the ORIGINAL observed bank.
    /// A detached learned output cannot masquerade as a raw anchor even when its
    /// parent/index numbers or geometry happen to agree. Never synthesize members.
    static func recoverySourceFromObservedRecord(_ record: NativeOCRIndividualGeometryHypotheses.Record,
        detector: Observation, bboxConfidence: Double?) -> RecoverySource? {
        let q = record.polygon.map { Point(x:$0.x,y:$0.y) }
        guard record.origin == .sourceOriginal, let index = record.originalDetectorIndex, index >= 0,
              record.sourceIndex == index, record.alternativeID == "original/\(index)",
              validMaterializationQuad(q), canonical(q) == canonical(detector.polygon),
              detector.confidence.isFinite, detector.confidence > 0, detector.confidence <= 1 else { return nil }
        return .init(polygon:q,detectorConfidence:detector.confidence,bboxConfidence:bboxConfidence)
    }
    static let sourceFirstEnvironmentKey = "AIDOKU_OCR_GENERATION_SOURCE_FIRST"

    /// Parent calls this BEFORE any learned.corrections invocation. It consumes
    /// raw anchors, measured canonical-body confidence and independent actual
    /// support envelopes. It never accepts head records, sourceMembers or IDs.
    /// All full-reference/context banks must remain alive independently of outputs.
    static func recoveryPlan(rawSources: [RecoverySource], canonicalCandidates: [RecoveryCandidate],
        support: [RecoverySupport], contextBanksFrozen: Bool,
        environment: [String:String] = ProcessInfo.processInfo.environment,
        polygonIoU: (Quad,Quad)->Double) -> RecoveryPlan {
        let enabled = environment[sourceFirstEnvironmentKey] == "1" && contextBanksFrozen
        var fallbacks:[Int] = [], requests:[HeadRecoveryRequest] = [], probes:[ConfidenceProbe] = []
        func result() -> RecoveryPlan {
            .init(enabled:enabled,rawSourceCount:rawSources.count,canonicalCandidateCount:canonicalCandidates.count,
                rawFallbackSourceIndices:fallbacks,headRequests:requests,confidenceProbes:probes,
                contextRawSourceIndices:Array(rawSources.indices))
        }
        guard enabled else {return result()}
        func overlap(_ a:Quad,_ b:Quad)->Double {
            guard validMaterializationQuad(a),validMaterializationQuad(b) else {return 0}
            let x=polygonIoU(a,b);return x.isFinite && (0...1).contains(x) ? x : 0
        }
        func coverage(_ a:Quad,_ b:Quad)->Double {
            let u=overlap(a,b),area=materializationArea(b)
            return area>0 ? min(1,max(0,u*(materializationArea(a)+area)/(1+u)/area)) : 0
        }
        func measured(_ score:Double?)->Double? {
            score.flatMap{$0.isFinite && (0...1).contains($0) ? $0 : nil}
        }
        func supportAccepted(_ s:RecoverySupport)->Bool {
            guard validMaterializationQuad(s.polygon),s.confidence.isFinite,s.confidence<=1 else {return false}
            switch s.kind {
            case .recognition: return s.confidence>=0.45
            case .rfMask: return s.confidence>=0.5
            case .physicalGlyph: return s.confidence==1
            }
        }
        let positiveSupport=support.indices.filter{supportAccepted(support[$0])}
        let usable=canonicalCandidates.indices.filter {
            validMaterializationQuad(canonicalCandidates[$0].polygon)
                && (measured(canonicalCandidates[$0].bboxConfidence).map{$0>=0.085} ?? false)
        }
        let unmeasured=canonicalCandidates.indices.filter {
            validMaterializationQuad(canonicalCandidates[$0].polygon)
                && measured(canonicalCandidates[$0].bboxConfidence)==nil
        }
        for i in rawSources.indices {
            let raw=rawSources[i]
            guard validMaterializationQuad(raw.polygon),raw.detectorConfidence.isFinite,
                  raw.detectorConfidence>0,raw.detectorConfidence<=1 else {continue}
            // Physical association nominates support; it does not rewrite source
            // membership. Every request remains attached to this actual raw anchor.
            let nearby=positiveSupport.filter{overlap(raw.polygon,support[$0].polygon)>=0.25}
            let missing=nearby.filter { s in
                !usable.contains{coverage(canonicalCandidates[$0].polygon,support[s].polygon)>=0.95}
            }
            let rawCovered=usable.contains{overlap(raw.polygon,canonicalCandidates[$0].polygon)>=0.8}
            if rawCovered && missing.isEmpty {continue}
            // Resolve at most ONE plausible existing candidate confidence first.
            // The caller uses the already-computed DB map, then calls this planner
            // again. A probe is not a learned-model call or crop-family fanout.
            let possible=unmeasured.filter { c in
                overlap(raw.polygon,canonicalCandidates[c].polygon)>=0.8
                    || missing.contains{coverage(canonicalCandidates[c].polygon,support[$0].polygon)>=0.95}
            }
            if let candidate=possible.max(by:{
                overlap(raw.polygon,canonicalCandidates[$0].polygon)<overlap(raw.polygon,canonicalCandidates[$1].polygon)
            }) {
                probes.append(.init(rawSourceInputIndex:i,canonicalCandidateIndex:candidate))
                continue
            }
            guard let rawDB=measured(raw.bboxConfidence) else {
                probes.append(.init(rawSourceInputIndex:i,canonicalCandidateIndex:nil))
                continue
            }
            // First recovery is an immutable observed geometry, not an old head
            // bank. Its admission still uses the unchanged actual DB cutoff.
            if rawDB>=0.085 && (!rawCovered || !missing.isEmpty) {fallbacks.append(i)}
            let stillMissing=missing.filter {s in rawDB<0.085 || coverage(raw.polygon,support[s].polygon)<0.95}
            // Only measured independent positive support can request ONE canonical
            // frozen head. No all-three invocation, no recursive learned seed.
            if !stillMissing.isEmpty {
                requests.append(.init(rawSourceInputIndex:i,head:.legacy,uncoveredSupportIndices:stillMissing,
                    reason:rawDB<0.085 ? "positive-support-low-DB-source" : "positive-support-beyond-raw-fallback"))
            }
        }
        return result()
    }

    /// The factory is invoked only for emitted alternatives. Context decisions
    /// stay outside this API; if they still require full Records, callers cannot
    /// count their already-executed constructors as an avoided allocation.
    static func materializeHeads<T>(_ plan: MaterializationPlan, factory: (Int) throws -> T) rethrows -> [T] {
        try plan.headIndicesToEmit.map(factory)
    }
    static func materializeSources<T>(_ plan: MaterializationPlan, factory: (Int) throws -> T) rethrows -> [T] {
        try plan.sourceIndicesToEmit.map(factory)
    }
    private static func materializationArea(_ q: Quad) -> Double {
        abs(q.indices.reduce(0.0) { result,i in
            let j = (i+1)%q.count
            return result+q[i].x*q[j].y-q[j].x*q[i].y
        })/2
    }
    private static func validMaterializationQuad(_ q: Quad) -> Bool {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), materializationArea(q) > 0 else { return false }
        let turns = (0..<4).map { i in
            let a = q[i], b = q[(i+1)%4], c = q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 })
    }

    private static func canonical(_ quad: Quad) -> Quad? {
        guard quad.count == 4, quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        func less(_ a: Quad, _ b: Quad) -> Bool {
            for (p, q) in zip(a, b) {
                if p.x != q.x { return p.x < q.x }
                if p.y != q.y { return p.y < q.y }
            }
            return false
        }
        let forward = (0..<4).map { i in Array(quad[i...] + quad[..<i]) }
        let reverse = Array(quad.reversed())
        let backward = (0..<4).map { i in Array(reverse[i...] + reverse[..<i]) }
        return (forward + backward).min(by: less)
    }
}
