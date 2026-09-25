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

    @Test func base64PayloadChangesInvalidatePageTranslationAndSplitOverrideRemainsStable() {
        var first = page(), second = page()
        first.imageURL = nil
        second.imageURL = nil
        first.base64 = Data("first-image".utf8).base64EncodedString()
        second.base64 = Data("second-image".utf8).base64EncodedString()
        #expect(first.translationCacheKey != second.translationCacheKey)
        second.base64 = first.base64
        #expect(first.translationCacheKey == second.translationCacheKey)
        second.translationOriginalKey = "original-full-page"
        #expect(second.translationCacheKey == "original-full-page")
    }
    @Test func base64DigestIsStoredAcrossCopiesAndRefreshedOnlyOnAssignment() {
        let initial = Page(sourceId: "source", chapterId: "chapter", base64: "aGVsbG8=")
        #expect(initial.$base64 == ReaderImageContentIdentity.base64Key("aGVsbG8=", processorSettingsKey: ""))
        var copy = initial
        #expect(copy == initial)
        #expect(copy.$base64 == initial.$base64)
        let originalKey = initial.translationCacheKey
        for _ in 0..<100 { #expect(initial.translationCacheKey == originalKey) }
        copy.base64 = "d29ybGQ="
        #expect(copy.$base64 != initial.$base64)
        #expect(copy.translationCacheKey != originalKey)
        #expect(initial.base64 == "aGVsbG8=")
        copy.base64 = nil
        #expect(copy.$base64 == nil)
        #expect(Page(sourceId: "source", chapterId: "chapter").base64 == nil)
    }

}
