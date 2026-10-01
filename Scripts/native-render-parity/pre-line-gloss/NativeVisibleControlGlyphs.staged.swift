import CoreGraphics
import CoreText
import Foundation

/// Staged transport for the specifically proven U+000C visible-control branch.
/// Native Typography must replace both glyph and advance in the selected run;
/// merely adding width to a line does not establish rendered pixel parity.
enum NativeVisibleControlGlyphs {
    struct Glyph {
        let sourceUTF16: Int
        let glyph: CGGlyph
        let advance: CGFloat
        let font: CTFont
    }
    static func formFeeds(text: String, font: CTFont) -> [Glyph] {
        var glyphs: [CGGlyph] = [0], advances = [CGSize.zero]
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, 1)
        return text.utf16.enumerated().compactMap { offset, unit in
            unit == 12 ? Glyph(sourceUTF16: offset, glyph: 0, advance: advances[0].width, font: font) : nil
        }
    }
}
