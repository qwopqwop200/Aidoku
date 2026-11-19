import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationProviderTests {
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
        settings.model = ""
        #expect(throws: RemoteTranslationError.self) {
            try settings.save(defaults: fixture.defaults, apiKey: "uncommitted-key", credentialStore: fixture.keys)
        }
        #expect(try fixture.keys.secret(for: "openai") == "original-key")
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == original)
        settings.provider = .custom
        settings.model = "custom-model"
        settings.custom.baseURL = "http://192.168.1.10:8000/v1"
        #expect(throws: RemoteTranslationError.self) {
            try settings.save(defaults: fixture.defaults, apiKey: "uncommitted-key", credentialStore: fixture.keys)
        }
        #expect(try !fixture.keys.containsSecret(for: settings.selectedCredentialAccount))
        #expect(fixture.defaults.dictionaryRepresentation() as NSDictionary == original)
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
