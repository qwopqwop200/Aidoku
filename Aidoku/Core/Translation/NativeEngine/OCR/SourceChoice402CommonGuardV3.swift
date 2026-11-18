import Foundation
import CoreGraphics

/// A shared source policy calibrated on frozen native candidates. No identities or GT at runtime.
enum SourceChoice402CommonGuardV3 {
    static let runtimeEnabled = true
    static func allows(rawOffer: [String: Any], actualPrior: [CGPoint],
                       sourceFeaturePrefix: [Double], nativeW: CGFloat) -> Bool {
        var limits = SourceChoice402CommonGuard.Limits()
        limits.maximumAxisResidual = 0.03
        limits.maximumPlaneMovementWidths = 0.15
        limits.minimumNewBodyAreaDensity = 0.15
        return SourceChoice402CommonGuard.evaluate(rawOffer: rawOffer, actualPrior: actualPrior,
            sourceFeaturePrefix: sourceFeaturePrefix, nativeW: nativeW, limits: limits).allowed
    }
}
