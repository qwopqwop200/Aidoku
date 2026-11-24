import UIKit

enum ReaderTranslationWidePageLayout: String, Sendable {
    case whole, halves, pendingSplit
}

/// The same pixel crop as ReaderPageView.splitImage (Core Graphics expands fractional edges).
enum ReaderTranslationSplitGeometry {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func image(_ image: UIImage, crop: CGRect) -> UIImage? {
        if crop == unit { return image }
        guard let pixels = image.cgImage,
              let cropped = pixels.cropping(to: CGRect(
                x: crop.minX * CGFloat(pixels.width), y: crop.minY * CGFloat(pixels.height),
                width: crop.width * CGFloat(pixels.width), height: crop.height * CGFloat(pixels.height))) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
