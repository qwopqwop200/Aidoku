import CoreGraphics
import Foundation

/// Additional candidates only. Never replaces baseline measurement/features or erasure ownership.
@available(iOS 18.0, *)
enum NativeOCRResidualForwardedAlternatives {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    static func candidates(baseline: Measurement, alternate: Measurement, caps: [CGPoint]) -> [NativeOCRResidualCandidate] {
        guard baseline.status == "no-private-source" || baseline.status == "insufficient-private-cells",
              alternate.status == "measured", !alternate.provisionalOwners.isEmpty,
              alternate.index == baseline.index, alternate.polygon == baseline.polygon,
              alternate.privateSamples >= 4 else { return [] }
        let support = baseline.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(baseline) + caps +
            alternate.guardPoints + NativeOCRSourceComponentBounds.visibleForeground(alternate) + alternate.privateHull.map(alternate.restore)
        guard support.count >= 3, support.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        let complete = NativeOCRSourceComponentMeasurements.convexHull(support)
        // Existing, independently tested geometry menus; this stage fixes evidence, not their padding parameters.
        let parents = NativeOCRResidualEvidence.candidates(alternate) +
            NativeOCRResidualSupportMinimumRectangle.candidates(alternate, caps: support) +
            NativeOCRResidualSideEnvelope.candidates(alternate)
        return parents.filter { candidate in
            candidate.consumedIndices.isEmpty && candidate.polygon.count == 4 &&
                complete.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(candidate.polygon, $0, tolerance: 1e-6) })
        }.map { candidate in
            .init(key: "evidence-forward-v1-" + candidate.key, polygon: candidate.polygon, supportPoints: complete)
        }
    }
}
