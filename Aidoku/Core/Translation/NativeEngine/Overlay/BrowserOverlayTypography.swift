import Foundation
import CoreGraphics

/// Page-local typography. Source evidence separates emphasis from ordinary
/// dialogue; measured layout remains the final authority on whether text fits.
enum BrowserOverlayTypography {
    static func sourceSize(text: String, rect: CGRect) -> CGFloat? {
        let units = text.unicodeScalars.reduce(CGFloat.zero) { sum, c in
            if CharacterSet.whitespacesAndNewlines.contains(c) { return sum }
            return sum + (c.value < 0x3000 ? 0.55 : 1)
        }
        guard units >= 2, rect.width > 0, rect.height > 0 else { return nil }
        return min(min(rect.width, rect.height), sqrt(rect.width * rect.height / units))
    }
}
