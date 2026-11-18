import CoreGraphics
import CoreText
import Foundation

extension NativeSimpleTextLayout {
    /// One fixed-font width, selected from measured source/word width and the
    /// actual caller height/pitch. Placement and final paint admission stay external.
    struct SingleWidthFit {
        let outerWidth: CGFloat
        let wrapped: NativeWholeWordWrap.Result
        let positioned: NativeWholeWordGlyphPainter.PositionedRows
        let measurements: Int
    }

    static func fitSingleWidth(text: String, font: CTFont, size: CGFloat, preferredOuterWidth: CGFloat,
                               maximumOuterWidth: CGFloat, availableHeight: CGFloat,
                               outwardExtent: CGFloat, padding: CGFloat, minimumLineHeight: CGFloat,
                               color: CGColor = CGColor(gray: 0, alpha: 1)) throws -> SingleWidthFit? {
        guard [size, preferredOuterWidth, maximumOuterWidth, availableHeight, outwardExtent, padding, minimumLineHeight]
                .allSatisfy(\.isFinite),
              size > 0, preferredOuterWidth > 0, maximumOuterWidth > 0, availableHeight > 0,
              outwardExtent >= 0, padding >= 0, minimumLineHeight >= 0 else {
            throw NativeWholeWordWrap.Failure.invalidInput
        }
        let inset = outwardExtent + padding
        guard maximumOuterWidth > 2 * inset else { return nil }
        let input = TypesettingInput(text: text, font: font, size: size, color: color)
        let ns = text as NSString
        func physicalWidth(_ range: NSRange) -> CGFloat {
            guard range.length > 0 else { return 0 }
            let line = CTTypesetterCreateLine(input.typesetter, CFRange(location: range.location, length: range.length))
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).union(CTLineGetImageBounds(line, nil))
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return max(advance, ink.isNull || ink.isEmpty ? 0 : ink.maxX) - min(0, ink.isNull || ink.isEmpty ? 0 : ink.minX)
        }
        var floor: CGFloat = 0
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            floor = max(floor, physicalWidth(NSRange(location: offset, length: length)))
            offset += length
        }
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, _ in
            var start = range.location
            var end = NSMaxRange(range)
            while start > 0 {
                let previous = ns.rangeOfComposedCharacterSequence(at: start - 1)
                guard let c = ns.substring(with: previous).first, c.isPunctuation || c.isSymbol else { break }
                start = previous.location
            }
            while end < ns.length {
                let next = ns.rangeOfComposedCharacterSequence(at: end)
                guard let c = ns.substring(with: next).first, c.isPunctuation || c.isSymbol else { break }
                end = NSMaxRange(next)
            }
            floor = max(floor, physicalWidth(NSRange(location: start, length: end - start)))
        }
        let preferred = min(maximumOuterWidth, max(preferredOuterWidth, floor + 2 * inset))
        var measurements = 0
        func fit(_ outer: CGFloat) throws -> (NativeWholeWordWrap.Result, NativeWholeWordGlyphPainter.PositionedRows)? {
            try Task.checkCancellation()
            measurements += 1
            let width = outer - 2 * inset
            guard width > 0 else { return nil }
            let wrapped = try layout(input, width: width)
            guard wrapped.completeOwnership, wrapped.unresolvedGlyphRanges.isEmpty, wrapped.requiredWidth <= width + 0.01 else { return nil }
            let positioned = try NativeWholeWordGlyphPainter.position(wrapped, width: width,
                minimumLineHeight: minimumLineHeight, outwardExtent: outwardExtent)
            guard positioned.fillBounds.height + 2 * inset <= availableHeight + 0.01 else { return nil }
            return (wrapped, positioned)
        }
        if let initial = try fit(preferred) {
            return .init(outerWidth: preferred, wrapped: initial.0, positioned: initial.1, measurements: measurements)
        }
        guard var selected = try fit(maximumOuterWidth) else { return nil }
        var lower = preferred
        var upper = maximumOuterWidth
        // Keep an actually measured feasible endpoint; greedy wrap height is
        // not asserted globally monotone. Stop at one native output pixel.
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if let value = try fit(middle) { upper = middle; selected = value } else { lower = middle }
        }
        return .init(outerWidth: upper, wrapped: selected.0, positioned: selected.1, measurements: measurements)
    }
}
