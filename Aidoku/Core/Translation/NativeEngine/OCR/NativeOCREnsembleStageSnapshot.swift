import CoreGraphics
import Foundation

/// Transient observations of this exact pipeline invocation, never a cache,
/// tensor, ROI, pixel buffer, primary-source certificate or inferred decode.
/// nil stage = unavailable; [] = actually observed empty. Reader supplies the
/// live original-image binding when projecting this same result.
@available(iOS 18.0, *)
struct NativeOCREnsembleStageSnapshot: Equatable, Sendable {
    struct Observation: Equatable, Sendable {
        let sourceIndex: Int
        let polygon: [CGPoint]
        let text: String?
        let confidence: Double
    }
    enum Failure: Error, Equatable { case dimensions, geometry, confidence, sourceIndex, budget }
    let width: Int
    let height: Int
    let detector: [Observation]?
    let recognized: [Observation]?
    let rejected: [Observation]?
    let decoded: [Observation]?
    let retainedBytes: Int
    static let maximumRecords = 4096
    static let maximumBytes = 1_048_576

    init(width: Int, height: Int, detector: [Observation]? = nil, recognized: [Observation]? = nil,
         rejected: [Observation]? = nil, decoded: [Observation]? = nil) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 16_777_216 / height else { throw Failure.dimensions }
        var records = 0, vertices = 0, bytes = 0
        for stage in [detector, recognized, rejected, decoded] {
            guard let stage else { continue }
            guard stage.count <= Self.maximumRecords - records else { throw Failure.budget }
            records += stage.count
            for row in stage {
                // Supplementary observations may share ancestry. Preserve the
                // actual index rather than dropping observations or inventing IDs.
                guard row.sourceIndex >= 0 else { throw Failure.sourceIndex }
                guard row.confidence.isFinite, (0...1).contains(row.confidence) else { throw Failure.confidence }
                guard (3...32).contains(row.polygon.count), row.polygon.allSatisfy({
                    $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_073_741_824 && abs($0.y) <= 1_073_741_824
                }) else { throw Failure.geometry }
                let xs = row.polygon.map(\.x), ys = row.polygon.map(\.y)
                guard xs.max()! > xs.min()!, ys.max()! > ys.min()! else { throw Failure.geometry }
                let textBytes = row.text?.utf8.count ?? 0
                guard textBytes <= 16_384 else { throw Failure.budget }
                vertices += row.polygon.count
                bytes += textBytes + row.polygon.count * 16 + 64
                guard vertices <= 65_536, bytes <= Self.maximumBytes else { throw Failure.budget }
            }
        }
        self.width = width; self.height = height
        self.detector = detector; self.recognized = recognized; self.rejected = rejected; self.decoded = decoded
        retainedBytes = bytes
    }

    /// Call once at pipeline return, with the actual final arrays. Do not pass
    /// [] for a stage that did not run. In particular recognized + rejected are
    /// NOT a substitute for raw decoded observations (recognizer floor exists).
    static func capture(width: Int, height: Int, detectionBoxes: [NativeCoreMLDetectionBox]?,
                        recognizedRegions: [NativeCoreMLRecognizedRegion]?, rejectedReads: [NativeCoreMLRecognizedRegion]?,
                        decodedRegions: [NativeCoreMLRecognizedRegion]? = nil) throws -> Self {
        func reads(_ rows: [NativeCoreMLRecognizedRegion]?) -> [Observation]? {
            rows?.map { .init(sourceIndex: $0.sourceIndex, polygon: $0.polygon, text: $0.text, confidence: $0.confidence) }
        }
        // Bound before copying polygons/strings; aggregate budgets are checked
        // by init. Copy-on-write arrays retain only the compact value fields.
        for count in [detectionBoxes?.count, recognizedRegions?.count, rejectedReads?.count, decodedRegions?.count].compactMap({ $0 }) {
            guard count <= maximumRecords else { throw Failure.budget }
        }
        return try .init(width: width, height: height, detector: detectionBoxes?.enumerated().map {
            .init(sourceIndex: $0.offset, polygon: $0.element.polygon, text: nil, confidence: $0.element.score)
        }, recognized: reads(recognizedRegions), rejected: reads(rejectedReads), decoded: reads(decodedRegions))
    }

    func project(binding: NativeMainEnsembleOCREvidence.Binding,
                 audit: (String) -> Void = { _ in }) throws -> [NativeMainEnsembleOCREvidence.StageRows] {
        guard width == binding.width, height == binding.height else { throw Failure.dimensions }
        let stages: [(NativeMainEnsembleOCREvidence.Stage, [Observation]?)] = [
            (.detector, detector), (.recognized, recognized), (.rejected, rejected), (.decoded, decoded)]
        return stages.compactMap { stage, observed in
            guard let observed else { return nil }
            let duplicates = observed.count - Set(observed.map(\.sourceIndex)).count
            if duplicates > 0 { for _ in 0..<duplicates { audit(stage.rawValue + ".duplicateSourceIndex") } }
            let rows: [[String: Any]] = observed.map { observation in
                var row: [String: Any] = ["sourceIndex": observation.sourceIndex,
                    "polygon": observation.polygon.map { [Double($0.x), Double($0.y)] }, "confidence": observation.confidence]
                if let text = observation.text { row["text"] = text }
                if stage == .detector { row["score"] = observation.confidence }
                return row
            }
            do {
                return try NativeMainEnsembleOCREvidence.project(rows: rows, stage: stage,
                    space: .originalPixels(width: width, height: height), binding: binding)
            } catch {
                audit(stage.rawValue + ".projectionFailure")
                return nil // unavailable, not an invented observed-empty stage
            }
        }
    }

    /// Transient JSON input to the existing owned/partial CC projector. The ROI
    /// is removed BEFORE encoding; full seeds never survive in the OCR packet.
    struct SeedBudget {
        var remainingRuns = 131_072
        var remainingBytes = 2_097_152
    }
    static func compactSeedRows(_ evidence: [NativeOCRDetectorSeedEvidence]?, budget: inout SeedBudget) throws -> [[String: Any]]? {
        guard let evidence else { return nil }
        guard evidence.count <= 64 else { throw Failure.budget }
        var runs = 0
        for record in evidence {
            let components = record.components + (record.ambiguousComponents ?? []) + (record.candidateComponents ?? []).map(\.component)
            guard components.count <= 256 else { throw Failure.budget }
            for component in components {
                guard component.runs.count <= 8192, component.runs.count <= budget.remainingRuns - runs else { throw Failure.budget }
                runs += component.runs.count
            }
        }
        let sparse = evidence.map { original in
            var row = original; row.sourceProbabilityROI = nil; return row
        }
        let encoded = try JSONEncoder().encode(sparse)
        guard encoded.count <= budget.remainingBytes else { throw Failure.budget }
        guard let rows = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] else { throw Failure.geometry }
        budget.remainingRuns -= runs; budget.remainingBytes -= encoded.count
        return rows
    }

    /// Optional enrichment cannot invalidate measured base text/geometry.
    /// Failed encoding never consumes the shared budget.
    static func optionalSeedRows(_ evidence: [NativeOCRDetectorSeedEvidence]?, budget: inout SeedBudget,
                                 audit: (String) -> Void = { _ in }) -> [[String: Any]]? {
        do { return try compactSeedRows(evidence, budget: &budget) }
        catch {
            audit("missingGeometry")
            audit(error as? Failure == .budget ? "seedBudgetFailure" : "seedEncodingFailure")
            return nil
        }
    }

    /// Actual pre-grouping native lines, in original pixels. Their indices are
    /// not detector indices: do not manufacture sourceIndex by enumeration.
    static func projectNativeLines(_ lines: [NativeCoreMLOCRLine], binding: NativeMainEnsembleOCREvidence.Binding,
                                   includeSeeds: Bool = true,
                                   audit: (String) -> Void = { _ in })
        throws -> NativeMainEnsembleOCREvidence.StageRows {
        guard lines.count <= maximumRecords else { throw Failure.budget }
        var seedBudget = SeedBudget()
        let rows: [[String: Any]] = lines.map { line in
            var row: [String: Any] = ["polygon": line.polygon.map { [Double($0.x), Double($0.y)] },
                "source": line.text, "score": line.score, "confidence": line.score,
                "sourceOrientation": line.orientation.rawValue]
            if includeSeeds, let seeds = optionalSeedRows(line.detectorSeedEvidence, budget: &seedBudget, audit: audit) {
                row["detectorSeedEvidence"] = seeds
            }
            return row
        }
        return try NativeMainEnsembleOCREvidence.project(rows: rows, stage: .nativeLines,
            space: .originalPixels(width: binding.width, height: binding.height), binding: binding)
    }
}
