import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

struct ReaderLocalPageIdentityTests {
    private func page(_ url: URL, entry: String? = nil) -> Page {
        Page(sourceId: "local-test", chapterId: "chapter", imageURL: entry ?? url.absoluteString,
             zipURL: entry == nil ? nil : url.absoluteString)
    }

    @Test func samePathSameLengthReplacementCannotReuseOldTranslationKey() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first image".utf8).write(to: url, options: .atomic)
        let first = await ReaderLocalPageIdentity.prepare([page(url)])
        let unchanged = await ReaderLocalPageIdentity.prepare([page(url)])
        #expect(first[0].translationCacheKey == unchanged[0].translationCacheKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let regions = [ReaderTranslationRegion(id: "saved", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                              source: "Original", translation: "저장된 번역")]
        let writer = ReaderTranslationDiskCache(directory: directory)
        try await writer.storeRegions(regions,
            for: ReaderTranslationCacheIdentity.translation(page: first[0].translationCacheKey, settings: settings),
            kind: .translation, generation: 0)
        let reader = ReaderTranslationDiskCache(directory: directory)
        #expect(try await reader.translatedRegions(page: unchanged[0].translationCacheKey, settings: settings) == regions)
        try Data("other image".utf8).write(to: url, options: .atomic)
        let replacement = await ReaderLocalPageIdentity.prepare([page(url)])
        #expect(first[0].translationCacheKey != replacement[0].translationCacheKey)
        #expect(try await reader.translatedRegions(page: replacement[0].translationCacheKey, settings: settings) == nil)
        // The captured identity stays immutable; key lookups do not stat files.
        #expect(first[0].translationCacheKey == unchanged[0].translationCacheKey)
    }

    @Test func archiveReplacementInvalidatesEveryEntryButKeepsEntriesDistinct() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("archive one".utf8).write(to: url, options: .atomic)
        let pages = [page(url, entry: "1.png"), page(url, entry: "2.png")]
        let original = await ReaderLocalPageIdentity.prepare(pages)
        #expect(original[0].translationCacheKey != original[1].translationCacheKey)
        try Data("archive two".utf8).write(to: url, options: .atomic)
        let updated = await ReaderLocalPageIdentity.prepare(pages)
        #expect(original[0].translationCacheKey != updated[0].translationCacheKey)
        #expect(original[1].translationCacheKey != updated[1].translationCacheKey)
    }

    @Test func remoteAndAlreadyContentAddressedPagesKeepExistingIdentities() async {
        let remote = page(URL(string: "https://example.invalid/page.png")!)
        var raw = page(URL(fileURLWithPath: "/does-not-exist/temporary.png"))
        raw.imageContentIdentity = "encoded-content-digest"
        let prepared = await ReaderLocalPageIdentity.prepare([remote, raw])
        #expect(prepared[0].translationCacheKey == remote.translationCacheKey)
        #expect(prepared[1].translationCacheKey == raw.translationCacheKey)
    }

    @Test func missingLocalFileDoesNotHydratePreviouslyStoredTranslation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data("image".utf8).write(to: url)
        let existing = await ReaderLocalPageIdentity.prepare([page(url)])
        try FileManager.default.removeItem(at: url)
        let missing = await ReaderLocalPageIdentity.prepare([page(url)])
        #expect(existing[0].translationCacheKey != missing[0].translationCacheKey)
    }
}
