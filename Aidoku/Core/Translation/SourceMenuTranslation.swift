import SwiftUI

/// Resolve strings on the visible menu owner: native Menu rows do not reliably run SwiftUI tasks.
enum SourceMenuTranslation {
    static let maximumTranslatedOptions = 100

    static func translatesOptions(count: Int, includeLargeLists: Bool) -> Bool {
        includeLargeLists || count <= maximumTranslatedOptions
    }

    static func translate(_ originals: [String], settings: ReaderTranslationSettings, kind: TitleTranslationKind = .sourceLabel,
                          service: ReaderTranslationService = .shared,
                          diskCache: ReaderTranslationDiskCache = .shared) async -> [String: String] {
        guard kind.isEnabled(in: settings) else { return [:] }
        let unique = Array(Set(originals).filter { !$0.isEmpty })
        let translated = await MetadataTranslationTaskWindow.map(unique, fallback: { $0 }) { original in
            await TitleTranslation.translate(original, kind: kind, settings: settings,
                service: service, diskCache: diskCache)
        }
        return Dictionary(uniqueKeysWithValues: zip(unique, translated))
    }
}

struct SourceMenuTranslationModifier: ViewModifier {
    let originals: [String]
    @Binding var labels: [String: String]
    var limitsOptions = false
    var filterTitle: String?
    var optionKind: TitleTranslationKind = .sourceLabel
    @State private var revision = UUID()
    @State private var requestIdentity: [String?]?
    private var identity: String { revision.uuidString + ReaderTranslationCacheIdentity.encoded(originals + [filterTitle ?? "", String(limitsOptions), optionKind.rawValue]) }

    func body(content: Content) -> some View {
        content
            .task(id: identity) {
                let settings = ReaderTranslationSettings()
                if requestIdentity != settingsIdentity(settings) { requestIdentity = settingsIdentity(settings) }
                let skipsOptions = limitsOptions && !SourceMenuTranslation.translatesOptions(
                    count: originals.count, includeLargeLists: settings.translateLargeFilterOptions)
                let requested = skipsOptions ? [] : originals
                // Submit and display the section heading before its potentially large option list.
                let headings = await SourceMenuTranslation.translate([filterTitle].compactMap { $0 }, settings: settings)
                guard !Task.isCancelled else { return }
                labels.merge(headings) { _, heading in heading }
                var translated = await SourceMenuTranslation.translate(requested, settings: settings, kind: optionKind)
                guard !Task.isCancelled else { return }
                translated.merge(headings) { _, heading in heading }
                labels = translated
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed).receive(on: DispatchQueue.main)) { _ in
                if let requestIdentity, requestIdentity == settingsIdentity(ReaderTranslationSettings()) { return }
                labels = [:]
                revision = UUID()
            }
    }

    private func settingsIdentity(_ settings: ReaderTranslationSettings) -> [String?] {
        [TitleTranslation.settingsIdentity(kind: .sourceLabel, settings: settings),
         TitleTranslation.settingsIdentity(kind: optionKind, settings: settings), String(settings.translateLargeFilterOptions)]
    }
}

/// Count the complete source list, never the currently visible or searched subset.
struct SourceFilterOptionText: View {
    let original: String
    let totalOptionCount: Int
    var kind: TitleTranslationKind = .sourceLabel
    @AppStorage("Reader.translation.largeFilterOptions") private var includeLargeLists = false

    var body: some View {
        if SourceMenuTranslation.translatesOptions(count: totalOptionCount, includeLargeLists: includeLargeLists) {
            TranslatedTitleText(original, kind: kind)
        } else {
            Text(original)
        }
    }
}
