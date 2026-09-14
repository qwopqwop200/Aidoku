import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationNetworkTests {
    @Test func keychainRoundTripDoesNotUseUserDefaults() throws {
        let store = KeychainTranslationCredentialStore(service: "AidokuTests.\(UUID().uuidString)")
        let account = "test-only"
        defer { try? store.deleteSecret(for: account) }
        #expect(try !store.containsSecret(for: account))
        try store.save("test-key-never-sent", for: account)
        #expect(try store.containsSecret(for: account))
        #expect(try store.secret(for: account) == "test-key-never-sent")
        try store.deleteSecret(for: account)
        #expect(try !store.containsSecret(for: account))
    }

    @Test func readerUsesResponsesAndCachesByLanguageAndCredential() async throws {
        let transport = ReaderTranslationTransport()
        let service = ReaderTranslationService(client: RemoteTranslationClient(
            credentialStore: ReaderTestCredential(), transport: transport
        ))
        let regions = [ReaderTranslationRegion(id: "region-9", rect: .zero, source: "こんにちは")]
        var settings = ReaderTranslationSettings()
        settings.provider = .openAI
        settings.targetLanguage = "ko"
        let first = try await service.translate(regions: regions, settings: settings)
        #expect(first.first?.id == "region-9")
        #expect(first.first?.translation == "ko:こんにちは")
        _ = try await service.translate(regions: regions, settings: settings)
        #expect(await transport.requests.count == 1)
        settings.targetLanguage = "en"
        let second = try await service.translate(regions: regions, settings: settings)
        #expect(second.first?.translation == "en:こんにちは")
        #expect(await transport.requests.count == 2)
        settings.credentialGeneration += 1
        _ = try await service.translate(regions: regions, settings: settings)
        #expect(await transport.requests.count == 3)
        try await service.clearCache()
        _ = try await service.translate(regions: regions, settings: settings)
        #expect(await transport.requests.count == 4)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-only")
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["store"] as? Bool == false)
        #expect(!(String(data: body, encoding: .utf8) ?? "").contains("input_image"))
        #expect(!(String(data: body, encoding: .utf8) ?? "").contains("unit-test-only"))
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions])
    func readerUsesCustomProtocolModelAndOnlyItsOwnKey(apiProtocol: RemoteTranslationProtocol) async throws {
        let transport = ReaderTranslationTransport()
        let keys = KeychainTranslationCredentialStore(service: "AidokuTests.Custom.\(UUID().uuidString)")
        let suite = "AidokuTests.Custom.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.apiProtocol = apiProtocol
        settings.custom.baseURL = "https://first.example/gateway/v1"
        settings.model = "my-model"
        let firstAccount = settings.selectedCredentialAccount
        try keys.save("custom-first", for: firstAccount)
        try keys.save("openai-only", for: "openai")
        defer {
            try? keys.deleteSecret(for: firstAccount)
            try? keys.deleteSecret(for: "openai")
        }
        let service = ReaderTranslationService(client: RemoteTranslationClient(credentialStore: keys, transport: transport))
        let regions = [ReaderTranslationRegion(id: "custom-region", rect: .zero, source: "Hello")]
        let first = try await service.translate(regions: regions, settings: settings)
        #expect(first.first?.translation == "ko:Hello")
        _ = try await service.translate(regions: regions, settings: settings)
        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        let suffix = apiProtocol == .responses ? "/responses" : "/chat/completions"
        #expect(request.url?.absoluteString == "https://first.example/gateway/v1" + suffix)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer custom-first")
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["model"] as? String == "my-model")
        #expect(apiProtocol == .responses ? root["input"] != nil : root["messages"] != nil)
        #expect(apiProtocol == .responses ? root["text"] != nil : root["response_format"] != nil)
        #expect(!String(decoding: body, as: UTF8.self).contains("input_image"))

        settings.custom.baseURL = "https://second.example/v1"
        do {
            _ = try await service.translate(regions: first, settings: settings)
            Issue.record("A new server must never reuse the first server's cached result or key")
        } catch let error as RemoteTranslationError { #expect(error == .missingCredential) }
        #expect(await transport.requests.count == 1)
        let secondAccount = settings.selectedCredentialAccount
        try keys.save("custom-second", for: secondAccount)
        defer { try? keys.deleteSecret(for: secondAccount) }
        _ = try await service.translate(regions: first, settings: settings)
        #expect(await transport.requests.count == 2)
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer custom-second")
        settings.provider = .openAI
        _ = try await service.translate(regions: first, settings: settings)
        #expect(await transport.requests.count == 3)
        #expect(await transport.requests.last?.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer openai-only")
    }

    @Test(arguments: [404, 405, 501])
    func customFallbackHandlesFullEndpointAndResponsesReasoning(status: Int) async throws {
        let transport = ReaderTranslationTransport(responsesFailure: status)
        let client = RemoteTranslationClient(credentialStore: ReaderTestCredential(), transport: transport)
        let configuration = RemoteTranslationConfiguration(
            provider: .custom, apiProtocol: .responses,
            baseURL: "https://translator.example/proxy/v1/responses",
            model: "custom-model", credentialAccount: "custom-test", reasoningEffort: .high
        )
        let request = RemoteTranslationRequest(sourceLanguage: "auto", targetLanguage: "ko", sourceText: "Hello")
        let result = try await client.translate(request, configuration: configuration)
        #expect(result.translations.first?.text == "ko:Hello")
        #expect(await transport.requests.map { $0.url!.path } == ["/proxy/v1/responses", "/proxy/v1/chat/completions"])
        _ = try await client.translate(request, configuration: configuration)
        #expect(await transport.requests.count == 3)
        #expect(await transport.requests.last?.url?.path == "/proxy/v1/chat/completions")
        let body = try #require(await transport.requests.last?.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["reasoning"] == nil)
        #expect(root["reasoning_effort"] as? String == "high")
    }

    @Test func customAuthenticationFailureDoesNotTryAnotherProtocol() async throws {
        let transport = ReaderTranslationTransport(responsesFailure: 401)
        let client = RemoteTranslationClient(credentialStore: ReaderTestCredential(), transport: transport)
        do {
            _ = try await client.translate(
                .init(sourceLanguage: "auto", targetLanguage: "ko", sourceText: "Hello"),
                configuration: .init(provider: .custom, apiProtocol: .responses,
                                     baseURL: "https://translator.example/v1", model: "custom-model", credentialAccount: "custom-test")
            )
            Issue.record("Authentication failure should fail")
        } catch let error as RemoteTranslationError { #expect(error == .httpStatus(401, requestID: nil)) }
        #expect(await transport.requests.count == 1)
    }

    @Test func missingCredentialDoesNotSendRequest() async throws {
        let transport = ReaderTranslationTransport()
        let client = RemoteTranslationClient(credentialStore: ReaderTestCredential(missing: true), transport: transport)
        do {
            _ = try await client.translate(
                .init(sourceLanguage: "auto", targetLanguage: "ko", sourceText: "Hello"),
                configuration: .openAI(model: "gpt-5-mini")
            )
            Issue.record("Missing credential should fail")
        } catch let error as RemoteTranslationError {
            #expect(error == .missingCredential)
        }
        #expect(await transport.requests.isEmpty)
    }
}

private struct ReaderTestCredential: TranslationCredentialProviding {
    var missing = false
    func secret(for account: String) throws -> String {
        if missing { throw TranslationCredentialStoreError.notFound }
        return "unit-test-only"
    }
}

private actor ReaderTranslationTransport: TranslationHTTPTransport {
    private(set) var requests: [URLRequest] = []
    let responsesFailure: Int?

    init(responsesFailure: Int? = nil) { self.responsesFailure = responsesFailure }

    func data(for request: URLRequest, maximumResponseBytes: Int, bypassesProxy: Bool) async throws -> TranslationHTTPResponse {
        requests.append(request)
        let body = try #require(request.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let isResponses = request.url?.lastPathComponent == "responses"
        if isResponses, let responsesFailure {
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: responsesFailure, httpVersion: nil, headerFields: nil))
            return TranslationHTTPResponse(data: Data(), response: response)
        }
        let text: String
        if isResponses {
            let input = try #require(root["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            text = try #require(content.first?["text"] as? String)
        } else {
            let messages = try #require(root["messages"] as? [[String: Any]])
            text = try #require(messages.first(where: { $0["role"] as? String == "user" })?["content"] as? String)
        }
        let data = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let language = try #require(data["target_language"] as? String)
        let segments = try #require(data["segments"] as? [[String: String]])
        let translations = segments.map { ["id": $0["id"] ?? "", "text": language + ":" + ($0["text"] ?? "")] }
        let output = try JSONSerialization.data(withJSONObject: ["translations": translations])
        let envelope: [String: Any] = isResponses ? [
            "status": "completed",
            "output": [["type": "message", "status": "completed", "content": [
                ["type": "output_text", "text": (String(data: output, encoding: .utf8) ?? "")]
            ]]]
        ] : ["choices": [["index": 0, "finish_reason": "stop", "message": [
            "role": "assistant", "content": String(decoding: output, as: UTF8.self)
        ]]]]
        let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
        return TranslationHTTPResponse(data: try JSONSerialization.data(withJSONObject: envelope), response: response)
    }
}

@Suite(.serialized) @MainActor
struct ReaderTranslationValidationTests {
    @Test func explicitActivationRechecksAfterCachedNetworkFailureAndSuccess() async throws {
        let transport = ReaderTranslationTransport()
        let validator = ReaderTranslationAPIValidator(client: RemoteTranslationClient(
            credentialStore: ReaderTestCredential(), transport: transport))
        var settings = ReaderTranslationSettings()
        settings.provider = .openAI
        try await validator.validateForActivation(settings)
        validator.recordFailure(URLError(.notConnectedToInternet), settings: settings)
        try await validator.validateFreshForActivation(settings)
        #expect(await transport.requests.count == 2)
        try await validator.validateFreshForActivation(settings)
        #expect(await transport.requests.count == 3)
    }

    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions], OpenAIReasoningEffort.allCases)
    func probeUsesSavedSettingsWithoutChangingEffort(apiProtocol: RemoteTranslationProtocol, effort: OpenAIReasoningEffort) async throws {
        let transport = ReaderTranslationTransport()
        let validator = ReaderTranslationAPIValidator(client: RemoteTranslationClient(
            credentialStore: ReaderTestCredential(), transport: transport
        ), onFailure: { _ in Issue.record("Probe should succeed") })
        let suite = "AidokuTests.Validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://translator.example/v1"
        settings.custom.apiProtocol = apiProtocol
        settings.model = "configured-model"
        settings.reasoningEffort = effort
        validator.refresh(settings) // App opening starts this in the background.
        for _ in 0..<4 { try await validator.validateForActivation(settings) }
        #expect(await transport.requests.count == 1)
        #expect(settings.reasoningEffort == effort)
        let body = try #require(await transport.requests.first?.httpBody)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["model"] as? String == "configured-model")
        let encodedEffort = apiProtocol == .responses ? (root["reasoning"] as? [String: Any])?["effort"] as? String : root["reasoning_effort"] as? String
        #expect(encodedEffort == (effort == .modelDefault ? nil : effort.rawValue))
        #expect(!(String(decoding: body, as: UTF8.self)).contains("input_image"))
        settings.automaticallyTranslate.toggle()
        settings.overlay.opacity = 0.5
        validator.refresh(settings)
        try await validator.validateForActivation(settings)
        #expect(await transport.requests.count == 1)
        settings.reasoningEffort = effort == .low ? .high : .low
        validator.refresh(settings)
        try await validator.validateForActivation(settings)
        #expect(await transport.requests.count == 2)
        validator.refresh(settings, force: true) // A new app opening.
        try await validator.validateForActivation(settings)
        #expect(await transport.requests.count == 3)
    }

    @Test(arguments: [400, 401, 422, 500])
    func failedProbeStaysOffWithoutRepeatedRequests(status: Int) async throws {
        let transport = ReaderTranslationTransport(responsesFailure: status)
        var failures = 0
        let validator = ReaderTranslationAPIValidator(client: RemoteTranslationClient(
            credentialStore: ReaderTestCredential(), transport: transport
        ), onFailure: { _ in failures += 1 })
        var settings = ReaderTranslationSettings()
        settings.provider = .openAI
        settings.reasoningEffort = .none
        validator.refresh(settings)
        for _ in 0..<3 {
            do { try await validator.validateForActivation(settings); Issue.record("Failure must not enable translation") }
            catch let error as RemoteTranslationError { #expect(error == .httpStatus(status, requestID: nil)) }
        }
        #expect(await transport.requests.count == 1)
        #expect(failures == 1)
        #expect(settings.reasoningEffort == .none)
    }

    @Test func defaultFailureHandlerPreservesSavedAutomaticPreference() async throws {
        let key = ReaderTranslationSettings.keyPrefix + "automatic"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)
        let validator = ReaderTranslationAPIValidator(client: RemoteTranslationClient(
            credentialStore: ReaderTestCredential(), transport: ReaderTranslationTransport(responsesFailure: 500)
        ))
        var settings = ReaderTranslationSettings()
        settings.provider = .openAI
        do {
            try await validator.validateForActivation(settings)
            Issue.record("Probe should fail")
        } catch {}
        #expect(ReaderTranslationSettings().automaticallyTranslate)
        validator.recordFailure(URLError(.timedOut), settings: settings)
        #expect(ReaderTranslationSettings().automaticallyTranslate)
    }

    @Test func credentialAndLanguageChangesInvalidateApproval() async throws {
        let transport = ReaderTranslationTransport()
        let validator = ReaderTranslationAPIValidator(client: RemoteTranslationClient(
            credentialStore: ReaderTestCredential(), transport: transport
        ), onFailure: { _ in })
        var settings = ReaderTranslationSettings()
        settings.provider = .openAI
        try await validator.validateForActivation(settings)
        settings.credentialGeneration += 1
        try await validator.validateForActivation(settings)
        settings.targetLanguage = "fr"
        try await validator.validateForActivation(settings)
        #expect(await transport.requests.count == 3)
        validator.recordFailure(RemoteTranslationError.httpStatus(401, requestID: nil), settings: settings)
        do { try await validator.validateForActivation(settings); Issue.record("Runtime failure must invalidate approval") } catch {}
        #expect(await transport.requests.count == 3)
    }
}

@Suite(.serialized) @MainActor
struct ReaderTranslationValidationRaceTests {
    @Test func staleFailureCannotDisableNewSettingsAndConcurrentReadersShareOneProbe() async throws {
        let client = ValidationGateClient()
        var failures = 0
        let validator = ReaderTranslationAPIValidator(client: client, onFailure: { _ in failures += 1 })
        var settings = ReaderTranslationSettings()
        settings.provider = .openAI
        settings.model = "old"
        validator.refresh(settings)
        while !(await client.started) { try await Task.sleep(nanoseconds: 5_000_000) }
        settings.model = "new"
        validator.refresh(settings)
        try await validator.validateForActivation(settings)
        await client.release()
        try await Task.sleep(nanoseconds: 10_000_000)
        try await validator.validateForActivation(settings)
        #expect(failures == 0)
        #expect(await client.calls == 2)
    }

    @Test func emptyTranslationCannotApproveActivation() async throws {
        let validator = ReaderTranslationAPIValidator(client: ValidationEmptyClient(), onFailure: { _ in })
        do {
            try await validator.validateForActivation(ReaderTranslationSettings())
            Issue.record("Empty translation must not enable the reader")
        } catch let error as RemoteTranslationError {
            guard case .invalidResponse = error else { Issue.record("Unexpected error"); return }
        }
    }
}
private actor ValidationGateClient: RemoteTranslating {
    private(set) var started = false
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        calls += 1
        if configuration.model == "old" {
            await withCheckedContinuation { continuation = $0; started = true }
            throw RemoteTranslationError.httpStatus(401, requestID: nil)
        }
        return .init(translations: [.init(id: "connection-test", text: "안녕하세요")], source: .network, providerRequestID: nil)
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct ValidationEmptyClient: RemoteTranslating {
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        .init(translations: [.init(id: "connection-test", text: "  ")], source: .network, providerRequestID: nil)
    }
}

@Suite(.serialized) @MainActor
struct ReaderTranslationManualConnectionTests {
    @Test(arguments: [RemoteTranslationProtocol.responses, .chatCompletions])
    func draftKeyAndSavedKeyUseExactFormSettingsWithoutSaving(apiProtocol: RemoteTranslationProtocol) async throws {
        let transport = ReaderTranslationTransport()
        let keys = KeychainTranslationCredentialStore(service: "AidokuTests.Manual.\(UUID().uuidString)")
        let suite = "AidokuTests.Manual.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://manual.example/v1"
        settings.custom.apiProtocol = apiProtocol
        settings.model = "draft-model"
        settings.reasoningEffort = .high
        let account = settings.selectedCredentialAccount
        try keys.save("saved-test-key", for: account)
        defer { try? keys.deleteSecret(for: account) }
        let before = defaults.dictionaryRepresentation() as NSDictionary
        for key in ["draft-test-key", ""] {
            let translated = try await ReaderTranslationConnectionTest.translate(
                settings: settings, apiKey: key, savedCredentials: keys, transport: transport
            )
            #expect(translated == "ko:Hello, world!")
            let request = try #require(await transport.requests.last)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + (key.isEmpty ? "saved-test-key" : key))
            let body = try #require(request.httpBody)
            let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(root["model"] as? String == "draft-model")
            let reasoning = apiProtocol == .responses ? (root["reasoning"] as? [String: Any])?["effort"] : root["reasoning_effort"]
            #expect(reasoning as? String == "high")
            #expect(!String(decoding: body, as: UTF8.self).contains("test-key"))
        }
        #expect(await transport.requests.count == 2) // No cached test result.
        #expect(try keys.secret(for: account) == "saved-test-key")
        #expect(defaults.dictionaryRepresentation() as NSDictionary == before)
        settings.custom.baseURL = "https://other.example/v1"
        do {
            _ = try await ReaderTranslationConnectionTest.translate(settings: settings, apiKey: "", savedCredentials: keys, transport: transport)
            Issue.record("A different server must not receive the saved key")
        } catch let error as RemoteTranslationError { #expect(error == .missingCredential) }
        #expect(await transport.requests.count == 2)
    }

    @Test func missingAndInvalidDraftKeysDoNotSendRequests() async throws {
        let transport = ReaderTranslationTransport()
        for key in ["", "unsafe\nkey"] {
            do {
                _ = try await ReaderTranslationConnectionTest.translate(
                    settings: ReaderTranslationSettings(), apiKey: key,
                    savedCredentials: ReaderTestCredential(missing: true), transport: transport
                )
                Issue.record("Invalid credentials must fail")
            } catch { #expect(await transport.requests.isEmpty) }
        }
    }

    @Test func successfulRetestRecoversCachedFailureWithoutAnotherProbe() async throws {
        let transport = ReaderTranslationTransport(responsesFailure: 401)
        let validator = ReaderTranslationAPIValidator(client: RemoteTranslationClient(
            credentialStore: ReaderTestCredential(), transport: transport
        ), onFailure: { _ in })
        var settings = ReaderTranslationSettings()
        settings.provider = .openAI
        do { try await validator.validateForActivation(settings); Issue.record("Expected 401") } catch {}
        validator.recordSuccess(settings: settings)
        try await validator.validateForActivation(settings)
        #expect(await transport.requests.count == 1)
    }
}
