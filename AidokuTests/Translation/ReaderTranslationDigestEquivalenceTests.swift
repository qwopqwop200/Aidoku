import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Golden oracle frozen from baseline formatter implementation before the fast-hex change.
/// Independent of production digest/encoded; explicit schema revisions track intentional cache invalidation.
@Suite(.serialized) @MainActor
struct ReaderTranslationDigestEquivalenceTests {
    @Test func knownSHA256Fixtures() {
        let fixtures = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("The quick brown fox jumps over the lazy dog", "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
        ]
        for (input, golden) in fixtures {
            #expect(ReaderTranslationCacheIdentity.digest(input) == golden)
            #expect(ReaderTranslationCacheIdentity.digest(Data(input.utf8)) == golden)
        }
    }

    @Test func everyInputByteAndLeadingZeroDigestsRemainExact() {
        for value in UInt16(0)...255 {
            let input = Data([UInt8(value)])
            let expected = FrozenFormatterIdentity.digest(input)
            let actual = ReaderTranslationCacheIdentity.digest(input)
            #expect(actual == expected, "Single input byte: \(value)")
            #expect(actual.utf8.count == 64)
            #expect(actual.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        }
        // Concatenated full byte domain also rejects ordering/truncation errors.
        let allBytes = Data((0...255).map(UInt8.init))
        #expect(ReaderTranslationCacheIdentity.digest(allBytes) == FrozenFormatterIdentity.digest(allBytes))
        // Known input whose SHA256 starts with 00: exact comparison must retain both zeros.
        let leadingZeroInput = Data("286".utf8)
        #expect(FrozenFormatterIdentity.digest(leadingZeroInput).hasPrefix("00"))
        #expect(ReaderTranslationCacheIdentity.digest(leadingZeroInput) == FrozenFormatterIdentity.digest(leadingZeroInput))
    }

    @Test func utf8AndSortedJSONInputsRemainUnchanged() {
        for text in ["한국어/日本語?x=1#fragment", "\u{0000}\n\r\t", "-0.0", "local|chapter|0001"] {
            #expect(ReaderTranslationCacheIdentity.digest(text) == FrozenFormatterIdentity.digest(text))
        }
        let first = ["z": "last", "a": "first"]
        var second: [String: String] = [:]; second["a"] = "first"; second["z"] = "last"
        #expect(ReaderTranslationCacheIdentity.encoded(first) == FrozenFormatterIdentity.encoded(first))
        #expect(ReaderTranslationCacheIdentity.encoded(second) == FrozenFormatterIdentity.encoded(first))
        #expect(ReaderTranslationCacheIdentity.encoded(["-0.0", "0.0"]) == FrozenFormatterIdentity.encoded(["-0.0", "0.0"]))
    }

    @Test func persistedOCRTranslationAndRenderKeyContractsRemainExact() throws {
        let suite = "DigestEquivalence-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.includePageImage = false
        for variant in 0..<3 {
            settings.credentialGeneration = UInt64(variant)
            settings.rightToLeftPanelOrder = variant == 1
            settings.targetLanguage = variant == 2 ? "ja" : "ko"
            settings.overlay.opacity = variant == 2 ? 0.5 : 0.84
            let page = "local/chapter-\(variant)|0"
            #expect(ReaderTranslationCacheIdentity.ocr(page: page, settings: settings) == FrozenFormatterIdentity.ocr(page: page, settings: settings))
            #expect(ReaderTranslationCacheIdentity.translation(page: page, settings: settings) == FrozenFormatterIdentity.translation(page: page, settings: settings))
            let size = CGSize(width: 640, height: 960)
            let viewport = CGSize(width: 240.125, height: 360.25)
            let crop = variant == 1 ? CGRect(x: 0.5, y: 0, width: 0.5, height: 1) : CGRect(x: 0, y: 0, width: 1, height: 1)
            let actual = ReaderTranslationCacheIdentity.render(page: page, settings: settings, imageSize: size, viewport: viewport,
                scale: CGFloat(variant + 1), aspectFit: variant != 2, crop: crop, dark: variant == 2)
            let expected = FrozenFormatterIdentity.render(page: page, settings: settings, imageSize: size, viewport: viewport,
                scale: CGFloat(variant + 1), aspectFit: variant != 2, crop: crop, dark: variant == 2)
            #expect(actual == expected)
            // Intentional fences: the v5 wide-complement de-dup revision invalidates
            // OCR and every page-derived key; v316 invalidates only the visual namespace.
            let priorRawCanonical = FrozenFormatterIdentity.priorRawCanonicalRevision
            #expect(ReaderTranslationCacheIdentity.ocr(page: page, settings: settings, rawCanonicalRevision: priorRawCanonical)
                == FrozenFormatterIdentity.ocr(page: page, settings: settings, rawCanonicalRevision: priorRawCanonical))
            #expect(ReaderTranslationCacheIdentity.ocr(page: page, settings: settings)
                != FrozenFormatterIdentity.ocr(page: page, settings: settings, rawCanonicalRevision: priorRawCanonical))
            let priorNativeRenderer = FrozenFormatterIdentity.render(page: page, settings: settings, imageSize: size, viewport: viewport,
                scale: CGFloat(variant + 1), aspectFit: variant != 2, crop: crop, dark: variant == 2,
                renderRevision: "reader-render-v256-native-source-style-cohort-reflow")
            #expect(actual != priorNativeRenderer)
        }
    }
}

private enum FrozenFormatterIdentity {
    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest((try? encoder.encode(value)) ?? Data())
    }
    /// Intentional raw-canonical fence after the wide-complement de-dup fix.
    /// Bumping NativeOCRRawCanonicalPolicy.version must also update this literal.
    static let rawCanonicalRevision = "main-source-anchor-long104-legacy-short-consensus-isolated-groups-wide-complement-dedup-v5"
    static let priorRawCanonicalRevision = "main-source-anchor-long104-legacy-short-consensus-isolated-groups-wide-v4"
    // Independent replica of the persisted OCR key recipe. Schema literals and the
    // composition order are frozen here; policy versions owned by their modules
    // and runtime/env-selected routes are read from production, as before.
    static func ocr(page: String, settings: ReaderTranslationSettings,
                    rawCanonicalRevision: String = rawCanonicalRevision) -> String {
        let detectorPreprocessingABI: String
        if #available(iOS 18.0, *) {
            detectorPreprocessingABI = NativeCoreMLDetectionPreprocessor.provenanceABI
        } else { detectorPreprocessingABI = "native-db-unavailable-before-ios18" }
        var key = encoded(["reader-ocr-" + NativeParagraphFragmentGrouping.policyVersion, detectorPreprocessingABI,
            NativeOCRPremergePolicyBundle.cacheVersion, NativeFinalOutputDuplicateResolver.policyVersion,
            NativeFinalOutputContentFilter.admissionPolicyVersion, NativePostMergeSignalFilter.policyVersion,
            rawCanonicalRevision, NativePostLLMContentReclassifier.policyVersion,
            page, encoded(settings.ocrConfiguration)])
        let nomination = NativeCausalRFNominationPolicy.configured()
        if nomination != .legacy { key = encoded([key, nomination.cacheVersion]) }
        if NativeCausalRFLongitudinalSampling.configuredFraction != 0 {
            key = encoded([key, NativeCausalRFLongitudinalSampling.cacheVersion])
        }
        let acceptance = NativeCausalRFParagraphRecognition.Policy.configured()
        if acceptance.parameterGrid {
            key = encoded([key, "rf-padded-actual-read-grid-v1", String(acceptance.minimumConfidence)])
        }
        if NativeCausalRFComponentParagraphRequests.runtimeEnabled {
            key = encoded([key, NativeCausalRFComponentParagraphRequests.cacheVersion])
        }
        if NativeCausalRFAdaptiveSampling.runtimeEnabled { key = encoded([key, NativeCausalRFAdaptiveSampling.cacheVersion]) }
        if NativeCausalRFOriginalContextRecovery.runtimeEnabled {
            key = encoded([key, NativeCausalRFOriginalContextRecovery.policy])
        }
        if #available(iOS 18.0, *) {
            let manga = settings.ocrConfiguration.modelTier == .manga
            key = encoded([key, NativeOCRRFPrimaryEnsemble.policyVersion,
                manga ? NativeOCRDirectionGeometry.policyVersion : "direction-profile-legacy",
                manga ? NativeCoreMLRecognitionPreprocessor.mangaWidthPolicyVersion : "recognition-width-legacy",
                manga ? NativeOCRIndependentLanes.policyVersion : "independent-lanes-disabled",
                "db-unclip=" + String(settings.ocrConfiguration.detectorPostprocessConfiguration.unclipRatio)])
        }
        let sourceReaderKeys = ["AIDOKU_OCR_RF_CLOSED_COLUMN_NOMINATION",
            "AIDOKU_OCR_UNRETAINED_READ_SUPPORT", "AIDOKU_OCR_ORIGINAL_PACKET_EXTENT",
            "AIDOKU_OCR_ORIGINAL_PACKET_CROSS_EXTENT", "AIDOKU_OCR_ORIGINAL_PACKET_SEGMENTS",
            "AIDOKU_OCR_ORIGINAL_PRIMARY_SOURCE_JOIN",
            "AIDOKU_OCR_ORIGINAL_PACKET_MIN_CONFIDENCE", "AIDOKU_OCR_CAUSAL_UNOWNED_CONTEXT",
            "AIDOKU_OCR_CAUSAL_UNOWNED_COMPETITION",
            "AIDOKU_OCR_RF_GAP_RECOVERY", "AIDOKU_OCR_RECOVERY_BUDGET", "AIDOKU_OCR_SEQUENCE_CONTEXT_RECOVERY",
            "AIDOKU_OCR_RF_ENDPOINT_COMPLETION", "AIDOKU_OCR_ENDPOINT_INK_REFINEMENT", "AIDOKU_OCR_RF_ENDPOINT_LEGACY_AXES",
            "AIDOKU_OCR_CLIPPED_EDGE_INK", "AIDOKU_OCR_RF_LANE_GAP", "AIDOKU_OCR_SOURCE_INK_COLUMNS",
            "AIDOKU_OCR_SOURCE_INK_PARTITIONS", "AIDOKU_OCR_INK_ANNOTATION_BANDS",
            "AIDOKU_OCR_RF_ORIENTED_PIXEL", "AIDOKU_OCR_RF_ORIENTED_REREAD", "AIDOKU_OCR_RF_ORIENTED_WIDTH",
            "AIDOKU_OCR_ORIENTED_PATHS"]
        let environment = ProcessInfo.processInfo.environment
        let sourceReaderValues = sourceReaderKeys.compactMap { name in environment[name].map { name + "=" + $0 } }
        if !sourceReaderValues.isEmpty { key = encoded([key, "original-source-readers-v214", encoded(sourceReaderValues)]) }
        key = encoded([key, "quoted-dot-enclosed-components-v246", TranslationBackgroundRolePolicy.version])
        if #available(iOS 18.0, *), NativeOCRRawCanonicalRuntime.sourceAnchorMode != .disabled {
            key = encoded([key, "raw-source-anchor-mode-v1", NativeOCRRawCanonicalRuntime.sourceAnchorMode.rawValue])
        }
        if #available(iOS 18.0, *), let configuration = NativeOCRRawCanonicalRuntime.simpleDeduplication {
            key = encoded([key, NativeSimpleOCRDedup.policyVersion, encoded(configuration)])
        }
        if let configuration = NativeSimpleRecognitionAdmission.configuration {
            key = encoded([key, NativeSimpleRecognitionAdmission.policyVersion, encoded(configuration)])
        }
        if let configuration = NativeSimpleOCRBoundaryExpansionRuntime.configuration {
            key = encoded([key, NativeSimpleOCRBoundaryExpansion.policyVersion, encoded(configuration)])
        }
        if #available(iOS 18.0, *), NativeCoreMLDBPostprocessor.alternateCellEnvelopeEnabled {
            key = encoded([key, NativeOCRRawCanonicalPolicy.detectorAlternatePolicyVersion])
        }
        return ReaderTranslationOrderedSourceRoute.anyEnabled
            ? encoded([key, ReaderTranslationOrderedSourceRoute.activeCacheVersion]) : key
    }
    static func translation(page: String, settings: ReaderTranslationSettings) -> String {
        let previous = unfilteredTranslation(page: page, settings: settings)
        let base = settings.rightToLeftPanelOrder ? encoded([previous, ReaderTranslationPanelOrder.cacheVersion]) : previous
        guard let filter = ReaderTranslationLanguageFilter.identity(settings: settings) else { return base }
        return encoded([base] + filter)
    }
    static func unfilteredTranslation(page: String, settings: ReaderTranslationSettings) -> String {
        let config = settings.configuration
        // Page translation has one image-required identity: the user image opt-out
        // and LLM role filters are mandatory for pages and fenced by the write policy.
        let base = encoded([
            "reader-translation-v7-symbol-preservation-state", NativePostLLMContentReclassifier.policyVersion,
            ocr(page: page, settings: settings), config.provider.rawValue, config.apiProtocol.rawValue,
            config.baseURL, config.model, config.credentialAccount, String(config.credentialGeneration), config.reasoningEffort.rawValue,
            config.instructions, settings.sourceLanguage, settings.targetLanguage, TranslationHTTPCodec.letteringPolicy,
            "literal-recovery-v1-preserve-filters-bounded-isolation",
            "page-image-required-v1", TranslationHTTPCodec.sfxPolicy, TranslationHTTPCodec.backgroundPolicy
        ])
        let policy = NativePostLLMContentReclassifier.activePolicy
        return policy == .established ? base : encoded([base, "post-llm-derived-translation-v1", policy.version])
    }
    // Every geometry/appearance input must be included to reject stale pixels after a reader change.
    // swiftlint:disable:next function_parameter_count
    static func render(page: String, settings: ReaderTranslationSettings, imageSize: CGSize, viewport: CGSize,
                       scale: CGFloat, aspectFit: Bool, crop: CGRect, dark: Bool,
                       renderRevision: String = "reader-render-v316-unchanged-symbol-source-preservation",
                       letteringFontKey: String = NativeTranslationTypography.availabilityKey) -> String {
        // Auto Layout rounds view edges to display pixels. Mathematical prefetch
        // sizes differ by tiny fractions (568.016 pt vs 568 pt); those are one raster.
        let pixelScale = max(1, scale)
        let viewport = CGSize(width: (viewport.width * pixelScale).rounded() / pixelScale,
                              height: (viewport.height * pixelScale).rounded() / pixelScale)
        let base = encoded([
            renderRevision, NativeSourceSegmentationExecution.policySHA256,
            translation(page: page, settings: settings), encoded(settings.overlay),
            encoded(imageSize), encoded(viewport), String(Double(scale)), String(aspectFit), encoded(crop), String(dark),
            "balanced-columns-v15-visible-balloon-fit", "source-rotation-v7-native-balloon-fit", letteringFontKey,
            ProcessInfo.processInfo.operatingSystemVersionString
        ])
        let variants = NativeRenderVariantPolicy.projection
        return variants.isEmpty ? base : encoded([base, encoded(variants)])
    }
}
