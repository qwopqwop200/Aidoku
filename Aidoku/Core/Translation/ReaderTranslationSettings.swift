import CryptoKit
import Foundation

// The one provider (stored as `custom`); new users start on OpenAI.
struct ReaderCustomTranslationSettings: Equatable, Codable, Sendable {
    static let openAIBaseURL = "https://api.openai.com/v1"
    var baseURL = Self.openAIBaseURL
    var model = "gpt-5-mini"
    var apiProtocol: RemoteTranslationProtocol = .responses
    var reasoningEffort: OpenAIReasoningEffort = .none
}

struct ReaderTranslationSettings: Equatable, Sendable {
    static let keyPrefix = "Reader.translation."
    static let credentialAccount = "openai"
    static let changed = Notification.Name("Reader.translation.changed")

    var provider: RemoteTranslationProvider { RemoteTranslationProvider(baseURL: custom.baseURL) }
    /// "Pages" in What to Translate: reader pages are translated (and pre-translated) at all.
    var translatePages = true
    /// The reader button: translated or original pages on screen; translation continues either way.
    var showsTranslation = true
    var automaticallyTranslate: Bool { translatePages && showsTranslation }
    var shouldProcessReaderPages: Bool { translatePages }
    // Internal; metadata translation overrides these in TitleTranslation.
    var includePageImage = true
    var filterBackgroundWithLLM = true
    var filterSFXWithLLM = true
    var translateMangaTitles = false
    var translateChapterTitles = false
    var translateAuthors = false
    var translateSourceLabels = false
    var translateLargeFilterOptions = false
    var translateMangaTags = false
    var translateMangaDescriptions = false
    var custom = ReaderCustomTranslationSettings()
    var model: String {
        get { custom.model }
        set { custom.model = newValue }
    }
    var reasoningEffort: OpenAIReasoningEffort {
        get { custom.reasoningEffort }
        set { custom.reasoningEffort = newValue }
    }
    var selectedCredentialAccount: String {
        provider == .openAI ? Self.credentialAccount : Self.customCredentialAccount(custom.baseURL)
    }

    // Bind each custom key to the exact configured URL, so servers never share a key.
    private static func customCredentialAccount(_ baseURL: String) -> String {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        return "custom-" + digest
    }
    var targetLanguage = "ko"
    var sourceLanguage = "auto"
    var translationSourceLanguages: [String] = []
    // Metadata has no OCR model and must retain its independent language choices.
    var usesOCRLanguagePolicy = true
    /// The page pipeline has one fixed manga detector/recognizer.
    var supportedOCRSourceLanguageCodes: Set<String> { IPhoneOCRSettings.mangaSourceLanguageCodes }

    mutating func normalizeOCRSourceLanguages() {
        if sourceLanguage != "auto", !supportedOCRSourceLanguageCodes.contains(ReaderTranslationLanguageFilter.canonical(sourceLanguage)) {
            sourceLanguage = "auto"
        }
        // Match the source-language picker's explicit Simplified Chinese tag.
        if sourceLanguage == "zh" { sourceLanguage = "zh-Hans" }
        translationSourceLanguages = ReaderTranslationLanguageFilter.normalized(translationSourceLanguages)
            .filter { supportedOCRSourceLanguageCodes.contains($0) }
        // One "source language" choice: a single checked language is the fixed source the
        // provider is told; none or several stay automatic. A legacy fixed source becomes its
        // one-language selection.
        if sourceLanguage != "auto" {
            translationSourceLanguages = [ReaderTranslationLanguageFilter.canonical(sourceLanguage)]
        } else if translationSourceLanguages.count == 1 {
            sourceLanguage = Self.sourceTag(translationSourceLanguages[0])
        }
    }

    /// The fixed source tag of one selected language (the selection stores Simplified Chinese as "zh").
    static func sourceTag(_ code: String) -> String { code == "zh" ? "zh-Hans" : code }

    /// Sets the source selection and the fixed source it implies.
    mutating func selectSourceLanguages(_ codes: [String]) {
        let codes = ReaderTranslationLanguageFilter.normalized(codes)
        sourceLanguage = codes.count == 1 ? Self.sourceTag(codes[0]) : "auto"
        translationSourceLanguages = codes
        normalizeOCRSourceLanguages()
    }

    /// Transient chapter direction from the reader; V2 orders blocks and panels by it.
    var readingDirection: V2ReadingDirection = .rightToLeft
    var overlay = IPhoneOverlaySettings(
        visible: true, mode: .translateOnly, colorMode: .white, opacity: 0.84,
        textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 2, subtitleContextSentences: 0
    )
    var maximumConcurrentRequests = 16
    // Internal context for metadata translation; never loaded from user preferences.
    var metadataInstructions = ""
    var credentialGeneration: UInt64 = 0
    var cacheLimitBytes: Int64 = ReaderTranslationDiskCache.defaultBytes
    /// Retired preference keys: ignored on load and removed on save.
    // Per-kind metadata language filters are retired: metadata follows the one source selection.
    static let retiredKeys = ["Reader.translationPipelineV2", keyPrefix + "authorSourceLanguages",
        keyPrefix + "sourceLabelSourceLanguages", keyPrefix + "mangaTagSourceLanguages",
        keyPrefix + "mangaDescriptionSourceLanguages", keyPrefix + "mangaTitleSourceLanguages",
        keyPrefix + "chapterTitleSourceLanguages", keyPrefix + "ocr", keyPrefix + "modelTier",
        keyPrefix + "includePageImage", keyPrefix + "filterSFXWithLLM", keyPrefix + "filterBackgroundWithLLM",
        keyPrefix + "pretranslationLimit", keyPrefix + "background"] + legacyOpenAIKeys
    /// The retired picker's OpenAI-only model and reasoning effort.
    static let legacyOpenAIKeys = [keyPrefix + "model", keyPrefix + "reasoningEffort"]

    init(
        defaults: UserDefaults = .standard,
        credentialStore: (any TranslationCredentialManaging)? = nil
    ) {
        Self.migrateProvider(defaults, credentialStore: credentialStore)
        func languages(_ key: String) -> [String] {
            ReaderTranslationLanguageFilter.normalized(defaults.stringArray(forKey: Self.keyPrefix + key) ?? [])
                .filter { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        }
        showsTranslation = defaults.object(forKey: Self.keyPrefix + "automatic") as? Bool ?? showsTranslation
        if let pages = defaults.object(forKey: Self.keyPrefix + "pages") as? Bool {
            translatePages = pages
        } else {
            // Former "automatic" / "translate while showing originals" switches.
            translatePages = showsTranslation || defaults.bool(forKey: Self.keyPrefix + "background")
            if !translatePages { showsTranslation = true }
        }
        translateMangaTitles = defaults.bool(forKey: Self.keyPrefix + "mangaTitles")
        translateChapterTitles = defaults.bool(forKey: Self.keyPrefix + "chapterTitles")
        translateAuthors = defaults.bool(forKey: Self.keyPrefix + "authors")
        translateLargeFilterOptions = defaults.bool(forKey: Self.keyPrefix + "largeFilterOptions")
        translateSourceLabels = defaults.bool(forKey: Self.keyPrefix + "sourceLabels")
        translateMangaTags = defaults.bool(forKey: Self.keyPrefix + "mangaTags")
        translateMangaDescriptions = defaults.bool(forKey: Self.keyPrefix + "mangaDescriptions")
        if let data = defaults.data(forKey: Self.keyPrefix + "custom"),
           let value = try? JSONDecoder().decode(ReaderCustomTranslationSettings.self, from: data) { custom = value }
        targetLanguage = defaults.string(forKey: Self.keyPrefix + "targetLanguage") ?? targetLanguage
        sourceLanguage = defaults.string(forKey: Self.keyPrefix + "sourceLanguage") ?? sourceLanguage
        translationSourceLanguages = languages("translationSourceLanguages")
        if let data = defaults.data(forKey: Self.keyPrefix + "overlay"),
           let value = try? JSONDecoder().decode(IPhoneOverlaySettings.self, from: data) { overlay = value }
        overlay.enforceSourceReplacement()
        maximumConcurrentRequests = defaults.object(forKey: Self.keyPrefix + "concurrency") as? Int ?? maximumConcurrentRequests
        credentialGeneration = Self.savedGeneration(defaults)
        if let value = defaults.object(forKey: Self.keyPrefix + "cacheLimitBytes") as? NSNumber,
           ReaderTranslationDiskCache.limitChoices.contains(value.int64Value) { cacheLimitBytes = value.int64Value }
        normalizeOCRSourceLanguages()
    }

    /// One-time fold of the retired OpenAI/custom picker into the single provider. "provider" stays
    /// "custom" afterwards: the `custom` JSON is authoritative (older builds read it the same way).
    /// OpenAI users (and fresh installs) get the OpenAI base URL with their model, effort and "openai"
    /// Keychain account. Custom users keep their settings; the key of a custom api.openai.com URL moves to
    /// "openai", the account that host now uses.
    private static func migrateProvider(_ defaults: UserDefaults, credentialStore: (any TranslationCredentialManaging)?) {
        let custom = RemoteTranslationProvider.custom.rawValue
        let provider = defaults.string(forKey: keyPrefix + "provider")
        if provider == custom {
            guard defaults.object(forKey: keyPrefix + "model") != nil else { return }
            let saved = defaults.data(forKey: keyPrefix + "custom")
                .flatMap { try? JSONDecoder().decode(ReaderCustomTranslationSettings.self, from: $0) }
            if let saved, RemoteTranslationProvider(baseURL: saved.baseURL) == .openAI {
                let keys = credentialStore ?? KeychainTranslationCredentialStore()
                let legacyAccount = customCredentialAccount(saved.baseURL)
                if let secret = try? keys.secret(for: legacyAccount), (try? keys.secret(for: credentialAccount)) != secret {
                    // Retry on the next launch rather than losing the key.
                    guard (try? keys.save(secret, for: credentialAccount)) != nil else { return }
                    defaults.set(Int(clamping: savedGeneration(defaults) &+ 1), forKey: keyPrefix + "credentialGeneration")
                }
                try? keys.deleteSecret(for: legacyAccount)
            }
        } else {
            var settings = ReaderCustomTranslationSettings()
            settings.model = defaults.string(forKey: keyPrefix + "model") ?? settings.model
            settings.reasoningEffort = defaults.string(forKey: keyPrefix + "reasoningEffort")
                .flatMap(OpenAIReasoningEffort.init(rawValue:)) ?? settings.reasoningEffort
            guard let data = try? JSONEncoder().encode(settings) else { return }
            defaults.set(data, forKey: keyPrefix + "custom")
            defaults.set(custom, forKey: keyPrefix + "provider")
        }
        legacyOpenAIKeys.forEach(defaults.removeObject(forKey:))
    }

    private static func savedGeneration(_ defaults: UserDefaults) -> UInt64 {
        UInt64(max(0, defaults.integer(forKey: keyPrefix + "credentialGeneration")))
    }

    var configuration: RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(
            provider: provider,
            apiProtocol: custom.apiProtocol,
            // OpenAI's endpoint is fixed; this canonical form keeps its cache keys.
            baseURL: provider == .openAI ? "https://api.openai.com" : custom.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialAccount: selectedCredentialAccount,
            credentialGeneration: credentialGeneration,
            instructions: metadataInstructions.isEmpty ? RemoteTranslationConfiguration.defaultInstructions : metadataInstructions,
            reasoningEffort: reasoningEffort,
            // Model defaults may enable reasoning too; only explicit none uses the shorter wait.
            timeout: reasoningEffort == .none ? 120 : 300
        )
    }

    static func setAutomaticTranslation(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: keyPrefix + "automatic")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    func validate() throws {
        guard overlay.opacity.isFinite, (0.2...1).contains(overlay.opacity),
              (1...64).contains(maximumConcurrentRequests),
              ReaderTranslationDiskCache.limitChoices.contains(cacheLimitBytes)
        else { throw RemoteTranslationError.invalidRequest("Invalid OCR or overlay setting.") }
        guard [translationSourceLanguages].allSatisfy({ languages in
            languages.count <= AutomaticSourceLanguageDetector.supportedLanguageCodes.count &&
                Set(languages).count == languages.count &&
                languages.allSatisfy { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        })
        else { throw RemoteTranslationError.invalidRequest("Invalid translation source-language filter.") }
        if usesOCRLanguagePolicy {
            let supported = supportedOCRSourceLanguageCodes
            guard sourceLanguage == "auto" || supported.contains(ReaderTranslationLanguageFilter.canonical(sourceLanguage)),
                  translationSourceLanguages.allSatisfy({ supported.contains(ReaderTranslationLanguageFilter.canonical($0)) }) else {
                throw RemoteTranslationError.invalidRequest(NSLocalizedString("TRANSLATION_OCR_MANGA_HELP"))
            }
        }
        _ = try configuration.validatedEndpoint()
        try RemoteTranslationRequest(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            sourceText: "validation"
        ).validate()
    }

    func save(
        defaults: UserDefaults = .standard,
        apiKey: String = "",
        credentialStore: any TranslationCredentialManaging = KeychainTranslationCredentialStore()
    ) throws {
        try validate()
        try persist(defaults: defaults, apiKey: apiKey, credentialStore: credentialStore, notify: true)
    }

    /// Preserve form edits while incomplete; requests still validate before sending.
    func autosave(
        defaults: UserDefaults = .standard,
        apiKey: String = "",
        credentialStore: any TranslationCredentialManaging = KeychainTranslationCredentialStore()
    ) throws {
        try persist(defaults: defaults, apiKey: apiKey, credentialStore: credentialStore, notify: false)
    }

    private func persist(
        defaults: UserDefaults, apiKey: String,
        credentialStore: any TranslationCredentialManaging, notify: Bool
    ) throws {
        var replacement = overlay
        replacement.enforceSourceReplacement()
        let overlayData = try JSONEncoder().encode(replacement)
        let customData = try JSONEncoder().encode(custom)
        // Encode everything before mutating credentials or preferences.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var generation = max(credentialGeneration, Self.savedGeneration(defaults))
        if !key.isEmpty, (try? credentialStore.secret(for: selectedCredentialAccount)) != key {
            try credentialStore.save(key, for: selectedCredentialAccount)
            generation = max(generation, Self.savedGeneration(defaults)) &+ 1
        }
        defaults.set(overlayData, forKey: Self.keyPrefix + "overlay")
        defaults.set(RemoteTranslationProvider.custom.rawValue, forKey: Self.keyPrefix + "provider")
        Self.retiredKeys.forEach(defaults.removeObject(forKey:))
        defaults.set(showsTranslation, forKey: Self.keyPrefix + "automatic")
        defaults.set(translatePages, forKey: Self.keyPrefix + "pages")
        defaults.set(translateMangaTitles, forKey: Self.keyPrefix + "mangaTitles")
        defaults.set(translateChapterTitles, forKey: Self.keyPrefix + "chapterTitles")
        defaults.set(translateAuthors, forKey: Self.keyPrefix + "authors")
        defaults.set(translateLargeFilterOptions, forKey: Self.keyPrefix + "largeFilterOptions")
        defaults.set(translateSourceLabels, forKey: Self.keyPrefix + "sourceLabels")
        defaults.set(translateMangaTags, forKey: Self.keyPrefix + "mangaTags")
        defaults.set(translateMangaDescriptions, forKey: Self.keyPrefix + "mangaDescriptions")
        defaults.set(customData, forKey: Self.keyPrefix + "custom")
        defaults.set(maximumConcurrentRequests, forKey: Self.keyPrefix + "concurrency")
        defaults.set(targetLanguage, forKey: Self.keyPrefix + "targetLanguage")
        defaults.set(sourceLanguage, forKey: Self.keyPrefix + "sourceLanguage")
        defaults.set(translationSourceLanguages.sorted(), forKey: Self.keyPrefix + "translationSourceLanguages")
        defaults.set(Int(clamping: generation), forKey: Self.keyPrefix + "credentialGeneration")
        let previousCacheLimit = defaults.object(forKey: Self.keyPrefix + "cacheLimitBytes") as? NSNumber
        defaults.set(cacheLimitBytes, forKey: Self.keyPrefix + "cacheLimitBytes")
        if defaults === UserDefaults.standard {
            if previousCacheLimit?.int64Value != cacheLimitBytes {
                Task { try? await ReaderTranslationDiskCache.shared.setByteLimit(cacheLimitBytes) }
            }
            Task { try? await ReaderTranslationDiskCache.shared.refreshSavedSettings() }
        }
        if notify { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    mutating func deleteKey(
        defaults: UserDefaults = .standard,
        credentialStore: any TranslationCredentialManaging = KeychainTranslationCredentialStore()
    ) throws {
        try credentialStore.deleteSecret(for: selectedCredentialAccount)
        // Publish immediately without committing unrelated edits in the settings form.
        credentialGeneration = max(credentialGeneration, Self.savedGeneration(defaults)) &+ 1
        defaults.set(Int(clamping: credentialGeneration), forKey: Self.keyPrefix + "credentialGeneration")
        if defaults === UserDefaults.standard {
            Task { try? await ReaderTranslationDiskCache.shared.refreshSavedSettings() }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
