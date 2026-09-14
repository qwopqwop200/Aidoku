import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationProviderTests {
    @Test func autosavePreservesIncompleteFormWithoutAllowingNetworkUse() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        settings.provider = .custom
        settings.custom.baseURL = "https://"
        settings.model = ""
        settings.instructions = ""
        settings.automaticallyTranslate = false
        settings.ocr.confidenceThreshold = 0.75
        settings.overlay.opacity = 0.5
        settings.translationSourceLanguages = ["ja"]
        try settings.autosave(defaults: fixture.defaults, credentialStore: fixture.keys)
        let restored = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(restored.custom == settings.custom)
        #expect(restored.instructions.isEmpty)
        #expect(!restored.automaticallyTranslate)
        #expect(restored.ocr.confidenceThreshold == 0.75)
        #expect(restored.overlay.opacity == 0.5)
        #expect(restored.translationSourceLanguages == ["ja"])
        #expect(throws: RemoteTranslationError.self) { try restored.validate() }
    }

    @Test func autosaveRetainsCredentialGenerationAndServerIsolation() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        try settings.autosave(defaults: fixture.defaults, apiKey: "original-key", credentialStore: fixture.keys)
        // A later form write must not roll back the generation from the key write.
        settings.model = ""
        try settings.autosave(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(ReaderTranslationSettings(defaults: fixture.defaults).credentialGeneration == 1)
        #expect(try fixture.keys.secret(for: "openai") == "original-key")
        settings.provider = .custom
        settings.custom.baseURL = "https://translator.example/v1"
        let account = settings.selectedCredentialAccount
        defer { try? fixture.keys.deleteSecret(for: account) }
        try settings.autosave(defaults: fixture.defaults, apiKey: "custom-key", credentialStore: fixture.keys)
        settings.custom.baseURL = "https://other.example/v1"
        try settings.autosave(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        #expect(try fixture.keys.secret(for: account) == "custom-key")
        #expect(try fixture.keys.secret(for: "openai") == "original-key")
        #expect(ReaderTranslationSettings(defaults: fixture.defaults).credentialGeneration == 2)
    }

    @Test func existingOpenAISettingsAndKeySurviveProviderSwitches() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("existing-model", forKey: ReaderTranslationSettings.keyPrefix + "model")
        fixture.defaults.set("high", forKey: ReaderTranslationSettings.keyPrefix + "reasoningEffort")
        try fixture.keys.save("original-openai-key", for: "openai")
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(settings.provider == .openAI)
        #expect(settings.model == "existing-model")
        #expect(settings.reasoningEffort == .high)
        #expect(settings.configuration.credentialAccount == "openai")

        settings.provider = .custom
        settings.custom.baseURL = "https://translator.example/v1"
        settings.model = "custom-model"
        settings.custom.apiProtocol = .chatCompletions
        try settings.save(defaults: fixture.defaults, apiKey: "custom-only-key", credentialStore: fixture.keys)
        let customAccount = settings.selectedCredentialAccount
        defer { try? fixture.keys.deleteSecret(for: customAccount) }
        var restored = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(restored.provider == .custom)
        #expect(restored.model == "custom-model")
        #expect(restored.configuration.apiProtocol == .chatCompletions)
        #expect(try restored.configuration.validatedEndpoint().absoluteString == "https://translator.example/v1/chat/completions")
        #expect(restored.credentialGeneration == 1)
        #expect(try fixture.keys.secret(for: restored.selectedCredentialAccount) == "custom-only-key")

        restored.provider = .openAI
        #expect(restored.model == "existing-model")
        #expect(restored.reasoningEffort == .high)
        #expect(try fixture.keys.secret(for: restored.selectedCredentialAccount) == "original-openai-key")
        try restored.save(defaults: fixture.defaults)
        restored = ReaderTranslationSettings(defaults: fixture.defaults)
        restored.provider = .custom
        #expect(restored.custom == settings.custom)
        #expect(restored.selectedCredentialAccount == customAccount)
    }

    @Test func customKeysAreBoundToServerURLAndPathButNotModelOrProtocol() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        settings.provider = .custom
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
        try settings.save(defaults: fixture.defaults, apiKey: "original-key", credentialStore: fixture.keys)
        let original = fixture.defaults.dictionaryRepresentation() as NSDictionary
        settings.instructions = ""
        #expect(throws: RemoteTranslationError.self) {
            try settings.save(defaults: fixture.defaults, apiKey: "uncommitted-key", credentialStore: fixture.keys)
        }
        #expect(try fixture.keys.secret(for: "openai") == "original-key")
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == original)
        settings.instructions = RemoteTranslationConfiguration.defaultInstructions
        settings.provider = .custom
        settings.model = "custom-model"
        settings.custom.baseURL = "http://192.168.1.10:8000/v1"
        #expect(throws: RemoteTranslationError.self) {
            try settings.save(defaults: fixture.defaults, apiKey: "uncommitted-key", credentialStore: fixture.keys)
        }
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == original)
    }

    @Test func deletingCustomKeyDoesNotDeleteOpenAIKeyOrCommitDraft() throws {
        let fixture = ProviderSettingsFixture()
        defer { fixture.cleanUp() }
        var settings = ReaderTranslationSettings(defaults: fixture.defaults)
        try settings.save(defaults: fixture.defaults, apiKey: "openai-key", credentialStore: fixture.keys)
        settings.provider = .custom
        settings.custom.baseURL = "https://translator.example"
        settings.model = "custom-model"
        try fixture.keys.save("custom-key", for: settings.selectedCredentialAccount)
        defer { try? fixture.keys.deleteSecret(for: settings.selectedCredentialAccount) }
        try settings.deleteKey(defaults: fixture.defaults, credentialStore: fixture.keys)
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        #expect(try fixture.keys.secret(for: "openai") == "openai-key")
        let saved = ReaderTranslationSettings(defaults: fixture.defaults)
        #expect(saved.provider == .openAI)
        #expect(saved.model == "gpt-5-mini")
        #expect(saved.credentialGeneration == 2)
        #expect(settings.credentialGeneration == saved.credentialGeneration)
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
