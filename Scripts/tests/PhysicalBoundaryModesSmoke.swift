import Foundation

// Only the producer receipt interface is needed by this pure policy test.
enum NativeOCRSourcePaintGeometry {
    enum TerminalEvidence { case completeSourceInk }
    struct Measurement {
        let polygon: [[Double]]
        let diagnostics: [String: Double]
        let layer: String
        let terminalEvidence: TerminalEvidence?
    }
}

@main enum PhysicalBoundaryModesSmoke {
    typealias P = NativeOCRPhysicalPaintSupport
    typealias M = NativeOCRPhysicalBoundaryModePolicy
    static func q(_ left: Double = 0, _ right: Double = 100) -> [P.Point] {
        [.init(x: left, y: 0), .init(x: right, y: 0), .init(x: right, y: 100), .init(x: left, y: 100)]
    }
    static func row(_ polygon: [P.Point], quality: Double? = 0.9, physical: Bool = true, complete: Bool = false) -> P.Candidate {
        .init(polygon: polygon, quality: quality, bboxConfidence: 0.8, detector: 0.8,
              recognition: 0.8, rfText: 0.8, physical: physical, halo: false, completeInk: complete, family: "unit")
    }
    static func select(_ rows: [P.Candidate], _ roles: [M.Role]) -> P.Output {
        let component = P.Component(token: "measured", mapWidth: 100, mapHeight: 100, sourceWidth: 100, sourceHeight: 100,
                                    runs: [.init(x: 35, y: 50, count: 30)])
        let input = P.Input(sourceSHA256: "source", fullReferenceSHA256: "reference", fullReferenceCount: rows.count,
                            components: [component], rf: [], rfAllQueries: 300, candidates: rows,
                            finalIndices: Array(rows.indices), admittedIndices: [], selectedIndices: [])
        return M.select(bank: P.Bank(input), roles: roles)
    }
    static func role(_ contract: String, partition: Bool = false) -> M.Role {
        var r = M.Role()
        r.contracts = [contract]
        r.nonexclusivePartition = partition
        return r
    }
    static func main() {
        let rows = [row(q()), row(q(20, 80), quality: 0.8)]
        let inner = role("internal-ink-mass"), fixed = role("measured-normal-fixed-endpoints")
        let reduced = select(rows, [inner, fixed])
        precondition(reduced.kept == [0] && reduced.replacements.count == 1)
        precondition(reduced.replacements.allSatisfy { reduced.kept.contains($0.witnessIndex) && $0.exactCCCellCover })
        // Distinct physical extent contracts and uncertain partitions remain.
        precondition(select(rows, [inner, role("closed-paint-envelope")]).kept == [0, 1])
        precondition(select(rows, [inner, role("unknown")]).kept == [0, 1])
        precondition(select(rows, [inner, role("internal-ink-mass", partition: true)]).kept == [0, 1])
        precondition(select(rows, []).kept == [0, 1])
        precondition(select([row(q(), physical: false), rows[1]], [inner, fixed]).kept == [0, 1])
        precondition(select([row(q()), row(q(20, 80), quality: nil)], [inner, fixed]).kept == [0, 1])
        precondition(select([row(q(20, 80)), row(q(), quality: 0.8, complete: true)],
                            [role("complete-source-ink"), role("complete-source-ink")]).kept == [0, 1])
        let receipt = NativeOCRSourcePaintGeometry.Measurement(polygon: q().map { [$0.x, $0.y] },
            diagnostics: ["normalMassFraction": 0.9], layer: "fill", terminalEvidence: nil)
        precondition(M.roles(candidates: [rows[0]], measurements: [receipt])[0].boundaryMode == "inner-body")
        print("PASS: receipt-backed body modes, outer/complete boundary protection, uncertain partitions, missing evidence and direct retained witnesses")
    }
}
