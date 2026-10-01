import Foundation
import NaturalLanguage

/// Apply the source-language policy after raw OCR caching, before requests or overlays.
enum ReaderTranslationLanguageFilter {
    /// A provider can append a stray OCR fragment after a complete Korean
    /// sentence. Drop only a separate, multi-character Han/kana tail after
    /// sentence punctuation; names embedded in the sentence remain intact.
    static func removingForeignScriptTail(_ translation: String, target: String) -> String {
        guard canonical(target) == "ko" else { return translation }
        let scalars = Array(translation.unicodeScalars)
        func korean(_ scalar: Unicode.Scalar) -> Bool {
            (0xAC00...0xD7A3).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value) ||
                (0x3130...0x318F).contains(scalar.value)
        }
        func foreign(_ scalar: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9D).contains(scalar.value) ||
                (0x3400...0x9FFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
        }
        let end = scalars.lastIndex { !CharacterSet.whitespacesAndNewlines.contains($0) }.map { $0 + 1 } ?? 0
        guard end > 0 else { return translation }
        var start = end
        while start > 0 && foreign(scalars[start - 1]) { start -= 1 }
        guard end - start >= 2, start > 0,
              CharacterSet.whitespacesAndNewlines.contains(scalars[start - 1]) else { return translation }
        let prefix = String(String.UnicodeScalarView(scalars[..<start]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.unicodeScalars.filter(korean).count >= 4,
              let last = prefix.last, "!?！？…。".contains(last) else { return translation }
        return prefix
    }

    /// A Japanese sentence re-punctuated by the provider is not a Korean translation.
    /// Exact copies remain valid for explicit SFX/background preservation; short names,
    /// symbols and mixed Korean output are deliberately outside this narrow rejection.
    static func isUntranslatedJapaneseReply(source: String, translation: String, target: String) -> Bool {
        guard canonical(target) == "ko",
              source.trimmingCharacters(in: .whitespacesAndNewlines) != translation.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        func kana(_ scalar: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(scalar.value) || (0xFF66...0xFF9D).contains(scalar.value)
        }
        let letters = translation.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard letters.count >= 20, letters.filter(kana).count >= 2,
              source.unicodeScalars.filter(kana).count >= 2 else { return false }
        return !letters.contains {
            (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) ||
                (0x3130...0x318F).contains($0.value)
        }
    }

    /// Geometrically established balloon prose cannot be silently kept as Japanese in a Korean page.
    /// Short names, effects, signs and unverified background components remain preservation candidates.
    static func requiresBalloonTranslation(_ region: ReaderTranslationRegion, translation: String, target: String) -> Bool {
        guard canonical(target) == "ko", region.balloonInterior?.contourVerified == true,
              region.source.trimmingCharacters(in: .whitespacesAndNewlines) == translation.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        let letters = region.source.unicodeScalars.filter { $0.properties.isAlphabetic }
        let kana = letters.filter { (0x3040...0x30FF).contains($0.value) }
        return letters.count >= 10 && kana.count >= 3 && !letters.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    static func containsUntranslatedJapaneseReply(_ regions: [ReaderTranslationRegion], target: String) -> Bool {
        regions.contains { region in
            region.translation.map { isUntranslatedJapaneseReply(source: region.source, translation: $0, target: target) || requiresBalloonTranslation(region, translation: $0, target: target) } ?? false
        }
    }

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

    /// `apply` runs when OCR is cached and again before requests. The
    /// NaturalLanguage decision is deterministic for the same text/target.
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

    /// Nil preserves the existing all-language cache. Fixed sources with no Apple
    /// classifier also keep the permissive fallback.
    static func identity(settings: ReaderTranslationSettings) -> [String]? {
        var language = languageIdentity(settings: settings)
        if settings.filterBackgroundWithLLM { language = (language ?? []) + [TranslationHTTPCodec.backgroundPolicy] }
        if settings.filterSFXWithLLM { language = (language ?? []) + [TranslationHTTPCodec.sfxPolicy] }
        return language
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
        return eligible
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
