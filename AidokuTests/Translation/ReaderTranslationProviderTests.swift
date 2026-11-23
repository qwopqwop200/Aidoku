import CryptoKit
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationProviderTests {
    @Test func customKeysAreBoundToServerURLAndPathButNotModelOrProtocol() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        settings.custom.baseURL = "https://translator.example/tenant-a/v1"
        settings.model = "model-a"
        let account = settings.selectedCredentialAccount
        defer { try? fixture.keys.deleteSecret(for: account) }
        try settings.save(defaults: fixture.defaults, apiKey: "tenant-a-key", credentialStore: fixture.keys)
        settings.model = "model-b"
        settings.reasoningEffort = .high
        settings.custom.apiProtocol = .chatCompletions
        #expect(settings.configuration.reasoningEffort == .high)
        #expect(try fixture.keys.secret(for: settings.selectedCredentialAccount) == "tenant-a-key")
        settings.custom.baseURL = "https://translator.example/tenant-b/v1"
        #expect(settings.selectedCredentialAccount != account)
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        settings.custom.baseURL = "https://another.example/tenant-a/v1"
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        settings.custom.baseURL = " https://translator.example/tenant-a/v1 \n"
        #expect(settings.selectedCredentialAccount == account)
        settings.custom.apiProtocol = .responses
        #expect(settings.configuration.reasoningEffort == .high)
    }

    @Test func invalidSaveCannotReplaceAKeyOrPreferences() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        // New installs have no model, so nothing can be sent until one is entered.
        #expect(throws: RemoteTranslationError.missingModel) { try settings.validate() }
        settings.model = "gpt-5-mini"
        try settings.save(defaults: fixture.defaults, apiKey: "original-key", credentialStore: fixture.keys)
        let original = fixture.defaults.dictionaryRepresentation() as NSDictionary
        settings.model = ""
        #expect(throws: RemoteTranslationError.self) {
            try settings.save(defaults: fixture.defaults, apiKey: "uncommitted-key", credentialStore: fixture.keys)
        }
        #expect(try fixture.keys.secret(for: "openai") == "original-key")
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == original)
        settings.model = "custom-model"
        settings.custom.baseURL = "http://192.168.1.10:8000/v1"
        #expect(throws: RemoteTranslationError.self) {
            try settings.save(defaults: fixture.defaults, apiKey: "uncommitted-key", credentialStore: fixture.keys)
        }
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == original)
    }

    @Test func legacyOpenAIChoiceMigratesWithModelEffortAndKeychainAccount() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        let prefix = ReaderTranslationSettings.keyPrefix
        fixture.defaults.set("openai", forKey: prefix + "provider")
        fixture.defaults.set("gpt-5", forKey: prefix + "model")
        fixture.defaults.set("low", forKey: prefix + "reasoningEffort")
        let inactive = ReaderCustomTranslationSettings(baseURL: "https://inactive.example/v1", model: "other")
        fixture.defaults.set(try JSONEncoder().encode(inactive), forKey: prefix + "custom")
        var settings = ReaderTranslationSettings(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(settings.custom == ReaderCustomTranslationSettings(model: "gpt-5", reasoningEffort: .low))
        #expect(settings.selectedCredentialAccount == "openai")
        // Same configuration as the old OpenAI provider: identical requests and cache keys.
        #expect(settings.configuration == .openAI(model: "gpt-5", reasoningEffort: .low, timeout: 300))
        #expect(ReaderTranslationSettings.legacyOpenAIKeys.allSatisfy { fixture.defaults.object(forKey: $0) == nil })
        #expect(fixture.defaults.string(forKey: prefix + "provider") == "custom")
        #expect(ReaderTranslationSettings(defaults: fixture.defaults).custom == settings.custom)
        // A server chosen after the migration is never folded back.
        settings.custom.baseURL = "https://translator.example/v1"
        try settings.save(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(ReaderTranslationSettings(defaults: fixture.defaults).custom == settings.custom)
        // New users, and an old build's OpenAI choice saved without "provider", start on OpenAI.
        let fresh = UserDefaults(suiteName: fixture.suite + ".fresh")!
        defer { fresh.removePersistentDomain(forName: fixture.suite + ".fresh") }
        #expect(ReaderTranslationSettings(defaults: fresh).configuration == .openAI(model: "", reasoningEffort: .none,
                                                                                    timeout: 120))
        fresh.removeObject(forKey: prefix + "provider")
        fresh.set(try JSONEncoder().encode(ReaderCustomTranslationSettings(baseURL: "", model: "")), forKey: prefix + "custom")
        #expect(ReaderTranslationSettings(defaults: fresh).custom == ReaderCustomTranslationSettings())
    }

    @Test func legacyCustomChoiceKeepsSettingsAndKey() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        let prefix = ReaderTranslationSettings.keyPrefix
        for baseURL in ["https://translator.example/v1", "https://API.openai.com/v1"] {
            let custom = ReaderCustomTranslationSettings(baseURL: baseURL, model: "m", apiProtocol: .chatCompletions,
                                                         reasoningEffort: .high)
            fixture.defaults.set("custom", forKey: prefix + "provider")
            fixture.defaults.set("gpt-5", forKey: prefix + "model")
            fixture.defaults.set(try JSONEncoder().encode(custom), forKey: prefix + "custom")
            // The pre-migration account of a custom server URL.
            let legacyAccount = "custom-" + SHA256.hash(data: Data(baseURL.utf8)).map { String(format: "%02x", $0) }.joined()
            try fixture.keys.save("key-\(baseURL.count)", for: legacyAccount)
            defer { try? fixture.keys.deleteSecret(for: legacyAccount) }
            let generation = UInt64(fixture.defaults.integer(forKey: prefix + "credentialGeneration"))
            let settings = ReaderTranslationSettings(defaults: fixture.defaults, credentialStore: fixture.keys)
            #expect(settings.custom == custom)
            #expect(try fixture.keys.secret(for: settings.selectedCredentialAccount) == "key-\(baseURL.count)")
            #expect(fixture.defaults.string(forKey: prefix + "provider") == "custom")
            #expect(fixture.defaults.object(forKey: prefix + "model") == nil)
            if baseURL.contains("openai") {
                // The host now decides: OpenAI wire format, its fixed endpoint and the "openai" account.
                #expect(settings.provider == .openAI && settings.selectedCredentialAccount == "openai")
                #expect(settings.credentialGeneration > generation)
                #expect(try !fixture.keys.containsSecret(for: legacyAccount))
                #expect(try settings.configuration.validatedEndpoint().absoluteString ==
                    "https://api.openai.com/v1/chat/completions")
            } else {
                #expect(settings.provider == .custom && settings.selectedCredentialAccount == legacyAccount)
            }
        }
    }

    @Test func endpointHostDecidesOpenAIOnlyRequestFields() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        settings.custom.apiProtocol = .chatCompletions
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", sourceText: "原文")
        for (baseURL, provider) in [("https://api.openai.com/v1", RemoteTranslationProvider.openAI),
                                    ("https://api.openai.com", .openAI), ("https://example.test/v1", .custom),
                                    ("https://api.openai.com.example.test/v1", .custom)] {
            settings.custom.baseURL = baseURL
            #expect(settings.provider == provider)
            let root = try #require(JSONSerialization.jsonObject(with: TranslationHTTPCodec.requestBody(
                configuration: settings.configuration, request: request)) as? [String: Any])
            #expect(root[provider == .openAI ? "max_completion_tokens" : "max_tokens"] as? Int == 8192)
            #expect(root["top_k"] == nil && root["repetition_penalty"] == nil && root["store"] as? Bool == false)
        }
    }
}

private struct ProviderSettingsFixture {
    let suite = "AidokuTests.Provider.\(UUID().uuidString)"
    let keys = KeychainTranslationCredentialStore(service: "AidokuTests.Provider.Keys.\(UUID().uuidString)")
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? keys.deleteSecret(for: "openai")
    }
}
