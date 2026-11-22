import UIKit

/// Source-image preparation shared by reader pages, look-ahead and the provider request.
enum ReaderTranslationImagePreparation {
    /// Redraws only non-upright or non-CG-backed images.
    nonisolated static func uprightSourceImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.cgImage == nil else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
    }

    static func translationJPEG(_ image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else {
            throw RemoteTranslationError.invalidRequest("The page image is empty.")
        }
        // 1024 cut provider time 13% on device (4.2 -> 3.6 s) with role drift inside run-to-run noise.
        var side: CGFloat = 1024, quality: CGFloat = 0.85
#if AIDOKU_DEVELOPER_PERFORMANCE
        // On-device A/B (DeveloperAutoRead) of the provider image size.
        let defaults = UserDefaults.standard
        if defaults.double(forKey: "AidokuPerfJPEGSide") > 0 { side = defaults.double(forKey: "AidokuPerfJPEGSide") }
        if defaults.double(forKey: "AidokuPerfJPEGQuality") > 0 { quality = defaults.double(forKey: "AidokuPerfJPEGQuality") }
#endif
        let ratio = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, (image.size.width * ratio).rounded()),
                          height: max(1, (image.size.height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: quality), data.count <= 4 * 1024 * 1024 else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        ReaderTranslationDiagnostics.record("v2_jpeg", count: data.count, code: Int(max(size.width, size.height)))
        return data
    }
}
