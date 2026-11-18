import Foundation
import CoreGraphics

/// Current-source adapter for the explicit V3 fragment head. No replay files,
/// GT, recognition, image lookup, fitted layout prior or mutable global state.
/// The caller must preserve V2 output and invoke this only in the V3 path.
@available(iOS 18.0, *)
enum NativeOCRSourceFragmentGeometry {
    typealias Envelope = NativeOCRSourceFragmentEnvelope
    typealias Geometry = NativeOCRIndividualGeometryHypotheses

    enum RFKind: String, Sendable { case text, soundEffect }

    struct SourceRFBound: Sendable {
        let queryID: Int
        let bounds: CGRect
        let confidence: Double
        let kind: RFKind
    }

    struct SourceSeed: Codable, Equatable, Sendable {
        let sourceIndex: Int
        /// Exact input packet, not a fabricated polygon-filled seed inventory.
        let evidence: NativeOCRDetectorSeedEvidence
    }

    struct Completeness: Codable, Equatable, Sendable {
        let addedOwnedAlongSupport: Double
        let addedOwnedCells: Int
        let memberCount: Int
        let envelopeArea: Double
    }

    struct Evidence: Codable, Equatable, Sendable {
        let refinement: Geometry.Refinement
        let candidate: Envelope.Candidate
        let completeness: Completeness
        let sourceSeeds: [SourceSeed]
        let seedUnion: [NativeOCRDetectorSeedEvidence]
    }

    struct Production: Sendable {
        let evidence: [Evidence]
        let reasons: [String]
        var refinements: [Geometry.Refinement] { evidence.map(\.refinement) }
    }

    /// Exact parent-call interface. This is a source-owned diagnostic producer;
    /// gating is the caller's V3 mode, never recognition success or confidence.
    static func refinements(requestID: String, originals: [NativeCoreMLDetectionBox],
                            width: Int, height: Int) -> [Geometry.Refinement] {
        produce(requestID: requestID, originals: originals, width: width, height: height).refinements
    }

    /// Optional current-frame RF scopes annotate ownership evidence; they do not
    /// become a required RF/recognition gate for the initial source-owned pilot.
    static func produce(requestID: String, originals: [NativeCoreMLDetectionBox],
                        width: Int, height: Int, sourceRFBounds: [SourceRFBound] = []) -> Production {
        func abstain(_ reason: String) -> Production { .init(evidence: [], reasons: [reason]) }
        guard !requestID.isEmpty, requestID.utf8.count <= 256, width > 0, height > 0,
              width <= 131072, height <= 131072, !originals.isEmpty, originals.count <= 128 else {
            return abstain("invalid-frame-or-source-budget")
        }
        let token = requestID
        var members: [Envelope.Member] = []
        var packets: [Int: NativeOCRDetectorSeedEvidence] = [:]
        var counts: [Envelope.ComponentID: Int] = [:]
        var reasons = Set<String>()
        for (index, box) in originals.enumerated() {
            let polygon = box.polygon.map { Envelope.Point(x: Double($0.x), y: Double($0.y)) }
            // Uncertain owners still appear in members/blockers. They are never
            // removed because their decode, detector score or role is unknown.
            var components: [Envelope.Component] = []
            var complete = false
            if let seed = box.detectorSeedEvidence, seed.isValid,
               seed.sourceWidth == width, seed.sourceHeight == height {
                packets[index] = seed
                let grid = "fullgrid:\(seed.mapFullWidth)x\(seed.mapFullHeight):source\(width)x\(height)"
                let definite = seed.components.map { ($0, Envelope.Ownership.exclusive) }
                let uncertain = (seed.ambiguousComponents ?? []).map { ($0, Envelope.Ownership.ambiguous) }
                let competing = (seed.candidateComponents ?? []).map { ($0.component, Envelope.Ownership.ambiguous) }
                for (component, ownership) in definite + uncertain + competing {
                    let hull = ownedHull(component, seed: seed)
                    guard hull.count >= 3, hull.count <= 64 else {
                        reasons.insert("source-\(index)-component-hull-budget")
                        components = []
                        break
                    }
                    let id = Envelope.ComponentID(gridID: grid, ownerID: seed.ownerID, seed: component.seed)
                    components.append(.init(id: id, ownership: ownership, hull: hull))
                    counts[id] = component.pixelCount
                }
                complete = seed.ownershipVersion == 2 && seed.completeCCScan == true && !components.isEmpty
            } else {
                reasons.insert("source-\(index)-missing-invalid-or-cross-frame-seed")
            }
            // The array position is the live raw observation identity. Internal
            // seed.parentBoxIndex can be pre-sort numbering and is not lineage.
            members.append(.init(sourceIndex: index, sourceParent: index, frameToken: token, lineage: [index],
                polygon: polygon, completeSeedScan: complete, components: components))
        }
        let blockers = members.map { Envelope.Blocker(frameToken: token, lineage: $0.lineage, polygon: $0.polygon) }
        let scopes = sourceRFBounds.compactMap { bound -> Envelope.Scope? in
            guard bound.queryID >= 0, bound.confidence.isFinite, (0...1).contains(bound.confidence),
                  !bound.bounds.isNull, !bound.bounds.isInfinite,
                  bound.bounds.minX.isFinite, bound.bounds.minY.isFinite,
                  bound.bounds.maxX.isFinite, bound.bounds.maxY.isFinite else { return nil }
            let clipped = bound.bounds.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return .init(queryID: bound.queryID, frameToken: token, kind: bound.kind == .text ? .text : .soundEffect,
                confidence: bound.confidence, polygon: [
                    .init(x: Double(clipped.minX), y: Double(clipped.minY)),
                    .init(x: Double(clipped.maxX), y: Double(clipped.minY)),
                    .init(x: Double(clipped.maxX), y: Double(clipped.maxY)),
                    .init(x: Double(clipped.minX), y: Double(clipped.maxY))])
        }
        var output: [Evidence] = []
        for index in originals.indices {
            guard let basis = Basis(members[index].polygon) else { continue }
            let result = Envelope.propose(anchorSourceIndex: index, members: members, scopes: scopes,
                blockers: blockers, frameWidth: Double(width), frameHeight: Double(height), frameToken: token,
                mode: .replayOnly, scopePolicy: .sourceOwnedReplay)
            if result.candidates.isEmpty {
                result.reasons.forEach { reasons.insert("anchor-\(index):\($0)") }
                continue
            }
            let anchorIDs = Set(members[index].components.map(\.id))
            let scored = result.candidates.compactMap { candidate -> (Envelope.Candidate, Completeness)? in
                let proof = completeness(candidate, anchorIDs: anchorIDs, basis: basis, counts: counts)
                // Mere raw-box/context margin growth is not newly observed support.
                guard proof.addedOwnedAlongSupport > 1e-6 else { return nil }
                return (candidate, proof)
            }.sorted { preferred($0, over: $1) }
            // One deterministic eligible result per anchor/head, not a menu for
            // a later GT oracle. Failed native packet union tries the next result.
            for (candidate, proof) in scored {
                let ids = candidate.memberSourceIndices
                let sourceSeeds = ids.compactMap { source -> SourceSeed? in
                    packets[source].map { .init(sourceIndex: source, evidence: $0) }
                }
                guard sourceSeeds.count == ids.count,
                      let union = NativeOCRDetectorSeedEvidence.preservingUnion(sourceSeeds.map { [$0.evidence] }) else {
                    reasons.insert("anchor-\(index)-native-seed-union-unresolved")
                    continue
                }
                let record = Geometry.Record(requestID: requestID, sourceIndex: index, sourceParent: index,
                    sourceMembers: Set(ids), alternativeID: "source-fragment-v1/\(index)/members/" +
                        ids.map(String.init).joined(separator: ","),
                    origin: .sourceRefinement, originalDetectorIndex: index,
                    polygon: candidate.polygon.map { .init(x: $0.x, y: $0.y) })
                let refinement = Geometry.Refinement(head: .fragment, record: record)
                output.append(.init(refinement: refinement, candidate: candidate, completeness: proof,
                    sourceSeeds: sourceSeeds, seedUnion: union))
                break
            }
        }
        return .init(evidence: output, reasons: reasons.sorted())
    }

    /// RLE runs are already FULL detector-grid coordinates. mapOrigin must not
    /// be added again. Every actual cell-boundary extremum contributes to hull.
    private static func ownedHull(_ component: NativeOCRDetectorSeedEvidence.Component,
                                  seed: NativeOCRDetectorSeedEvidence) -> [Envelope.Point] {
        let sx = Double(seed.sourceWidth) / Double(seed.mapFullWidth)
        let sy = Double(seed.sourceHeight) / Double(seed.mapFullHeight)
        let corners = component.runs.flatMap { run -> [Envelope.Point] in
            let left = Double(run.x) * sx, right = Double(run.x + run.count) * sx
            let top = Double(run.y) * sy, bottom = Double(run.y + 1) * sy
            return [.init(x: left, y: top), .init(x: right, y: top),
                    .init(x: right, y: bottom), .init(x: left, y: bottom)]
        }.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var unique: [Envelope.Point] = []
        for point in corners where unique.last != point { unique.append(point) }
        guard unique.count > 2 else { return unique }
        func cross(_ a: Envelope.Point, _ b: Envelope.Point, _ c: Envelope.Point) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lower: [Envelope.Point] = [], upper: [Envelope.Point] = []
        for point in unique {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        for point in unique.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    private struct Basis {
        let origin: Envelope.Point
        let along: Envelope.Point
        let start: Double
        let end: Double
        init?(_ polygon: [Envelope.Point]) {
            guard polygon.count == 4 else { return nil }
            let edges = polygon.indices.map { i in
                Envelope.Point(x: polygon[(i + 1) % 4].x - polygon[i].x,
                               y: polygon[(i + 1) % 4].y - polygon[i].y)
            }
            guard let edge = edges.max(by: { hypot($0.x, $0.y) < hypot($1.x, $1.y) }) else { return nil }
            let length = hypot(edge.x, edge.y)
            guard length.isFinite, length > 0 else { return nil }
            let sign = edge.y > 1e-9 || (abs(edge.y) <= 1e-9 && edge.x >= 0) ? 1.0 : -1.0
            origin = polygon[0]
            let direction = Envelope.Point(x: sign * edge.x / length, y: sign * edge.y / length)
            along = direction
            let projected = polygon.map { ($0.x - polygon[0].x) * direction.x + ($0.y - polygon[0].y) * direction.y }
            start = projected.min()!; end = projected.max()!
        }
        func project(_ point: Envelope.Point) -> Double {
            (point.x - origin.x) * along.x + (point.y - origin.y) * along.y
        }
    }

    private static func completeness(_ candidate: Envelope.Candidate, anchorIDs: Set<Envelope.ComponentID>,
                                     basis: Basis, counts: [Envelope.ComponentID: Int]) -> Completeness {
        var spans: [(Double, Double)] = []
        for component in candidate.members.flatMap(\.components) {
            let projected = component.hull.map(basis.project)
            guard let lo = projected.min(), let hi = projected.max() else { continue }
            if lo < basis.start { spans.append((lo, min(hi, basis.start))) }
            if hi > basis.end { spans.append((max(lo, basis.end), hi)) }
        }
        spans = spans.filter { $0.1 > $0.0 }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var support = 0.0, stop = -Double.infinity
        for span in spans {
            support += max(0, span.1 - max(span.0, stop)); stop = max(stop, span.1)
        }
        let newCells = candidate.componentIDs.filter { !anchorIDs.contains($0) }.reduce(0) { $0 + (counts[$1] ?? 0) }
        let polygon = candidate.polygon
        let area = abs(polygon.indices.reduce(0.0) { sum, i in
            let next = polygon[(i + 1) % polygon.count]
            return sum + polygon[i].x * next.y - next.x * polygon[i].y
        }) / 2
        return .init(addedOwnedAlongSupport: support, addedOwnedCells: newCells,
                     memberCount: candidate.memberSourceIndices.count, envelopeArea: area)
    }

    private static func preferred(_ a: (Envelope.Candidate, Completeness),
                                  over b: (Envelope.Candidate, Completeness)) -> Bool {
        // Subpixel quantization makes ties independent of negligible projection
        // roundoff while remaining source-only and completely deterministic.
        let first = Int64((a.1.addedOwnedAlongSupport * 1024).rounded())
        let second = Int64((b.1.addedOwnedAlongSupport * 1024).rounded())
        if first != second { return first > second }
        if a.1.addedOwnedCells != b.1.addedOwnedCells { return a.1.addedOwnedCells > b.1.addedOwnedCells }
        if a.1.memberCount != b.1.memberCount { return a.1.memberCount < b.1.memberCount }
        if a.1.envelopeArea != b.1.envelopeArea { return a.1.envelopeArea < b.1.envelopeArea }
        if a.0.memberSourceIndices != b.0.memberSourceIndices {
            return a.0.memberSourceIndices.lexicographicallyPrecedes(b.0.memberSourceIndices)
        }
        for (left, right) in zip(a.0.polygon, b.0.polygon) {
            if left.x != right.x { return left.x < right.x }
            if left.y != right.y { return left.y < right.y }
        }
        return false
    }
}
