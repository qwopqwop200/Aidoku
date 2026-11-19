import Foundation

// The bundled Core ML packages require iOS 18.
enum IPhoneOCRModelTier: String, Codable, CaseIterable, Sendable {
    case medium
    case small
    case tiny
    case manga

    /// Nil retains the unified models' existing source-language contract.
    var restrictedSourceLanguageCodes: Set<String>? {
        self == .manga ? Self.mangaSourceLanguageCodes : nil
    }

    /// Languages `ppocrv6_manga_rec_character_dict.txt` can spell: CJK, kana,
    /// ASCII and Latin-1/Extended-A/B letters. It has no Hangul or Cyrillic and
    /// almost none of Vietnamese's stacked diacritics (U+1EA0...U+1EF9), so
    /// Korean (never offered) and Vietnamese are excluded. A literal set (not
    /// `AutomaticSourceLanguageDetector`) keeps this file self-contained for the host CLI.
    static let mangaSourceLanguageCodes: Set<String> = [
        "zh", "zh-Hant", "en", "ja",
        "fr", "de", "it", "es", "pt", "nl", "pl", "ro", "cs", "sv",
        "no", "da", "fi", "hu", "tr", "id", "ms", "az", "af",
        "bs", "hr", "cy", "et", "ga", "is", "ku", "lt", "lv", "mt",
        "mi", "oc", "sk", "sl", "sq", "sw", "tl", "uz", "la",
        "sr-Latn", "ca", "eu", "gl", "lb", "rm", "qu",
    ]
}

enum IPhoneOCRSettings {
    static let defaultModelTier: IPhoneOCRModelTier = .manga
    static let minimumInputDimension = 32
    static let maximumDetectorSide = 1_184
    static let maximumRecognizerWidth = 1_184
    static let mangaMaximumRecognizerWidth = 2_400
    static let defaultDetectorMaximumSide = 1_120
    static let defaultRecognizerMaximumWidth = maximumRecognizerWidth
    static let mangaConfidenceThreshold = 0.30

    static func defaultDetectorMaximumSide(for tier: IPhoneOCRModelTier) -> Int {
        tier == .manga ? defaultDetectorMaximumSide : maximumDetectorSide
    }

    static func maximumRecognizerWidth(for tier: IPhoneOCRModelTier) -> Int {
        tier == .manga ? mangaMaximumRecognizerWidth : maximumRecognizerWidth
    }
    static func defaultConfidenceThreshold(for tier: IPhoneOCRModelTier) -> Double {
        tier == .manga ? mangaConfidenceThreshold : 0.50
    }
    static func migratedConfidenceThreshold(_ value: Double, for tier: IPhoneOCRModelTier) -> Double {
        value == 0.75 || tier == .manga && (value == 0.50 || value == 0.45)
            ? defaultConfidenceThreshold(for: tier) : value
    }
}
