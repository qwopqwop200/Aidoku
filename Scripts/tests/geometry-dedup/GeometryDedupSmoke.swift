import Foundation
@main enum GeometryDedupSmoke {
    typealias D = NativeOCRGeometryDeduplication
    typealias G = NativeOCRIndividualGeometryHypotheses
    static func quad(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [G.Point] {
        [.init(x: x, y: y), .init(x: x+w, y: y), .init(x: x+w, y: y+h), .init(x: x, y: y+h)]
    }
    static func output(_ polygons: [[G.Point]], scores: [Double?]) -> G.Output {
        let records = polygons.enumerated().map { index, polygon in
            G.Record(requestID: "observation", sourceIndex: index, sourceParent: 7,
                sourceMembers: [], alternativeID: "alternative/\(index)", origin: .corrected,
                originalDetectorIndex: nil, polygon: polygon)
        }
        let raw = G.emit(requestID: "observation", corrected: records, originals: [])
        return .init(mode: raw.mode, individuals: zip(raw.individuals, scores).map {
            .init(polygon: $0.0.polygon, provenance: $0.0.provenance, bboxConfidence: $0.1)
        }, counts: raw.counts, events: raw.events)
    }
    static func main() throws {
        let base = quad(0, 0, 10, 10)
        let smaller = quad(0.1, 0.1, 9.8, 9.8)
        let input = output([base, smaller], scores: [0.6, 0.61])
        let selected = try D.configured(input, environment: [D.environmentKey: "0.96"])
        precondition(selected.report.keptIndices == [0])
        precondition(selected.output.individuals == [input.individuals[0]])
        precondition(selected.output.counts.emittedIndividuals == 1)
        precondition(selected.report.suppressed[0].representativeIndex == 0)
        // Query-context equality MUST NOT be promoted into source membership.
        precondition(!selected.report.suppressed[0].sharedObservation)
        let adjacent = output([base, quad(11, 0, 10, 10), quad(1, 1, 8, 8)], scores: [0.7, 0.7, 0.9])
        precondition(D.apply(adjacent, threshold: 0.96).output.individuals.count == 3)
        let reversed = output([base, Array(base.reversed())], scores: [0.7, 0.7])
        precondition(D.apply(reversed, threshold: 0.96).report.keptIndices == [0])
        // Identical AABBs with different rotated ink columns are not duplicates.
        let a: [G.Point] = [.init(x: 0,y: 0), .init(x: 10,y: 10), .init(x: 11,y: 10), .init(x: 1,y: 0)]
        let b: [G.Point] = [.init(x: 0,y: 10), .init(x: 10,y: 0), .init(x: 11,y: 0), .init(x: 1,y: 10)]
        precondition(D.polygonIoU(a,b) < 0.1)
        precondition(D.apply(output([a,b], scores: [0.9,0.8]), threshold: 0.96).report.keptCount == 2)
        // Missing evidence and malformed geometry always survive unchanged.
        precondition(D.apply(output([base,base], scores: [nil,0.9]), threshold: 0.96).report.keptCount == 2)
        let concave: [G.Point] = [.init(x: 0,y: 0), .init(x: 10,y: 0), .init(x: 2,y: 2), .init(x: 0,y: 10)]
        precondition(D.apply(output([concave,concave], scores: [0.9,0.8]), threshold: 0.96).report.keptCount == 2)
        let disabled = try D.configured(input, environment: [:])
        precondition(!disabled.report.enabled && disabled.output.individuals == input.individuals)
        for raw in ["nan", "inf", "0", "1.1", "garbage"] {
            do { _ = try D.configured(input, environment: [D.environmentKey: raw]); preconditionFailure("invalid threshold accepted") }
            catch D.Failure.invalidThreshold { }
        }
        let empty = output([], scores: [])
        precondition(D.apply(empty, threshold: 0.96).report.keptCount == 0)
        print("PASS: evidence ranking, unchanged provenance, containment/adjacent/rotated separation, missing evidence, invalid geometry, deterministic ties, configuration, empty output")
    }
}
