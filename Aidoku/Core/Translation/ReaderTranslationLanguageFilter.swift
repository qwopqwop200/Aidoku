import Foundation
import NaturalLanguage

/// Apply the source-language policy before provider requests; excluded text keeps its source.
enum ReaderTranslationLanguageFilter {
    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9D).contains(scalar.value)
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value) || (0x3130...0x318F).contains(scalar.value)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
    }

    /// A Japanese sentence re-punctuated by the provider is not a Korean translation (`V2ReplyText`).
    static func isUntranslatedJapaneseReply(source: String, translation: String, target: String) -> Bool {
        V2ReplyText.isUntranslatedJapaneseReply(source: source, translation: translation, target: canonical(target))
    }

    /// Completed-provider check; classifier-preserved effects keep their existing policy.
    static func containsWrongLanguage(_ translations: [RemoteTranslatedSegment], request: RemoteTranslationRequest) -> Bool {
        let sources = Dictionary(request.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        return translations.contains { segment in
            guard segment.isSFX != true, let source = sources[segment.id] else { return false }
            let displayedText = TranslationHTTPCodec.decodingLeakedEscapes(in: segment.text, source: source)
            return isUntranslatedJapaneseReply(source: source, translation: displayedText, target: request.targetLanguage)
        }
    }

    /// Only skip confident, unmixed text. Short Latin tags and romanized titles remain eligible.
    static func isAlreadyTargetLanguage(_ text: String, target: String) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return false }
        let language = canonical(target)
        if language == "ko" { return letters.allSatisfy(isHangul) }
        if letters.contains(where: isHangul) { return false }
        if language == "ja" {
            return letters.contains(where: isKana) && letters.allSatisfy { isKana($0) || isHan($0) }
        }
        if language == "zh" || language == "zh-Hant" {
            return letters.allSatisfy(isHan) && AutomaticSourceLanguageDetector.detect(text) == language
        }
        guard letters.count >= 20, !letters.contains(where: isHan), !letters.contains(where: isKana) else { return false }
        let key = TargetLanguageKey(text: text, language: language)
        if case let .some(.some(cached)) = targetLanguageCache.value(for: key) { return cached }
        let result = isConfidentlyUnmixed(text, language: language)
        targetLanguageCache.insert(result, for: key)
        return result
    }

    private struct TargetLanguageKey: Hashable {
        let text: String
        let language: String
    }

    /// The same text is rechecked (V2 paint prediction and request; metadata lookup and `apply`).
    private static let targetLanguageCache = LanguageDetectionLRUCache<TargetLanguageKey, Bool>(capacity: 512)

    private static func isConfidentlyUnmixed(_ text: String, language: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.key.rawValue == language, best.value >= 0.95 else { return false }
        // A confident foreign word is evidence of mixed-language metadata.
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) where word.count >= 4 {
            recognizer.reset()
            recognizer.processString(String(word))
            if let wordLanguage = recognizer.languageHypotheses(withMaximum: 1).first,
               wordLanguage.value >= 0.9, wordLanguage.key.rawValue != language { return false }
        }
        return true
    }

    static func canonical(_ code: String) -> String { code == "zh-Hans" ? "zh" : code }

    static func normalized(_ codes: [String]) -> [String] { Set(codes.map(canonical)).sorted() }

    /// Nil preserves the all-language cache identity.
    static func identity(settings: ReaderTranslationSettings) -> [String]? {
        var language = languageIdentity(settings: settings)
        if settings.usesOCRLanguagePolicy {
            language = ["ocr-source-manga-v4-ja-zh-en"] + (language ?? [])
        }
        if settings.filterBackgroundWithLLM { language = (language ?? []) + [TranslationHTTPCodec.backgroundPolicy] }
        if settings.filterSFXWithLLM { language = (language ?? []) + [TranslationHTTPCodec.sfxPolicy] }
        return language
    }

    private static func languageIdentity(settings: ReaderTranslationSettings) -> [String]? {
        let source = canonical(settings.sourceLanguage)
        if source == "auto" {
            let languages = normalized(settings.translationSourceLanguages)
            return languages.isEmpty ? nil : ["source-filter-v3-excluded-source-ownership", "auto"] + languages
        }
        guard AutomaticSourceLanguageDetector.automaticallyClassifiableLanguageCodes.contains(source) else { return nil }
        return ["source-filter-v3-excluded-source-ownership", "fixed", source]
    }

    /// Classify against the complete language set, not just the model's list.
    static func allowsModelSource(_ text: String) -> Bool {
        if isLanguageNeutralSymbols(text) { return true }
        if let detected = AutomaticSourceLanguageDetector.detect(text) {
            return IPhoneOCRSettings.translatedSourceLanguageCodes.contains(detected)
        }
        // Unclassifiable short text: keep scripts the recognizer can spell (not Hangul/Cyrillic).
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        func latin(_ scalar: Unicode.Scalar) -> Bool {
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) ||
                (0xC0...0x24F).contains(scalar.value)
        }
        return !letters.isEmpty && letters.allSatisfy { isKana($0) || isHan($0) || latin($0) }
    }

    /// Punctuation and symbols have no source language to reject.
    static func isLanguageNeutralSymbols(_ text: String) -> Bool {
        let scalars = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        return !scalars.isEmpty && scalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) ||
                CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    static func apply(_ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> [ReaderTranslationRegion] {
        regions.filter { allowsSource($0.source, settings: settings) }
    }

    /// The per-text rule of `apply`.
    static func allowsSource(_ text: String, settings: ReaderTranslationSettings) -> Bool {
        let source = canonical(settings.sourceLanguage)
        let languages = normalized(settings.translationSourceLanguages)
        return isLanguageNeutralSymbols(text) ||
            ((!settings.usesOCRLanguagePolicy || allowsModelSource(text)) &&
            !isAlreadyTargetLanguage(text, target: settings.targetLanguage) &&
            AutomaticSourceLanguageDetector.allowsOCRText(text, configuredSourceLanguage: source, automaticLanguageFilter: languages))
    }

    /// V2 cache identity of `allowsV2Source` (manga recognizer, shared-Han recall).
    static let v2SourcePolicy = "v2-source-filter-v3-manga-latin-shared-han"

    /// The legacy rule, plus Han-only text (which NaturalLanguage cannot split
    /// between Japanese and Chinese) whenever any Han-script language is allowed.
    static func allowsV2Source(_ text: String, settings: ReaderTranslationSettings) -> Bool {
        if allowsSource(text, settings: settings) { return true }
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty, letters.allSatisfy({ isHan($0) || (0xF900...0xFAFF).contains($0.value) }) else { return false }
        let source = canonical(settings.sourceLanguage)
        let allowed = source == "auto" ? normalized(settings.translationSourceLanguages) : [source]
        let hanLanguages: Set<String> = ["ja", "zh", "zh-Hant"]
        return (allowed.isEmpty || allowed.contains(where: hanLanguages.contains)) &&
            !isAlreadyTargetLanguage(text, target: settings.targetLanguage)
    }

    /// Filtered-out lettering keeps its source text; only eligible IDs receive provider text.
    static func preservingExcludedSource(
        original: [ReaderTranslationRegion], translated: [ReaderTranslationRegion], eligibleIDs: Set<String>
    ) -> [ReaderTranslationRegion] {
        let completed = Dictionary(translated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return original.map { source in
            if eligibleIDs.contains(source.id) { return completed[source.id] ?? source }
            var kept = source
            kept.translation = source.source
            kept.translationReuseIdentity = nil
            return kept
        }
    }
}
