import CoreGraphics
import Foundation

/// Composes admitted source canvases on the render worker. The retained name also
/// serves older capture callers; no live window or temporary UIKit layers are needed.
/// Device-aligned geometry and premultiplied source-over alpha remain unchanged.
enum NativeSourceCanvasHierarchyCompositor {
    struct Request: Sendable {
        let prefix: CGImage
        let source: CGImage
        let viewport: CGSize
        let scale: CGFloat
        let sourceFrame: CGRect
        let opacity: CGFloat
        let blendMode: CGBlendMode
        /// Logical capture size; nil preserves the full viewport. Minified output
        /// is derived from the completed device-density canvas.
        let outputSize: CGSize?

        init(prefix: CGImage, source: CGImage, viewport: CGSize,
             scale: CGFloat, sourceFrame: CGRect, opacity: CGFloat = 1,
             blendMode: CGBlendMode = .normal, outputSize: CGSize? = nil) {
            self.prefix = prefix
            self.source = source
            self.viewport = viewport
            self.scale = scale
            self.sourceFrame = sourceFrame
            self.opacity = opacity
            self.blendMode = blendMode
            self.outputSize = outputSize
        }
    }

    enum Failure: Error { case captureFailed, invalidCaptureFormat }

    /// Paint directly into the worker's existing top-left bitmap. Declines before
    /// touching unsupported state; the caller retains its ordinary source renderer.
    /// This route allocates no viewport copy and never crosses to the main actor.
    static func draw(source: CGImage, sourceFrame: CGRect, viewport: CGSize,
                     scale: CGFloat, in context: CGContext) throws -> Bool {
        try Task.checkCancellation()
        guard let size = admittedSourceSize(source: source, frame: sourceFrame, viewport: viewport, scale: scale),
              context.width == size.width, context.height == size.height,
              context.bitsPerComponent == 8, context.bitsPerPixel == 32,
              context.colorSpace?.name == CGColorSpace.sRGB,
              [.premultipliedFirst, .premultipliedLast].contains(context.alphaInfo) else { return false }
        let matrix = context.ctm
        guard matrix.a == scale, matrix.d == -scale, matrix.b == 0, matrix.c == 0,
              matrix.tx == 0, matrix.ty == CGFloat(size.height) else { return false }
        paint(source, frame: sourceFrame, in: context, blendMode: .normal, interpolation: .default)
        try Task.checkCancellation()
        return true
    }

    /// Compatibility capture for immutable prefixes and optional smaller outputs.
    /// Production drawing uses `draw` to avoid allocating this extra full canvas.
    static func compose(_ request: Request,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> CGImage? {
        try checkCancellation()
        guard let size = admittedPixelSize(request) else { return nil }
        try checkCancellation()
        let image: CGImage = try autoreleasepool {
            let context = try bitmap(width: request.prefix.width, height: request.prefix.height)
            context.translateBy(x: 0, y: CGFloat(request.prefix.height))
            context.scaleBy(x: request.scale, y: -request.scale)
            paint(request.prefix, frame: CGRect(origin: .zero, size: request.viewport),
                  in: context, blendMode: .copy, interpolation: .none)
            try checkCancellation()
            paint(request.source, frame: request.sourceFrame, in: context, blendMode: .normal, interpolation: .default)
            guard let fullImage = context.makeImage() else { throw Failure.captureFailed }
            let result: CGImage
            if size.width == fullImage.width, size.height == fullImage.height {
                result = fullImage
            } else {
                // Source minification occurs at device density before optional
                // output scaling, so outputSize never changes source geometry.
                let output = try bitmap(width: size.width, height: size.height)
                output.setBlendMode(.copy)
                output.interpolationQuality = .default
                output.draw(fullImage, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                guard let captured = output.makeImage() else { throw Failure.captureFailed }
                result = captured
            }
            try checkCancellation()
            guard result.width == size.width, result.height == size.height,
                  admittedImage(result, maximumPixels: 4_000_000) else { throw Failure.invalidCaptureFormat }
            return result
        }
        try checkCancellation()
        return image
    }

    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw Failure.captureFailed }
        return context
    }

    private static func paint(_ image: CGImage, frame: CGRect, in context: CGContext,
                              blendMode: CGBlendMode, interpolation: CGInterpolationQuality) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(blendMode)
        context.setAlpha(1)
        context.setShouldAntialias(false)
        context.interpolationQuality = interpolation
        context.clip(to: frame)
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
    }

    private static func admittedPixelSize(_ request: Request) -> (width: Int, height: Int)? {
        guard request.opacity == 1, request.blendMode == .normal,
              let full = admittedSourceSize(source: request.source, frame: request.sourceFrame,
                viewport: request.viewport, scale: request.scale),
              request.prefix.width == full.width, request.prefix.height == full.height,
              admittedImage(request.prefix, maximumPixels: 4_000_000) else { return nil }
        let output = request.outputSize ?? request.viewport
        guard output.width.isFinite, output.height.isFinite, output.width > 0, output.height > 0,
              output.width <= request.viewport.width, output.height <= request.viewport.height else { return nil }
        let xRatio = output.width / request.viewport.width, yRatio = output.height / request.viewport.height
        // Representation error of equivalent ratios only; no geometry tolerance.
        guard abs(xRatio - yRatio) <= 2 * max(xRatio.ulp, yRatio.ulp) else { return nil }
        let ow = output.width * request.scale, oh = output.height * request.scale
        guard integralDevice(ow), integralDevice(oh), ow <= 16_384, oh <= 16_384 else { return nil }
        let width = Int(ow.rounded()), height = Int(oh.rounded())
        guard width > 0, height > 0, width * height <= 4_000_000 else { return nil }
        return (width, height)
    }

    private static func admittedSourceSize(source: CGImage, frame: CGRect, viewport: CGSize,
                                           scale: CGFloat) -> (width: Int, height: Int)? {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              scale.isFinite, scale > 0 else { return nil }
        let wp = viewport.width * scale, hp = viewport.height * scale
        guard integralDevice(wp), integralDevice(hp), wp <= 16_384, hp <= 16_384 else { return nil }
        let width = Int(wp.rounded()), height = Int(hp.rounded())
        guard width > 0, height > 0, width * height <= 4_000_000,
              admittedImage(source, maximumPixels: 12_000_000),
              frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, frame.minX >= 0, frame.minY >= 0,
              frame.maxX <= viewport.width, frame.maxY <= viewport.height else { return nil }
        let sw = frame.width * scale, sh = frame.height * scale
        guard integralDevice(sw), integralDevice(sh), integralDevice(frame.minX * scale, positive: false),
              integralDevice(frame.minY * scale, positive: false), sw <= 16_384, sh <= 16_384,
              sw * sh <= 4_000_000, sw <= CGFloat(source.width), sh <= CGFloat(source.height) else { return nil }
        return (width, height)
    }

    private static func integralDevice(_ value: CGFloat, positive: Bool = true) -> Bool {
        value.isFinite && (positive ? value > 0 : value >= 0)
            && abs(value - value.rounded()) <= 2 * value.ulp
    }

    private static func admittedImage(_ image: CGImage, maximumPixels: Int) -> Bool {
        guard image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384,
              image.width * image.height <= maximumPixels, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.colorSpace?.name == CGColorSpace.sRGB else { return false }
        switch image.alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .noneSkipFirst, .noneSkipLast: return true
        default: return false
        }
    }
}
