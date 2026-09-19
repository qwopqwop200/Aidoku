import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor
struct ReaderSessionCacheAdmissionTests {
    @Test func nonEvictingReplacementFitsWithoutDoubleCountingExistingBytes() throws {
        let cache = ReaderTranslationSessionCache()
        let source = String(repeating: "a", count: 3 * 1_024 * 1_024)
        let original = ReaderTranslationRegion(id: "line", rect: .zero, source: source, translation: "old")
        try cache.store([original], for: "page")
        let originalBytes = cache.bytes
        var updated = original
        updated.translation = "new"
        try cache.store([updated], for: "page", evict: false)
        #expect(cache.regions(for: "page")?.first?.translation == "new")
        #expect(cache.bytes == originalBytes)
    }

    @Test func nonEvictingReplacementWorksAtEntryLimitWithoutEvictingOtherPages() throws {
        let cache = ReaderTranslationSessionCache()
        for index in 0..<64 { try cache.store([], for: String(index)) }
        let region = ReaderTranslationRegion(id: "line", rect: .zero, source: "hello", translation: "translated")
        try cache.store([region], for: "0", evict: false)
        #expect(cache.regions(for: "0") == [region])
        #expect((0..<64).allSatisfy { cache.contains(String($0)) })
        try cache.store([], for: "overflow", evict: false)
        #expect(!cache.contains("overflow"))
    }

    @Test func rejectedReplacementPreservesExistingValue() throws {
        let cache = ReaderTranslationSessionCache()
        let original = ReaderTranslationRegion(id: "line", rect: .zero, source: "hello", translation: "saved")
        try cache.store([original], for: "page")
        let originalBytes = cache.bytes
        var oversized = original
        oversized.translation = String(repeating: "x", count: ReaderTranslationSessionCache.byteLimit)
        try cache.store([oversized], for: "page", evict: false)
        #expect(cache.regions(for: "page") == [original])
        #expect(cache.bytes == originalBytes)
    }
}
