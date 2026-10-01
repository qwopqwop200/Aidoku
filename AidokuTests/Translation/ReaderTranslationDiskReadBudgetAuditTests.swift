import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationDiskReadBudgetAuditTests {
    @Test
    func disablingThenEnablingStorageRejectsPendingWriters() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskReadBudgetAudit-" + UUID().uuidString)
        let name = "DiskReadBudgetAudit-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: name)
        }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let cache = ReaderTranslationDiskCache(directory: directory)
        try await cache.synchronizeSettings(settings)
        let token = try #require(await cache.captureTranslationWrite(settings: settings))
        let pageGeneration = await cache.currentGeneration()
        let metadataGeneration = await cache.currentGeneration(kind: .metadata)
        try await cache.setByteLimit(0)
        try await cache.setByteLimit(ReaderTranslationDiskCache.defaultBytes)
        try await cache.synchronizeSettings(settings)
        try await cache.store(Data("late page".utf8), for: "page", kind: .translation, generation: pageGeneration)
        try await cache.store(Data("late title".utf8), for: "title", kind: .metadata, generation: metadataGeneration)
        #expect(try await cache.statistics().entries == 0)
        #expect(await cache.resolveTranslationWrite(page: "page", settings: settings, token: token) == nil)
        let current = await cache.currentGeneration()
        try await cache.store(Data("fresh".utf8), for: "page", kind: .translation, generation: current)
        #expect(try await cache.data(for: "page", kind: .translation) == Data("fresh".utf8))
    }

    @Test(arguments: [false, true])
    func limitedReadPreservesValidPayloadAcrossReopen(compressed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskReadBudgetAudit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = compressed ? Data(repeating: 65, count: 128_000) : Data("valid saved layout".utf8)
        #expect(ReaderTranslationCacheCodec.isPacked(ReaderTranslationCacheCodec.pack(payload)) == compressed)
        let cache = ReaderTranslationDiskCache(directory: directory)
        let generation = await cache.currentGeneration()
        try await cache.store(payload, for: "saved", kind: .layout, generation: generation)
        #expect(try await cache.data(for: "saved", kind: .layout, maximumBytes: payload.count - 1) == nil)
        #expect(try await cache.contains("saved", kind: .layout))
        let reopened = ReaderTranslationDiskCache(directory: directory)
        #expect(try await reopened.data(for: "saved", kind: .layout, maximumBytes: payload.count) == payload)
    }

    @Test(arguments: [false, true])
    func permanentFormatLimitRemovesOnlyOversizedPayload(compressed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskReadFormatAudit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = compressed ? Data(repeating: 65, count: 128_000) : Data("valid saved layout".utf8)
        #expect(ReaderTranslationCacheCodec.isPacked(ReaderTranslationCacheCodec.pack(payload)) == compressed)
        let cache = ReaderTranslationDiskCache(directory: directory)
        let generation = await cache.currentGeneration()
        try await cache.store(payload, for: "oversized", kind: .layout, generation: generation)
        try await cache.store(payload, for: "boundary", kind: .layout, generation: generation)
        #expect(try await cache.data(for: "boundary", kind: .layout, maximumBytes: payload.count, discardOversized: true) == payload)
        #expect(try await cache.data(for: "oversized", kind: .layout, maximumBytes: payload.count - 1, discardOversized: true) == nil)
        #expect(try await cache.contains("oversized", kind: .layout) == false)
        #expect(try await cache.statistics().entries == 1)
        let reopened = ReaderTranslationDiskCache(directory: directory)
        #expect(try await reopened.data(for: "oversized", kind: .layout) == nil)
        #expect(try await reopened.data(for: "boundary", kind: .layout, maximumBytes: payload.count) == payload)
    }

    @Test
    func boundedReadStillRemovesCorruptCompressedPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskReadBudgetAudit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ReaderTranslationDiskCache(directory: directory)
        let generation = await cache.currentGeneration()
        try await cache.store(Data("ATZ2invalid".utf8), for: "broken", kind: .layout, generation: generation)
        #expect(try await cache.data(for: "broken", kind: .layout, maximumBytes: 128_000) == nil)
        #expect(try await cache.contains("broken", kind: .layout) == false)
    }
}
