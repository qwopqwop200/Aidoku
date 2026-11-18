import CoreGraphics
import Foundation

/// ADD ONLY: parent supplies fully admitted fresh child support; baseline measurements/features stay unchanged.
@available(iOS 18.0, *)
enum NativeOCRResidualCollinearPeerChainProducer {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    static func candidates(_ m: M, context: NativeOCRResidualSourceContext,
                           mandatorySupport: (Int) -> [CGPoint]?) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.rect.width >= 5, m.rect.height >= m.rect.width * 3,
              let own = mandatorySupport(m.index), !own.isEmpty else { return [] }
        var support = [m.index: own]
        // Nominate only potentially collinear siblings before evaluating expensive fresh terminal evidence.
        for peer in context.regions where peer.index != m.index && peer.polygon.count == 4 {
            let r = NativeOCRResidualMembership.bounds(peer.polygon.map(m.project)), w = m.rect.width
            guard r.width >= w * 0.65, r.width <= w * 1.4, r.height >= w * 0.45,
                  abs(r.midX - m.rect.midX) <= w * 0.22,
                  NativeOCRResidualMembership.axisAgreement(peer.polygon, along: m.along),
                  let points = mandatorySupport(peer.index), !points.isEmpty else { continue }
            support[peer.index] = points
        }
        return NativeOCRResidualCollinearPeerChain.candidates(m, context: context, protectedSupport: support)
    }
}
