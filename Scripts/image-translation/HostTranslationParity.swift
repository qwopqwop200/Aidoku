import Foundation
import CoreGraphics
import ImageIO

/// Creates the white-backed JPEG used in page translation requests on macOS.
enum HostTranslationParity {
    static func translationJPEG(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0 else {
            throw RemoteTranslationError.invalidRequest("The page image is empty.")
        }
        let ratio = min(1, 2048 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        CGImageDestinationAddImage(destination, normalized,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 4 * 1024 * 1024 else {
            throw RemoteTranslationError.invalidRequest("The page image could not be prepared for translation.")
        }
        return data as Data
    }
}
