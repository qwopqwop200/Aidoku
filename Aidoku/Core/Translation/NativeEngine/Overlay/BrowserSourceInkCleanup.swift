import Foundation

// Conservative source-pixel cleanup. Integration owns source coordinates, image
// decoding, page budgets and opacity; this helper never invents background art.
enum BrowserSourceInkCleanup {
    // Matches the frozen cleanup applicability gate after Unicode NFKC normalization.
    // This authorizes pixel inspection only; it never filters OCR or translated dialogue.
    private static let coloredCleanupLetters = try? NSRegularExpression(
        pattern: #"[\p{script=Han}\p{script=Hiragana}\p{script=Katakana}\p{script=Hangul}A-Za-z]"#
    )

    static func hasColoredCleanupText(_ source: String) -> Bool {
        guard !source.isEmpty, let expression = coloredCleanupLetters else { return false }
        let normalized = source.precomposedStringWithCompatibilityMapping as NSString
        var cjkCount = 0
        var latinCount = 0
        var firstLetter: String?
        var hasDistinctLetters = false
        var eligible = false
        expression.enumerateMatches(
            in: normalized as String, range: NSRange(location: 0, length: normalized.length)
        ) { match, _, stop in
            guard let match else { return }
            var letter = normalized.substring(with: match.range)
            let scalar = normalized.character(at: match.range.location)
            if (65...90).contains(scalar) || (97...122).contains(scalar) {
                latinCount += 1
                letter = letter.lowercased()
            } else {
                cjkCount += 1
            }
            if let firstLetter {
                if firstLetter != letter { hasDistinctLetters = true }
            } else {
                firstLetter = letter
            }
            if hasDistinctLetters && (cjkCount >= 3 || latinCount >= 4) {
                eligible = true
                stop.pointee = true
            }
        }
        return eligible
    }
}
