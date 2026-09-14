import Testing
import Foundation
@testable import Aidoku

@Suite(.serialized) @MainActor
struct TitleTranslationTests {
    @Test func switchesPersistIndependentlyWithoutChangingPageTranslation() throws {
        let suite = "title-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(!settings.translateMangaTitles && !settings.translateChapterTitles)
        let original = settings
        settings.translateMangaTitles = true
        settings.automaticallyTranslate = false
        try settings.autosave(defaults: defaults)
        let saved = ReaderTranslationSettings(defaults: defaults)
        #expect(saved.translateMangaTitles && !saved.translateChapterTitles)
        #expect(!saved.automaticallyTranslate)
        #expect(original.hasSameTranslation(as: saved))
        settings.translateMangaTitles = false
        settings.translateChapterTitles = true
        try settings.autosave(defaults: defaults)
        let reloaded = ReaderTranslationSettings(defaults: defaults)
        #expect(!reloaded.translateMangaTitles && reloaded.translateChapterTitles)
    }

    @Test func disabledKindDoesNotSendAndEnabledKindUsesTargetLanguage() async throws {
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "ja"
        settings.targetLanguage = "ko"
        settings.translateMangaTitles = false
        settings.translateChapterTitles = true
        settings.automaticallyTranslate = false
        let source = "これは日本語のタイトルです"
        #expect(await TitleTranslation.translate(source, kind: .manga, settings: settings, service: service, diskCache: fixture.disk) == source)
        #expect(await client.requests.isEmpty)
        #expect(await TitleTranslation.translate(source, kind: .chapter, settings: settings, service: service, diskCache: fixture.disk) == "일본어 제목")
        #expect(await client.requests.first?.targetLanguage == "ko")
        settings.translateChapterTitles = false
        #expect(await TitleTranslation.translate(source, kind: .chapter, settings: settings, service: service, diskCache: fixture.disk) == source)
        #expect(await client.requests.count == 1)
    }

    @Test func failureKeepsOriginal() async {
        let fixture = TitleCacheFixture()
        let service = ReaderTranslationService(client: TitleTestClient(fail: true))
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "ja"
        settings.translateMangaTitles = true
        let original = "これは日本語のタイトルです"
        #expect(await TitleTranslation.translate(original, kind: .manga, settings: settings, service: service, diskCache: fixture.disk) == original)
    }
    @Test func diskSurvivesServiceRestartAndClearRemovesTitles() async throws {
        let fixture = TitleCacheFixture()
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "ja"
        settings.translateMangaTitles = true
        let original = "これは日本語のタイトルです"
        let client = TitleTestClient()
        let first = await TitleTranslation.translate(original, kind: .manga, settings: settings,
            service: ReaderTranslationService(client: client), diskCache: fixture.disk)
        #expect(first == "일본어 제목")
        let offline = TitleTestClient(fail: true)
        let reopened = ReaderTranslationDiskCache(directory: fixture.root)
        let second = await TitleTranslation.translate(original, kind: .manga, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened)
        #expect(second == first)
        #expect(await offline.requests.isEmpty)
        settings.targetLanguage = "en"
        #expect(await TitleTranslation.translate(original, kind: .manga, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened) == original)
        #expect(await offline.requests.count == 1)
        try await reopened.clear()
        settings.targetLanguage = "ko"
        #expect(await TitleTranslation.translate(original, kind: .manga, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: reopened) == original)
        #expect(try await reopened.statistics().entries == 0)
    }

    @Test func titleIdentityTracksTranslationSettingsButNotAppearance() {
        var settings = ReaderTranslationSettings()
        let key = TitleTranslation.cacheKey("title", kind: .manga, settings: settings)
        settings.overlay.opacity = 0.5
        settings.translateMangaTitles.toggle()
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: settings) == key)
        settings.model += "-new"
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: settings) != key)
        #expect(TitleTranslation.cacheKey("other", kind: .manga, settings: settings) != key)
    }

}

private actor TitleTestClient: RemoteTranslating {
    let fail: Bool
    private(set) var requests: [RemoteTranslationRequest] = []
    init(fail: Bool = false) { self.fail = fail }
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        requests.append(request)
        if fail { throw URLError(.notConnectedToInternet) }
        return RemoteTranslationBatchResult(translations: request.segments.map { .init(id: $0.id, text: "일본어 제목") },
                                            source: .network, providerRequestID: nil)
    }
}

@MainActor private final class TitleCacheFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("title-cache-" + UUID().uuidString)
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    deinit { try? FileManager.default.removeItem(at: root) }
}
