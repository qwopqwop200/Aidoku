import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor
struct NativeKeptSourceCopyTests {
    @Test(arguments: ["contain", "cover"])
    func liveCopyUsesNormalizedBitmapGeometryAndViewportClip(fit: String) throws {
        let sourceSize = fit == "contain" ? CGSize(width: 4, height: 2) : CGSize(width: 2, height: 4)
        let source = UIGraphicsImageRenderer(size: sourceSize, format: format()).image { renderer in
            renderer.cgContext.setFillColor(UIColor.red.cgColor)
            renderer.cgContext.fill(CGRect(origin: .zero, size: sourceSize))
            renderer.cgContext.setFillColor(UIColor.blue.cgColor)
            renderer.cgContext.fill(CGRect(x: 0, y: sourceSize.height / 2,
                                          width: sourceSize.width, height: sourceSize.height / 2))
        }
        // The OCR planner's original aspect ratio differs from the normalized
        // bitmap. A live cloned IMG uses the latter; export restores originals.
        let viewport = CGSize(width: 8, height: 8)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 4, height: 3),
            sourceRect: CGRect(x: 0, y: 1, width: 8, height: 6), viewport: viewport, items: [], sourceObjectFit: fit)
        let geometry = try #require(NativeTranslationRenderer.normalizedCleanupGeometry(layout: layout, naturalSize: sourceSize))
        #expect(geometry.frame != layout.sourceRect)
        #expect(geometry.frame == (fit == "contain" ? CGRect(x: 0, y: 2, width: 8, height: 4)
                                  : CGRect(x: 0, y: -4, width: 8, height: 16)))
        let image = try #require(source.cgImage)
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format()).image { renderer in
            renderer.cgContext.interpolationQuality = .none
            NativeTranslationRenderer.drawKeptSourceCopy(source: image, geometry: geometry,
                pieces: [CGRect(x: 1, y: -2, width: 6, height: 12)], context: renderer.cgContext)
        }
        let pixels = try #require(rendered.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        var expected = [UInt8](repeating: 0, count: 10 * 10 * 4)
        let visibleRows = fit == "contain" ? 2..<6 : 0..<8
        for y in visibleRows {
            for x in 1..<7 {
                let offset = (y * 10 + x) * 4
                expected[offset + (y < 4 ? 0 : 2)] = 255
                expected[offset + 3] = 255
            }
        }
        #expect(pixels.bytes == expected)
    }

    @Test func missingCoverageLeavesTheOverlayTransparent() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format()).image { renderer in
            renderer.cgContext.setFillColor(UIColor.red.cgColor)
            renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let image = try #require(source.cgImage)
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format()).image { renderer in
            NativeTranslationRenderer.drawKeptSourceCopy(source: image,
                geometry: .init(frame: CGRect(x: 0, y: 0, width: 4, height: 4), clip: CGRect(x: 0, y: 0, width: 4, height: 4)),
                pieces: [], context: renderer.cgContext)
        }
        let pixels = try #require(rendered.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        #expect(pixels.bytes.allSatisfy { $0 == 0 })
    }

    private func format() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        format.opaque = false
        return format
    }
}
