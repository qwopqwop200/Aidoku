import Foundation
import CoreText
/// CSS letter spacing is trailing cluster spacing. A nonzero CT kern value
/// also enables native pair kerning (including Hiragino vertical kerx pairs).
/// Tracking retains literal text and the vertical glyphs while kern zero
/// suppresses those additional pairs, matching the captured vertical CSS.
enum NativeVerticalLetterSpacing {
    static func apply(to text: NSMutableAttributedString) {
        guard text.length > 0, text.length <= 65_536 else { return }
        let full = NSRange(location: 0, length: text.length)
        var spans: [(NSRange, Any)] = []
        text.enumerateAttribute(NSAttributedString.Key(kCTKernAttributeName as String), in: full) { value, range, _ in
            spans.append((range, value ?? 0))
        }
        for (range, value) in spans {
            text.addAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String), value: value, range: range)
        }
        text.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: 0, range: full)
    }
}
