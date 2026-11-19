// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLOCRLine: Equatable, Sendable {
    let polygon: [CGPoint]
    let text: String
    let score: Double
    let orientation: BrowserOCRSourceOrientation
    /// Aspect-ratio estimates may be revised using neighbouring glyphs. An
    /// explicit writing-direction hint must survive fragment grouping.
    let orientationIsEstimated: Bool
    /// Page-space tile bounds, supplied by tiled readers after offsetting the
    /// polygon. The merger uses interior edges to identify truncated retries.
    let sourceTileBounds: CGRect?
    let erasurePolygons: [[CGPoint]]
    let detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]?

    var acceptedSource: NativeOCRSourceMetadata = .init()

    /// A calibrated output still belongs to the line geometry on which the
    /// recognizer and the paragraph adjacency thresholds operated.
    var preCalibrationPolygon: [CGPoint]?
    var isLegacyComplement = false

    init(
        polygon: [CGPoint],
        text: String,
        score: Double,
        orientation: BrowserOCRSourceOrientation,
        orientationIsEstimated: Bool = false,
        sourceTileBounds: CGRect? = nil,
        erasurePolygons: [[CGPoint]] = [],
        detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]? = nil,
        acceptedSource: NativeOCRSourceMetadata = .init()
    ) {
        self.polygon = polygon
        self.text = text
        self.score = score
        self.orientation = orientation
        self.orientationIsEstimated = orientationIsEstimated
        self.sourceTileBounds = sourceTileBounds
        self.erasurePolygons = erasurePolygons
        self.detectorSeedEvidence = detectorSeedEvidence
        self.acceptedSource = acceptedSource
    }
}
