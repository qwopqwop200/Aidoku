import Foundation
import CoreGraphics

/// Platform adapters around the production geometry/sizing functions extracted by the launcher.
/// Keep their policy in the app sources.
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

    private static func geometryError(_ message: String) -> NSError {
        NSError(domain: "HostRenderGeometry", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
