import Foundation

/// Apply the source-language policy after raw OCR caching, before requests or overlays.
enum ReaderTranslationLanguageFilter {
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
