import Foundation
import Testing
@testable import Aidoku

struct TranslationCacheScalingTests {
    // This suite measures cache behavior, so immutable provider setup is shared across 5,000 keys.
    private static let configuration = RemoteTranslationConfiguration.openAI(model: "cache-test")
    private static let endpoint: Result<URL, Error> = Result { try configuration.validatedEndpoint() }
    private static let translationText = String(repeating: "a", count: 512)

    private func key(_ index: Int) throws -> TranslationCacheKey {
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
            sourceText: String(format: "source-%05d", index))
        return TranslationCacheKey(configuration: Self.configuration,
            endpoint: try Self.endpoint.get(), request: request)
    }

    private func value(_ key: TranslationCacheKey) -> [RemoteTranslatedSegment] {
        key.segments.map { .init(id: $0.id, text: Self.translationText) }
    }

    @Test func largeBudgetReductionPreservesExactLRUAfterHitsAndReplacement() async throws {
        let cache = try TranslationCache(configuration: .init(diskEnabled: false, maxSizeMiB: 16))
        let keys = try (0..<5_000).map(key)
        for key in keys { await cache.insert(value(key), for: key) }
        #expect(await cache.statistics().memoryEntries == keys.count)
        var order = Array(keys.indices)
        // Exercise head, middle and tail promotion, then replacement of an existing entry.
        for index in [0, 2_500, 4_999, 0] {
            #expect(try await cache.value(for: keys[index]) != nil)
            order.removeAll { $0 == index }
            order.append(index)
        }
        await cache.insert(value(keys[10]), for: keys[10])
        order.removeAll { $0 == 10 }
        order.append(10)
        let start = Date()
        try await cache.reconfigure(.init(diskEnabled: false, maxSizeMiB: 1))
        let stats = await cache.statistics()
        print("CACHE_LRU_SHRINK entries=5000 retained=\(stats.memoryEntries) seconds=\(Date().timeIntervalSince(start))")
        #expect(stats.memoryBytes <= 1_024 * 1_024)
        #expect(stats.memoryEntries > 0 && stats.memoryEntries < keys.count / 2)
        #expect(stats.evictions == UInt64(keys.count - stats.memoryEntries))
        let survivors = Set(order.suffix(stats.memoryEntries))
        for index in keys.indices {
            #expect((try await cache.valueIfPresent(for: keys[index]) != nil) == survivors.contains(index))
        }
    }

    @Test func resetsAndSingleEntryReplacementKeepLRUUsable() async throws {
        let cache = try TranslationCache(configuration: .init(diskEnabled: false, maxSizeMiB: 1))
        let first = try key(0), second = try key(1)
        await cache.insert(value(first), for: first)
        await cache.insert(value(first), for: first)
        #expect(await cache.statistics().memoryEntries == 1)
        #expect(try await cache.value(for: first) != nil)
        try await cache.clear(memory: true, disk: false)
        #expect(await cache.statistics().memoryBytes == 0)
        await cache.insert(value(second), for: second)
        #expect(try await cache.value(for: first) == nil)
        #expect(try await cache.value(for: second) != nil)
        try await cache.reconfigure(.init(memoryEnabled: false, diskEnabled: false, maxSizeMiB: 1))
        #expect(await cache.statistics().memoryEntries == 0)
        try await cache.reconfigure(.init(diskEnabled: false, maxSizeMiB: 1))
        await cache.insert(value(first), for: first)
        #expect(try await cache.value(for: first) != nil)
        #expect(try await cache.value(for: second) == nil)
    }

    @Test func diskBulkEvictionPreservesLRUAndReplacementAcrossReopen() async throws {
        struct StoredKey: Decodable { let key: TranslationCacheKey }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = TranslationCacheConfiguration(memoryEnabled: false, maxSizeMiB: 4)
        let original = try TranslationCache(configuration: configuration, storageRootURL: root)
        let keys = try (0..<64).map(key)
        let text = String(repeating: "a", count: 40_000)
        for key in keys {
            await original.insert(key.segments.map { .init(id: $0.id, text: text) }, for: key)
        }
        #expect(await original.statistics().diskEntries == keys.count)
        // Fix the persisted order independently of filesystem clock resolution.
        let directory = root.appendingPathComponent("browser-app/translation-cache-v1")
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let stored = try JSONDecoder().decode(StoredKey.self, from: Data(contentsOf: url))
            let index = try #require(keys.firstIndex(of: stored.key))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))],
                                                 ofItemAtPath: url.path)
        }
        let cache = try TranslationCache(configuration: configuration, storageRootURL: root)
        // A read must promote the oldest entry before a multi-victim shrink.
        #expect(try await cache.value(for: keys[0]) != nil)
        var order = Array(keys.dropFirst()) + [keys[0]]
        try await cache.reconfigure(.init(memoryEnabled: false, maxSizeMiB: 1))
        let shrunk = await cache.statistics()
        #expect(shrunk.diskBytes <= 1_024 * 1_024)
        #expect(shrunk.diskEntries > 1 && shrunk.diskEntries < keys.count)
        #expect(shrunk.evictions == UInt64(keys.count - shrunk.diskEntries))
        order = Array(order.suffix(shrunk.diskEntries))

        // Grow the protected replacement enough to evict several other records.
        let replacement = keys[0]
        let large = replacement.segments.map { RemoteTranslatedSegment(id: $0.id, text: String(repeating: "b", count: 500_000)) }
        await cache.insert(large, for: replacement)
        let replaced = await cache.statistics()
        #expect(replaced.diskBytes <= 1_024 * 1_024)
        #expect(replaced.diskEntries < shrunk.diskEntries - 1)
        order = Array(order.suffix(replaced.diskEntries))
        let expected = Set(order)
        let reopened = try TranslationCache(configuration: .init(memoryEnabled: false, maxSizeMiB: 1), storageRootURL: root)
        for key in keys {
            #expect((try await reopened.value(for: key) != nil) == expected.contains(key))
        }
        #expect(try await reopened.value(for: replacement)?.translations == large)
    }

}
