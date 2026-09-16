import Foundation
import NaturalLanguage

/// Apply the source-language policy after raw OCR caching, before requests or overlays.
enum ReaderTranslationLanguageFilter {
    /// Only skip confident, unmixed text. Short Latin tags and romanized titles remain eligible.
    static func isAlreadyTargetLanguage(_ text: String, target: String) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return false }
        let language = canonical(target)
        let hangul: (Unicode.Scalar) -> Bool = {
            (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) ||
                (0x3130...0x318F).contains($0.value)
        }
        if language == "ko" { return letters.allSatisfy(hangul) }
        if letters.contains(where: hangul) { return false }
        let han: (Unicode.Scalar) -> Bool = {
            (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }
        let kana: (Unicode.Scalar) -> Bool = {
            (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9D).contains($0.value)
        }
        if language == "ja" {
            return letters.contains(where: kana) && letters.allSatisfy { kana($0) || han($0) }
        }
        if language == "zh" || language == "zh-Hant" {
            return letters.allSatisfy(han) && AutomaticSourceLanguageDetector.detect(text) == language
        }
        guard letters.count >= 20, !letters.contains(where: han), !letters.contains(where: kana) else { return false }
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

    /// Nil preserves the existing all-language cache. Fixed sources with no Apple
    /// classifier also keep the permissive fallback.
    static func identity(settings: ReaderTranslationSettings) -> [String]? {
        var language = languageIdentity(settings: settings)
        if settings.filterSFXWithLLM { language = (language ?? []) + ["llm-sfx-v1"] }
        guard settings.filterJapaneseSFX else { return language }
        return (language ?? []) + [ReaderJapaneseSFXFilter.version] +
            (settings.filterJapaneseSFXContext ? [ReaderJapaneseSFXFilter.contextVersion] : [])
    }

    private static func languageIdentity(settings: ReaderTranslationSettings) -> [String]? {
        let source = canonical(settings.sourceLanguage)
        if source == "auto" {
            let languages = normalized(settings.translationSourceLanguages)
            return languages.isEmpty ? nil : ["source-filter-v2-kana-evidence", "auto"] + languages
        }
        guard AutomaticSourceLanguageDetector.automaticallyClassifiableLanguageCodes.contains(source) else { return nil }
        return ["source-filter-v2-kana-evidence", "fixed", source]
    }

    static func apply(_ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> [ReaderTranslationRegion] {
        let source = canonical(settings.sourceLanguage)
        let languages = normalized(settings.translationSourceLanguages)
        let eligible = regions.filter {
            !isAlreadyTargetLanguage($0.source, target: settings.targetLanguage) &&
            AutomaticSourceLanguageDetector.allowsOCRText($0.source, configuredSourceLanguage: source, automaticLanguageFilter: languages)
        }
        return ReaderJapaneseSFXFilter.apply(eligible, settings: settings)
    }

    /// NaturalLanguage classification must not block reader gestures.
    static func applyOffMain(
        _ regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings
    ) async throws -> [ReaderTranslationRegion] {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = apply(regions, settings: settings)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
