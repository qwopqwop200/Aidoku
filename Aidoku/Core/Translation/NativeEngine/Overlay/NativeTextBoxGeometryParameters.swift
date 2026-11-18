import CoreGraphics
import Foundation

/// Rendering geometry only. Never changes OCR, translation, color roles, or panel shape.
struct NativeTextBoxGeometryParameters: Codable, Equatable, Sendable {
    var sourceMarginMinimum: Double = 1.5
    var sourceMarginMaximum: Double = 2.25
    var sourceWidthRatio: Double = 0.12
    var sourceFontRatio: Double = 0
    var openPanelExpansion: Double = 0.75
    // Optional to keep saved five-parameter manifests backward compatible.
    // These control candidate shaping only, never colors or source content.
    var translationPaddingScale: Double?
    var translationLineHeightScale: Double?
    var translationFontRecoveryScale: Double?
    /// Explicit controlled trial, 0=legacy, 1=same-family relative typography.
    /// Absent in historical manifests; never enabled by default or page identity.
    var observedFamilyRatiosEnabled: Double?

    static let baseline = NativeTextBoxGeometryParameters()

    var isValid: Bool {
        [sourceMarginMinimum, sourceMarginMaximum, sourceWidthRatio, sourceFontRatio, openPanelExpansion]
            .allSatisfy(\.isFinite)
            && (0.35...6).contains(sourceMarginMinimum)
            && (sourceMarginMinimum...8).contains(sourceMarginMaximum)
            && (0...0.4).contains(sourceWidthRatio)
            && (0...0.8).contains(sourceFontRatio)
            && (0...8).contains(openPanelExpansion)
            && [translationPaddingScale, translationLineHeightScale, translationFontRecoveryScale]
                .compactMap { $0 }.allSatisfy(\.isFinite)
            && (0.5...2).contains(translationPaddingScale ?? 1)
            && (0.95...1.3).contains(translationLineHeightScale ?? 1.05)
            && (0.8...1.6).contains(translationFontRecoveryScale ?? 1)
            && (observedFamilyRatiosEnabled == nil || observedFamilyRatiosEnabled == 0 || observedFamilyRatiosEnabled == 1)
    }

    func sourceGuard(owner: CGRect, sourceFontSize: CGFloat, outputOutline: CGFloat,
                     panelPadding: CGFloat) -> CGFloat {
        let widthTerm = min(owner.width, owner.height) * CGFloat(sourceWidthRatio)
        let fontTerm = max(0, sourceFontSize) * CGFloat(sourceFontRatio)
        return max(panelPadding, min(CGFloat(sourceMarginMaximum),
            max(CGFloat(sourceMarginMinimum), max(widthTerm, max(fontTerm, outputOutline / 2 + panelPadding)))))
    }

    var diagnosticValues: [String: Double] {
        ["sourceMarginMinimum": sourceMarginMinimum, "sourceMarginMaximum": sourceMarginMaximum,
         "sourceWidthRatio": sourceWidthRatio, "sourceFontRatio": sourceFontRatio,
         "openPanelExpansion": openPanelExpansion,
         "translationPaddingScale": translationPaddingScale ?? 1,
         "translationLineHeightScale": translationLineHeightScale ?? 1.05,
         "translationFontRecoveryScale": translationFontRecoveryScale ?? 1,
         "observedFamilyRatiosEnabled": observedFamilyRatiosEnabled ?? 0]
    }
}
