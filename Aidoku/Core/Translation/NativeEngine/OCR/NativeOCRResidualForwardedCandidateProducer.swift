import CoreGraphics
import Foundation

/// ADD ONLY: baseline Context/cache/features remain untouched; a temporary Context samples original v2 cells.
@available(iOS 18.0, *)
enum NativeOCRResidualForwardedCandidateProducer {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    static func candidates(_ baseline: Measurement, context: NativeOCRResidualSourceContext,
                           caps: [CGPoint]) -> [NativeOCRResidualCandidate] {
        guard baseline.status == "no-private-source" || baseline.status == "insufficient-private-cells" else { return [] }
        let assessed = NativeOCRResidualEvidenceForwarding.assess(index: baseline.index, polygon: baseline.polygon,
            originals: context.originals, prepared: context.prepared, groups: context.groups)
        guard let plan = assessed.plan else { return [] }
        let alternateContext = NativeOCRSourceComponentMeasurements.Context(originals: context.originals,
            prepared: context.prepared, groups: context.groups, scopes: baseline.scopes,
            frameProvider: context.frameProvider, provisionalPlans: [baseline.index: plan])
        guard let alternate = alternateContext.measure(index: baseline.index, polygon: baseline.polygon, hasInk: baseline.hasInk),
              alternate.status == "measured" else { return [] }
        return NativeOCRResidualForwardedAlternatives.candidates(baseline: baseline, alternate: alternate, caps: caps)
    }
}
