import UIKit

/// Bound background working pixels; OCR retains its original coordinates and pixels.
enum ReaderTranslationBackgroundImage {
    static let maximumPixels: CGFloat = 4_000_000
    static let maximumSide: CGFloat = 8_192

    static func pixelSize(for size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, maximumSide / max(size.width, size.height),
                        sqrt(maximumPixels / size.width / size.height))
        return CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
    }

    static func prepare(_ image: UIImage, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> UIImage {
        try Task.checkCancellation()
        let source = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let size = pixelSize(for: CGSize(width: source.width * crop.width, height: source.height * crop.height))
        guard size.width > 0, size.height > 0, crop.width > 0, crop.height > 0 else {
            throw URLError(.cannotDecodeContentData)
        }
        if crop == CGRect(x: 0, y: 0, width: 1, height: 1), size == source, image.imageOrientation == .up { return image }
        return try autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let result = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(x: -crop.minX * size.width / crop.width,
                                      y: -crop.minY * size.height / crop.height,
                                      width: size.width / crop.width, height: size.height / crop.height))
            }
            try Task.checkCancellation()
            return result
        }
    }
}

