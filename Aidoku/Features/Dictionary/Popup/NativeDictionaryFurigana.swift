import Foundation

/// Preserves the popup's kana alignment and ambiguous-reading fallback without a DOM.
enum NativeDictionaryFurigana {
    struct Segment {
        let text: String
        let reading: String
    }

    private static func hiragana(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map {
            (0x30A1...0x30F6).contains($0.value) ? UnicodeScalar($0.value - 0x60)! : $0
        }))
    }

    static func segments(_ expression: String, reading: String) -> [Segment] {
        guard !reading.isEmpty, expression != reading else { return [Segment(text: expression, reading: "")] }
        var groups: [(text: String, kanji: Bool)] = []
        for character in expression {
            let kanji = NativeDictionarySelection.isKanji(character)
            if groups.last?.kanji == kanji { groups[groups.count - 1].text.append(character) }
            else { groups.append((String(character), kanji)) }
        }
        let readingCharacters = Array(reading)
        var budget = 50_000
        func split(_ index: Int, _ offset: Int) -> [Segment]? {
            budget -= 1
            guard budget >= 0 else { return nil }
            guard index < groups.count else { return offset == readingCharacters.count ? [] : nil }
            let group = groups[index]
            let count = group.text.count
            let remaining = String(readingCharacters.dropFirst(offset))
            if !group.kanji {
                guard hiragana(remaining).hasPrefix(hiragana(group.text)), offset + count <= readingCharacters.count,
                      let tail = split(index + 1, offset + count) else { return nil }
                let actual = Array(readingCharacters[offset..<(offset + count)])
                let base = Array(group.text)
                var pieces: [Segment] = []
                var start = 0
                for end in 1...count where end == count || (actual[end] == base[end]) != (actual[start] == base[start]) {
                    let text = String(base[start..<end])
                    pieces.append(Segment(text: text, reading: actual[start] == base[start] ? "" : String(actual[start..<end])))
                    start = end
                }
                return pieces + tail
            }
            guard readingCharacters.count - offset >= count else { return nil }
            var result: [Segment]?
            for end in stride(from: readingCharacters.count, through: offset + count, by: -1) {
                if let tail = split(index + 1, end) {
                    guard result == nil else { return nil }
                    result = [Segment(text: group.text, reading: String(readingCharacters[offset..<end]))] + tail
                }
                if index == groups.count - 1 { break }
            }
            return result
        }
        return split(0, 0) ?? [Segment(text: expression, reading: reading)]
    }
}
