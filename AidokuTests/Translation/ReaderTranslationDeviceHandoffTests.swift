import Foundation
import Testing
@testable import Aidoku

/// Opt-in device handoff check. Never prints credentials or server configuration.
struct ReaderTranslationDeviceHandoffTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        FileManager.default.documentDirectory.appendingPathComponent("verify-translation-handoff").path)))
    func migratedSettingsAndCredentialCanTranslate() async throws {
        defer {
            try? FileManager.default.removeItem(at:
                FileManager.default.documentDirectory.appendingPathComponent("verify-translation-handoff"))
        }
        let settings = ReaderTranslationSettings()
        try settings.validate()
        let store = KeychainTranslationCredentialStore()
        let hasCredential = try store.containsSecret(for: settings.configuration.credentialAccount)
        try #require(hasCredential)
        let result = try await ReaderTranslationAPIValidator.probe(settings, client: RemoteTranslationClient())
        #expect(!result.isEmpty)
    }
}
