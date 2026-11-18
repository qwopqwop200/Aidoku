import Foundation

/// Confidence/overlap summaries of distinct ORIGINAL detector observations.
/// Multiple observations from one detector are never described as independent models.
/// No image, recognition, RF mask, label or model APIs enter this helper.
enum NativeOCRPremergeDetectorAgreement {
    typealias Point = NativeOCRPremergeCandidateFeatures.Point

    struct Observation: Codable, Sendable {
        let polygon: [Point]
        let score: Double
        /// Page-local original detector seed groups. Derived unions carry ALL parent groups.
        /// A shared group always collapses observations, regardless of their current overlap.
        /// IDs are used for equality only and never emitted as numerical features.
        let sourceGroups: [Int]
    }

    struct Configuration: Sendable {
        var matchIoU: Double = 0.3
        var duplicateIoU: Double = 0.99
    }

    struct Statistics: Codable, Sendable {
        let currentCount: Int
        let referenceCount: Int
        /// A single member must match BOTH polygons; evidence from siblings is not combined.
        let jointCount: Int
        let bestSupport: Double
        let secondSupport: Double
        let bestConfidence: Double
        let secondConfidence: Double
        let bestCurrentIoU: Double
        let bestReferenceIoU: Double
        let secondCurrentIoU: Double
        let secondReferenceIoU: Double
        let bestSecondIoU: Double

        var featureVector: [Double] {
            [Double(currentCount), Double(referenceCount), Double(jointCount), bestSupport, secondSupport,
             bestConfidence, secondConfidence, bestCurrentIoU, bestReferenceIoU,
             secondCurrentIoU, secondReferenceIoU, bestSecondIoU]
        }

        /// Supplemental ABI: preserve raw counts above; cap and normalize only count slots.
        var supplementalFeatureVector: [Double] {
            var result = featureVector
            for index in 0..<3 { result[index] = min(result[index], 4) / 4 }
            return result
        }
    }

    static let featureNames = [
        "detOriginal_currentCount", "detOriginal_referenceCount", "detOriginal_jointCount",
        "detOriginal_bestSupport", "detOriginal_secondSupport", "detOriginal_bestConfidence", "detOriginal_secondConfidence",
        "detOriginal_bestCurrentIoU", "detOriginal_bestReferenceIoU", "detOriginal_secondCurrentIoU",
        "detOriginal_secondReferenceIoU", "detOriginal_bestSecondIoU"
    ]
    static let supplementalFeatureNames = featureNames.enumerated().map { index, name in
        index < 3 ? name + "Fraction" : name
    }
    static let maximumObservations = 4096

    /// Prepare once per page, before extracting statistics for individual candidates.
    /// Invalid/oversized evidence returns nil, never a fabricated zero-support result.
    struct Context: Sendable {
        private let observations: [Observation]
        private let geometry: [Polygon]
        private let groups: [[Int]]
        private let configuration: Configuration
        let usesExplicitSourceGroups: Bool
        var distinctOriginalGroupCount: Int { groups.count }

        init?(observations: [Observation], configuration: Configuration = .init()) {
            self.init(observations: observations, configuration: configuration, explicitGroups: true)
        }

        /// Fallback for an array known to contain ORIGINAL detections, not RF/lane proposals.
        /// Without lineage only polygon duplicates can be collapsed. Different shapes derived
        /// from the same seed cannot be identified here; use Observation for such inputs.
        init?(detectorBoxes: [NativeOCRPremergeCandidateFeatures.DetectorBox], configuration: Configuration = .init()) {
            guard detectorBoxes.count <= NativeOCRPremergeDetectorAgreement.maximumObservations else { return nil }
            self.init(observations: detectorBoxes.enumerated().map {
                Observation(polygon: $0.element.polygon, score: $0.element.score, sourceGroups: [$0.offset])
            }, configuration: configuration, explicitGroups: false)
        }

        private init?(observations: [Observation], configuration: Configuration, explicitGroups: Bool) {
            guard observations.count <= NativeOCRPremergeDetectorAgreement.maximumObservations,
                  configuration.matchIoU.isFinite, configuration.matchIoU > 0, configuration.matchIoU <= 1,
                  configuration.duplicateIoU.isFinite, configuration.duplicateIoU > 0, configuration.duplicateIoU <= 1 else { return nil }
            var polygons: [Polygon] = []
            for observation in observations {
                guard observation.score.isFinite, (0...1).contains(observation.score),
                      !observation.sourceGroups.isEmpty, observation.sourceGroups.count <= 64,
                      observation.sourceGroups.allSatisfy({ $0 >= 0 }),
                      let polygon = Polygon(observation.polygon) else { return nil }
                polygons.append(polygon)
            }
            var parents = Array(observations.indices)
            func root(_ value: Int) -> Int {
                var index = value
                while parents[index] != index { index = parents[index] }
                return index
            }
            func join(_ a: Int, _ b: Int) {
                let left = root(a), right = root(b)
                if left != right { parents[max(left, right)] = min(left, right) }
            }
            var owners: [Int: Int] = [:]
            for (index, observation) in observations.enumerated() {
                for key in observation.sourceGroups {
                    if let previous = owners[key] { join(index, previous) } else { owners[key] = index }
                }
            }
            for a in observations.indices {
                for b in 0..<a where root(a) != root(b) {
                    if polygons[a].iou(polygons[b]) >= configuration.duplicateIoU { join(a, b) }
                }
            }
            var members: [Int: [Int]] = [:]
            for index in observations.indices { members[root(index), default: []].append(index) }
            self.observations = observations
            self.geometry = polygons
            self.groups = members.keys.sorted().map { members[$0]! }
            self.configuration = configuration
            self.usesExplicitSourceGroups = explicitGroups
        }

        func extract(polygon: [Point], reference: [Point]? = nil) -> Statistics? {
            guard let current = Polygon(polygon), let original = Polygon(reference ?? polygon) else { return nil }
            struct Support {
                let index: Int
                let confidence: Double
                let current: Double
                let reference: Double
                var value: Double { confidence * min(current, reference) }
            }
            func preferred(_ left: Support, _ right: Support) -> Bool {
                if left.value != right.value { return left.value > right.value }
                if left.confidence != right.confidence { return left.confidence > right.confidence }
                if left.current != right.current { return left.current > right.current }
                if left.reference != right.reference { return left.reference > right.reference }
                return left.index < right.index
            }
            var currentCount = 0, referenceCount = 0
            var supports: [Support] = []
            for group in groups {
                var matchesCurrent = false, matchesReference = false
                var best: Support?
                for index in group {
                    let ci = current.iou(geometry[index]), ri = original.iou(geometry[index])
                    matchesCurrent = matchesCurrent || ci >= configuration.matchIoU
                    matchesReference = matchesReference || ri >= configuration.matchIoU
                    guard ci >= configuration.matchIoU, ri >= configuration.matchIoU else { continue }
                    let candidate = Support(index: index, confidence: observations[index].score, current: ci, reference: ri)
                    if best == nil || preferred(candidate, best!) { best = candidate }
                }
                if matchesCurrent { currentCount += 1 }
                if matchesReference { referenceCount += 1 }
                if let best { supports.append(best) }
            }
            supports.sort(by: preferred)
            let first = supports.first, second = supports.dropFirst().first
            let agreement: Double
            if let first, let second { agreement = geometry[first.index].iou(geometry[second.index]) } else { agreement = 0 }
            return Statistics(currentCount: currentCount, referenceCount: referenceCount, jointCount: supports.count,
                bestSupport: first?.value ?? 0, secondSupport: second?.value ?? 0,
                bestConfidence: first?.confidence ?? 0, secondConfidence: second?.confidence ?? 0,
                bestCurrentIoU: first?.current ?? 0, bestReferenceIoU: first?.reference ?? 0,
                secondCurrentIoU: second?.current ?? 0, secondReferenceIoU: second?.reference ?? 0, bestSecondIoU: agreement)
        }
    }

    /// Only area/intersection needed for permitted polygon overlap; no shape features.
    private struct Polygon: Sendable {
        let points: [Point]
        let area: Double
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double

        init?(_ points: [Point]) {
            guard (3...64).contains(points.count), points.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e7 && abs($0.y) <= 1e7
            }) else { return nil }
            let signed = Self.signedArea(points), sign = signed > 0 ? 1.0 : -1.0
            guard abs(signed) > 1e-9 else { return nil }
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                guard a != b else { return nil }
                for point in points where sign * Self.cross(a, b, point) < -1e-8 { return nil }
            }
            self.points = points; self.area = abs(signed)
            self.minX = points.map(\.x).min()!; self.minY = points.map(\.y).min()!
            self.maxX = points.map(\.x).max()!; self.maxY = points.map(\.y).max()!
        }

        func iou(_ other: Self) -> Double {
            guard min(maxX, other.maxX) > max(minX, other.minX),
                  min(maxY, other.maxY) > max(minY, other.minY) else { return 0 }
            var result = points
            let clip = other.points, sign = Self.signedArea(clip) > 0 ? 1.0 : -1.0
            for index in clip.indices {
                let a = clip[index], b = clip[(index + 1) % clip.count], input = result
                result = []
                if input.isEmpty { return 0 }
                for j in input.indices {
                    let p = input[j], q = input[(j + 1) % input.count]
                    let dp = sign * Self.cross(a, b, p), dq = sign * Self.cross(a, b, q)
                    if dp >= 0 { result.append(p) }
                    if (dp >= 0) != (dq >= 0) {
                        let t = dp / (dp - dq)
                        result.append(Point(x: p.x + t * (q.x - p.x), y: p.y + t * (q.y - p.y)))
                    }
                }
            }
            let overlap = max(0, min(Self.signedArea(result).magnitude, min(area, other.area)))
            return overlap / max(1e-12, area + other.area - overlap)
        }

        private static func cross(_ a: Point, _ b: Point, _ p: Point) -> Double {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        private static func signedArea(_ points: [Point]) -> Double {
            guard points.count >= 3 else { return 0 }
            var sum = 0.0
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                sum += a.x * b.y - b.x * a.y
            }
            return sum / 2
        }
    }
}
