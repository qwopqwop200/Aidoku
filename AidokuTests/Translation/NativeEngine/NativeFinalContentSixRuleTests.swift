import Foundation
import Testing
@testable import Aidoku

/// Small app-hosted CPU contracts; no image, model, client, transport or GT fixture.
@Suite(.serialized) @MainActor
struct NativeFinalContentSixRuleTests {
    private typealias Final = NativeFinalOutputContentFilter
    private typealias Post = NativePostMergeSignalFilter

    private struct ConditionValue: Equatable {
        let feature: Int
        let lower: Double?
        let upper: Double?
    }

    private func values(_ rules: [[Final.Condition]]) -> [[ConditionValue]] {
        rules.map { $0.map { .init(feature: $0.feature, lower: $0.lower, upper: $0.upper) } }
    }

    @Test func compiledDefaultIsSixRulesAndLegacyThresholdsAreUnchanged() throws {
        let post = try #require(Post.defaultPolicy)
        let legacyPost = try #require(Post.legacyPolicy)
        #expect(!Final.usesLegacyAdmissionRules)
        #expect(Final.featureNames.count == 92 && Post.featureNames.count == 107)
        #expect(Final.defaultPolicy.isValid && post.isValid)
        #expect(Final.defaultPolicy.rules.count + post.rules.count == 6)
        #expect((Final.defaultPolicy.rules + post.rules).reduce(0) { $0 + $1.count } == 22)
        #expect(Final.legacyPolicy.rules.count + legacyPost.rules.count == 8)
        #expect((Final.legacyPolicy.rules + legacyPost.rules).reduce(0) { $0 + $1.count } == 29)
        #expect(values(Final.defaultPolicy.rules) == values([
            Final.legacyPolicy.rules[0], Final.legacyPolicy.rules[1], Final.legacyPolicy.rules[3]
        ]))
        #expect(values(post.rules) == values([legacyPost.rules[1], legacyPost.rules[2], legacyPost.rules[3]]))
        let expectedFinal: [[ConditionValue]] = [
            [.init(feature: 70, lower: nil, upper: 0.4), .init(feature: 80, lower: nil, upper: 0.3),
             .init(feature: 2, lower: nil, upper: 0.6)],
            [.init(feature: 6, lower: nil, upper: 0.25), .init(feature: 5, lower: 0.025, upper: nil)],
            [.init(feature: 19, lower: 0.25, upper: nil), .init(feature: 70, lower: nil, upper: 0.3),
             .init(feature: 20, lower: 0.75, upper: nil)],
            [.init(feature: 8, lower: 0.6, upper: nil), .init(feature: 89, lower: nil, upper: 0.2),
             .init(feature: 80, lower: nil, upper: 0), .init(feature: 3, lower: nil, upper: 0.65)]
        ]
        let expectedPost: [[ConditionValue]] = [
            [.init(feature: 28, lower: nil, upper: 0.6), .init(feature: 31, lower: 0.1, upper: nil),
             .init(feature: 99, lower: nil, upper: 0.75), .init(feature: 101, lower: nil, upper: 0.85)],
            [.init(feature: 28, lower: nil, upper: 0.4), .init(feature: 50, lower: 0.25, upper: nil),
             .init(feature: 53, lower: nil, upper: 0.5)],
            [.init(feature: 7, lower: nil, upper: 0.05), .init(feature: 28, lower: nil, upper: 0.6),
             .init(feature: 38, lower: 0.05, upper: nil), .init(feature: 55, lower: nil, upper: 0.025),
             .init(feature: 62, lower: nil, upper: 0.15)],
            [.init(feature: 24, lower: nil, upper: 0.6), .init(feature: 38, lower: 0.05, upper: nil),
             .init(feature: 42, lower: nil, upper: 0.75), .init(feature: 65, lower: nil, upper: 0.55),
             .init(feature: 79, lower: 0.4, upper: nil)]
        ]
        #expect(values(Final.legacyPolicy.rules) == expectedFinal)
        #expect(values(legacyPost.rules) == expectedPost)
    }

    @Test func missingMalformedAndUnsupportedEvidenceAbstains() {
        for count in [0, 91, 93] {
            let malformed = Array(repeating: 0.0, count: count)
            #expect(Final.keep(malformed, policy: Final.defaultPolicy))
            #expect(Post.extract(features: malformed, detectorFeatures: nil) == nil)
        }
        #expect(Final.keep(nil, policy: Final.defaultPolicy))
        #expect(Post.decide(nil).keep && Post.decide(nil).unavailable)
        for index in 0..<92 {
            var invalid = Array(repeating: 0.0, count: 92)
            invalid[index] = .nan
            #expect(Final.keep(invalid, policy: Final.defaultPolicy))
            #expect(Post.extract(features: invalid, detectorFeatures: Array(repeating: 1, count: 15)) == nil)
        }
        var unavailable = Array(repeating: 0.0, count: 107)
        unavailable[92] = 0 // Measured adapter unavailable, not invented zero confidence.
        #expect(Post.decide(unavailable).keep && Post.decide(unavailable).unavailable)
        #expect(Post.decide(Array(unavailable.dropLast())).keep)
    }

    @Test func removedRulesAreEmpiricalPruningNotUniversalImplications() throws {
        var final = Array(repeating: 0.0, count: 92)
        for (index, value) in [(1, 0.8), (2, 0.8), (3, 0.8), (5, 0.4), (6, 0.5),
                               (19, 0.3), (20, 0.8), (70, 0.2)] {
            final[index] = value
        }
        // Valid scalar-domain counterexample: removed final2 alone can reject.
        #expect(!Final.keep(final, policy: Final.legacyPolicy))
        #expect(Final.keep(final, policy: Final.defaultPolicy))
        var post = Array(repeating: 0.0, count: 107)
        for (index, value) in [(28, 0.5), (31, 0.2), (92, 1.0), (99, 0.7), (101, 0.8)] {
            post[index] = value
        }
        let old = Post.decide(post, policy: try #require(Post.legacyPolicy))
        #expect(!old.keep && !old.unavailable && old.matchedRule == 0)
        #expect(Post.decide(post).keep && !Post.decide(post).unavailable)
    }

    @Test func selectedThresholdComparisonsRemainInclusive() throws {
        let post = try #require(Post.defaultPolicy)
        let rules: [(final: Bool, rule: [Final.Condition])] =
            Final.defaultPolicy.rules.map { (true, $0) } + post.rules.map { (false, $0) }
        for item in rules {
            var boundary = Array(repeating: 0.0, count: 107)
            boundary[92] = 1
            for condition in item.rule {
                boundary[condition.feature] = condition.lower ?? condition.upper!
            }
            func keep(_ vector: [Double]) -> Bool {
                if item.final {
                    return Final.keep(Array(vector.prefix(92)),
                        policy: .init(version: 1, featureNames: Final.featureNames, rules: [item.rule]),
                        detectorFeatures: Array(vector.suffix(15)))
                }
                return Post.decide(vector,
                    policy: .init(version: 1, featureNames: Post.featureNames, rules: [item.rule])).keep
            }
            #expect(!keep(boundary))
            for condition in item.rule {
                var outside = boundary
                if let lower = condition.lower, lower > 0 {
                    outside[condition.feature] = lower.nextDown
                } else if let upper = condition.upper, upper < 1 {
                    outside[condition.feature] = upper.nextUp
                } else { continue }
                #expect(keep(outside))
            }
        }
    }

    @Test func defaultAdmissionCacheIdentityDiffersFromExplicitLegacyIdentity() {
        #expect(Final.admissionPolicyVersion == "combined-final3-postmerge3-v2-rf-effect")
        #expect(Post.policyVersion == "postmerge-joint107-v2-reduced3")
        let current = ReaderTranslationCacheIdentity.encoded([Final.admissionPolicyVersion, Post.policyVersion])
        let legacy = ReaderTranslationCacheIdentity.encoded(["combined-final4-postmerge-v2", "postmerge-joint107-v1"])
        #expect(current != legacy)
    }
}
