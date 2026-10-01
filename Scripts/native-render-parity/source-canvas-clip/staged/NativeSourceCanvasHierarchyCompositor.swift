import UIKit

/// Realizes a normal source-image draw through UIKit's window-associated recording
/// path. Every temporary view belongs to this synchronous MainActor call. Only
/// immutable images and numeric geometry cross the render-worker boundary.
@MainActor enum NativeSourceCanvasHierarchyCompositor {
    nonisolated struct Request: Sendable {
        let prefix: CGImage
        let source: CGImage
        let viewport: CGSize
        let scale: CGFloat
        let sourceFrame: CGRect
        let opacity: CGFloat
        let blendMode: CGBlendMode

        nonisolated init(prefix: CGImage, source: CGImage, viewport: CGSize,
                         scale: CGFloat, sourceFrame: CGRect, opacity: CGFloat = 1,
                         blendMode: CGBlendMode = .normal) {
            self.prefix = prefix
            self.source = source
            self.viewport = viewport
            self.scale = scale
            self.sourceFrame = sourceFrame
            self.opacity = opacity
            self.blendMode = blendMode
        }
    }

    nonisolated enum Failure: Error { case captureFailed, invalidCaptureFormat }

    /// nil declines unsupported geometry/image formats or an absent foreground
    /// window before allocating views. Capture failures throw; cancellation always
    /// propagates. The caller may use its ordinary renderer for a non-cancel failure.
    /// No task hop or suspension occurs while a temporary hierarchy is attached.
    static func compose(_ request: Request,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> CGImage? {
        try checkCancellation()
        guard let pixelSize = admittedPixelSize(request) else { return nil }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        let eligible = windows.filter {
            !$0.isHidden && $0.alpha > 0 && $0.rootViewController?.viewIfLoaded?.window === $0
        }
        guard let window = eligible.first(where: \.isKeyWindow) ?? eligible.first,
              let root = window.rootViewController?.viewIfLoaded,
              root.bounds.width > 0, root.bounds.height > 0 else { return nil }
        // The proven recording route uses the actual window's device scale. Other
        // scales keep the ordinary renderer until their source transport is proven.
        guard request.scale == window.screen.scale else { return nil }
        try checkCancellation()
        let image: CGImage = try autoreleasepool {
            let ancestor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            ancestor.clipsToBounds = true
            ancestor.isOpaque = false
            ancestor.backgroundColor = .clear
            disableInteraction(ancestor)
            let host = UIView(frame: CGRect(origin: CGPoint(x: 2, y: 2), size: request.viewport))
            host.backgroundColor = .clear
            host.isOpaque = false
            host.overrideUserInterfaceStyle = .light
            disableInteraction(host)
            ancestor.addSubview(host)
            root.addSubview(ancestor)
            defer { ancestor.removeFromSuperview() }

            let page = CGRect(origin: .zero, size: request.viewport)
            let prefix = PrefixPaintView(frame: page, image: request.prefix)
            prefix.contentScaleFactor = request.scale
            disableInteraction(prefix)
            host.addSubview(prefix)
            let source = SourcePaintView(frame: request.sourceFrame, image: request.source)
            source.contentScaleFactor = request.scale
            source.layer.drawsAsynchronously = true
            disableInteraction(source)
            host.addSubview(source)
            prefix.setNeedsDisplay()
            source.setNeedsDisplay()
            host.layoutIfNeeded()
            prefix.layer.displayIfNeeded()
            source.layer.displayIfNeeded()
            try checkCancellation()

            let format = UIGraphicsImageRendererFormat()
            format.scale = request.scale
            format.preferredRange = .standard
            format.opaque = false
            var succeeded = false
            let rendered = UIGraphicsImageRenderer(size: request.viewport, format: format).image { _ in
                succeeded = host.drawHierarchy(in: page, afterScreenUpdates: true)
            }
            try checkCancellation()
            guard succeeded, let result = rendered.cgImage else { throw Failure.captureFailed }
            guard result.width == pixelSize.width, result.height == pixelSize.height,
                  admittedImage(result, maximumPixels: 4_000_000) else { throw Failure.invalidCaptureFormat }
            return result
        }
        // The owned ancestor has already been removed before this final checkpoint.
        try checkCancellation()
        return image
    }

    private static func admittedPixelSize(_ request: Request) -> (width: Int, height: Int)? {
        guard request.opacity == 1, request.blendMode == .normal,
              request.viewport.width.isFinite, request.viewport.height.isFinite,
              request.viewport.width > 0, request.viewport.height > 0,
              request.scale.isFinite, request.scale > 0 else { return nil }
        let wp = request.viewport.width * request.scale, hp = request.viewport.height * request.scale
        guard integralDevice(wp), integralDevice(hp), wp <= 16_384, hp <= 16_384 else { return nil }
        let width = Int(wp.rounded()), height = Int(hp.rounded())
        guard width * height <= 4_000_000,
              request.prefix.width == width, request.prefix.height == height,
              admittedImage(request.prefix, maximumPixels: 4_000_000),
              admittedImage(request.source, maximumPixels: 12_000_000) else { return nil }
        let frame = request.sourceFrame
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, frame.minX >= 0, frame.minY >= 0,
              frame.maxX <= request.viewport.width, frame.maxY <= request.viewport.height else { return nil }
        let sw = frame.width * request.scale, sh = frame.height * request.scale
        guard integralDevice(sw), integralDevice(sh), integralDevice(frame.minX * request.scale, positive: false),
              integralDevice(frame.minY * request.scale, positive: false), sw <= 16_384, sh <= 16_384,
              sw * sh <= 4_000_000,
              sw <= CGFloat(request.source.width), sh <= CGFloat(request.source.height) else { return nil }
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

    private static func disableInteraction(_ view: UIView) {
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
    }

    @MainActor private final class PrefixPaintView: UIView {
        let image: CGImage
        init(frame: CGRect, image: CGImage) {
            self.image = image
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("requires immutable image") }
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState()
            context.setBlendMode(.copy)
            context.setShouldAntialias(false)
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: bounds)
            context.restoreGState()
        }
    }

    @MainActor private final class SourcePaintView: UIView {
        let image: CGImage
        init(frame: CGRect, image: CGImage) {
            self.image = image
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("requires immutable image") }
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState()
            context.setShouldAntialias(false)
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: bounds)
            context.restoreGState()
        }
    }
}
