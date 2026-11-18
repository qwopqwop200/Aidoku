import CoreGraphics
import Foundation

/// Search the same quarter-point sizes that the renderer will actually retain.
/// Searching continuous sizes and flooring afterwards loses an entire quarter
/// at exact fit boundaries, and does not test the size ultimately painted.
enum NativeTranslationFontFitSearch {
    static func largestFitting(minimum: CGFloat, maximum: CGFloat,
                               fits: (CGFloat) -> Bool) -> CGFloat? {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum,
              maximum * 4 < CGFloat(Int.max), fits(minimum) else { return nil }
        var low = Int(ceil(minimum * 4)), high = Int(floor(maximum * 4))
        var accepted = minimum
        while low <= high {
            let middle = low + (high - low) / 2
            let candidate = CGFloat(middle) / 4
            if fits(candidate) {
                accepted = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return accepted
    }
}
