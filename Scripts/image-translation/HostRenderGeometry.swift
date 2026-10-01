import Foundation
import CoreGraphics
import ImageIO

/// Platform adapters around the production geometry/sizing functions extracted by the launcher.
/// Keep their policy in the app sources; the host only supplies bitmap allocation and PNG encoding.
enum HostRenderGeometry {
    static func backgroundPixelSize(for size: CGSize) -> CGSize {
        ReaderTranslationBackgroundImage.pixelSize(for: size)
    }

    static func outputPixelSize(for size: CGSize) -> CGSize {
        HostProductionExportSizing.outputSize(for: size)
    }

    static func parseViewport(_ text: String) throws -> CGSize {
        let parts = text.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw geometryError("Viewport must be WIDTHxHEIGHT in screen points, with positive finite dimensions up to 16384")
        }
        return CGSize(width: width, height: height)
    }

    static func displayRect(imageSize: CGSize, viewport: CGSize, aspectFit: Bool = true) -> CGRect {
        ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: imageSize, bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit)
    }

    /// Matches the reader's rendered-page pixel budget for a given screen scale.
    static func loadedOutputPixelSize(imageSize: CGSize, viewport: CGSize, screenScale: CGFloat,
                                      aspectFit: Bool = true) -> CGSize {
        guard screenScale.isFinite, screenScale > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let rect = displayRect(imageSize: imageSize, viewport: viewport, aspectFit: aspectFit)
        let pixelScale = max(rect.width / imageSize.width, rect.height / imageSize.height) * max(1, screenScale)
        return backgroundPixelSize(for: CGSize(width: imageSize.width * pixelScale, height: imageSize.height * pixelScale))
    }

    static func preparedBackground(_ image: CGImage) throws -> CGImage {
        try Task.checkCancellation()
        let source = CGSize(width: image.width, height: image.height)
        let size = backgroundPixelSize(for: source)
        guard size.width > 0, size.height > 0 else { throw geometryError("Invalid source image dimensions") }
        if size == source { return image }
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw geometryError("Cannot allocate bounded WebKit background")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let resized = context.makeImage() else { throw geometryError("Cannot resize WebKit background") }
        try Task.checkCancellation()
        return resized
    }

    static func backgroundDataURL(for image: CGImage) throws -> String {
        let background = try preparedBackground(image)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw geometryError("Cannot encode WebKit background")
        }
        CGImageDestinationAddImage(destination, background, nil)
        guard CGImageDestinationFinalize(destination) else { throw geometryError("Cannot encode WebKit background") }
        try Task.checkCancellation()
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    private static func geometryError(_ message: String) -> NSError {
        NSError(domain: "HostRenderGeometry", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
