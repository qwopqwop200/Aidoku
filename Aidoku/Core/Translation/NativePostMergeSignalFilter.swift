import Foundation

/// Admission of complete merged owners from measured REC/RF/DET signals.
/// No image samples, text, absolute geometry, source IDs or GT are predictors.
enum NativePostMergeSignalFilter {
    static let policyVersion = NativeFinalOutputContentFilter.usesLegacyAdmissionRules
        ? "postmerge-joint107-v1" : "postmerge-joint107-v2-reduced3"
    // The feature ABI never depends on a page or a decision.
    static let featureNames: [String] = NativePostLLMContentReclassifier.featureNames
    typealias Condition = NativeFinalOutputContentFilter.Condition

    struct Policy: Codable, Sendable {
        let version: Int
        let featureNames: [String]
        let rules: [[Condition]]

        var isValid: Bool {
            version == 1 && featureNames == NativePostMergeSignalFilter.featureNames &&
                (1...4).contains(rules.count) && rules.allSatisfy { rule in
                    (2...5).contains(rule.count) && Set(rule.map(\.feature)).count == rule.count &&
                        rule.allSatisfy { condition in
                            featureNames.indices.contains(condition.feature) &&
                                (condition.lower != nil || condition.upper != nil) &&
                                [condition.lower, condition.upper].compactMap { $0 }.allSatisfy {
                                    $0.isFinite && (0...1).contains($0)
                                } && (condition.lower ?? 0) <= (condition.upper ?? 1)
                        }
                }
        }
    }

    struct Decision: Codable, Sendable {
        let keep: Bool
        let matchedRule: Int?
        let unavailable: Bool
        let sourceEvidenceProtected: Bool
    }

    // Global confidence/RF/DET thresholds; no page, source or GT lookup.
    // The member-conservation guard below is mandatory for this rule policy.
    static let legacyPolicy: Policy? = .init(version: 1, featureNames: featureNames, rules: [
            [
                .init(feature: 28, lower: nil, upper: 0.6),
                .init(feature: 31, lower: 0.1, upper: nil),
                .init(feature: 99, lower: nil, upper: 0.75),
                .init(feature: 101, lower: nil, upper: 0.85)
            ],
            [
                .init(feature: 28, lower: nil, upper: 0.4),
                .init(feature: 50, lower: 0.25, upper: nil),
                .init(feature: 53, lower: nil, upper: 0.5)
            ],
            [
                .init(feature: 7, lower: nil, upper: 0.05),
                .init(feature: 28, lower: nil, upper: 0.6),
                .init(feature: 38, lower: 0.05, upper: nil),
                .init(feature: 55, lower: nil, upper: 0.025),
                .init(feature: 62, lower: nil, upper: 0.15)
            ],
            [
                .init(feature: 24, lower: nil, upper: 0.6),
                .init(feature: 38, lower: 0.05, upper: nil),
                .init(feature: 42, lower: nil, upper: 0.75),
                .init(feature: 65, lower: nil, upper: 0.55),
                .init(feature: 79, lower: 0.4, upper: nil)
            ]
        ])

    // Rule0 did not fire in the frozen OLD corpus; this is empirical pruning,
    // not a claim that it can never fire on another detector geometry.
    static let defaultPolicy: Policy? = NativeFinalOutputContentFilter.usesLegacyAdmissionRules
        ? legacyPolicy : legacyPolicy.map {
            .init(version: 1, featureNames: featureNames, rules: [$0.rules[1], $0.rules[2], $0.rules[3]])
        }

    static func extract(features: [Double]?, detectorFeatures: [Double]?) -> [Double]? {
        guard let features, features.count == 92,
              let detectorFeatures, detectorFeatures.count == 15 else { return nil }
        let values = features + detectorFeatures
        return values.allSatisfy { $0.isFinite && (0...1).contains($0) } ? values : nil
    }

    static func decide(_ values: [Double]?, policy: Policy? = defaultPolicy) -> Decision {
        guard let policy, policy.isValid, let values, values.count == featureNames.count,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let availability = featureNames.firstIndex(of: "detector.bodyMin.available"),
              values[availability] >= 0.5 else {
            return .init(keep: true, matchedRule: nil, unavailable: true, sourceEvidenceProtected: false)
        }
        let rule = policy.rules.firstIndex { rule in
            rule.allSatisfy { condition in
                let value = values[condition.feature]
                return (condition.lower.map { value >= $0 } ?? true) &&
                    (condition.upper.map { value <= $0 } ?? true)
            }
        }
        let protected = rule != nil && possibleSupportedMember(values)
        return .init(keep: rule == nil || protected, matchedRule: rule, unavailable: false,
                     sourceEvidenceProtected: protected)
    }

    /// Maxima can come from different packets, so they do not prove a jointly
    /// corroborated source. They conservatively bound whether such a source
    /// could remain in the merged owner. Abstain when it cannot be ruled out,
    /// using the same source-corroboration cutoffs as the existing final filter.
    private static func possibleSupportedMember(_ values: [Double]) -> Bool {
        func value(_ name: String) -> Double { values[featureNames.firstIndex(of: name)!] }
        return value("ocrBodyMax") >= 0.9 && value("bodyMax.rawTextSupport") >= 0.1 &&
            value("bodyMax.jointTextSupport") >= 0.025 && value("bodyMax.jointTextMaskCoverage") > 0 &&
            value("detector.bodyMax.available") >= 0.5 && value("detector.bodyMax.confidence") >= 0.5 &&
            value("detector.bodyMax.currentIoU") >= 0.8 && value("detector.bodyMax.currentCoverage") >= 0.9
    }

    static func keep(features: [Double]?, detectorFeatures: [Double]?) -> Bool {
        decide(extract(features: features, detectorFeatures: detectorFeatures)).keep
    }
}
