import CoreText
import Foundation

/// Optional break evidence only. Call with the physical candidate width at the
/// unchanged font. Returned offsets refer to the canonical UTF-16 text.
enum NativeNecessaryCJKBreaks {
    private static let delimiters = Set("-‐‒–—―/\\")
    struct Proposal {
        let offsets: Set<Int>
        let overwideUnits: [NSRange]
        let authority: String
    }
    static func cjk(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value)
                || (0x3130...0x318F).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
                || (0x20000...0x323AF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
                || (0x3100...0x312F).contains($0.value) || (0x31A0...0x31BF).contains($0.value)
                || (0x31F0...0x31FF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                || (0xFF66...0xFF9F).contains($0.value) || (0x1AFF0...0x1B16F).contains($0.value)
                || (0xA960...0xA97F).contains($0.value) || (0xD7B0...0xD7FF).contains($0.value)
        }
    }
    static func propose(text: String, attributed: NSAttributedString, physicalWidth: CGFloat,
                        lineFactory: ((NSAttributedString) -> CTLine)? = nil,
                        legalOffsets: Set<Int>? = nil, bindForbiddenWhitespace: Bool = false) -> Proposal {
        let ns = text as NSString
        var ranges: [NSRange] = [], offset = 0
        for character in text {
            let length = String(character).utf16.count
            ranges.append(NSRange(location: offset, length: length)); offset += length
        }
        // The wrapper has already analysed this exact text. Reuse its set;
        // independent callers retain the same default calculation.
        let legal = legalOffsets ?? NativeLineBreakPolicy.legalOffsets(text: text)
        var result = Set<Int>(), overwide: [NSRange] = []
        var members: [NSRange] = []
        func flush() {
            defer { members.removeAll(keepingCapacity: true) }
            guard let first = members.first, let last = members.last, members.count > 1 else { return }
            let unit = NSRange(location: first.location, length: NSMaxRange(last)-first.location)
            let fragment = attributed.attributedSubstring(from: unit)
            let line = lineFactory?(fragment) ?? CTLineCreateWithAttributedString(fragment)
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let body = max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), ink.maxX)-min(0, ink.minX)
            guard body > physicalWidth+0.01 else { return }
            overwide.append(unit)
            let typesetter = CTTypesetterCreateWithAttributedString(fragment)
            for (left, right) in zip(members.dropLast(), members.dropFirst()) {
                // Natural Unicode delimiter breaks also rescue long compounds
                // and paths. Pure Latin words, nonbreaking hyphens and original
                // graphemes remain intact; only overwide units reach this path.
                let leftText = ns.substring(with: left), rightText = ns.substring(with: right)
                guard (cjk(leftText) || cjk(rightText) ||
                       (leftText.last.map { delimiters.contains($0) } ?? false)),
                      legal.contains(NSMaxRange(left)) else { continue }
                let end = NSMaxRange(left)-unit.location
                let prefixText = fragment.attributedSubstring(from: NSRange(location: 0, length: end))
                let prefix = lineFactory?(prefixText) ?? CTLineCreateWithAttributedString(prefixText)
                let advance = CTLineGetTypographicBounds(prefix, nil, nil, nil)
                // Core Text's Unicode line-breaking decision, not a forced
                // cluster break. Filter it back onto extended grapheme edges.
                if CTTypesetterSuggestLineBreak(typesetter, 0, advance+0.001) == end {
                    result.insert(unit.location+end)
                }
            }
        }
        // A whitespace run is a unit boundary only when the shared kinsoku
        // policy allows it. Otherwise measure the bound lexical unit together:
        // dropping its CJK offsets as an individual word starts to fit can make
        // a wider physical width require an even wider unbreakable line.
        func ordinarySpace(_ range: NSRange) -> Bool {
            let value = ns.substring(with: range)
            return value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
                && value != "\u{00A0}" && value != "\u{202F}"
        }
        var index = 0
        while index < ranges.count {
            let range = ranges[index], value = ns.substring(with: range)
            if value.last.map(NativeLineBreakPolicy.isBreak) ?? false {
                flush(); index += 1
            } else if ordinarySpace(range) {
                var end = index + 1
                while end < ranges.count, ordinarySpace(ranges[end]),
                      !(ns.substring(with: ranges[end]).last.map(NativeLineBreakPolicy.isBreak) ?? false) { end += 1 }
                let boundary = NSMaxRange(ranges[end-1])
                if !bindForbiddenWhitespace || legal.contains(boundary) || end == ranges.count ||
                    (ns.substring(with: ranges[end]).last.map(NativeLineBreakPolicy.isBreak) ?? false) {
                    flush()
                } else {
                    members.append(contentsOf: ranges[index..<end])
                }
                index = end
            } else {
                members.append(range); index += 1
            }
        }
        flush()
        return .init(offsets: result, overwideUnits: overwide,
            authority: "CoreText Unicode line break intersected with grapheme-safe CJK/delimiter boundaries and shared kinsoku; overwide units only")
    }
}
