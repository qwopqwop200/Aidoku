import Foundation

enum NativeDictionarySelection {
    static let scanDelimiters = Set("。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]・：；:;，,.─\n\r")
    static let sentenceDelimiters = Set("。！？.!?\n\r")
    static let trailing = Set("。、！？」』）)】〉》〕｝}］]")
    static let brackets: [Character: Character] = ["「": "」", "『": "』", "（": "）", "(": ")", "【": "】", "〈": "〉", "《": "》", "〔": "〕", "｛": "｝", "{": "}", "［": "］", "[": "]"]

    static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                || (0x20000...0x323AF).contains($0.value) || (0x2F800...0x2FA1F).contains($0.value) || $0.value == 0x3005
        }
    }

    static func isJapanese(_ character: Character) -> Bool {
        let ranges: [ClosedRange<UInt32>] = [
            0x3040...0x30FF, 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF,
            0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0x2CEB0...0x2EBEF,
            0x30000...0x3134F, 0x31350...0x323AF, 0x2EBF0...0x2EE5F, 0xF900...0xFAFF,
            0x2F800...0x2FA1F, 0xFF61...0xFF9F, 0x3000...0x303F,
            0xFF01...0xFF60, 0xFFE0...0xFFEE
        ]
        return character.unicodeScalars.contains { scalar in ranges.contains { $0.contains(scalar.value) } }
    }

    static func scan(_ text: String, offset: Int, length: Int, includeNonJapanese: Bool) -> String {
        let value = text as NSString
        guard offset >= 0, offset < value.length else { return "" }
        var result = ""
        for character in value.substring(from: offset).prefix(max(1, length)) {
            if character.isWhitespace || scanDelimiters.contains(character) || (!includeNonJapanese && !isJapanese(character)) { break }
            result.append(character)
        }
        return result
    }

    static func sentence(_ text: String, offset: Int) -> (text: String, offset: Int) {
        let value = text as NSString
        guard offset >= 0, offset <= value.length else { return (text, 0) }
        let before = value.substring(to: offset)
        let after = value.substring(from: offset)
        var prefix = ""
        for character in before.reversed() {
            if sentenceDelimiters.contains(character) { break }
            prefix.insert(character, at: prefix.startIndex)
        }
        var suffix = "", reachedEnd = false
        for character in after {
            if reachedEnd && !trailing.contains(character) { break }
            suffix.append(character)
            if sentenceDelimiters.contains(character) { reachedEnd = true }
        }
        let sentence = prefix + suffix
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = Array(trimmed)
        var stack: [Character] = [], unmatchedClose: [Character] = []
        let closing = Set(brackets.values)
        for character in characters {
            if brackets[character] != nil { stack.append(character) }
            else if closing.contains(character) {
                if let last = stack.last, brackets[last] == character { stack.removeLast() }
                else { unmatchedClose.append(character) }
            }
        }
        var start = 0, end = characters.count - 1, cursor = end
        while !stack.isEmpty && start < characters.count - 1 && stack.first == characters[start] {
            stack.removeFirst(); start += 1
        }
        while !unmatchedClose.isEmpty && cursor > start {
            if unmatchedClose.last == characters[cursor] { unmatchedClose.removeLast(); end = cursor - 1 }
            else if !sentenceDelimiters.contains(characters[cursor]) { break }
            cursor -= 1
        }
        let sliced = end >= start ? String(characters[start...end]) : ""
        let result = sliced.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = (sentence as NSString).range(of: trimmed).location
        let removed = (String(characters.prefix(start)) as NSString).length
        let sliceLeading = (sliced as NSString).range(of: result).location
        return (result, (prefix as NSString).length - (leading == NSNotFound ? 0 : leading)
            - removed - (sliceLeading == NSNotFound ? 0 : sliceLeading))
    }
}
