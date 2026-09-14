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
                Toggle(NSLocalizedString("TRANSLATION_CHAPTER_TITLES"), isOn: persistedSettings.translateChapterTitles)
                    .accessibilityIdentifier("translation.chapterTitles")
            } footer: {
                Text(NSLocalizedString("TRANSLATION_TITLES_HELP"))
            }
            providerSection
            Section(NSLocalizedString("TRANSLATION_ADVANCED")) {
                Picker(NSLocalizedString("TRANSLATION_REASONING"), selection: persistedSettings.reasoningEffort) {
                    ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                        Text(effort == .modelDefault ? NSLocalizedString("TRANSLATION_MODEL_DEFAULT") : effort.rawValue).tag(effort)
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
                Picker(NSLocalizedString("TRANSLATION_SOURCE"), selection: persistedSettings.sourceLanguage) {
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
                    Text("Medium").tag(IPhoneOCRModelTier.medium)
                    Text("Small").tag(IPhoneOCRModelTier.small)
                    Text("Tiny").tag(IPhoneOCRModelTier.tiny)
                }
                Picker(NSLocalizedString("TRANSLATION_DETECTOR_SIZE"), selection: persistedSettings.ocr.detectorMaximumSide) {
                    ForEach([800, 1_200, 1_600, 2_000], id: \.self) { Text(String($0)).tag($0) }
                }
                Picker(NSLocalizedString("TRANSLATION_RECOGNIZER_SIZE"), selection: persistedSettings.ocr.recognizerMaximumWidth) {
                    ForEach([800, 1_200, 1_600, 2_000], id: \.self) { Text(String($0)).tag($0) }
                }
                HStack {
                    Text(NSLocalizedString("TRANSLATION_CONFIDENCE"))
                    Spacer()
                    Text(settings.ocr.confidenceThreshold, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary)
                }
                Slider(value: persistedSettings.ocr.confidenceThreshold, in: 0...1, step: 0.05)
            } footer: {
                Text(NSLocalizedString("TRANSLATION_OCR_HELP"))
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
        .onAppear(perform: refreshCredential)
        .task { cachedBytes = (try? await ReaderTranslationDiskCache.shared.statistics().bytes) ?? 0 }
        .onDisappear {
            publishPendingChange()
            connectionTest.reset()
        }
        .onChange(of: settings.configuration) { _ in connectionTest.reset() }
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
                Text("Custom OpenAI").tag(RemoteTranslationProvider.custom)
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
