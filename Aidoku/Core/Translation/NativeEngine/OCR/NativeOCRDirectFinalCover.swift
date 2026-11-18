import Foundation

/// Final-only source-preserving direct NMS over existing emitted rows.
/// Scores must describe the exact input rows and stay fixed during selection.
/// No recomputation, source union, geometry synthesis or transitive replacement.
enum NativeOCRDirectFinalCover {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias D = NativeOCRGeometryDeduplication

    struct Configuration: Codable, Equatable, Sendable {
        var overlapThreshold: Double = 0.925
        // Optional controls keep decoding old threshold-only policies compatible.
        var adaptiveOverlapThreshold: Double? = 0.8
        var minimumQualityMargin: Double? = 0.1
        var boundaryTolerance: Double? = 0.2
    }
    struct Replacement: Codable, Equatable, Sendable {
        let inputIndex: Int
        let representativeIndex: Int
        let polygonIoU: Double
        var supportingIndices: [Int]? = nil
        var rule: String? = nil
    }
    struct Report: Codable, Equatable, Sendable {
        let inputCount: Int
        /// Original INPUT order, suitable for downstream aligned arrays.
        let keptIndices: [Int]
        let rankingOrder: [Int]
        let missingScoreKeptIndices: [Int]
        let replacements: [Replacement]
        let scoreAlignmentValid: Bool
        let configuration: Configuration
    }
    struct Result: Sendable { let output: G.Output; let report: Report }
    enum Failure: Error { case invalidThreshold }

    private struct Members: Hashable {
        let requestID: String
        let indices: [Int]
    }
    /// Compatibility only, never text ownership: parent-scoped unknown records
    /// still require the independent strict polygon-IoU and frozen-score gates.
    /// Explicit different member sets cannot suppress each other; no ancestry union.
    private static func lineage(_ row: G.Individual) -> Set<Members>? {
        guard !row.provenance.isEmpty else { return nil }
        var result = Set<Members>()
        for record in row.provenance {
            guard !record.requestID.isEmpty else { return nil }
            let members = record.sourceMembers.isEmpty ? [record.sourceParent] : record.sourceMembers.sorted()
            guard !members.isEmpty, members.allSatisfy({ $0 >= 0 }) else { return nil }
            result.insert(.init(requestID: record.requestID, indices: members))
        }
        return result
    }

    /// Immutable producer signature, independent of sourceIndex/parent numbering.
    /// Shared lineage is only compatibility; physical overlap remains mandatory.
    private static func producers(_ row: G.Individual) -> Set<String> {
        Set(row.provenance.compactMap { record in
            let parts = record.alternativeID.split(separator: "/")
            guard let first = parts.first else { return nil }
            if first == "source-paint" { return parts.count > 3 ? String(parts[3]) : nil }
            return String(first)
        })
    }

    private static func bounds(_ row: G.Individual) -> [Double] {
        [row.polygon.map(\.x).min() ?? .nan, row.polygon.map(\.y).min() ?? .nan,
         row.polygon.map(\.x).max() ?? .nan, row.polygon.map(\.y).max() ?? .nan]
    }

    /// Every measured boundary receives direct retained support. This only
    /// compares existing geometry; no union polygon or ancestry ownership exists.
    private static func boundarySupport(_ target: [Double], _ a: [Double], _ b: [Double], tolerance: Double) -> Bool {
        for edge in 0..<4 {
            let extent = edge % 2 == 0 ? target[2] - target[0] : target[3] - target[1]
            guard extent.isFinite, extent > 0,
                  min(abs(a[edge] - target[edge]), abs(b[edge] - target[edge])) <= tolerance * extent else { return false }
        }
        return true
    }

    static func apply(_ input: G.Output, frozenQualityScores: [Double?]?,
                      configuration: Configuration = .init(),
                      cancellationCheck: () throws -> Void = {}) throws -> Result {
        let threshold = configuration.overlapThreshold
        let adaptive = configuration.adaptiveOverlapThreshold ?? 0.8
        let margin = configuration.minimumQualityMargin ?? 0.1
        let tolerance = configuration.boundaryTolerance ?? 0.2
        guard adaptive.isFinite, adaptive > 0, adaptive <= 1,
              margin.isFinite, margin >= 0, tolerance.isFinite, tolerance >= 0, tolerance <= 1 else {
            throw Failure.invalidThreshold
        }
        guard threshold.isFinite, threshold > 0, threshold <= 1 else { throw Failure.invalidThreshold }
        let rows = input.individuals
        let aligned = frozenQualityScores?.count == rows.count
        let scores: [Double?] = aligned ? frozenQualityScores! : Array(repeating: nil, count: rows.count)
        let missing = rows.indices.filter { scores[$0]?.isFinite != true }
        let ranked = rows.indices.filter { scores[$0]?.isFinite == true }.sorted { a, b in
            if scores[a]! != scores[b]! { return scores[a]! > scores[b]! }
            let ac = rows[a].bboxConfidence.flatMap { $0.isFinite ? $0 : nil } ?? -.infinity
            let bc = rows[b].bboxConfidence.flatMap { $0.isFinite ? $0 : nil } ?? -.infinity
            return ac == bc ? a < b : ac > bc
        }
        let shapes = rows.map { D.Shape($0.polygon) }
        let sources = rows.map(lineage)
        let families = rows.map(producers), boxes = rows.map(bounds)
        var representatives = [Int](), replacements = [Replacement]()
        for i in ranked {
            try cancellationCheck()
            guard let source = sources[i], shapes[i].convex,
                  shapes[i].area.isFinite, shapes[i].area > 0 else {
                representatives.append(i); continue
            }
            var witness: (Int, Double)?
            var supporting = [(Int, Double)]()
            var rule = "strict-overlap"
            for j in representatives where sources[j] == source {
                let overlap = D.intersectionIoU(shapes[i], shapes[j], minimum: min(threshold, adaptive))
                if overlap >= threshold { witness = (j, overlap); break }
                // Missing confidence cannot establish dominance or consensus.
                guard overlap >= adaptive, let ci = rows[i].bboxConfidence, let cj = rows[j].bboxConfidence,
                      ci.isFinite, cj.isFinite, cj >= ci,
                      !families[i].isEmpty, !families[j].isEmpty else { continue }
                if scores[j]! - scores[i]! >= margin {
                    witness = (j, overlap); rule = "quality-confidence-dominance"; break
                }
                supporting.append((j, overlap))
            }
            var supportIDs: [Int]? = nil
            if witness == nil, supporting.count >= 2 {
                outer: for a in supporting.indices {
                    for b in supporting.indices where b > a {
                        let first = supporting[a], second = supporting[b]
                        guard families[first.0].isDisjoint(with: families[second.0]),
                              boundarySupport(boxes[i], boxes[first.0], boxes[second.0], tolerance: tolerance) else { continue }
                        witness = first; supportIDs = [first.0, second.0]
                        rule = "independent-boundary-support"; break outer
                    }
                }
            }
            if let witness {
                replacements.append(.init(inputIndex: i, representativeIndex: witness.0, polygonIoU: witness.1,
                    supportingIndices: supportIDs, rule: rule))
            } else { representatives.append(i) }
        }
        // Missing scores remain verbatim and do not suppress scored observations.
        let kept = (representatives + missing).sorted()
        return .init(output: G.selecting(input, indices: kept), report: .init(inputCount: rows.count,
            keptIndices: kept, rankingOrder: ranked, missingScoreKeptIndices: missing,
            replacements: replacements, scoreAlignmentValid: aligned, configuration: configuration))
    }
}
