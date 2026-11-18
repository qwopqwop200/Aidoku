import CoreGraphics
import Foundation

/// Post-correction detector probability, never OCR confidence or GT routing.
@available(iOS 18.0, *)
enum NativeOCRBBoxConfidenceAdmission {
    typealias G = NativeOCRIndividualGeometryHypotheses
    static let environmentKey = "AIDOKU_OCR_BBOX_CONFIDENCE_THRESHOLD"
    static let defaultThreshold = 0.085
    static var enabled: Bool {
        NativeOCRSourcePaintGeometry.enabled || ProcessInfo.processInfo.environment[environmentKey] != nil
    }
    enum Failure: Error { case invalidThreshold }
    static func threshold() throws -> Double {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return defaultThreshold }
        guard let value = Double(raw), value.isFinite, (0...1).contains(value) else { throw Failure.invalidThreshold }
        return value
    }
    struct Row: Codable, Sendable {
        let inputOrdinal: Int
        let bboxConfidence: Double
        let kept: Bool
    }
    struct Report: Codable, Sendable {
        let schema: String
        let threshold: Double
        let applied: Bool
        let status: String
        let inputCount: Int
        let keptCount: Int
        let rejectedCount: Int
        let scoreDefinition: String
        let rows: [Row]
    }
    struct Production: Sendable { let output: G.Output; let report: Report }
    static func apply(_ input: G.Output, probability: NativeMainEnsembleOCRProbability.Sample?,
                      sourceWidth: Int, sourceHeight: Int, enabled: Bool = enabled,
                      cancellationCheck: () throws -> Void = {}) throws -> Production {
        let cutoff = try threshold()
        func report(_ applied: Bool, _ status: String, _ rows: [Row] = []) -> Report {
            let kept = applied ? rows.filter(\.kept).count : input.individuals.count
            return .init(schema: "native-corrected-bbox-confidence-admission-v1", threshold: cutoff,
                applied: applied, status: status, inputCount: input.individuals.count, keptCount: kept,
                rejectedCount: input.individuals.count-kept,
                scoreDefinition: "mean finite DB probability inside final corrected bbox; production integer raster",
                rows: rows)
        }
        guard enabled else { return .init(output: input, report: report(false, "disabled")) }
        guard let p = probability, p.sourceWidth == sourceWidth, p.sourceHeight == sourceHeight,
              p.width > 0, p.height > 0, p.width <= 2_000, p.height <= 2_000,
              p.width == p.resizedWidth, p.height == p.resizedHeight,
              p.region == CGRect(x: 0, y: 0, width: p.width, height: p.height),
              p.values.count == p.width*p.height,
              p.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            // Missing/partial evidence never fabricates a low confidence or deletes text.
            return .init(output: input, report: report(false, "full-source-probability-unavailable-kept"))
        }
        let scores = try NativeCoreMLDBPostprocessor.validatedFiniteCorrectedBoxScores(
            map: .init(width: p.width, height: p.height, values: p.values),
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            polygons: input.individuals.map { $0.polygon.map { CGPoint(x: $0.x, y: $0.y) } },
            cancellationCheck: cancellationCheck)
        let rows = scores.enumerated().map { Row(inputOrdinal: $0.offset, bboxConfidence: $0.element, kept: $0.element >= cutoff) }
        return .init(output: G.admitting(input, bboxScores: scores, threshold: cutoff),
                     report: report(true, "applied", rows))
    }
}
