import Foundation

/// Fixed optional SOURCE-MIXTURE admission over already computed independent heads.
/// No model execution, GT, content/recognition gate or ownership reconstruction.
@available(iOS 18.0, *)
enum NativeOCRLearnedBoundaryAdmission {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias V3 = NativeOCRLearnedBoundaryGeometryV2
    typealias B376 = NativeOCRLearnedBoundaryGeometry376
    static let environmentKey = "AIDOKU_OCR_LEARNED_BOUNDARY_376_ADMISSION"
    static let schema = "learned-boundary-376-source-mixture-v1"
    enum Mode: String, Codable, Sendable { case append, sourceMixture = "source-mixture" }
    enum Failure: Error { case invalidPolicy(String) }
    static func mode(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Mode {
        guard let value = environment[environmentKey], !value.isEmpty else { return .append }
        guard let mode = Mode(rawValue: value) else { throw Failure.invalidPolicy(value) }
        return mode
    }
    struct RecordReference: Codable, Hashable, Sendable {
        let requestID: String
        let sourceIndex: Int
        let alternativeID: String
        let polygon: [G.Point]
    }
    struct Event: Codable, Equatable, Sendable {
        let requestID: String
        let inputOrdinal: Int
        let inputQuad: [G.Point]
        let valid376: Bool
        let unchanged376: Bool
        let db32Available: Bool?
        let baselinePresent: Bool
        let action: String
        let reason: String
        let computedV3: [RecordReference]
        let computed376: [RecordReference]
        let suppressedV3: [RecordReference]
        let admittedV3: [RecordReference]
        let admitted376: [RecordReference]
    }
    struct Counts: Codable, Equatable, Sendable {
        var computedV3: Int
        var computed376: Int
        var suppressedV3: Int
        var suppressed376: Int
        var admittedV3: Int
        var admitted376: Int
        var emittedV3: Int = 0
        var emitted376: Int = 0
        var unpredictedV3: Int
        var valid376Predictions: Int
        var validUnchanged376: Int
        var invalidOrUnaligned376: Int
    }
    struct Proof: Codable, Equatable, Sendable {
        let schema: String
        let policy: String
        let requestID: String
        let baselineRows: Int
        var counts: Counts
        let computedV3Records: [RecordReference]
        let computed376Records: [RecordReference]
        let suppressedV3Records: [RecordReference]
        let suppressed376Records: [RecordReference]
        let admittedV3Records: [RecordReference]
        let admitted376Records: [RecordReference]
        var emittedV3Records: [RecordReference] = []
        var emitted376Records: [RecordReference] = []
        var notFoundAfterEmitV3Records: [RecordReference] = []
        var notFoundAfterEmit376Records: [RecordReference] = []
        let events: [Event]
        var finalized = false
        var finalIndividualCount: Int? = nil
        var GTAtInference = false
        var queryOwnershipUsedForMatching = false
    }
    struct Selection: Sendable {
        let v3Records: [G.Record]
        let records376: [G.Record]
        let proof: Proof
        /// Actual post-G.emit provenance establishes emission, not an unselected union.
        func finalized(actualOutput: [G.Individual]) -> Proof {
            let present = Set(actualOutput.flatMap(\.provenance).map { reference($0) })
            var result = proof
            result.emittedV3Records = proof.admittedV3Records.filter { present.contains($0) }
            result.emitted376Records = proof.admitted376Records.filter { present.contains($0) }
            result.notFoundAfterEmitV3Records = proof.admittedV3Records.filter { !present.contains($0) }
            result.notFoundAfterEmit376Records = proof.admitted376Records.filter { !present.contains($0) }
            result.counts.emittedV3 = result.emittedV3Records.count
            result.counts.emitted376 = result.emitted376Records.count
            result.finalized = true; result.finalIndividualCount = actualOutput.count
            return result
        }
    }
    private struct InputKey: Hashable {
        let ordinal: Int
        let polygon: [G.Point]
    }
    /// baseline is immutable and remains in the caller's final G.emit. Only actual
    /// V3 return records are removed; other heads/shared-quad provenance remain intact.
    static func select(requestID: String, baseline: [G.Individual],
                       v3: V3.Production, learned376: B376.Production, mode: Mode) -> Selection {
        let v3Refs = v3.records.map(reference), newRefs = learned376.records.map(reference)
        let oldOutputs = Dictionary(grouping: v3.records.indices.filter { v3.records[$0].origin == .corrected && canonical(v3.records[$0].polygon) != nil }, by: { v3Refs[$0] })
        let newOutputs = Dictionary(grouping: learned376.records.indices.filter { learned376.records[$0].origin == .corrected && canonical(learned376.records[$0].polygon) != nil }, by: { newRefs[$0] })
        var oldByInput: [InputKey: [Int]] = [:], newByInput: [InputKey: [Int]] = [:]
        for (index, decision) in v3.decisions.enumerated() {
            if let key = inputKey(requestID: requestID, proofRequest: decision.requestID,
                ordinal: decision.inputOrdinal, quad: decision.inputQuad,
                individualQuad: decision.inputIndividual.polygon, baseline: baseline) { oldByInput[key, default: []].append(index) }
        }
        for (index, decision) in learned376.decisions.enumerated() {
            if let key = inputKey(requestID: requestID, proofRequest: decision.requestID,
                ordinal: decision.inputOrdinal, quad: decision.inputQuad,
                individualQuad: decision.inputIndividual.polygon, baseline: baseline) { newByInput[key, default: []].append(index) }
        }
        var suppressOld = Set<Int>(), admitNew = Set<Int>(), attributableOld = Set<Int>()
        var events: [Event] = [], validPredictions = 0, unchangedPredictions = 0, invalidPredictions = 0
        if mode == .append { admitNew = Set(learned376.records.indices) }
        for decision in v3.decisions {
            guard let key = inputKey(requestID: requestID, proofRequest: decision.requestID,
                ordinal: decision.inputOrdinal, quad: decision.inputQuad,
                individualQuad: decision.inputIndividual.polygon, baseline: baseline), newByInput[key] != nil else { continue }
            if let index = outputIndex(requestID: requestID, outcomeCorrected: decision.outcome == .corrected,
                outputSourceIndex: decision.outputSourceIndex, outputAlternativeID: decision.outputAlternativeID,
                chosen: decision.chosenQuad, outputs: oldOutputs) { attributableOld.insert(index) }
        }
        for decision in learned376.decisions {
            let key = inputKey(requestID: requestID, proofRequest: decision.requestID,
                ordinal: decision.inputOrdinal, quad: decision.inputQuad,
                individualQuad: decision.inputIndividual.polygon, baseline: baseline)
            let changedIndex = outputIndex(requestID: requestID, outcomeCorrected: decision.outcome == .corrected,
                outputSourceIndex: decision.outputSourceIndex, outputAlternativeID: decision.outputAlternativeID,
                chosen: decision.chosenQuad, outputs: newOutputs)
            let alignedUnique = key.map { newByInput[$0]?.count == 1 } == true
            let unchanged = decision.outcome == .unchanged && decision.outputSourceIndex == nil &&
                decision.outputAlternativeID == nil && canonical(decision.chosenQuad) != nil &&
                canonical(decision.chosenQuad) == key?.polygon
            let changed = decision.outcome == .corrected && changedIndex != nil &&
                canonical(decision.chosenQuad) != key?.polygon
            let finiteResidual = decision.predictedResidual.map { $0.count == 5 && $0.allSatisfy(\.isFinite) } == true
            let valid = alignedUnique && (changed || unchanged) && finiteResidual && decision.featureDigest != nil &&
                decision.db32 != nil && decision.internalOfferCount == 1 && !decision.utilityInvoked &&
                decision.policy == B376.policy
            let available = decision.db32?.available
            var oldIndices: [Int] = [], oldJoinUnique = true
            if let key, let old = oldByInput[key] {
                oldJoinUnique = old.count == 1
                if old.count == 1 {
                    let proof = v3.decisions[old[0]]
                    if let index = outputIndex(requestID: requestID, outcomeCorrected: proof.outcome == .corrected,
                        outputSourceIndex: proof.outputSourceIndex, outputAlternativeID: proof.outputAlternativeID,
                        chosen: proof.chosenQuad, outputs: oldOutputs) { oldIndices = [index] }
                }
            }
            if valid { validPredictions += 1; if unchanged { unchangedPredictions += 1 } }
            else { invalidPredictions += 1 }
            var action = "append", reason = "default-append-keeps-computed-head-records", suppressed: [Int] = []
            if mode == .sourceMixture {
                if !valid {
                    action = "keep-v3-invalid376"
                    reason = alignedUnique ? "invalid376-or-output-proof-join" : "unaligned-or-duplicate376-input-proof"
                } else {
                    if let changedIndex { admitNew.insert(changedIndex) }
                    if available == true {
                        if oldJoinUnique {
                            suppressed = oldIndices
                            suppressOld.formUnion(oldIndices)
                            action = unchanged ? "baseline-unchanged-replaces-v3" : "available376-replaces-v3"
                            reason = oldIndices.isEmpty ? "no-attributable-v3-record-to-remove" : "exact-input-and-actual-v3-output-proof"
                        } else {
                            action = "keep-v3-ambiguous-output-proof"
                            reason = "multiple-v3-input-proofs-no-suppression"
                        }
                    } else {
                        action = "unavailable376-keeps-both"
                        reason = unchanged ? "376-is-existing-baseline-v3-kept" : "db32-unavailable-keep-v3-and376"
                    }
                }
            }
            let computedNew = changedIndex.map { [newRefs[$0]] } ?? []
            events.append(.init(requestID: decision.requestID, inputOrdinal: decision.inputOrdinal,
                inputQuad: decision.inputQuad, valid376: valid, unchanged376: valid && unchanged,
                db32Available: available, baselinePresent: key != nil, action: action, reason: reason,
                computedV3: oldIndices.map { v3Refs[$0] }, computed376: computedNew,
                suppressedV3: suppressed.map { v3Refs[$0] },
                admittedV3: oldIndices.filter { !suppressOld.contains($0) }.map { v3Refs[$0] },
                admitted376: changedIndex.flatMap { admitNew.contains($0) ? [newRefs[$0]] : nil } ?? []))
        }
        let old = v3.records.indices.filter { !suppressOld.contains($0) }
        let new = learned376.records.indices.filter { admitNew.contains($0) }
        let rejectedNew = learned376.records.indices.filter { !admitNew.contains($0) }
        let suppressedOld = v3.records.indices.filter { suppressOld.contains($0) }
        let proof = Proof(schema: schema, policy: mode.rawValue, requestID: requestID, baselineRows: baseline.count,
            counts: .init(computedV3: v3.records.count, computed376: learned376.records.count,
                suppressedV3: suppressedOld.count, suppressed376: rejectedNew.count,
                admittedV3: old.count, admitted376: new.count, unpredictedV3: v3.records.count - attributableOld.count,
                valid376Predictions: validPredictions, validUnchanged376: unchangedPredictions, invalidOrUnaligned376: invalidPredictions),
            computedV3Records: v3Refs, computed376Records: newRefs,
            suppressedV3Records: suppressedOld.map { v3Refs[$0] }, suppressed376Records: rejectedNew.map { newRefs[$0] },
            admittedV3Records: old.map { v3Refs[$0] }, admitted376Records: new.map { newRefs[$0] }, events: events)
        return .init(v3Records: old.map { v3.records[$0] }, records376: new.map { learned376.records[$0] }, proof: proof)
    }
    private static func inputKey(requestID: String, proofRequest: String, ordinal: Int, quad: [G.Point],
                                 individualQuad: [G.Point], baseline: [G.Individual]) -> InputKey? {
        guard requestID == proofRequest, baseline.indices.contains(ordinal),
              let current = canonical(baseline[ordinal].polygon), canonical(quad) == current,
              canonical(individualQuad) == current else { return nil }
        return .init(ordinal: ordinal, polygon: current)
    }
    private static func outputIndex(requestID: String, outcomeCorrected: Bool, outputSourceIndex: Int?,
                                    outputAlternativeID: String?, chosen: [G.Point], outputs: [RecordReference: [Int]]) -> Int? {
        guard outcomeCorrected, let sourceIndex = outputSourceIndex, let alternative = outputAlternativeID,
              let polygon = canonical(chosen) else { return nil }
        let tag = RecordReference(requestID: requestID, sourceIndex: sourceIndex, alternativeID: alternative, polygon: polygon)
        let matches = outputs[tag] ?? []
        return matches.count == 1 ? matches[0] : nil
    }
    private static func reference(_ record: G.Record) -> RecordReference {
        .init(requestID: record.requestID, sourceIndex: record.sourceIndex, alternativeID: record.alternativeID,
            polygon: canonical(record.polygon) ?? record.polygon)
    }
    private static func canonical(_ q: [G.Point]) -> [G.Point]? {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let turns = (0..<4).map { i -> Double in
            let a = q[i], b = q[(i+1)%4], c = q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 }) else { return nil }
        let points = q.map { G.Point(x: $0.x == 0 ? 0 : $0.x, y: $0.y == 0 ? 0 : $0.y) }
        func less(_ a: [G.Point], _ b: [G.Point]) -> Bool {
            for i in 0..<4 { if a[i] != b[i] { return a[i].x == b[i].x ? a[i].y < b[i].y : a[i].x < b[i].x } }
            return false
        }
        var best = points
        for start in 0..<4 { for direction in [-1, 1] {
            let order = (0..<4).map { points[(start + direction * $0 + 4) % 4] }
            if less(order, best) { best = order }
        } }
        return best
    }
}
