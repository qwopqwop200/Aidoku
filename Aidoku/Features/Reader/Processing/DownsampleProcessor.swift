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
        "com.github.Aidoku/Aidoku/downsample?s=\(size)"
    }

    func process(_ image: PlatformImage) -> PlatformImage? {
        let scaleHor = size.width / image.size.width
        let scaleVert = size.height / image.size.height
        let scale = min(scaleHor, scaleVert)

        if scale == 1 {
            return image // no need to scale
        } else if scale > 1 {
            return image // don't want to upscale
        }

        let finalSize = CGSize(
            width: CGFloat(round(image.size.width * scale)),
            height: CGFloat(round(image.size.height * scale))
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
