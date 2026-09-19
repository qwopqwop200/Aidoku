import Foundation
import SQLite3
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationDiskCacheTests {
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

    @Test(arguments: ["reader-render-v32-neutral-readable-edge", "reader-render-v31-readable-source-role-coverage", "reader-render-v30-readable-paragraph-ink-coverage", "reader-render-v29-source-role-cleanup-geometry", "reader-render-v28-short-paragraph-guard", "reader-render-v27-readable-palette-ink", "reader-render-v26-horizontal-caption-anchors", "reader-render-v24-readable-paragraph-contours", "reader-render-v25-source-anchored-captions", "reader-render-v23-source-stroke-opaque-ink", "reader-render-v21-korean-punctuation", "reader-render-v22-korean-orphans", "reader-render-v20-readable-source-colors", "reader-render-v19-faithful-source-colors", "reader-render-v18-neutral-ink-fringe", "reader-render-v17-chroma-emergency-wrap", "reader-render-v16-contrast-preserved-chroma", "reader-render-v15-korean-small-text", "reader-render-v3-source-coverage", "reader-render-v4-visible-source-bands", "reader-render-v5-normal-font-floor", "reader-render-v6-korean-balanced-wrap", "reader-render-v7-resolved-font", "reader-render-v8-source-ink", "reader-render-v9-small-text", "reader-render-v9-word-safe-small-text", "reader-render-v10-fragment-line-profile", "reader-render-v11-balloon-contained-type"])
    func earlierLayoutsCannotBeReusedAfterRendererRevision(revision: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let settings = ReaderTranslationSettings()
        let size = CGSize(width: 390, height: 780)
        let crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        let legacyKey = ReaderTranslationCacheIdentity.encoded([
            revision,
            ReaderTranslationCacheIdentity.translation(page: "real-comic", settings: settings),
            ReaderTranslationCacheIdentity.encoded(settings.overlay),
            ReaderTranslationCacheIdentity.encoded(size), ReaderTranslationCacheIdentity.encoded(size),
            String(Double(3)), String(true), ReaderTranslationCacheIdentity.encoded(crop), String(false),
            ProcessInfo.processInfo.operatingSystemVersionString
        ])
        try await cache.store(Data("[{\"x\":-205}]".utf8), for: legacyKey, kind: .layout, generation: 0)
        let currentKey = ReaderTranslationCacheIdentity.render(page: "real-comic", settings: settings,
            imageSize: size, viewport: size, scale: 3, aspectFit: true, crop: crop, dark: false)
        #expect(currentKey != legacyKey)
        #expect(try await cache.data(for: legacyKey, kind: .layout) != nil)
        #expect(try await cache.data(for: currentKey, kind: .layout) == nil)
    }

    @Test(arguments: ["reader-ocr-v42-phonetic-kimi", "reader-ocr-v41-cross-panel-separator", "reader-ocr-v43-centered-phrases", "reader-ocr-v44-leaf-reading-bands"])
    func earlierMergedRubyRegionsCannotBeReused(revision: String) {
        let settings = ReaderTranslationSettings()
        let oldKey = ReaderTranslationCacheIdentity.encoded([
            revision, "page", ReaderTranslationCacheIdentity.encoded(settings.ocrConfiguration)
        ])
        #expect(oldKey != ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings))
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
        #expect(sqlite3_exec(handle, """
            WITH RECURSIVE numbers(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM numbers WHERE x<100000)
            INSERT INTO cache(name,data,accessed)
            SELECT 'translation-bulk-' || printf('%06d',x), zeroblob(256), x FROM numbers
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

    @Test func translationSettingsAndRenderGeometryHaveSeparateIdentities() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = ReaderTranslationSettings(defaults: defaults)
        let key = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        let ocrKey = ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings)
        for change in 0..<5 {
            var changed = settings
            switch change {
            case 0: changed.targetLanguage = "en"
            case 1: changed.model = "different-model"
            case 2: changed.reasoningEffort = .high
            case 3: changed.instructions = "different prompt"
            default: changed.credentialGeneration += 1
            }
            #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: changed) != key)
            #expect(ReaderTranslationCacheIdentity.ocr(page: "page", settings: changed) == ocrKey)
        }
        var changed = settings
        changed.overlay.opacity = 0.5
        changed.cacheLimitBytes = 10_000_000_000
        #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: changed) == key)
        changed.ocr.detectorMaximumSide = 800
        #expect(ReaderTranslationCacheIdentity.ocr(page: "page", settings: changed) != ocrKey)
        func render(_ settings: ReaderTranslationSettings, width: CGFloat = 390, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> String {
            ReaderTranslationCacheIdentity.render(page: "page", settings: settings, imageSize: CGSize(width: 600, height: 800),
                                                  viewport: CGSize(width: width, height: 800), scale: 3, aspectFit: true, crop: crop, dark: false)
        }
        #expect(render(settings) != render(settings, width: 430))
        #expect(render(settings) != render(settings, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        #expect(render(settings) != render(changed))
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

    @Test @MainActor func renderedVariantsStayOnlyInMemoryAndKeepDurableLayouts() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let render = ReaderTranslationRenderCache(disk: disk)
        let image = ReaderTranslationPersistentPipelineTests.image()
        for index in 0..<5 {
            try await disk.store(Data("[]".utf8), for: String(index), kind: .layout, generation: 0)
            await render.store(image, key: String(index), pageIdentity: "page", diskGeneration: 0)
        }
        for index in 0..<3 { #expect(render.cachedImage(for: String(index)) == nil) }
        #expect(render.cachedImage(for: "4") != nil)
        #expect(render.cachedImage(for: "3") != nil)
        #expect(try await disk.statistics().payloadBytes == 10)
        #expect(try await disk.statistics().entries == 5)
        let reopened = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        #expect(await reopened.load("4") == nil)
        for index in 0..<5 { #expect(try await disk.data(for: String(index), kind: .layout) != nil) }
    }

    @Test @MainActor func preparingFarPagesKeepsOnlyNeighborsInMemory() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let render = ReaderTranslationRenderCache(disk: disk)
        let settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        render.setNearbyPages(pageKeys: ["near"], settings: settings)
        let near = ReaderTranslationCacheIdentity.translation(page: "near", settings: settings)
        let far = ReaderTranslationCacheIdentity.translation(page: "far", settings: settings)
        let image = ReaderTranslationPersistentPipelineTests.image()
        await render.store(image, key: "near-render", pageIdentity: near, diskGeneration: 0)
        await render.store(image, key: "far-render", pageIdentity: far, diskGeneration: 0)
        #expect(render.cachedImage(for: "near-render") != nil)
        #expect(render.cachedImage(for: "far-render") == nil)
        #expect(try await disk.statistics().payloadBytes == 0)
        render.setNearbyPages(pageKeys: ["far"], settings: settings)
        #expect(await render.load("far-render") == nil)
        #expect(render.needsImage(for: far))
        #expect(render.cachedImage(for: "near-render") == nil)
        await render.store(image, key: "far-render", pageIdentity: far, diskGeneration: 0)
        #expect(render.cachedImage(for: "far-render") != nil)
        render.clearMemory()
        await render.store(image, key: "late-render", pageIdentity: far, diskGeneration: 0)
        #expect(render.cachedImage(for: "far-render") == nil)
        #expect(render.cachedImage(for: "late-render") == nil)
    }

    @Test @MainActor func distantSnapshotCannotEvictNearestPages() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let render = ReaderTranslationRenderCache(disk: disk)
        let settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        render.setNearbyPages(pageKeys: ["current", "next", "previous"], settings: settings,
                              availableMemory: 1_280 * 1_024 * 1_024)
        let context = try #require(CGContext(data: nil, width: 2048, height: 2048, bitsPerComponent: 8,
            bytesPerRow: 2048 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = UIImage(cgImage: try #require(context.makeImage()))
        for key in ["current", "next", "previous"] {
            await render.store(image, key: key,
                pageIdentity: ReaderTranslationCacheIdentity.translation(page: key, settings: settings), diskGeneration: 0)
        }
        #expect(render.cachedImage(for: "current") != nil)
        #expect(render.cachedImage(for: "next") != nil)
        #expect(render.cachedImage(for: "previous") == nil)
        #expect(render.bitmapBytes <= render.currentBitmapByteLimit)
    }

    @Test @MainActor func bitmapWindowExpandsAndShrinksWithHeadroom() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let render = ReaderTranslationRenderCache(disk: disk)
        let settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let keys = (0..<9).map(String.init)
        render.setNearbyPages(pageKeys: keys, settings: settings, availableMemory: 2_048 * 1_024 * 1_024)
        #expect(render.nearbyPageCount == 7)
        for key in keys.prefix(7) {
            await render.store(ReaderTranslationPersistentPipelineTests.image(), key: key,
                pageIdentity: ReaderTranslationCacheIdentity.translation(page: key, settings: settings), diskGeneration: 0)
        }
        #expect(render.cachedImage(for: "6") != nil)
        render.setNearbyPages(pageKeys: keys, settings: settings, availableMemory: 1_280 * 1_024 * 1_024)
        #expect(render.nearbyPageCount == 3)
        #expect(render.cachedImage(for: "0") != nil)
        #expect(render.cachedImage(for: "1") != nil)
        #expect(render.cachedImage(for: "2") != nil)
        #expect(render.cachedImage(for: "3") == nil)
        #expect(render.bitmapBytes <= render.currentBitmapByteLimit)
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
            region.sfxEnclosedBackground = false
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

    @Test(arguments: ["model", "language", "prompt", "credentials", "provider", "filter",
                      "ocrPixel", "ocrRegion", "ocrRecognition", "ocrMinimumSize"])
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
        case "prompt": settings.instructions += " Translate differently."
        case "credentials": settings.credentialGeneration += 1
        case "provider": settings.provider = .custom; settings.custom.baseURL = "https://example.invalid/v1"; settings.model = "custom-model"
        case "ocrPixel": settings.ocr.detectorPixelThreshold = 0.25
        case "ocrRegion": settings.ocr.detectorConfidenceThreshold = 0.55
        case "ocrRecognition": settings.ocr.confidenceThreshold = 0.8
        case "ocrMinimumSize": settings.ocr.detectorMinimumBoxSide = 2
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

    @Test func appearanceChangesOnlyRemoveLayoutsAndOperationalSettingsKeepAllResults() async throws {
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
        settings.overlay.opacity = 0.5
        try await cache.synchronizeSettings(settings)
        #expect(try await cache.statistics().entries == 3)
        #expect(try await cache.contains("keep", kind: .translation))
        #expect(try await cache.contains("keep", kind: .metadata))
        #expect(try await cache.contains("keep", kind: .ocr))
        #expect(try await cache.contains("keep", kind: .layout) == false)
    }

    @Test(arguments: ["ocrPixel", "ocrRegion", "ocrRecognition", "ocrMinimumSize", "ocrModel", "ocrResolution", "pageFilter"])
    func pageSettingsPreserveMetadataAndItsPendingWriters(change: String) async throws {
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
        switch change {
        case "ocrPixel": settings.ocr.detectorPixelThreshold = 0.25
        case "ocrRegion": settings.ocr.detectorConfidenceThreshold = 0.55
        case "ocrRecognition": settings.ocr.confidenceThreshold = 0.8
        case "ocrMinimumSize": settings.ocr.detectorMinimumBoxSide = 2
        case "ocrModel": settings.ocr.modelTier = .tiny
        case "ocrResolution": settings.ocr.detectorMaximumSide = 1280; settings.ocr.recognizerMaximumWidth = 1280
        default: settings.translationSourceLanguages = ["ja"]
        }
        try await cache.synchronizeSettings(settings)
        #expect(try await cache.regions(for: "title", kind: .metadata) == metadata)
        #expect(try await !cache.contains("page", kind: .translation))
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

    @Test(arguments: ["model", "target", "prompt", "credentials", "metadataFilter", "clear"])
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
        case "prompt": settings.instructions += " Use formal language."
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
