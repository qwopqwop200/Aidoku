import Foundation

/// No provider/client/HTTP cache is reachable here. Approximate targets belong
/// only to a unique old-owner match, never to consensus or unknown outcomes.
enum HostMatchedRenderPlan {
    static let version = "matched-target-renderqa-preserve-unobserved-v1"
    struct Entry: Codable {
        let id: String
        let approximateTarget: String?
        let contentClass: String?
        let cachedKeep: Bool
        let preserveWithoutTarget: Bool
        let matchStatus: String
        let candidateKeys: [String]
    }
    struct Plan: Codable {
        let version: String
        let matcherVersion: String
        let entries: [Entry]
        let providerCalls: Int
        let exactHTTPResponseSynthesized: Bool
        let approximateRenderQAOnly: Bool
    }
    static func build(_ input: HostMatchedLLMFilterReplay.Input) -> Plan {
        let result = HostMatchedLLMFilterReplay.replay(input)
        let entries = result.outcomes.map { outcome in
            let target = outcome.status == "matched_existing_LLM_filter_simulation"
                && outcome.matchedCandidateKey != nil
                ? outcome.approximateTargetForRenderQA.flatMap { $0.isEmpty ? nil : $0 } : nil
            return Entry(id: outcome.callerID, approximateTarget: target,
                contentClass: outcome.contentClass, cachedKeep: outcome.keep,
                preserveWithoutTarget: target == nil, matchStatus: outcome.status,
                candidateKeys: outcome.candidateKeys)
        }
        return Plan(version: version, matcherVersion: result.policyVersion, entries: entries,
            providerCalls: 0, exactHTTPResponseSynthesized: false, approximateRenderQAOnly: true)
    }
}
