import SwiftUI

/// Resolve strings on the visible menu owner: native Menu rows do not reliably run SwiftUI tasks.
enum SourceMenuTranslation {
    static let maximumTranslatedOptions = 100

    static func translatesOptions(count: Int, includeLargeLists: Bool = false) -> Bool {
        includeLargeLists || count <= maximumTranslatedOptions
    }

    static func labelsToTranslate(options: [String], title: String? = nil, includeLargeLists: Bool = false) -> [String] {
        let headings = [title].compactMap { $0 }
        return translatesOptions(count: options.count, includeLargeLists: includeLargeLists) ? headings + options : headings
    }

    static func translate(_ originals: [String], settings: ReaderTranslationSettings, kind: TitleTranslationKind = .sourceLabel,
                          service: ReaderTranslationService = .shared,
                          diskCache: ReaderTranslationDiskCache = .shared) async -> [String: String] {
        guard kind.isEnabled(in: settings) else { return [:] }
        return await withTaskGroup(of: (String, String).self) { group in
            for original in Set(originals) where !original.isEmpty {
                group.addTask {
                    (original, await TitleTranslation.translate(original, kind: kind, settings: settings,
                        service: service, diskCache: diskCache))
                }
            }
            var result: [String: String] = [:]
            for await (original, translated) in group { result[original] = translated }
            return result
        }
    }
}

struct SourceMenuTranslationModifier: ViewModifier {
    let originals: [String]
    @Binding var labels: [String: String]
    var limitsOptions = false
    var filterTitle: String?
    var optionKind: TitleTranslationKind = .sourceLabel
    @State private var revision = UUID()
    private var identity: String { revision.uuidString + ReaderTranslationCacheIdentity.encoded(originals + [filterTitle ?? "", String(limitsOptions), optionKind.rawValue]) }

    func body(content: Content) -> some View {
        content
            .task(id: identity) {
                let settings = ReaderTranslationSettings()
                let requested = limitsOptions
                    ? SourceMenuTranslation.labelsToTranslate(options: originals,
                        includeLargeLists: settings.translateLargeFilterOptions)
                    : originals
                // Submit and display the section heading before its potentially
                // large tag/option list; queue priority alone cannot fix a late submission.
                let headings = await SourceMenuTranslation.translate([filterTitle].compactMap { $0 }, settings: settings)
                guard !Task.isCancelled else { return }
                labels.merge(headings) { _, heading in heading }
                var translated = await SourceMenuTranslation.translate(requested, settings: settings, kind: optionKind)
                guard !Task.isCancelled else { return }
                translated.merge(headings) { _, heading in heading }
                labels = translated
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed)) { _ in
                labels = [:]
                revision = UUID()
            }
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
