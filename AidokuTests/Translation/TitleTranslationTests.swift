import Testing
import Foundation
import CoreGraphics
@testable import Aidoku

@Suite(.serialized) @MainActor
struct TitleTranslationTests {
    @Test func allMetadataReusesDiskCacheAfterOCRSettingsChangeWithoutNetwork() async throws {
        let fixture = TitleCacheFixture()
        var settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguage = "ko"
        settings.translateMangaTitles = true
        settings.translateChapterTitles = true
        settings.translateAuthors = true
        settings.translateMangaTags = true
        settings.translateSourceLabels = true
        settings.translateMangaDescriptions = true
        settings.mangaTitleSourceLanguages = []
        settings.chapterTitleSourceLanguages = []
        settings.authorSourceLanguages = []
        settings.mangaTagSourceLanguages = []
        settings.sourceLabelSourceLanguages = []
        settings.mangaDescriptionSourceLanguages = []
        try await fixture.disk.synchronizeSettings(settings)
        let online = TitleTestClient()
        for kind in TitleTranslationKind.allCases {
            #expect(await TitleTranslation.translate("The Lost Adventure \(kind.rawValue)", kind: kind, settings: settings,
                service: ReaderTranslationService(client: online), diskCache: fixture.disk) == "일본어 제목")
        }
        #expect(await online.requests.count == 6)
        settings.ocr.detectorPixelThreshold = 0.25
        settings.ocr.detectorConfidenceThreshold = 0.5
        settings.ocr.confidenceThreshold = 0.8
        settings.ocr.detectorMinimumBoxSide = 2
        let reopened = ReaderTranslationDiskCache(directory: fixture.root)
        try await reopened.synchronizeSettings(settings)
        let offline = TitleTestClient(fail: true)
        for kind in TitleTranslationKind.allCases {
            #expect(await TitleTranslation.translate("The Lost Adventure \(kind.rawValue)", kind: kind, settings: settings,
                service: ReaderTranslationService(client: offline), diskCache: reopened) == "일본어 제목")
        }
        #expect(await offline.requests.isEmpty)
        #expect(try await reopened.statistics().entries == 6)
    }

    @Test func metadataTranslatesWithoutAnImageWhenPageAttachmentsAreEnabled() async throws {
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        var settings = ReaderTranslationSettings()
        settings.includePageImage = true
        settings.targetLanguage = "ko"
        settings.translateMangaTitles = true
        settings.translateChapterTitles = true
        settings.translateAuthors = true
        settings.translateMangaTags = true
        settings.translateSourceLabels = true
        settings.translateMangaDescriptions = true
        settings.mangaTitleSourceLanguages = []
        settings.chapterTitleSourceLanguages = []
        settings.authorSourceLanguages = []
        settings.mangaTagSourceLanguages = []
        settings.sourceLabelSourceLanguages = []
        settings.mangaDescriptionSourceLanguages = []

        for kind: TitleTranslationKind in [.manga, .chapter, .author, .tag, .sourceLabel, .description] {
            let original = "The Lost Adventure \(kind.rawValue)"
            let result = await TitleTranslation.translate(original, kind: kind, settings: settings,
                service: service, diskCache: fixture.disk)
            #expect(result == "일본어 제목")
        }
        let menu = await SourceMenuTranslation.translate(["School Life"], settings: settings, kind: .tag,
            service: service, diskCache: fixture.disk)
        #expect(menu["School Life"] == "일본어 제목")
        let synopsis = await MangaDescriptionTranslation.translate("A detective travels.\n\nAn adventure begins.",
            settings: settings, service: service, diskCache: fixture.disk)
        #expect(synopsis == "일본어 제목\n\n일본어 제목")
        let requests = await client.requests
        #expect(requests.count == 9)
        #expect(requests.allSatisfy { $0.imageJPEG == nil && $0.preparedImageDataURL == nil })
        #expect(settings.includePageImage)
        // A reader page must still require its image when the option is enabled.
        await #expect(throws: RemoteTranslationError.self) {
            _ = try await service.translate(regions: [.init(id: "page", rect: .zero, source: "これは日本語です")],
                settings: settings)
        }
        #expect(await client.requests.count == 9)
    }

    @Test func cachedMetadataSurvivesOtherItemsFailingOffline() async {
        let fixture = TitleCacheFixture()
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.translateMangaTitles = true
        settings.translateChapterTitles = true
        settings.translateAuthors = true
        settings.translateMangaTags = true
        settings.translateSourceLabels = true
        settings.mangaTitleSourceLanguages = []
        settings.chapterTitleSourceLanguages = []
        settings.authorSourceLanguages = []
        settings.mangaTagSourceLanguages = []
        settings.sourceLabelSourceLanguages = []
        let online = ReaderTranslationService(client: TitleTestClient())
        let offline = TitleTestClient(fail: true)
        let failingService = ReaderTranslationService(client: offline)
        for kind: TitleTranslationKind in [.manga, .chapter, .author, .tag, .sourceLabel] {
            let original = "The Lost Adventure"
            #expect(await TitleTranslation.translate(original, kind: kind, settings: settings,
                service: online, diskCache: fixture.disk) == "일본어 제목")
            let result = await SourceMenuTranslation.translate(["A Missing Story", original], settings: settings, kind: kind,
                service: failingService, diskCache: ReaderTranslationDiskCache(directory: fixture.root))
            #expect(result[original] == "일본어 제목")
            #expect(result["A Missing Story"] == "A Missing Story")
        }
        #expect(await offline.requests.count == 5)
    }

    @Test func tagsPersistAndReuseCacheAcrossSourceIndependentRequests() async throws {
        let suite = "tag-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        let page = settings
        settings.translateMangaTags = true
        settings.mangaTagSourceLanguages = ["en"]
        try settings.autosave(defaults: defaults)
        let saved = ReaderTranslationSettings(defaults: defaults)
        #expect(saved.translateMangaTags && saved.mangaTagSourceLanguages == ["en"])
        #expect(saved.hasSameTranslation(as: page))
        settings.mangaTagSourceLanguages = []
        settings.targetLanguage = "ko"
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let text = "School Life"
        _ = await TitleTranslation.translate(text, kind: .tag, settings: settings,
            service: ReaderTranslationService(client: client), diskCache: fixture.disk)
        let offline = TitleTestClient(fail: true)
        let result = await TitleTranslation.translate(text, kind: .tag, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: ReaderTranslationDiskCache(directory: fixture.root))
        #expect(result == "일본어 제목")
        #expect(await offline.requests.isEmpty)
        settings.translateMangaTags = false
        #expect(await TitleTranslation.translate(text, kind: .tag, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: fixture.disk) == text)
    }

    @Test func targetLanguageSkipsNetworkButMixedAndRomanizedTextRemainEligible() async throws {
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.translateMangaTitles = true
        settings.mangaTitleSourceLanguages = []
        let korean = "골목길의 수녀님 1–9"
        #expect(await TitleTranslation.translate(korean, kind: .manga, settings: settings,
            service: service, diskCache: fixture.disk) == korean)
        #expect(await client.requests.isEmpty)
        for text in ["일본어 제목: 路地裏のシスター", "한국어와 English", "Isekai Majutsushi", "School Life"] {
            #expect(!ReaderTranslationLanguageFilter.isAlreadyTargetLanguage(text, target: "ko"))
            _ = await TitleTranslation.translate(text, kind: .manga, settings: settings,
                service: service, diskCache: fixture.disk)
        }
        #expect(await client.requests.count == 4)
        #expect(!ReaderTranslationLanguageFilter.isAlreadyTargetLanguage("Isekai Majutsushi", target: "en"))
        #expect(!ReaderTranslationLanguageFilter.isAlreadyTargetLanguage("日本語 English", target: "ja"))
        #expect(ReaderTranslationLanguageFilter.isAlreadyTargetLanguage("これは日本語です", target: "ja"))
        #expect(try ReaderTranslationService.requests(regions: [.init(id: "ko", rect: .zero, source: korean)], settings: settings).isEmpty)
    }

    @Test func screenshotEnglishTitleTranslatesWithEnglishFilter() async {
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        var settings = ReaderTranslationSettings()
        settings.translateMangaTitles = true
        settings.targetLanguage = "ko"
        settings.mangaTitleSourceLanguages = []
        let result = await TitleTranslation.translate("CycloneAction Batch 11", kind: .manga, settings: settings,
            service: ReaderTranslationService(client: client), diskCache: fixture.disk)
        #expect(result == "일본어 제목")
        #expect(await client.requests.count == 1)
    }

    @Test func sourceLabelsHaveIndependentToggleAndCacheIdentity() async throws {
        let suite = "source-label-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.targetLanguage = "ko"
        settings.mangaTitleSourceLanguages = ["ja"]
        settings.translationSourceLanguages = ["ja"]
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        #expect(await TitleTranslation.translate("Popular Today", kind: .sourceLabel, settings: settings,
            service: service, diskCache: fixture.disk) == "Popular Today")
        #expect(await client.requests.isEmpty)
        settings.translateSourceLabels = true
        try settings.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).translateSourceLabels)
        #expect(!ReaderTranslationSettings(defaults: defaults).translateMangaTitles)
        #expect(await TitleTranslation.translate("Popular Today", kind: .sourceLabel, settings: settings,
            service: service, diskCache: fixture.disk) == "일본어 제목")
        let offline = TitleTestClient(fail: true)
        #expect(await TitleTranslation.translate("Popular Today", kind: .sourceLabel, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: fixture.disk) == "일본어 제목")
        #expect(await offline.requests.isEmpty)
        let effective = TitleTranslation.effectiveSettings(settings, kind: .manga)
        #expect(effective.configuration.instructions.contains("including English words"))
        #expect(TitleTranslation.effectiveSettings(effective, kind: .manga) == effective)
    }

    @Test func sourceLabelLanguageFilterPersistsAndDoesNotReuseExcludedCache() async throws {
        let suite = "source-label-filter-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(settings.sourceLabelSourceLanguages.isEmpty)
        settings.translateSourceLabels = true
        settings.targetLanguage = "ko"
        let page = settings
        let mangaKey = TitleTranslation.cacheKey("Popular Today", kind: .manga, settings: settings)
        settings.sourceLabelSourceLanguages = ["en"]
        try settings.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).sourceLabelSourceLanguages == ["en"])
        #expect(settings.hasSameTranslation(as: page))
        #expect(TitleTranslation.cacheKey("Popular Today", kind: .manga, settings: settings) == mangaKey)
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        #expect(await TitleTranslation.translate("Popular Today", kind: .sourceLabel, settings: settings,
            service: service, diskCache: fixture.disk) == "일본어 제목")
        settings.sourceLabelSourceLanguages = ["ja"]
        #expect(await TitleTranslation.translate("Popular Today", kind: .sourceLabel, settings: settings,
            service: service, diskCache: fixture.disk) == "Popular Today")
        #expect(await client.requests.count == 1)
        settings.sourceLabelSourceLanguages = ["invalid"]
        #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: defaults) }
        #expect(ReaderTranslationSettings(defaults: defaults).sourceLabelSourceLanguages == ["en"])
    }

    @Test func authorsHaveIndependentSettingsAndPersistentCache() async throws {
        let suite = "author-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.targetLanguage = "ko"
        let page = settings
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        #expect(await TitleTranslation.translate("ogami kazuki", kind: .author, settings: settings,
            service: service, diskCache: fixture.disk) == "ogami kazuki")
        #expect(await client.requests.isEmpty)
        settings.translateAuthors = true
        settings.authorSourceLanguages = ["en", "ja"]
        try settings.autosave(defaults: defaults)
        let saved = ReaderTranslationSettings(defaults: defaults)
        #expect(saved.translateAuthors && saved.authorSourceLanguages == ["en", "ja"])
        #expect(saved.hasSameTranslation(as: page))
        settings.authorSourceLanguages = []
        #expect(await TitleTranslation.translate("ogami kazuki", kind: .author, settings: settings,
            service: service, diskCache: fixture.disk) == "일본어 제목")
        let offline = TitleTestClient(fail: true)
        #expect(await TitleTranslation.translate("ogami kazuki", kind: .author, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: ReaderTranslationDiskCache(directory: fixture.root)) == "일본어 제목")
        #expect(await offline.requests.isEmpty)
        #expect(TitleTranslation.effectiveSettings(settings, kind: .author).configuration.instructions.contains("phonetic transliteration"))
        settings.authorSourceLanguages = ["invalid"]
        #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: defaults) }
    }

    @Test func chapterLanguageNamesUseAppLocaleWithoutChangingGroupNames() {
        let korean = Locale(identifier: "ko")
        #expect(ChapterLanguageDisplay.localized("japanese", locale: korean) == "일본어")
        #expect(ChapterLanguageDisplay.localized("ja", locale: korean) == "일본어")
        #expect(ChapterLanguageDisplay.localized("Japanese", acceptsCode: false, locale: korean) == "일본어")
        #expect(ChapterLanguageDisplay.localized("English", acceptsCode: false, locale: korean) == "영어")
        #expect(ChapterLanguageDisplay.localized("en", acceptsCode: false, locale: korean) == "en")
        #expect(ChapterLanguageDisplay.localized("Japanese Scan Team", acceptsCode: false, locale: korean) == "Japanese Scan Team")
        #expect(ChapterLanguageDisplay.localized("japanese", locale: Locale(identifier: "en")) == "Japanese")
    }

    @Test func nativeSortMenuPreloadsUniqueLabelsAndSharesSourceLabelToggle() async {
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        var settings = ReaderTranslationSettings()
        settings.translateSourceLabels = true
        settings.sourceLabelSourceLanguages = []
        settings.targetLanguage = "ko"
        let options = ["人気", "タイトル", "更新順", "評価", "人気"]
        let translated = await SourceMenuTranslation.translate(options, settings: settings, service: service, diskCache: fixture.disk)
        #expect(translated.count == 4)
        #expect(translated["タイトル"] == "일본어 제목")
        #expect(await client.requests.count == 4)
        #expect(options == ["人気", "タイトル", "更新順", "評価", "人気"])
        settings.translateSourceLabels = false
        #expect(await SourceMenuTranslation.translate(options, settings: settings, service: service, diskCache: fixture.disk).isEmpty)
        #expect(await client.requests.count == 4)
    }

    @Test func largeFilterOptionsNeverReachTranslationButHeadingDoes() async {
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        var settings = ReaderTranslationSettings()
        settings.translateSourceLabels = true
        settings.sourceLabelSourceLanguages = []
        settings.targetLanguage = "ko"
        let options = (0..<1000).map { "Tag \($0)" }
        let labels = SourceMenuTranslation.labelsToTranslate(options: options, title: "Tags")
        #expect(labels == ["Tags"])
        _ = await SourceMenuTranslation.translate(labels, settings: settings, service: service, diskCache: fixture.disk)
        #expect(await client.requests.flatMap(\.segments).map(\.text) == ["Tags"])
        #expect(!SourceMenuTranslation.translatesOptions(count: options.count))
        #expect(SourceMenuTranslation.labelsToTranslate(options: options).isEmpty)
        #expect(SourceMenuTranslation.labelsToTranslate(options: Array(options.prefix(100))).count == 100)
        #expect(SourceMenuTranslation.labelsToTranslate(options: Array(options.prefix(101))).isEmpty)
    }

    @Test func largeFilterTranslationRequiresExplicitOptInAndPersists() throws {
        let suite = "large-filter-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(!settings.translateLargeFilterOptions)
        let options = (0..<101).map { "Option \($0)" }
        #expect(SourceMenuTranslation.labelsToTranslate(options: options, title: "Tags",
            includeLargeLists: settings.translateLargeFilterOptions) == ["Tags"])
        settings.translateLargeFilterOptions = true
        try settings.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).translateLargeFilterOptions)
        #expect(SourceMenuTranslation.labelsToTranslate(options: options,
            includeLargeLists: settings.translateLargeFilterOptions) == options)
        #expect(!settings.translateSourceLabels)
        settings.translateLargeFilterOptions = false
        try settings.autosave(defaults: defaults)
        #expect(!ReaderTranslationSettings(defaults: defaults).translateLargeFilterOptions)
    }

    @Test func tagFilterOptionsUseTagSwitchFilterAndCacheRatherThanSourceLabels() async {
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.translateSourceLabels = true
        settings.translateMangaTags = false
        #expect(await SourceMenuTranslation.translate(["School Life"], settings: settings, kind: .tag,
            service: service, diskCache: fixture.disk).isEmpty)
        #expect(await client.requests.isEmpty)
        settings.translateSourceLabels = false
        settings.translateMangaTags = true
        settings.mangaTagSourceLanguages = []
        #expect(await SourceMenuTranslation.translate(["School Life"], settings: settings, kind: .tag,
            service: service, diskCache: fixture.disk)["School Life"] == "일본어 제목")
        let offline = TitleTestClient(fail: true)
        #expect(await TitleTranslation.translate("School Life", kind: .tag, settings: settings,
            service: ReaderTranslationService(client: offline), diskCache: fixture.disk) == "일본어 제목")
        #expect(await offline.requests.isEmpty)
        settings.mangaTagSourceLanguages = ["ja"]
        #expect(await SourceMenuTranslation.translate(["School Life"], settings: settings, kind: .tag,
            service: service, diskCache: fixture.disk)["School Life"] == "School Life")
        #expect(await client.requests.count == 1)
    }

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

    @Test func titleFiltersPersistAndRemainOutsidePageIdentity() throws {
        let suite = "title-language-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(settings.mangaTitleSourceLanguages.isEmpty && settings.chapterTitleSourceLanguages.isEmpty)
        settings.sourceLanguage = "ja"
        let pageSettings = settings
        settings.mangaTitleSourceLanguages = ["fr", "en"]
        settings.chapterTitleSourceLanguages = ["en"]
        try settings.save(defaults: defaults)
        let saved = ReaderTranslationSettings(defaults: defaults)
        #expect(saved.mangaTitleSourceLanguages == ["en", "fr"])
        #expect(saved.chapterTitleSourceLanguages == ["en"])
        #expect(saved.sourceLanguage == "ja")
        #expect(saved.hasSameTranslation(as: pageSettings))
        settings.chapterTitleSourceLanguages = ["invalid"]
        #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: defaults) }
        #expect(ReaderTranslationSettings(defaults: defaults).chapterTitleSourceLanguages == ["en"])
    }

    @Test func pageJapaneseMangaAllAndChapterEnglishAreIndependent() async throws {
        let fixture = TitleCacheFixture()
        let client = TitleTestClient()
        let service = ReaderTranslationService(client: client)
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "ja"
        settings.translationSourceLanguages = ["ja"]
        settings.mangaTitleSourceLanguages = []
        settings.chapterTitleSourceLanguages = ["en"]
        settings.translateMangaTitles = true
        settings.translateChapterTitles = true
        let english = "The mysterious adventures of a young detective"
        let japanese = "これは日本語のタイトルです"
        let page = try await service.translate(regions: [.init(id: "page", rect: .zero, source: english)], settings: settings)
        #expect(page.isEmpty)
        #expect(await client.requests.isEmpty)
        #expect(await TitleTranslation.translate(english, kind: .manga, settings: settings,
            service: service, diskCache: fixture.disk) == "일본어 제목")
        #expect(await TitleTranslation.translate(japanese, kind: .manga, settings: settings,
            service: service, diskCache: fixture.disk) == "일본어 제목")
        #expect(await TitleTranslation.translate(english, kind: .chapter, settings: settings,
            service: service, diskCache: fixture.disk) == "일본어 제목")
        let beforeExcluded = await client.requests.count
        #expect(await TitleTranslation.translate(japanese, kind: .chapter, settings: settings,
            service: service, diskCache: fixture.disk) == japanese)
        #expect(await client.requests.count == beforeExcluded)
        // A previously cached translation must not bypass a narrower title filter.
        settings.mangaTitleSourceLanguages = ["en"]
        #expect(await TitleTranslation.translate(japanese, kind: .manga, settings: settings,
            service: service, diskCache: fixture.disk) == japanese)
        #expect(await client.requests.count == beforeExcluded)
    }

    @Test func eachTitleCacheIgnoresOtherFiltersButTracksItsOwn() {
        var settings = ReaderTranslationSettings()
        let mangaKey = TitleTranslation.cacheKey("title", kind: .manga, settings: settings)
        let chapterKey = TitleTranslation.cacheKey("title", kind: .chapter, settings: settings)
        settings.sourceLanguage = "ja"
        settings.translationSourceLanguages = ["ja"]
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: settings) == mangaKey)
        #expect(TitleTranslation.cacheKey("title", kind: .chapter, settings: settings) == chapterKey)
        settings.chapterTitleSourceLanguages = ["en"]
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: settings) == mangaKey)
        #expect(TitleTranslation.cacheKey("title", kind: .chapter, settings: settings) != chapterKey)
        settings.mangaTitleSourceLanguages = ["ja"]
        #expect(TitleTranslation.cacheKey("title", kind: .manga, settings: settings) != mangaKey)
    }

    @Test func titlesAndPagesRunConcurrentlyWithinSharedLimit() async {
        let fixture = TitleCacheFixture()
        let client = TitleConcurrencyClient()
        let service = ReaderTranslationService(client: client)
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = []
        settings.mangaTitleSourceLanguages = []
        settings.chapterTitleSourceLanguages = []
        settings.translateMangaTitles = true
        settings.translateChapterTitles = true
        settings.maximumConcurrentRequests = 2
        let configuration = settings
        let disk = fixture.disk
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let source = "This is a unique story about a detective number \(index)"
                    if index == 0 {
                        _ = try? await service.translate(regions: [.init(id: "page", rect: .zero, source: source)], settings: configuration)
                    } else {
                        _ = await TitleTranslation.translate(source, kind: index.isMultiple(of: 2) ? .manga : .chapter,
                            settings: configuration, service: service, diskCache: disk)
                    }
                }
            }
        }
        #expect(await client.completed == 6)
        #expect(await client.peak == 2)
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

private actor TitleConcurrencyClient: RemoteTranslating {
    private var active = 0
    private(set) var peak = 0
    private(set) var completed = 0
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(40))
        completed += 1
        return RemoteTranslationBatchResult(translations: request.segments.map { .init(id: $0.id, text: "번역된 제목") },
                                            source: .network, providerRequestID: nil)
    }
}
