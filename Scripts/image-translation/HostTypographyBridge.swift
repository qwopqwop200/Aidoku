import AppKit
import CoreText

// These names let the unmodified production layout planner use macOS's
// attributed-string and Core Text implementation. They bridge platform types;
// they do not implement a separate font fitting or card placement algorithm.
typealias UIFont = NSFont
typealias UIColor = NSColor

extension NSFont {
    /// UIKit exposes this metric directly. Use the same Core Text ascent,
    /// descent and leading on the host without rounding fractional font sizes.
    /// Platform font versions/shaping can still differ from an actual iPhone;
    /// exact device pixel parity requires the device's measured layout payload.
    var lineHeight: CGFloat {
        let font = self as CTFont
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }
}

struct UIEdgeInsets: Equatable, Hashable, Sendable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static let zero = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
}
