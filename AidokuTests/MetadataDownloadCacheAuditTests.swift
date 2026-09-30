import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct MetadataDownloadCacheAuditTests {
    @Test func presentationIdentitySeparatesMetadataKindAndTextBoundaries() {
        let revision = UUID()
        let first = TitleTranslation.presentationIdentity(original: "aba", source: "ba", kind: .manga, revision: revision)
        // Both formerly concatenated to "ababa", so a reused row displayed stale text.
        let differentSplit = TitleTranslation.presentationIdentity(original: "abab", source: "a", kind: .manga, revision: revision)
        #expect(first != differentSplit)
        #expect(first != TitleTranslation.presentationIdentity(original: "aba", source: "ba", kind: .author, revision: revision))
        #expect(first == TitleTranslation.presentationIdentity(original: "aba", source: "ba", kind: .manga, revision: revision))
    }

    @Test func reopenedMetadataCacheRepairsWrongLanguageThenReusesResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-audit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "metadata-audit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.targetLanguage = "ko"
        settings.translateMangaTitles = true
        settings.mangaTitleSourceLanguages = []
        let original = "これはとても長い日本語の物語について書かれた新しい冒険のタイトルです"
        let wrong = original + "！"
        #expect(ReaderTranslationLanguageFilter.isUntranslatedJapaneseReply(source: original, translation: wrong, target: "ko"))
        let key = TitleTranslation.cacheKey(original, kind: .manga, settings: settings)
        let disk = ReaderTranslationDiskCache(directory: root)
        let generation = await disk.currentGeneration(settings: settings, kind: .metadata)
        try await disk.storeRegions([.init(id: "title", rect: .zero, source: original, translation: wrong)],
                                    for: key, kind: .metadata, generation: generation)
        let client = MetadataAuditClient()
        let result = await TitleTranslation.translate(original, kind: .manga, settings: settings,
            service: ReaderTranslationService(client: client), diskCache: ReaderTranslationDiskCache(directory: root))
        #expect(result == "새로운 모험의 제목")
        #expect(await client.calls == 1)
        let offline = MetadataAuditClient(fails: true)
        #expect(await TitleTranslation.translate(original, kind: .manga, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: ReaderTranslationDiskCache(directory: root)) == result)
        #expect(await offline.calls == 0)
    }

    @Test func uncertainCreatorNameRemainsValidCachedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("author-audit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.translateAuthors = true
        settings.authorSourceLanguages = []
        let original = "藤本タツキ"
        let disk = ReaderTranslationDiskCache(directory: root)
        let generation = await disk.currentGeneration(settings: settings, kind: .metadata)
        try await disk.storeRegions([.init(id: "title", rect: .zero, source: original, translation: original)],
            for: TitleTranslation.cacheKey(original, kind: .author, settings: settings), kind: .metadata, generation: generation)
        let offline = MetadataAuditClient(fails: true)
        #expect(await TitleTranslation.translate(original, kind: .author, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: ReaderTranslationDiskCache(directory: root)) == original)
        #expect(await offline.calls == 0)
    }
}

private actor MetadataAuditClient: RemoteTranslating {
    let fails: Bool
    private(set) var calls = 0
    init(fails: Bool = false) { self.fails = fails }
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        calls += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return .init(translations: request.segments.map { .init(id: $0.id, text: "새로운 모험의 제목") },
                     source: .network, providerRequestID: nil)
    }
}
