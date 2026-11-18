import Foundation
import CryptoKit

/// Render-only alternatives must not invalidate OCR, provider or source-mask caches.
/// Source-crop execution changes are fenced independently of render alternatives.
enum NativeRenderVariantPolicy {
    static var projection: [String: String] {
        var result = make(font: NativeAcceptedSourceFontInference.cachePolicy,
             mask: NativeOriginalMaskFringeCompletion.cacheProjection.merging(
                NativeSourceBackedRFProtection.cacheProjection, uniquingKeysWith: { _, current in current }),
             localBoundary: EnsembleCandidate03.localRFBoundarySupportEnabled,
             supportedContour: NativeEnsembleLayoutContour.supportedEstimatedContourEnabled)
        if NativeSimpleTextLayout.enabled {
            result["simpleTextLayout"] = NativeSimpleTextLayout.version
        }
        result["sourceCropPolicy"] = NativeSourceInputFactory.sourceCropPolicyVersion
        result["horizontalSourceLeading"] = NativeHorizontalSourceLeading.identity
        if !NativeMainEnsembleRenderer.enabled {
            result["legacySourceRestoration"] = "native-erasure-palette-v1"
        }
        do {
            if let placement = try NativeSimpleRFBalloonCoreDomain.Configuration.configured() {
                result["simpleRFBalloonPlacement"] = placement.cacheIdentity
            }
        } catch { result["simpleRFBalloonPlacement"] = "invalid-explicit-configuration" }
        if #available(iOS 16.0, macOS 13.0, *) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let bytes = try encoder.encode(NativeMainEnsembleConfiguration.parameters())
                result["mainEnsembleParameters"] = SHA256.hash(data: bytes)
                    .map { String(format: "%02x", $0) }.joined()
            } catch {
                // Invalid parameters cannot reuse a successful default render;
                // the actual renderer still throws the precise configuration error.
                result["mainEnsembleParameters"] = "invalid-explicit-configuration"
            }
        }
        result.merge(NativeSourceInferencePolicy.cacheProjection, uniquingKeysWith: { _, current in current })
        result.merge(NativePostLLMContentReclassifier.activePolicy.cacheProjection,
                     uniquingKeysWith: { _, current in current })
        return result
    }

    static func make(font: String?, mask: [String: String], localBoundary: Bool,
                     supportedContour: Bool) -> [String: String] {
        var result = mask
        if let font { result["sourceFontEstimatorPolicy"] = font }
        if localBoundary { result["localRGBBoundaryPolicy"] = NativeSupportedEstimatedContour.revision }
        if supportedContour { result["supportedEstimatedContourPolicy"] = NativeSupportedEstimatedContour.revision }
        return result
    }
}

/// Numeric, page-independent overrides for reproducible main-path parameter search.
/// Production defaults stay in the shared pipeline. No labels or image identifiers.
@available(iOS 16.0, macOS 13.0, *)
enum NativeMainEnsembleConfiguration {
    static func parameters() throws -> NativeMainEnsemblePipeline.Parameters {
        #if os(macOS)
        if let path = ProcessInfo.processInfo.environment["AIDOKU_ENSEMBLE_PARAMETERS"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let values = try JSONDecoder().decode([String: [String: Double]].self, from: data)
            // Share the real pipeline's groups so an integrated optional stage
            // cannot be rejected by a stale host-only allowlist.
            guard Set(values.keys).isSubset(of: Set(NativeMainEnsemblePipeline.defaultParameters.keys)),
                  values.values.allSatisfy({ $0.values.allSatisfy(\.isFinite) }) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return values
        }
        #endif
        return NativeMainEnsemblePipeline.defaultParameters
    }
}
