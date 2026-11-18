import Foundation

/// Suppresses only geometrically equivalent alternatives. Context/query ancestry
/// is not text membership; adjacent columns and containment alone never qualify.
enum NativeOCRGeometryDeduplication {
    typealias G = NativeOCRIndividualGeometryHypotheses
    static let environmentKey = "AIDOKU_OCR_GEOMETRY_DEDUP_IOU"
    static let defaultThreshold = 0.96
    enum Failure: Error { case invalidThreshold }

    struct Suppression: Codable, Sendable {
        let inputIndex: Int
        let representativeIndex: Int
        let polygonIoU: Double
        let sharedObservation: Bool
        var exactCyclicQuad: Bool? = nil
    }
    struct Report: Codable, Sendable {
        let enabled: Bool
        let threshold: Double
        let inputCount: Int
        let keptCount: Int
        let keptIndices: [Int]
        let suppressed: [Suppression]
        var ranking: Ranking = .confidence
        var probabilityPlateauTolerance: Double? = nil
        var normalDriftTolerance: Double? = nil
    }
    struct Result: Sendable {
        let output: G.Output
        let report: Report
    }

    static func configured(_ input: G.Output,
                           environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Result {
        let raw = environment[environmentKey]
        guard raw != nil || environment["AIDOKU_OCR_SOURCE_PAINT_GEOMETRY"] == "1" else {
            return .init(output: input, report: .init(enabled: false, threshold: defaultThreshold,
                inputCount: input.individuals.count, keptCount: input.individuals.count,
                keptIndices: Array(input.individuals.indices), suppressed: [], ranking: .evidenceMass))
        }
        let threshold: Double
        if let raw {
            guard let value = Double(raw) else { throw Failure.invalidThreshold }
            threshold = value
        } else { threshold = defaultThreshold }
        guard threshold.isFinite, threshold > 0, threshold <= 1 else {
            throw Failure.invalidThreshold
        }
        return apply(input, threshold: threshold, ranking: .evidenceMass)
    }

    struct Shape {
        let polygon: [G.Point]
        let area: Double
        fileprivate let winding: Double
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
        let convex: Bool
        let axisX: Double
        let axisY: Double
        let length: Double
        let width: Double
        init(_ polygon: [G.Point]) {
            self.polygon = polygon
            let signedArea = NativeOCRGeometryDeduplication.signedArea(polygon)
            area = abs(signedArea)
            winding = signedArea >= 0 ? 1 : -1

            var x0 = polygon.first?.x ?? 0, x1 = x0
            var y0 = polygon.first?.y ?? 0, y1 = y0
            for point in polygon.dropFirst() {
                if point.x < x0 { x0 = point.x }
                if point.x > x1 { x1 = point.x }
                if point.y < y0 { y0 = point.y }
                if point.y > y1 { y1 = point.y }
            }
            minX = x0; maxX = x1; minY = y0; maxY = y1

            if polygon.count == 4 && polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
                let a = polygon[0], b = polygon[1], c = polygon[2], d = polygon[3]
                let first = NativeOCRGeometryDeduplication.cross(a, b, c)
                let second = NativeOCRGeometryDeduplication.cross(b, c, d)
                let third = NativeOCRGeometryDeduplication.cross(c, d, a)
                let fourth = NativeOCRGeometryDeduplication.cross(d, a, b)
                convex = (first > 0 && second > 0 && third > 0 && fourth > 0)
                    || (first < 0 && second < 0 && third < 0 && fourth < 0)
            } else {
                convex = false
            }
            let first = polygon.count >= 3 ? (polygon[1].x - polygon[0].x, polygon[1].y - polygon[0].y) : (0, 0)
            let second = polygon.count >= 3 ? (polygon[2].x - polygon[1].x, polygon[2].y - polygon[1].y) : (0, 0)
            let firstLength = hypot(first.0, first.1), secondLength = hypot(second.0, second.1)
            let firstIsLonger = firstLength >= secondLength
            length = firstIsLonger ? firstLength : secondLength
            width = firstIsLonger ? secondLength : firstLength
            let axis = firstIsLonger ? first : second
            axisX = axis.0 / max(length, Double.leastNormalMagnitude)
            axisY = axis.1 / max(length, Double.leastNormalMagnitude)
        }
    }
    private static func signedArea(_ polygon: [G.Point]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        let origin = polygon[0]
        return (1..<(polygon.count-1)).reduce(0) { total, i in
            let a = polygon[i], b = polygon[i+1]
            return total + (a.x-origin.x)*(b.y-origin.y) - (a.y-origin.y)*(b.x-origin.x)
        } * 0.5
    }
    private static func area(_ polygon: [G.Point]) -> Double { abs(signedArea(polygon)) }
    private static func cross(_ a: G.Point, _ b: G.Point, _ p: G.Point) -> Double {
        (b.x-a.x)*(p.y-a.y) - (b.y-a.y)*(p.x-a.x)
    }
    static func polygonIoU(_ a: [G.Point], _ b: [G.Point]) -> Double {
        intersectionIoU(Shape(a), Shape(b), minimum: 0)
    }
    static func intersectionIoU(_ a: Shape, _ b: Shape, minimum: Double) -> Double {
        guard a.convex, b.convex, a.area > 0, b.area > 0, a.area.isFinite, b.area.isFinite,
              min(a.area, b.area) >= minimum * max(a.area, b.area) else { return 0 }
        let width = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard width > 0, height > 0 else { return 0 }
        let upper = min(width*height, min(a.area, b.area))
        guard upper >= minimum/(1+minimum)*(a.area+b.area) else { return 0 }
        var clipped = a.polygon
        var scratch: [G.Point] = []
        let direction = b.winding
        for i in b.polygon.indices {
            let p = b.polygon[i], q = b.polygon[(i+1) % b.polygon.count]
            guard let last = clipped.last else { return 0 }
            scratch.removeAll(keepingCapacity: true)
            var start = last
            var startDistance = direction*cross(p, q, start)
            for end in clipped {
                let endDistance = direction*cross(p, q, end)
                if (startDistance >= 0) != (endDistance >= 0) {
                    let fraction = startDistance/(startDistance-endDistance)
                    scratch.append(.init(x: start.x+fraction*(end.x-start.x), y: start.y+fraction*(end.y-start.y)))
                }
                if endDistance >= 0 { scratch.append(end) }
                start = end; startDistance = endDistance
            }
            swap(&clipped, &scratch)
        }
        let intersection = min(area(clipped), min(a.area, b.area))
        return intersection / max(Double.leastNormalMagnitude, a.area+b.area-intersection)
    }

    /// Only immutable producer-declared observations establish shared ownership.
    private static func observations(_ row: G.Individual) -> Set<String> {
        Set(row.provenance.flatMap { record -> [String] in
            let members = record.originalDetectorIndex.map { [$0] } ?? Array(record.sourceMembers)
            return members.map { "\(record.requestID)/\($0)" }
        })
    }

    /// Equality is exact, with no coordinate quantization. Only cyclic rotations
    /// and reversed winding are equivalent; malformed polygons never enter here.
    private static func exactKey(_ shape: Shape) -> [G.Point]? {
        guard shape.convex, shape.area.isFinite, shape.area > 0 else { return nil }
        let polygon = shape.polygon
        let start = polygon.indices.min {
            polygon[$0].x == polygon[$1].x ? polygon[$0].y < polygon[$1].y : polygon[$0].x < polygon[$1].x
        }!
        let forward = (0..<4).map { polygon[(start+$0) % 4] }
        let reverse = (0..<4).map { polygon[(start+4-$0) % 4] }
        for i in 1..<4 where forward[i] != reverse[i] {
            return forward[i].x == reverse[i].x
                ? (forward[i].y < reverse[i].y ? forward : reverse)
                : (forward[i].x < reverse[i].x ? forward : reverse)
        }
        return forward
    }

    enum Ranking: String, Codable { case confidence, smallerArea, largerArea, balancedEvidence, evidenceMass }

    static func apply(_ input: G.Output, threshold: Double, ranking: Ranking = .confidence,
                      probabilityPlateauTolerance: Double? = nil, normalDriftTolerance: Double = 0.025) -> Result {
        precondition(threshold.isFinite && threshold > 0 && threshold <= 1)
        let rows = input.individuals
        let shapes = rows.map { Shape($0.polygon) }
        let sources = rows.map(observations)
        // A score is evidence only, never a GT IoU estimate. Stable input order
        // resolves ties; missing scores cannot outrank measured confidence.
        let exponent = ranking == .balancedEvidence ? 0.5 : (ranking == .evidenceMass ? 1.0 : 0.0)
        let scores = rows.indices.map { index -> Double in
            guard let confidence = rows[index].bboxConfidence, confidence.isFinite,
                  shapes[index].convex, shapes[index].area.isFinite, shapes[index].area > 0 else { return -1 }
            return confidence * pow(shapes[index].area, exponent)
        }
        let ranked = rows.indices.sorted {
            if (ranking == .smallerArea || ranking == .largerArea), shapes[$0].area != shapes[$1].area {
                return ranking == .smallerArea ? shapes[$0].area < shapes[$1].area : shapes[$0].area > shapes[$1].area
            }
            let a = scores[$0], b = scores[$1]
            return a == b ? $0 < $1 : a > b
        }
        var selected: [Int] = []
        var suppressed: [Suppression] = []
        // Register retained rows only. Mapping through an already suppressed
        // member would silently turn direct NMS into transitive component collapse.
        var exactRepresentatives: [[G.Point]: Int] = [:]
        for index in ranked {
            guard scores[index] >= 0 else { selected.append(index); continue }
            let key = exactKey(shapes[index])
            if let key, let representative = exactRepresentatives[key] {
                suppressed.append(.init(inputIndex: index, representativeIndex: representative,
                    polygonIoU: 1, sharedObservation: !sources[index].isDisjoint(with: sources[representative]),
                    exactCyclicQuad: true))
                continue
            }
            var winner: (Int, Double, Bool)?
            // Prefer equivalent alternatives from the same declared observation,
            // then allow cross-detector duplicates with the SAME strict IoU gate.
            for sameSource in [true, false] {
                for representative in selected {
                    guard scores[representative] >= 0 else { continue }
                    let shared = !sources[index].isDisjoint(with: sources[representative])
                    guard shared == sameSource else { continue }
                    let iou = intersectionIoU(shapes[index], shapes[representative], minimum: threshold)
                    if iou >= threshold {
                        if let tolerance = probabilityPlateauTolerance, iou < 0.99,
                           let a = rows[index].bboxConfidence, let b = rows[representative].bboxConfidence,
                           abs(a-b) <= tolerance * max(abs(a), abs(b)) {
                            let first = shapes[index], second = shapes[representative]
                            // A coarse probability map cannot resolve tied evidence
                            // from differently oriented thin columns. Keep that
                            // geometric uncertainty instead of preferring area.
                            if first.length >= 2*first.width, second.length >= 2*second.width {
                                let sine = abs(first.axisX*second.axisY-first.axisY*second.axisX)
                                let drift = sine * max(first.length, second.length) /
                                    max(min(first.width, second.width), Double.leastNormalMagnitude)
                                if drift > normalDriftTolerance { continue }
                            }
                        }
                        winner = (representative, iou, shared); break
                    }
                }
                if winner != nil { break }
            }
            if let winner {
                suppressed.append(.init(inputIndex: index, representativeIndex: winner.0,
                    polygonIoU: winner.1, sharedObservation: winner.2))
            } else {
                selected.append(index)
                if let key { exactRepresentatives[key] = index }
            }
        }
        let kept = selected.sorted()
        return .init(output: G.selecting(input, indices: kept), report: .init(enabled: true,
            threshold: threshold, inputCount: rows.count, keptCount: kept.count,
            keptIndices: kept, suppressed: suppressed.sorted { $0.inputIndex < $1.inputIndex }, ranking: ranking,
            probabilityPlateauTolerance: probabilityPlateauTolerance,
            normalDriftTolerance: probabilityPlateauTolerance == nil ? nil : normalDriftTolerance))
    }
}
