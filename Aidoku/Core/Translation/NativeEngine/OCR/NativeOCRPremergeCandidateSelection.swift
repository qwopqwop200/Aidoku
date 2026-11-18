import Foundation

/// Source-only quality ranking and greedy duplicate suppression before paragraph assembly.
/// Models are global numeric parameters. No target inventory, page identifier or bbox ID is read.
struct NativeOCRPremergeCandidateSelection: Sendable {
    typealias Point = NativeOCRPremergeCandidateFeatures.Point

    struct Result: Sendable {
        let keep: [Bool]
        let qualityScores: [Double?]
        let rankScores: [Double?]
        let aliases: [(anchor: Int, removed: Int)]
    }

    private struct Ridge: Decodable, Sendable {
        let kind: String
        let mean: [Double]
        let scale: [Double]
        let coef: [Double]
        let bias: Double
        let featureNames: [String]
    }

    private enum Quality: Sendable {
        case ridge(Ridge)
        case boost(NativeOCRPremergeCandidateModel)

        init?(data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = object["kind"] as? String else { return nil }
            if kind == "ridge" {
                guard let q = try? JSONDecoder().decode(Ridge.self, from: data),
                      q.featureNames == NativeOCRPremergeCandidateModel.featureNames,
                      q.mean.count == 55, q.scale.count == 55, q.coef.count == 55,
                      q.mean.allSatisfy({ $0.isFinite && abs($0) <= 1e6 }),
                      q.coef.allSatisfy({ $0.isFinite && abs($0) <= 1e6 }),
                      q.scale.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1e6 }),
                      q.bias.isFinite, abs(q.bias) <= 1e6 else { return nil }
                self = .ridge(q)
            } else if kind == "boost" {
                guard Set(object.keys) == ["kind", "model", "featureNames"],
                      object["featureNames"] as? [String] == NativeOCRPremergeCandidateModel.featureNames,
                      let payload = object["model"] as? [String: Any],
                      let encoded = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
                let model = NativeOCRPremergeCandidateModel(data: encoded)
                guard model.isAvailable else { return nil }
                self = .boost(model)
            } else { return nil }
        }

        func score(_ vector: [Double]) -> Double? {
            switch self {
            case .ridge(let q):
                var value = q.bias
                for feature in 0..<55 where q.coef[feature] != 0 {
                    guard vector[feature].isFinite else { return nil }
                    let normalized = (vector[feature] - q.mean[feature]) / q.scale[feature]
                    value += normalized * q.coef[feature]
                }
                return value.isFinite ? value : nil
            case .boost(let model):
                let result = model.evaluate(features: vector)
                return result.failure == nil ? result.score : nil
            }
        }
    }

    private struct Configuration: Decodable, Sendable {
        let iou: Double
        let containment: Double
        let axis: Double
        let across: Double
        let along: Double
        let minContrastSamples: Double
        let minimumRecognitionConfidence: Double?
    }

    private struct Policy: Decodable, Sendable {
        let schema: String
        let qualityWeight: Double
        let contentWeight: Double
        let featureNames: [String]
        let config: Configuration
        let enabled: Bool?
    }

    private let quality: Quality?
    private let policy: Policy?
    var isAvailable: Bool { quality != nil && policy != nil }
    var usesOnlyFixedConfidenceAndIoU: Bool {
        guard case .ridge(let q)? = quality, let policy,
              ["source-confidence-iou-only-v1", "source-confidence-provenance-dedup-v2"].contains(policy.schema),
              policy.config.iou >= 0.99, policy.qualityWeight == 1,
              policy.config.minContrastSamples == 0, policy.contentWeight == 0,
              q.bias == 0, q.mean.allSatisfy({ $0 == 0 }), q.scale.allSatisfy({ $0 == 1 }) else { return false }
        return q.coef.enumerated().allSatisfy { index, value in value == ([9, 30].contains(index) ? 0.5 : 0) }
    }

    /// Explicit research replay may use a newly fitted quality ranker. These
    /// checks do not admit it as an app default or permit pixel/text features.
    var usesOnlyLearnedSignalQuality: Bool {
        guard case .ridge(let q)? = quality, let policy,
              policy.schema == "source-confidence-iou-only-v1", policy.qualityWeight == 1,
              policy.contentWeight == 0, policy.config.minContrastSamples == 0 else { return false }
        return q.coef.enumerated().allSatisfy { index, value in value == 0 || (8...30).contains(index) }
    }
    var usesOnlyPreRecognitionSignalQuality: Bool {
        guard usesOnlyLearnedSignalQuality, case .ridge(let q)? = quality else { return false }
        return q.coef[29] == 0 && q.coef[30] == 0
    }

    init(qualityData: Data?, policyData: Data?) {
        guard let qualityData, let policyData,
              qualityData.count <= NativeOCRPremergeCandidateModel.maximumModelBytes, policyData.count <= 65_536,
              let q = Quality(data: qualityData),
              let p = try? JSONDecoder().decode(Policy.self, from: policyData),
              p.featureNames == NativeOCRPremergeCandidateModel.featureNames,
              ["source-quality-content-minimal-pixel-global-v2", "source-confidence-iou-only-v1",
               "source-confidence-provenance-dedup-v2"].contains(p.schema),
              [p.qualityWeight, p.contentWeight].allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              p.qualityWeight + p.contentWeight > 0,
              [p.config.iou, p.config.containment, p.config.axis].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [p.config.across, p.config.along].allSatisfy({ $0.isFinite && (0...2).contains($0) }),
              p.config.minContrastSamples.isFinite, (0...2048).contains(p.config.minContrastSamples),
              p.config.minimumRecognitionConfidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true
        else { quality = nil; policy = nil; return }
        quality = q
        policy = p
    }

    init(qualityURL: URL, policyURL: URL) {
        func boundedRead(_ url: URL, limit: Int) -> Data? {
            guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: limit + 1)
        }
        self.init(qualityData: boundedRead(qualityURL, limit: NativeOCRPremergeCandidateModel.maximumModelBytes),
                  policyData: boundedRead(policyURL, limit: 65_536))
    }

    func select(polygons: [[Point]], features: [[Double]?],
                content: [NativeOCRPremergeCandidateModel.Decision], detectorProvenance: [Int?]? = nil) -> Result {
        let count = content.count
        var keep = content.map(\.keep)
        var qualityScores = Array<Double?>(repeating: nil, count: count)
        var rankScores = qualityScores
        guard let quality, let policy, policy.enabled != false, polygons.count == count, features.count == count else {
            return Result(keep: keep, qualityScores: qualityScores, rankScores: rankScores, aliases: [])
        }
        var geometry = Array<Geometry?>(repeating: nil, count: count)
        var contrast = Array(repeating: 0.0, count: count)
        for index in 0..<count where keep[index] && content[index].failure == nil && !content[index].punctuationPreserved {
            guard let vector = features[index], vector.count == 55,
                  let contentScore = content[index].score, contentScore.isFinite,
                  let g = Self.geometry(polygons[index]),
                  let value = quality.score(vector) else { continue }
            if let minimum = policy.config.minimumRecognitionConfidence,
               vector[29] != 1 || vector[30] < minimum { continue }
            let rank = policy.qualityWeight * value + policy.contentWeight * contentScore
            guard value.isFinite, rank.isFinite else { continue }
            qualityScores[index] = value
            rankScores[index] = rank
            geometry[index] = g
            // Reuse the existing 32x64 border-relative contrast probe; no second image raster.
            if policy.config.minContrastSamples > 0 {
                guard (0...1).contains(vector[51]) else { geometry[index] = nil; continue }
                contrast[index] = vector[51] * 2048
            }
        }
        let order = (0..<count).filter { rankScores[$0] != nil }.sorted {
            let left = rankScores[$0]!, right = rankScores[$1]!
            return left == right ? $0 < $1 : left > right
        }
        var pending = keep
        var aliases: [(anchor: Int, removed: Int)] = []
        for anchor in order {
            pending[anchor] = false
            guard keep[anchor], let a = geometry[anchor], contrast[anchor] >= policy.config.minContrastSamples else { continue }
            for removed in order where pending[removed] && keep[removed] {
                guard let b = geometry[removed], contrast[removed] >= policy.config.minContrastSamples,
                      Self.compatible(a, b, config: policy.config,
                                      onlyIoU: policy.schema != "source-quality-content-minimal-pixel-global-v2") else { continue }
                keep[removed] = false
                aliases.append((anchor, removed))
            }
        }
        // Optional second pass, never a relaxation of the existing baseline pass.
        // Provenance is the caller's page-local original detector observation index, not a
        // candidate/GT identifier. Missing, invalid or oversized groups preserve candidates.
        if policy.schema == "source-confidence-provenance-dedup-v2", usesOnlyFixedConfidenceAndIoU,
           let detectorProvenance, detectorProvenance.count == count {
            let baselineAnchors = Set(aliases.map(\.anchor))
            var groups: [Int: [Int]] = [:]
            for index in order where keep[index] {
                guard let observation = detectorProvenance[index], (0..<100_000).contains(observation),
                      let vector = features[index], vector[8] == 1, vector[29] == 1 else { continue }
                groups[observation, default: []].append(index)
            }
            // Traverse rank order globally so aliases remain deterministic across dictionary seeds.
            for anchor in order where keep[anchor] {
                guard let observation = detectorProvenance[anchor], let group = groups[observation],
                      group.count <= 64, let a = geometry[anchor], let av = features[anchor] else { continue }
                for removed in group where removed != anchor && keep[removed] && !baselineAnchors.contains(removed) {
                    guard let ar = rankScores[anchor], let br = rankScores[removed],
                          ar > br || (ar == br && anchor < removed),
                          let b = geometry[removed], let bv = features[removed],
                          Self.provenanceDominates(av, bv) else { continue }
                    let z = max(0, min(Self.intersection(a.polygon, b.polygon), min(a.area, b.area)))
                    guard z / max(1e-12, a.area + b.area - z) >= 0.9 else { continue }
                    keep[removed] = false
                    aliases.append((anchor, removed))
                }
            }
        }
        return Result(keep: keep, qualityScores: qualityScores, rankScores: rankScores, aliases: aliases)
    }

    /// Associate with the first best-overlapping ORIGINAL detector, exactly as source55
    /// extraction does. Supply baseline ?? current polygon for every candidate. No image,
    /// recognition text, RF class identity or corpus metadata is inspected here.
    static func detectorProvenance(references: [[Point]], detectorBoxes: [NativeOCRPremergeCandidateFeatures.DetectorBox]) -> [Int?] {
        guard detectorBoxes.count <= 100_000 else { return Array(repeating: nil, count: references.count) }
        let detectors = detectorBoxes.map { geometry($0.polygon) }
        guard detectors.allSatisfy({ $0 != nil }),
              detectorBoxes.allSatisfy({ $0.score.isFinite && (0...1).contains($0.score) }) else {
            return Array(repeating: nil, count: references.count)
        }
        return references.map { reference in
            guard let a = geometry(reference) else { return nil }
            var best = -Double.infinity
            var selected: Int?
            for (index, value) in detectors.enumerated() {
                guard let b = value else { continue }
                let z = max(0, min(intersection(a.polygon, b.polygon), min(a.area, b.area)))
                let overlap = z / max(1e-12, a.area + b.area - z)
                if overlap > best { best = overlap; selected = index }
            }
            return best >= 0.3 ? selected : nil
        }
    }

    private static func provenanceDominates(_ a: [Double], _ b: [Double]) -> Bool {
        let positive = [9, 10, 11, 12, 13, 21, 30]
        let negative = [17]
        guard (positive + negative).allSatisfy({
            a[$0].isFinite && b[$0].isFinite && (0...1).contains(a[$0]) && (0...1).contains(b[$0])
        }) else { return false }
        return positive.allSatisfy { a[$0] >= b[$0] } && negative.allSatisfy { a[$0] <= b[$0] }
    }

    private struct Geometry {
        let polygon: [Point]
        let area: Double
        let center: Point
        let axis: Point
        let normal: Point
        let long: Double
        let short: Double
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
    }

    private static func geometry(_ p: [Point]) -> Geometry? {
        guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e7 && abs($0.y) <= 1e7 }) else { return nil }
        var axis = Point(x: 0, y: 0), longest = -1.0
        var sign = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let turn = cross(a, b, c)
            guard abs(turn) > 1e-12 else { return nil }
            if sign == 0 { sign = turn }
            guard turn * sign > 0 else { return nil }
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            if length > longest { longest = length; axis = Point(x: dx, y: dy) }
        }
        guard longest > 1e-12 else { return nil }
        let norm = sqrt(longest)
        axis = Point(x: axis.x / norm, y: axis.y / norm)
        let normal = Point(x: -axis.y, y: axis.x)
        let along = p.map { dot($0, axis) }, across = p.map { dot($0, normal) }
        let long = along.max()! - along.min()!, short = across.max()! - across.min()!
        let area = abs(signedArea(p))
        guard area > 1e-9, long > 1e-9, short > 1e-9 else { return nil }
        return Geometry(polygon: p, area: area,
            center: Point(x: p.map(\.x).reduce(0, +) / 4, y: p.map(\.y).reduce(0, +) / 4),
            axis: axis, normal: normal, long: long, short: short,
            minX: p.map(\.x).min()!, minY: p.map(\.y).min()!, maxX: p.map(\.x).max()!, maxY: p.map(\.y).max()!)
    }

    private static func compatible(_ a: Geometry, _ b: Geometry, config: Configuration, onlyIoU: Bool) -> Bool {
        if onlyIoU {
            let z = max(0, min(intersection(a.polygon, b.polygon), min(a.area, b.area)))
            return z / max(1e-12, a.area + b.area - z) >= config.iou
        }
        guard min(a.maxX, b.maxX) > max(a.minX, b.minX), min(a.maxY, b.maxY) > max(a.minY, b.minY),
              min(abs(dot(a.axis, b.axis)), 1) >= config.axis else { return false }
        let delta = Point(x: b.center.x - a.center.x, y: b.center.y - a.center.y)
        guard max(abs(dot(delta, a.normal)) / a.short, abs(dot(delta, b.normal)) / b.short) <= config.across,
              max(abs(dot(delta, a.axis)) / a.long, abs(dot(delta, b.axis)) / b.long) <= config.along else { return false }
        let z = max(0, min(intersection(a.polygon, b.polygon), min(a.area, b.area)))
        return z / max(1e-12, a.area + b.area - z) >= config.iou &&
            z / max(1e-12, min(a.area, b.area)) >= config.containment
    }

    private static func dot(_ a: Point, _ b: Point) -> Double { a.x * b.x + a.y * b.y }
    private static func cross(_ a: Point, _ b: Point, _ p: Point) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }
    private static func signedArea(_ p: [Point]) -> Double {
        guard p.count >= 3 else { return 0 }
        var sum = 0.0
        for i in p.indices { let q = p[(i + 1) % p.count]; sum += p[i].x * q.y - q.x * p[i].y }
        return sum / 2
    }
    private static func intersection(_ polygon: [Point], _ clip: [Point]) -> Double {
        var result = polygon
        let sign = signedArea(clip) > 0 ? 1.0 : -1.0
        for i in clip.indices {
            let a = clip[i], b = clip[(i + 1) % clip.count], input = result
            result = []
            if input.isEmpty { return 0 }
            for j in input.indices {
                let p = input[j], q = input[(j + 1) % input.count]
                let dp = sign * cross(a, b, p), dq = sign * cross(a, b, q)
                if dp >= 0 { result.append(p) }
                if (dp >= 0) != (dq >= 0) {
                    let t = dp / (dp - dq)
                    result.append(Point(x: p.x + t * (q.x - p.x), y: p.y + t * (q.y - p.y)))
                }
            }
        }
        return abs(signedArea(result))
    }
}
