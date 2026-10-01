import CoreGraphics
import CoreText
import Foundation

/// WebKit paints a visible form feed with the selected font's missing glyph.
/// GlyphInfo replaces its glyph and advance without changing source UTF16.
enum NativeVisibleControlGlyphs {
    struct Glyph {
        let sourceUTF16: Int
        let glyph: CGGlyph
        let advance: CGFloat
        let font: CTFont
    }

    static func formFeeds(text: String, font: CTFont) -> [Glyph] {
        var glyph: CGGlyph = 0, advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return text.utf16.enumerated().compactMap { index, unit in
            unit == 12 ? Glyph(sourceUTF16: index, glyph: 0, advance: advance.width, font: font) : nil
        }
    }

    static func apply(to attributed: NSMutableAttributedString) {
        let source = attributed.string as NSString
        let indices = (0..<source.length).filter { source.character(at: $0) == 12 }
        guard !indices.isEmpty else { return }
        // Resolve the actual shaped font before installing any overrides.
        let line = CTLineCreateWithAttributedString(attributed)
        var replacements: [(Int, CTFont, CTGlyphInfo)] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let range = CTRunGetStringRange(run)
            let locations = indices.filter { $0 >= range.location && $0 < range.location + range.length }
            guard !locations.isEmpty else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let object = attributes[kCTFontAttributeName],
                  CFGetTypeID(object as CFTypeRef) == CTFontGetTypeID() else { continue }
            let font = object as! CTFont
            guard let info = CTGlyphInfoCreateWithGlyph(0, font, "\u{000C}" as CFString) else { continue }
            for index in locations { replacements.append((index, font, info)) }
        }
        for (index, font, info) in replacements {
            attributed.addAttributes([
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTGlyphInfoAttributeName as String): info,
            ], range: NSRange(location: index, length: 1))
        }
    }
}
