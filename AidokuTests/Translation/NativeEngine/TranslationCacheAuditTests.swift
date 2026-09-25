import Foundation
import Testing
@testable import Aidoku

struct TranslationCacheAuditTests {
    private func key() throws -> TranslationCacheKey {
        let config = RemoteTranslationConfiguration.openAI(model: "cache-audit")
        return TranslationCacheKey(configuration: config, endpoint: try config.validatedEndpoint(),
            request: .init(sourceLanguage: "ja", targetLanguage: "ko", sourceText: "こんにちは"))
    }

    private func answer(_ key: TranslationCacheKey) -> [RemoteTranslatedSegment] {
        key.segments.map { .init(id: $0.id, text: "안녕하세요") }
    }

    @Test func failedDiskEnableKeepsPreviousConfigurationAndMemoryThenRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("browser-app")
        try Data("not a directory".utf8).write(to: blocker)
        let previous = TranslationCacheConfiguration(diskEnabled: false, maxSizeMiB: 1)
        let next = TranslationCacheConfiguration(memoryEnabled: false, diskEnabled: true, maxSizeMiB: 2)
        let cache = try TranslationCache(configuration: previous, storageRootURL: root)
        let key = try key(), translations = answer(key)
        await cache.insert(translations, for: key)
        do {
            try await cache.reconfigure(next)
            Issue.record("Disk enable should fail for a regular file at the cache directory")
        } catch {}
        #expect(await cache.configuration == previous)
        #expect(try await cache.value(for: key)?.translations == translations)
        #expect(await cache.statistics().memoryEntries == 1)

        try FileManager.default.removeItem(at: blocker)
        try await cache.reconfigure(next)
        #expect(await cache.configuration == next)
        await cache.insert(translations, for: key)
        let reopened = try TranslationCache(configuration: next, storageRootURL: root)
        #expect(try await reopened.value(for: key)?.translations == translations)
    }

    @Test func failedDiskDisableKeepsPreviousConfigurationAndReadableMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = TranslationCacheConfiguration(maxSizeMiB: 1)
        let cache = try TranslationCache(configuration: previous, storageRootURL: root)
        let key = try key(), translations = answer(key)
        await cache.insert(translations, for: key)
        let directory = root.appendingPathComponent("browser-app/translation-cache-v1")
        let saved = root.appendingPathComponent("saved-cache")
        try FileManager.default.moveItem(at: directory, to: saved)
        try Data("unavailable".utf8).write(to: directory)
        do {
            try await cache.reconfigure(.init(memoryEnabled: false, diskEnabled: false, maxSizeMiB: 2))
            Issue.record("Disk disable should fail while the managed directory is inaccessible")
        } catch {}
        #expect(await cache.configuration == previous)
        #expect(try await cache.value(for: key)?.translations == translations)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: saved, to: directory)
        try await cache.reconfigure(.init(memoryEnabled: false, diskEnabled: false, maxSizeMiB: 2))
        #expect(await cache.statistics().memoryEntries == 0)
        #expect(await cache.statistics().diskEntries == 0)
    }

    @Test func invalidAnswersNeverBecomeMemoryOrPersistentHits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try TranslationCache(storageRootURL: root)
        let key = try key()
        let invalid: [[RemoteTranslatedSegment]] = [[], [.init(id: "wrong", text: "answer")],
            [.init(id: key.segments[0].id, text: " \n ")], answer(key) + answer(key)]
        for value in invalid {
            await cache.insert(value, for: key)
            #expect(try await cache.value(for: key) == nil)
        }
        #expect(await cache.statistics().memoryEntries == 0)
        #expect(await cache.statistics().diskEntries == 0)
        let reopened = try TranslationCache(storageRootURL: root)
        #expect(try await reopened.value(for: key) == nil)
        await cache.insert(answer(key), for: key)
        #expect(try await cache.value(for: key)?.source == .memoryCache)
        try await cache.clear(memory: true, disk: false)
        #expect(try await cache.value(for: key)?.source == .diskCache)
    }
}
