import Foundation

enum IPhoneOCRSettings {
    /// Languages `ppocrv6_manga_rec_character_dict` can spell: CJK, kana,
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
    static let mangaMaximumRecognizerWidth = 2_400
    static let defaultDetectorMaximumSide = 1_120
    static let defaultRecognizerMaximumWidth = 1_184
    static let mangaConfidenceThreshold = 0.30
}
