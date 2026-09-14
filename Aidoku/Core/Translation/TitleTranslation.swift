import SwiftUI
import UIKit

enum TitleTranslationKind: String {
    case manga
    case chapter

    func isEnabled(in settings: ReaderTranslationSettings) -> Bool {
        switch self {
        case .manga: settings.translateMangaTitles
        case .chapter: settings.translateChapterTitles
        }
    }
}

enum TitleTranslation {
    /// Title detection is independent even when the reader uses a fixed source language.
    static func effectiveSettings(_ settings: ReaderTranslationSettings, kind: TitleTranslationKind) -> ReaderTranslationSettings {
        var result = settings
        result.sourceLanguage = "auto"
        result.translationSourceLanguages = kind == .manga ? settings.mangaTitleSourceLanguages : settings.chapterTitleSourceLanguages
        result.rightToLeftPanelOrder = false
        return result
    }

    static func cacheKey(_ original: String, kind: TitleTranslationKind, settings: ReaderTranslationSettings) -> String {
        let settings = effectiveSettings(settings, kind: kind)
        let config = settings.configuration
        return ReaderTranslationCacheIdentity.encoded([
            "title-translation-v2-independent-languages", kind.rawValue, original, config.provider.rawValue, config.apiProtocol.rawValue,
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
        let settings = effectiveSettings(settings, kind: kind)
        let key = cacheKey(original, kind: kind, settings: settings)
        let generation = await diskCache.currentGeneration()
        if let cached = try? await diskCache.regions(for: key, kind: .translation),
           let region = cached.first, region.source == original,
           let title = region.translation, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Task.isCancelled ? original : title
        }
        // Share the byte limit, eviction and clear generation with the page cache.
        // Cache failures must never hide a successful network translation.
        let region = ReaderTranslationRegion(id: "title", rect: .zero, source: original)
        do {
            let result = try await service.translate(regions: [region], settings: settings)
            try Task.checkCancellation()
            guard let title = result.first?.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return original }
            try? await diskCache.storeRegions(result, for: key, kind: .translation, generation: generation)
            return title
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

    private var identity: String { revision.uuidString + original + source }

    var body: some View {
        Text(translatedIdentity == identity ? (translated ?? original) : original)
            .task(id: identity) {
                let requestIdentity = identity
                guard !source.isEmpty, original.contains(source) else { return }
                let result = await TitleTranslation.translate(source, kind: kind, settings: ReaderTranslationSettings())
                guard !Task.isCancelled else { return }
                translated = original.replacingOccurrences(of: source, with: result)
                translatedIdentity = requestIdentity
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed)) { _ in
                translated = nil
                revision = UUID()
            }
    }
}

/// Retains the source text across settings changes and ignores results for reused cells.
final class TranslatedTitleLabel: UILabel {
    var kind: TitleTranslationKind = .manga
    private var original: String?
    private var translationTask: Task<Void, Never>?
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
        NotificationCenter.default.addObserver(self, selector: #selector(refreshTranslation),
            name: ReaderTranslationSettings.changed, object: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshTranslation),
            name: ReaderTranslationSettings.changed, object: nil)
    }

    deinit { translationTask?.cancel() }

    @objc private func refreshTranslation() {
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
