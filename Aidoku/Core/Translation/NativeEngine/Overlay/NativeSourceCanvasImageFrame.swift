import CoreGraphics
import Foundation

/// The live source canvas image destination, independently of its CSS
/// basic-shape clip reference and the saved raw mask's DOM-used frame.
enum NativeSourceCanvasImageFrame {
    /// Untransformed canvas images paint at integer CSS edges. Device/output
    /// scales are applied afterwards; rounding origin and extent separately
    /// would change the right/bottom edges. Empty destinations omit the image.
    static func liveFrame(domRect: CGRect) -> CGRect? {
        let x = domRect.origin.x, y = domRect.origin.y
        let width = domRect.size.width, height = domRect.size.height
        guard [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite),
              width > 0, height > 0 else { return nil }
        let left = floor(x + 0.5), top = floor(y + 0.5)
        let right = floor(x + width + 0.5), bottom = floor(y + height + 0.5)
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
