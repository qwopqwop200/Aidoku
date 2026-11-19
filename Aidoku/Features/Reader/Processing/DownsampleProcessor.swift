//
//  DownsampleProcessor.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/17/22.
//

import Nuke
import UIKit

struct DownsampleProcessor: ImageProcessing {
    private let size: CGSize
    @MainActor
    let scaleFactor = UIScreen.main.scale

    @MainActor
    init(size: CGSize) {
        self.size = size
    }

    @MainActor
    init(width: CGFloat) {
        self.size = CGSize(width: width, height: CGFloat.infinity)
    }

    var identifier: String {
        "com.github.Aidoku/Aidoku/downsample-v2?s=\(size)&scale=\(scaleFactor)"
    }

    func process(_ image: PlatformImage) -> PlatformImage? {
        guard size.width > 0, size.height > 0, !size.width.isNaN, !size.height.isNaN,
              image.size.width > 0, image.size.height > 0 else { return image }
        let scaleHor = size.width / image.size.width
        let scaleVert = size.height / image.size.height
        let scale = min(scaleHor, scaleVert)

        if scale == 1 {
            return image // no need to scale
        } else if scale > 1 {
            return image // don't want to upscale
        }

        let finalSize = CGSize(
            width: max(1 / scaleFactor, round(image.size.width * scale * scaleFactor) / scaleFactor),
            height: max(1 / scaleFactor, round(image.size.height * scale * scaleFactor) / scaleFactor)
        )

        // Resample the processed pixels directly. Encoding the full image as PNG
        // first duplicates a large page and performs a needless encode/decode cycle.
        return autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scaleFactor
            format.preferredRange = .standard
            format.opaque = false
            return UIGraphicsImageRenderer(size: finalSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: finalSize))
            }
        }
    }
}

extension DownsampleProcessor {
    /// Decode-time counterpart of `init(width:)`. ImageIO then never allocates
    /// the full-resolution bitmap (a 20 MP page is 80 MB) before this processor
    /// shrinks it. Pixel dimensions match the processor, which stays in the chain
    /// and only normalizes the image scale. Never upscales. Only use it when no
    /// earlier processor (crop borders, source page processing) needs full pixels.
    static func decodeThumbnail(width: CGFloat) -> ImageRequest.ThumbnailOptions? {
        guard width.isFinite, width > 0 else { return nil }
        // A finite height keeps the target bounded if ImageIO reports no size.
        return ImageRequest.ThumbnailOptions(
            size: CGSize(width: width, height: 1_000_000),
            unit: .points,
            contentMode: .aspectFit
        )
    }
}
