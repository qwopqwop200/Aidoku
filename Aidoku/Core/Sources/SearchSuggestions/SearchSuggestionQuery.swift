import Foundation

struct SearchSuggestion: Decodable, Equatable, Sendable {
    let text: String
    var namespace: String?
    var count: Int?
}

/// Holds the original edit range so selecting a candidate cannot overwrite other terms.
struct SearchSuggestionQuery: Equatable, Sendable {
    let text: String
    let term: String
    let namespace: String?
    let excluded: Bool
    let range: NSRange
    let tokenMode: Bool
    let spaceReplacement: String
    let quoteTokens: Bool

    init?(text: String, selection: NSRange, configuration: SearchSuggestionConfiguration) {
        guard let selectionRange = Range(selection, in: text) else { return nil }
        quoteTokens = configuration.quoteTokens == true
        tokenMode = configuration.queryMode == .token
        spaceReplacement = configuration.tokenSpaceReplacement ?? "_"
        self.text = text

        if tokenMode {
            let caret = selectionRange.lowerBound
            // Only whitespace outside a quoted value separates search tokens.
            var separators = Set<String.Index>()
            var quoted = false
            var escaped = false
            for index in text.indices {
                let character = text[index]
                if quoteTokens && escaped {
                    escaped = false
                } else if quoteTokens && character == "\\" {
                    escaped = true
                } else if quoteTokens && character == "\"" {
                    quoted.toggle()
                } else if character.isWhitespace && !quoted {
                    separators.insert(index)
                }
            }
            var start = caret
            while start > text.startIndex, !separators.contains(text.index(before: start)) {
                start = text.index(before: start)
            }
            var end = selectionRange.upperBound
            while end < text.endIndex, !separators.contains(end) {
                end = text.index(after: end)
            }
            guard start < caret || !selectionRange.isEmpty,
                  !separators.contains(where: { $0 >= start && $0 < end })
            else { return nil }
            range = NSRange(start..<end, in: text)
            var fragment = String(text[start..<selectionRange.upperBound])
            excluded = fragment.hasPrefix("-")
            if excluded { fragment.removeFirst() }
            if let separator = fragment.firstIndex(of: ":") {
                namespace = String(fragment[..<separator]).lowercased()
                fragment = String(fragment[fragment.index(after: separator)...])
            } else {
                namespace = nil
            }
            if quoteTokens && fragment.hasPrefix("\"") {
                fragment.removeFirst()
                if fragment.hasSuffix("\"") { fragment.removeLast() }
                fragment = fragment.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            term = spaceReplacement.isEmpty ? fragment : fragment.replacingOccurrences(of: spaceReplacement, with: " ")
        } else {
            range = NSRange(text.startIndex..<text.endIndex, in: text)
            term = text.trimmingCharacters(in: .whitespacesAndNewlines)
            namespace = nil
            excluded = false
        }
        let namespaceOnly = tokenMode && term.isEmpty && !(namespace?.isEmpty ?? true)
        guard namespaceOnly || term.count >= max(1, configuration.minimumQueryLength ?? 2) else { return nil }
    }

    func applying(_ suggestion: SearchSuggestion) -> (text: String, selection: NSRange)? {
        guard let editRange = Range(range, in: text) else { return nil }
        var completion = suggestion.text
        if tokenMode {
            if quoteTokens {
                completion = completion.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                completion = "\"" + completion + "\""
            } else {
                completion = completion.split(whereSeparator: \.isWhitespace).joined(separator: spaceReplacement)
            }
            if let namespace = suggestion.namespace ?? namespace, !namespace.isEmpty {
                completion = namespace + ":" + completion
            }
            if excluded { completion = "-" + completion }
        }
        let prefix = String(text[..<editRange.lowerBound])
        let suffix = String(text[editRange.upperBound...])
        if tokenMode && suffix.isEmpty { completion += " " }
        let result = prefix + completion + suffix
        return (result, NSRange(location: (prefix + completion).utf16.count, length: 0))
    }
}
