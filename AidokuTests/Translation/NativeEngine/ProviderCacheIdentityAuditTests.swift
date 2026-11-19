import Foundation
import Testing
@testable import Aidoku

struct ProviderCacheIdentityAuditTests {
    private func configuration(
        model: String = "model-a", account: String = "account-a", generation: UInt64 = 0,
        apiProtocol: RemoteTranslationProtocol = .responses, reasoning: OpenAIReasoningEffort = .none
    ) -> RemoteTranslationConfiguration {
        .init(provider: .custom, apiProtocol: apiProtocol, baseURL: "https://cache-audit.example/v1",
              model: model, credentialAccount: account, credentialGeneration: generation, reasoningEffort: reasoning)
    }

    @Test(arguments: ["model", "account", "generation"])
    func protocolFallbackDoesNotLeakAcrossProviderRoutes(field: String) async throws {
        let transport = ProviderCacheAuditTransport(rejectFirstResponses: true)
        let client = RemoteTranslationClient(credentialStore: ProviderCacheAuditCredentials(), transport: transport)
        let request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko",
            segments: [.init(id: "line", text: "Hello")])
        _ = try await client.translate(request, configuration: configuration())
        let changed = configuration(model: field == "model" ? "model-b" : "model-a",
                                    account: field == "account" ? "account-b" : "account-a",
                                    generation: field == "generation" ? 1 : 0)
        _ = try await client.translate(request, configuration: changed)
        #expect(await transport.paths == ["/v1/responses", "/v1/chat/completions", "/v1/responses"])
    }

    @Test func explicitProtocolChangeIsNotOverriddenByEarlierSuccess() async throws {
        let transport = ProviderCacheAuditTransport()
        let client = RemoteTranslationClient(credentialStore: ProviderCacheAuditCredentials(), transport: transport)
        let request = RemoteTranslationRequest(sourceLanguage: "en", targetLanguage: "ko",
            segments: [.init(id: "line", text: "Hello")])
        _ = try await client.translate(request, configuration: configuration())
        _ = try await client.translate(request, configuration: configuration(apiProtocol: .chatCompletions))
        #expect(await transport.paths == ["/v1/responses", "/v1/chat/completions"])
    }

    @Test func compactRejectionIsScopedToModelCredentialsAndReasoning() async throws {
        let client = RemoteTranslationClient(credentialStore: ProviderCacheAuditCredentials(), transport: ProviderCacheAuditTransport())
        let original = configuration()
        let originalKey = try RemoteTranslationClient.compactCapabilityKey(for: original)
        client.compactOutput.markUnsupported(originalKey)
        let changed = [configuration(model: "model-b"), configuration(account: "account-b"),
                       configuration(generation: 1), configuration(reasoning: .medium)]
        for configuration in changed {
            // A different route must still be allowed to discover its own compact capability.
            await client.prepare(configuration: configuration)
            let key = try RemoteTranslationClient.compactCapabilityKey(for: configuration)
            #expect(client.compactOutput.state(for: key) == (configuration.reasoningEffort == .none ? .eligible : .unknown))
        }
        #expect(client.compactOutput.state(for: originalKey) == .unsupported)
    }

    @Test func failedProtocolFollowerDoesNotClearLeadersInFlightProbe() async throws {
        let registry = CustomProtocolPreferenceRegistry()
        let key = CustomProtocolPreferenceRegistry.Key(provider: .custom,
            endpointNamespace: "https://cache-audit.example/v1", configuredProtocol: .responses,
            model: "model-a", credentialAccount: "account-a", credentialGeneration: 0)
        let leader = await registry.begin(key: key, configured: .responses)
        let token = try #require(leader.failureOwnershipToken)
        let follower = await registry.begin(key: key, configured: .responses)
        #expect(follower.failureOwnershipToken == nil)
        await registry.finishProbeFailure(key: key, token: follower.failureOwnershipToken)
        let next = await registry.begin(key: key, configured: .responses)
        guard case let .probeFollower(nextToken, _) = next else {
            Issue.record("Follower failure discarded the still running leader's protocol probe")
            return
        }
        #expect(nextToken == token)
        await registry.finishProbeFailure(key: key, token: token)
        let replacement = await registry.begin(key: key, configured: .responses)
        #expect(replacement.failureOwnershipToken != nil)
        #expect(replacement.failureOwnershipToken != token)
    }

    @Test func imageCapabilityAndRevisionSurviveNewRegistryInstance() throws {
        let suite = "ProviderCacheIdentityAudit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = configuration()
        let first = TranslationImageSupport(defaults: defaults)
        first.record(.unsupported, for: original)
        let revision = first.revision(for: original)
        let reopened = TranslationImageSupport(defaults: defaults)
        #expect(reopened.status(for: original) == .unsupported)
        #expect(reopened.revision(for: original) == revision)
        reopened.record(.unsupported, for: original)
        #expect(reopened.revision(for: original) == revision)
        #expect(reopened.status(for: configuration(generation: 1)) == .unknown)
    }
}

private struct ProviderCacheAuditCredentials: TranslationCredentialProviding {
    func secret(for account: String) throws -> String { "test-only" }
}

private actor ProviderCacheAuditTransport: TranslationHTTPTransport {
    private(set) var paths: [String] = []
    private let rejectFirstResponses: Bool

    init(rejectFirstResponses: Bool = false) { self.rejectFirstResponses = rejectFirstResponses }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        let url = try #require(request.url)
        paths.append(url.path)
        let rejects = rejectFirstResponses && paths.count == 1 && url.lastPathComponent == "responses"
        let metadata = url.lastPathComponent == "models"
        let response = try #require(HTTPURLResponse(url: url, statusCode: rejects ? 404 : 200,
            httpVersion: nil, headerFields: metadata ? ["X-vLLM-Version": "0.27.0"] : nil))
        if rejects || metadata { return .init(data: Data("{}".utf8), response: response) }
        let text = #"{"translations":[{"id":"line","text":"안녕하세요"}]}"#
        let envelope: [String: Any] = url.lastPathComponent == "responses"
            ? ["status": "completed", "output": [["type": "message", "status": "completed",
                "content": [["type": "output_text", "text": text]]]]]
            : ["choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": text]]]]
        return .init(data: try JSONSerialization.data(withJSONObject: envelope), response: response)
    }
}
