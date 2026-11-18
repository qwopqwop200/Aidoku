import CoreGraphics
import Foundation

/// Immutable source evidence for bounded post-stage alternatives. Original owner
/// inventories stay unchanged; local remeasurement never invokes an OCR model.
@available(iOS 18.0, *)
struct NativeOCRResidualSourceContext {
    struct Region {
        let index: Int
        let polygon: [CGPoint]
        let independent: Bool
        let hasInk: Bool
    }
    let originals: [NativeCoreMLDetectionBox]
    let prepared: [NativeCoreMLDetectionBox]
    let groups: [Int: [Int]]
    let regions: [Region]
    let layout: NativeRFDETRLayoutResult?
    let frameProvider: () -> NativeOCRRGBAFrame?
    let measure: (Int, [CGPoint]) -> NativeOCRSourceComponentMeasurements.Measurement?
}
