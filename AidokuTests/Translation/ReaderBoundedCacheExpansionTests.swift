import Foundation
import Testing
@testable import Aidoku

struct ReaderBoundedCacheExpansionTests {
    @Test(arguments: [false, true])
    func acceptedLegacyAndCurrentBytesAreExact(legacy: Bool) throws {
        let raw = Data(repeating: 65, count: 200_000)
        let packed = legacy ? ReaderTranslationCacheCodec.packSharedBase(raw)
            : Data("ATZ2".utf8) + (try (raw as NSData).compressed(using: .zlib) as Data)
        #expect(try ReaderTranslationCacheCodec.unpack(packed, maximumBytes: raw.count) == raw)
        #expect(throws: (any Error).self) {
            try ReaderTranslationCacheCodec.unpack(packed, maximumBytes: raw.count - 1)
        }
    }

    @MainActor
    @Test func renderAssetReadRejectsAndRemovesOversizedCompressedEntryBeforeJSONDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let key = ReaderTranslationRenderCache.renderAssetStorageKey("oversized")
        let raw = Data(repeating: 65, count: ReaderTranslationRenderAsset.maximumEncodedBytes + 1)
        try await disk.store(raw, for: key, kind: .layout, generation: 0)
        #expect(try await disk.statistics().entries == 1)
        let cache = ReaderTranslationRenderCache(disk: disk, decodeAsset: { _ in
            Issue.record("Oversized entry reached JSON decoder")
            return nil
        })
        #expect(await cache.renderAsset(for: "oversized") == nil)
        #expect(try await disk.statistics().entries == 0)
        #expect(try await disk.data(for: key, kind: .layout) == nil)
    }

    @Test func oversizedExpansionAndPlainDataAreRejected() throws {
        let raw = Data(repeating: 65, count: 8 * 1024 * 1024)
        let packed = ReaderTranslationCacheCodec.pack(raw)
        #expect(packed.count < 64 * 1024)
        #expect(throws: (any Error).self) {
            try ReaderTranslationCacheCodec.unpack(packed, maximumBytes: 128 * 1024)
        }
        #expect(throws: (any Error).self) {
            try ReaderTranslationCacheCodec.unpack(Data([1, 2, 3]), maximumBytes: 2)
        }
        #expect(throws: (any Error).self) {
            try ReaderTranslationCacheCodec.unpack(Data("ATZ2invalid".utf8), maximumBytes: 1024)
        }
    }
}
