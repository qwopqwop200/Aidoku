import Foundation
import CoreGraphics

/// Platform adapters around the production geometry/sizing functions extracted by the launcher.
/// Keep their policy in the app sources.
enum HostRenderGeometry {
    static let readerFitContract = "reader-aspect-fit-v2"
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

    /// Legacy host payloads have a page-sized viewport and zero-origin frame.
    /// Fresh payloads carry both the Reader viewport and its fitted source frame.
    static func savedFrames(_ payload: [String: Any], fallbackViewport: CGSize) throws -> (viewport: CGSize, display: CGRect) {
        func numbers(_ key: String, fallback: [Double]) throws -> [Double] {
            guard let value = payload[key] else { return fallback }
            // Fresh payloads may contain CGFloat; decoded JSON uses Double.
            guard let values = (value as? [CGFloat])?.map(Double.init) ?? value as? [Double],
                  values.count == fallback.count, values.allSatisfy(\.isFinite) else {
                throw geometryError("Invalid saved render " + key)
            }
            return values
        }
        let size = try numbers("hostViewport", fallback: [Double(fallbackViewport.width), Double(fallbackViewport.height)])
        guard size.allSatisfy({ $0 > 0 && $0 <= 16_384 }) else { throw geometryError("Invalid saved render viewport") }
        let pageFrame = [0.0, 0.0, size[0], size[1]]
        let frame: [Double]
        if let declared = payload["hostViewportContract"] {
            guard declared as? String == readerFitContract, payload["hostViewport"] != nil,
                  payload["hostDisplayRect"] != nil else { throw geometryError("Invalid saved render viewport contract") }
            frame = try numbers("hostDisplayRect", fallback: pageFrame)
        } else {
            // Legacy renderers treated hostDisplayRect as descriptive, not authoritative.
            frame = pageFrame
        }
        guard frame[2] > 0, frame[3] > 0, frame[0] >= -1e-8, frame[1] >= -1e-8,
              frame[0] + frame[2] <= size[0] + 1e-8, frame[1] + frame[3] <= size[1] + 1e-8 else {
            throw geometryError("Invalid saved render display frame")
        }
        return (CGSize(width: size[0], height: size[1]),
            CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
    }

    private static func geometryError(_ message: String) -> NSError {
        NSError(domain: "HostRenderGeometry", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
