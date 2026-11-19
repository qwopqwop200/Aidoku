// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Testing
@testable import Aidoku

@Suite("Automatic translation source-language detection")
struct AutomaticSourceLanguageDetectorTests {
    @Test
    func scriptEvidenceHandlesShortChineseAndJapaneseText() {
        #expect(AutomaticSourceLanguageDetector.detect("这") == "zh")
        #expect(AutomaticSourceLanguageDetector.detect("這") == "zh-Hant")
        #expect(AutomaticSourceLanguageDetector.detect("次へ") == "ja")
        #expect(AutomaticSourceLanguageDetector.detect("다음") == nil)
        #expect(AutomaticSourceLanguageDetector.detect("ー", sourceHint: "ja") == nil)
    }

    @Test
    func fixedJapaneseOCRSourceFiltersOtherLanguages() {
        for text in ["次へ", "設定"] {
            #expect(AutomaticSourceLanguageDetector.allowsOCRText(text, configuredSourceLanguage: "ja", automaticLanguageFilter: []))
        }
        for text in ["Open the advertising window now", "这是简体中文的广告页面"] {
            #expect(!AutomaticSourceLanguageDetector.allowsOCRText(text, configuredSourceLanguage: "ja", automaticLanguageFilter: []))
        }
    }

    @Test
    func automaticOCRSourceUsesTheConfiguredLanguageAllowlist() {
        #expect(AutomaticSourceLanguageDetector.allowsOCRText("これは日本語のメニューです",
            configuredSourceLanguage: "auto", automaticLanguageFilter: ["ja"]))
        #expect(!AutomaticSourceLanguageDetector.allowsOCRText("This English advertisement must be filtered out.",
            configuredSourceLanguage: "auto", automaticLanguageFilter: ["ja"]))
        #expect(AutomaticSourceLanguageDetector.allowsOCRText("This line remains when automatic filtering is disabled.",
            configuredSourceLanguage: "auto", automaticLanguageFilter: []))
        #expect(!AutomaticSourceLanguageDetector.allows(" \n\t", selectedLanguageCodes: []))
    }
}
