import Foundation
import SQLite3
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationDiskCacheTests {
    @Test func reopenedCacheRepairsOnlyTheObservedPayload() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ReaderTranslationDiskCache(directory: root)
        let old = Data("old".utf8), newer = Data("newer".utf8), repair = Data("repair".utf8)
        try await first.store(old, for: "page", kind: .layout, generation: 0)
        try databaseExecute(root, "DROP INDEX cache_key_only")
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.data(for: "page", kind: .layout) == old)
        #expect(try databaseInteger(root, "SELECT count(*) FROM sqlite_master WHERE name='cache_key_only' AND type='index'") == 1)
        let observed = ReaderTranslationDiskCache.ReplacementCondition(maximumBytes: 64) { $0 == old }
        try await first.store(newer, for: "page", kind: .layout, generation: 0)
        #expect(try await !reopened.store(repair, for: "page", kind: .layout, generation: 0, replacing: observed))
        #expect(try await first.data(for: "page", kind: .layout) == newer)
        let replacement = ReaderTranslationDiskCache.ReplacementCondition(maximumBytes: 64) { $0 == newer }
        #expect(try await reopened.store(repair, for: "page", kind: .layout, generation: 0, replacing: replacement))
        #expect(try await first.data(for: "page", kind: .layout) == repair)
    }

    @Test func revisitingDecodedPagesPreservesClaimsAndObservesReplacements() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let secondConnection = ReaderTranslationDiskCache(directory: root)
        let claim = try #require(ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: String(repeating: "a", count: 64)))
        let otherClaim = try #require(ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: String(repeating: "b", count: 64)))
        let original = [ReaderTranslationRegion(id: "one", rect: .zero, source: "original", translation: "첫 번역")]
        try await cache.storeRegions(original, for: "page", kind: .translation, generation: 0, sourceRasterClaim: claim)
        let first = try #require(try await cache.regionRecord(for: "page", kind: .translation, matching: claim))
        let repeatRead = try #require(try await cache.regionRecord(for: "page", kind: .translation, matching: claim))
        let reusedBuffer = first.regions.withUnsafeBufferPointer { firstBuffer in
            repeatRead.regions.withUnsafeBufferPointer { $0.baseAddress == firstBuffer.baseAddress }
        }
        #expect(reusedBuffer)
        #expect(try await cache.regionRecord(for: "page", kind: .translation, matching: otherClaim) == nil)

        let replacement = [ReaderTranslationRegion(id: "two", rect: .zero, source: "replacement", translation: "새 번역")]
        try await secondConnection.storeRegions(replacement, for: "page", kind: .translation, generation: 0, sourceRasterClaim: otherClaim)
        #expect(try await cache.regionRecord(for: "page", kind: .translation, matching: claim) == nil)
        #expect(try await cache.regionRecord(for: "page", kind: .translation, matching: otherClaim)?.regions == replacement)
        try await cache.storeRegions(original, for: "page", kind: .translation, generation: 0, sourceRasterClaim: claim)
        #expect(try await cache.regionRecord(for: "page", kind: .translation, matching: claim)?.regions == original)
        try await cache.remove("page", kind: .translation)
        #expect(try await cache.regionRecord(for: "page", kind: .translation) == nil)
    }

    @Test(arguments: [false, true])
    func pendingReadTouchesCommitWithContentAndSurviveFailedStore(regionPayload: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        // Keep the actor uninterrupted so the touch timer cannot race this test.
        func exercise(_ cache: isolated ReaderTranslationDiskCache) throws {
            let first = Data("first".utf8), second = Data("second".utf8)
            try cache.store(first, for: "first", kind: .layout, generation: 0)
            try cache.store(second, for: "second", kind: .layout, generation: 0)
            let before = try databaseContents(root)
            #expect(try cache.data(for: "first", kind: .layout) == first)
            try databaseExecute(root, "CREATE TRIGGER reject_content BEFORE INSERT ON cache BEGIN SELECT RAISE(ABORT,'test'); END")
            let regions = [ReaderTranslationRegion(id: "test", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                   source: "Original", translation: "번역")]
            func store(_ cache: isolated ReaderTranslationDiskCache) throws {
                if regionPayload {
                    try cache.storeRegions(regions, for: "third", kind: .translation, generation: 0)
                } else {
                    try cache.store(Data("third".utf8), for: "third", kind: .layout, generation: 0)
                }
            }
            do {
                try store(cache)
                Issue.record("Injected content failure must propagate")
            } catch {}
            // The failed content transaction must not commit the queued LRU touch.
            #expect(try databaseContents(root) == before)
            try databaseExecute(root, "DROP TRIGGER reject_content")
            try store(cache)
            let firstName = "layout-" + ReaderTranslationCacheIdentity.digest("first") + ".cache"
            let secondName = "layout-" + ReaderTranslationCacheIdentity.digest("second") + ".cache"
            #expect(try databaseInteger(root, "SELECT accessed FROM cache WHERE name='\(firstName)'") >
                    databaseInteger(root, "SELECT accessed FROM cache WHERE name='\(secondName)'"))
            let committed = try databaseContents(root)
            try cache.flushAccesses()
            #expect(try databaseContents(root) == committed)
        }
        try await exercise(cache)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.contains("third", kind: regionPayload ? .translation : .layout))
    }

    @Test func compactCompressionPreservesResultsBasesAndLRUAndRetriesFailures() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        // Below the old 512-byte threshold, independent of encoder key order
        // or OS-specific LZFSE compression heuristics.
        let raw = Data(("[{\"text\":\"" + String(repeating: "무손실 번역 원문 ", count: 8) + "\"}]").utf8)
        #expect(raw.count >= 128 && raw.count < 512)
        let old = ReaderTranslationCacheCodec.packSharedBase(raw)
        let packed = ReaderTranslationCacheCodec.pack(raw)
        #expect(packed.count < old.count)
        #expect(try ReaderTranslationCacheCodec.unpack(old) == raw)
        #expect(try ReaderTranslationCacheCodec.unpack(packed) == raw)
        try await cache.store(old, for: "old-layout", kind: .layout, generation: 0)
        // store() already uses the new codec. Seed the historical bytes directly
        // so the test exercises migration rather than an already-upgraded row.
        let oldHex = old.map { String(format: "%02x", $0) }.joined()
        try databaseExecute(root, "UPDATE cache SET data=X'\(oldHex)' WHERE name LIKE 'layout-%'")
        let regions = [ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            source: "Original", translation: "변하지 않는 번역")]
        try await cache.storeRegions(regions, for: "saved", kind: .translation, generation: 0)
        let before = try await cache.statistics()
        let access = try databaseInteger(root, "SELECT SUM(accessed) FROM cache")
        let baseCount = try databaseInteger(root, "SELECT COUNT(*) FROM region_bases")
        // A failed write must preserve the old readable blob and allow retry.
        try databaseExecute(root, "CREATE TRIGGER reject_repack BEFORE UPDATE OF data ON cache BEGIN SELECT RAISE(ABORT,'test'); END")
        do {
            try await cache.compact()
            Issue.record("Expected an injected write failure")
        } catch {}
        #expect(try await cache.statistics().payloadBytes == before.payloadBytes)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM cache_policy WHERE name='payload-compression-v2'") == 0)
        try databaseExecute(root, "DROP TRIGGER reject_repack")
        try await cache.compact()
        #expect(try await cache.statistics().payloadBytes < before.payloadBytes)
        #expect(try databaseInteger(root, "SELECT SUM(accessed) FROM cache") == access)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == baseCount)
        let completed = try databaseContents(root)
        try await cache.compact()
        #expect(try databaseContents(root) == completed)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.data(for: "old-layout", kind: .layout) == raw)
        #expect(try await reopened.regions(for: "saved", kind: .translation) == regions)
        try await reopened.storeRegions(regions, for: "second-variant", kind: .translation, generation: 0)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == baseCount)
        try await reopened.store(Data("ATZ2invalid".utf8), for: "broken-v2", kind: .layout, generation: 0)
        #expect(try await reopened.data(for: "broken-v2", kind: .layout) == nil)
    }

    @Test func sharedBaseCompressionPreservesIdentityAccountingAndRetries() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let regions = [ReaderTranslationRegion(id: "base", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            source: String(repeating: "원문 Original ", count: 8), translation: "보존할 번역")]
        let archive = try ReaderTranslationRegionArchive(regions)
        // Seed a valid historical uncompressed base under the canonical identity.
        let raw = try ReaderTranslationCacheCodec.unpack(archive.base)
        let packed = try ReaderTranslationCacheCodec.repack(raw)
        #expect(packed.count < raw.count)
        try await cache.storeRegions(regions, for: "first", kind: .translation, generation: 0)
        let canonicalID = ReaderTranslationCacheIdentity.digest(archive.base)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases WHERE name='\(canonicalID)'") == 1)
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        try databaseExecute(root, "UPDATE region_bases SET data=X'\(hex)'")
        let before = try await cache.statistics()
        let access = try databaseInteger(root, "SELECT SUM(accessed) FROM cache")
        try databaseExecute(root, "CREATE TRIGGER reject_base_repack BEFORE UPDATE OF data ON region_bases BEGIN SELECT RAISE(ABORT,'test'); END")
        do {
            try await cache.compact()
            Issue.record("Expected an injected base write failure")
        } catch {}
        #expect(try await cache.statistics().payloadBytes == before.payloadBytes)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM cache_policy WHERE name='base-compression-v2'") == 0)
        try databaseExecute(root, "DROP TRIGGER reject_base_repack")
        try await cache.compact()
        #expect(try await cache.statistics().payloadBytes == before.payloadBytes - Int64(raw.count - packed.count))
        #expect(try databaseInteger(root, "SELECT SUM(accessed) FROM cache") == access)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_links WHERE base='\(canonicalID)'") == 1)
        let completed = try databaseContents(root)
        try await cache.compact()
        #expect(try databaseContents(root) == completed)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: "first", kind: .translation) == regions)
        try await reopened.storeRegions(regions, for: "second", kind: .translation, generation: 0)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 1)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_links") == 2)
        try await reopened.remove("first", kind: .translation)
        #expect(try await reopened.regions(for: "second", kind: .translation) == regions)
        #expect(try databaseInteger(root, "SELECT bytes FROM totals") == databaseInteger(root,
            "SELECT (SELECT COALESCE(SUM(length(data)),0) FROM cache)+(SELECT COALESCE(SUM(length(data)),0) FROM region_bases)"))
        try await reopened.remove("second", kind: .translation)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 0)
        #expect(try await reopened.statistics().payloadBytes == 0)
    }

    @Test func compactPagesMigrateWithoutChangingSavedWorkOrLRU() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let regions = [ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2),
            source: "Original 原文", translation: "보존할 번역", polygon: [CGPoint(x: 0.1, y: 0.2)],
            confidence: 0.98, sourceOrientation: .vertical, sourceSingleVerticalColumn: true)]
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .metadata] {
            try await cache.storeRegions(regions, for: "saved", kind: kind, generation: 0)
        }
        for index in 0..<100 {
            try await cache.store(noise(1_200), for: "layout-\(index)", kind: .layout, generation: 0)
        }
        #expect(try databaseInteger(root, "PRAGMA page_size") == 1024)
        // Recreate the shipped 4 KiB layout, including its overflow-page cost.
        try databaseExecute(root, "PRAGMA page_size=4096; VACUUM")
        #expect(try databaseInteger(root, "PRAGMA page_size") == 4096)
        let before = try await cache.statistics()
        let saved = try databaseContents(root)
        let reopened = ReaderTranslationDiskCache(directory: root)
        let after = try await reopened.statistics()
        #expect(try databaseInteger(root, "PRAGMA page_size") == 1024)
        #expect(after.bytes < before.bytes * 8 / 10)
        #expect(after.entries == before.entries)
        #expect(after.payloadBytes == before.payloadBytes)
        // Includes exact packed bytes, timestamps, shared references and policy.
        #expect(try databaseContents(root) == saved)
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .metadata] {
            #expect(try await reopened.regions(for: "saved", kind: kind) == regions)
        }
        #expect(try await reopened.data(for: "layout-50", kind: .layout) == noise(1_200))
        try await reopened.flushAccesses()
        let again = ReaderTranslationDiskCache(directory: root)
        #expect(try await again.statistics().entries == after.entries)
        try await again.remove("saved", kind: .ocr)
        #expect(try await again.regions(for: "saved", kind: .translation) == regions)
        print("CACHE_PAGE_MIGRATION before=\(before.bytes) after=\(after.bytes) payload=\(after.payloadBytes)")
    }

    @Test func rendererRevisionRetiresOnlyRecomputableLayouts() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let settings = ReaderTranslationSettings()
        try await cache.synchronizeSettings(settings)
        let generation = await cache.currentGeneration()
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .layout] {
            try await cache.store(Data("preserved".utf8), for: "fixture", kind: kind, generation: generation)
        }
        let previousPolicy = ReaderTranslationCacheIdentity.encoded(settings.overlay)
        try databaseExecute(root, "UPDATE cache_policy SET value='\(previousPolicy)' WHERE name='layout'")
        let reopened = ReaderTranslationDiskCache(directory: root)
        try await reopened.synchronizeSettings(settings)
        #expect(try await reopened.data(for: "fixture", kind: .layout) == nil)
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation] {
            #expect(try await reopened.data(for: "fixture", kind: kind) == Data("preserved".utf8))
        }
    }

    @Test func reopeningRemovesLegacyRastersAndPreservesDurableWork() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .layout] {
            try await disk.store(Data("saved work".utf8), for: "keep", kind: kind, generation: 0)
        }
        try databaseExecute(root, "INSERT INTO cache(name,data,accessed) VALUES('snapshot-old.cache',zeroblob(4000000),0)")
        let before = try await disk.statistics().bytes
        let reopened = ReaderTranslationDiskCache(directory: root)
        let after = try await reopened.statistics()
        #expect(after.bytes < before / 10)
        #expect(after.entries == 3)
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .layout] {
            #expect(try await reopened.data(for: "keep", kind: kind) == Data("saved work".utf8))
        }
        try await reopened.store(noise(100_000), for: "new", kind: .snapshot, generation: 0)
        #expect(try await !reopened.contains("new", kind: .snapshot))
    }

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

    @Test(arguments: [false, true])
    func shrinkingLimitEvictsLeastRecentlyUsedAcrossKinds(reopen: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ReaderTranslationDiskCache(directory: root)
        for (key, kind) in [("first", ReaderTranslationDiskCache.Kind.ocr), ("second", .translation), ("third", .layout)] {
            try await original.store(noise(65_536), for: key, kind: kind, generation: 0)
        }
        try await original.markUsed("first", kind: .ocr)
        let occupied = try await original.statistics().bytes
        let cache = reopen ? ReaderTranslationDiskCache(directory: root) : original
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

    @Test func manySmallEntriesShareStorageAndReopenWithoutRescanningLegacyFiles() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let started = Date()
        for index in 0..<1_000 {
            try await cache.store(Data("small translation \(index)".utf8), for: String(index), kind: .translation, generation: 0)
        }
        let stats = try await cache.statistics()
        #expect(stats.entries == 1_000)
        #expect(stats.bytes > stats.payloadBytes)
        #expect(stats.bytes < 1_000 * 4_096)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["cache.sqlite"])
        // Once migration is complete, normal opens must not enumerate/import new legacy files.
        let stray = root.appendingPathComponent("ocr-unrelated-late.cache")
        try Data("late".utf8).write(to: stray)
        let reopenStart = Date()
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.statistics().entries == 1_000)
        #expect(try await reopened.data(for: "500", kind: .translation) == Data("small translation 500".utf8))
        print("CACHE_STORAGE entries=1000 allocated=\(stats.bytes) payload=\(stats.payloadBytes) writeSeconds=\(reopenStart.timeIntervalSince(started)) reopenSeconds=\(Date().timeIntervalSince(reopenStart))")
        // Replacement and deletion must update totals without counting the same key twice.
        try await reopened.store(Data("replacement".utf8), for: "500", kind: .translation, generation: 0)
        #expect(try await reopened.statistics().entries == 1_000)
        try await reopened.remove("500", kind: .translation)
        #expect(try await reopened.statistics().entries == 999)
    }

    @Test func indexedReadsWithOneHundredThousandEntries() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.store(Data("hot".utf8), for: "hot", kind: .translation, generation: 0)
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        // Index lookup scales with entry count. Large payload allocation is
        // covered separately; avoid writing 25 MB just to seed this index.
        #expect(sqlite3_exec(handle, """
            WITH RECURSIVE numbers(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM numbers WHERE x<100000)
            INSERT INTO cache(name,data,accessed)
            SELECT 'translation-bulk-' || printf('%06d',x), zeroblob(1), x FROM numbers
            """, nil, nil, nil) == SQLITE_OK)
        #expect(try await cache.statistics().entries == 100_001)
        let start = Date()
        for _ in 0..<100 {
            #expect(try await cache.data(for: "hot", kind: .translation) == Data("hot".utf8))
            #expect(try await cache.data(for: "missing", kind: .translation) == nil)
        }
        print("CACHE_LARGE_READ entries=100001 hits=100 misses=100 seconds=\(Date().timeIntervalSince(start))")
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.data(for: "hot", kind: .translation) == Data("hot".utf8))
        #expect(try await reopened.statistics().entries == 100_001)
    }

    @Test func newestEntryReadsAvoidWritesAndTiedLegacyAccessStillPromotes() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.store(Data("first".utf8), for: "first", kind: .translation, generation: 0)
        try await cache.store(Data("second".utf8), for: "second", kind: .translation, generation: 0)
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        func version() throws -> Int32 {
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(handle, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            #expect(sqlite3_step(statement) == SQLITE_ROW)
            return sqlite3_column_int(statement, 0)
        }
        let initial = try version()
        for _ in 0..<10 {
            #expect(try await cache.data(for: "second", kind: .translation) == Data("second".utf8))
            try await cache.markUsed("second", kind: .translation)
        }
        #expect(try version() == initial)
        try await cache.markUsed("first", kind: .translation)
        #expect(try version() != initial)
        // Imported legacy files can have identical timestamps: the smaller name
        // must still move past the other entry when touched.
        #expect(sqlite3_exec(handle, "UPDATE cache SET accessed=42", nil, nil, nil) == SQLITE_OK)
        let tied = try version()
        let firstName = ReaderTranslationCacheIdentity.digest("first")
        let secondName = ReaderTranslationCacheIdentity.digest("second")
        try await cache.markUsed(firstName < secondName ? "first" : "second", kind: .translation)
        #expect(try version() != tied)
    }

    @Test func legacyBatchMigrationReducesActualAllocationAndPreservesEveryEntry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var previousAllocation: Int64 = 0
        for index in 0..<512 {
            let file = root.appendingPathComponent("translation-" + ReaderTranslationCacheIdentity.digest(String(index)) + ".cache")
            try Data("cached translation \(index)".utf8).write(to: file)
            let size = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            previousAllocation += Int64(max(size.totalFileAllocatedSize ?? 0, size.fileSize ?? 0))
        }
        let started = Date()
        let cache = ReaderTranslationDiskCache(directory: root)
        let stats = try await cache.statistics()
        #expect(stats.entries == 512)
        #expect(stats.bytes < previousAllocation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["cache.sqlite"])
        for index in 0..<512 {
            #expect(try await cache.data(for: String(index), kind: .translation) == Data("cached translation \(index)".utf8))
        }
        print("CACHE_MIGRATION entries=512 beforeAllocated=\(previousAllocation) afterAllocated=\(stats.bytes) migrateAndReadSeconds=\(Date().timeIntervalSince(started))")
    }

    @Test func interruptedMigrationKeepsCommittedNewerRowsAndImportsRemainingFiles() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = ReaderTranslationDiskCache(directory: root)
        try await initial.store(Data("new translation".utf8), for: "same", kind: .translation, generation: 0)
        // Simulate interruption after commit but before deleting the original file and marking migration complete.
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "PRAGMA user_version=0", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        for key in ["same", "remaining"] {
            let file = root.appendingPathComponent("translation-" + ReaderTranslationCacheIdentity.digest(key) + ".cache")
            try Data("legacy translation".utf8).write(to: file)
        }
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.data(for: "same", kind: .translation) == Data("new translation".utf8))
        #expect(try await reopened.data(for: "remaining", kind: .translation) == Data("legacy translation".utf8))
        #expect(try await reopened.statistics().entries == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["cache.sqlite"])
    }

    @Test func emptyPayloadAndZeroQuotaPreserveUnrelatedFiles() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.store(Data(), for: "empty", kind: .layout, generation: 0)
        #expect(try await cache.data(for: "empty", kind: .layout) == Data())
        let unrelated = root.appendingPathComponent("unrelated.cache")
        try Data("keep".utf8).write(to: unrelated)
        try await cache.setByteLimit(0)
        #expect(try await cache.statistics().bytes == 0)
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
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

    @Test func migrationRemovesOnlyLegacyImagesBeforeEnforcingTheMetadataQuota() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let regions = [ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                               source: "hello", translation: "안녕")]
        let raw = try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
        for kind in ["ocr", "translation", "layout"] {
            let data = kind == "layout" ? Data("[{\"x\":1}]".utf8) : raw
            try data.write(to: root.appendingPathComponent(kind + "-" + ReaderTranslationCacheIdentity.digest("page") + ".cache"))
        }
        let size: Int64 = 100_000
        for name in ["render-old.cache", "renderIndex-old.cache"] {
            try Data(repeating: 7, count: 1_000_000).write(to: root.appendingPathComponent(name))
        }
        let unrelated = root.appendingPathComponent("unrelated.cache")
        try Data("leave me alone".utf8).write(to: unrelated)
        let reopened = ReaderTranslationDiskCache(directory: root, byteLimit: size)
        try await reopened.compact()
        #expect(try await reopened.statistics().bytes <= size)
        #expect(try await reopened.regions(for: "page", kind: .ocr) == regions)
        #expect(try await reopened.regions(for: "page", kind: .translation) == regions)
        #expect(try await reopened.data(for: "page", kind: .layout) == Data("[{\"x\":1}]".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("render-old.cache").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("renderIndex-old.cache").path))
        #expect(try Data(contentsOf: unrelated) == Data("leave me alone".utf8))
        #expect(try await ReaderTranslationDiskCache(directory: root).statistics().bytes <= size)
    }

    @Test func sharedRegionsSurviveDeletionReplacementAndReopening() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [
            .init(id: "one", text: "同じ原文"), .init(id: "two", text: "次の台詞")
        ])
        let identities = try NativeTranslationReuseIdentity.identitiesBySegmentID(
            configuration: .openAI(model: "cache-test"), request: request)
        var regions = request.segments.map { segment in
            var region = ReaderTranslationRegion(id: segment.id, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                source: segment.text, translation: "번역 " + segment.id, polygon: [CGPoint(x: 0.123456789, y: 0.987654321)])
            region.translationReuseIdentity = identities[segment.id]
            return region
        }
        let source = regions.map { value in
            var value = value; value.translation = nil; value.translationReuseIdentity = nil; return value
        }
        try await cache.storeRegions(source, for: "ocr", kind: .ocr, generation: 0)
        try await cache.storeRegions(regions, for: "ko", kind: .translation, generation: 0)
        regions[0].translation = "different target"
        try await cache.storeRegions(regions, for: "en", kind: .translation, generation: 0)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 1)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_links") == 3)
        try await cache.remove("ocr", kind: .ocr)
        try await cache.store(Data("replaced".utf8), for: "ko", kind: .translation, generation: 0)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: "en", kind: .translation) == regions)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 1)
        try await reopened.remove("en", kind: .translation)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 0)
        #expect(try await reopened.statistics().payloadBytes == 8)
    }

    @Test func sharedBaseEvictionKeepsTheNewestVariantReadable() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        var region = ReaderTranslationRegion(id: "one", rect: .zero, source: noise(20_000).base64EncodedString())
        try await cache.storeRegions([region], for: "old-ocr", kind: .ocr, generation: 0)
        region.translation = noise(30_000).base64EncodedString()
        try await cache.storeRegions([region], for: "old-translation", kind: .translation, generation: 0)
        region.translation = "newest " + (region.translation ?? "")
        try await cache.storeRegions([region], for: "keep", kind: .translation, generation: 0)
        let before = try await cache.statistics()
        try await cache.setByteLimit(before.bytes - 1)
        #expect(try await cache.statistics().bytes <= before.bytes - 1)
        #expect(try await cache.statistics().entries < before.entries)
        #expect(try await cache.regions(for: "keep", kind: .translation) == [region])
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 1)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM pragma_foreign_key_check") == 0)
    }

    @Test func failedSharedReplacementRollsBackBaseLinksPayloadAndTotals() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let old = [ReaderTranslationRegion(id: "one", rect: .zero, source: "original", translation: "원래 번역")]
        try await cache.storeRegions(old, for: "key", kind: .translation, generation: 0)
        let before = try await cache.statistics().payloadBytes
        try databaseExecute(root, "CREATE TRIGGER fail_link BEFORE INSERT ON region_links BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        do {
            try await cache.storeRegions([ReaderTranslationRegion(id: "new", rect: .zero, source: "new source")],
                for: "key", kind: .translation, generation: 0)
            Issue.record("Injected transaction failure must propagate")
        } catch { }
        #expect(try await cache.regions(for: "key", kind: .translation) == old)
        #expect(try await cache.statistics().payloadBytes == before)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 1)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_links") == 1)
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

    @Test(arguments: [false, true])
    func recomputingPageRepairsSharedBaseWithoutDiscardingSiblingTranslations(readCorruptFirst: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let source = [ReaderTranslationRegion(id: "one", rect: .zero, source: "Original source")]
        var translated = source
        translated[0].translation = "보존할 번역"
        try await cache.storeRegions(source, for: "ocr", kind: .ocr, generation: 0)
        try await cache.storeRegions(translated, for: "translated", kind: .translation, generation: 0)
        try databaseExecute(root, "UPDATE region_bases SET data=X'00'")
        if readCorruptFirst {
            #expect(try await cache.regions(for: "ocr", kind: .ocr) == nil)
        }
        // The translation's link still owns the damaged base, even when the OCR
        // miss deleted its own link. Recomputed OCR must heal both consumers.
        try await cache.storeRegions(source, for: "ocr", kind: .ocr, generation: 0)
        #expect(try await cache.regions(for: "ocr", kind: .ocr) == source)
        #expect(try await cache.regions(for: "translated", kind: .translation) == translated)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 1)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_links") == 2)
        #expect(try databaseInteger(root, "SELECT bytes FROM totals") == databaseInteger(root,
            "SELECT COALESCE((SELECT SUM(length(data)) FROM cache),0)+COALESCE((SELECT SUM(length(data)) FROM region_bases),0)"))
        // An already healthy base must not add a write merely to share it.
        try databaseExecute(root, "CREATE TRIGGER reject_healthy_base_update BEFORE UPDATE ON region_bases BEGIN SELECT RAISE(ABORT,'unexpected write'); END")
        try await cache.storeRegions(source, for: "another", kind: .ocr, generation: 0)
        #expect(try await cache.regions(for: "another", kind: .ocr) == source)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: "translated", kind: .translation) == translated)
    }

    @Test(arguments: [1, 3])
    func realRegionCorpusReducesAllocatedStorageAndMigratesLosslessly(variants: Int) async throws {
        let root = directory()
        let legacyRoot = directory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: legacyRoot)
        }
        let bundle = Bundle(for: ReaderCacheFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "CacheRealRegions", withExtension: "json"))
        let pages = try JSONDecoder().decode([String: [ReaderTranslationStoredRegion]].self, from: Data(contentsOf: url))
        let optimized = ReaderTranslationDiskCache(directory: root)
        let legacy = ReaderTranslationDiskCache(directory: legacyRoot)
        for (key, stored) in pages.sorted(by: { $0.key < $1.key }) {
            let regions = stored.map(\.region)
            let source = regions.map { value in
                var value = value; value.translation = nil; value.translationReuseIdentity = nil; return value
            }
            try await legacy.store(ReaderTranslationCacheCodec.packSharedBase(JSONEncoder().encode(source.map(ReaderTranslationStoredRegion.init))), for: key, kind: .ocr, generation: 0)
            try await optimized.storeRegions(source, for: key, kind: .ocr, generation: 0)
            // One actual Korean translation plus two simulated settings variants.
            for variant in 0..<variants {
                let translated = regions.map { value in
                    var value = value
                    if variant > 0, let text = value.translation { value.translation = text + " [variant \(variant)]" }
                    return value
                }
                let name = key + "-\(variant)"
                try await legacy.store(ReaderTranslationCacheCodec.packSharedBase(JSONEncoder().encode(translated.map(ReaderTranslationStoredRegion.init))), for: name, kind: .translation, generation: 0)
                try await optimized.storeRegions(translated, for: name, kind: .translation, generation: 0)
                #expect(try await optimized.regions(for: name, kind: .translation) == translated)
            }
        }
        // Model the shipped legacy storage, not a new compact-page database.
        try databaseExecute(legacyRoot, "PRAGMA page_size=4096; VACUUM")
        let before = try await legacy.statistics()
        let after = try await optimized.statistics()
        #expect(after.entries == before.entries)
        #expect(after.payloadBytes < before.payloadBytes)
        #expect(after.bytes < before.bytes)
        let accessBefore = try databaseInteger(legacyRoot, "SELECT SUM(accessed) FROM cache")
        try await legacy.compact()
        #expect(try databaseInteger(legacyRoot, "SELECT SUM(accessed) FROM cache") == accessBefore)
        let migrated = try await legacy.statistics()
        #expect(migrated.payloadBytes == after.payloadBytes)
        #expect(migrated.bytes < before.bytes)
        let reopened = ReaderTranslationDiskCache(directory: legacyRoot)
        for (key, stored) in pages {
            #expect(try await reopened.regions(for: key + "-0", kind: .translation) == stored.map(\.region))
        }
        // Repeat migration is idempotent and shared bases are removed by LRU eviction.
        try await reopened.compact()
        #expect(try await reopened.statistics().payloadBytes == migrated.payloadBytes)
        try await reopened.setByteLimit(65_536)
        #expect(try await reopened.statistics().bytes <= 65_536)
        #expect(try databaseInteger(legacyRoot, "SELECT COUNT(*) FROM region_bases WHERE NOT EXISTS (SELECT 1 FROM region_links WHERE base=region_bases.name)") == 0)
        #expect(try databaseInteger(legacyRoot, "SELECT bytes FROM totals") == databaseInteger(legacyRoot,
            "SELECT COALESCE((SELECT SUM(length(data)) FROM cache),0)+COALESCE((SELECT SUM(length(data)) FROM region_bases),0)"))
        print("CACHE_NORMALIZED variants=\(variants) realPages=\(pages.count) entries=\(after.entries) oldPayload=\(before.payloadBytes) newPayload=\(after.payloadBytes) oldAllocated=\(before.bytes) newAllocated=\(after.bytes) migratedAllocated=\(migrated.bytes)")
    }

    @Test(arguments: ["model", "language", "prompt", "credentials", "provider", "filter"])
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
        case "language": settings.targetLanguage = "en"
        case "prompt": settings.metadataInstructions += " Translate differently."
        case "credentials": settings.credentialGeneration += 1
        case "provider": settings.provider = .custom; settings.custom.baseURL = "https://example.invalid/v1"; settings.model = "custom-model"
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

    @Test func appearanceAndOperationalSettingsKeepAllResults() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await cache.synchronizeSettings(settings)
        let generation = await cache.currentGeneration(settings: settings)
        for kind in ReaderTranslationDiskCache.Kind.allCases {
            try await cache.store(Data("value".utf8), for: "keep", kind: kind, generation: generation)
        }
        settings.maximumConcurrentRequests = 2
        settings.cacheLimitBytes = 200_000_000
        settings.automaticallyTranslate.toggle()
        settings.translateMangaTitles.toggle()
        settings.rightToLeftPanelOrder = true // A chapter's reading direction is not a global model switch.
        try await cache.synchronizeSettings(settings)
        #expect(await cache.currentGeneration(settings: settings) == generation)
        #expect(try await cache.statistics().entries == 4) // OCR, translation, metadata and layout; no persisted raster.
        // V2 page bitmaps do not depend on the retired overlay appearance options.
        settings.overlay.opacity = 0.5
        try await cache.synchronizeSettings(settings)
        #expect(await cache.currentGeneration(settings: settings) == generation)
        #expect(try await cache.statistics().entries == 4)
        #expect(try await cache.contains("keep", kind: .translation))
        #expect(try await cache.contains("keep", kind: .metadata))
        #expect(try await cache.contains("keep", kind: .layout))
    }

    @Test func pageSettingsPreserveMetadataAndItsPendingWriters() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let original = settings
        try await cache.synchronizeSettings(settings)
        let pageGeneration = await cache.currentGeneration(settings: settings)
        let metadataGeneration = await cache.currentGeneration(settings: settings, kind: .metadata)
        let metadata = [ReaderTranslationRegion(id: "title", rect: .zero, source: "Title", translation: "제목")]
        try await cache.storeRegions(metadata, for: "title", kind: .metadata, generation: metadataGeneration)
        try await cache.store(Data("page".utf8), for: "page", kind: .translation, generation: pageGeneration)
        settings.translationSourceLanguages = ["ja"]
        try await cache.synchronizeSettings(settings)
        #expect(try await cache.regions(for: "title", kind: .metadata) == metadata)
        #expect(try await cache.contains("page", kind: .translation) == false)
        #expect(await cache.currentGeneration(settings: original, kind: .metadata) == metadataGeneration)
        try await cache.storeRegions(metadata, for: "in-flight", kind: .metadata, generation: metadataGeneration)
        let queued = await cache.currentGeneration(settings: original, kind: .metadata)
        try await cache.store(Data("queued".utf8), for: "queued", kind: .metadata, generation: queued)
        try await cache.store(Data("late".utf8), for: "late", kind: .translation, generation: pageGeneration)
        #expect(try await cache.statistics().entries == 3)
        let reopened = ReaderTranslationDiskCache(directory: root)
        try await reopened.synchronizeSettings(settings)
        #expect(try await reopened.regions(for: "in-flight", kind: .metadata) == metadata)
        #expect(try await reopened.data(for: "queued", kind: .metadata) == Data("queued".utf8))
    }

    @Test(arguments: ["model", "target", "credentials", "metadataFilter", "clear"])
    func metadataInvalidationRejectsPendingWritersWithoutClearingUnrelatedPages(change: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let original = settings
        try await cache.synchronizeSettings(settings)
        let generation = await cache.currentGeneration(settings: settings, kind: .metadata)
        for kind in ReaderTranslationDiskCache.Kind.allCases {
            try await cache.store(Data("value".utf8), for: "old", kind: kind, generation: generation)
        }
        switch change {
        case "model": settings.model = "different-model"
        case "target": settings.targetLanguage = "en"
        case "credentials": settings.credentialGeneration += 1
        case "metadataFilter": settings.authorSourceLanguages = ["ja"]; settings.sourceLabelSourceLanguages = ["en"]
        default: try await cache.clear()
        }
        try await cache.synchronizeSettings(settings)
        #expect(try await !cache.contains("old", kind: .metadata))
        #expect(try await cache.contains("old", kind: .translation) == (change == "metadataFilter"))
        #expect(try await cache.contains("old", kind: .ocr) == (change != "clear"))
        try await cache.store(Data("late".utf8), for: "late", kind: .metadata, generation: generation)
        #expect(try await !cache.contains("late", kind: .metadata))
        if change != "clear" {
            let queued = await cache.currentGeneration(settings: original, kind: .metadata)
            try await cache.storeRegions([.init(id: "title", rect: .zero, source: "Old")],
                for: "queued", kind: .metadata, generation: queued)
            #expect(try await !cache.contains("queued", kind: .metadata))
        }
    }

    @Test(arguments: [false, true])
    func legacyMetadataMovesBeforePageInvalidationPreservingStorage(normalized: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let regions = [ReaderTranslationRegion(id: "title", rect: .zero, source: "Old title", translation: "기존 제목")]
        if normalized {
            try await cache.storeRegions(regions, for: "legacy", kind: .translation, generation: 0)
        } else {
            try await cache.store(JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init)),
                for: "legacy", kind: .translation, generation: 0)
        }
        let page = [ReaderTranslationRegion(id: "title", rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.1), source: "Page")]
        try await cache.storeRegions(page, for: "page", kind: .translation, generation: 0)
        try databaseExecute(root, "DELETE FROM cache_policy WHERE name='metadata-kind-v1'; INSERT INTO cache_policy(name,value) VALUES('translation','old-policy'); UPDATE cache SET accessed=42")
        let before = try await cache.statistics()
        let reopened = ReaderTranslationDiskCache(directory: root)
        let after = try await reopened.statistics()
        #expect(after.entries == before.entries && after.payloadBytes == before.payloadBytes)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM cache WHERE accessed=42") == 2)
        #expect(try await !reopened.contains("legacy", kind: .translation))
        #expect(try await reopened.regions(for: "legacy", kind: .metadata) == regions)
        #expect(try await reopened.regions(for: "page", kind: .translation) == page)
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.ocr.detectorMinimumBoxSide = 2
        try await reopened.synchronizeSettings(settings)
        #expect(try await !reopened.contains("page", kind: .translation))
        #expect(try await reopened.regions(for: "legacy", kind: .metadata) == regions)
        try await reopened.compact()
        let again = ReaderTranslationDiskCache(directory: root)
        try await again.synchronizeSettings(settings)
        #expect(try await again.regions(for: "legacy", kind: .metadata) == regions)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_links") == 1)
        #expect(try databaseInteger(root, "SELECT COUNT(*) FROM region_bases") == 1)
        #expect(try databaseInteger(root, "SELECT bytes FROM totals") == databaseInteger(root,
            "SELECT COALESCE((SELECT SUM(length(data)) FROM cache),0)+COALESCE((SELECT SUM(length(data)) FROM region_bases),0)"))
    }

    private func databaseExecute(_ root: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func databaseContents(_ root: URL) throws -> [String] {
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var result: [String] = []
        for query in [
            "SELECT name || '|' || hex(data) || '|' || accessed FROM cache ORDER BY name",
            "SELECT name || '|' || hex(data) FROM region_bases ORDER BY name",
            "SELECT name || '|' || base FROM region_links ORDER BY name",
            "SELECT name || '|' || value FROM cache_policy ORDER BY name",
            "SELECT entries || '|' || bytes FROM totals"
        ] {
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(String(cString: sqlite3_column_text(statement, 0)))
            }
        }
        return result
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

private final class ReaderCacheFixtureBundle: NSObject {}
