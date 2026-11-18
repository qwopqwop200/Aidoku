import Foundation

/// Fixed positive-corroboration admission for geometry proposals, not OCR lines.
/// Witnesses are distinct producer families and distinct exact quads, without a
/// claim of statistically independent observations. Query ancestry is not used.
enum NativeOCRGeometryWitnessAdmission {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias D = NativeOCRGeometryDeduplication
    static let environmentKey = "AIDOKU_OCR_GEOMETRY_WITNESS_ADMISSION"
    // Bounded near-equivalence: both distinct retained producer witnesses must
    // overlap directly; no transitive neighbor or source identity substitution.
    static let polygonIoUThreshold = 0.90
    private static let anchors: Set<String> = ["corrected", "original", "layout"]

    struct Witness: Codable, Equatable, Sendable {
        /// Index in the original input, never an index in the filtered output.
        let inputIndex: Int
        let polygonIoU: Double
        /// One producer family absent from the removed candidate's families.
        let producerFamilyID: String
        let bboxConfidence: Double
    }
    struct Replacement: Codable, Equatable, Sendable {
        let inputIndex: Int
        let bboxConfidence: Double
        let firstWitness: Witness
        let secondWitness: Witness
    }
    struct Report: Codable, Equatable, Sendable {
        let inputCount: Int
        let keptIndices: [Int]
        /// Exactly two direct, retained witnesses per removed proposal.
        let replacements: [Replacement]
        let anchorKeptIndices: [Int]
        /// Missing/nonfinite DB or unavailable polygon evidence stays retained.
        let missingEvidenceKeptIndices: [Int]
        let polygonIoUThreshold: Double
    }
    struct Result: Sendable {
        let output: G.Output
        let report: Report
    }
    private struct Neighbor {
        let index: Int
        let iou: Double
    }
    private struct Support {
        let index: Int
        let iou: Double
        let families: [String]
    }

    /// Same unprefixed producer vocabulary as the fixed Python reference.
    static func producerFamilies(_ row: G.Individual) -> Set<String> {
        Set(row.provenance.map { record in
            let parts = record.alternativeID.split(separator: "/", omittingEmptySubsequences: false)
            if parts.first == "source-paint", parts.count > 3 { return String(parts[3]) }
            return parts.first.map(String.init) ?? ""
        })
    }

    /// Exact cyclic/winding identity, with no rounding or coordinate changes.
    private static func quadKey(_ polygon: [G.Point]) -> [G.Point] {
        guard !polygon.isEmpty else { return [] }
        func less(_ first: [G.Point], _ second: [G.Point]) -> Bool {
            for (a, b) in zip(first, second) where a != b {
                return a.x == b.x ? a.y < b.y : a.x < b.x
            }
            return false
        }
        var best = polygon
        for winding in [polygon, Array(polygon.reversed())] {
            for start in winding.indices {
                let rotated = Array(winding[start...]) + Array(winding[..<start])
                if less(rotated, best) { best = rotated }
            }
        }
        return best
    }

    /// Exact physical footprint covered by two directly retained quads. Producer
    /// diversity alone cannot resolve two observations with the same missing rim.
    static func corroboratedCoverage(_ candidate: D.Shape, _ first: D.Shape, _ second: D.Shape) -> Double {
        func signedArea(_ polygon: [G.Point]) -> Double {
            guard polygon.count >= 3 else { return 0 }
            let origin = polygon[0]
            return (1..<(polygon.count - 1)).reduce(0) { total, i in
                let a = polygon[i], b = polygon[i + 1]
                return total + (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
            } * 0.5
        }
        func clip(_ polygon: [G.Point], to boundary: [G.Point]) -> [G.Point] {
            let direction = signedArea(boundary) >= 0 ? 1.0 : -1.0
            var clipped = polygon
            for i in boundary.indices {
                let p = boundary[i], q = boundary[(i + 1) % boundary.count]
                func distance(_ r: G.Point) -> Double {
                    direction * ((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x))
                }
                let previous = clipped
                guard var start = previous.last else { return [] }
                var startDistance = distance(start)
                clipped.removeAll(keepingCapacity: true)
                for end in previous {
                    let endDistance = distance(end)
                    if (startDistance >= 0) != (endDistance >= 0) {
                        let fraction = startDistance / (startDistance - endDistance)
                        clipped.append(.init(x: start.x + fraction * (end.x - start.x),
                                             y: start.y + fraction * (end.y - start.y)))
                    }
                    if endDistance >= 0 { clipped.append(end) }
                    start = end
                    startDistance = endDistance
                }
            }
            return clipped
        }
        let firstIntersection = clip(candidate.polygon, to: first.polygon)
        let secondIntersection = clip(candidate.polygon, to: second.polygon)
        let tripleIntersection = clip(firstIntersection, to: second.polygon)
        let covered = abs(signedArea(firstIntersection)) + abs(signedArea(secondIntersection)) - abs(signedArea(tripleIntersection))
        return min(1, max(0, covered / candidate.area))
    }

    static func apply(_ input: G.Output, cancellationCheck: () throws -> Void = {}) throws -> Result {
        try cancellationCheck()
        let rows = input.individuals
        let shapes = rows.map { D.Shape($0.polygon) }
        let families = rows.map(producerFamilies)
        let anchor = families.map { !$0.isDisjoint(with: anchors) }
        // A finite measurement remains a measurement, including zero. This is
        // not a new score admission threshold and does not substitute OCR scores.
        let confidence = rows.map { row -> Double? in
            guard let value = row.bboxConfidence, value.isFinite else { return nil }
            return value
        }
        let geometryAvailable = shapes.map { $0.convex && $0.area.isFinite && $0.area > 0 }
        let keys = rows.map { quadKey($0.polygon) }
        var neighbors = Array(repeating: [Neighbor](), count: rows.count)
        // Bounds inside D accelerate exact polygon overlap only. Shape size,
        // pixels and source/query IDs never classify or reject a candidate.
        for i in rows.indices {
            try cancellationCheck()
            guard geometryAvailable[i], i + 1 < rows.count else { continue }
            for j in (i + 1)..<rows.count where geometryAvailable[j] {
                if j % 256 == 0 { try cancellationCheck() }
                let iou = D.intersectionIoU(shapes[i], shapes[j], minimum: polygonIoUThreshold)
                if iou >= polygonIoUThreshold {
                    neighbors[i].append(.init(index: j, iou: iou))
                    neighbors[j].append(.init(index: i, iou: iou))
                }
            }
        }
        let ranked = rows.indices.sorted {
            let first = confidence[$0] ?? -.infinity, second = confidence[$1] ?? -.infinity
            return first == second ? $0 < $1 : first > second
        }
        var kept = anchor
        var replacements: [Replacement] = []
        for index in ranked {
            try cancellationCheck()
            if anchor[index] { continue }
            guard let score = confidence[index], geometryAvailable[index] else {
                kept[index] = true
                continue
            }
            let supporters = neighbors[index].compactMap { neighbor -> Support? in
                let other = neighbor.index
                guard kept[other], let measured = confidence[other], measured >= score else { return nil }
                let otherFamilies = families[other].subtracting(families[index]).sorted()
                guard !otherFamilies.isEmpty else { return nil }
                return .init(index: other, iou: neighbor.iou, families: otherFamilies)
            }
            // The Python condition is union(other families).count >= 2 and
            // distinct quad count >= 2. The following finds a concrete pair
            // proving exactly that condition; it adds no eligibility criterion.
            var witnesses: (Witness, Witness)?
            for first in supporters {
                try cancellationCheck()
                for second in supporters where second.index > first.index && keys[first.index] != keys[second.index] {
                    for firstFamily in first.families {
                        guard let secondFamily = second.families.first(where: { $0 != firstFamily }) else { continue }
                        witnesses = (.init(inputIndex: first.index, polygonIoU: first.iou,
                            producerFamilyID: firstFamily, bboxConfidence: confidence[first.index]!),
                            .init(inputIndex: second.index, polygonIoU: second.iou,
                            producerFamilyID: secondFamily, bboxConfidence: confidence[second.index]!))
                        break
                    }
                    if witnesses != nil { break }
                }
                if witnesses != nil { break }
            }
            if let witnesses {
                replacements.append(.init(inputIndex: index, bboxConfidence: score,
                    firstWitness: witnesses.0, secondWitness: witnesses.1))
            } else { kept[index] = true }
        }
        let indices = rows.indices.filter { kept[$0] }
        return .init(output: G.selecting(input, indices: indices), report: .init(inputCount: rows.count,
            keptIndices: indices, replacements: replacements, anchorKeptIndices: rows.indices.filter { anchor[$0] },
            missingEvidenceKeptIndices: rows.indices.filter { confidence[$0] == nil || !geometryAvailable[$0] },
            polygonIoUThreshold: polygonIoUThreshold))
    }
}
