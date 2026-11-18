import CoreGraphics
import Foundation

/// Polygon NMS on actual recognized crops. No source/layout agreement, RF/DB
/// dominance, text features or auxiliary model is used to elect a survivor.
enum NativeSimpleOCRDedup {
    static let policyVersion = "simple-actual-rec64-polygon-nms-v1"
    typealias G = NativeOCRIndividualGeometryHypotheses
    private typealias D = NativeOCRGeometryDeduplication

    enum Rank: String, Codable, Sendable {
        case recognition = "rec"
        case recognitionThenBBox = "rec_bbox_tie"
    }
    struct Configuration: Codable, Equatable, Sendable {
        var iouThreshold: Double = 0.85
        var rank: Rank = .recognition
    }
    enum Failure: Error { case invalidThreshold, recognitionBinding }

    @available(iOS 18.0, *)
    static func apply(_ input: G.Output, reads: [NativeCoreMLRecognizedRegion],
                      configuration: Configuration) throws -> NativeOCRPostRecognitionDeduplication.Result {
        let threshold = configuration.iouThreshold
        guard threshold.isFinite, threshold > 0, threshold <= 1 else { throw Failure.invalidThreshold }
        let rows = input.individuals
        // A read sourceIndex refers to the scheduled bank, not this accepted
        // array. It may be sparse; only exact ordered crop geometry binds REC.
        guard reads.count == rows.count, Set(reads.map(\.sourceIndex)).count == reads.count,
              reads.indices.allSatisfy({ i in
                  reads[i].sourceIndex >= 0 && reads[i].polygon.map {
                      G.Point(x: Double($0.x), y: Double($0.y))
                  } == rows[i].polygon
              }) else { throw Failure.recognitionBinding }
        let shapes = rows.map { D.Shape($0.polygon) }
        let order = reads.indices.filter { i in
            reads[i].confidence.isFinite && (0...1).contains(reads[i].confidence) &&
                shapes[i].convex && shapes[i].area.isFinite && shapes[i].area > 0
        }.sorted { a, b in
            let av = reads[a].confidence, bv = reads[b].confidence
            if av != bv { return av > bv }
            if configuration.rank == .recognitionThenBBox {
                let aa = rows[a].bboxConfidence.flatMap { $0.isFinite ? $0 : nil } ?? -Double.infinity
                let bb = rows[b].bboxConfidence.flatMap { $0.isFinite ? $0 : nil } ?? -Double.infinity
                if aa != bb { return aa > bb }
            }
            return a < b
        }
        return NativeOCRPostRecognitionDeduplication.suppress(input, shapes: shapes, order: order,
            threshold: threshold, maySuppress: { _, _ in true })
    }
}
