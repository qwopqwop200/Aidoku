import UIKit

extension NSAttributedString.Key {
    static let nativeDictionaryRuby = NSAttributedString.Key("AidokuDictionaryRuby")
}

/// Furigana is painted above base glyphs; it never becomes part of selectable dictionary text.
final class NativeDictionaryRubyLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.nativeDictionaryRuby, in: characters) { value, range, _ in
            guard let reading = value as? String, !reading.isEmpty,
                  let base = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = base.withSize(base.pointSize * 0.55)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            let readingCharacters = Array(reading)
            enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, fragment, _ in
                let visible = NSIntersectionRange(fragment, glyphs)
                guard visible.length > 0 else { return }
                let baseRange = NSIntersectionRange(self.characterRange(forGlyphRange: visible, actualGlyphRange: nil), range)
                let start = Int((Double(baseRange.location - range.location) / Double(range.length) * Double(readingCharacters.count)).rounded())
                let end = Int((Double(NSMaxRange(baseRange) - range.location) / Double(range.length) * Double(readingCharacters.count)).rounded())
                guard end > start, start >= 0, end <= readingCharacters.count else { return }
                let text = String(readingCharacters[start..<end]) as NSString
                let size = text.size(withAttributes: attributes)
                let box = self.boundingRect(forGlyphRange: visible, in: container)
                text.draw(at: CGPoint(x: origin.x + box.midX - size.width / 2,
                                      y: origin.y + box.minY - size.height), withAttributes: attributes)
            }
        }
    }
}
