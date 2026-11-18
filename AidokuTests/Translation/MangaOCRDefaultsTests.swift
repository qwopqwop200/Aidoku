import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct MangaOCRDefaultsTests {
    @Test func adoptedMangaThresholdMigratesOnlyLegacyDefaults() throws {
        let suite = "MangaOCRThreshold.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for (saved, expected) in [(0.50, 0.30), (0.75, 0.30), (0.45, 0.30), (0.30, 0.30), (0.4, 0.4), (0.6, 0.6)] {
            let value = ReaderOCRConfiguration(modelTier: .manga, confidenceThreshold: saved)
            defaults.set(try JSONEncoder().encode(value), forKey: ReaderTranslationSettings.keyPrefix + "ocr")
            #expect(ReaderTranslationSettings(defaults: defaults).ocr.confidenceThreshold == expected)
        }
        #expect(ReaderOCRConfiguration(modelTier: .small).confidenceThreshold == 0.50)
    }
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
        #expect(settings.supportedOCRSourceLanguageCodes == ["ja", "zh", "zh-Hant"])
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
        settings.sourceLanguage = "en"
        settings.translationSourceLanguages = ["en", "ja", "zh-Hans", "zh-Hant"]
        settings.mangaTitleSourceLanguages = ["en", "fr"]
        settings.modelTier = .manga
        #expect(settings.sourceLanguage == "auto")
        #expect(settings.translationSourceLanguages == ["ja", "zh", "zh-Hant"])
        #expect(settings.mangaTitleSourceLanguages == ["en", "fr"])
        #expect(settings.ocr.detectorMaximumSide == 1_120)
        #expect(settings.ocr.detectorPixelThreshold == 0.85)
        #expect(settings.ocr.detectorConfidenceThreshold == 0.25)
        settings.sourceLanguage = "en"
        #expect(throws: RemoteTranslationError.self) { try settings.validate() }
    }

    @Test func explicitSavedModelsRemainSelectableAfterInstallation() throws {
        let suite = "MangaOCRSaved.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = ReaderOCRConfiguration(modelTier: .small, detectorMaximumSide: 800, detectorPixelThreshold: 0.4)
        defaults.set(try JSONEncoder().encode(selected), forKey: ReaderTranslationSettings.keyPrefix + "ocr")
        defaults.set("en", forKey: ReaderTranslationSettings.keyPrefix + "sourceLanguage")
        let restored = ReaderTranslationSettings(defaults: defaults)
        #expect(restored.ocr == selected)
        #expect(restored.sourceLanguage == "en")
        defaults.set(try JSONEncoder().encode(ReaderOCRConfiguration()), forKey: ReaderTranslationSettings.keyPrefix + "ocr")
        defaults.set(["en", "ja"], forKey: ReaderTranslationSettings.keyPrefix + "translationSourceLanguages")
        let manga = ReaderTranslationSettings(defaults: defaults)
        #expect(manga.sourceLanguage == "auto")
        #expect(manga.translationSourceLanguages == ["ja"])
        defaults.set("zh", forKey: ReaderTranslationSettings.keyPrefix + "sourceLanguage")
        #expect(ReaderTranslationSettings(defaults: defaults).sourceLanguage == "zh-Hans")
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
        #expect(admitted.map(\.id) == ["0", "1", "2", "3"])
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
