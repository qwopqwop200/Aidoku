import UIKit

/// Resolve only the bounded set of tight Latin seams proposed by the native
/// merger. UITextChecker is main-actor isolated; OCR and grouping stay off it.
enum ReaderOCRWordBoundaryResolver {
    @MainActor
    static func recognizedWords(in candidates: Set<String>) -> Set<String> {
        guard !candidates.isEmpty,
              let language = UITextChecker.availableLanguages.first(where: { $0.hasPrefix("en") })
        else { return [] }
        let checker = UITextChecker()
        return Set(candidates.filter { word in
            checker.rangeOfMisspelledWord(
                in: word, range: NSRange(word.startIndex..., in: word),
                startingAt: 0, wrap: false, language: language
            ).location == NSNotFound
        })
    }
}
