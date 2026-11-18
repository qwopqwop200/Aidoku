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
        // The codec trims replies. Restore source whitespace outside model control,
        // including Markdown indentation, hard breaks and chunk separators.
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
    /// SwiftUI retains state when a row changes its text or metadata role.
    /// Keep every input separate so an old result cannot match another split.
    static func presentationIdentity(original: String, source: String, kind: TitleTranslationKind, revision: UUID) -> String {
        ReaderTranslationCacheIdentity.encoded([revision.uuidString, kind.rawValue, original, source])
    }

    /// Title detection is independent even when the reader uses a fixed source language.
    static func effectiveSettings(_ settings: ReaderTranslationSettings, kind: TitleTranslationKind) -> ReaderTranslationSettings {
        var result = settings
        result.usesOCRLanguagePolicy = false
        result.sourceLanguage = "auto"
        // Metadata has no reader page to attach. Inheriting this option makes
        // the shared service reject every uncached text request before sending it.
        result.includePageImage = false
        switch kind {
        case .manga: result.translationSourceLanguages = settings.mangaTitleSourceLanguages
        case .chapter: result.translationSourceLanguages = settings.chapterTitleSourceLanguages
        case .author: result.translationSourceLanguages = settings.authorSourceLanguages
        case .sourceLabel: result.translationSourceLanguages = settings.sourceLabelSourceLanguages
        case .tag: result.translationSourceLanguages = settings.mangaTagSourceLanguages
        case .description: result.translationSourceLanguages = settings.mangaDescriptionSourceLanguages
        }
        result.metadataInstructions = kind.instructions
        result.filterSFXWithLLM = false
        result.filterBackgroundWithLLM = false
        result.rightToLeftPanelOrder = false
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
        // Share the byte limit and eviction, but OCR changes must not invalidate metadata.
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
                guard !source.isEmpty, original.contains(source) else { return }
                let result: String
                if kind == .description {
                    result = await MangaDescriptionTranslation.translate(source, settings: ReaderTranslationSettings())
                } else {
                    result = await TitleTranslation.translate(source, kind: kind, settings: ReaderTranslationSettings())
                }
                guard !Task.isCancelled else { return }
                translated = original.replacingOccurrences(of: source, with: result)
                translatedIdentity = requestIdentity
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed).receive(on: DispatchQueue.main)) { _ in
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

    override var text: String? {
        get { super.text }
        set {
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
        // Settings can be persisted by background work. NotificationCenter otherwise
        // delivers on that caller's thread, bypassing UILabel's MainActor isolation.
        settingsObserver = NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTranslation() }
            }
    }

    private func refreshTranslation() {
        translationTask?.cancel()
        revision = UUID()
        super.text = original
        guard let original else { return }
        let settings = ReaderTranslationSettings()
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
