import CoreGraphics
import Foundation

/// Intrinsic width of a collapsed controlled block row. Glyph painting keeps
/// using the collapsed text; this preserves the Float arithmetic of the raw
/// inline items, including a following space that is trimmed at line close.
enum NativeCollapsedRowIntrinsicWidth {
    /// The callback must use natural shaping without letter spacing and return
    /// one advance per scalar. Complex clusters and unsupported directions
    /// decline in the caller, leaving its existing intrinsic measurement intact.
    /// Unique fragments are measured once; their combined length is linear in
    /// the input, so this does not introduce a candidate/font search.
    static func width(
        text: String,
        letterSpacing: Float,
        extendsWordsIntoFollowingSpace: Bool = true,
        measureNaturalGlyphAdvances: (String) -> [Float]?
    ) -> CGFloat? {
        guard letterSpacing.isFinite else { return nil }
        var content = "", pendingSpace = false
        for scalar in text.unicodeScalars {
            if [9, 10, 12, 13, 32].contains(scalar.value) {
                if !content.isEmpty { pendingSpace = true }
            } else {
                if pendingSpace { content.append(" "); pendingSpace = false }
                content.unicodeScalars.append(scalar)
            }
        }
        if pendingSpace { content.append(" ") }
        guard !content.isEmpty else { return 0 }

        var cache: [String: Float] = [:]
        func measure(_ fragment: String) -> Float? {
            if let hit = cache[fragment] { return hit }
            guard let advances = measureNaturalGlyphAdvances(fragment),
                  advances.count == fragment.unicodeScalars.count,
                  advances.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            // WidthIterator accumulates natural glyph advances first, then
            // applies CSS spacing after shaping, all in the float domain.
            var result: Float = 0
            for advance in advances { result += advance }
            for advance in advances where advance != 0 { result += letterSpacing }
            guard result.isFinite, result >= 0 else { return nil }
            cache[fragment] = result
            return result
        }
        guard let measuredSpace = measure(" ") else { return nil }
        let space = max(0, measuredSpace)
        let parts = content.split(separator: " ", omittingEmptySubsequences: false)
        var result: Float = 0
        for index in parts.indices where !parts[index].isEmpty {
            let followsSpace = index + 1 < parts.count
            let word = String(parts[index])
            let measured: Float
            if followsSpace && extendsWordsIntoFollowingSpace {
                guard let extended = measure(word + " ") else { return nil }
                // TextUtil::width extends the non-space item into its next
                // space, then subtracts singleSpaceWidth before placement.
                measured = extended - space
            } else {
                guard let plain = measure(word) else { return nil }
                measured = plain
            }
            result += measured
            if followsSpace { result += space }
        }
        if content.last == " " { result -= space }
        guard result.isFinite, result >= 0 else { return nil }
        return CGFloat(result)
    }
}
