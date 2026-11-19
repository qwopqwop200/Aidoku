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
        #expect(settings.modelTier == .manga)
        #expect(settings.ocr == ReaderOCRConfiguration(modelTier: .manga))
        #expect(settings.ocr.detectorMaximumSide == 1_120)
        #expect(settings.ocr.recognizerMaximumWidth == 2_400)
        #expect(settings.ocr.confidenceThreshold == 0.30)
        #expect(settings.ocr.detectorPostprocessConfiguration == .manga)
        #expect(settings.sourceLanguage == "auto")
        #expect(settings.targetLanguage == "ko")
        // The manga dictionary spells CJK and Latin-script text (no Hangul, Cyrillic or Vietnamese).
        #expect(settings.supportedOCRSourceLanguageCodes == AutomaticSourceLanguageDetector.supportedLanguageCodes.subtracting(["vi"]))
        #expect(settings.supportedOCRSourceLanguageCodes.isSuperset(of: ["ja", "zh", "zh-Hant", "en", "fr", "de", "es"]))
        #expect(!settings.supportedOCRSourceLanguageCodes.contains("ko"))
        let profile = NativeCoreMLOCRModelProfile.profile(for: settings.modelTier)
        #expect(NativeCoreMLDetector.modelResourceName == profile.detectorResourceName)
        #expect(NativeCoreMLRecognizer.modelResourceName == profile.recognizerResourceName)
        #expect(NativeCoreMLRecognizer.dictionaryResourceName == profile.dictionaryResourceName)
    }

    @Test func modelSelectionNormalizesOnlyPageSourceLanguages() throws {
        let suite = "MangaOCRSources.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.modelTier = .medium
        settings.sourceLanguage = "vi"
        settings.translationSourceLanguages = ["en", "ja", "vi", "zh-Hans", "zh-Hant"]
        settings.mangaTitleSourceLanguages = ["en", "fr"]
        settings.modelTier = .manga
        #expect(settings.sourceLanguage == "auto")
        #expect(settings.translationSourceLanguages == ["en", "ja", "zh", "zh-Hant"])
        #expect(settings.mangaTitleSourceLanguages == ["en", "fr"])
        #expect(settings.ocr.detectorMaximumSide == 1_120)
        #expect(settings.ocr.detectorPixelThreshold == 0.85)
        #expect(settings.ocr.detectorConfidenceThreshold == 0.25)
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
