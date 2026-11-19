import Foundation
import SQLite3
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationCacheResilienceTests {
    /// A failing LRU flush (disk full, busy) must not turn already-read hits into errors.
    @Test func readsSurviveFailingAccessFlush() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let keys = (0..<40).map { "page-\($0)" }
        func exercise(_ cache: isolated ReaderTranslationDiskCache) throws {
            for key in keys { try cache.store(Data(key.utf8), for: key, kind: .layout, generation: 0) }
            try execute(root, "CREATE TRIGGER reject_touch BEFORE UPDATE OF accessed ON cache BEGIN SELECT RAISE(ABORT,'test'); END")
            for key in keys {
                #expect(try cache.data(for: key, kind: .layout) == Data(key.utf8))
            }
            try execute(root, "DROP TRIGGER reject_touch")
            try cache.store(Data("after".utf8), for: "after", kind: .layout, generation: 0)
            #expect(try cache.data(for: "after", kind: .layout) == Data("after".utf8))
        }
        try await exercise(cache)
    }

    /// Without auto_vacuum, deletions never shrink the file and trimming evicted every row.
    @Test func reopeningMigratesDatabasesWithoutAutoVacuum() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let original = ReaderTranslationDiskCache(directory: root)
            for key in ["first", "second", "third"] {
                let noise = Data((0..<65_536).map { _ in UInt8.random(in: 0...255) })
                try await original.store(noise, for: key, kind: .layout, generation: 0)
            }
        }
        try execute(root, "PRAGMA auto_vacuum=NONE; VACUUM;")
        #expect(try integer(root, "PRAGMA auto_vacuum") == 0)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.contains("third", kind: .layout))
        #expect(try integer(root, "PRAGMA auto_vacuum") == 1)
        let occupied = try await reopened.statistics().bytes
        try await reopened.setByteLimit(occupied - 1)
        #expect(try await reopened.contains("third", kind: .layout))
        #expect(try await reopened.statistics().bytes <= occupied - 1)
    }

    @Test func downloadTranslationRejectsRastersThatCanNeverFit() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }.pngData())
        let required = TranslationImageWorkBudget.requiredHeadroom(decodedBytes: 64 * 48 * 4)
        #expect(try DownloadImageTranslator.admittedDecodedBytes(png, physicalMemory: required + 1) == 64 * 48 * 4)
        #expect(throws: TranslationImageWorkBudget.AdmissionError.self) {
            try DownloadImageTranslator.admittedDecodedBytes(png, physicalMemory: required)
        }
    }

    private func execute(_ root: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func integer(_ root: URL, _ sql: String) throws -> Int64 {
        var handle: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("translation-cache-resilience-" + UUID().uuidString)
    }
}
