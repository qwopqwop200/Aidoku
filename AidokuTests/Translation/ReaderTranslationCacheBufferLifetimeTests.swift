import CoreGraphics
import Foundation
import SQLite3
import Testing
@testable import Aidoku

struct ReaderTranslationCacheBufferLifetimeTests {
    @Test(arguments: ["raw", "ATZ1", "ATZ2"])
    func decodedBytesOutliveStatementReplacementAndClear(format: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let original = randomBytes(count: 256 * 1024)
        let stored: Data
        switch format {
        case "ATZ1": stored = Data("ATZ1".utf8) + (try (original as NSData).compressed(using: .lzfse) as Data)
        case "ATZ2": stored = Data("ATZ2".utf8) + (try (original as NSData).compressed(using: .zlib) as Data)
        default:
            stored = original
            #expect(!ReaderTranslationCacheCodec.isPacked(ReaderTranslationCacheCodec.pack(original)))
        }
        try await disk.store(stored, for: "large", kind: .layout, generation: 0)
        let unlimited = try #require(try await disk.data(for: "large", kind: .layout))
        let bounded = try #require(try await disk.data(for: "large", kind: .layout, maximumBytes: original.count))
        #expect(unlimited == original)
        #expect(bounded == original)
        // Reuse SQLite's row storage before touching the first results again.
        // Borrowed compressed input must not become borrowed returned content.
        for index in 0..<4 {
            let replacement = Data(repeating: UInt8(index + 1), count: original.count + index * 64)
            try await disk.store(replacement, for: "large", kind: .layout, generation: 0)
            #expect(try await disk.data(for: "large", kind: .layout) == replacement)
        }
        try await disk.clear()
        #expect(unlimited == original)
        #expect(bounded == original)
    }

    @Test func rawAndEmptyReadBudgetsPreserveDurableBytes() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let raw = randomBytes(count: 256 * 1024)
        try await disk.store(raw, for: "raw", kind: .layout, generation: 0)
        #expect(try await disk.data(for: "raw", kind: .layout, maximumBytes: raw.count - 1) == nil)
        #expect(try await disk.contains("raw", kind: .layout))
        #expect(try await disk.data(for: "raw", kind: .layout, maximumBytes: raw.count) == raw)
        try await disk.store(Data(), for: "empty", kind: .layout, generation: 0)
        #expect(try await disk.data(for: "empty", kind: .layout, maximumBytes: -1) == nil)
        #expect(try await disk.contains("empty", kind: .layout))
        #expect(try await disk.data(for: "empty", kind: .layout, maximumBytes: 0) == Data())
        #expect(try await disk.data(for: "raw", kind: .layout, maximumBytes: raw.count - 1, discardOversized: true) == nil)
        #expect(try await !disk.contains("raw", kind: .layout))
    }

    @Test func sharedArchiveCompatibilityDataKeepsOwnershipAndBudget() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let regions = [ReaderTranslationRegion(id: "large", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2),
            source: String(repeating: "元の文字", count: 8192), translation: "Saved translation")]
        try await disk.storeRegions(regions, for: "page", kind: .translation, generation: 0)
        let data = try #require(try await disk.data(for: "page", kind: .translation))
        #expect(try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: data).map(\.region) == regions)
        #expect(try await disk.data(for: "page", kind: .translation, maximumBytes: data.count - 1) == nil)
        #expect(try await disk.contains("page", kind: .translation))
        #expect(try await disk.data(for: "page", kind: .translation, maximumBytes: data.count) != nil)
        try await disk.clear()
        #expect(try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: data).map(\.region) == regions)
    }

    @Test func failedStaticBindingFinalizesBeforeNextWrite() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let original = randomBytes(count: 256 * 1024)
        try await disk.store(original, for: "page", kind: .layout, generation: 0)
        try executeSQL("CREATE TRIGGER reject_write BEFORE INSERT ON cache BEGIN SELECT RAISE(ABORT,'fixture rejection'); END", root: root)
        var failed = false
        do {
            try await disk.store(Data(repeating: 17, count: original.count), for: "page", kind: .layout, generation: 0)
        } catch { failed = true }
        #expect(failed)
        #expect(try await disk.data(for: "page", kind: .layout) == original)
        try executeSQL("DROP TRIGGER reject_write", root: root)
        let replacement = randomBytes(count: original.count + 1024)
        try await disk.store(replacement, for: "page", kind: .layout, generation: 0)
        #expect(try await disk.data(for: "page", kind: .layout) == replacement)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.data(for: "page", kind: .layout) == replacement)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cache-buffer-lifetime-\(UUID().uuidString)")
    }

    private func randomBytes(count: Int) -> Data {
        // SplitMix64 keeps the raw fixture incompressible without random test state.
        var state: UInt64 = 0x718b_4f32_aed9_0465
        return Data((0..<count).map { _ in
            state &+= 0x9e37_79b9_7f4a_7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
            value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
            return UInt8(truncatingIfNeeded: value ^ (value >> 31))
        })
    }

    private func executeSQL(_ sql: String, root: URL) throws {
        var connection: OpaquePointer?
        let opened = sqlite3_open(root.appendingPathComponent("cache.sqlite").path, &connection)
        let handle = try #require(connection)
        defer { sqlite3_close(handle) }
        try #require(opened == SQLITE_OK)
        try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }
}
