import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationPageIdentityTests {
    @Test func hitomiRoutingRotationRestoresTranslationAfterReopeningDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = "f71c81e179c49d058275918fe1699f4427957c295d0ac933b3f36f6e0b6d5a79"
        let original = Page(sourceId: "multi.hitomi", chapterId: "chapter", index: 1,
            imageURL: "https://a1.gold-usergeneratedcontent.net/1790658001/2471/\(hash).avif")
        var reopened = original
        reopened.imageURL = "https://a2.gold-usergeneratedcontent.net/1790744401/2471/\(hash).avif"
        #expect(original.translationCacheKey == reopened.translationCacheKey)
        let settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let regions = [ReaderTranslationRegion(id: "saved", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                              source: "Original", translation: "저장한 번역")]
        let writer = ReaderTranslationDiskCache(directory: root)
        try await writer.storeRegions(regions,
            for: ReaderTranslationCacheIdentity.translation(page: original.translationCacheKey, settings: settings),
            kind: .translation, generation: 0)
        let reader = ReaderTranslationDiskCache(directory: root)
        #expect(try await reader.translatedRegions(page: reopened.translationCacheKey, settings: settings) == regions)
        reopened.context = ["variant": "different"]
        #expect(original.translationCacheKey != reopened.translationCacheKey)
        reopened = original
        reopened.imageURL = original.imageURL! + "?token=other"
        #expect(original.translationCacheKey != reopened.translationCacheKey)
        reopened = original
        reopened.imageURL = original.imageURL!.replacingOccurrences(of: ".avif", with: ".webp")
        #expect(original.translationCacheKey != reopened.translationCacheKey)
        reopened = original
        reopened.imageURL = original.imageURL!.replacingOccurrences(of: hash, with: "a" + hash.dropFirst())
        #expect(original.translationCacheKey != reopened.translationCacheKey)
    }

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
