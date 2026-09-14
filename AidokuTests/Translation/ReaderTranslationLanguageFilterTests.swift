import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationLanguageFilterTests {
    @Test func correctedKanaEvidenceReusesRawOCRButRejectsOldFilteredSubset() async throws {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.sourceLanguage = "zh-Hant"
        let page = fixture.page.translationCacheKey
        let raw = [ReaderTranslationRegion(id: "dialogue",
            rect: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.2), source: "你・現在有什麼打算？")]
        let rawKey = ReaderTranslationCacheIdentity.ocr(page: page, settings: settings)
        try await fixture.disk.storeRegions(raw, for: rawKey, kind: .ocr, generation: 0)
        let oldKey = ReaderTranslationCacheIdentity.encoded([
            ReaderTranslationCacheIdentity.unfilteredTranslation(page: page, settings: settings),
            "source-filter-v1", "fixed", "zh-Hant"
        ])
        try await fixture.disk.storeRegions([], for: oldKey, kind: .translation, generation: 0)
        let reopened = ReaderTranslationPreloader(diskCache: ReaderTranslationDiskCache(directory: fixture.root),
            translator: { regions, _, _ in regions }, recognizer: { _, _ in
                Issue.record("Corrected language filtering must reuse the unfiltered OCR cache")
                return []
            })
        #expect(try await reopened.translate(fixture.page, settings: settings).map(\.id) == ["dialogue"])
        #expect(try await fixture.disk.regions(for: rawKey, kind: .ocr)?.map(\.id) == ["dialogue"])
    }

    @Test func mixedPageOnlySendsSelectedSourcesAndPublishesMatchingIDs() async throws {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.translationSourceLanguages = ["ja"]
        let client = LanguageFilterClient()
        let progress = LanguageFilterProgress()
        let service = ReaderTranslationService(client: client)
        let output = try await service.translate(regions: Self.mixed, settings: settings) { await progress.record($0) }
        #expect(output.map(\.id) == ["ja"])
        let requests = await client.requests
        let wireSegment = try #require(requests.first?.segments.first)
        #expect(output.first?.translation == "translated-" + wireSegment.id)
        #expect(requests.flatMap(\.segments).count == 1)
        #expect(requests.flatMap(\.segments).map(\.text) == [Self.mixed[1].source])
        #expect(await progress.snapshots.allSatisfy { $0.map(\.id) == ["ja"] })
        #expect(try ReaderTranslationService.requests(regions: Self.mixed, settings: settings).flatMap(\.segments).map(\.id) == ["ja"])
    }

    @Test func allExcludedPageCompletesWithoutAnAPIRequestOrOverlay() async throws {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.translationSourceLanguages = ["fr"]
        let client = LanguageFilterClient()
        #expect(try await ReaderTranslationService(client: client).translate(regions: Self.mixed, settings: settings).isEmpty)
        #expect(await client.requests.isEmpty)
        let preloader = ReaderTranslationPreloader(translator: { _, _, _ in
            Issue.record("An empty filtered page must not call the translator")
            return []
        }, recognizer: { _, _ in Self.mixed })
        #expect(try await preloader.translate(fixture.page, settings: settings).isEmpty)
    }

    @Test func fixedJapaneseKeepsSharedHanAndChineseAliasFiltersEnglish() {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.sourceLanguage = "ja"
        settings.translationSourceLanguages = ["en"] // Inactive in fixed-source mode.
        #expect(ReaderTranslationLanguageFilter.apply(Self.mixed, settings: settings).map(\.id) == ["ja", "han"])
        settings.sourceLanguage = "zh-Hans"
        #expect(ReaderTranslationLanguageFilter.apply(Self.mixed, settings: settings).map(\.id) == ["zh", "han"])
        settings.sourceLanguage = "az"
        #expect(ReaderTranslationLanguageFilter.apply(Self.mixed, settings: settings).map(\.id) == Self.mixed.map(\.id))
    }

    @Test func restartingWithExpandedFilterUsesUnfilteredOCRFromDisk() async throws {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.translationSourceLanguages = ["ja"]
        let preloader = ReaderTranslationPreloader(diskCache: fixture.disk, translator: { regions, _, _ in regions },
                                                   recognizer: { _, _ in Self.mixed })
        #expect(try await preloader.translate(fixture.page, settings: settings).map(\.id) == ["ja"])
        let rawKey = ReaderTranslationCacheIdentity.ocr(page: fixture.page.translationCacheKey, settings: settings)
        #expect(try await fixture.disk.regions(for: rawKey, kind: .ocr)?.map(\.id) == Self.mixed.map(\.id))
        preloader.cancel()
        settings.translationSourceLanguages = []
        let reopened = ReaderTranslationPreloader(diskCache: ReaderTranslationDiskCache(directory: fixture.root),
                                                  translator: { regions, _, _ in regions }, recognizer: { _, _ in
            Issue.record("Changing the language filter must reuse raw OCR")
            return []
        })
        #expect(try await reopened.translate(fixture.page, settings: settings).map(\.id) == Self.mixed.map(\.id))
    }

    @Test func legacyTranslationIsFilteredAfterRestartWithoutProcessingAgain() async throws {
        let fixture = LanguageFilterFixture()
        let originals = Self.mixed.map { var region = $0; region.translation = "saved-" + region.id; return region }
        // Cover both an old auto/all cache and old fixed Japanese (previously unfiltered).
        for source in ["auto", "ja"] {
            var settings = fixture.settings
            settings.sourceLanguage = source
            settings.translationSourceLanguages = ["ja"]
            let key = ReaderTranslationCacheIdentity.unfilteredTranslation(page: fixture.page.translationCacheKey, settings: settings)
            try await fixture.disk.storeRegions(originals, for: key, kind: .translation, generation: 0)
            let view = UIImageView(image: Self.image())
            let page = ReaderTranslationPage(imageView: view)
            page.sourcePage = fixture.page
            let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in
                Issue.record("Saved all-language results must not trigger OCR or API again")
                return []
            }, diskCache: ReaderTranslationDiskCache(directory: fixture.root))
            session.update(items: [.init(fixture.page)], visible: [page], context: "chapter")
            session.enable(settings: settings)
            try await waitUntil { page.hasCompletedTranslation(settings: settings) }
            #expect(page.regions.map(\.id) == (source == "auto" ? ["ja"] : ["ja", "han"]))
            #expect(page.regions.allSatisfy { $0.translation == "saved-" + $0.id })
            session.close()
        }
    }

    @Test func filteredSubsetNeverPoisonsAnExpandedOrAllLanguageCache() async throws {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.translationSourceLanguages = ["ja"]
        let key = ReaderTranslationCacheIdentity.translation(page: fixture.page.translationCacheKey, settings: settings)
        try await fixture.disk.storeRegions([Self.mixed[1]], for: key, kind: .translation, generation: 0)
        #expect(try await fixture.disk.translatedRegions(page: fixture.page.translationCacheKey, settings: settings)?.count == 1)
        settings.translationSourceLanguages = ["ja", "en"]
        #expect(try await fixture.disk.translatedRegions(page: fixture.page.translationCacheKey, settings: settings) == nil)
        settings.translationSourceLanguages = []
        #expect(try await fixture.disk.translatedRegions(page: fixture.page.translationCacheKey, settings: settings) == nil)
    }

    @Test func filterChangesInvalidatePixelsButKeepRawOCRAndIgnoreSelectionOrder() {
        let fixture = LanguageFilterFixture()
        let original = fixture.settings
        var filtered = original
        filtered.translationSourceLanguages = ["ja", "en"]
        #expect(!original.hasSameTranslation(as: filtered))
        #expect(ReaderTranslationCacheIdentity.ocr(page: "page", settings: original) ==
                ReaderTranslationCacheIdentity.ocr(page: "page", settings: filtered))
        #expect(renderKey(original) != renderKey(filtered))
        var reordered = filtered
        reordered.translationSourceLanguages.reverse()
        #expect(filtered.hasSameTranslation(as: reordered))
        #expect(renderKey(filtered) == renderKey(reordered))
        filtered.sourceLanguage = "ja"
        reordered = filtered
        reordered.translationSourceLanguages = ["fr"]
        #expect(filtered.hasSameTranslation(as: reordered))
    }

    @Test func filterChangeImmediatelyHidesOldBoxesAndReusesRawPageOCR() async throws {
        let fixture = LanguageFilterFixture()
        let view = UIImageView(image: Self.image())
        view.frame.size = CGSize(width: 320, height: 480)
        let calls = LanguageFilterProgress()
        let page = ReaderTranslationPage(imageView: view, recognize: { _, _ in
            await calls.record(Self.mixed)
            return Self.mixed
        }, translate: { regions, _ in regions.map { var region = $0; region.translation = "translated"; return region } })
        defer { page.reset() }
        var settings = fixture.settings
        _ = try await page.process(translate: true, settings: settings)
        #expect(!view.subviews.isEmpty)
        settings.translationSourceLanguages = ["ja"]
        page.applySettings(settings)
        #expect(view.subviews.isEmpty)
        #expect(page.regions.isEmpty)
        #expect(!page.hasCompletedTranslation(settings: settings))
        _ = try await page.process(translate: true, settings: settings)
        #expect(page.regions.map(\.id) == ["ja"])
        settings.translationSourceLanguages = []
        page.applySettings(settings)
        _ = try await page.process(translate: false, settings: settings, renderOverlay: false)
        #expect(page.regions.map(\.id) == Self.mixed.map(\.id))
        #expect(await calls.snapshots.count == 1)
    }

    @Test func filterPersistsAndRejectsInvalidSelectionsWithoutChangingSavedPreferences() throws {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        #expect(settings.translationSourceLanguages.isEmpty)
        settings.translationSourceLanguages = ["ja", "en"]
        try settings.save(defaults: fixture.defaults)
        #expect(fixture.settings.translationSourceLanguages == ["en", "ja"])
        #expect(fixture.settings.hasSameTranslation(as: settings))
        for invalid in [["xx"], ["ja", "ja"], ["ko"]] {
            settings.translationSourceLanguages = invalid
            #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: fixture.defaults) }
            #expect(fixture.settings.translationSourceLanguages == ["en", "ja"])
        }
    }

    @Test func languageFilterDoesNotReprobeProviderOrFilterConnectionTestText() async throws {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.translationSourceLanguages = ["ja"]
        let client = LanguageFilterClient()
        let validator = ReaderTranslationAPIValidator(client: client, onFailure: { _ in Issue.record("Probe unexpectedly failed") })
        try await validator.validateForActivation(settings)
        settings.translationSourceLanguages = ["fr"]
        validator.refresh(settings)
        try await validator.validateForActivation(settings)
        #expect(await client.requests.count == 1)
        #expect(await client.requests.first?.segments.first?.text == "Hello, world!")
    }

    nonisolated static let mixed: [ReaderTranslationRegion] = [
        ("en", "This English advertisement must be filtered out."), ("ja", "これは日本語のメニューです"),
        ("zh", "这是简体中文的广告页面"), ("han", "設定")
    ].enumerated().map { index, pair in
        ReaderTranslationRegion(id: pair.0, rect: CGRect(x: 0.1, y: 0.1 + Double(index) * 0.2, width: 0.7, height: 0.12), source: pair.1)
    }
    private func renderKey(_ settings: ReaderTranslationSettings) -> String {
        ReaderTranslationCacheIdentity.render(page: "page", settings: settings, imageSize: CGSize(width: 600, height: 900),
                                              viewport: CGSize(width: 320, height: 480), scale: 3, aspectFit: true,
                                              crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: false)
    }
    private static func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor LanguageFilterClient: RemoteTranslating {
    private(set) var requests: [RemoteTranslationRequest] = []
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        requests.append(request)
        return RemoteTranslationBatchResult(translations: request.segments.map { .init(id: $0.id, text: "translated-" + $0.id) },
                                            source: .network, providerRequestID: nil)
    }
}
private actor LanguageFilterProgress {
    private(set) var snapshots: [[ReaderTranslationRegion]] = []
    func record(_ regions: [ReaderTranslationRegion]) { snapshots.append(regions) }
}
@MainActor private final class LanguageFilterFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("language-filter-" + UUID().uuidString)
    let suite = "language-filter-" + UUID().uuidString
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    var settings: ReaderTranslationSettings { ReaderTranslationSettings(defaults: defaults) }
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    var page: Page { Page(sourceId: "filter-test", chapterId: "chapter", index: 0, imageURL: "https://example.invalid/page") }
    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
