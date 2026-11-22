import Foundation

enum IPhoneOCRSettings {
    /// Languages the manga recognizer dictionary can spell (no Hangul, Cyrillic or
    /// Vietnamese diacritics). A literal set keeps this file self-contained for the host CLI.
    static let mangaSourceLanguageCodes: Set<String> = [
        "zh", "zh-Hant", "en", "ja",
        "fr", "de", "it", "es", "pt", "nl", "pl", "ro", "cs", "sv",
        "no", "da", "fi", "hu", "tr", "id", "ms", "az", "af",
        "bs", "hr", "cy", "et", "ga", "is", "ku", "lt", "lv", "mt",
        "mi", "oc", "sk", "sl", "sq", "sw", "tl", "uz", "la",
        "sr-Latn", "ca", "eu", "gl", "lb", "rm", "qu",
    ]
    static let defaultDetectorMaximumSide = 1_120
    static let mangaConfidenceThreshold = 0.30
}
