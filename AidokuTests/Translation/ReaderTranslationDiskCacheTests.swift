import Foundation
import SQLite3
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationDiskCacheTests {
    @Test func durableRegionsSurviveANewCacheInstanceAndPreserveGeometry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let regions = [ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2), source: "hello",
                                               translation: "안녕", polygon: [CGPoint(x: 0.1, y: 0.2)], confidence: 0.98,
                                               sourceOrientation: .vertical, sourceSingleVerticalColumn: true)]
        try await cache.storeRegions(regions, for: "book/chapter/page", kind: .translation, generation: 0)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: "book/chapter/page", kind: .translation) == regions)
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func corruptRegionsAreDiscardedWithoutPoisoningFutureWrites() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.store(Data("invalid json".utf8), for: "corrupt", kind: .ocr, generation: 0)
        #expect(try await cache.regions(for: "corrupt", kind: .ocr) == nil)
        #expect(try await cache.statistics().entries == 0)
        try await cache.storeRegions([], for: "corrupt", kind: .ocr, generation: 0)
        #expect(try await cache.regions(for: "corrupt", kind: .ocr)?.isEmpty == true)
    }

    @Test func corruptSharedBaseBecomesMissAndLastReferenceReclaimsStorage() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let regions = [ReaderTranslationRegion(id: "one", rect: .zero, source: "source")]
        try await cache.storeRegions(regions, for: "one", kind: .ocr, generation: 0)
        try await cache.storeRegions(regions, for: "two", kind: .translation, generation: 0)
        // Corruption without changing length also leaves byte accounting intact.
        try databaseExecute(root, "UPDATE region_bases SET data=zeroblob(length(data))")
        #expect(try await cache.regions(for: "one", kind: .ocr) == nil)
        #expect(try await cache.regions(for: "two", kind: .translation) == nil)
        #expect(try await cache.statistics().entries == 0)
        #expect(try await cache.statistics().payloadBytes == 0)
    }

    @Test func legacyJSONCompactsWithoutLosingTextOrGeometry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let regions = (0..<30).map { index in
            ReaderTranslationRegion(id: String(index), rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1),
                                    source: String(repeating: "Long repeated OCR text ", count: 20), translation: "압축 뒤에도 그대로 유지되는 번역")
        }
        let raw = try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
        let url = root.appendingPathComponent("translation-" + ReaderTranslationCacheIdentity.digest("legacy") + ".cache")
        try raw.write(to: url)
        let cache = ReaderTranslationDiskCache(directory: root)
        #expect(try await cache.regions(for: "legacy", kind: .translation) == regions)
        try await cache.compact()
        #expect(try await cache.statistics().payloadBytes < Int64(raw.count / 4))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache.sqlite").path))
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: "legacy", kind: .translation) == regions)
        try await reopened.store(Data("ATZ1invalid".utf8), for: "broken", kind: .layout, generation: 0)
        #expect(try await reopened.data(for: "broken", kind: .layout) == nil)
    }

    @Test func clearingRejectsOldWritersAndOversizedFilesDoNotExceedQuota() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root, byteLimit: 100_000)
        let oldGeneration = await cache.currentGeneration()
        try await cache.store(noise(150_000), for: "too-large", kind: .layout, generation: oldGeneration)
        #expect(try await cache.statistics().entries == 0)
        try await cache.clear()
        try await cache.store(Data(repeating: 1, count: 50), for: "late", kind: .layout, generation: oldGeneration)
        #expect(try await cache.statistics().entries == 0)
        try await cache.storeRegions([ReaderTranslationRegion(id: "late", rect: .zero, source: "late")],
            for: "late-regions", kind: .translation, generation: oldGeneration)
        #expect(try await cache.statistics().entries == 0)
        let current = await cache.currentGeneration()
        try await cache.store(Data(repeating: 1, count: 50), for: "new", kind: .layout, generation: current)
        #expect(try await cache.statistics().payloadBytes == 50)
        #expect(try await cache.statistics().bytes <= 100_000)
        try await cache.setByteLimit(200_000_000_000)
        #expect(try await cache.statistics().limit == 100_000_000_000)
    }

    @Test func shrinkingLimitEvictsLeastRecentlyUsedAcrossKindsAfterReopening() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ReaderTranslationDiskCache(directory: root)
        for (key, kind) in [("first", ReaderTranslationDiskCache.Kind.ocr), ("second", .translation), ("third", .layout)] {
            try await original.store(noise(65_536), for: key, kind: kind, generation: 0)
        }
        try await original.markUsed("first", kind: .ocr)
        let occupied = try await original.statistics().bytes
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.setByteLimit(occupied - 1)
        #expect(try await cache.statistics().bytes <= occupied - 1)
        #expect(try await cache.contains("second", kind: .translation) == false)
        #expect(try await cache.contains("third", kind: .layout))
        #expect(try await cache.contains("first", kind: .ocr))
        _ = try await cache.data(for: "first", kind: .ocr)
        let nextLimit = try await cache.statistics().bytes - 1
        try await cache.setByteLimit(nextLimit)
        #expect(try await cache.statistics().bytes <= nextLimit)
        #expect(try await cache.contains("third", kind: .layout) == false)
        #expect(try await cache.contains("first", kind: .ocr))
        try await cache.setByteLimit(0)
        #expect(try await cache.statistics().entries == 0)
        #expect(try await cache.statistics().bytes == 0)
    }

    @Test(arguments: ["model", "credentials", "filter"])
    func changingTranslationSettingsDeletesOldResultsButKeepsOCR(change: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let original = settings
        try await cache.synchronizeSettings(settings)
        let oldGeneration = await cache.currentGeneration(settings: settings)
        var region = ReaderTranslationRegion(id: "one", rect: .zero, source: "original")
        try await cache.storeRegions([region], for: "ocr", kind: .ocr, generation: oldGeneration)
        region.translation = "이전 번역"
        try await cache.storeRegions([region], for: "old", kind: .translation, generation: oldGeneration)
        try await cache.store(Data("layout".utf8), for: "old", kind: .layout, generation: oldGeneration)
        switch change {
        case "model": settings.model = "new-model"
        case "credentials": settings.credentialGeneration += 1
        default: settings.translationSourceLanguages = ["ja"]
        }
        try await cache.synchronizeSettings(settings)
        #expect(try await cache.regions(for: "ocr", kind: .ocr)?.first?.source == "original")
        #expect(try await cache.contains("old", kind: .translation) == false)
        #expect(try await cache.contains("old", kind: .layout) == false)
        #expect(try await cache.statistics().entries == 1)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 1)
        // Both requests already in flight and old requests queued after the change are rejected.
        try await cache.storeRegions([region], for: "late", kind: .translation, generation: oldGeneration)
        let staleQueuedGeneration = await cache.currentGeneration(settings: original)
        try await cache.storeRegions([region], for: "queued", kind: .translation, generation: staleQueuedGeneration)
        #expect(try await cache.statistics().entries == 1)
        let current = await cache.currentGeneration(settings: settings)
        try await cache.storeRegions([region], for: "new", kind: .translation, generation: current)
        let reopened = ReaderTranslationDiskCache(directory: root)
        try await reopened.synchronizeSettings(settings)
        #expect(try await reopened.regions(for: "new", kind: .translation) == [region])
        settings.model = "third-model"
        try await reopened.synchronizeSettings(settings)
        #expect(try await reopened.contains("new", kind: .translation) == false)
        #expect(try await reopened.contains("ocr", kind: .ocr))
    }

    @Test func corruptCompressedPayloadIsRemovedOnRead() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.store(Data("ATZ2invalid".utf8), for: "broken", kind: .layout, generation: await cache.currentGeneration())
        #expect(try await cache.data(for: "broken", kind: .layout) == nil)
        #expect(try await cache.contains("broken", kind: .layout) == false)
    }

    /// Returned payloads must own their bytes after SQLite reuses or frees the row storage.
    @Test(arguments: ["raw", "ATZ1", "ATZ2"])
    func decodedBytesOutliveStatementReplacementAndClear(format: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let original = noise(256 * 1024)
        let stored: Data
        switch format {
        case "ATZ1": stored = Data("ATZ1".utf8) + (try (original as NSData).compressed(using: .lzfse) as Data)
        case "ATZ2": stored = Data("ATZ2".utf8) + (try (original as NSData).compressed(using: .zlib) as Data)
        default: stored = original
        }
        try await disk.store(stored, for: "large", kind: .layout, generation: 0)
        let first = try #require(try await disk.data(for: "large", kind: .layout))
        #expect(first == original)
        for index in 0..<4 {
            let replacement = Data(repeating: UInt8(index + 1), count: original.count + index * 64)
            try await disk.store(replacement, for: "large", kind: .layout, generation: 0)
            #expect(try await disk.data(for: "large", kind: .layout) == replacement)
        }
        try await disk.clear()
        #expect(first == original)
    }

    @Test func regionArchivePreservesStateAndLegacyRecordsStayReadable() throws {
        var region = ReaderTranslationRegion(id: "one", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: "source", translation: "translated")
        region.keepsClassifiedSFXSource = true
        region.translationRecoveryFailure = "fixture"
        let archive = try ReaderTranslationRegionArchive([region])
        #expect(try ReaderTranslationRegionArchive.record(base: archive.base, variant: archive.variant).regions == [region])
        let legacy = try ReaderTranslationRegionArchive.restore(base: archive.base, variant: archive.variant)
        #expect(try ReaderTranslationRegionArchive.record(legacy: legacy).regions == [region])
        let empty = Data("[]".utf8)
        let oldVariant = Data(#"{"k":[],"r":[],"s":[],"t":[],"v":1}"#.utf8)
        #expect(try ReaderTranslationRegionArchive.record(legacy: empty).regions.isEmpty)
        #expect(try ReaderTranslationRegionArchive.record(base: empty, variant: oldVariant).regions.isEmpty)
        #expect(try ReaderTranslationRegionArchive([]).variant == oldVariant)
    }

    private func databaseExecute(_ root: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func databaseInteger(_ root: URL, _ sql: String) throws -> Int64 {
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    private func noise(_ count: Int) -> Data {
        var state: UInt64 = 0x123456789abcdef
        return Data((0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
    }

    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("translation-cache-test-" + UUID().uuidString) }
}
