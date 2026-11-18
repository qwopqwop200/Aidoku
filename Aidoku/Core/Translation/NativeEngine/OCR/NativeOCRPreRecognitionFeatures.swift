import Foundation

/// Frozen source165 ABI on actual scored candidate polygons. Source associations
/// must be authenticated by the caller; ancestry alone does not establish ownership.
/// No OCR, provenance/category columns, absolute-shape features or filtering policy.
enum NativeOCRPreRecognitionFeatures {
    typealias G = NativeOCRIndividualGeometryHypotheses
    private typealias D = NativeOCRGeometryDeduplication

    static let featureNames: [String] = NativeOCRSourceSupportFeatures155.featureNames + [
        "finalBBoxConfidence", "candidateSourcePolygonIoU", "otherCandidateMaxIoU",
        "otherCandidateSecondIoU", "otherCandidateMaxConfidenceOverlap", "higherConfidenceOtherMaxIoU",
        "otherOverlapWeightedBBoxConfidence", "otherCandidateCount80",
        "observedDetectorMaxConfidenceOverlap", "missingFeatureFraction"
    ]

    struct SourceObservation: Sendable {
        let polygon: [[Double]]
        let score: Double
        let detectorSeedEvidence: NativeOCRDetectorSeedEvidence?
    }

    enum Failure: Error {
        case invalidDimensions, sourceObservationCount, invalidObservation, invalidCandidate, invalidSourceSupport
    }

    /// Actual needed scalars, not a fabricated165-vector with missing slots.
    struct RecognitionAgreement: Equatable, Sendable {
        let rfSupport: Double
        let detectorAgreement: Double
    }

    /// Exact Float32-promoted fields6/163 only. Other-candidate overlap/sort,
    /// source IoU,CC/boundary scans and unused RF planes are not calculated.
    /// Call only when the full165 bank has no active consumer (legacy dedup,
    /// fixed preREC,observer and terminal-recovery paths retain extract()).
    static func extractRecognitionAgreement(input: G.Output, detectorObservations: [SourceObservation],
                        rf: NativeOCRSourceSupportFeatures155.PreparedRF,
                        sourceWidth: Int, sourceHeight: Int) throws -> [RecognitionAgreement] {
        guard sourceWidth > 0, sourceHeight > 0, rf.width == sourceWidth, rf.height == sourceHeight else {
            throw Failure.invalidDimensions
        }
        let detectors = try detectorObservations.map { observation -> D.Shape in
            guard observation.score.isFinite, (0...1).contains(observation.score), observation.polygon.count == 4,
                  observation.polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                throw Failure.invalidObservation
            }
            let shape = D.Shape(observation.polygon.map { G.Point(x: $0[0], y: $0[1]) })
            guard shape.convex, shape.area.isFinite, shape.area > 0 else { throw Failure.invalidObservation }
            return shape
        }
        var output = [RecognitionAgreement]()
        output.reserveCapacity(input.individuals.count)
        for row in input.individuals {
            let candidate = D.Shape(row.polygon)
            guard candidate.convex, candidate.area.isFinite, candidate.area > 0 else { throw Failure.invalidCandidate }
            guard let support = NativeOCRSourceSupportFeatures155.recognitionRFSupport(
                rawPolygon: row.polygon.map { [$0.x,$0.y] }, sourceWidth: sourceWidth, sourceHeight: sourceHeight, rf: rf) else {
                throw Failure.invalidSourceSupport
            }
            var observed = 0.0
            for j in detectors.indices {
                observed = max(observed, D.intersectionIoU(candidate, detectors[j], minimum: 0) * detectorObservations[j].score)
            }
            output.append(.init(rfSupport: Double(support), detectorAgreement: Double(Float(observed))))
        }
        return output
    }

    /// Every output scalar is Float32 promoted to Double, including legitimate NaNs.
    /// The immutable input inventory supplies all overlap context, including aux rows.
    static func extract(input: G.Output, sourceObservations: [SourceObservation],
                        detectorObservations: [SourceObservation],
                        rf: NativeOCRSourceSupportFeatures155.PreparedRF,
                        sourceWidth: Int, sourceHeight: Int) throws -> [[Double]] {
        guard sourceWidth > 0, sourceHeight > 0,
              rf.width == sourceWidth, rf.height == sourceHeight else { throw Failure.invalidDimensions }
        let rows = input.individuals
        guard sourceObservations.count == rows.count else { throw Failure.sourceObservationCount }
        func shape(_ observation: SourceObservation) throws -> D.Shape {
            guard observation.score.isFinite, (0...1).contains(observation.score),
                  observation.polygon.count == 4,
                  observation.polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                throw Failure.invalidObservation
            }
            let result = D.Shape(observation.polygon.map { G.Point(x: $0[0], y: $0[1]) })
            guard result.convex, result.area.isFinite, result.area > 0 else { throw Failure.invalidObservation }
            return result
        }
        let sources = try sourceObservations.map(shape)
        let detectors = try detectorObservations.map(shape)
        let candidates = rows.map { D.Shape($0.polygon) }
        let confidences = try rows.map { row -> Double in
            guard let score = row.bboxConfidence, score.isFinite, (0...1).contains(score) else {
                throw Failure.invalidCandidate
            }
            return score
        }
        guard candidates.allSatisfy({ $0.convex && $0.area.isFinite && $0.area > 0 }) else {
            throw Failure.invalidCandidate
        }
        var output = [[Double]]()
        output.reserveCapacity(rows.count)
        for i in rows.indices {
            let source = sourceObservations[i]
            guard let prefix = NativeOCRSourceSupportFeatures155.extract(
                rawPolygon: rows[i].polygon.map { [$0.x, $0.y] }, detectorConfidence: source.score,
                detectorSeed: source.detectorSeedEvidence, sourceWidth: sourceWidth,
                sourceHeight: sourceHeight, rf: rf), prefix.features.count == 155 else {
                throw Failure.invalidSourceSupport
            }
            // Diagonal is exactly zero, before reductions, as in the frozen NumPy producer.
            // Preserve Double confidences through all products and reductions.
            let overlaps = rows.indices.map { j in
                i == j ? 0 : D.intersectionIoU(candidates[i], candidates[j], minimum: 0)
            }
            let weighted = rows.indices.map { overlaps[$0] * confidences[$0] }
            let sorted = overlaps.sorted()
            let mass = numpySum(overlaps)
            var higher = 0.0, observed = 0.0
            for j in rows.indices where confidences[j] > confidences[i] {
                higher = max(higher, overlaps[j])
            }
            for j in detectors.indices {
                observed = max(observed, D.intersectionIoU(candidates[i], detectors[j], minimum: 0)
                    * detectorObservations[j].score)
            }
            let extras: [Double] = [
                confidences[i], D.intersectionIoU(candidates[i], sources[i], minimum: 0),
                sorted.last ?? 0, sorted.count > 1 ? sorted[sorted.count - 2] : 0,
                weighted.max() ?? 0, higher, mass > 0 ? numpySum(weighted) / mass : 0,
                Double(overlaps.filter { $0 >= 0.8 }.count), observed
            ]
            var values = prefix.features + extras.map(Float.init)
            let missing = values.reduce(0) { $0 + ($1.isFinite ? 0 : 1) }
            values.append(Float(Double(missing) / 164))
            output.append(values.map(Double.init))
        }
        return output
    }

    /// NumPy contiguous Float64 add.reduce order (including its recursive split).
    /// Required before the final Float32 cast of the overlap-weighted confidence.
    private static func numpySum(_ values: [Double]) -> Double {
        func sum(_ start: Int, _ count: Int) -> Double {
            if count < 8 {
                var result = -0.0
                for i in start..<(start + count) { result += values[i] }
                return result
            }
            if count <= 128 {
                var accumulators = Array(values[start..<(start + 8)])
                var i = 8
                while i < count - count % 8 {
                    for k in 0..<8 { accumulators[k] += values[start + i + k] }
                    i += 8
                }
                var result = ((accumulators[0] + accumulators[1]) + (accumulators[2] + accumulators[3]))
                    + ((accumulators[4] + accumulators[5]) + (accumulators[6] + accumulators[7]))
                while i < count { result += values[start + i]; i += 1 }
                return result
            }
            var middle = count / 2
            middle -= middle % 8
            return sum(start, middle) + sum(start + middle, count - middle)
        }
        return sum(0, values.count)
    }
}
