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
            languageSection
            pageTranslationSection
            translationTargetsSection
            providerSection
            translationOptionsSection
            cacheSection
        }
        .navigationTitle(NSLocalizedString("TRANSLATION_TITLE"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshCredential() }
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

    // The page pipeline always uses the manga recognizer and its language set.
    private let allOCRSourceLanguagesTitle = NSLocalizedString("TRANSLATION_OCR_SUPPORTED_LANGUAGES")

    private var languageSection: some View {
        Section(NSLocalizedString("TRANSLATION_LANGUAGE")) {
            Picker(NSLocalizedString("TRANSLATION_TARGET"), selection: persistedSettings.targetLanguage) {
                ForEach(languages, id: \.0) { code, title in Text(title).tag(code) }
            }
            Picker(NSLocalizedString("TRANSLATION_PAGE_SOURCE"), selection: persistedSettings.sourceLanguage) {
                Text(NSLocalizedString("TRANSLATION_AUTO")).tag("auto")
                ForEach(ReaderTranslationLanguageOptions.codes.filter { settings.supportedOCRSourceLanguageCodes.contains($0) }, id: \.self) { code in
                    Text(ReaderTranslationLanguageOptions.name(code)).tag(code == "zh" ? "zh-Hans" : code)
                }
            }
            if settings.sourceLanguage == "auto" {
                NavigationLink {
                    ReaderTranslationLanguageFilterView(selection: persistedSettings.translationSourceLanguages,
                        help: NSLocalizedString("TRANSLATION_OCR_MANGA_HELP"),
                        allowedCodes: settings.supportedOCRSourceLanguageCodes,
                        allTitle: allOCRSourceLanguagesTitle)
                } label: {
                    filterLabel("TRANSLATION_SOURCE_FILTER", settings.translationSourceLanguages, allTitle: allOCRSourceLanguagesTitle)
                }
                .accessibilityIdentifier("translation.sourceFilter")
            } else {
                Text(NSLocalizedString("TRANSLATION_FIXED_SOURCE_FILTER_HELP"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var translationTargetsSection: some View {
        Section {
            targetRows("TRANSLATION_MANGA_TITLES", \.translateMangaTitles, id: "translation.mangaTitles",
                       filter: "TRANSLATION_MANGA_TITLE_FILTER", \.mangaTitleSourceLanguages, filterID: "translation.mangaTitleFilter")
            targetRows("TRANSLATION_CHAPTER_TITLES", \.translateChapterTitles, id: "translation.chapterTitles",
                       filter: "TRANSLATION_CHAPTER_TITLE_FILTER", \.chapterTitleSourceLanguages, filterID: "translation.chapterTitleFilter")
            targetRows("TRANSLATION_AUTHORS", \.translateAuthors, id: "translation.authors",
                       filter: "TRANSLATION_AUTHOR_FILTER", \.authorSourceLanguages, filterID: "translation.authorFilter")
            targetRows("TRANSLATION_MANGA_TAGS", \.translateMangaTags, id: "translation.mangaTags",
                       filter: "TRANSLATION_TAG_FILTER", \.mangaTagSourceLanguages, filterID: "translation.tagFilter")
            targetRows("TRANSLATION_MANGA_DESCRIPTIONS", \.translateMangaDescriptions, id: "translation.mangaDescriptions",
                       filter: "TRANSLATION_DESCRIPTION_FILTER", \.mangaDescriptionSourceLanguages, filterID: "translation.descriptionFilter")
            targetRows("TRANSLATION_SOURCE_LABELS", \.translateSourceLabels, id: "translation.sourceLabels",
                       filter: "TRANSLATION_SOURCE_LABEL_FILTER", \.sourceLabelSourceLanguages, filterID: "translation.sourceLabelFilter")
            Toggle(NSLocalizedString("TRANSLATION_LARGE_FILTER_OPTIONS"), isOn: persistedSettings.translateLargeFilterOptions)
                .accessibilityIdentifier("translation.largeFilterOptions")
        } header: {
            Text(NSLocalizedString("TRANSLATION_TARGETS"))
        } footer: {
            Text(NSLocalizedString("TRANSLATION_TITLES_HELP"))
        }
    }

    private var pageTranslationSection: some View {
        Section {
            toggleWithHelp("TRANSLATION_AUTOMATIC", isOn: persistedSettings.automaticallyTranslate,
                           id: "translation.automatic", help: "TRANSLATION_AUTOMATIC_HELP")
            toggleWithHelp("TRANSLATION_BACKGROUND", isOn: persistedSettings.translateInBackground,
                           id: "translation.background", help: "TRANSLATION_BACKGROUND_HELP")
            Picker(NSLocalizedString("TRANSLATION_PRETRANSLATION_LIMIT"), selection: persistedSettings.maximumPretranslatedPages) {
                Text(NSLocalizedString("TRANSLATION_UNLIMITED")).tag(Optional<Int>.none)
                Text(NSLocalizedString("TRANSLATION_VISIBLE_PAGES_ONLY")).tag(Optional(0))
                ForEach([1, 2, 3, 5, 10, 20, 50, 100], id: \.self) { count in
                    Text(count, format: .number).tag(Optional(count))
                }
            }
            .accessibilityIdentifier("translation.pretranslationLimit")
        } header: {
            Text(NSLocalizedString("TRANSLATION_PAGE_SETTINGS"))
        } footer: {
            Text(NSLocalizedString("TRANSLATION_PRETRANSLATION_LIMIT_HELP"))
        }
    }

    private var translationOptionsSection: some View {
        Section {
            Picker(NSLocalizedString("TRANSLATION_REASONING"), selection: persistedSettings.reasoningEffort) {
                ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                    Text(reasoningTitle(effort)).tag(effort)
                }
            }
            .accessibilityIdentifier("translation.reasoning")
            Picker(NSLocalizedString("TRANSLATION_CONCURRENCY"), selection: persistedSettings.maximumConcurrentRequests) {
                ForEach([1, 2, 4, 8, 16], id: \.self) { Text(String($0)).tag($0) }
            }
        } header: {
            Text(NSLocalizedString("TRANSLATION_ADVANCED"))
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

    @ViewBuilder
    private func targetRows(
        _ key: String, _ isOn: WritableKeyPath<ReaderTranslationSettings, Bool>, id: String,
        filter filterKey: String, _ languages: WritableKeyPath<ReaderTranslationSettings, [String]>, filterID: String
    ) -> some View {
        Toggle(NSLocalizedString(key), isOn: persistedSettings[dynamicMember: isOn]).accessibilityIdentifier(id)
        let selection = persistedSettings[dynamicMember: languages]
        NavigationLink {
            ReaderTranslationLanguageFilterView(selection: selection, title: NSLocalizedString(filterKey),
                help: NSLocalizedString("TRANSLATION_METADATA_FILTER_HELP"), accessibilityPrefix: filterID)
        } label: {
            filterLabel(filterKey, selection.wrappedValue, allTitle: NSLocalizedString("TRANSLATION_FILTER_ALL"))
        }
        .accessibilityIdentifier(filterID)
    }

    private func filterLabel(_ key: String, _ codes: [String], allTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString(key))
            Text(codes.isEmpty ? allTitle : codes.map(ReaderTranslationLanguageOptions.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func toggleWithHelp(_ key: String, isOn: Binding<Bool>, id: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(NSLocalizedString(key), isOn: isOn).accessibilityIdentifier(id)
            Text(NSLocalizedString(help)).font(.footnote).foregroundStyle(.secondary)
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
                        try await ReaderTranslationDiskCache.shared.clear()
                        try await ReaderTranslationService.shared.clearCache()
                        if #available(iOS 18.0, *) { await ReaderTranslationV2Service.shared.clearMemory() }
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
        connectionTest.start(settings: testedSettings, apiKey: "")
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
