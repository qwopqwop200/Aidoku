import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct MangaOCRDefaultsTests {
    @Test func freshInstallUsesMangaForBothStagesAndItsPreset() throws {
        let suite = "MangaOCRDefaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        #expect(settings.sourceLanguage == "auto")
        #expect(settings.targetLanguage == "ko")
        // The manga dictionary spells CJK and Latin-script text (no Hangul, Cyrillic or Vietnamese).
        #expect(settings.supportedOCRSourceLanguageCodes == AutomaticSourceLanguageDetector.supportedLanguageCodes.subtracting(["vi"]))
        #expect(settings.supportedOCRSourceLanguageCodes.isSuperset(of: ["ja", "zh", "zh-Hant", "en", "fr", "de", "es"]))
        #expect(!settings.supportedOCRSourceLanguageCodes.contains("ko"))
        #expect(NativeCoreMLDetector.modelResourceName == V2Models.detectorResourceName)
    }

    @Test func normalizationRestrictsOnlyPageSourceLanguages() throws {
        let suite = "MangaOCRSources.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.sourceLanguage = "vi"
        settings.translationSourceLanguages = ["en", "ja", "vi", "zh-Hans", "zh-Hant"]
        settings.mangaTitleSourceLanguages = ["en", "fr"]
        settings.normalizeOCRSourceLanguages()
        #expect(settings.sourceLanguage == "auto")
        #expect(settings.translationSourceLanguages == ["en", "ja", "zh", "zh-Hant"])
        #expect(settings.mangaTitleSourceLanguages == ["en", "fr"])
        settings.sourceLanguage = "vi"
        #expect(throws: RemoteTranslationError.self) { try settings.validate() }
        settings.sourceLanguage = "en"
        settings.normalizeOCRSourceLanguages()
        #expect(settings.sourceLanguage == "en")
    }

    @Test func mangaRestrictsOCRSourceWithoutRestrictingTargetsOrMetadata() throws {
        let suite = "MangaOCRLanguages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let inputs = ["こんにちは", "这是中文的测试。", "這是繁體中文的測試。", "愛",
                      "This is an English sentence about today's weather.", "안녕하세요", "Привет мир", "日本語 한국어"]
        let regions = inputs.enumerated().map { ReaderTranslationRegion(id: String($0.offset), rect: .zero, source: $0.element) }
        let admitted = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        #expect(admitted.map(\.id) == ["0", "1", "2", "3", "4"])
        var englishTarget = settings
        englishTarget.targetLanguage = "en"
        #expect(ReaderTranslationLanguageFilter.apply(regions, settings: englishTarget).map(\.id) == ["0", "1", "2", "3"])
        for kind in TitleTranslationKind.allCases {
            let metadata = TitleTranslation.effectiveSettings(settings, kind: kind)
            #expect(!metadata.usesOCRLanguagePolicy)
            #expect(ReaderTranslationLanguageFilter.apply([regions[4]], settings: metadata).count == 1)
            #expect(ReaderTranslationLanguageFilter.identity(settings: metadata) != ReaderTranslationLanguageFilter.identity(settings: settings))
        }
    }
}
