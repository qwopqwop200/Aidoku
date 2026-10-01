import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationCachePolicyAuditTests {
    @Test
    func identicalCredentialSavePreservesRestartCacheIdentity() async throws {
        let name = "ReaderTranslationCachePolicyAuditTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let credentials = PolicyAuditCredentials()
        var settings = ReaderTranslationSettings(defaults: defaults)
        try settings.save(defaults: defaults, apiKey: "test-key", credentialStore: credentials)
        settings = ReaderTranslationSettings(defaults: defaults)
        let key = ReaderTranslationCacheIdentity.translation(page: "saved-page", settings: settings)
        let cache = ReaderTranslationDiskCache(directory: directory)
        try await cache.synchronizeSettings(settings)
        let generation = await cache.currentGeneration(settings: settings)
        try await cache.store(Data("saved translation".utf8), for: key, kind: .translation, generation: generation)

        try settings.save(defaults: defaults, apiKey: "  test-key\n", credentialStore: credentials)
        let reopenedSettings = ReaderTranslationSettings(defaults: defaults)
        #expect(reopenedSettings.credentialGeneration == settings.credentialGeneration)
        #expect(ReaderTranslationCacheIdentity.translation(page: "saved-page", settings: reopenedSettings) == key)
        let reopened = ReaderTranslationDiskCache(directory: directory)
        try await reopened.synchronizeSettings(reopenedSettings)
        #expect(try await reopened.data(for: key, kind: .translation) == Data("saved translation".utf8))
    }

    @Test
    func changedCredentialStillInvalidatesSavedAndPendingTranslations() async throws {
        let name = "ReaderTranslationCachePolicyAuditTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let credentials = PolicyAuditCredentials()
        var settings = ReaderTranslationSettings(defaults: defaults)
        try settings.save(defaults: defaults, apiKey: "first-key", credentialStore: credentials)
        settings = ReaderTranslationSettings(defaults: defaults)
        let cache = ReaderTranslationDiskCache(directory: directory)
        try await cache.synchronizeSettings(settings)
        let token = try #require(await cache.captureTranslationWrite(settings: settings))
        let generation = await cache.currentGeneration(settings: settings)
        try await cache.store(Data("old".utf8), for: "page", kind: .translation, generation: generation)

        try settings.save(defaults: defaults, apiKey: "replacement-key", credentialStore: credentials)
        let replacement = ReaderTranslationSettings(defaults: defaults)
        #expect(replacement.credentialGeneration == settings.credentialGeneration + 1)
        try await cache.synchronizeSettings(replacement)
        #expect(try await cache.contains("page", kind: .translation) == false)
        #expect(await cache.resolveTranslationWrite(page: "page", settings: settings, token: token) == nil)
    }

    @Test
    func settingsRoundTripCannotReviveAnInvalidatedWriter() async throws {
        let name = "ReaderTranslationCachePolicyAuditTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let cache = ReaderTranslationDiskCache(directory: directory)
        try await cache.synchronizeSettings(settings)
        let token = try #require(await cache.captureTranslationWrite(settings: settings))
        var changed = settings
        changed.targetLanguage = "en"
        try await cache.synchronizeSettings(changed)
        try await cache.synchronizeSettings(settings)
        #expect(await cache.resolveTranslationWrite(page: "page", settings: settings, token: token) == nil)
    }
}

private final class PolicyAuditCredentials: TranslationCredentialManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func secret(for account: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return values[account] ?? ""
    }

    func save(_ secret: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = secret
    }

    func containsSecret(for account: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values[account] != nil
    }

    func deleteSecret(for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}
