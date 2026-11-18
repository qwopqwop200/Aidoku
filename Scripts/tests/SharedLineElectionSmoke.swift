import Foundation

// Host-only boundary types. Policy tests do not run OCR or RF feature extraction;
// the source-bound feature replay is verified separately against native fields.
enum NativeOCRIndividualGeometryHypotheses {
    struct Point: Codable, Hashable, Sendable { let x: Double; let y: Double }
    enum Origin: String, Codable, Sendable { case sourceOriginal, sourceLayout, sourceRefinement, corrected }
    struct Record: Codable, Equatable, Sendable {
        let requestID: String; let sourceIndex: Int; let sourceParent: Int; let sourceMembers: Set<Int>
        let alternativeID: String; let origin: Origin; let originalDetectorIndex: Int?; let polygon: [Point]
    }
    struct Individual: Codable, Sendable { let polygon: [Point]; let provenance: [Record]; var bboxConfidence: Double? = nil }
    struct Output: Codable, Sendable { let individuals: [Individual] }
    static func selecting(_ input: Output, indices: [Int]) -> Output { .init(individuals: indices.map { input.individuals[$0] }) }
}
enum NativeOCRRFSemanticAdmission {
    static func means(_ polygon: [NativeOCRIndividualGeometryHypotheses.Point], grid: NativeRFDETRSemanticGrid) -> [Double] {
        fatalError("Policy-only tests must not execute RF extraction")
    }
}

@available(iOS 18.0, *)
@main struct SharedLineElectionSmoke {
    typealias S = NativeOCRSharedLineElection
    typealias P = NativeOCRPhysicalPaintSupport
    static func box(_ x: Double, _ end: Double) -> [P.Point] {
        [.init(x: x, y: 0), .init(x: end, y: 0), .init(x: end, y: 3), .init(x: x, y: 3)]
    }
    static func policy(_ risk: Double, threshold: Double = 0.025, preserveWitnesses: Bool = false) throws -> S.Policy {
        let model: [String: Any] = ["schema": "numeric-hist-gradient-boost-v1", "bias": risk,
            "learningRate": 0.1, "featureNames": S.featureNames, "trees": []]
        let data = try JSONSerialization.data(withJSONObject: ["schema": "shared-line-evidence-uncertainty-v1",
            "riskThreshold": threshold, "models": Array(repeating: model, count: 5),
            "preserveMeasuredBoundaryWitnesses": preserveWitnesses])
        return try JSONDecoder().decode(S.Policy.self, from: data)
    }
    static func bank(_ polygons: [[P.Point]], disjoint: Bool = false, boundarySecond: Bool = false) -> P.Bank {
        let runs: [[P.Run]] = disjoint ? [[.init(x: 0, y: 1, count: 1)], [.init(x: 9, y: 1, count: 1)]]
            : [[.init(x: 4, y: 1, count: 4)]]
        let components = runs.enumerated().map { index, runs in
            P.Component(token: String(index), mapWidth: 12, mapHeight: 4, sourceWidth: 12, sourceHeight: 4, runs: runs)
        }
        let candidates = polygons.enumerated().map { index, polygon in
            P.Candidate(polygon: polygon, quality: 0.9 - Double(index) * 0.1, bboxConfidence: 0.5,
                detector: 0.8, recognition: 0.9, rfText: 0.5, physical: boundarySecond && index == 1,
                halo: boundarySecond && index == 1, completeInk: boundarySecond && index == 1,
                family: index == 0 ? "original" : "independent-correction")
        }
        return P.Bank(.init(sourceSHA256: "fixture", fullReferenceSHA256: "reference", fullReferenceCount: polygons.count,
            components: components, rf: [.init(canonicalClass: 1, confidence: 0.9, polygon: box(0, 12))], rfAllQueries: 300,
            candidates: candidates, finalIndices: Array(polygons.indices), admittedIndices: [], selectedIndices: []))
    }
    static func features(_ count: Int) -> [[Double]] {
        (0..<count).map { i in
            var row = [Double](repeating: 0.5, count: 17)
            row[7] = 0.9 - Double(i) * 0.1
            return row
        }
    }
    static func main() throws {
        let input = bank([box(0, 10), box(0, 11)])
        func run(_ risk: Double, valid: [Bool] = [true, true], recognition: [S.Observation] = []) throws -> S.Result {
            try S.select(bank: input, features: features(2), available: valid, detectors: [], recognition: recognition,
                         policy: policy(risk))
        }
        let elected = try run(0)
        let uncertain = try run(1)
        let missing = try run(0, valid: [true, false])
        precondition(elected.keptIndices == [0], "Cross-producer shared support should elect one boundary")
        precondition(uncertain.keptIndices == [0, 1], "Conflicting evidence must retain alternatives")
        precondition(missing.keptIndices == [0, 1], "Missing features must fail open")
        let observed = S.Observation(polygon: box(0, 11), confidence: 0.9)
        let restored = try run(0, recognition: [observed])
        precondition(restored.keptIndices == [0, 1], "Actual strongest OCR support must survive")
        let weak = S.Observation(polygon: box(0, 11), confidence: 0.4)
        let weakResult = try run(0, recognition: [weak])
        precondition(weakResult.keptIndices == [0])
        let measuredBoundary = try S.select(bank: bank([box(0, 10), box(0, 11)], boundarySecond: true),
            features: features(2), available: [true, true], detectors: [], recognition: [],
            policy: policy(0, preserveWitnesses: true))
        precondition(measuredBoundary.keptIndices == [0, 1])
        precondition(measuredBoundary.report.boundaryWitnessIndices == [1, 1], "Measured outer and complete-stroke witnesses must survive")
        let separate = bank([box(0, 8), box(2, 10)], disjoint: true)
        let separateResult = try S.select(bank: separate, features: features(2), available: [true, true],
            detectors: [], recognition: [], policy: policy(0))
        precondition(separateResult.keptIndices == [0, 1], "Overlapping boxes with disjoint strokes must remain separate")
        let chain = bank([box(0, 8), box(2, 10), box(4, 12)])
        let chainResult = try S.select(bank: chain, features: features(3), available: [true, true, true],
            detectors: [], recognition: [], policy: policy(0))
        precondition(chainResult.keptIndices == [0, 2], "An intermediate overlap must not merge separate end groups")
        let empty = try S.select(bank: bank([]), features: [], available: [], detectors: [], recognition: [], policy: policy(0))
        precondition(empty.keptIndices.isEmpty)
        do {
            _ = try run(0, valid: [true])
            preconditionFailure("Invalid alignment must be rejected")
        } catch S.Failure.invalidAlignment {}
        do {
            _ = try S.select(bank: input, features: features(2), available: [true, true], detectors: [], recognition: [],
                             policy: policy(0, threshold: -1))
            preconditionFailure("Invalid policy must be rejected")
        } catch S.Failure.invalidPolicy {}
        print("PASS: shared support, uncertainty, missing evidence, observed support, disjoint strokes, non-transitive grouping, empty input and policy guards")
    }
}
