import Foundation

enum IPhoneOCRSettings {
    /// Page text is translated only in the languages the manga recognizer reads reliably
    /// (synthetic probe: other Latin languages lose accents; Hangul, Cyrillic and Vietnamese are
    /// not in its dictionary). Text confidently detected as anything else keeps its source.
    static let translatedSourceLanguageCodes: Set<String> = ["ja", "zh", "zh-Hant", "en"]
    static let defaultDetectorMaximumSide = 1_120
    static let mangaConfidenceThreshold = 0.30
}
