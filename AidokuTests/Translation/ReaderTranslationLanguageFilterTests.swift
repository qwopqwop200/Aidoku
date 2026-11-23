import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationLanguageFilterTests {
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
        #expect(!ReaderTranslationLanguageFilter.allowsModelSource("이미 한국어 문장입니다"))
        #expect(!ReaderTranslationLanguageFilter.allowsModelSource("Это русский текст"))
    }

    @Test func pagesTranslateOnlyJapaneseChineseAndEnglish() {
        let fixture = LanguageFilterFixture()
        // Retired source choices are ignored: the app always detects.
        fixture.defaults.set("fr", forKey: ReaderTranslationSettings.keyPrefix + "sourceLanguage")
        fixture.defaults.set(["fr"], forKey: ReaderTranslationSettings.keyPrefix + "translationSourceLanguages")
        let settings = fixture.settings
        #expect(settings.sourceLanguage == "auto" && settings.translationSourceLanguages.isEmpty)
        for text in ["Wait, where did everyone go?", "Hey, are you even listening to me?", "WHAT?!", "OK", "どうしてここにいるの？", "你到底在这里干什么？"] {
            #expect(ReaderTranslationLanguageFilter.allowsSource(text, settings: settings), "\(text)")
        }
        for text in ["¿Qué demonios estás haciendo aquí?", "Je ne vais pas abandonner maintenant !", "Was zum Teufel machst du hier?"] {
            #expect(!ReaderTranslationLanguageFilter.allowsSource(text, settings: settings), "\(text)")
        }
    }

    @Test func wrongLanguageProviderReplyRetriesAndReplacesOldBatchCache() async throws {
        let fixture = LanguageFilterFixture()
        let source = "これからも毎日おいしいパンを作ってみんなに届けます"
        let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", sourceText: source)
        let configuration = fixture.settings.configuration
        let canonical = request.canonicalizedForTranslationSemantics().request
        let cache = TranslationCache()
        let key = TranslationCacheKey(configuration: configuration, endpoint: try configuration.validatedEndpoint(), request: canonical)
        await cache.insert(canonical.segments.map { .init(id: $0.id, text: "「" + $0.text + "」") }, for: key)
        let client = WrongLanguageThenKoreanClient()
        let service = TranslationService(client: client, cache: cache)
        #expect(try await service.cachedResult(request, configuration: configuration) == nil)
        let result = try await service.translate(request, configuration: configuration)
        #expect(result.translations.first?.text == "앞으로도 매일 맛있는 빵을 만들어 모두에게 전하겠습니다")
        #expect(await client.calls == 2)
        #expect(try await service.cachedResult(request, configuration: configuration)?.translations == result.translations)
        _ = try await service.translate(request, configuration: configuration)
        #expect(await client.calls == 2)
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

    nonisolated static let mixed: [ReaderTranslationRegion] = [
        ("en", "This English advertisement must be filtered out."), ("ja", "これは日本語のメニューです"),
        ("zh", "这是简体中文的广告页面"), ("han", "設定")
    ].enumerated().map { index, pair in
        ReaderTranslationRegion(id: pair.0, rect: CGRect(x: 0.1, y: 0.1 + Double(index) * 0.2, width: 0.7, height: 0.12), source: pair.1)
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
