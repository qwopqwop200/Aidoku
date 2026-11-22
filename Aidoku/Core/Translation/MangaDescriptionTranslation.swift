import SwiftUI

enum SynopsisChunking {
    /// Exact source slices; an oversized indivisible link/grapheme returns the original as one chunk.
    static func chunks(_ text: String, maximumBytes: Int) -> [String] {
        precondition(maximumBytes > 0)
        guard !text.isEmpty else { return [] }
        let protected = protectedRanges(in: text, maximumBytes: maximumBytes)
        var rangeIndex = 0
        var start = text.startIndex
        var result: [String] = []
        while start < text.endIndex {
            var cursor = start
            var bytes = 0
            var safeEnd = start
            var preferredEnd: String.Index?
            while cursor < text.endIndex {
                let character = text[cursor]
                bytes += String(character).utf8.count
                let next = text.index(after: cursor)
                if bytes > maximumBytes { break }
                while rangeIndex < protected.count, protected[rangeIndex].upperBound <= next {
                    rangeIndex += 1
                }
                let insideLink = rangeIndex < protected.count &&
                    protected[rangeIndex].lowerBound < next && next < protected[rangeIndex].upperBound
                if !insideLink {
                    safeEnd = next
                    if character.isWhitespace || ".!?;,:。！？；，、".contains(character) {
                        preferredEnd = next
                    }
                }
                cursor = next
            }
            guard safeEnd > start else { return [text] }
            let end = cursor == text.endIndex ? cursor : (preferredEnd ?? safeEnd)
            result.append(String(text[start..<end]))
            start = end
            // A preferred boundary can precede ranges visited while looking ahead.
            while rangeIndex > 0, protected[rangeIndex - 1].upperBound > start { rangeIndex -= 1 }
        }
        return result
    }

    private static func protectedRanges(in text: String, maximumBytes: Int) -> [Range<String.Index>] {
        // Bare URLs, autolinks and angle-delimited Markdown destinations.
        let pattern = #"(?im)(?:[a-z][a-z0-9+.-]*:|www\.)[^\s<>]+|<[^<>\r\n]+>|^[ \t]{0,3}\[[^\]\r\n]+\]:[ \t]*([^\s<>]+)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var ranges = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match -> Range<String.Index>? in
                guard let range = Range(match.range, in: text) else { return nil }
                // Reference labels, like inline labels, need not be indivisible.
                if text[range].utf8.count > maximumBytes, match.range(at: 1).location != NSNotFound {
                    return Range(match.range(at: 1), in: text)
                }
                return range
            }
        var cursor = text.startIndex
        var openings: [String.Index] = []
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            if text[cursor] == "\\" {
                cursor = next < text.endIndex ? text.index(after: next) : next
                continue
            }
            if text[cursor] == "[" { openings.append(cursor) }
            let opening = text[cursor] == "]" ? openings.popLast() : nil
            guard text[cursor] == "]", next < text.endIndex, text[next] == "(" else {
                cursor = next
                continue
            }
            var end = text.index(after: next)
            var depth = 1
            while end < text.endIndex, depth > 0 {
                let character = text[end]
                end = text.index(after: end)
                if character == "\\", end < text.endIndex {
                    end = text.index(after: end)
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                }
            }
            if depth == 0 {
                let link = (opening ?? cursor)..<end
                // A bare-URL match can include the closing ')'; use the Markdown range instead.
                ranges.removeAll { $0.overlaps(next..<end) }
                if text[link].utf8.count <= maximumBytes {
                    ranges.append(link)
                } else {
                    // A long label/title is splittable; only its destination is indivisible.
                    let content = text.index(after: next)..<text.index(before: end)
                    if let destination = text.range(of: #"^(?:<[^>]*>|(?:\\.|[^\s])+)"#,
                                                    options: .regularExpression, range: content) {
                        ranges.append(destination)
                    }
                }
            }
            cursor = depth == 0 ? end : next
        }
        var merged: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// Translate the complete synopsis, keeping each request within the API segment limit.
enum MangaDescriptionTranslation {
    /// Repair escaped newlines and the source metadata typo " /nLabel:" without changing URL paths.
    static func normalizedLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+/n(?=[^/\s:]{1,32}:)"#, with: "\n", options: .regularExpression)
    }

    static func chunks(_ text: String) -> [String] {
        SynopsisChunking.chunks(text, maximumBytes: RemoteTranslationRequest.maximumSegmentTextBytes)
    }

    static func translate(_ original: String, settings: ReaderTranslationSettings,
                          service: ReaderTranslationService = .shared,
                          diskCache: ReaderTranslationDiskCache = .shared) async -> String {
        let original = normalizedLineBreaks(original)
        guard settings.translateMangaDescriptions else { return original }
        // Keep every source line boundary outside model output, including empty lines.
        let paragraphs = original.components(separatedBy: "\n")
        var translated = paragraphs
        let nonempty = paragraphs.enumerated().filter {
            !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { (index: $0.offset, paragraph: $0.element) }
        let results = await MetadataTranslationTaskWindow.map(nonempty, fallback: { $0.paragraph }) { item in
            let pieces = chunks(item.paragraph)
            guard pieces.allSatisfy({ $0.utf8.count <= RemoteTranslationRequest.maximumSegmentTextBytes }) else {
                return item.paragraph
            }
            var result = ""
            for chunk in pieces {
                guard !Task.isCancelled else { return item.paragraph }
                result += await TitleTranslation.translate(chunk, kind: .description, settings: settings,
                    service: service, diskCache: diskCache)
            }
            return result
        }
        for (item, result) in zip(nonempty, results) { translated[item.index] = result }
        return Task.isCancelled ? original : normalizedLineBreaks(translated.joined(separator: "\n"))
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
        let fallback = MangaDescriptionTranslation.normalizedLineBreaks(original)
        ExpandableTextView(text: translatedIdentity == identity ? (translation ?? fallback) : fallback, expanded: $expanded)
            .task(id: identity) {
                let requestedIdentity = identity
                let result = await MangaDescriptionTranslation.translate(original, settings: ReaderTranslationSettings())
                guard !Task.isCancelled else { return }
                translation = result
                translatedIdentity = requestedIdentity
            }
            .onReceive(NotificationCenter.default.publisher(for: ReaderTranslationSettings.changed).receive(on: DispatchQueue.main)) { _ in
                translation = nil
                revision = UUID()
            }
    }
}
