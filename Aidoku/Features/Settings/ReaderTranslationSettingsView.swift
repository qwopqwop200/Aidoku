import SwiftUI

struct ReaderTranslationSettingsView: View {
    @State private var settings = ReaderTranslationSettings()
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var cachedBytes: Int64 = 0
    @State private var clearingCache = false
    @StateObject private var connectionTest = ReaderTranslationConnectionTest()
    @State private var pendingChange: Task<Void, Never>?
    @State private var imageSupportStatus: TranslationImageSupport.Status = .unknown

    private let languages: [(String, String)] = [
        ("ko", "한국어"), ("en", "English"), ("ja", "日本語"), ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
        ("pt", "Português"), ("it", "Italiano"), ("ru", "Русский"), ("vi", "Tiếng Việt")
    ]

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("TRANSLATION_AUTOMATIC"), isOn: persistedSettings.automaticallyTranslate)
                    .accessibilityIdentifier("translation.automatic")
            } footer: {
                Text(NSLocalizedString("TRANSLATION_AUTOMATIC_HELP"))
            }
            Section {
                Toggle(NSLocalizedString("TRANSLATION_MANGA_TITLES"), isOn: persistedSettings.translateMangaTitles)
                    .accessibilityIdentifier("translation.mangaTitles")
                titleLanguageFilterLink("TRANSLATION_MANGA_TITLE_FILTER", selection: persistedSettings.mangaTitleSourceLanguages,
                                        accessibilityPrefix: "translation.mangaTitleFilter")
                Toggle(NSLocalizedString("TRANSLATION_CHAPTER_TITLES"), isOn: persistedSettings.translateChapterTitles)
                    .accessibilityIdentifier("translation.chapterTitles")
                titleLanguageFilterLink("TRANSLATION_CHAPTER_TITLE_FILTER", selection: persistedSettings.chapterTitleSourceLanguages,
                                        accessibilityPrefix: "translation.chapterTitleFilter")
                Toggle(NSLocalizedString("TRANSLATION_AUTHORS"), isOn: persistedSettings.translateAuthors)
                    .accessibilityIdentifier("translation.authors")
                titleLanguageFilterLink("TRANSLATION_AUTHOR_FILTER", selection: persistedSettings.authorSourceLanguages,
                                        accessibilityPrefix: "translation.authorFilter")
                Toggle(NSLocalizedString("TRANSLATION_SOURCE_LABELS"), isOn: persistedSettings.translateSourceLabels)
                    .accessibilityIdentifier("translation.sourceLabels")
                titleLanguageFilterLink("TRANSLATION_SOURCE_LABEL_FILTER", selection: persistedSettings.sourceLabelSourceLanguages,
                                        accessibilityPrefix: "translation.sourceLabelFilter")
                Toggle(NSLocalizedString("TRANSLATION_MANGA_TAGS"), isOn: persistedSettings.translateMangaTags)
                    .accessibilityIdentifier("translation.mangaTags")
                titleLanguageFilterLink("TRANSLATION_TAG_FILTER", selection: persistedSettings.mangaTagSourceLanguages,
                                        accessibilityPrefix: "translation.tagFilter")
                Toggle(NSLocalizedString("TRANSLATION_MANGA_DESCRIPTIONS"), isOn: persistedSettings.translateMangaDescriptions)
                    .accessibilityIdentifier("translation.mangaDescriptions")
                titleLanguageFilterLink("TRANSLATION_DESCRIPTION_FILTER", selection: persistedSettings.mangaDescriptionSourceLanguages,
                                        accessibilityPrefix: "translation.descriptionFilter")
                Toggle(NSLocalizedString("TRANSLATION_LARGE_FILTER_OPTIONS"), isOn: persistedSettings.translateLargeFilterOptions)
                    .accessibilityIdentifier("translation.largeFilterOptions")
            } footer: {
                Text(NSLocalizedString("TRANSLATION_TITLES_HELP"))
            }
            providerSection
            Section(NSLocalizedString("TRANSLATION_ADVANCED")) {
                Picker(NSLocalizedString("TRANSLATION_REASONING"), selection: persistedSettings.reasoningEffort) {
                    ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                        Text(reasoningTitle(effort)).tag(effort)
                    }
                }
                .accessibilityIdentifier("translation.reasoning")
                Picker(NSLocalizedString("TRANSLATION_CONCURRENCY"), selection: persistedSettings.maximumConcurrentRequests) {
                    ForEach([1, 2, 4, 8, 16], id: \.self) { Text(String($0)).tag($0) }
                }
            }
            Section(NSLocalizedString("TRANSLATION_LANGUAGE")) {
                Picker(NSLocalizedString("TRANSLATION_TARGET"), selection: persistedSettings.targetLanguage) {
                    ForEach(languages, id: \.0) { code, title in Text(title).tag(code) }
                }
                Picker(NSLocalizedString("TRANSLATION_PAGE_SOURCE"), selection: persistedSettings.sourceLanguage) {
                    Text(NSLocalizedString("TRANSLATION_AUTO")).tag("auto")
                    ForEach(ReaderTranslationLanguageOptions.codes, id: \.self) { code in
                        Text(ReaderTranslationLanguageOptions.name(code)).tag(code == "zh" ? "zh-Hans" : code)
                    }
                    // Preserve a legacy source choice until the user changes it.
                    if settings.sourceLanguage != "auto", !AutomaticSourceLanguageDetector.supportedLanguageCodes
                        .contains(ReaderTranslationLanguageFilter.canonical(settings.sourceLanguage)) {
                        Text(ReaderTranslationLanguageOptions.name(settings.sourceLanguage)).tag(settings.sourceLanguage)
                    }
                }
                if settings.sourceLanguage == "auto" {
                    NavigationLink {
                        ReaderTranslationLanguageFilterView(selection: persistedSettings.translationSourceLanguages)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("TRANSLATION_SOURCE_FILTER"))
                            Text(settings.translationSourceLanguages.isEmpty ? NSLocalizedString("TRANSLATION_FILTER_ALL") :
                                    settings.translationSourceLanguages.map(ReaderTranslationLanguageOptions.name).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier("translation.sourceFilter")
                } else {
                    Text(NSLocalizedString("TRANSLATION_FIXED_SOURCE_FILTER_HELP"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("PP-OCRv6", selection: persistedSettings.modelTier) {
                    Text(NSLocalizedString("TRANSLATION_OCR_MEDIUM")).tag(IPhoneOCRModelTier.medium)
                    Text(NSLocalizedString("TRANSLATION_OCR_SMALL")).tag(IPhoneOCRModelTier.small)
                    Text(NSLocalizedString("TRANSLATION_OCR_TINY")).tag(IPhoneOCRModelTier.tiny)
                }
                Picker(NSLocalizedString("TRANSLATION_DETECTOR_SIZE"), selection: persistedSettings.ocr.detectorMaximumSide) {
                    ForEach([800, 1_200, 1_600, 2_000], id: \.self) { Text(String($0)).tag($0) }
                }
                Picker(NSLocalizedString("TRANSLATION_RECOGNIZER_SIZE"), selection: persistedSettings.ocr.recognizerMaximumWidth) {
                    ForEach([800, 1_200, 1_600, 2_000], id: \.self) { Text(String($0)).tag($0) }
                }
                ocrThresholdSlider(
                    title: NSLocalizedString("TRANSLATION_DETECTOR_PIXEL_THRESHOLD"),
                    value: persistedSettings.ocr.detectorPixelThreshold,
                    identifier: "translation.detectorPixelThreshold"
                )
                ocrThresholdSlider(
                    title: NSLocalizedString("TRANSLATION_DETECTOR_CONFIDENCE"),
                    value: persistedSettings.ocr.detectorConfidenceThreshold,
                    identifier: "translation.detectorConfidence"
                )
                ocrThresholdSlider(
                    title: NSLocalizedString("TRANSLATION_CONFIDENCE"),
                    value: persistedSettings.ocr.confidenceThreshold,
                    identifier: "translation.recognitionConfidence"
                )
                VStack(alignment: .leading) {
                    HStack {
                        Text(NSLocalizedString("TRANSLATION_DETECTOR_MINIMUM_SIZE"))
                        Spacer()
                        Text(settings.ocr.detectorMinimumBoxSide.formatted(.number.precision(.fractionLength(0))) + " px")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Slider(value: persistedSettings.ocr.detectorMinimumBoxSide, in: 0...20, step: 1)
                        .accessibilityLabel(NSLocalizedString("TRANSLATION_DETECTOR_MINIMUM_SIZE"))
                        .accessibilityValue(settings.ocr.detectorMinimumBoxSide.formatted(.number.precision(.fractionLength(0))) + " px")
                        .accessibilityIdentifier("translation.detectorMinimumSize")
                    Text(NSLocalizedString("TRANSLATION_DETECTOR_MINIMUM_SIZE_HELP"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(NSLocalizedString("TRANSLATION_OCR_HELP") + "\n\n" + NSLocalizedString("TRANSLATION_OCR_CONFIDENCE_HELP"))
            }
            Section {
                Toggle(NSLocalizedString("TRANSLATION_SFX_FILTER"), isOn: persistedSettings.filterJapaneseSFX)
                    .accessibilityIdentifier("translation.filterJapaneseSFX")
                Toggle(NSLocalizedString("TRANSLATION_SFX_CONTEXT_FILTER"), isOn: persistedSettings.filterJapaneseSFXContext)
                    .accessibilityIdentifier("translation.filterJapaneseSFXContext")
                    .disabled(!settings.filterJapaneseSFX)
            } footer: {
                Text(NSLocalizedString("TRANSLATION_SFX_FILTER_HELP") + "\n\n" + NSLocalizedString("TRANSLATION_SFX_CONTEXT_FILTER_HELP"))
            }
            Section {
                Toggle(NSLocalizedString("TRANSLATION_LLM_SFX"), isOn: persistedSettings.filterSFXWithLLM)
                    .accessibilityIdentifier("translation.filterSFXWithLLM")
            } footer: {
                Text(NSLocalizedString("TRANSLATION_LLM_SFX_HELP") + "\n\n" + NSLocalizedString("TRANSLATION_LLM_SFX_NO_IMAGE"))
            }
            Section {
                Toggle(NSLocalizedString("TRANSLATION_LLM_BACKGROUND"), isOn: persistedSettings.filterBackgroundWithLLM)
                    .accessibilityIdentifier("translation.filterBackgroundWithLLM")
            } footer: {
                Text(NSLocalizedString("TRANSLATION_LLM_BACKGROUND_HELP"))
            }
            Section {
                Toggle(NSLocalizedString("TRANSLATION_INCLUDE_IMAGE"), isOn: persistedSettings.includePageImage)
                    .accessibilityIdentifier("translation.includePageImage")
                imageSupportNotice
            } footer: {
                Text(NSLocalizedString("TRANSLATION_INCLUDE_IMAGE_HELP"))
            }
            overlaySection
            cacheSection
            Section(NSLocalizedString("TRANSLATION_INSTRUCTIONS")) {
                TextEditor(text: persistedSettings.instructions)
                    .frame(minHeight: 140)
                Button(NSLocalizedString("TRANSLATION_RESET_PROMPT")) {
                    persistedSettings.wrappedValue.instructions = RemoteTranslationConfiguration.defaultInstructions
                }
            }
            Section {
                NavigationLink(NSLocalizedString("TRANSLATION_NOTICES")) {
                    ScrollView {
                        Text(notices).font(.footnote).textSelection(.enabled).padding()
                    }
                    .navigationTitle(NSLocalizedString("TRANSLATION_NOTICES"))
                }
            }
        }
        .navigationTitle(NSLocalizedString("TRANSLATION_TITLE"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshCredential(); refreshImageSupport() }
        .onReceive(NotificationCenter.default.publisher(for: TranslationImageSupport.changed)) { _ in
            refreshImageSupport()
        }
        .task { cachedBytes = (try? await ReaderTranslationDiskCache.shared.statistics().bytes) ?? 0 }
        .onDisappear {
            publishPendingChange()
            connectionTest.reset()
        }
        .onChange(of: settings.configuration) { _ in connectionTest.reset(); refreshImageSupport() }
        .onChange(of: settings.includePageImage) { _ in connectionTest.reset() }
        .onChange(of: settings.sourceLanguage) { _ in connectionTest.reset() }
        .onChange(of: settings.targetLanguage) { _ in connectionTest.reset() }
        .onChange(of: apiKey) { _ in connectionTest.reset() }
        .alert(NSLocalizedString("TRANSLATION_TITLE"), isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button(NSLocalizedString("OK"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func ocrThresholdSlider(title: String, value: Binding<Double>, identifier: String) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Slider(value: value, in: 0...1, step: 0.05)
                .accessibilityLabel(title)
                .accessibilityValue(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .accessibilityIdentifier(identifier)
        }
    }

    private func reasoningTitle(_ effort: OpenAIReasoningEffort) -> String {
        switch effort {
        case .modelDefault: NSLocalizedString("TRANSLATION_MODEL_DEFAULT")
        case .none: NSLocalizedString("TRANSLATION_REASONING_NONE")
        case .minimal: NSLocalizedString("TRANSLATION_REASONING_MINIMAL")
        case .low: NSLocalizedString("TRANSLATION_REASONING_LOW")
        case .medium: NSLocalizedString("TRANSLATION_REASONING_MEDIUM")
        case .high: NSLocalizedString("TRANSLATION_REASONING_HIGH")
        case .xhigh: NSLocalizedString("TRANSLATION_REASONING_XHIGH")
        case .max: NSLocalizedString("TRANSLATION_REASONING_MAX")
        }
    }

    private func titleLanguageFilterLink(_ key: String, selection: Binding<[String]>, accessibilityPrefix: String) -> some View {
        NavigationLink {
            ReaderTranslationLanguageFilterView(selection: selection, title: NSLocalizedString(key),
                help: NSLocalizedString("TRANSLATION_METADATA_FILTER_HELP"), accessibilityPrefix: accessibilityPrefix)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString(key))
                Text(selection.wrappedValue.isEmpty ? NSLocalizedString("TRANSLATION_FILTER_ALL") :
                        selection.wrappedValue.map(ReaderTranslationLanguageOptions.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityIdentifier(accessibilityPrefix)
    }

    private var cacheSection: some View {
        Section {
            Picker(NSLocalizedString("TRANSLATION_CACHE_LIMIT"), selection: persistedSettings.cacheLimitBytes) {
                ForEach(ReaderTranslationDiskCache.limitChoices, id: \.self) { limit in
                    Text(ByteCountFormatter.string(fromByteCount: limit, countStyle: .decimal)).tag(limit)
                }
            }
            .accessibilityIdentifier("translation.cacheLimit")
            HStack {
                Text(NSLocalizedString("TRANSLATION_CACHE_USED"))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: cachedBytes, countStyle: .decimal)).foregroundStyle(.secondary)
            }
            Button(NSLocalizedString("TRANSLATION_CLEAR_CACHE"), role: .destructive) {
                clearingCache = true
                Task {
                    defer { clearingCache = false }
                    do {
                        ReaderTranslationRenderCache.shared.clearMemory()
                        try await ReaderTranslationDiskCache.shared.clear()
                        try await ReaderTranslationService.shared.clearCache()
                        ReaderTranslationRenderCache.shared.clearMemory()
                        cachedBytes = (try? await ReaderTranslationDiskCache.shared.statistics().bytes) ?? 0
                        message = NSLocalizedString("TRANSLATION_CACHE_CLEARED")
                    } catch { message = error.localizedDescription }
                }
            }
            .disabled(clearingCache)
            .accessibilityIdentifier("translation.clearCache")
        } header: {
            Text(NSLocalizedString("TRANSLATION_CACHE"))
        } footer: {
            Text(NSLocalizedString("TRANSLATION_CACHE_HELP"))
        }
    }

    private var providerSection: some View {
        Section {
            Picker(NSLocalizedString("TRANSLATION_PROVIDER"), selection: persistedSettings.provider) {
                Text("OpenAI").tag(RemoteTranslationProvider.openAI)
                Text(NSLocalizedString("TRANSLATION_CUSTOM_PROVIDER")).tag(RemoteTranslationProvider.custom)
            }
            .accessibilityIdentifier("translation.provider")
            if settings.provider == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("TRANSLATION_BASE_URL")).font(.caption).foregroundStyle(.secondary)
                    TextField("https://example.com/v1", text: persistedSettings.custom.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("translation.baseURL")
                }
                Picker(NSLocalizedString("TRANSLATION_API_FORMAT"), selection: persistedSettings.custom.apiProtocol) {
                    Text("Responses").tag(RemoteTranslationProtocol.responses)
                    Text("Chat Completions").tag(RemoteTranslationProtocol.chatCompletions)
                }
                .accessibilityIdentifier("translation.apiProtocol")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("TRANSLATION_MODEL")).font(.caption).foregroundStyle(.secondary)
                TextField(NSLocalizedString("TRANSLATION_MODEL"), text: persistedSettings.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("translation.model")
            }
            SecureField(NSLocalizedString(hasKey ? "TRANSLATION_KEY_REPLACE" : "TRANSLATION_KEY"), text: persistedAPIKey)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("translation.apiKey")
            if hasKey {
                Label(NSLocalizedString("TRANSLATION_KEY_SAVED"), systemImage: "checkmark.shield")
                Button(NSLocalizedString("TRANSLATION_KEY_DELETE"), role: .destructive, action: deleteKey)
            }
            connectionTestRows
            if settings.provider == .openAI {
                Link(NSLocalizedString("TRANSLATION_GET_KEY"), destination: URL(string: "https://platform.openai.com/api-keys")!)
            }
        } header: {
            Text(NSLocalizedString("TRANSLATION_PROVIDER"))
        } footer: {
            if settings.provider == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("TRANSLATION_CUSTOM_HELP"))
                    if let endpoint = try? TranslationEndpointPolicy.endpoint(for: settings.configuration) {
                        Text(endpoint.absoluteString).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionTestRows: some View {
        Button(action: testConnection) {
            HStack {
                Text(NSLocalizedString(connectionTest.state == .running ? "TRANSLATION_TEST_RUNNING" : "TRANSLATION_TEST"))
                Spacer()
                if connectionTest.state == .running { ProgressView() }
            }
        }
        .disabled(connectionTest.state == .running)
        .accessibilityIdentifier("translation.test")
        switch connectionTest.state {
        case .success(let translated):
            VStack(alignment: .leading, spacing: 6) {
                Label(NSLocalizedString("TRANSLATION_TEST_SUCCESS"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(translated).font(.footnote).textSelection(.enabled)
                imageSupportNotice
            }
            .accessibilityIdentifier("translation.test.success")
        case .failure(let error):
            VStack(alignment: .leading, spacing: 6) {
                Label(NSLocalizedString("TRANSLATION_TEST_FAILURE"), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .accessibilityIdentifier("translation.test.failure")
        case .idle, .running:
            EmptyView()
        }
        Text(NSLocalizedString("TRANSLATION_TEST_HELP"))
            .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var imageSupportNotice: some View {
        if imageSupportStatus == .unsupported {
            Label(NSLocalizedString("TRANSLATION_IMAGE_UNSUPPORTED"), systemImage: "photo.badge.exclamationmark")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("translation.imageUnsupported")
        }
    }

    private func refreshImageSupport() {
        imageSupportStatus = TranslationImageSupport.shared.status(for: settings.configuration)
    }

    private func testConnection() {
        let testedSettings = settings
        publishPendingChange()
        connectionTest.start(settings: testedSettings, apiKey: "") { result in
            // Only apply results to the same persisted configuration and credential.
            let saved = ReaderTranslationSettings()
            guard testedSettings.configuration == saved.configuration,
                  testedSettings.sourceLanguage == saved.sourceLanguage,
                  testedSettings.targetLanguage == saved.targetLanguage else { return }
            switch result {
            case .success:
                ReaderTranslationAPIValidator.shared.recordSuccess(settings: testedSettings)
            case .failure(let error):
                ReaderTranslationAPIValidator.shared.recordFailure(error, settings: testedSettings)
            }
        }
    }

    private var overlaySection: some View {
        Section {
            Toggle(isOn: persistedSettings.overlay.preserveSourceTextColor) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("TRANSLATION_SOURCE_TEXT_COLOR"))
                    Text(NSLocalizedString("TRANSLATION_SOURCE_TEXT_COLOR_HELP"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: persistedSettings.overlay.preserveSourceBackgroundColor) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("TRANSLATION_SOURCE_BACKGROUND_COLOR"))
                    Text(NSLocalizedString("TRANSLATION_SOURCE_BACKGROUND_COLOR_HELP"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker(NSLocalizedString("TRANSLATION_SURFACE"), selection: persistedSettings.overlay.colorMode) {
                Text(NSLocalizedString("TRANSLATION_WHITE")).tag(IPhoneOverlayColorMode.white)
                Text(NSLocalizedString("TRANSLATION_DARK")).tag(IPhoneOverlayColorMode.dark)
                Text(NSLocalizedString("TRANSLATION_AUTO")).tag(IPhoneOverlayColorMode.automatic)
            }
            HStack {
                Text(NSLocalizedString("TRANSLATION_OPACITY"))
                Spacer()
                Text(settings.overlay.opacity, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary)
            }
            Slider(value: persistedSettings.overlay.opacity, in: 0.2...1, step: 0.01)
            Picker(NSLocalizedString("TRANSLATION_EXPANSION"), selection: persistedSettings.overlay.expansionPolicy) {
                Text(NSLocalizedString("TRANSLATION_PANEL_BOUNDS")).tag(IPhoneOverlayExpansionPolicy.panelConstrained)
                Text(NSLocalizedString("TRANSLATION_SOURCE_BOUNDS")).tag(IPhoneOverlayExpansionPolicy.sourceBounds)
                Text(NSLocalizedString("TRANSLATION_UNRESTRICTED")).tag(IPhoneOverlayExpansionPolicy.unrestricted)
            }
            Picker(NSLocalizedString("TRANSLATION_FONT_SIZE"), selection: persistedSettings.overlay.fontSizing) {
                Text(NSLocalizedString("TRANSLATION_AUTO_FIT")).tag(IPhoneOverlayFontSizing.autoFit)
                Text(NSLocalizedString("TRANSLATION_FIXED")).tag(IPhoneOverlayFontSizing.fixed)
            }
            if settings.overlay.fontSizing == .fixed {
                Stepper("\(settings.overlay.fixedFontSizePoints) pt", value: persistedSettings.overlay.fixedFontSizePoints, in: 8...64)
            }
        } header: {
            Text(NSLocalizedString("TRANSLATION_OVERLAY"))
        } footer: {
            Text(NSLocalizedString("TRANSLATION_OVERLAY_HELP"))
        }
    }

    private var notices: String {
        guard let url = Bundle.main.url(forResource: "OCR-TRANSLATION-NOTICES", withExtension: "txt") else {
            return "OCR and translation engine (MIT), PaddleOCR (Apache 2.0)"
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // Persist in the binding setter, including edits made in pushed filter views.
    // Clear the key field synchronously when switching its server account.
    private var persistedSettings: Binding<ReaderTranslationSettings> {
        Binding(get: { settings }, set: { value in
            let accountChanged = settings.selectedCredentialAccount != value.selectedCredentialAccount
            settings = value
            if accountChanged {
                apiKey = ""
                refreshCredential()
            }
            autosave()
        })
    }

    private var persistedAPIKey: Binding<String> {
        Binding(get: { apiKey }, set: { value in
            apiKey = value
            autosave(apiKey: value)
        })
    }

    private func autosave(apiKey: String = "") {
        do {
            try settings.autosave(apiKey: apiKey)
            settings.credentialGeneration = ReaderTranslationSettings().credentialGeneration
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasKey = true }
            // Preferences are already durable; only debounce expensive reader/API updates.
            pendingChange?.cancel()
            pendingChange = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
                publishPendingChange()
            }
        } catch { message = error.localizedDescription }
    }

    private func publishPendingChange() {
        guard pendingChange != nil else { return }
        pendingChange?.cancel()
        pendingChange = nil
        NotificationCenter.default.post(name: ReaderTranslationSettings.changed, object: nil)
    }

    private func deleteKey() {
        do {
            connectionTest.reset()
            try settings.deleteKey()
            hasKey = false
            apiKey = ""
        } catch { message = error.localizedDescription }
    }

    private func refreshCredential() {
        hasKey = false
        do {
            hasKey = try KeychainTranslationCredentialStore().containsSecret(for: settings.selectedCredentialAccount)
        } catch { message = error.localizedDescription }
    }
}
