import CoreGraphics
import Foundation
import ImageIO

/// Hard ceiling on decoded page pixels, shared by the reader's Nuke decoder, the
/// translation image loaders and the V2 page pipeline. A page above it is
/// downsampled (aspect kept) instead of being decoded or rasterized at full size:
/// a 100+ MP page would otherwise need 400+ MB per RGBA copy. Images at or below
/// the cap are never touched. Every helper takes `maxPixels` so tests can use
/// small synthetic images. This file is Foundation/ImageIO only so the V2 host CLI
/// compiles it with the V2 stages; the UIKit/Nuke helpers are in
/// `Core/Utilities/ImagePixelCap+Decoding.swift`.
enum ImagePixelCap {
    /// About 64 megapixels (256 MiB as RGBA8).
    static let maxPixels = 64 * 1024 * 1024

    static func exceeds(width: Int, height: Int, maxPixels: Int = maxPixels) -> Bool {
        guard width > 0, height > 0 else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow || pixels > maxPixels
    }

    /// The largest aspect-preserving size within `maxPixels`; the input size when
    /// it already fits (never upscales).
    static func cappedSize(width: Int, height: Int, maxPixels: Int = maxPixels) -> (width: Int, height: Int) {
        guard maxPixels > 0, exceeds(width: width, height: height, maxPixels: maxPixels) else { return (width, height) }
        let scale = (Double(maxPixels) / (Double(width) * Double(height))).squareRoot()
        var cappedWidth = max(1, min(width, Int((Double(width) * scale).rounded(.down))))
        var cappedHeight = max(1, min(height, Int((Double(height) * scale).rounded(.down))))
        // A side clamped up to 1 (extreme aspect) or floating-point rounding can leave the
        // area over the cap; shrink the longer side to fit exactly.
        if cappedWidth * cappedHeight > maxPixels {
            if cappedWidth >= cappedHeight {
                cappedWidth = max(1, maxPixels / cappedHeight)
            } else {
                cappedHeight = max(1, maxPixels / cappedWidth)
            }
        }
        return (cappedWidth, cappedHeight)
    }

    /// `kCGImageSourceThumbnailMaxPixelSize` (longest side) whose thumbnail fits
    /// `maxPixels`, or nil when the image already fits. ImageIO may round the
    /// short side up, so the bound accounts for that.
    static func thumbnailMaxPixelSize(width: Int, height: Int, maxPixels: Int = maxPixels) -> Int? {
        guard maxPixels > 0, exceeds(width: width, height: height, maxPixels: maxPixels) else { return nil }
        let long = Double(max(width, height)), short = Double(min(width, height))
        let capped = cappedSize(width: width, height: height, maxPixels: maxPixels)
        var side = max(capped.width, capped.height)
        while side > 1, side * max(1, Int((short * Double(side) / long).rounded(.up))) > maxPixels { side -= 1 }
        return side
    }

    // MARK: Header inspection

    /// Pixel dimensions from the image header; no pixels are decoded.
    static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return pixelSize(of: source)
    }

    /// RGBA8 bytes of the decode the capped decoders actually perform for `bytes`
    /// (a full-size estimate from the header).
    static func cappedDecodedBytes(_ bytes: UInt64, maxPixels: Int = maxPixels) -> UInt64 {
        min(bytes, UInt64(max(0, maxPixels)) * 4)
    }

    // MARK: Decoding

    /// Upright ImageIO thumbnail; never allocates the full-resolution bitmap.
    static func downsampledImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    // MARK: Rasters

    /// An already-decoded image within the cap is returned as is (same object);
    /// above it, a high-quality sRGB RGBA8 (premultipliedLast) redraw at
    /// `cappedSize`. Nil only when the smaller bitmap cannot be allocated.
    static func downscaled(_ image: CGImage, maxPixels: Int = maxPixels) -> CGImage? {
        guard exceeds(width: image.width, height: image.height, maxPixels: maxPixels) else { return image }
        let size = cappedSize(width: image.width, height: image.height, maxPixels: maxPixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: size.width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }
}
