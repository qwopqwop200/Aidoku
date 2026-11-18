import Foundation

/// Final-owner admission from model evidence only. No raster, text statistics,
/// size, angle, aspect ratio, coordinates, page IDs or GT enter the policy.
/// Polygons are used only to associate RF predictions and measure overlap.
enum NativeFinalOutputContentFilter {
    static let policyVersion = "final-content-signals-v3-postmerge107-corroboration"
    /// Explicit process-start rollback; never derived from an owner or image.
    static let usesLegacyAdmissionRules = ProcessInfo.processInfo.environment["AIDOKU_FINAL_CONTENT_FILTER"] == "legacy"
    typealias F = NativeOCRPremergeCandidateFeatures
    static let semanticNames = NativeOCRPremergeSpatialEvidence.featureNames + NativeOCRPremergeQueryRelations.featureNames
    // Immutable schema only; do not rebuild its strings for every owner/rule check.
    static let featureNames: [String] =
        ["ocrOutputConfidence", "ocrBodyMin", "ocrBodyMean", "ocrBodyMax"]
            + ["out", "bodyMin", "bodyMean", "bodyMax"].flatMap { prefix in semanticNames.map { prefix + "." + $0 } }
    struct Context: Sendable {
        let spatial: NativeOCRPremergeSpatialEvidence
        let joint: NativeOCRPremergeQueryRelations
        init?(width: Int, height: Int, primitives: [F.RFPrimitive], queries: [NativeOCRPremergeSpatialEvidence.Query]) {
            guard let spatial = NativeOCRPremergeSpatialEvidence(width: width, height: height, primitives: primitives, queries: queries),
                let joint = NativeOCRPremergeQueryRelations(primitives: primitives, queries: queries)
            else { return nil }
            self.spatial = spatial
            self.joint = joint
        }
        func semantic(_ polygon: [F.Point]) -> [Double]? {
            guard let a = spatial.extract(polygon: polygon), let b = joint.extract(polygon: polygon) else { return nil }
            return a + b
        }
    }
    struct Condition: Codable, Sendable {
        let feature: Int
        let lower: Double?
        let upper: Double?
    }
    struct Policy: Codable, Sendable {
        let version: Int
        let featureNames: [String]
        let rules: [[Condition]]
        var isValid: Bool {
            version == 1 && featureNames == NativeFinalOutputContentFilter.featureNames && rules.count <= 4
                && rules.allSatisfy { rule in
                    (2...5).contains(rule.count) && Set(rule.map(\.feature)).count == rule.count
                        && rule.allSatisfy {
                            featureNames.indices.contains($0.feature) && ($0.lower != nil || $0.upper != nil)
                                && [$0.lower, $0.upper].compactMap { $0 }.allSatisfy { $0.isFinite && (0...1).contains($0) }
                                && ($0.lower ?? 0) <= ($0.upper ?? 1)
                        }
                }
        }
    }
    static func extract(
        output: [F.Point], confidence: Double, bodyConfidence: [Double], bodySemantic: [[Double]],
        context: Context, exactSingletonBodyPolygon: [F.Point]? = nil
    ) -> [Double]? {
        guard confidence.isFinite, (0...1).contains(confidence), !bodyConfidence.isEmpty,
            bodyConfidence.count == bodySemantic.count, bodyConfidence.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            bodySemantic.allSatisfy({ $0.count == semanticNames.count && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }),
            let outside = outputSemantic(output, bodySemantic: bodySemantic, context: context,
                                         exactSingletonBodyPolygon: exactSingletonBodyPolygon)
        else { return nil }
        var lo = bodySemantic[0]
        var hi = lo
        var mean = Array(repeating: 0.0, count: lo.count)
        for row in bodySemantic {
            for i in row.indices {
                lo[i] = min(lo[i], row[i])
                hi[i] = max(hi[i], row[i])
                mean[i] += row[i] / Double(bodySemantic.count)
            }
        }
        let result =
            [confidence, bodyConfidence.min()!, bodyConfidence.reduce(0, +) / Double(bodyConfidence.count), bodyConfidence.max()!] + outside + lo
            + mean + hi
        return result.count == featureNames.count && result.allSatisfy { $0.isFinite && (0...1.000000001).contains($0) }
            ? result.map { min(1, max(0, $0)) } : nil
    }
    private static func outputSemantic(_ output: [F.Point], bodySemantic: [[Double]], context: Context,
                                       exactSingletonBodyPolygon: [F.Point]?) -> [Double]? {
        if let packet = exactSingletonBodyPolygon, bodySemantic.count == 1,
           packet.count == output.count,
           zip(packet, output).allSatisfy({ a, b in
               a.x.bitPattern == b.x.bitPattern && a.y.bitPattern == b.y.bitPattern
           }) {
            return bodySemantic[0]
        }
        return context.semantic(output)
    }

    // One global sparse policy, calibrated on grouped historical data.
    // No image-specific values or target-count constraints are embedded.
    static let legacyPolicy = Policy(
        version: 1, featureNames: featureNames,
        rules: [
            [.init(feature: 70, lower: nil, upper: 0.4), .init(feature: 80, lower: nil, upper: 0.3), .init(feature: 2, lower: nil, upper: 0.6)],
            [.init(feature: 6, lower: nil, upper: 0.25), .init(feature: 5, lower: 0.025, upper: nil)],
            [.init(feature: 19, lower: 0.25, upper: nil), .init(feature: 70, lower: nil, upper: 0.3), .init(feature: 20, lower: 0.75, upper: nil)],
            [
                .init(feature: 8, lower: 0.6, upper: nil), .init(feature: 89, lower: nil, upper: 0.2), .init(feature: 80, lower: nil, upper: 0),
                .init(feature: 3, lower: nil, upper: 0.65),
            ],
        ])

    // TRAIN-group refit mask235 removes empirically redundant rule2, not a
    // universal implication: the complete legacy policy stays available above.
    static let defaultPolicy: Policy = usesLegacyAdmissionRules ? legacyPolicy : .init(
        version: 1, featureNames: featureNames,
        rules: [legacyPolicy.rules[0], legacyPolicy.rules[1], legacyPolicy.rules[3]])

    /// A competing RF class is not an independent negative detector witness.
    /// Keep a well-recognized original body with actual text-mask support when
    /// raw detector corroboration is unavailable or strongly agrees with it.
    /// In particular, a missing detector adapter must not become zero support.
    private static func unresolvedSourceDisagreement(_ features: [Double], detectorFeatures: [Double]?) -> Bool {
        func value(_ name: String) -> Double {
            features[featureNames.firstIndex(of: name)!]
        }
        guard value("ocrBodyMin") >= 0.9,
              value("bodyMin.rawTextSupport") >= 0.1,
              value("bodyMin.jointTextSupport") >= 0.025,
              value("bodyMin.jointTextMaskCoverage") > 0 else { return false }
        guard let detectorFeatures, detectorFeatures.count == 15,
              detectorFeatures.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              detectorFeatures[0] >= 0.5 else { return true }
        // Native source55 detector slots, aggregated bodyMin/bodyMean/bodyMax.
        // Only measured availability/confidence/current overlap are read.
        return detectorFeatures[1] >= 0.5 && detectorFeatures[3] >= 0.8 && detectorFeatures[4] >= 0.9
    }

    /// Invalid or unavailable evidence is retained, never converted to zeros.
    /// The optional vector is existing source55 detector evidence, not invented
    /// from recognition confidence or an output/source membership identifier.
    static func keep(_ features: [Double]?, policy: Policy?, detectorFeatures: [Double]? = nil) -> Bool {
        guard let policy, policy.isValid, let features, features.count == featureNames.count,
            features.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return true }
        let rejected = policy.rules.contains { rule in
            rule.allSatisfy { c in
                (c.lower.map { features[c.feature] >= $0 } ?? true) && (c.upper.map { features[c.feature] <= $0 } ?? true)
            }
        }
        guard rejected else { return true }
        return unresolvedSourceDisagreement(features, detectorFeatures: detectorFeatures)
    }
}
