import CryptoKit
import Foundation

// The bundled Core ML packages require iOS 18.
enum IPhoneOCRModelTier: String, Codable, CaseIterable, Sendable {
    case medium
    case small
    case tiny
}

enum IPhoneOCRSettings {
    static let defaultDetectorMaximumSide = 1_600
    static let defaultRecognizerMaximumWidth = 1_600
}

struct ReaderOCRConfiguration: Equatable, Codable, Sendable {
    var modelTier: IPhoneOCRModelTier = .medium
    var detectorMaximumSide = 1_600
    var recognizerMaximumWidth = 1_600
    var confidenceThreshold = 0.75
    var detectorPixelThreshold: Double
    var detectorConfidenceThreshold: Double
    var detectorMinimumBoxSide: Double

    init(
        modelTier: IPhoneOCRModelTier = .medium,
        detectorMaximumSide: Int = 1_600,
        recognizerMaximumWidth: Int = 1_600,
        confidenceThreshold: Double = 0.75,
        detectorPixelThreshold: Double? = nil,
        detectorConfidenceThreshold: Double? = nil,
        detectorMinimumBoxSide: Double = 3
    ) {
        self.modelTier = modelTier
        self.detectorMaximumSide = detectorMaximumSide
        self.recognizerMaximumWidth = recognizerMaximumWidth
        self.confidenceThreshold = confidenceThreshold
        self.detectorPixelThreshold = detectorPixelThreshold ?? (modelTier == .tiny ? 0.2 : 0.3)
        self.detectorConfidenceThreshold = detectorConfidenceThreshold ?? (modelTier == .tiny ? 0.4 : 0.6)
        self.detectorMinimumBoxSide = detectorMinimumBoxSide
    }

    private enum CodingKeys: String, CodingKey {
        case modelTier, detectorMaximumSide, recognizerMaximumWidth, confidenceThreshold
        case detectorPixelThreshold, detectorConfidenceThreshold, detectorMinimumBoxSide
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older saved OCR settings lack detector thresholds or minimum size. Preserve
        // every existing preference and use that model's original defaults.
        self.init(
            modelTier: try values.decode(IPhoneOCRModelTier.self, forKey: .modelTier),
            detectorMaximumSide: try values.decode(Int.self, forKey: .detectorMaximumSide),
            recognizerMaximumWidth: try values.decode(Int.self, forKey: .recognizerMaximumWidth),
            confidenceThreshold: try values.decode(Double.self, forKey: .confidenceThreshold),
            detectorPixelThreshold: try values.decodeIfPresent(Double.self, forKey: .detectorPixelThreshold),
            detectorConfidenceThreshold: try values.decodeIfPresent(Double.self, forKey: .detectorConfidenceThreshold),
            detectorMinimumBoxSide: try values.decodeIfPresent(Double.self, forKey: .detectorMinimumBoxSide) ?? 3
        )
    }

    @available(iOS 18.0, *)
    var detectorPostprocessConfiguration: NativeCoreMLDBPostprocessConfiguration {
        let base = NativeCoreMLOCRModelProfile.profile(for: modelTier).postprocessConfiguration
        // Autosaved drafts can bypass validate(); never feed invalid values
        // into the detector's preconditions.
        return NativeCoreMLDBPostprocessConfiguration(
            threshold: detectorPixelThreshold.isFinite ? min(max(detectorPixelThreshold, 0), 1) : base.threshold,
            boxThreshold: detectorConfidenceThreshold.isFinite ? min(max(detectorConfidenceThreshold, 0), 1) : base.boxThreshold,
            unclipRatio: base.unclipRatio,
            maximumCandidates: base.maximumCandidates,
            minimumBoxSide: detectorMinimumBoxSide.isFinite ? min(max(detectorMinimumBoxSide, 0), 20) : base.minimumBoxSide
        )
    }
}

struct ReaderCustomTranslationSettings: Equatable, Codable, Sendable {
    var baseURL = ""
    var model = ""
    var apiProtocol: RemoteTranslationProtocol = .responses
    var reasoningEffort: OpenAIReasoningEffort = .modelDefault
}

struct ReaderTranslationSettings: Equatable, Sendable {
    static let keyPrefix = "Reader.translation."
    static let credentialAccount = "openai"
    static let changed = Notification.Name("Reader.translation.changed")

    var provider: RemoteTranslationProvider = .openAI
    var automaticallyTranslate = true
    var includePageImage = false
    var shouldAttachPageImage: Bool {
        includePageImage && TranslationImageSupport.shared.status(for: configuration) != .unsupported
    }
    var filterBackgroundWithLLM = false
    var filterSFXWithLLM = false
    var filterJapaneseSFX = false
    var filterJapaneseSFXContext = false
    var translateMangaTitles = false
    var translateChapterTitles = false
    var translateAuthors = false
    var authorSourceLanguages: [String] = []
    var translateSourceLabels = false
    var translateLargeFilterOptions = false
    var sourceLabelSourceLanguages: [String] = []
    var translateMangaTags = false
    var mangaTagSourceLanguages: [String] = []
    var translateMangaDescriptions = false
    var mangaDescriptionSourceLanguages: [String] = []
    var mangaTitleSourceLanguages: [String] = []
    var chapterTitleSourceLanguages: [String] = []
    var custom = ReaderCustomTranslationSettings()
    private var openAIModel = "gpt-5-mini"
    private var openAIReasoningEffort: OpenAIReasoningEffort = .modelDefault
    var model: String {
        get { provider == .openAI ? openAIModel : custom.model }
        set {
            if provider == .openAI { openAIModel = newValue } else { custom.model = newValue }
        }
    }
    var reasoningEffort: OpenAIReasoningEffort {
        get {
            if provider == .openAI { return openAIReasoningEffort }
            return custom.reasoningEffort
        }
        set {
            if provider == .openAI { openAIReasoningEffort = newValue } else { custom.reasoningEffort = newValue }
        }
    }
    var selectedCredentialAccount: String {
        guard provider == .custom else { return Self.credentialAccount }
        // Bind each custom key to the exact configured URL (including path).
        // Changing servers cannot reuse OpenAI's key or another server's key.
        let address = custom.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        return "custom-" + digest
    }
    var targetLanguage = "ko"
    var sourceLanguage = "auto"
    var translationSourceLanguages: [String] = []
    // Transient chapter direction, supplied by the reader coordinator.
    var rightToLeftPanelOrder = false
    var modelTier: IPhoneOCRModelTier {
        get { ocr.modelTier }
        set { ocr.modelTier = newValue }
    }
    static let defaultOverlay = IPhoneOverlaySettings(
        visible: true, mode: .translateOnly, colorMode: .white, opacity: 0.84,
        fixedFontSizePoints: 14, textPlacement: .replace, expansionPolicy: .panelConstrained,
        fontSizing: .autoFit, subtitlePosition: .bottom, subtitleMaxLines: 2, subtitleContextSentences: 0
    )
    var overlay = Self.defaultOverlay
    var ocr = ReaderOCRConfiguration()
    var maximumConcurrentRequests = 16
    var instructions = RemoteTranslationConfiguration.defaultInstructions
    var credentialGeneration: UInt64 = 0
    var cacheLimitBytes: Int64 = ReaderTranslationDiskCache.defaultBytes

    init(defaults: UserDefaults = .standard) {
        // Keep the existing OpenAI preferences and Keychain account during migration.
        openAIModel = defaults.string(forKey: Self.keyPrefix + "model") ?? openAIModel
        provider = defaults.string(forKey: Self.keyPrefix + "provider").flatMap(RemoteTranslationProvider.init) ?? provider
        automaticallyTranslate = defaults.object(forKey: Self.keyPrefix + "automatic") as? Bool ?? automaticallyTranslate
        includePageImage = defaults.bool(forKey: Self.keyPrefix + "includePageImage")
        filterSFXWithLLM = defaults.bool(forKey: Self.keyPrefix + "filterSFXWithLLM")
        filterBackgroundWithLLM = defaults.bool(forKey: Self.keyPrefix + "filterBackgroundWithLLM")
        filterJapaneseSFX = defaults.bool(forKey: Self.keyPrefix + "filterJapaneseSFX")
        filterJapaneseSFXContext = defaults.bool(forKey: Self.keyPrefix + "filterJapaneseSFXContext")
        translateMangaTitles = defaults.bool(forKey: Self.keyPrefix + "mangaTitles")
        translateChapterTitles = defaults.bool(forKey: Self.keyPrefix + "chapterTitles")
        translateAuthors = defaults.bool(forKey: Self.keyPrefix + "authors")
        authorSourceLanguages = ReaderTranslationLanguageFilter.normalized(
            defaults.stringArray(forKey: Self.keyPrefix + "authorSourceLanguages") ?? []
        ).filter { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        translateLargeFilterOptions = defaults.bool(forKey: Self.keyPrefix + "largeFilterOptions")
        translateSourceLabels = defaults.bool(forKey: Self.keyPrefix + "sourceLabels")
        sourceLabelSourceLanguages = ReaderTranslationLanguageFilter.normalized(
            defaults.stringArray(forKey: Self.keyPrefix + "sourceLabelSourceLanguages") ?? []
        ).filter { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        translateMangaTags = defaults.bool(forKey: Self.keyPrefix + "mangaTags")
        mangaTagSourceLanguages = ReaderTranslationLanguageFilter.normalized(
            defaults.stringArray(forKey: Self.keyPrefix + "mangaTagSourceLanguages") ?? []
        ).filter { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        translateMangaDescriptions = defaults.bool(forKey: Self.keyPrefix + "mangaDescriptions")
        mangaDescriptionSourceLanguages = ReaderTranslationLanguageFilter.normalized(
            defaults.stringArray(forKey: Self.keyPrefix + "mangaDescriptionSourceLanguages") ?? []
        ).filter { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        mangaTitleSourceLanguages = ReaderTranslationLanguageFilter.normalized(
            defaults.stringArray(forKey: Self.keyPrefix + "mangaTitleSourceLanguages") ?? []
        ).filter { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        chapterTitleSourceLanguages = ReaderTranslationLanguageFilter.normalized(
            defaults.stringArray(forKey: Self.keyPrefix + "chapterTitleSourceLanguages") ?? []
        ).filter { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        if let data = defaults.data(forKey: Self.keyPrefix + "custom"),
           let value = try? JSONDecoder().decode(ReaderCustomTranslationSettings.self, from: data) { custom = value }
        targetLanguage = defaults.string(forKey: Self.keyPrefix + "targetLanguage") ?? targetLanguage
        sourceLanguage = defaults.string(forKey: Self.keyPrefix + "sourceLanguage") ?? sourceLanguage
        translationSourceLanguages = ReaderTranslationLanguageFilter.normalized(
            defaults.stringArray(forKey: Self.keyPrefix + "translationSourceLanguages") ?? []
        ).filter { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        let storedModelTier = defaults.string(forKey: Self.keyPrefix + "modelTier").flatMap(IPhoneOCRModelTier.init) ?? modelTier
        ocr = ReaderOCRConfiguration(modelTier: storedModelTier)
        if let data = defaults.data(forKey: Self.keyPrefix + "overlay"),
           let value = try? JSONDecoder().decode(IPhoneOverlaySettings.self, from: data) { overlay = value }
        overlay.enforceSourceReplacement()
        if let data = defaults.data(forKey: Self.keyPrefix + "ocr"),
           let value = try? JSONDecoder().decode(ReaderOCRConfiguration.self, from: data) { ocr = value }
        ocr.modelTier = modelTier
        openAIReasoningEffort = defaults.string(forKey: Self.keyPrefix + "reasoningEffort")
            .flatMap(OpenAIReasoningEffort.init(rawValue:)) ?? openAIReasoningEffort
        maximumConcurrentRequests = defaults.object(forKey: Self.keyPrefix + "concurrency") as? Int ?? maximumConcurrentRequests
        instructions = defaults.string(forKey: Self.keyPrefix + "instructions") ?? instructions
        credentialGeneration = UInt64(max(0, defaults.integer(forKey: Self.keyPrefix + "credentialGeneration")))
        if let value = defaults.object(forKey: Self.keyPrefix + "cacheLimitBytes") as? NSNumber,
           ReaderTranslationDiskCache.limitChoices.contains(value.int64Value) { cacheLimitBytes = value.int64Value }
    }

    var configuration: RemoteTranslationConfiguration {
        RemoteTranslationConfiguration(
            provider: provider,
            apiProtocol: provider == .openAI ? .responses : custom.apiProtocol,
            baseURL: provider == .openAI ? "https://api.openai.com" : custom.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialAccount: selectedCredentialAccount,
            credentialGeneration: credentialGeneration,
            instructions: instructions,
            reasoningEffort: reasoningEffort,
            // Model defaults may enable reasoning too; only explicit none uses the shorter wait.
            timeout: reasoningEffort == .none ? 120 : 300
        )
    }

    var ocrConfiguration: ReaderOCRConfiguration {
        var value = ocr
        value.modelTier = modelTier
        return value
    }

    func hasSameTranslation(as other: Self) -> Bool {
        includePageImage == other.includePageImage && rightToLeftPanelOrder == other.rightToLeftPanelOrder && configuration == other.configuration && ocrConfiguration == other.ocrConfiguration &&
            sourceLanguage == other.sourceLanguage && targetLanguage == other.targetLanguage &&
            ReaderTranslationLanguageFilter.identity(settings: self) == ReaderTranslationLanguageFilter.identity(settings: other)
    }

    static func setAutomaticTranslation(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: keyPrefix + "automatic")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    func validate() throws {
        guard overlay.opacity.isFinite, (0.2...1).contains(overlay.opacity),
              (8...64).contains(overlay.fixedFontSizePoints),
              [800, 1_200, 1_600, 2_000].contains(ocr.detectorMaximumSide),
              [800, 1_200, 1_600, 2_000].contains(ocr.recognizerMaximumWidth),
              ocr.confidenceThreshold.isFinite, (0...1).contains(ocr.confidenceThreshold),
              ocr.detectorPixelThreshold.isFinite, (0...1).contains(ocr.detectorPixelThreshold),
              ocr.detectorConfidenceThreshold.isFinite, (0...1).contains(ocr.detectorConfidenceThreshold),
              ocr.detectorMinimumBoxSide.isFinite, (0...20).contains(ocr.detectorMinimumBoxSide),
              (1...64).contains(maximumConcurrentRequests), ReaderTranslationDiskCache.limitChoices.contains(cacheLimitBytes)
        else { throw RemoteTranslationError.invalidRequest("Invalid OCR or overlay setting.") }
        guard [translationSourceLanguages, mangaTitleSourceLanguages, chapterTitleSourceLanguages, mangaDescriptionSourceLanguages, mangaTagSourceLanguages, sourceLabelSourceLanguages, authorSourceLanguages].allSatisfy({ languages in
            languages.count <= AutomaticSourceLanguageDetector.supportedLanguageCodes.count &&
                Set(languages).count == languages.count &&
                languages.allSatisfy { AutomaticSourceLanguageDetector.supportedLanguageCodes.contains($0) }
        })
        else { throw RemoteTranslationError.invalidRequest("Invalid translation source-language filter.") }
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

    /// Preserve form edits even while an endpoint or model is incomplete.
    /// Network requests still validate the configuration before sending anything.
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
        let ocrData = try JSONEncoder().encode(ocrConfiguration)
        let customData = try JSONEncoder().encode(custom)
        // Encode everything before mutating credentials or preferences.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var generation = max(credentialGeneration, UInt64(max(0, defaults.integer(forKey: Self.keyPrefix + "credentialGeneration"))))
        if !key.isEmpty {
            try credentialStore.save(key, for: selectedCredentialAccount)
            generation = max(generation, UInt64(max(0, defaults.integer(forKey: Self.keyPrefix + "credentialGeneration")))) &+ 1
        }
        defaults.set(overlayData, forKey: Self.keyPrefix + "overlay")
        defaults.set(ocrData, forKey: Self.keyPrefix + "ocr")
        defaults.set(openAIReasoningEffort.rawValue, forKey: Self.keyPrefix + "reasoningEffort")
        defaults.set(provider.rawValue, forKey: Self.keyPrefix + "provider")
        defaults.set(includePageImage, forKey: Self.keyPrefix + "includePageImage")
        defaults.set(filterSFXWithLLM, forKey: Self.keyPrefix + "filterSFXWithLLM")
        defaults.set(filterBackgroundWithLLM, forKey: Self.keyPrefix + "filterBackgroundWithLLM")
        defaults.set(automaticallyTranslate, forKey: Self.keyPrefix + "automatic")
        defaults.set(filterJapaneseSFX, forKey: Self.keyPrefix + "filterJapaneseSFX")
        defaults.set(filterJapaneseSFXContext, forKey: Self.keyPrefix + "filterJapaneseSFXContext")
        defaults.set(translateMangaTitles, forKey: Self.keyPrefix + "mangaTitles")
        defaults.set(translateChapterTitles, forKey: Self.keyPrefix + "chapterTitles")
        defaults.set(translateAuthors, forKey: Self.keyPrefix + "authors")
        defaults.set(authorSourceLanguages.sorted(), forKey: Self.keyPrefix + "authorSourceLanguages")
        defaults.set(translateLargeFilterOptions, forKey: Self.keyPrefix + "largeFilterOptions")
        defaults.set(translateSourceLabels, forKey: Self.keyPrefix + "sourceLabels")
        defaults.set(sourceLabelSourceLanguages.sorted(), forKey: Self.keyPrefix + "sourceLabelSourceLanguages")
        defaults.set(translateMangaTags, forKey: Self.keyPrefix + "mangaTags")
        defaults.set(mangaTagSourceLanguages.sorted(), forKey: Self.keyPrefix + "mangaTagSourceLanguages")
        defaults.set(translateMangaDescriptions, forKey: Self.keyPrefix + "mangaDescriptions")
        defaults.set(mangaDescriptionSourceLanguages.sorted(), forKey: Self.keyPrefix + "mangaDescriptionSourceLanguages")
        defaults.set(mangaTitleSourceLanguages.sorted(), forKey: Self.keyPrefix + "mangaTitleSourceLanguages")
        defaults.set(chapterTitleSourceLanguages.sorted(), forKey: Self.keyPrefix + "chapterTitleSourceLanguages")
        defaults.set(customData, forKey: Self.keyPrefix + "custom")
        defaults.set(maximumConcurrentRequests, forKey: Self.keyPrefix + "concurrency")
        defaults.set(openAIModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.keyPrefix + "model")
        defaults.set(targetLanguage, forKey: Self.keyPrefix + "targetLanguage")
        defaults.set(sourceLanguage, forKey: Self.keyPrefix + "sourceLanguage")
        defaults.set(translationSourceLanguages.sorted(), forKey: Self.keyPrefix + "translationSourceLanguages")
        defaults.set(modelTier.rawValue, forKey: Self.keyPrefix + "modelTier")
        defaults.set(instructions, forKey: Self.keyPrefix + "instructions")
        defaults.set(Int(clamping: generation), forKey: Self.keyPrefix + "credentialGeneration")
        let previousCacheLimit = defaults.object(forKey: Self.keyPrefix + "cacheLimitBytes") as? NSNumber
        defaults.set(cacheLimitBytes, forKey: Self.keyPrefix + "cacheLimitBytes")
        if defaults === UserDefaults.standard, previousCacheLimit?.int64Value != cacheLimitBytes {
            Task { try? await ReaderTranslationDiskCache.shared.setByteLimit(cacheLimitBytes) }
        }
        if defaults === UserDefaults.standard {
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
        let savedGeneration = UInt64(max(0, defaults.integer(forKey: Self.keyPrefix + "credentialGeneration")))
        credentialGeneration = max(credentialGeneration, savedGeneration) &+ 1
        defaults.set(Int(clamping: credentialGeneration), forKey: Self.keyPrefix + "credentialGeneration")
        if defaults === UserDefaults.standard {
            Task { try? await ReaderTranslationDiskCache.shared.refreshSavedSettings() }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
