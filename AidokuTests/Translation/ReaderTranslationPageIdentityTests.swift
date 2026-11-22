import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationPageIdentityTests {
    private func page() -> Page {
        Page(sourceId: "identity-source", chapterId: "chapter", index: 1,
             imageURL: "https://example.invalid/image")
    }

    @Test func contextChangesCannotReusePreviousPageTranslation() {
        var first = page(), second = page()
        first.context = ["Authorization": "first-secret", "variant": "a"]
        second.context = ["Authorization": "second-secret", "variant": "a"]
        #expect(first.translationCacheKey != second.translationCacheKey)
        #expect(first.translationCacheKey != page().translationCacheKey)
        #expect(!first.translationCacheKey.contains("first-secret"))
    }

    @Test func contextDictionaryOrderIsCanonicalAndEmptyContextKeepsLegacyKey() throws {
        var first = page(), second = page()
        first.context = ["a": "1", "b": "2"]
        second.context = [:]
        second.context?["b"] = "2"
        second.context?["a"] = "1"
        #expect(first.translationCacheKey == second.translationCacheKey)
        first.context = [:]
        #expect(first.translationCacheKey == page().translationCacheKey)
        let originalParts = [first.sourceId, first.chapterId, String(first.index), first.imageURL ?? "",
                             first.zipURL ?? "", ImageProcessingSettingsKey.getProcessorSettingsKey()]
        let expected = SHA256.hash(data: try JSONEncoder().encode(originalParts)).map { String(format: "%02x", $0) }.joined()
        #expect(first.translationCacheKey == expected)
    }
}
