import Foundation
import CoreGraphics

/// One source-only additive menu offer. No joining/consumption or GT/ID inputs.
/// Existing Bank.safe/semantic/foreign-private checks are still mandatory.
@available(iOS 18.0, *)
enum NativeOCRResidualPrivatePCATurningStroke {
    struct Observation {
        let offer: NativeOCRResidualCandidate?
        let veto: NativeOCRResidualTurningStrokeGuardHistogram.Result?
        let reason: String
    }
    static func observe(
        _ m: NativeOCRSourceComponentMeasurements.Measurement,
        privateObservation p: NativeOCRPrivateObservation.Retained,
        inherited: [CGPoint], originalGuard: [CGPoint],
        visibleForeground: [CGPoint], protectedCaps: [CGPoint],
        rgba: NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA,
        sourceFrameSize: CGSize
    ) -> Observation {
        guard p.missingPrivateRGBPixels == 0 else {
            return .init(offer: nil, veto: nil, reason: "incomplete-authentic-private-RGB-observation")
        }
        let candidates = NativeOCRResidualPrivatePCAEnvelopeFringe.candidates(
            m, privateMoments: p.moments, inherited: inherited, originalGuard: originalGuard,
            visibleForeground: visibleForeground, protectedCaps: protectedCaps)
        guard let q = candidates.first else { return .init(offer: nil, veto: nil, reason: "no-private-PCA-geometry") }
        guard q.polygon.allSatisfy({ $0.x >= 0 && $0.y >= 0
            && $0.x <= sourceFrameSize.width && $0.y <= sourceFrameSize.height }) else {
            return .init(offer: nil, veto: nil, reason: "source-frame-invalid")
        }
        let normalSpan = inherited.map { m.project($0).x }
        let veto = NativeOCRResidualTurningStrokeGuardHistogram.assess(
            old: inherited, new: q.polygon, rgba: rgba,
            authenticatedPalettes: p.palettes, privateRGBSampleCount: p.privateRGBSamples,
            frameOrigin: m.origin, normal: m.normal, along: m.along,
            sourceWidth: m.rect.width, inheritedNormalBounds: normalSpan.min()!...normalSpan.max()!)
        guard veto.decision == "no-entire-closed-component-loss-observed" else {
            return .init(offer: nil, veto: veto, reason: veto.decision == "reject" ? "pixel-veto" : "uncertain-pixel-observation")
        }
        return .init(offer: q, veto: veto, reason: "source-only-menu-offer-native-admission-pending")
    }
    static func candidates(
        _ m: NativeOCRSourceComponentMeasurements.Measurement,
        privateObservation p: NativeOCRPrivateObservation.Retained,
        inherited: [CGPoint], originalGuard: [CGPoint],
        visibleForeground: [CGPoint], protectedCaps: [CGPoint],
        rgba: NativeOCRResidualTurningStrokeGuardHistogram.LocalRGBA,
        sourceFrameSize: CGSize
    ) -> [NativeOCRResidualCandidate] {
        let result = observe(m, privateObservation: p, inherited: inherited, originalGuard: originalGuard,
            visibleForeground: visibleForeground, protectedCaps: protectedCaps, rgba: rgba, sourceFrameSize: sourceFrameSize)
        return result.offer.map { [$0] } ?? []
    }
}
