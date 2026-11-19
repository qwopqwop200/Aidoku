import Foundation
import Testing
@testable import Aidoku

struct TranslationCacheAuditTests {
    private func key(_ text: String = "こんにちは") throws -> TranslationCacheKey {
        let config = RemoteTranslationConfiguration.openAI(model: "cache-audit")
        return TranslationCacheKey(configuration: config, endpoint: try config.validatedEndpoint(),
            request: .init(sourceLanguage: "ja", targetLanguage: "ko", sourceText: text))
    }

    private func answer(_ key: TranslationCacheKey, text: String = "안녕하세요") -> [RemoteTranslatedSegment] {
        key.segments.map { .init(id: $0.id, text: text) }
    }

    @Test func invalidAnswersNeverBecomeHits() async throws {
        let cache = TranslationCache()
        let key = try key()
        let invalid: [[RemoteTranslatedSegment]] = [[], [.init(id: "wrong", text: "answer")],
            [.init(id: key.segments[0].id, text: " \n ")], answer(key) + answer(key)]
        for value in invalid {
            await cache.insert(value, for: key)
            #expect(await cache.value(for: key) == nil)
        }
        await cache.insert(answer(key), for: key)
        #expect(await cache.value(for: key)?.source == .memoryCache)
    }

    @Test func budgetEvictsLeastRecentlyUsedEntry() async throws {
        let cache = TranslationCache(maxSizeMiB: 1)
        let text = String(repeating: "a", count: 300 * 1024)
        let keys = try (0..<3).map { try key("source-\($0)") }
        for key in keys.prefix(2) { await cache.insert(answer(key, text: text), for: key) }
        #expect(await cache.value(for: keys[0]) != nil)
        await cache.insert(answer(keys[2], text: text), for: keys[2])
        await cache.insert(answer(keys[1], text: text + "b"), for: keys[1])
        // Three ~300 KiB entries fit; replacement keeps the count and refreshes recency.
        #expect(await cache.value(for: keys[0]) != nil)
        #expect(await cache.value(for: keys[2]) != nil)
        #expect(await cache.value(for: keys[1]) != nil)
        // A fourth entry exceeds 1 MiB and evicts the least recently used one.
        let extra = try key("source-extra")
        await cache.insert(answer(extra, text: text), for: extra)
        #expect(await cache.value(for: keys[0]) == nil)
    }

    @Test func purgeClearsMemoryAndLegacyRecordsOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("browser-app/translation-cache-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = directory.appendingPathComponent("0123456789abcdef-0123456789abcdef-01234567.json")
        let unmanaged = directory.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: record)
        try Data("{}".utf8).write(to: unmanaged)
        let cache = TranslationCache(storageRootURL: root)
        let key = try key()
        await cache.insert(answer(key), for: key)
        let lease = await cache.lookup(for: key).storageGeneration
        try await cache.purgeAll()
        #expect(await cache.value(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(FileManager.default.fileExists(atPath: unmanaged.path))
        // A provider result admitted before the purge cannot refill the cache.
        await cache.insert(answer(key), for: key, admittedStorageGeneration: lease)
        #expect(await cache.value(for: key) == nil)
        // A missing legacy directory is not an error.
        try await TranslationCache(storageRootURL: root.appendingPathComponent("missing")).purgeAll()
    }
}
