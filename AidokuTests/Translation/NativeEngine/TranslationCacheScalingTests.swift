import Foundation
import Testing
@testable import Aidoku

struct TranslationCacheScalingTests {
    private func key(_ index: Int) throws -> TranslationCacheKey {
        let configuration = RemoteTranslationConfiguration.openAI(model: "cache-test")
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko",
            sourceText: String(format: "source-%05d", index))
        return TranslationCacheKey(configuration: configuration,
            endpoint: try configuration.validatedEndpoint(), request: request)
    }

    private func value(_ key: TranslationCacheKey) -> [RemoteTranslatedSegment] {
        key.segments.map { .init(id: $0.id, text: String(repeating: "a", count: 512)) }
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
}
