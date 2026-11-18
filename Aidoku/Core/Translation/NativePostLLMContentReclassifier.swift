import Foundation

/// Reconciles provider admission with source-bound RF and OCR model evidence.
/// No source raster, text statistics, shape, coordinates, page identity or GT
/// are inputs to a decision. RF masks are model outputs, not image samples.
enum NativePostLLMContentReclassifier {
    static let policyVersion = "post-llm-role-model-signals-v5-class-corroboration"
    static let evidenceVersion = NativeFinalOutputContentFilter.policyVersion + "-features-v2-detector"
    // Feature names derive solely from immutable model/schema constants. Do
    // not rebuild their 92 strings for every Evidence init/validation. This
    // caches only schema metadata, never observations or decision outcomes.
    private static let expectedFeatureCount = NativeFinalOutputContentFilter.featureNames.count

    /// Shared three-condition corroboration is the default. The former
    /// per-role policy remains an explicit rollback; additional admissions
    /// have unknown semantic truth, not independent role-accuracy proof.
    enum Policy: String, Codable, Sendable {
        case established
        case compactCorroboration
        /// Removal baseline: use the provider's role/flag without correction.
        case providerOnly
        /// One common positive witness across rejected semantic classes.
        case sharedModelCorroboration
        /// Small RF competition + REC baseline; no optional DET dependency.
        case normalizedCorroboration

        var version: String {
            switch self {
            case .established: return NativePostLLMContentReclassifier.policyVersion
            case .compactCorroboration: return "post-llm-role-compact-corroboration-v1"
            case .providerOnly: return "post-llm-provider-role-direct-v1"
            case .sharedModelCorroboration: return "post-llm-shared-rf-rec-det-corroboration-v1"
            case .normalizedCorroboration: return "post-llm-normalized-rf-rec-corroboration-v1"
            }
        }

        /// Only derived classification/render results depend on this choice.
        /// Preserve incumbent cache identity; never add this to raw provider
        /// requests, core OCR identity or an unchanged raw response cache key.
        var cacheProjection: [String: String] {
            self == .established ? [:] : ["postLLMRolePolicy": version]
        }
    }

    static let defaultPolicy: Policy = .normalizedCorroboration

    /// Scope around the entire page request, including cache lookup, streamed
    /// progress, classification and render. Child tasks inherit the selection;
    /// callers creating detached tasks must explicitly re-establish the scope.
    /// This shared entry point is used unchanged on macOS and iOS.
    @TaskLocal static var activePolicy: Policy = defaultPolicy

    struct Evidence: Codable, Equatable, Sendable {
        let version: String
        let features: [Double]
        let detectorFeatures: [Double]?

        init?(features: [Double]?, detectorFeatures: [Double]? = nil) {
            guard let features, Self.valid(features),
                detectorFeatures.map({ NativePostLLMContentReclassifier.validDetectorVector($0, count: 15) }) ?? true else { return nil }
            version = NativePostLLMContentReclassifier.evidenceVersion
            self.features = features
            self.detectorFeatures = detectorFeatures
        }

        var isValid: Bool {
            version == NativePostLLMContentReclassifier.evidenceVersion && Self.valid(features)
                && (detectorFeatures.map { NativePostLLMContentReclassifier.validDetectorVector($0, count: 15) } ?? true)
        }

        func value(at index: Int) -> Double? {
            if features.indices.contains(index) { return features[index] }
            let extra = index - features.count
            guard let detectorFeatures, detectorFeatures.indices.contains(extra) else { return nil }
            return detectorFeatures[extra]
        }

        private static func valid(_ features: [Double]) -> Bool {
            features.count == NativePostLLMContentReclassifier.expectedFeatureCount
                && features.allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
    }

    static let detectorNames = ["available", "confidence", "referenceIoU", "currentIoU", "currentCoverage"]
    static var featureNames: [String] {
        NativeFinalOutputContentFilter.featureNames + ["bodyMin", "bodyMean", "bodyMax"].flatMap { prefix in
            detectorNames.map { "detector." + prefix + "." + $0 }
        }
    }

    private static func validDetectorVector(_ values: [Double], count: Int) -> Bool {
        values.count == count && values.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    /// Source55 slots 8...12 contain model confidence and matched-detector
    /// overlap only. Slots for shape, source pixels and text are never read.
    static func detectorSignals(from sourceFeatures: [Double]?) -> [Double]? {
        guard let sourceFeatures, sourceFeatures.count == 55 else { return nil }
        return normalizedDetectorHead(Array(sourceFeatures[8..<13]))
    }

    private static func normalizedDetectorHead(_ values: [Double]) -> [Double]? {
        // Polygon intersection can exceed one by small rounding error.
        guard values.allSatisfy({ $0.isFinite && (0...1.001).contains($0) }) else { return nil }
        return values.map { min(1, $0) }
    }

    /// DET fallback for accepted observations when premerge policy loading
    /// abstains. Original observations remain separate from refined proposals.
    static func detectorSignals(polygon: [NativeOCRPremergeCandidateFeatures.Point],
                                baseline: [NativeOCRPremergeCandidateFeatures.Point]?,
                                originalDetectors: [NativeOCRPremergeCandidateFeatures.DetectorBox],
                                recognitionConfidence: Double) -> [Double]? {
        detectorSignals(polygon: polygon, baseline: baseline,
            inventory: NativeOCRPremergeCandidateFeatures.prepareDetectorInventory(originalDetectors),
            recognitionConfidence: recognitionConfidence)
    }

    static func detectorSignals(polygon: [NativeOCRPremergeCandidateFeatures.Point],
                                baseline: [NativeOCRPremergeCandidateFeatures.Point]?,
                                inventory: NativeOCRPremergeCandidateFeatures.DetectorInventory,
                                recognitionConfidence: Double) -> [Double]? {
        guard let values = NativeOCRPremergeCandidateFeatures.detectorHead(polygon: polygon, baseline: baseline,
            inventory: inventory, recognitionConfidence: recognitionConfidence) else { return nil }
        return normalizedDetectorHead(values)
    }

    static func detectorFeatures(bodySignals: [[Double]?]) -> [Double]? {
        guard !bodySignals.isEmpty, bodySignals.allSatisfy({
            $0.map { validDetectorVector($0, count: detectorNames.count) } ?? false
        }) else { return nil }
        let rows = bodySignals.compactMap { $0 }
        return (0..<detectorNames.count).map { i in rows.map { $0[i] }.min()! }
            + (0..<detectorNames.count).map { i in rows.reduce(0) { $0 + $1[i] } / Double(rows.count) }
            + (0..<detectorNames.count).map { i in rows.map { $0[i] }.max()! }
    }

    enum Action: String, Codable, Sendable {
        case retain, rescue, suppress
    }

    struct Rule: Codable, Sendable {
        let action: Action
        let conditions: [NativeFinalOutputContentFilter.Condition]
    }

    /// Each provider role owns its thresholds. Shared feature extraction does
    /// not imply shared admission thresholds or cross-role rule application.
    struct RolePolicy: Codable, Sendable {
        let role: RemoteTranslationTextRole
        let rules: [Rule]
    }

    private static func lower(_ name: String, _ value: Double) -> NativeFinalOutputContentFilter.Condition {
        .init(feature: featureNames.firstIndex(of: name)!, lower: value, upper: nil)
    }

    private static func upper(_ name: String, _ value: Double) -> NativeFinalOutputContentFilter.Condition {
        .init(feature: featureNames.firstIndex(of: name)!, lower: nil, upper: value)
    }

    // Source-grouped, per-role model-signal correction. Retain rules
    // corroborate provider admission before legacy suppression; extra rescue
    // and suppression are validated separately against current and historical
    // cohorts. No target labels, source pixels, shape or page IDs at runtime.
    static let rolePolicies: [RolePolicy] = [
        .init(role: .dialogue, rules: [
            .init(action: .retain, conditions: [
                upper("detector.bodyMin.referenceIoU", 0.95), lower("ocrOutputConfidence", 0.7),
            ]),
            .init(action: .retain, conditions: [
                lower("out.jointSFXClassShare", 0.75), lower("ocrOutputConfidence", 0.9),
            ]),
            .init(action: .suppress, conditions: [
                upper("bodyMax.rawTextSupport", 0.3), lower("out.jointSFXClassShare", 0.5),
                upper("ocrBodyMean", 0.75),
            ]),
            .init(action: .suppress, conditions: [
                upper("bodyMax.rawTextSupport", 0.1), upper("bodyMax.balloonInteriorCoverage", 0.05),
                upper("ocrBodyMax", 0.75),
            ]),
            .init(action: .suppress, conditions: [
                upper("bodyMax.rawTextSupport", 0.1), lower("out.jointSFXClassShare", 0.5),
                upper("ocrBodyMean", 0.9),
            ]),
            .init(action: .suppress, conditions: [
                lower("out.maskSFXOnlyCoverage", 0.5), upper("bodyMax.rawTextSupport", 0.2),
                lower("out.jointSFXClassShare", 0.6),
            ]),
            .init(action: .suppress, conditions: [
                lower("out.balloonInteriorCoverage", 0.7), upper("bodyMean.rawTextShare", 0.6),
                lower("bodyMax.jointSFXClassShare", 0.5),
            ]),
            .init(action: .suppress, conditions: [
                lower("out.maskSFXShare", 0.2), lower("out.frameInteriorCoverage", 0.2),
            ]),
            .init(action: .suppress, conditions: [
                upper("bodyMean.rawTextShare", 0.5), upper("detector.bodyMax.currentIoU", 0.8),
            ]),
        ]),
        .init(role: .narration, rules: [
            .init(action: .suppress, conditions: [
                upper("bodyMax.rawTextSupport", 0.1), upper("bodyMax.balloonInteriorCoverage", 0.05),
                upper("ocrBodyMax", 0.75),
            ]),
            .init(action: .suppress, conditions: [
                upper("out.rawTextShare", 0.7), upper("out.rawTextSupport", 0.2),
            ]),
        ]),
        .init(role: .storyText, rules: [
            .init(action: .suppress, conditions: [
                upper("bodyMax.rawTextSupport", 0.1), upper("bodyMax.balloonInteriorCoverage", 0.05),
                upper("ocrBodyMax", 0.75),
            ]),
            .init(action: .suppress, conditions: [
                upper("out.rawTextShare", 0.5), upper("out.rawTextSupport", 0.01),
            ]),
        ]),
        .init(role: .sfx, rules: [
            .init(action: .rescue, conditions: [
                lower("bodyMean.rawTextSupport", 0.6), lower("ocrBodyMean", 0.45),
                lower("bodyMean.balloonInteriorCoverage", 0.5), upper("out.maskSFXOnlyCoverage", 0.05),
            ]),
            .init(action: .rescue, conditions: [
                lower("bodyMean.rawTextSupport", 0.1), lower("ocrBodyMean", 0.45),
                lower("bodyMean.rawTextShare", 0.9), upper("out.maskSFXOnlyCoverage", 0.05),
            ]),
            .init(action: .rescue, conditions: [
                lower("bodyMean.maskTextOnlyCoverage", 0.75), upper("ocrOutputConfidence", 0.8),
                lower("out.rawTextSupport", 0.3),
            ]),
            .init(action: .rescue, conditions: [
                lower("out.jointTextClassShare", 0.9), lower("out.jointSFXClassShare", 0.1),
                lower("bodyMin.rawTextShare", 0.6),
            ]),
            .init(action: .rescue, conditions: [
                upper("detector.bodyMax.referenceIoU", 0.8), lower("out.rawSFXSupport", 0.4),
                upper("out.rawTextSupport", 0.4),
            ]),
        ]),
        .init(role: .background, rules: [
            .init(action: .rescue, conditions: [
                lower("bodyMean.rawTextSupport", 0.1), lower("ocrBodyMean", 0.45),
                lower("bodyMean.balloonInteriorCoverage", 0.5), upper("out.maskSFXOnlyCoverage", 0.05),
            ]),
            .init(action: .rescue, conditions: [
                lower("out.jointTextSupport", 0.2), upper("detector.bodyMin.referenceIoU", 0.8),
            ]),
            .init(action: .rescue, conditions: [
                lower("out.jointTextSupport", 0.2), lower("out.jointTextClassShare", 0.95),
                upper("out.rawSFXSupport", 0.05),
            ]),
            .init(action: .rescue, conditions: [
                lower("out.rawTextSupport", 0.2), upper("out.jointSFXTextSupport", 0),
                lower("detector.bodyMin.confidence", 0.9),
            ]),
        ]),
        .init(role: .error, rules: []),
    ]

    static func decision(_ segment: RemoteTranslatedSegment, evidence: Evidence?,
                         policy selectedPolicy: Policy = NativePostLLMContentReclassifier.activePolicy) -> Action? {
        // Removal must not initialize the legacy per-class policy or require
        // auxiliary evidence merely to preserve the original provider reply.
        guard selectedPolicy != .providerOnly else { return nil }
        guard let role = segment.textRole else { return nil }
        // Every common corroboration policy contains rescue rules only for
        // SFX/background. Empty-policy roles cannot use evidence; abstain
        // before validating the otherwise unused 92/107 model-signal slots.
        if selectedPolicy != .established, role != .sfx, role != .background { return nil }
        guard let evidence, evidence.isValid else { return nil }
        let admitted = segment.isSFX != true && [.dialogue, .narration, .storyText].contains(role)
        let rules: [Rule]
        switch selectedPolicy {
        case .established: rules = rolePolicies.first(where: { $0.role == role })?.rules ?? []
        case .compactCorroboration:
            rules = compactCorroborationRules
        case .sharedModelCorroboration:
            rules = sharedModelCorroborationRules
        case .normalizedCorroboration:
            rules = normalizedCorroborationRules
        case .providerOnly: return nil
        }
        for rule in rules {
            switch rule.action {
            case .retain:
                // Corroborated provider admission wins over later suppression.
                // Preserve its semantic role and translated text exactly.
                guard admitted, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            case .rescue:
                // Nonempty translation availability is a prerequisite, not a
                // linguistic feature. Never fabricate text or promote errors.
                guard !admitted, [.sfx, .background].contains(role),
                    !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            case .suppress:
                guard admitted else { continue }
            }
            if rule.conditions.allSatisfy({ condition in
                guard let value = evidence.value(at: condition.feature) else { return false }
                return (condition.lower.map { value >= $0 } ?? true) && (condition.upper.map { value <= $0 } ?? true)
            }) { return rule.action }
        }
        return nil
    }

    /// Apply to the raw response once at the display boundary. Geometry,
    /// member identities and translated text are never edited or regenerated.
    static func resolved(_ segment: RemoteTranslatedSegment, evidence: Evidence?,
                         policy: Policy = NativePostLLMContentReclassifier.activePolicy) -> RemoteTranslatedSegment {
        guard let action = decision(segment, evidence: evidence, policy: policy) else { return segment }
        return applying(action, to: segment)
    }

    /// Three shared RF witnesses, six thresholds, four model-signal slots.
    /// These corroborate rejected roles only: dialogue/narration/story text are
    /// never demoted, and error/missing roles never become story text. Selected
    /// on grouped TRAIN/DEV historical admission evidence, not semantic role GT.
    /// Extra admissions remain unverified; this is not the default policy.
    static let compactCorroborationRules: [Rule] = [
        .init(action: .rescue, conditions: [
            lower("out.rawTextSupport", 0.3), lower("out.rawTextShare", 0.7),
        ]),
        .init(action: .rescue, conditions: [
            lower("out.rawTextSupport", 0.2), upper("out.jointTextSupport", 0.025),
        ]),
        .init(action: .rescue, conditions: [
            lower("out.jointTextSupport", 0.2), lower("bodyMean.balloonInteriorCoverage", 0.025),
        ]),
    ]

    /// A deliberately small baseline, not a selected replacement. RF text and
    /// competing SFX evidence share a model family; REC and original detector
    /// confidence provide the additional families. Missing DET abstains rather
    /// than becoming invented zero confidence. No role-specific thresholds,
    /// suppression, learned normalization, pixel/shape/text or target lookup.
    /// The fixed seed is compared with TRAIN-only grouped-CV refits offline.
    static let sharedModelCorroborationRules: [Rule] = [
        .init(action: .rescue, conditions: [
            lower("out.rawTextSupport", 0.3), upper("out.rawSFXSupport", 0.2),
            lower("ocrBodyMin", 0.7), lower("detector.bodyMin.available", 0.5),
            lower("detector.bodyMin.confidence", 0.5),
        ]),
    ]

    /// Existing RF text share compares text/SFX support from the same family;
    /// REC is the additional witness. No fitted normalization or new model.
    /// One common body, three thresholds, no per-role suppression. The default
    /// favors the smaller common rule after frozen actual-Reader TRAIN/DEV
    /// preservation checks; cached roles are not semantic accuracy proof.
    static let normalizedCorroborationRules: [Rule] = [
        .init(action: .rescue, conditions: [
            lower("out.rawTextSupport", 0.2), lower("out.rawTextShare", 0.7),
            lower("ocrBodyMin", 0.7),
        ]),
    ]

    static func applying(_ action: Action, to segment: RemoteTranslatedSegment) -> RemoteTranslatedSegment {
        if action == .retain { return segment }
        var result = segment
        result.isSFX = false
        result.textRole = action == .rescue ? .storyText : .background
        return result
    }
}
