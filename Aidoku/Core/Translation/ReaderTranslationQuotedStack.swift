import CoreGraphics
import Foundation

/// Recognized quote endpoints plus one tightly aligned column, not shared RF
/// ownership alone. Source characters are concatenated verbatim, never repaired.
enum ReaderTranslationQuotedStack {
    struct Fragment {
        let text: String
        let rect: CGRect // original-image pixels, top-left
        let vertical: Bool
        let translated: Bool
    }

    static func isBoundedQuote(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first, let last = value.last,
              "「『".contains(first), "」』".contains(last), value.count >= 3 else { return false }
        return !value.dropFirst().dropLast().contains { "「『」』".contains($0) }
    }

    static func groups(_ fragments: [Fragment], separates: (CGRect, CGRect) -> Bool) -> [[Int]] {
        guard fragments.count <= 4096 else { return [] }
        var claimed = Set<Int>(), result: [[Int]] = []
        for start in fragments.indices where !claimed.contains(start) {
            let first = fragments[start], text = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !first.translated, first.vertical, let opening = text.first, "「『".contains(opening),
                  !text.dropFirst().contains(where: { "「『」』".contains($0) }),
                  first.rect.width >= 3, first.rect.height > 0 else { continue }
            let em = first.rect.width
            var chain = [start], previous = start, complete = false
            for _ in 0..<11 {
                let a = fragments[previous].rect
                let possible = fragments.indices.filter { index in
                    guard index != start, !claimed.contains(index), !chain.contains(index) else { return false }
                    let value = fragments[index], b = value.rect
                    let gap = b.minY - a.maxY
                    return !value.translated && b.width > 0 && b.height > 0 &&
                        b.minY > a.minY && gap >= -em * 0.15 && gap <= em * 1.5 &&
                        abs(b.midX - first.rect.midX) <= em * 0.3 && b.width <= em * 1.3 &&
                        b.height <= em * 3 && b.maxY - first.rect.minY <= em * 18
                }.sorted { fragments[$0].rect.minY < fragments[$1].rect.minY }
                guard let next = possible.first else { break }
                // Equally near columns or competing fragments do not form a certified chain.
                if possible.count > 1, abs(fragments[possible[1]].rect.minY - fragments[next].rect.minY) < em * 0.3 { break }
                let value = fragments[next], valueText = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !valueText.isEmpty, valueText.count <= 12,
                      !valueText.contains(where: { "「『".contains($0) }),
                      !valueText.dropLast().contains(where: { "」』".contains($0) }),
                      (value.vertical || valueText.count <= 1),
                      valueText.unicodeScalars.allSatisfy({ scalar in
                          !scalar.properties.isAlphabetic || (0x3040...0x30ff).contains(scalar.value) ||
                              (0x3400...0x9fff).contains(scalar.value)
                      }), !separates(a, value.rect) else { break }
                chain.append(next); previous = next
                if let last = valueText.last, "」』".contains(last) { complete = true; break }
            }
            guard complete, chain.count >= 2 else { continue }
            let joined = chain.map { fragments[$0].text }.joined()
            guard isBoundedQuote(joined), joined.count <= 64 else { continue }
            let bounds = chain.dropFirst().reduce(first.rect) { $0.union(fragments[$1].rect) }
            let members = Set(chain)
            // Never swallow another sentence, even when it was not eligible above.
            guard !fragments.indices.contains(where: { !members.contains($0) && fragments[$0].rect.intersects(bounds) }) else { continue }
            result.append(chain); claimed.formUnion(chain)
        }
        return result
    }
}
