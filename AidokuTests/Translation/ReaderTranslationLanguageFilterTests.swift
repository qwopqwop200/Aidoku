import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationLanguageFilterTests {
    @Test func languageNeutralSymbolsReachTheExistingMangaRequest() {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.modelTier = .manga
        settings.sourceLanguage = "ja"
        settings.translationSourceLanguages = ["ja"]
        let region = ReaderTranslationRegion(id: "symbols", rect: .zero, source: "『…?』")
        #expect(ReaderTranslationLanguageFilter.allowsModelSource(region.source, tier: .manga))
        #expect(ReaderTranslationLanguageFilter.apply([region], settings: settings).map(\.id) == [region.id])
    }

    @Test func mixedKoreanDoesNotCertifyCopiedJapaneseClause() {
        let source = "でも安心してこっちにも本を届けます"
        for mixed in ["「でも安心して、こっちにも 책을 보내 줄게」", "책을 보내 줄게. でも安心して、こっちにも"] {
            #expect(ReaderTranslationLanguageFilter.isUntranslatedJapaneseReply(source: source, translation: mixed, target: "ko"))
        }
        for allowed in ["안심해. 이쪽에도 책을 보내 줄게", "「でも安心して、こっちにも」라는 표현을 사용했어",
                        "スタジオジブリ의 새 책이야", "でも 안심해", "다나카(田中)가 보냈어"] {
            #expect(!ReaderTranslationLanguageFilter.isUntranslatedJapaneseReply(source: source, translation: allowed, target: "ko"))
        }
        #expect(!ReaderTranslationLanguageFilter.isUntranslatedJapaneseReply(
            source: "明日の会議は三時です", translation: "でも安心して、こっちにも 책을 보내 줄게", target: "ko"))
        #expect(!ReaderTranslationLanguageFilter.isUntranslatedJapaneseReply(source: source, translation: source, target: "ko"))
        let effect = RemoteTranslatedSegment(id: "effect", text: "でも安心して、こっちにも 쿵", isSFX: true)
        #expect(!ReaderTranslationLanguageFilter.isWrongLanguage(effect, source: source, target: "ko"))
    }

    @Test func wrongLanguageProviderReplyRetriesAndReplacesOldBatchCache() async throws {
        let fixture = LanguageFilterFixture()
        let source = "これからも毎日おいしいパンを作ってみんなに届けます"
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", sourceText: source)
        let configuration = fixture.settings.configuration
        let canonical = request.canonicalizedForTranslationSemantics().request
        let cache = try TranslationCache(configuration: .init(diskEnabled: false))
        let key = TranslationCacheKey(configuration: configuration, endpoint: try configuration.validatedEndpoint(), request: canonical)
        await cache.insert(canonical.segments.map { .init(id: $0.id, text: "「" + $0.text + "」") }, for: key)
        let client = WrongLanguageThenKoreanClient()
        let service = TranslationService(client: client, cache: cache)
        #expect(try await service.cachedResult(request, configuration: configuration) == nil)
        #expect(try await service.cachedTranslation(request, configuration: configuration) == nil)
        let result = try await service.translate(request, configuration: configuration)
        #expect(result.translations.first?.text == "앞으로도 매일 맛있는 빵을 만들어 모두에게 전하겠습니다")
        #expect(await client.calls == 2)
        #expect(try await service.cachedResult(request, configuration: configuration)?.translations == result.translations)
        _ = try await service.translate(request, configuration: configuration)
        #expect(await client.calls == 2)
    }

    @Test func fixedJapaneseKeepsSharedHanAndChineseAliasFiltersEnglish() {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        settings.sourceLanguage = "ja"
        settings.translationSourceLanguages = ["en"] // Inactive in fixed-source mode.
        #expect(ReaderTranslationLanguageFilter.apply(Self.mixed, settings: settings).map(\.id) == ["ja", "han"])
        settings.sourceLanguage = "zh-Hans"
        #expect(ReaderTranslationLanguageFilter.apply(Self.mixed, settings: settings).map(\.id) == ["zh", "han"])
        // An unclassifiable fixed source keeps the permissive language rule; the
        // manga recognizer also reads Latin-script text.
        settings.sourceLanguage = "az"
        #expect(ReaderTranslationLanguageFilter.apply(Self.mixed, settings: settings).map(\.id) == ["en", "ja", "zh", "han"])
        // Scripts the manga dictionary cannot spell stay excluded.
        #expect(!ReaderTranslationLanguageFilter.allowsModelSource("이미 한국어 문장입니다", tier: .manga))
        #expect(!ReaderTranslationLanguageFilter.allowsModelSource("Это русский текст", tier: .manga))
    }

    @Test func v2SourceRuleAdmitsSharedHanDialogueOnlyForHanLanguages() {
        var settings = LanguageFilterFixture().settings
        settings.targetLanguage = "ko"
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = ["ja"]
        // Short Han-only dialogue that NaturalLanguage cannot split between ja/zh.
        #expect(ReaderTranslationLanguageFilter.allowsV2Source("本当", settings: settings))
        #expect(ReaderTranslationLanguageFilter.allowsV2Source("！？", settings: settings))
        #expect(!ReaderTranslationLanguageFilter.allowsV2Source("이미 한국어", settings: settings))
        settings.sourceLanguage = "en"
        settings.translationSourceLanguages = []
        #expect(!ReaderTranslationLanguageFilter.allowsV2Source("本当", settings: settings))
    }

    @Test func v2SendsEnglishOnlyWhenEnglishOrAutoIsTheSource() {
        var settings = LanguageFilterFixture().settings
        settings.targetLanguage = "ko"
        let english = "Wait! I told you to stay behind the line, didn't I?"
        let blocks = [V2Block(id: 0, lines: [], bounds: CGRect(x: 0, y: 0, width: 10, height: 10), polygon: [], vertical: false,
                              readingOrder: 0, sourceText: english)]
        func sent(_ source: String, _ filter: [String]) -> Bool {
            settings.sourceLanguage = source
            settings.translationSourceLanguages = filter
            return ReaderTranslationV2Service.eligibleForTranslation(blocks, settings: settings) == [0]
        }
        #expect(sent("auto", []))
        #expect(sent("auto", ["en"]))
        #expect(sent("auto", ["en", "ja"]))
        #expect(sent("en", []))
        #expect(!sent("auto", ["ja"]))
        #expect(!sent("ja", []))
        #expect(!sent("zh-Hans", []))
        // Short unclassifiable Latin dialogue follows the recognizer, not a ja/zh-only rule.
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = []
        #expect(ReaderTranslationLanguageFilter.allowsV2Source("OK!", settings: settings))
        settings.targetLanguage = "en"
        #expect(!ReaderTranslationLanguageFilter.allowsV2Source(english, settings: settings))
    }

    @Test func v2SourceRuleKeepsTheSourceFilterInTheV2CacheIdentity() {
        var settings = LanguageFilterFixture().settings
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        settings.translationSourceLanguages = []
        let all = ReaderTranslationV2Service.cacheKey(page: "p", crop: unit, settings: settings)
        settings.translationSourceLanguages = ["ja"]
        let japanese = ReaderTranslationV2Service.cacheKey(page: "p", crop: unit, settings: settings)
        settings.translationSourceLanguages = ["ja", "zh"]
        let han = ReaderTranslationV2Service.cacheKey(page: "p", crop: unit, settings: settings)
        settings.translationSourceLanguages = ["en", "ja"]
        let latin = ReaderTranslationV2Service.cacheKey(page: "p", crop: unit, settings: settings)
        #expect(Set([all, japanese, han, latin]).count == 4)
        settings.translationSourceLanguages = ["zh", "ja"]
        #expect(ReaderTranslationV2Service.cacheKey(page: "p", crop: unit, settings: settings) == han)
    }

    @Test func filterPersistsAndRejectsInvalidSelectionsWithoutChangingSavedPreferences() throws {
        let fixture = LanguageFilterFixture()
        var settings = fixture.settings
        #expect(settings.translationSourceLanguages.isEmpty)
        // The V2 manga recognizer reads CJK and Latin-script text, not Vietnamese.
        settings.translationSourceLanguages = ["zh", "ja"]
        try settings.save(defaults: fixture.defaults)
        #expect(fixture.settings.translationSourceLanguages == ["ja", "zh"])
        #expect(fixture.settings.hasSameTranslation(as: settings))
        for invalid in [["xx"], ["ja", "ja"], ["ko"], ["ja", "vi"]] {
            settings.translationSourceLanguages = invalid
            #expect(throws: RemoteTranslationError.self) { try settings.save(defaults: fixture.defaults) }
            #expect(fixture.settings.translationSourceLanguages == ["ja", "zh"])
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
}

private actor LanguageFilterClient: RemoteTranslating {
    private(set) var requests: [RemoteTranslationRequest] = []
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        requests.append(request)
        return RemoteTranslationBatchResult(translations: request.segments.map { .init(id: $0.id, text: "translated-" + $0.id) },
                                            source: .network, providerRequestID: nil)
    }
}
@MainActor private final class LanguageFilterFixture {
    let suite = "language-filter-" + UUID().uuidString
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    var settings: ReaderTranslationSettings {
        ReaderTranslationSettings(defaults: defaults)
    }
    deinit {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

private actor WrongLanguageThenKoreanClient: RemoteTranslating {
    private(set) var calls = 0
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        calls += 1
        return .init(translations: request.segments.map {
            .init(id: $0.id, text: calls == 1 ? "「" + $0.text + "」" : "앞으로도 매일 맛있는 빵을 만들어 모두에게 전하겠습니다")
        }, source: .network, providerRequestID: nil)
    }
}
