import Foundation

/// Original parenthetical Latin names and an adjacent Korean particle form one unit.
enum NativeParentheticalNameWrap {
    struct Unit {
        let text: String
    }
    static func units(_ text: String) -> [Unit]? {
        guard text.utf16.count <= 180, text.contains("("), text.contains(")"),
            !text.contains(where: \.isNewline), text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) })
        else { return nil }
        let suffixes: Set<String> = ["은", "는", "이", "가", "을", "를", "의", "와", "과", "도", "만", "다", "야", "에게", "으로"]
        var units: [Unit] = []
        var changed = false
        let characters = Array(text)
        var tokens: [String] = []
        var cursor = 0
        while cursor < characters.count {
            while cursor < characters.count && characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count else { return nil }
            let start = cursor
            while cursor < characters.count && !characters[cursor].isWhitespace { cursor += 1 }
            tokens.append(String(characters[start..<cursor]))
        }
        for word in tokens {
            let chars = Array(word)
            var open: Int?
            var close: Int?
            for i in chars.indices {
                if chars[i] == "(" {
                    if open != nil {
                        open = nil
                        break
                    }
                    open = i
                }
                if chars[i] == ")" {
                    close = i
                    break
                }
            }
            guard let a = open, let z = close, z > a + 1, z - a <= 25 else {
                units.append(.init(text: String(word)))
                continue
            }
            let name = chars[(a + 1)..<z]
            guard
                name.allSatisfy({ c in
                    c.unicodeScalars.count == 1 && c.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
                })
            else {
                units.append(.init(text: String(word)))
                continue
            }
            let tail = String(chars[(z + 1)...])
            let visible = tail.trimmingCharacters(in: .punctuationCharacters)
            guard !tail.contains("("), !tail.contains(")") else {
                units.append(.init(text: String(word)))
                continue
            }
            guard tail.isEmpty || visible.isEmpty || suffixes.contains(visible) else {
                units.append(.init(text: String(word)))
                continue
            }
            if a > 0 { units.append(.init(text: String(chars[..<a]))) }
            units.append(.init(text: String(chars[a...])))
            changed = true
        }
        return changed ? units : nil
    }
    static func protectedUTF16Cuts(_ text: String) -> Set<Int> {
        guard let units = units(text) else { return [] }
        let source = text as NSString
        var cursor = 0
        var cuts = Set<Int>()
        for unit in units {
            let range = source.range(of: unit.text, options: [], range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound else { return [] }
            if unit.text.hasPrefix("("), range.length > 1 {
                cuts.formUnion((range.location + 1)..<NSMaxRange(range))
            }
            cursor = NSMaxRange(range)
        }
        return cuts
    }
}
