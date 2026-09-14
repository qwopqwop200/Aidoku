import SwiftUI

/// Preserve the complete synopsis while keeping each request within the API segment limit.
enum MangaDescriptionTranslation {
    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > 12_000, !current.isEmpty {
                chunks.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func translate(_ original: String, settings: ReaderTranslationSettings,
                          service: ReaderTranslationService = .shared,
                          diskCache: ReaderTranslationDiskCache = .shared) async -> String {
        guard settings.translateMangaDescriptions else { return original }
        // Paragraph separators stay outside translated content, retaining the source layout.
        let paragraphs = original.components(separatedBy: "\n\n")
        var translated = paragraphs
        await withTaskGroup(of: (Int, String).self) { group in
            for (index, paragraph) in paragraphs.enumerated() where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                group.addTask {
                    var result = ""
                    for chunk in chunks(paragraph) {
                        guard !Task.isCancelled else { return (index, paragraph) }
                        result += await TitleTranslation.translate(chunk, kind: .description, settings: settings,
                            service: service, diskCache: diskCache)
                    }
                    return (index, result)
                }
            }
            for await (index, result) in group { translated[index] = result }
        }
        return Task.isCancelled ? original : translated.joined(separator: "\n\n")
    }
}

struct TranslatedDescriptionView: View {
    let original: String
    @Binding var expanded: Bool
    @State private var revision = UUID()
    @State private var translation: String?
    @State private var translatedIdentity: String?
    private var identity: String { revision.uuidString + original }

    var body: some View {
        ExpandableTextView(text: translatedIdentity == identity ? (translation ?? original) : original, expanded: $expanded)
            .task(id: identity) {
                let requestedIdentity = identity
                let result = await MangaDescriptionTranslation.translate(original, settings: ReaderTranslationSettings())
                guard !Task.isCancelled else { return }
                translation = result
                translatedIdentity = requestedIdentity
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed)) { _ in
                translation = nil
                revision = UUID()
            }
    }
}
