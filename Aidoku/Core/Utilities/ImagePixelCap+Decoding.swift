import Foundation
import ImageIO
import Nuke
import UIKit

extension ImagePixelCap {
    /// `UIImage(data:)` within the cap (unchanged behavior); above it, an upright
    /// thumbnail bounded by `maxPixels`, checked from the header before decoding.
    static func decodeImage(_ data: Data, maxPixels: Int = maxPixels) -> UIImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let size = pixelSize(of: source),
           let side = thumbnailMaxPixelSize(width: size.width, height: size.height, maxPixels: maxPixels) {
            guard let image = downsampledImage(from: source, maxPixelSize: side) else { return nil }
            return UIImage(cgImage: image, scale: 1, orientation: .up)
        }
        return UIImage(data: data)
    }

    /// Nuke thumbnail options that keep a decode of a `width` x `height` image within
    /// `maxPixels`, or nil when it already fits.
    static func thumbnailOptions(width: Int, height: Int, maxPixels: Int = maxPixels) -> ImageRequest.ThumbnailOptions? {
        thumbnailMaxPixelSize(width: width, height: height, maxPixels: maxPixels)
            .map { ImageRequest.ThumbnailOptions(maxPixelSize: Float($0)) }
    }

    /// Decode-time cap for the global Nuke pipeline: an over-cap page that requests
    /// no thumbnail (e.g. reader downsampling off) is decoded through the default
    /// decoder's thumbnail path, regardless of the reader setting. Contexts within
    /// the cap, or that already request a thumbnail, are returned unchanged.
    static func decodingContext(_ context: ImageDecodingContext, maxPixels: Int = maxPixels) -> ImageDecodingContext {
        guard context.request.thumbnail == nil, let size = pixelSize(of: context.data),
              let options = thumbnailOptions(width: size.width, height: size.height, maxPixels: maxPixels)
        else { return context }
        var capped = context
        capped.request.thumbnail = options
        return capped
    }
}
