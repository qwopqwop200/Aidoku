import Foundation

/// Optional pre-representative proposal compaction using measured signals only.
/// Context recognition is an old observation, never this candidate's OCR score.
/// This helper does not certify text ownership or emit recognized OCR lines.
enum NativeOCRGeometrySignalAdmission {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias D = NativeOCRGeometryDeduplication
    static let layoutSemanticSchema = "canonical-frame0-text1-balloon2-sfx3"
    static let environmentKey = "AIDOKU_OCR_GEOMETRY_SIGNAL_ADMISSION"

    // Bound direct overlap while preserving strict measured Pareto
    // dominance and complete evidence for both candidates.
    static let polygonIoUThreshold = 0.91
    static let bboxConfidenceMargin = 0.01

    // A second, cross-family retained observation bounds small signal changes
    // caused by slightly different polygons. All three context channels remain
    // mandatory; absence never acts as evidence against a proposal.
    static let corroboratedPolygonIoUThreshold = 0.80
    static let relativeSignalUncertainty = 0.10

    static let minimumCorroboratedCoverage = 0.98
    static let strongCorroboratingConfidenceMargin = 0.10

    struct Evidence: Codable, Sendable {
        let polygon: [G.Point]
        let confidence: Double
        var semanticClass: Int? = nil
    }
    struct Context: Codable, Sendable {
        var detectors: [Evidence] = []
        var recognition: [Evidence] = []
        /// Canonical frame=0, text=1, balloon=2, SFX=3; never premerge rawValue order.
        /// Signal dominance pools all classes and does not classify their meaning.
        var layout: [Evidence] = []
    }
    struct Signals: Codable, Equatable, Sendable {
        let detectorAgreement: Double?
        let observedRecognitionAgreement: Double?
        let layoutConfidenceCoverage: Double?
        let bboxConfidence: Double?

        var complete: Bool {
            [detectorAgreement, observedRecognitionAgreement, layoutConfidenceCoverage, bboxConfidence]
                .allSatisfy { $0.map { $0.isFinite && $0 > 0 && $0 <= 1 } == true }
        }
        func dominates(_ other: Signals) -> Bool {
            guard complete, other.complete else { return false }
            return bboxConfidence! >= other.bboxConfidence! + bboxConfidenceMargin
                && detectorAgreement! >= other.detectorAgreement!
                && observedRecognitionAgreement! >= other.observedRecognitionAgreement!
                && layoutConfidenceCoverage! >= other.layoutConfidenceCoverage!
        }
    }
    struct Replacement: Codable, Equatable, Sendable {
        let inputIndex: Int
        let retainedIndex: Int
        let polygonIoU: Double
        var corroboratingIndex: Int? = nil
        var corroboratingPolygonIoU: Double? = nil
        var relativeSignalUncertainty: Double? = nil
        var corroboratedCoverage: Double? = nil
        var strongConfidenceSupport: Bool? = nil
    }
    struct Report: Codable, Equatable, Sendable {
        let schema: String
        let inputCount: Int
        let keptIndices: [Int]
        let signals: [Signals]
        let replacements: [Replacement]
        let missingEvidenceKeptIndices: [Int]
        let freshCandidateRecognition: Bool
        let layoutSemanticSchema: String
    }
    struct Result: Sendable {
        let output: G.Output
        let report: Report
    }

    private static func validConfidence(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 1 else { return nil }
        return value
    }

    /// Zero overlap is unavailable evidence, not a negative classification.
    private static func agreement(_ shape: D.Shape, _ references: [(D.Shape, Double)], coverage: Bool) -> Double? {
        var maximum: Double = 0
        for (reference, confidence) in references {
            let iou = D.intersectionIoU(shape, reference, minimum: 0)
            let fraction = coverage ? iou * (shape.area + reference.area) / (1 + iou) / max(shape.area, 1e-12) : iou
            maximum = max(maximum, min(1, fraction) * confidence)
        }
        return maximum > 0 ? maximum : nil
    }

    static func apply(_ input: G.Output, context: Context,
                      cancellationCheck: () throws -> Void = {}) throws -> Result {
        func references(_ evidence: [Evidence]) -> [(D.Shape, Double)] {
            evidence.compactMap { item in
                let shape = D.Shape(item.polygon)
                guard shape.convex, shape.area.isFinite, shape.area > 0,
                      let confidence = validConfidence(item.confidence) else { return nil }
                return (shape, confidence)
            }
        }
        let detectors = references(context.detectors)
        let recognition = references(context.recognition)
        let layout = references(context.layout)
        let rows = input.individuals
        let shapes = rows.map { D.Shape($0.polygon) }
        let signals = try rows.indices.map { index -> Signals in
            try cancellationCheck()
            let shape = shapes[index]
            return .init(detectorAgreement: agreement(shape, detectors, coverage: false),
                observedRecognitionAgreement: agreement(shape, recognition, coverage: false),
                layoutConfidenceCoverage: agreement(shape, layout, coverage: true),
                bboxConfidence: validConfidence(rows[index].bboxConfidence))
        }
        let families = rows.map(NativeOCRGeometryWitnessAdmission.producerFamilies)
        let order = rows.indices.sorted {
            let a = signals[$0].bboxConfidence ?? -1, b = signals[$1].bboxConfidence ?? -1
            return a == b ? $0 < $1 : a > b
        }
        var kept: [Int] = [], replacements: [Replacement] = [], unavailable: [Int] = []
        for index in order {
            try cancellationCheck()
            guard signals[index].complete else {
                kept.append(index)
                unavailable.append(index)
                continue
            }
            // Only already retained candidates may suppress. No replacement
            // chains, shared-parent ownership inference, area ranking or GT.
            var replacement: Replacement?
            for other in kept where signals[other].dominates(signals[index]) {
                let iou = D.intersectionIoU(shapes[index], shapes[other], minimum: polygonIoUThreshold)
                if iou >= polygonIoUThreshold {
                    replacement = .init(inputIndex: index, retainedIndex: other, polygonIoU: iou)
                    break
                }
            }
            if replacement == nil {
                // Every supporter is retained permanently and directly overlaps
                // this proposal. Families attest producer diversity, not source
                // ownership or statistical independence.
                var supporters: [(index: Int, iou: Double, families: Set<String>)] = []
                for other in kept {
                    let a = signals[other], b = signals[index]
                    guard a.complete,
                          a.bboxConfidence! >= b.bboxConfidence! + bboxConfidenceMargin,
                          a.detectorAgreement! >= b.detectorAgreement! * (1 - relativeSignalUncertainty),
                          a.observedRecognitionAgreement! >= b.observedRecognitionAgreement! * (1 - relativeSignalUncertainty),
                          a.layoutConfidenceCoverage! >= b.layoutConfidenceCoverage! * (1 - relativeSignalUncertainty) else { continue }
                    let diverse = families[other]
                    guard !diverse.isEmpty else { continue }
                    let iou = D.intersectionIoU(shapes[index], shapes[other], minimum: corroboratedPolygonIoUThreshold)
                    guard iou >= corroboratedPolygonIoUThreshold else { continue }
                    if let first = supporters.first(where: {
                        $0.families.union(diverse).count >= 2
                            && D.intersectionIoU(shapes[$0.index], shapes[other], minimum: 0) < 1 - 1e-12
                            && (NativeOCRGeometryWitnessAdmission.corroboratedCoverage(shapes[index], shapes[$0.index], shapes[other]) >= minimumCorroboratedCoverage
                                || (signals[$0.index].bboxConfidence! >= b.bboxConfidence! + strongCorroboratingConfidenceMargin
                                    && a.bboxConfidence! >= b.bboxConfidence! + strongCorroboratingConfidenceMargin))
                    }) {
                        replacement = .init(inputIndex: index, retainedIndex: first.index, polygonIoU: first.iou,
                            corroboratingIndex: other, corroboratingPolygonIoU: iou,
                            relativeSignalUncertainty: relativeSignalUncertainty,
                            corroboratedCoverage: NativeOCRGeometryWitnessAdmission.corroboratedCoverage(shapes[index], shapes[first.index], shapes[other]),
                            strongConfidenceSupport: signals[first.index].bboxConfidence! >= b.bboxConfidence! + strongCorroboratingConfidenceMargin
                                && a.bboxConfidence! >= b.bboxConfidence! + strongCorroboratingConfidenceMargin)
                        break
                    }
                    supporters.append((other, iou, diverse))
                }
            }
            if let replacement { replacements.append(replacement) } else { kept.append(index) }
        }
        kept.sort()
        return .init(output: G.selecting(input, indices: kept), report: .init(
            schema: "native-geometry-multi-evidence-dominance-v3", inputCount: rows.count,
            keptIndices: kept, signals: signals, replacements: replacements,
            missingEvidenceKeptIndices: unavailable.sorted(), freshCandidateRecognition: false,
            layoutSemanticSchema: layoutSemanticSchema))
    }
}
