import Foundation

/// Optional source-only geometry policy. Four measured RF boundary scalars,
/// no learned head/165-vector/GT/text rule. Runtime activation remains separate.
enum NativeSimpleOCRBoundaryExpansion {
    static let policyVersion = "simple-measured-rf-boundary-expansion-v1"
    typealias G = NativeOCRIndividualGeometryHypotheses
    private typealias D = NativeOCRGeometryDeduplication

    struct Configuration: Codable, Equatable, Sendable {
        var threshold: Double = 0.3940652310848236
        var margin: Double = 0.025
    }
    struct BoundarySignals: Codable, Equatable, Sendable {
        let edge01: Double
        let edge12: Double
        let edge23: Double
        let edge30: Double
        var values: [Double] { [edge01, edge12, edge23, edge30] }
    }
    struct Correction: Codable, Equatable, Sendable {
        let sourceRow: Int
        let originalPolygon: [G.Point]
        let originalProvenance: [G.Record]
        let originalRefinements: [G.Refinement]
        let originalBBoxConfidence: Double?
        let newPolygon: [G.Point]
        let expandedEdges: [Int]
    }
    struct Report: Codable, Equatable, Sendable {
        let configuration: Configuration
        let inputCount: Int
        let signalRows: Int
        let corrections: [Correction]
        let abstainedRows: [Int]
    }
    struct Result: Sendable { let output: G.Output; let report: Report }
    enum Failure: Error { case invalidDimensions, invalidCandidate, signalBinding, invalidConfiguration }

    static func extract(input: G.Output, rf: NativeOCRSourceSupportFeatures155.PreparedRF,
                        sourceWidth: Int, sourceHeight: Int) throws -> [BoundarySignals] {
        guard sourceWidth > 0, sourceHeight > 0, rf.width == sourceWidth, rf.height == sourceHeight else { throw Failure.invalidDimensions }
        return try input.individuals.map { row in
            guard let values = NativeOCRSourceSupportFeatures155.boundaryTextOutsideMassFractions(
                rawPolygon: row.polygon.map { [$0.x, $0.y] }, sourceWidth: sourceWidth,
                sourceHeight: sourceHeight, rf: rf) else { throw Failure.invalidCandidate }
            return .init(edge01: Double(values[0]), edge12: Double(values[1]), edge23: Double(values[2]), edge30: Double(values[3]))
        }
    }

    static func apply(_ input: G.Output, signals: [BoundarySignals], configuration: Configuration) throws -> Result {
        guard signals.count == input.individuals.count else { throw Failure.signalBinding }
        guard configuration.threshold.isFinite, (0...1).contains(configuration.threshold),
              configuration.margin.isFinite, (0...0.1).contains(configuration.margin) else { throw Failure.invalidConfiguration }
        var output = input.individuals, corrections: [Correction] = [], abstained: [Int] = []
        for (index, row) in input.individuals.enumerated() {
            let shape = D.Shape(row.polygon)
            guard shape.convex, shape.area.isFinite, shape.area > 0, row.polygon.count == 4,
                  !row.provenance.isEmpty, row.provenance.allSatisfy({ $0.polygon == row.polygon }) else {
                abstained.append(index); continue
            }
            let edges = signals[index].values.indices.filter { side in
                let value = signals[index].values[side]
                return value.isFinite && value >= configuration.threshold
            }
            guard !edges.isEmpty, configuration.margin > 0 else { continue }
            let amount = (0..<4).map { edges.contains($0) ? configuration.margin : 0.0 }
            let p = row.polygon
            func point(_ u: Double, _ v: Double) -> G.Point {
                .init(x: p[0].x * (1-u) * (1-v) + p[1].x * u * (1-v) + p[2].x * u * v + p[3].x * (1-u) * v,
                      y: p[0].y * (1-u) * (1-v) + p[1].y * u * (1-v) + p[2].y * u * v + p[3].y * (1-u) * v)
            }
            let polygon = [point(-amount[3], -amount[0]), point(1+amount[1], -amount[0]),
                           point(1+amount[1], 1+amount[2]), point(-amount[3], 1+amount[2])]
            let expanded = D.Shape(polygon)
            guard expanded.convex, expanded.area.isFinite, expanded.area >= shape.area,
                  contains(polygon, points: row.polygon, tolerance: max(1, expanded.area) * 1e-10) else {
                abstained.append(index); continue
            }
            // Keep physical ancestry, but do not falsely label computed output
            // as an observed DET quad or retain an unmeasured bbox prediction.
            let provenance = row.provenance.map { record in
                G.Record(requestID: record.requestID, sourceIndex: record.sourceIndex,
                    sourceParent: record.sourceParent, sourceMembers: record.sourceMembers,
                    alternativeID: policyVersion + "/" + record.alternativeID, origin: .corrected,
                    originalDetectorIndex: nil, polygon: polygon)
            }
            output[index] = .init(polygon: polygon, provenance: provenance, refinements: [], bboxConfidence: nil)
            corrections.append(.init(sourceRow: index, originalPolygon: row.polygon, originalProvenance: row.provenance,
                originalRefinements: row.refinements, originalBBoxConfidence: row.bboxConfidence, newPolygon: polygon, expandedEdges: edges))
        }
        return .init(output: .init(mode: input.mode, individuals: output, counts: input.counts, events: input.events),
            report: .init(configuration: configuration, inputCount: input.individuals.count, signalRows: signals.count,
                corrections: corrections, abstainedRows: abstained))
    }

    private static func contains(_ polygon: [G.Point], points: [G.Point], tolerance: Double) -> Bool {
        points.allSatisfy { point in
            let crosses = (0..<4).map { i -> Double in
                let a = polygon[i], b = polygon[(i+1)%4]
                return (b.x-a.x)*(point.y-a.y) - (b.y-a.y)*(point.x-a.x)
            }
            return crosses.allSatisfy { $0 >= -tolerance } || crosses.allSatisfy { $0 <= tolerance }
        }
    }

}
