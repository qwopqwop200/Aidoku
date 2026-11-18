import Foundation

@main enum PhysicalPaintSupportSmoke {
    typealias P = NativeOCRPhysicalPaintSupport
    static func quad(_ left: Double = 0, _ right: Double = 100) -> [P.Point] {
        [.init(x: left, y: 0), .init(x: right, y: 0), .init(x: right, y: 100), .init(x: left, y: 100)]
    }
    static func row(
        _ polygon: [P.Point], quality: Double? = 0.9, physical: Bool = true,
        halo: Bool = false, complete: Bool = false
    ) -> P.Candidate {
        .init(
            polygon: polygon, quality: quality, bboxConfidence: 0.8, detector: 0.8,
            recognition: 0.8, rfText: 0.8, physical: physical, halo: halo, completeInk: complete, family: "unit")
    }
    static func select(_ rows: [P.Candidate], fullRun: Bool = false, queries: Int = 300) -> P.Output {
        let component = P.Component(
            token: "measured", mapWidth: 100, mapHeight: 100,
            sourceWidth: 100, sourceHeight: 100,
            runs: [.init(x: fullRun ? 0 : 20, y: 50, count: fullRun ? 100 : 60)])
        let input = P.Input(
            sourceSHA256: "source", fullReferenceSHA256: "reference", fullReferenceCount: rows.count,
            components: [component], rf: [], rfAllQueries: queries, candidates: rows,
            finalIndices: Array(rows.indices), admittedIndices: [], selectedIndices: [])
        return P.Bank(input).select(indices: Array(rows.indices))
    }
    static func main() {
        let compressed = select([row(quad()), row(quad(2), quality: 0.8)])
        precondition(compressed.kept == [0] && compressed.replacements.count == 1)
        precondition(
            compressed.replacements.allSatisfy {
                compressed.kept.contains($0.witnessIndex) && $0.exactCCCellCover && $0.haloPreserved
            })
        // The same CC identity does not prove coverage of a different pixel lane.
        precondition(select([row(quad(1, 99)), row(quad(-1, 101), quality: 0.8)], fullRun: true).kept == [0, 1])
        precondition(select([row(quad()), row(quad(-2, 102), quality: 0.8, halo: true)]).kept == [0, 1])
        precondition(select([row(quad()), row(quad(2), quality: 0.8, complete: true)]).kept == [0, 1])
        precondition(select([row(quad()), row(quad(15, 85), quality: 0.8)]).kept == [0, 1])
        precondition(select([row(quad(), physical: false), row(quad(2), quality: 0.8)]).kept == [0, 1])
        precondition(select([row(quad()), row(quad(2), quality: nil)]).kept == [0, 1])
        precondition(select([row(quad()), row(quad(2), quality: 0.8)], queries: 299).kept == [0, 1])
        let tied = select([row(quad()), row(quad(2))])
        precondition(tied.kept == [0])
        print("PASS: direct overlap, exact CC-cell cover, outer stroke, physical eligibility, missing evidence and deterministic retained witnesses")
    }
}
