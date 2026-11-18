import Foundation

/// Source165 must be extracted before pre-REC filtering on the complete immutable
/// scored inventory, then gathered using authenticated accepted-source ordinals.
/// This pure join never recomputes the prefix's overlap/CC/RF context.
enum NativeOCRPostRecognitionFeatures {
    typealias G = NativeOCRIndividualGeometryHypotheses
    static let featureNames: [String] = NativeOCRPreRecognitionFeatures.featureNames + ["actualRecognitionConfidence"]

    enum Failure: Error {
        case rowCountMismatch, invalidSourceFeatureCount, invalidRecognitionConfidence
    }

    /// Input rows are already joined and ordered to actual accepted candidates.
    /// Output is canonical Float32 promoted to Double; prefix NaNs remain missing.
    /// Source IDs, provenance and recognized strings are deliberately absent.
    static func extract(input: G.Output, source165: [[Double]],
                        recognitionConfidences: [Double]) throws -> [[Double]] {
        guard input.individuals.count == source165.count,
              source165.count == recognitionConfidences.count else { throw Failure.rowCountMismatch }
        return try zip(source165, recognitionConfidences).map { row, confidence in
            guard row.count == 165 else { throw Failure.invalidSourceFeatureCount }
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw Failure.invalidRecognitionConfidence
            }
            return row.map { Double(Float($0)) } + [Double(Float(confidence))]
        }
    }
}
