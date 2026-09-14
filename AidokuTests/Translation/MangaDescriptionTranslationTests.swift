import Testing
import Foundation
@testable import Aidoku

@Suite(.serialized) @MainActor
struct MangaDescriptionTranslationTests {
    @Test func preferencesPersistIndependently() throws {
        let suite = "description-settings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(!settings.translateMangaDescriptions && settings.mangaDescriptionSourceLanguages.isEmpty)
        let page = settings
        settings.translateMangaDescriptions = true
        settings.mangaDescriptionSourceLanguages = ["en", "ja"]
        try settings.save(defaults: defaults)
        let saved = ReaderTranslationSettings(defaults: defaults)
        #expect(saved.translateMangaDescriptions)
        #expect(saved.mangaDescriptionSourceLanguages == ["en", "ja"])
        #expect(saved.hasSameTranslation(as: page))
        #expect(saved.mangaTitleSourceLanguages.isEmpty && saved.chapterTitleSourceLanguages.isEmpty)
        settings.mangaDescriptionSourceLanguages = ["invalid"]
        #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: defaults) }
    }

    @Test func descriptionFilterKeepsExcludedParagraphsAndReusesDisk() async throws {
        let fixture = DescriptionFixture()
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "ja"
        settings.translationSourceLanguages = ["ja"]
        settings.mangaTitleSourceLanguages = ["fr"]
        settings.chapterTitleSourceLanguages = ["ja"]
        settings.mangaDescriptionSourceLanguages = ["en"]
        settings.translateMangaDescriptions = true
        let english = "A young detective travels around the world to solve mysterious crimes."
        let japanese = "これは日本語の物語の説明です。少年は世界中を旅します。"
        let original = english + "\n\n" + japanese
        let client = DescriptionClient()
        let translated = await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: client), diskCache: fixture.disk)
        #expect(translated == "번역된 설명\n\n" + japanese)
        #expect(await client.requests.count == 1)
        let offline = DescriptionClient(fails: true)
        let reopened = ReaderTranslationDiskCache(directory: fixture.root)
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened) == translated)
        #expect(await offline.requests.isEmpty)
        settings.translateMangaDescriptions = false
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened) == original)
        #expect(await offline.requests.isEmpty)
        settings.translateMangaDescriptions = true
        settings.mangaDescriptionSourceLanguages = ["fr"]
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened) == original)
        #expect(await offline.requests.isEmpty)
    }

    @Test func failurePreservesFullDescriptionAndDoesNotCacheIt() async throws {
        let fixture = DescriptionFixture()
        var settings = ReaderTranslationSettings()
        settings.translateMangaDescriptions = true
        let original = "A young detective travels around the world.\n\nHe discovers a secret hidden in an ancient city."
        #expect(await MangaDescriptionTranslation.translate(original, settings: settings,
            service: ReaderTranslationService(client: DescriptionClient(fails: true)), diskCache: fixture.disk) == original)
        #expect(try await fixture.disk.statistics().entries == 0)
    }

    @Test func cacheIdentityUsesOnlyDescriptionFilterAndPreservesFormattingInstructions() {
        var settings = ReaderTranslationSettings()
        let key = TitleTranslation.cacheKey("synopsis", kind: .description, settings: settings)
        settings.sourceLanguage = "ja"
        settings.mangaTitleSourceLanguages = ["en"]
        settings.chapterTitleSourceLanguages = ["fr"]
        #expect(TitleTranslation.cacheKey("synopsis", kind: .description, settings: settings) == key)
        settings.mangaDescriptionSourceLanguages = ["en"]
        #expect(TitleTranslation.cacheKey("synopsis", kind: .description, settings: settings) != key)
        let effective = TitleTranslation.effectiveSettings(settings, kind: .description)
        #expect(effective.instructions.contains("Markdown"))
        #expect(TitleTranslation.effectiveSettings(effective, kind: .description) == effective)
    }

    @Test func longUnicodeDescriptionsAreNotTruncated() {
        let original = String(repeating: "長い物語の説明👨‍👩‍👧‍👦 and words\n", count: 2_000)
        let chunks = MangaDescriptionTranslation.chunks(original)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == original)
        #expect(chunks.allSatisfy { $0.utf8.count <= RemoteTranslationRequest.maximumSegmentTextBytes })
    }
}

private actor DescriptionClient: RemoteTranslating {
    let fails: Bool
    private(set) var requests: [RemoteTranslationRequest] = []
    init(fails: Bool = false) { self.fails = fails }
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        requests.append(request)
        if fails { throw URLError(.notConnectedToInternet) }
        return .init(translations: request.segments.map { .init(id: $0.id, text: "번역된 설명") }, source: .network, providerRequestID: nil)
    }
}

@MainActor private final class DescriptionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("description-cache-" + UUID().uuidString)
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    deinit { try? FileManager.default.removeItem(at: root) }
}
