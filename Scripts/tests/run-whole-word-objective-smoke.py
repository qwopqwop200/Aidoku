"""Focused real-CoreText lexical objective checks; parent runs this on macOS."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
PROGRAM = r'''
import Foundation
import CoreText
import CoreGraphics

let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]
func measured(_ text: String) -> CGFloat {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let valid = !ink.isNull && !ink.isEmpty && !ink.isInfinite
    return max(advance, valid ? ink.maxX : 0) - min(0, valid ? ink.minX : 0)
}
func layout(_ text: String, _ width: CGFloat, _ prefer: Bool) throws -> NativeWholeWordWrap.Result {
    try NativeWholeWordWrap.layoutInternal(text: text, font: font, size: 20, width: width,
        captionBoundaryRules: false, characterControl: true, preferWholeWords: prefer)
}
func cuts(_ result: NativeWholeWordWrap.Result) -> Int {
    NativeRenderWrapQuality.wordCutOffsets(result.text, ranges: result.rows.map(\.ownedRange)).count
}
func ownership(_ result: NativeWholeWordWrap.Result, _ width: CGFloat) {
    precondition(result.completeOwnership && result.requiredWidth <= width)
    let ns = result.text as NSString
    let boundaries = Set([0] + result.graphemeRanges.map(NSMaxRange))
    var cursor = 0
    for row in result.rows {
        precondition(row.ownedRange.location == cursor && boundaries.contains(NSMaxRange(row.ownedRange)))
        precondition(row.occupiedWidth <= width)
        let owned = ns.substring(with: row.ownedRange)
        precondition(row.hardBreak == (owned.last.map(NativeLineBreakPolicy.isBreak) ?? false))
        // A hard terminator is the final grapheme of its owner, never inside a row.
        precondition(!owned.dropLast().contains(where: NativeLineBreakPolicy.isBreak))
        cursor = NSMaxRange(row.ownedRange)
    }
    precondition(cursor == ns.length)
}
func parity(_ a: NativeWholeWordWrap.Result, _ b: NativeWholeWordWrap.Result) {
    precondition(a.rows.map(\.ownedRange) == b.rows.map(\.ownedRange))
    precondition(a.rows.map(\.paintedRange) == b.rows.map(\.paintedRange))
    precondition(a.rows.map(\.advance) == b.rows.map(\.advance))
    precondition(a.rows.map(\.inkBounds) == b.rows.map(\.inkBounds))
    precondition(a.rows.map(\.hardBreak) == b.rows.map(\.hardBreak))
    precondition(a.rows.map(\.overflow) == b.rows.map(\.overflow))
    precondition(a.rows.map(\.discretionaryHyphen) == b.rows.map(\.discretionaryHyphen))
    precondition(a.requiredWidth == b.requiredWidth && a.bodyHeight == b.bodyHeight)
    precondition(a.completeOwnership == b.completeOwnership && a.graphemeRanges == b.graphemeRanges)
    precondition(a.fallbackRanges == b.fallbackRanges && a.unresolvedGlyphRanges == b.unresolvedGlyphRanges)
    precondition(a.appliedTracking == b.appliedTracking && a.attributedText.isEqual(to: b.attributedText))
}
// Preserve the old broad metric, while excluding standalone words/interjections
// from the new fragment metric, including whitespace and hard-break ownership.
for text in ["I a", "아\n오", "a\r\nI", "e\u{301} a", "1 2"] {
    var offset = 0
    let ranges = text.map { c -> NSRange in
        let length = String(c).utf16.count
        defer { offset += length }
        return NSRange(location: offset, length: length)
    }
    precondition(NativeRenderWrapQuality.singleCharacterRows(text, ranges: ranges) == 2)
    precondition(NativeRenderWrapQuality.singleCharacterFragmentRows(text, ranges: ranges) == 0)
}
for (text, ranges, expected) in [
    ("abcd", [NSRange(location: 0, length: 1), NSRange(location: 1, length: 3)], 1), // right cut
    ("abcd", [NSRange(location: 0, length: 3), NSRange(location: 3, length: 1)], 1), // left cut
    ("abc", [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1), NSRange(location: 2, length: 1)], 3),
    ("a1b", [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1), NSRange(location: 2, length: 1)], 3),
    ("e\u{301}b", [NSRange(location: 0, length: 2), NSRange(location: 2, length: 1)], 2),
    ("a\u{200E}b", [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1), NSRange(location: 2, length: 1)], 0),
    (" a ", [NSRange(location: 0, length: 3)], 0)
] {
    precondition(NativeRenderWrapQuality.singleCharacterFragmentRows(text, ranges: ranges) == expected)
}
// Exhaustive independent partition oracle on a short synthetic paragraph.
// This checks the lexicographic optimum AND existing secondary score, including
// pruning cases where a more expensive prefix has fewer cuts. No runtime fixtures.
let witness = "a abcdef a"
func objective(_ ranges: [NSRange], _ width: CGFloat) -> (Int, Double)? {
    let ns = witness as NSString
    var score = 0.0
    for (index, range) in ranges.enumerated() {
        let value = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        let occupied = measured(value)
        if occupied > width { return nil }
        let letters = value.filter(\.isLetter).count
        let ragged = pow(Double(max(0, width - occupied) / width), 2)
        let tail = index == ranges.count-1 && index > 0
            ? pow(Double(max(0, 0.35 - occupied / width)), 2) * 16 : 0
        score += 1 + ragged + tail + (letters == 1 ? 8 : 0)
    }
    return (NativeRenderWrapQuality.wordCutOffsets(witness, ranges: ranges).count, score)
}
let endpoints = NativeLineBreakPolicy.legalOffsets(text: witness).filter { $0 > 0 && $0 < witness.utf16.count }.sorted()
var improved = false
for factor: CGFloat in [0.85, 1, 1.15] {
    let width = measured("abcdef") * factor + 0.25
    let old = try layout(witness, width, false)
    let proposed = try layout(witness, width, true)
    ownership(proposed, width)
    var best = (Int.max, Double.infinity)
    for mask in 0..<(1 << endpoints.count) {
        let ends = endpoints.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil } + [witness.utf16.count]
        var start = 0
        let ranges = ends.map { end -> NSRange in
            defer { start = end }
            return NSRange(location: start, length: end-start)
        }
        if let value = objective(ranges, width), value.0 < best.0 || (value.0 == best.0 && value.1 < best.1) { best = value }
    }
    let actual = objective(proposed.rows.map(\.ownedRange), width)!
    precondition(actual.0 == best.0 && abs(actual.1-best.1) < 0.000001)
    precondition(cuts(proposed) <= cuts(old))
    improved = improved || cuts(proposed) < cuts(old)
}
precondition(improved, "CoreText witness must actually reduce word cuts")
// A single oversized lexical edge must never win because it has zero cuts.
let narrow = measured("W") + 0.25
let split = try layout("WW", narrow, true)
ownership(split, narrow)
precondition(cuts(split) == 1)
do {
    _ = try NativeWholeWordWrap.layoutInternal(text: "WW", font: font, size: 20, width: narrow,
        captionBoundaryRules: false, preferWholeWords: true)
    preconditionFailure("No legal fitting path must throw rather than return an oversized edge")
} catch NativeWholeWordWrap.Failure.noFittingLayout {}
// Extended graphemes, numeric adjacency, directional controls, every hard-break
// kind, empty paragraphs and terminal break ownership use actual CoreText rows.
let mixed = "e\u{301}abc 👩‍👩‍👧‍👦 가나다\r\n\nA1b\u{200E}cd\u{2028}아 오\r끝\u{000B}a\u{000C}b\u{0085}c\u{2029}"
ownership(try layout(mixed, 160, true), 160)
for text in ["", "a abcdef a", mixed, "ab\u{00AD}cd", "longunbreakableword"] {
    for width: CGFloat in [25, 90, 300] {
        let implicit = try NativeWholeWordWrap.layoutInternal(text: text, font: font, size: 20, width: width,
            captionBoundaryRules: false, necessaryCJK: true)
        let explicit = try NativeWholeWordWrap.layoutInternal(text: text, font: font, size: 20, width: width,
            captionBoundaryRules: false, necessaryCJK: true, preferWholeWords: false)
        parity(implicit, explicit)
    }
}
// A supplied row budget bypasses the new objective, including its exact DP.
let budgetText = "a abcdef a", budget: [Int: Int] = [0: 3]
func budgetLayout(_ prefer: Bool) throws -> NativeWholeWordWrap.Result {
    try NativeWholeWordWrap.layoutInternal(text: budgetText, font: font, size: 20, width: 90,
        captionBoundaryRules: false, characterControl: true, paragraphRows: budget, preferWholeWords: prefer)
}
parity(try budgetLayout(false), try budgetLayout(true))
print("PASS fragment metric, exhaustive lexical/score oracle, fewer cuts, physical fit, infeasibility, grapheme/hardbreak ownership, default parity, row-budget isolation")
'''

if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='aidoku-whole-word-objective-') as tmp:
        main = Path(tmp) / 'main.swift'
        main.write_text(PROGRAM)
        binary = Path(tmp) / 'check'
        sources = [SOURCES / f'{name}.swift' for name in (
            'NativeLineBreakPolicy', 'NativeNecessaryCJKBreaks', 'NativeTextSpacing',
            'NativeRenderWrapQuality', 'NativeWholeWordWrap')]
        subprocess.run(['xcrun', 'swiftc', '-O', *map(str, sources), str(main), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
