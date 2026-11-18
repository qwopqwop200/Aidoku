import CoreGraphics
import Foundation

/// Pools actual original-frame reads, never text assembled from legacy owners.
/// Each observation retains its own plan, request and crop identifier.
enum NativeCausalRFAdaptiveSampling {
    typealias P = NativeCausalRFParagraphRecognition
    struct Sample: Equatable, Sendable {
        let requestID: String
        let plan: P.Plan
        let requestedColumns: [Int]
        let reads: [P.Read]
    }
    struct Reference: Equatable, Sendable {
        let sampleIndex: Int
        let cropIdentifier: Int
    }
    struct Pair: Equatable, Sendable {
        let column: Int
        let first: Reference
        let second: Reference
    }
    struct Evidence: Equatable, Sendable {
        let version: String
        let samples: [Sample]
        let selected: [Pair]
    }
    struct Request: Sendable {
        let plan: P.Plan
        let columns: [Int]
    }
    struct Result: Sendable {
        let correction: P.Correction?
        let samples: [Sample]
        let requestedCrops: Int
    }
    static var runtimeEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_PARAGRAPH_ADAPTIVE_SAMPLING"] == "1"
    }
    static let cacheVersion = "rf-original-adaptive-pairs-v175"

    static func resolve(plan: P.Plan, current: [P.Owner], imageSize: CGSize, policy: P.Policy,
                        cropBudget: Int = 24, enabled: Bool = false,
                        recognize: (Request) async throws -> Sample?) async throws -> Result {
        guard enabled, (4...24).contains(cropBudget), plan.crops.count <= cropBudget else {
            return Result(correction: nil, samples: [], requestedCrops: 0)
        }
        var request = Request(plan: plan, columns: Array(plan.centers.indices))
        var samples = [Sample](), used = 0
        while samples.count < 3 {
            try Task.checkCancellation()
            let count = request.plan.crops.filter { request.columns.contains($0.column) }.count
            guard used + count <= cropBudget else { break }
            used += count
            guard let sample = try await recognize(request), sample.plan == request.plan,
                  sample.requestedColumns == request.columns else { break }
            samples.append(sample)
            if let correction = accept(samples: samples, current: current, policy: policy, enabled: true) {
                return Result(correction: correction, samples: samples, requestedCrops: used)
            }
            guard let next = nextRequest(samples: samples, current: current, imageSize: imageSize,
                policy: policy, enabled: true) else { break }
            request = next
        }
        return Result(correction: nil, samples: samples, requestedCrops: used)
    }

    /// At most three contexts and 24 actual crops. Only unresolved columns are
    /// requested after the first complete pass. Existing source Y is never cut.
    static func nextRequest(samples: [Sample], current: [P.Owner], imageSize: CGSize,
                            policy: P.Policy, enabled: Bool = false) -> Request? {
        guard enabled, valid(samples, current: current, policy: policy), samples.count < 3,
              let first = samples.first else { return nil }
        let unresolved = first.plan.centers.indices.filter { pair(column: $0, samples: samples, policy: policy) == nil }
        guard !unresolved.isEmpty else { return nil }
        let fractions = samples.map { $0.plan.longitudinalSampling?.fraction ?? 0 }
        guard let fraction = [0.1, 0.2, 0].first(where: { !fractions.contains($0) }) else { return nil }
        let p = first.plan, centers = Array(p.centers.reversed()), scope = p.bounds
        guard samples.allSatisfy({ sample in
            sample.plan.longitudinalSampling.map {
                $0.canvasWidth == imageSize.width && $0.canvasHeight == imageSize.height
            } ?? true
        }) else { return nil }
        let sampling = fraction == 0 ? nil : NativeCausalRFLongitudinalSampling.evidence(
            fraction: fraction, centers: centers, canvas: imageSize, originals: p.originals, current: current)
        guard fraction == 0 || sampling != nil else { return nil }
        var cuts = [scope.minX]
        for i in 1..<centers.count { cuts.append((centers[i - 1] + centers[i]) / 2) }
        cuts.append(scope.maxX)
        var crops = [P.Crop]()
        for (column, i) in centers.indices.reversed().enumerated() {
            for variant in 0...1 {
                let pad = variant == 0 ? 0 : (cuts[i + 1] - cuts[i]) * 0.1
                let left = max(scope.minX, cuts[i] - pad), right = min(scope.maxX, cuts[i + 1] + pad)
                let base = CGRect(x: left, y: scope.minY, width: right - left, height: scope.height)
                let rect: CGRect
                if let sampling {
                    guard let padded = NativeCausalRFLongitudinalSampling.padded(base, source: scope, evidence: sampling)
                    else { return nil }
                    rect = padded
                } else { rect = base }
                crops.append(.init(identifier: column * 2 + variant, column: column, variant: variant,
                    polygon: [.init(x: rect.minX, y: rect.minY), .init(x: rect.maxX, y: rect.minY),
                        .init(x: rect.maxX, y: rect.maxY), .init(x: rect.minX, y: rect.maxY)]))
            }
        }
        let plan = P.Plan(sourceIdentity: p.sourceIdentity, queryID: p.queryID, originals: p.originals,
            primaryUnion: p.primaryUnion, bounds: scope, centers: p.centers, crops: crops, longitudinalSampling: sampling)
        guard P.completeGeometry(plan), samples.reduce(0, { $0 + $1.reads.count }) + unresolved.count * 2 <= 24 else { return nil }
        return Request(plan: plan, columns: unresolved)
    }

    static func accept(samples: [Sample], current: [P.Owner], policy: P.Policy,
                       enabled: Bool = false) -> P.Correction? {
        guard enabled, valid(samples, current: current, policy: policy), let first = samples.first else { return nil }
        var selected = [Pair](), columns = [String](), confidence = 1.0
        for column in first.plan.centers.indices {
            guard let choice = pair(column: column, samples: samples, policy: policy) else { return nil }
            let a = read(choice.first, samples: samples), b = read(choice.second, samples: samples)
            selected.append(choice)
            columns.append(a.confidence >= b.confidence ? a.text : b.text)
            confidence = min(confidence, a.confidence, b.confidence)
        }
        let source = columns.joined()
        guard source.utf16.count <= 2048 else { return nil }
        // plan/reads explicitly retain the FIRST actual request, even when it
        // failed. The separate adaptive receipt supplies every selected pair.
        var correction = P.Correction(plan: first.plan, source: source, columns: columns,
            reads: first.reads, confidence: confidence, acceptancePolicy: policy)
        correction.adaptiveSampling = Evidence(version: cacheVersion, samples: samples, selected: selected)
        return correction
    }

    private static func valid(_ samples: [Sample], current: [P.Owner], policy: P.Policy) -> Bool {
        guard !policy.requiresLiteralLegacySource, policy.punctuationOnlyConsensus,
              (policy.parameterGrid ? [0.75, 0.8, 0.85, 0.9] : [0.90, 0.925, 0.95]).contains(policy.minimumConfidence),
              (1...3).contains(samples.count), let first = samples.first,
              !policy.parameterGrid || first.plan.longitudinalSampling != nil,
              first.requestedColumns == Array(first.plan.centers.indices),
              Set(samples.map(\.requestID)).count == samples.count,
              Set(samples.map { $0.plan.longitudinalSampling?.fraction ?? 0 }).count == samples.count,
              samples.reduce(0, { $0 + $1.reads.count }) <= 24 else { return false }
        let original = first.plan, ids = Set(original.originals.map(\.id))
        guard original.sourceIdentity.hasPrefix("canonical-rgb8:"), current.count <= 256,
              current.filter({ !ids.contains($0.id) }).allSatisfy({ !$0.bounds.intersects(original.bounds) }) else { return false }
        for sample in samples {
            let plan = sample.plan
            guard UUID(uuidString: sample.requestID) != nil, P.completeGeometry(plan),
                  plan.sourceIdentity == original.sourceIdentity, plan.queryID == original.queryID,
                  plan.originals == original.originals, plan.primaryUnion == original.primaryUnion,
                  plan.bounds == original.bounds, plan.centers == original.centers,
                  plan.originals.allSatisfy({ owner in current.filter { $0.id == owner.id } == [owner] }),
                  !sample.requestedColumns.isEmpty, sample.requestedColumns == sample.requestedColumns.sorted(),
                  Set(sample.requestedColumns).count == sample.requestedColumns.count,
                  sample.requestedColumns.allSatisfy({ plan.centers.indices.contains($0) }) else { return false }
            if let sampling = plan.longitudinalSampling {
                guard NativeCausalRFLongitudinalSampling.matchesCurrent(sampling, originals: plan.originals, current: current)
                else { return false }
            }
            let crops = plan.crops.filter { sample.requestedColumns.contains($0.column) }
            guard crops.count == sample.reads.count, Set(sample.reads.map(\.identifier)).count == sample.reads.count else { return false }
            for crop in crops {
                guard let read = sample.reads.first(where: { $0.identifier == crop.identifier }), read.polygon == crop.polygon,
                      read.confidence.isFinite, (0...1).contains(read.confidence), !read.text.isEmpty,
                      read.text.utf16.count <= 512, !read.text.contains("\n\n"), !read.text.contains("\u{2029}") else { return false }
            }
        }
        return true
    }

    private static func read(_ reference: Reference, samples: [Sample]) -> P.Read {
        samples[reference.sampleIndex].reads.first { $0.identifier == reference.cropIdentifier }!
    }

    private static func pair(column: Int, samples: [Sample], policy: P.Policy) -> Pair? {
        var references = [Reference]()
        for (i, sample) in samples.enumerated() where sample.requestedColumns.contains(column) {
            for crop in sample.plan.crops where crop.column == column {
                references.append(.init(sampleIndex: i, cropIdentifier: crop.identifier))
            }
        }
        // Even an extra low-confidence lexical disagreement prevents pooling.
        // Dot runs alone may differ. Never select away contradictory words.
        let keys = references.map { P.dotComparisonKey(read($0, samples: samples).text) }
        guard let key = keys.first, keys.allSatisfy({ $0.utf8.elementsEqual(key.utf8) }) else { return nil }
        var best: Pair?, bestFloor = -1.0, bestSum = -1.0
        for i in references.indices { for j in references.indices where j > i {
            let a = read(references[i], samples: samples), b = read(references[j], samples: samples)
            let floor = min(a.confidence, b.confidence), sum = a.confidence + b.confidence
            guard a.polygon != b.polygon, floor >= policy.minimumConfidence else { continue }
            if floor > bestFloor || (floor == bestFloor && sum > bestSum) {
                best = Pair(column: column, first: references[i], second: references[j])
                bestFloor = floor; bestSum = sum
            }
        } }
        return best
    }
}
