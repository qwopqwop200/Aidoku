import Foundation

@main enum ConditionalLearnedEmissionSmoke {
    typealias A = NativeOCRConditionalLearnedEmission
    typealias G = NativeOCRIndividualGeometryHypotheses
    static func q(_ x: Double) -> [G.Point] {
        [.init(x: x, y: 0), .init(x: x + 20, y: 0), .init(x: x + 20, y: 100), .init(x: x, y: 100)]
    }
    static func bridge(_ polygon: [G.Point]) -> A.Quad { polygon.map { .init(x: $0.x, y: $0.y) } }
    static func main() {
        let id = "learned-boundary/frozen/original/0"
        let record = G.Record(requestID: "source", sourceIndex: 10, sourceParent: 0, sourceMembers: [0],
            alternativeID: id, origin: .corrected, originalDetectorIndex: nil, polygon: q(0.2))
        let original = G.Record(requestID: "source", sourceIndex: 0, sourceParent: 0, sourceMembers: [0],
            alternativeID: "original/0", origin: .sourceOriginal, originalDetectorIndex: 0, polygon: q(0))
        let decision = A.Decision(head: .legacy, outputAlternativeID: id, inputQuad: bridge(q(0)), chosenQuad: bridge(q(0.2)))
        let peer = A.Decision(head: .v2, outputAlternativeID: nil, inputQuad: bridge(q(0)), chosenQuad: bridge(q(0)))
        let observations = [A.Observation(polygon: bridge(q(0)), confidence: 0.8)]
        let enabled = ["AIDOKU_OCR_LEARNED_PROPOSAL_EMISSION": "reciprocal-computed-heads-v1"]
        func select(_ decisions: [A.Decision], _ detectors: [A.Observation], observed: [G.Record] = [original]) -> [G.Record] {
            A.emittedRecords([record], observed: observed, decisions: decisions, detectors: detectors, environment: enabled)
        }
        precondition(A.emittedRecords([record], observed: [original], decisions: [decision, peer],
            detectors: observations, environment: [:]) == [record])
        precondition(select([decision, peer], observations).isEmpty)
        // Unchanged independent head is valid agreement, but missing or ambiguous
        // head/source evidence cannot retire the only boundary.
        precondition(select([decision], observations) == [record])
        precondition(select([decision, decision, peer], observations) == [record])
        precondition(select([decision, peer], []) == [record])
        precondition(select([decision, peer], [.init(polygon: bridge(q(0)), confidence: 0.06)]) == [record])
        // An observed/paint producer at the same quad protects exact shared
        // provenance, even when the learned alternative would be redundant.
        let observed = G.Record(requestID: "source", sourceIndex: 1, sourceParent: 1, sourceMembers: [1],
            alternativeID: "source-paint/observed", origin: .corrected, originalDetectorIndex: nil, polygon: q(0.2))
        precondition(select([decision, peer], observations, observed: [original, observed]) == [record])
        let distantPeer = A.Decision(head: .v2, outputAlternativeID: nil, inputQuad: bridge(q(0)), chosenQuad: bridge(q(10)))
        precondition(select([decision, distantPeer], observations) == [record])
        precondition(record.polygon == q(0.2) && original.polygon == q(0))
        print("PASS: context-only reciprocal emission, unchanged independent head, missing/ambiguous evidence, observed-quad protection and immutable records")
    }
}
