import CoreGraphics
import Foundation

/// Feature-only exact geometric agreement. Never establishes or changes ownership.
enum NativeOCRGeometricBaselineAssociation {
    typealias G = NativeOCRIndividualGeometryHypotheses
    static let abi = "exact-coincident-corrected-baseline-agreement-v1"
    enum Relation: String, Codable, Sendable {
        case noObservedBaseline, uniqueGeometricAgreement, ambiguousDistinctBaselines, invalidQuery
    }
    struct Contributor: Codable, Sendable {
        let observedCorrectedRecord: G.Record
        let observedBaseline: [G.Point]
    }
    struct Proof: Codable, Sendable {
        let associationABI: String
        let requestID: String
        let queryQuad: [G.Point]
        let relation: Relation
        let contributors: [Contributor]
        let distinctBaselineGeometries: Int
        let auxiliaryBaseline: [G.Point]?
        let ownershipInferred: Bool
    }
    fileprivate struct Key: Hashable, Sendable { let points: [G.Point] }
    private struct Observation: Hashable {
        let requestID: String
        let sourceIndex: Int
        let alternativeID: String
        let observedQuad: Key
    }
    struct Index: Sendable {
        fileprivate let requestID: String
        fileprivate let byObservedQuad: [Key: [Contributor]]
        func association(for query: [G.Point]) -> Proof {
            guard let key = NativeOCRGeometricBaselineAssociation.key(query) else {
                return .init(associationABI: abi, requestID: requestID, queryQuad: query,
                    relation: .invalidQuery, contributors: [], distinctBaselineGeometries: 0,
                    auxiliaryBaseline: nil, ownershipInferred: false)
            }
            let contributors = byObservedQuad[key] ?? []
            let distinct = Set(contributors.compactMap { NativeOCRGeometricBaselineAssociation.key($0.observedBaseline) })
            let selected = distinct.count == 1 ? contributors.first.map {
                NativeOCRGeometricBaselineAssociation.canonicalPerimeter($0.observedBaseline)!
            } : nil
            return .init(associationABI: abi, requestID: requestID, queryQuad: query,
                relation: distinct.isEmpty ? .noObservedBaseline : distinct.count == 1 ? .uniqueGeometricAgreement : .ambiguousDistinctBaselines,
                contributors: contributors, distinctBaselineGeometries: distinct.count,
                auxiliaryBaseline: selected, ownershipInferred: false)
        }
    }
    /// Baselines must be the genuine producer endpointBases, never inferred from members/IoU.
    /// Group by the RECORD's observed quad, not the containing derived Individual's quad.
    static func build(requestID: String, input: [G.Individual], baselines: [Int: [CGPoint]]) -> Index {
        var groups: [Key: [Contributor]] = [:], seen = Set<Observation>()
        for individual in input {
            for record in individual.provenance {
                guard !requestID.isEmpty, record.requestID == requestID, record.origin == .corrected,
                      record.sourceIndex >= 0, record.alternativeID == "corrected/\(record.sourceIndex)",
                      let observedKey = key(record.polygon), let provided = baselines[record.sourceIndex] else { continue }
                let baseline = provided.map { G.Point(x: Double($0.x), y: Double($0.y)) }
                guard key(baseline) != nil else { continue }
                let observation = Observation(requestID: requestID, sourceIndex: record.sourceIndex,
                    alternativeID: record.alternativeID, observedQuad: observedKey)
                guard seen.insert(observation).inserted else { continue }
                groups[observedKey, default: []].append(.init(observedCorrectedRecord: record, observedBaseline: baseline))
            }
        }
        return .init(requestID: requestID, byObservedQuad: groups)
    }
    /// The sorted four points are a lookup key ONLY, never a perimeter or model polygon.
    private static func key(_ polygon: [G.Point]) -> Key? {
        guard valid(polygon) else { return nil }
        return .init(points: polygon.map(normalized).sorted(by: less))
    }
    /// Select lexicographically least of 4 rotations x 2 windings, retaining convex perimeter.
    static func canonicalPerimeter(_ polygon: [G.Point]) -> [G.Point]? {
        guard valid(polygon) else { return nil }
        let points = polygon.map(normalized)
        var best = points
        for start in 0..<4 {
            for direction in [-1, 1] {
                let order = (0..<4).map { points[(start + direction * $0 + 4) % 4] }
                if sequenceLess(order, best) { best = order }
            }
        }
        return best
    }
    private static func normalized(_ p: G.Point) -> G.Point {
        .init(x: p.x == 0 ? 0 : p.x, y: p.y == 0 ? 0 : p.y)
    }
    private static func less(_ a: G.Point, _ b: G.Point) -> Bool {
        a.x == b.x ? a.y < b.y : a.x < b.x
    }
    private static func sequenceLess(_ a: [G.Point], _ b: [G.Point]) -> Bool {
        for i in 0..<4 { if a[i] != b[i] { return less(a[i], b[i]) } }
        return false
    }
    private static func valid(_ q: [G.Point]) -> Bool {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1e7 && abs($0.y) < 1e7 }) else { return false }
        let turns = (0..<4).map { i -> Double in
            let a = q[i], b = q[(i+1)%4], c = q[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }
}
