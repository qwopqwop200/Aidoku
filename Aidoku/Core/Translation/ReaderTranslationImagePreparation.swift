import UIKit

/// Source-image preparation shared by reader pages, look-ahead and the provider request.
enum ReaderTranslationImagePreparation {
    /// Redraws only non-upright or non-CG-backed images.
    nonisolated static func uprightSourceImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.cgImage == nil else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
    }

    static func translationJPEG(_ image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else {
            throw RemoteTranslationError.invalidRequest("The page image is empty.")
        }
        let ratio = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, (image.size.width * ratio).rounded()),
                          height: max(1, (image.size.height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.85), data.count <= 4 * 1024 * 1024 else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        return data
    }
}
