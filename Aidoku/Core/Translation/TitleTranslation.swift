import Combine
import SwiftUI
import UIKit

// BEGIN METADATA PROMPT CONTRACT
enum TitleTranslationKind: String, CaseIterable {
    case manga
    case chapter
    case description
    case tag
    case sourceLabel
    case author

    var instructions: String {
        switch self {
        case .manga, .chapter:
            "Manga/chapter title, not dialogue: translate ordinary words even alongside names; preserve numbering."
        case .description:
            "Manga synopsis: preserve Markdown, line breaks and link destinations."
        case .tag:
            "Manga tag/genre label: conventional terms."
        case .sourceLabel:
            "Source menu/section/filter label: use concise, natural UI wording."
        case .author:
            "Creator names, not dictionary meanings; preserve order and separators."
        }
    }

    func formattedTranslation(_ text: String, original: String) -> String {
        let translated = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self == .description, !translated.isEmpty else { return translated }
        // The codec trims replies; restore source edge whitespace (indentation, breaks, chunk separators).
        let leading = original.prefix(while: \.isWhitespace)
        let trailing = original.reversed().prefix(while: \.isWhitespace).reversed()
        return String(leading) + translated + String(trailing)
    }
}
// END METADATA PROMPT CONTRACT

extension TitleTranslationKind {
    var priority: MetadataTranslationPriority {
        switch self {
        case .sourceLabel: .sourceMenuTitle
        case .manga, .chapter: .mangaTitle
        case .description: .description
        case .author: .author
        case .tag: .tag
        }
    }

    /// `isEnabled` from the one saved key, without loading every setting on the main thread.
    var isSavedEnabled: Bool {
        let keys: [Self: String] = [.manga: "mangaTitles", .chapter: "chapterTitles", .author: "authors",
                                    .sourceLabel: "sourceLabels", .tag: "mangaTags", .description: "mangaDescriptions"]
        return UserDefaults.standard.bool(forKey: ReaderTranslationSettings.keyPrefix + (keys[self] ?? ""))
    }

    func isEnabled(in settings: ReaderTranslationSettings) -> Bool {
        switch self {
        case .manga: settings.translateMangaTitles
        case .chapter: settings.translateChapterTitles
        case .author: settings.translateAuthors
        case .sourceLabel: settings.translateSourceLabels
        case .tag: settings.translateMangaTags
        case .description: settings.translateMangaDescriptions
        }
    }
}

enum TitleTranslation {
    /// SwiftUI retains state when a row changes text or role; keep each input separate.
    static func presentationIdentity(original: String, source: String, kind: TitleTranslationKind, revision: UUID) -> String {
        ReaderTranslationCacheIdentity.encoded([revision.uuidString, kind.rawValue, original, source])
    }

    /// Title detection is independent even when the reader uses a fixed source language.
    static func effectiveSettings(_ settings: ReaderTranslationSettings, kind: TitleTranslationKind) -> ReaderTranslationSettings {
        var result = settings
        result.usesOCRLanguagePolicy = false
        result.sourceLanguage = "auto"
        // Metadata has no page image; inheriting this would reject every uncached request.
        result.includePageImage = false
        // The one source selection (`translationSourceLanguages`) also filters metadata.
        result.metadataInstructions = kind.instructions
        result.filterSFXWithLLM = false
        result.filterBackgroundWithLLM = false
        result.readingDirection = .leftToRight
        return result
    }

    static func cacheKey(_ original: String, kind: TitleTranslationKind, settings: ReaderTranslationSettings) -> String {
        let settings = effectiveSettings(settings, kind: kind)
        let config = settings.configuration
        return ReaderTranslationCacheIdentity.encoded([
            "title-translation-v2-independent-languages", String(TranslationCacheKey.schemaVersion),
            kind.rawValue, original, config.provider.rawValue, config.apiProtocol.rawValue,
            config.baseURL, config.model, config.credentialAccount, String(config.credentialGeneration),
            config.reasoningEffort.rawValue, config.instructions, settings.sourceLanguage, settings.targetLanguage
        ] + (ReaderTranslationLanguageFilter.identity(settings: settings) ?? []))
    }

    /// Settings inputs of a displayed translation (nil when disabled); other changes keep the result.
    static func settingsIdentity(kind: TitleTranslationKind, settings: ReaderTranslationSettings) -> String? {
        kind.isEnabled(in: settings) ? cacheKey("", kind: kind, settings: settings) : nil
    }

    static func translate(
        _ original: String, kind: TitleTranslationKind, settings: ReaderTranslationSettings,
        service: ReaderTranslationService = .shared, diskCache: ReaderTranslationDiskCache = .shared
    ) async -> String {
        guard kind.isEnabled(in: settings), !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return original
        }
        guard !ReaderTranslationLanguageFilter.isAlreadyTargetLanguage(original, target: settings.targetLanguage) else { return original }
        let generation = await diskCache.currentGeneration(settings: settings, kind: .metadata)
        let settings = effectiveSettings(settings, kind: kind)
        let key = cacheKey(original, kind: kind, settings: settings)
        if let cached = try? await diskCache.regions(for: key, kind: .metadata),
           let region = cached.first, region.source == original,
           let title = region.translation, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !ReaderTranslationLanguageFilter.isUntranslatedJapaneseReply(source: original, translation: title, target: settings.targetLanguage) {
            return Task.isCancelled ? original : kind.formattedTranslation(title, original: original)
        }
        // Cache failures must never hide a successful network translation.
        let region = ReaderTranslationRegion(id: "title", rect: .zero, source: original)
        do {
            let result = try await service.translateMetadata(regions: [region], settings: settings, priority: kind.priority)
            try Task.checkCancellation()
            guard let title = result.first?.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return original }
            try? await diskCache.storeRegions(result, for: key, kind: .metadata, generation: generation)
            return kind.formattedTranslation(title, original: original)
        } catch {
            return original
        }
    }
}

struct TranslatedTitleText: View {
    let original: String
    let kind: TitleTranslationKind
    let source: String
    @State private var revision = UUID()
    @State private var translated: String?
    @State private var translatedIdentity: String?
    @State private var requestSettings: ReaderTranslationSettings?

    init(_ original: String, kind: TitleTranslationKind, translating source: String? = nil) {
        self.original = original
        self.kind = kind
        self.source = source ?? original
    }

    private var identity: String {
        TitleTranslation.presentationIdentity(original: original, source: source, kind: kind, revision: revision)
    }

    var body: some View {
        Text(translatedIdentity == identity ? (translated ?? original) : original)
            .task(id: identity) {
                let requestIdentity = identity
                guard !source.isEmpty, original.contains(source), kind == .description || kind.isSavedEnabled else { return }
                let settings = ReaderTranslationSettings()
                if requestSettings != settings { requestSettings = settings }
                let result = kind == .description
                    ? await MangaDescriptionTranslation.translate(source, settings: settings)
                    : await TitleTranslation.translate(source, kind: kind, settings: settings)
                guard !Task.isCancelled else { return }
                translated = original.replacingOccurrences(of: source, with: result)
                translatedIdentity = requestIdentity
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed).receive(on: DispatchQueue.main)) { _ in
                // Unrelated changes must not cancel and resend in-flight provider requests.
                if let requestSettings, TitleTranslation.settingsIdentity(kind: kind, settings: requestSettings) ==
                    TitleTranslation.settingsIdentity(kind: kind, settings: ReaderTranslationSettings()) { return }
                translated = nil
                revision = UUID()
            }
    }
}

/// Retains the source text across settings changes and ignores results for reused cells.
final class TranslatedTitleLabel: UILabel {
    var kind: TitleTranslationKind = .manga {
        didSet {
            guard kind != oldValue else { return }
            refreshTranslation()
        }
    }
    private var original: String?
    private var translationTask: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?
    private var revision = UUID()
    private var settings: ReaderTranslationSettings?

    override var text: String? {
        get { super.text }
        set {
            // Cell reconfiguration repeats the text; restarting would cancel its provider request.
            guard newValue != original else { return }
            original = newValue
            refreshTranslation()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        observeSettings()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeSettings()
    }

    deinit { translationTask?.cancel() }

    private func observeSettings() {
        // Settings may be saved off the main thread; deliver on main for UILabel.
        settingsObserver = NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsChanged() }
            }
    }

    private func settingsChanged() {
        if let settings, TitleTranslation.settingsIdentity(kind: kind, settings: settings) ==
            TitleTranslation.settingsIdentity(kind: kind, settings: ReaderTranslationSettings()) { return }
        refreshTranslation()
    }

    private func refreshTranslation() {
        translationTask?.cancel()
        revision = UUID()
        super.text = original
        guard let original else { return }
        guard kind.isSavedEnabled else { settings = nil; return }
        let settings = ReaderTranslationSettings()
        self.settings = settings
        guard kind.isEnabled(in: settings) else { return }
        let requestRevision = revision
        let kind = kind
        translationTask = Task { [weak self] in
            let translated = await TitleTranslation.translate(original, kind: kind, settings: settings)
            guard !Task.isCancelled, let self, self.revision == requestRevision else { return }
            self.showTranslation(translated)
        }
    }

    private func showTranslation(_ value: String) { super.text = value }
}
