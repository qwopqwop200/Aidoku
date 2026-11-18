// Focused native capture geometry controls. No corpus, OCR, network, or saved PDF.
// Compile with the actual NativeTranslationPDFCapture.swift implementation.
import CoreGraphics
import Foundation
import Darwin

@main
struct NativePDFLogicalBoundsControls {
    static func alphaAtBottom(_ image: CGImage) throws -> Int {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw NativeTranslationPDFCapture.CaptureError.unavailable
        }
        // Identity copying preserves the capture CGImage's stored row order.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let x = image.width / 2
        return Int(data[((image.height - 1) * image.width + x) * 4 + 3])
    }

    static func main() throws {
        let boundsList = [
            CGRect(x: 0, y: 0, width: 43, height: 65.9968),
            CGRect(x: 0.25, y: -0.125, width: 43.75, height: 65.875),
            CGRect(x: -0.25, y: 0.375, width: 43.75, height: 65.875)
        ]
        let pixels = CGSize(width: 176, height: 264)
        var results: [[String: Any]] = []
        var problems: [String] = []
        for bounds in boundsList {
            for scale: CGFloat in [1, 1.75, 3] {
                for normalized in [false, true] {
                    let capture = try NativeTranslationPDFCapture.capture(bounds: bounds, pixels: pixels,
                        deviceScale: scale, alignsToLogicalBounds: normalized) { context in
                        context.setFillColor(CGColor(gray: 0, alpha: 1))
                        context.fill(CGRect(x: bounds.midX - 4, y: bounds.maxY - 0.125,
                            width: 8, height: 0.125))
                    }
                    let alpha = try alphaAtBottom(capture.image)
                    // All normalized cases preserve the terminal logical strip.
                    // The unnormalized origin0 arm is a causal positive clipping control.
                    if normalized && alpha == 0 { problems.append("normalized logical bottom strip disappeared") }
                    if !normalized && bounds.origin == .zero {
                        if alpha != 0 { problems.append("unnormalized fractional crop did not clip terminal strip") }
                    }
                    results.append(["origin": [bounds.minX, bounds.minY],
                        "logicalExtent": [bounds.width, bounds.height],
                        "mediaExtent": [capture.mediaBox.width, capture.mediaBox.height],
                        "scale": scale, "normalized": normalized, "bottomAlpha": alpha])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["passed": problems.isEmpty, "cases": results,
            "problems": problems,
            "scope": "actual native PDF capture/raster transform with synthetic terminal rectangle; not glyph/layout/composite GT",
            "PDFSaved": false, "OCRorAPI": false], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !problems.isEmpty { exit(1) }
    }
}
