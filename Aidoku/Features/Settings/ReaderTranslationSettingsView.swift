import SwiftUI

struct ReaderTranslationSettingsView: View {
    @State private var settings = ReaderTranslationSettings()
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var cachedBytes: Int64 = 0
    @State private var clearingCache = false
    @StateObject private var connectionTest = ReaderTranslationConnectionTest()
    @FocusState private var keyFocused: Bool
    @State private var pendingChange: Task<Void, Never>?
    @State private var autoCheck: Task<Void, Never>?

    private let languages: [(String, String)] = [
        ("ko", "한국어"), ("en", "English"), ("ja", "日本語"), ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
        ("pt", "Português"), ("it", "Italiano"), ("ru", "Русский"), ("vi", "Tiếng Việt")
    ]

    var body: some View {
        List {
            translateSection
            providerSection
            requestSection
            cacheSection
        }
        .navigationTitle(NSLocalizedString("TRANSLATION_TITLE"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshCredential() }
        .task { cachedBytes = (try? await ReaderTranslationDiskCache.shared.statistics().bytes) ?? 0 }
        .onDisappear {
            saveKey()
            publishPendingChange()
            connectionTest.reset()
        }
        // Each provider change re-checks the connection once editing pauses.
        .onChange(of: settings.configuration) { _ in scheduleConnectionCheck() }
        .onChange(of: settings.sourceLanguage) { _ in connectionTest.reset() }
        .onChange(of: settings.targetLanguage) { _ in connectionTest.reset() }
        .onChange(of: apiKey) { _ in connectionTest.reset() }
        // Like Aidoku text settings, save the key when the field loses focus.
        .onChange(of: keyFocused) { focused in
            guard !focused else { return }
            let typed = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            saveKey()
            if typed { scheduleConnectionCheck() }
        }
        .alert(NSLocalizedString("TRANSLATION_TITLE"), isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button(NSLocalizedString("OK"), role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private typealias AppTextKind = (key: String, isOn: WritableKeyPath<ReaderTranslationSettings, Bool>, id: String)

    private static let appTextKinds: [AppTextKind] = [
        ("TRANSLATION_SHORT_MANGA_TITLES", \.translateMangaTitles, "translation.mangaTitles"),
        ("TRANSLATION_SHORT_CHAPTER_TITLES", \.translateChapterTitles, "translation.chapterTitles"),
        ("TRANSLATION_SHORT_AUTHORS", \.translateAuthors, "translation.authors"),
        ("TRANSLATION_SHORT_TAGS", \.translateMangaTags, "translation.mangaTags"),
        ("TRANSLATION_SHORT_DESCRIPTIONS", \.translateMangaDescriptions, "translation.mangaDescriptions"),
        ("TRANSLATION_SHORT_SOURCE_LABELS", \.translateSourceLabels, "translation.sourceLabels"),
    ]

    /// Everything that gets translated, then the language it is translated into: pages first,
    /// then metadata (titles, names, tags, descriptions and source menus, in any source language).
    private var translateSection: some View {
        Section {
            Toggle(NSLocalizedString("TRANSLATION_AUTOMATIC"), isOn: persistedSettings.translatePages)
                .accessibilityIdentifier("translation.automatic")
            ForEach(Self.appTextKinds.indices, id: \.self) { index in
                let kind = Self.appTextKinds[index]
                Toggle(NSLocalizedString(kind.key), isOn: persistedSettings[dynamicMember: kind.isOn])
                    .accessibilityIdentifier(kind.id)
                if kind.isOn == \ReaderTranslationSettings.translateSourceLabels, settings.translateSourceLabels {
                    Toggle(NSLocalizedString("TRANSLATION_LARGE_FILTER_OPTIONS"), isOn: persistedSettings.translateLargeFilterOptions)
                        .accessibilityIdentifier("translation.largeFilterOptions")
                }
            }
            Picker(NSLocalizedString("TRANSLATION_TARGET"), selection: persistedSettings.targetLanguage) {
                ForEach(languages, id: \.0) { code, title in Text(title).tag(code) }
            }
        } header: {
            Text(NSLocalizedString("TRANSLATION_ALSO"))
        }
    }

    private var concurrencyChoices: [Int] { Array(1...PipelinePerformanceProfile.current.providerConcurrencyCap) }

    // Shows the effective value; larger saved values are capped by the device anyway.
    private var concurrency: Binding<Int> {
        Binding(get: { min(settings.maximumConcurrentRequests, concurrencyChoices.last ?? 1) },
                set: { persistedSettings.wrappedValue.maximumConcurrentRequests = $0 })
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

    /// Aidoku text row: title on the left, value field right-aligned in the secondary color.
    private func textRow(_ key: String, text: Binding<String>, placeholder: String, id: String, url: Bool = false) -> some View {
        HStack {
            Text(NSLocalizedString(key)).lineLimit(1)
            Spacer()
            TextField(placeholder, text: text)
                .foregroundStyle(Color.secondaryLabel)
                .multilineTextAlignment(.trailing)
                .keyboardType(url ? .URL : .default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(id)
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
                        if #available(iOS 18.0, *) { await ReaderTranslationPipelineService.shared.clearMemory() }
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

    @ViewBuilder
    // Request tuning sits in its own section right below the provider it belongs to.
    private var requestSection: some View {
        Section {
            Picker(NSLocalizedString("TRANSLATION_API_FORMAT"), selection: persistedSettings.custom.apiProtocol) {
                Text("Responses").tag(RemoteTranslationProtocol.responses)
                Text("Chat Completions").tag(RemoteTranslationProtocol.chatCompletions)
            }
            .accessibilityIdentifier("translation.apiProtocol")
            Picker(NSLocalizedString("TRANSLATION_REASONING"), selection: persistedSettings.reasoningEffort) {
                ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                    Text(reasoningTitle(effort)).tag(effort)
                }
            }
            .accessibilityIdentifier("translation.reasoning")
            Picker(NSLocalizedString("TRANSLATION_CONCURRENCY"), selection: concurrency) {
                ForEach(concurrencyChoices, id: \.self) { Text(String($0)).tag($0) }
            }
        } header: {
            Text(NSLocalizedString("TRANSLATION_REQUEST_OPTIONS"))
        }
    }

    private var providerSection: some View {
        Section {
            textRow("TRANSLATION_BASE_URL", text: persistedSettings.custom.baseURL,
                    placeholder: ReaderCustomTranslationSettings.openAIBaseURL, id: "translation.baseURL", url: true)
            textRow("TRANSLATION_MODEL", text: persistedSettings.model, placeholder: NSLocalizedString("TRANSLATION_REQUIRED"), id: "translation.model")
            HStack {
                Text(NSLocalizedString("TRANSLATION_KEY")).lineLimit(1)
                Spacer()
                SecureField(hasKey ? NSLocalizedString("TRANSLATION_KEY_SAVED") : (settings.provider == .openAI ? "sk-…" : ""), text: persistedAPIKey)
                    .foregroundStyle(Color.secondaryLabel)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($keyFocused)
                    .onSubmit(saveKey)
                    .accessibilityIdentifier("translation.apiKey")
            }
            // Typing a new key replaces the saved one; swipe the row to delete it.
            .swipeActions {
                if hasKey {
                    Button(NSLocalizedString("TRANSLATION_KEY_DELETE"), role: .destructive, action: deleteKey)
                }
            }
            connectionTestRows
        } header: {
            Text(NSLocalizedString("TRANSLATION_PROVIDER"))
        }
    }

    @ViewBuilder
    private var connectionTestRows: some View {
        // The section's only action keeps the accent colour; the trailing icon carries the result.
        Button(action: testConnection) {
            HStack {
                Text(NSLocalizedString(connectionTest.state == .running ? "TRANSLATION_TEST_RUNNING" : "TRANSLATION_TEST"))
                Spacer()
                switch connectionTest.state {
                case .running: ProgressView()
                case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                case .idle: EmptyView()
                }
            }
        }
        .disabled(connectionTest.state == .running)
        .accessibilityIdentifier("translation.test")
        switch connectionTest.state {
        case .success(let translated):
            Text(translated).font(.footnote).textSelection(.enabled)
                .accessibilityLabel(NSLocalizedString("TRANSLATION_TEST_SUCCESS") + ", " + translated)
                .accessibilityIdentifier("translation.test.success")
        case .failure(let error):
            Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                .accessibilityLabel(NSLocalizedString("TRANSLATION_TEST_FAILURE") + ", " + error)
                .accessibilityIdentifier("translation.test.failure")
        case .idle, .running:
            EmptyView()
        }
    }

    private func scheduleConnectionCheck() {
        connectionTest.reset()
        autoCheck?.cancel()
        autoCheck = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, hasKey, !keyFocused else { return }
            testConnection()
        }
    }

    private func testConnection() {
        saveKey()
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
        Binding(get: { apiKey }, set: { apiKey = $0 })
    }

    private func saveKey() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        autosave(apiKey: apiKey)
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


