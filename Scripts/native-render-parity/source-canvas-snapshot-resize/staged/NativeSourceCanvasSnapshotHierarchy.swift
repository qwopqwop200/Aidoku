import UIKit

/// Test-only public scene-capture controls. The two routes deliberately distinguish
/// an already flattened PMA8 backing from the prefix plus original source drawing.
/// Existing production UI capture and historical Metal-resize observations stay intact.
@MainActor enum NativeSourceCanvasSnapshotHierarchy {
    nonisolated enum Failure: Error { case captureFailed, invalidOutput }

    static func captureFlattened(backing: CGImage, viewport: CGSize,
                                 contentsScale: CGFloat, captureScale: CGFloat) throws -> CGImage? {
        try capture(prefix: backing, source: nil, sourceFrame: nil, viewport: viewport,
                    contentsScale: contentsScale, captureScale: captureScale)
    }

    static func capturePreserved(prefix: CGImage, source: CGImage, sourceFrame: CGRect,
                                 viewport: CGSize, contentsScale: CGFloat, captureScale: CGFloat) throws -> CGImage? {
        try capture(prefix: prefix, source: source, sourceFrame: sourceFrame, viewport: viewport,
                    contentsScale: contentsScale, captureScale: captureScale)
    }

    private static func capture(prefix: CGImage, source: CGImage?, sourceFrame: CGRect?,
                                viewport: CGSize, contentsScale: CGFloat, captureScale: CGFloat) throws -> CGImage? {
        try Task.checkCancellation()
        guard contentsScale.isFinite, contentsScale > 0, captureScale == contentsScale / 2,
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              integral(viewport.width * contentsScale), integral(viewport.height * contentsScale),
              integral(viewport.width * captureScale), integral(viewport.height * captureScale),
              viewport.width * contentsScale <= 16_384, viewport.height * contentsScale <= 16_384,
              viewport.width * viewport.height * contentsScale * contentsScale <= 4_000_000,
              prefix.width == Int(viewport.width * contentsScale), prefix.height == Int(viewport.height * contentsScale),
              validImage(prefix, maximumPixels: 4_000_000) else { return nil }
        if let source {
            guard let sourceFrame, validImage(source, maximumPixels: 12_000_000),
                  sourceFrame.origin.x.isFinite, sourceFrame.origin.y.isFinite,
                  sourceFrame.width.isFinite, sourceFrame.height.isFinite,
                  sourceFrame.width > 0, sourceFrame.height > 0,
                  CGRect(origin: .zero, size: viewport).contains(sourceFrame),
                  integral(sourceFrame.minX * contentsScale, positive: false),
                  integral(sourceFrame.minY * contentsScale, positive: false),
                  integral(sourceFrame.width * contentsScale), integral(sourceFrame.height * contentsScale),
                  sourceFrame.width * sourceFrame.height * contentsScale * contentsScale <= 4_000_000,
                  sourceFrame.width * contentsScale <= CGFloat(source.width),
                  sourceFrame.height * contentsScale <= CGFloat(source.height) else { return nil }
        } else if sourceFrame != nil { return nil }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        let eligible = windows.filter {
            !$0.isHidden && $0.alpha > 0 && $0.rootViewController?.viewIfLoaded?.window === $0
        }
        guard let window = eligible.first(where: \.isKeyWindow) ?? eligible.first,
              contentsScale == window.screen.scale,
              let root = window.rootViewController?.viewIfLoaded else { return nil }
        try Task.checkCancellation()
        let captured: CGImage = try autoreleasepool {
            let ancestor = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            ancestor.isOpaque = false; ancestor.backgroundColor = .clear
            ancestor.clipsToBounds = true
            hiddenFromInteraction(ancestor)
            let host = UIView(frame: CGRect(origin: CGPoint(x: 2, y: 2), size: viewport))
            host.isOpaque = false; host.backgroundColor = .clear
            host.overrideUserInterfaceStyle = .light
            hiddenFromInteraction(host)
            ancestor.addSubview(host)
            root.addSubview(ancestor)
            defer { ancestor.removeFromSuperview() }
            let page = CGRect(origin: .zero, size: viewport)
            let prefixView = PrefixView(frame: page, image: prefix)
            prefixView.contentScaleFactor = contentsScale
            hiddenFromInteraction(prefixView)
            host.addSubview(prefixView)
            var sourceView: SourceView?
            if let source, let sourceFrame {
                let view = SourceView(frame: sourceFrame, image: source)
                view.contentScaleFactor = contentsScale
                view.layer.drawsAsynchronously = true
                hiddenFromInteraction(view)
                host.addSubview(view)
                sourceView = view
            }
            prefixView.setNeedsDisplay(); sourceView?.setNeedsDisplay()
            host.layoutIfNeeded()
            prefixView.layer.displayIfNeeded(); sourceView?.layer.displayIfNeeded()
            try Task.checkCancellation()
            let format = UIGraphicsImageRendererFormat()
            format.scale = captureScale; format.preferredRange = .standard; format.opaque = false
            var succeeded = false
            let image = UIGraphicsImageRenderer(size: viewport, format: format).image { _ in
                succeeded = host.drawHierarchy(in: page, afterScreenUpdates: true)
            }
            try Task.checkCancellation()
            guard succeeded, let output = image.cgImage else { throw Failure.captureFailed }
            guard output.width == Int(viewport.width * captureScale), output.height == Int(viewport.height * captureScale),
                  validImage(output, maximumPixels: 4_000_000) else { throw Failure.invalidOutput }
            return output
        }
        try Task.checkCancellation()
        return captured
    }

    private static func integral(_ value: CGFloat, positive: Bool = true) -> Bool {
        value.isFinite && (positive ? value > 0 : value >= 0) && value.rounded(.towardZero) == value
    }
    private static func validImage(_ image: CGImage, maximumPixels: Int) -> Bool {
        guard image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384,
              image.width <= maximumPixels / image.height, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.colorSpace?.name == CGColorSpace.sRGB else { return false }
        return [.premultipliedFirst, .premultipliedLast, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }
    private static func hiddenFromInteraction(_ view: UIView) {
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
    }
    private final class PrefixView: UIView {
        let image: CGImage
        init(frame: CGRect, image: CGImage) {
            self.image = image; super.init(frame: frame)
            isOpaque = false; backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("requires immutable image") }
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState(); defer { context.restoreGState() }
            context.setBlendMode(.copy); context.setShouldAntialias(false)
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: bounds)
        }
    }
    private final class SourceView: UIView {
        let image: CGImage
        init(frame: CGRect, image: CGImage) {
            self.image = image; super.init(frame: frame)
            isOpaque = false; backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("requires immutable image") }
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState(); defer { context.restoreGState() }
            context.setShouldAntialias(false)
            // Same source draw as production65/66: original interpolation quality.
            context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: bounds)
        }
    }
}
