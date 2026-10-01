import CoreGraphics
import Foundation
import QuartzCore

/// Bounded live-only foreign-background composition. The caller's fresh bitmap
/// capability attests normal alpha-one painting and the unmodified root clip.
/// PDF, rotated/clipped/rounded panels and oversized viewports stay on the
/// existing painter. This uses a whole prefix; no cropped dither phase is guessed.
nonisolated enum NativeForeignBackgroundCompositor {
    static let maximumPixels = 4_000_000
    static let maximumLayers = 2

    struct Result { let image: CGImage; let frame: CGRect }
    private struct Gradient { let destination: CGRect; let tile: CGRect; let color: CGColor }

    static func compose(panel: NativeTranslationSourceStylePostPolish.Panel,
                        foreign: [NativeCaptionPacking.ForeignFill], context: CGContext,
                        backing: NativeCanvasBacking?) throws -> Result? {
        try Task.checkCancellation()
        guard !Thread.isMainThread, let backing, backing.matchesFreshState(context),
              !foreign.isEmpty, foreign.count <= maximumLayers,
              panel.radius == 0, !panel.clipped, !panel.overflowClip, panel.sourceFrameImage == nil,
              context.width > 0, context.height > 0,
              context.width <= maximumPixels / context.height else { return nil }
        let transform = context.ctm
        let frame = context.boundingBoxOfClipPath
        let pixels = CGSize(width: context.width, height: context.height)
        guard frame.origin == .zero, frame.width > 0, frame.height > 0,
              transform.a > 0, transform.d == -transform.a, transform.b == 0, transform.c == 0,
              context.convertToDeviceSpace(frame) == CGRect(origin: .zero, size: pixels),
              let baseColor = color(panel.background) else { return nil }
        let scale = transform.a
        let paintedBorder = NativeTranslationPDFCapture.snappedRect(panel.rect, deviceScale: scale)
        guard let basePixels = leafPixels(paintedBorder, scale: scale), paintedBorder.intersects(frame) else { return nil }
        var gradients: [Gradient] = []
        var declaredPixels = basePixels
        for fill in foreign.reversed() {
            guard let position = fill.backgroundPosition, let size = fill.backgroundSize,
                  let geometry = NativeForeignBackgroundGradient.geometry(owner: panel.rect,
                    position: position, size: size, deviceScale: scale), !geometry.usesPattern,
                  let fillColor = color(fill.color),
                  leafPixels(geometry.destination, scale: scale) != nil,
                  let tilePixels = leafPixels(geometry.tile, scale: scale),
                  tilePixels <= Double(maximumPixels) - declaredPixels else { return nil }
            declaredPixels += tilePixels
            gradients.append(.init(destination: geometry.destination, tile: geometry.tile, color: fillColor))
        }
        // At 4MP the explicit prefix + target + aligned readback + canonical
        // output + provider copy are <= ~81MB in aggregate, excluding the caller
        // bitmap and private CA allocations. Resources do not survive this call.
        guard let prefix = backing.backgroundRGBA(context: context, userRect: frame),
              prefix.count == context.width * context.height * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: prefix as CFData),
              let prefixImage = CGImage(width: context.width, height: context.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: context.width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        try Task.checkCancellation()
        let capture = try NativeLayerTreeCapture.capture(size: frame.size, scale: scale,
            checkCancellation: { try Task.checkCancellation() }, makeRoot: {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                let root = CALayer(); root.frame = frame; root.contentsScale = scale
                let prefixLayer = CALayer(); prefixLayer.frame = frame
                prefixLayer.contents = prefixImage; prefixLayer.contentsScale = scale
                prefixLayer.contentsGravity = .resize
                prefixLayer.minificationFilter = .nearest; prefixLayer.magnificationFilter = .nearest
                // Canonical prefix bytes are top-row-first; CARenderer's raw
                // CGImage leaf orientation is the opposite of its geometry.
                // Flip only this fixed-frame image leaf, never the whole graph.
                prefixLayer.transform = CATransform3DMakeScale(1, -1, 1)
                root.addSublayer(prefixLayer)
                let base = CALayer(); base.frame = paintedBorder; base.contentsScale = scale
                base.backgroundColor = baseColor; root.addSublayer(base)
                for value in gradients {
                    let clip = CALayer(); clip.frame = value.destination
                    clip.contentsScale = scale; clip.masksToBounds = true
                    let gradient = CAGradientLayer()
                    gradient.frame = value.tile.offsetBy(dx: -value.destination.minX, dy: -value.destination.minY)
                    gradient.contentsScale = scale; gradient.type = .axial
                    gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
                    gradient.locations = [0,1]; gradient.colors = [value.color,value.color]
                    clip.addSublayer(gradient); root.addSublayer(clip)
                }
                return root
            })
        try Task.checkCancellation()
        guard capture.pixelSize == pixels else { return nil }
        return Result(image: capture.image, frame: frame)
    }

    private static func color(_ rgb: [Double]) -> CGColor? {
        guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGColor(colorSpace: space, components: rgb.map { CGFloat(Float($0 / 255)) } + [1])
    }
    private static func finite(_ rect: CGRect) -> Bool {
        [rect.origin.x,rect.origin.y,rect.width,rect.height].allSatisfy(\.isFinite)
    }
    private static func leafPixels(_ rect: CGRect, scale: CGFloat) -> Double? {
        guard finite(rect), rect.width > 0, rect.height > 0 else { return nil }
        let width = Double(rect.width * scale), height = Double(rect.height * scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= Double(NativeCanvasTextureResampler.maximumDimension),
              height <= Double(NativeCanvasTextureResampler.maximumDimension),
              ceil(width) * ceil(height) <= Double(maximumPixels) else { return nil }
        return ceil(width) * ceil(height)
    }
}
