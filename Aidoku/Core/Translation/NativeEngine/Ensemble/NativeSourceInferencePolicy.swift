import Foundation

/// One process-wide, source-only policy selected before any auxiliary head is
/// constructed. The selected TRAIN/DEV candidate is the shared default; the
/// original accepted graph remains an explicit, cache-isolated rollback.
enum NativeSourceInferencePolicy {
    enum Mode: String, Sendable {
        case accepted
        case minimalPrimary = "minimal-primary-v1"
        case minimalRF = "minimal-rf-v1"
        case minimalM1P9Body32 = "minimal-m1-p9-body32-v1"
        case minimalM1P9Body64 = "minimal-m1-p9-body64-v1"
        case minimalM1P9Body64Presence95 = "minimal-m1-p9-body64-presence95-v1"
        case simpleFontAcceptedStyle = "simple-font-accepted-style-v1"
        case simpleFontAcceptedStyleWeight = "simple-font-accepted-style-weight-v1"
        case simpleFontAcceptedStyleBody = "simple-font-accepted-style-body-v1"
        case simpleFontAcceptedStyleBodyFixedGap = "simple-font-accepted-style-body-fixed-gap-v1"

        var m1StyleVariant: NativeM1SourceStyleInference.Variant? {
            switch self {
            case .minimalM1P9Body32: .rounds32
            case .minimalM1P9Body64, .minimalM1P9Body64Presence95: .rounds64
            default: nil
            }
        }
        var m1PresenceABI: NativeM1SourceStyleInference.PresenceABI {
            self == .minimalM1P9Body64Presence95 ? .noBackground95 : .legacy151
        }
        var usesMinimalM1Style: Bool { m1StyleVariant != nil }
        var usesMinimalObservations: Bool { self == .minimalPrimary || self == .minimalRF || usesMinimalM1Style }
        var usesAcceptedAppearance: Bool { !usesMinimalObservations }
        var usesAcceptedWeight: Bool { self == .accepted || self == .simpleFontAcceptedStyleWeight }
        var usesSingleBodyWeight: Bool {
            self == .simpleFontAcceptedStyleBody || self == .simpleFontAcceptedStyleBodyFixedGap || usesMinimalM1Style
        }
        var usesSimpleFont: Bool { self != .accepted }
    }
    struct SimpleFontConfiguration: Sendable {
        let calibration: NativeSimpleSourceFont.Calibration
        let relativeGap: Double
        var cluster: Bool = true
        var pageMedian: Bool = false
        var consistencyRule: NativeSimpleSourceFont.ConsistencyRule? = nil
        var groupedSizeScale: Double = 1
        func estimate(_ inputs: [NativeSimpleSourceFont.Input]) throws -> [Double] {
            let sizes = try NativeSimpleSourceFont.estimate(inputs, calibration: calibration,
                cluster: cluster, relativeGap: relativeGap, pageMedian: pageMedian, consistencyRule: consistencyRule)
            return groupedSizeScale == 1 ? sizes : sizes.map { $0 * groupedSizeScale }
        }
        var cacheProjection: [String: String] {
            var projection = ["sourceFontPolicy": NativeSimpleSourceFont.identity,
             "sourceFontScale": String(calibration.scale), "sourceFontBias": String(calibration.bias),
             "sourceFontBBoxShortScale": String(calibration.bboxShortScale), "sourceFontCluster": String(cluster),
             "sourceFontMemberShortScale": String(calibration.memberShortScale),
             "sourceFontMemberGeometry": NativeSourceFontGeometryFeatures.memberIdentity,
             "sourceFontCompleteLinkRelativeGap": String(relativeGap), "sourceFontPageMedian": String(pageMedian)]
            if let rule = consistencyRule {
                projection["sourceFontGroupingRule"] = NativeSimpleSourceFont.ConsistencyRule.identity
                projection["sourceFontGroupingBodyRatioWeight"] = String(rule.bodyRatioWeight)
                projection["sourceFontGroupingMaximumLogDistance"] = String(rule.maximumLogDistance)
            } else { projection["sourceFontGroupingRule"] = "fixed-relative-gap-complete-link-v1" }
            if groupedSizeScale != 1 { projection["sourceFontGroupedSizeScale"] = String(groupedSizeScale) }
            return projection
        }
    }
    /// One selected TRAIN-CV configuration shared by execution and cache keys.
    static var simpleFontConfiguration: SimpleFontConfiguration { fontConfiguration(for: selected) }
    static func fontConfiguration(for mode: Mode) -> SimpleFontConfiguration {
        let rule: NativeSimpleSourceFont.ConsistencyRule?
        if mode == .simpleFontAcceptedStyleBodyFixedGap || mode == .accepted { rule = nil }
        else { rule = .init(bodyRatioWeight: 0.8212525806130213, maximumLogDistance: 0.9705176286667344) }
        return .init(calibration: .init(scale: 0.43853239073260936, bias: 4.094089327930639,
            memberShortScale: 0.4140206805546956), relativeGap: 0.35, consistencyRule: rule,
            groupedSizeScale: mode == .minimalM1P9Body64Presence95 ? 1.0252379527066393 : 1)
    }
    enum Failure: Error { case unsupportedPolicy(String), missingM1StyleAssetDirectory, invalidM1StyleAssetDirectory }
    static let version = "minimal-source-inference-v1"
    // Fixed source-only minimal64 closure: actual primary/M1, five native44
    // style roles, physical member geometry and one whole-page BODY batch.
    // The former accepted-style BODY path remains an explicit rollback below.
    static let defaultMode: Mode = .minimalM1P9Body64Presence95
    static func resolveMode(override: String?) -> Mode? {
        Mode(rawValue: override ?? defaultMode.rawValue)
    }
    static var requestedMode: String {
        ProcessInfo.processInfo.environment["AIDOKU_SOURCE_INFERENCE_POLICY"] ?? defaultMode.rawValue
    }
    static var selected: Mode { Mode(rawValue: requestedMode) ?? .accepted }
    static func validate() throws {
        guard Mode(rawValue: requestedMode) != nil else { throw Failure.unsupportedPolicy(requestedMode) }
    }
    /// Explicit local staged assets only; missing assets fail, never fall back
    /// to accepted style or use an unpinned remotely fetched role model.
    static func stagedM1StyleDirectory(override: URL? = nil) throws -> URL? {
        try resolveStagedM1StyleDirectory(mode: selected, override: override,
            environmentPath: ProcessInfo.processInfo.environment["AIDOKU_SOURCE_M1_STYLE_ASSET_DIRECTORY"])
    }
    static func resolveStagedM1StyleDirectory(mode: Mode, override: URL? = nil, environmentPath: String? = nil) throws -> URL? {
        guard mode.usesMinimalM1Style else { return nil }
        if let override {
            guard override.isFileURL else { throw Failure.invalidM1StyleAssetDirectory }
            return override.standardizedFileURL
        }
        guard let path = environmentPath, !path.isEmpty else {
            if mode.m1StyleVariant == .rounds64 { return nil } // bundled64, authenticated by the shared page seam
            throw Failure.missingM1StyleAssetDirectory
        }
        guard path.hasPrefix("/") else { throw Failure.invalidM1StyleAssetDirectory }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    static let primaryM1Configuration = NativeMinimalSourceSegmentation.Configuration(
        mode: .primaryOnly, threshold: 0.25, closingRadius: 1,
        weakRecovery: .init(minimumPrimaryProbability: 0.01, radius: 2))
    static var minimalSegmentationConfiguration: NativeMinimalSourceSegmentation.Configuration? {
        switch selected {
        case .accepted, .simpleFontAcceptedStyle, .simpleFontAcceptedStyleWeight,
             .simpleFontAcceptedStyleBody, .simpleFontAcceptedStyleBodyFixedGap: nil
        case .minimalPrimary, .minimalM1P9Body32, .minimalM1P9Body64, .minimalM1P9Body64Presence95: primaryM1Configuration
        case .minimalRF: .init(mode: .rfTextOnly, threshold: 0.5, closingRadius: 0)
        }
    }
    /// Erasure consumes already-computed p. Rich feature masks remain unchanged
    /// for accepted colour/body inference; this does not remove their producers.
    /// Erasure-only typed selector; feature/style observations keep M1.
    enum ErasurePolicy: String, Sendable {
        case originalM1 = "original-M1-p025-weak001-r2-close1"
        case mild = "M1-without-closing-p025-weak001-r2-close0"
        case strong = "weak-noise-cleanup-p025-weak01-r1-close0"
    }
    // Residual text is harder to repair than extra covered pixels. Prefer the
    // higher-recall M1 mask; downstream owner and RF protection still apply.
    static let defaultErasurePolicy: ErasurePolicy = .originalM1
    static func primaryErasureConfiguration(_ policy: ErasurePolicy) -> NativeMinimalSourceSegmentation.Configuration {
        switch policy {
        case .originalM1: primaryM1Configuration
        case .mild: .init(mode: .primaryOnly, threshold: 0.25, closingRadius: 0,
            weakRecovery: .init(minimumPrimaryProbability: 0.01, radius: 2))
        case .strong: .init(mode: .primaryOnly, threshold: 0.25, closingRadius: 0,
            weakRecovery: .init(minimumPrimaryProbability: 0.1, radius: 1))
        }
    }
    static var erasureSegmentationConfiguration: NativeMinimalSourceSegmentation.Configuration? {
        erasureConfiguration(for: selected)
    }
    static func erasureConfiguration(for mode: Mode, erasurePolicy: ErasurePolicy = defaultErasurePolicy)
        -> NativeMinimalSourceSegmentation.Configuration? {
        switch mode {
        case .accepted, .minimalRF: nil
        case .minimalPrimary, .minimalM1P9Body32, .minimalM1P9Body64, .minimalM1P9Body64Presence95, .simpleFontAcceptedStyle, .simpleFontAcceptedStyleWeight,
             .simpleFontAcceptedStyleBody, .simpleFontAcceptedStyleBodyFixedGap:
            primaryErasureConfiguration(erasurePolicy)
        }
    }
    /// Root render/source cache projection consumes this declarative identity.
    /// No resource lookup, registry parse, model loading or image work occurs.
    static var cacheProjection: [String: String] {
        guard selected != .accepted else {
            var identity = ["sourcePrimaryFeatureSamplingPolicy": NativePixelRFFeatures.samplingPolicyVersion]
            if requestedMode != Mode.accepted.rawValue { identity["sourceInferenceInvalidPolicy"] = requestedMode }
            return identity
        }
        var projection = ["sourceInferencePolicy": version,
            "sourceInferenceMode": selected.rawValue,
            "sourceCropPolicy": NativeSourceInputFactory.sourceCropPolicyVersion,
            "sourcePrimaryFeatureSamplingPolicy": selected == .minimalRF ? "not-executed" : NativePixelRFFeatures.samplingPolicyVersion,
            "sourceAppearancePolicy": selected.usesAcceptedAppearance ? "accepted-source-appearance-graph-v1" : NativePhysicalSourceStyle.revision,
            "sourceBoldPolicy": selected.usesAcceptedWeight ? "accepted-bbox-font-context-weight-v1" :
                (selected.usesAcceptedAppearance ? "accepted-fill-physical-density-v1" : "physical-source-stem-density-v1"),
            "sourceBoldThreshold": selected.usesAcceptedWeight ? "frozen-weight-graph-policy" :
                (selected.usesAcceptedAppearance ? "0.1" : "0.12"),
            "sourceShadowPolicy": selected.usesAcceptedAppearance ? "accepted-source-shadow-observation" : "off-no-observation"]
        projection.merge(simpleFontConfiguration.cacheProjection, uniquingKeysWith: { _, current in current })
        if let variant = selected.m1StyleVariant {
            projection["sourceAppearancePolicy"] = NativeM1SourceStyleInference.revision
            projection["sourceM1StyleCandidate"] = variant.candidateID
            projection["sourceM1StyleAssetsAndWidthIdentity"] = NativeM1SourceStyleInference.cacheIdentity(
                for: variant, presenceABI: selected.m1PresenceABI)
            if selected.m1PresenceABI == .noBackground95 {
                projection["sourceM1PresenceABI"] = selected.m1PresenceABI.rawValue
                projection["sourceM1PresenceAssetResolution"] = "pinned95-from-selected-model-directory"
            }
            projection["sourceM1StyleFeatureABI"] = NativeM1SourceStyleFeatures44.revision
            projection["sourceM1StyleWidthCalibration"] = variant.calibration.identity
            projection["sourceShadowPolicy"] = "learned-presence-only;intrinsic-paint-unknown"
            projection["sourceAuxiliaryHeadClosure"] = "1primary62+5styleRoles+1BODY180;RF-layout-upstream-retained"
            projection["sourceBodyFontAdmission"] = "compact pinned BASE4 init+per-crop; no unused12 banks/full metadata"
            projection["sourceBodyFontInitializer"] = NativeM1SourcePageInference.bodyFontInitializerIdentity
            projection["sourceBodyFontSpecSHA256"] = NativeM1SourcePageInference.bodyBase4SpecSHA256
            projection["sourceBODYIntrinsicMetricsExecutionRevision"] = NativeM1SourcePageInference.bodyIntrinsicMetricsExecutionRevision
            projection["sourceBODYIntrinsicMetricsCacheDeclaration"] = NativeM1SourcePageInference.bodyIntrinsicMetricsCacheDeclaration
            projection["sourceM1PageInference"] = NativeM1SourcePageInference.revision
            projection["sourceM1AssetResolution"] = variant == .rounds64 ? "bundled64-or-verified-local-override" : "verified-local-override-required"
            projection["sourceBODYLoader"] = "compact-registry-direct-role;no-appearance-policy-metadata-head-loader"
        }
        if selected.usesSingleBodyWeight {
            projection["sourceBoldPolicy"] = NativeSingleBodyWeightInference.revision
            projection["sourceBoldThreshold"] = String(NativeSingleBodyWeightInference.threshold)
            projection["sourceBoldModel"] = NativeSingleBodyWeightInference.modelIdentity
            projection["sourceBoldModelSHA256"] = NativeSingleBodyWeightInference.modelSHA256
            projection["sourceBoldFeatureSchema"] = "Double-raw597-original-prior-pageContext1791-v1"
            // Numeric outputs are unchanged, but old generic-bridge cache
            // entries must not attest the dedicated bridge's reduced work.
            projection["sourceBoldMeasurementBridge"] = selected.usesMinimalM1Style ?
                NativeSingleBodyWeightInference.MeasurementABI.base4.rawValue :
                NativeSingleBodyWeightInference.MeasurementABI.genericAdmission.rawValue
        }
        let featureSegmentation = minimalSegmentationConfiguration
        if let segmentation = featureSegmentation {
            projection["sourceSegmentationMode"] = segmentation.mode.rawValue
            projection["sourceSegmentationThreshold"] = String(segmentation.threshold)
            projection["sourceSegmentationClosingRadius"] = String(segmentation.closingRadius)
            projection["sourceSegmentationPolicySHA256"] = segmentation.policySHA256
            if let weak = segmentation.weakRecovery {
                projection["sourceSegmentationWeakFloor"] = String(weak.minimumPrimaryProbability)
                projection["sourceSegmentationWeakRadius"] = String(weak.radius)
                projection["sourceSegmentationWeakAnchorPolicy"] = "original-primary-threshold-mask;single-step-chebyshev-before-close"
            }
        } else {
            projection["sourceSegmentationMode"] = "accepted-selected-actual-rich-observations"
        }
        if let erasure = erasureSegmentationConfiguration {
            projection["sourceErasurePolicySHA256"] = erasure.policySHA256
            projection["sourceErasureSelection"] = defaultErasurePolicy.rawValue
            projection["sourceErasureMode"] = erasure == featureSegmentation
                ? "M1-from-single-actual-primary;shared-style-and-erasure-mask"
                : "independent-primary-postprocess;feature-style-masks-unchanged;no-extra-head"
        }
        return projection
    }
}
