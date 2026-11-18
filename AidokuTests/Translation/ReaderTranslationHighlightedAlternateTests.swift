import CoreGraphics
import Gifu
import Testing
import UIKit
import VisionKit

/// Viewer feasibility only: no translation service, image requests, or model.
@Suite(.serialized) @MainActor
struct ReaderTranslationHighlightedAlternateTests {
    @Test(arguments: [false, true])
    func alternateDisplayIsOnePlaneAndKeepsTheOriginalImage(gifu: Bool) throws {
        let original = try page(translated: false)
        let settled = try page(translated: true)
        #expect(original.size == settled.size)
        let view: UIImageView = gifu ? GIFImageView() : UIImageView()
        view.image = original
        let liveText = ImageAnalysisInteraction()
        // No analysis is assigned; this is an attachment/geometry assertion,
        // not proof of live VisionKit analysis or gesture outcomes.
        view.addInteraction(liveText)
        let actual = fixture(view)
        let reference = fixture(UIImageView())
        let intrinsic = view.intrinsicContentSize
        let geometry = view.bounds

        for (mode, zoom, filter): (UIView.ContentMode, CGFloat, CALayerContentsFilter) in [
            (.scaleAspectFit, 1, .linear),
            (.scaleToFill, 0.72, .linear),
            (.scaleAspectFit, 1.33, .nearest),
        ] {
            configure(actual, mode: mode, zoom: zoom, filter: filter)
            configure(reference, mode: mode, zoom: zoom, filter: filter)

            reference.view.image = original
            let originalFrame = try raster(actual.root)
            #expect(originalFrame == (try raster(reference.root)))
            #expect(originalFrame.alpha.contains { $0 > 0 && $0 < 255 })

            UIView.performWithoutAnimation {
                view.highlightedImage = settled
                view.isHighlighted = true
            }
            reference.view.image = settled // One reference plane, never an overlay over the source.
            let expected = try raster(reference.root)
            #expect(expected != originalFrame)
            #expect(try raster(actual.root) == expected)
            // A second layer/display pass must not revive the underlying image.
            #expect(try raster(actual.root) == expected)
            #expect(view.image === original)
            #expect(view.highlightedImage === settled)
            #expect(view.intrinsicContentSize == intrinsic)
            #expect(view.bounds == geometry && view.contentMode == mode)
            #expect(view.layer.minificationFilter == filter && view.layer.magnificationFilter == filter)
            #expect(liveText.view === view)
            #expect(actual.marker.superview === view)
            #expect(view.hitTest(CGPoint(x: 2, y: 2), with: nil) === actual.marker)
            if let gif = view as? GIFImageView {
                #expect(gif.frameCount == 0 && !gif.isAnimatingGIF)
            }

            UIView.performWithoutAnimation {
                view.isHighlighted = false
                view.highlightedImage = nil
            }
            #expect(view.image === original)
            #expect(try raster(actual.root) == originalFrame)
        }
    }

    @Test func settledNoOpAndResetDoNotReplaceGifuSource() throws {
        let original = try page(translated: false)
        let noOp = UIImage(cgImage: try #require(original.cgImage), scale: original.scale, orientation: .up)
        let view = GIFImageView()
        let presentation = fixture(view)
        configure(presentation, mode: .scaleAspectFit, zoom: 1, filter: .linear)
        view.image = original
        let before = try raster(presentation.root)
        view.highlightedImage = noOp
        view.isHighlighted = true
        #expect(try raster(presentation.root) == before)
        #expect(view.image === original)

        // This fixture explicitly releases the candidate alternate before
        // reuse; it does not assume Gifu owns or clears highlighted state.
        view.isHighlighted = false
        view.highlightedImage = nil
        view.prepareForReuse()
        let replacement = try page(translated: true)
        view.image = replacement
        let normal = fixture(UIImageView(image: replacement))
        configure(normal, mode: .scaleAspectFit, zoom: 1, filter: .linear)
        #expect(view.image === replacement)
        #expect(!view.isHighlighted && view.highlightedImage == nil)
        #expect(try raster(presentation.root) == raster(normal.root))
    }

    private struct Fixture {
        let root: UIView
        let view: UIImageView
        let marker: UIView
    }

    private func fixture(_ view: UIImageView) -> Fixture {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 48, height: 40))
        root.isOpaque = false
        root.backgroundColor = .clear
        view.bounds = CGRect(x: 0, y: 0, width: 27.5, height: 21.25)
        view.center = CGPoint(x: 23.75, y: 20.25)
        view.isOpaque = false
        view.isUserInteractionEnabled = true
        view.backgroundColor = .clear
        let marker = UIView(frame: CGRect(x: 1, y: 1, width: 4, height: 4))
        marker.backgroundColor = .purple
        view.addSubview(marker)
        root.addSubview(view)
        return Fixture(root: root, view: view, marker: marker)
    }

    private func configure(_ fixture: Fixture, mode: UIView.ContentMode, zoom: CGFloat, filter: CALayerContentsFilter) {
        fixture.view.contentMode = mode
        fixture.view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        fixture.view.layer.minificationFilter = filter
        fixture.view.layer.magnificationFilter = filter
    }

    private func raster(_ view: UIView) throws -> Raster {
        view.layoutIfNeeded()
        for child in view.subviews {
            // Request the ordinary display lifecycle; never manually invoke
            // Gifu's layer delegate or assign backing contents.
            child.setNeedsDisplay()
            child.layer.displayIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let image = try #require(rendered.cgImage)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: rgb, bitmapInfo: bitmap.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        let buffer = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
        return Raster(rgba: Array(buffer))
    }

    private struct Raster: Equatable {
        let rgba: [UInt8]
        var alpha: [UInt8] { stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] } }
    }

    private var rgb: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }
    private var bitmap: CGBitmapInfo {
        .byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func page(translated: Bool) throws -> UIImage {
        let width = 24, height = 16
        let palette: [[UInt8]] = [[100, 25, 10, 128], [30, 80, 60, 255], [0, 0, 0, 0], [10, 50, 4, 64]]
        var rgba: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let cell = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                let altered = translated && x >= 15 && x <= 19 && y >= 2 && y <= 4
                rgba += altered ? [0, 25, 225, 255] : palette[cell]
            }
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: rgb, bitmapInfo: bitmap, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }
}
