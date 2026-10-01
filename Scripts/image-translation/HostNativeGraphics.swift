import AppKit
import CoreGraphics
import Foundation

/// Platform adapters for the production UIKit-shaped API. The renderer's layout,
/// restoration, text, PDF, and pixel kernels are compiled from production files.
/// ImageIO normalizes CLI input orientation before this image enters the renderer.
struct UIImage: @unchecked Sendable {
    enum Orientation: Sendable { case up }
    let cgImage: CGImage?
    let scale: CGFloat
    let imageOrientation: Orientation
    var size: CGSize {
        guard let cgImage else { return .zero }
        return CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
    }

    init(cgImage: CGImage, scale: CGFloat = 1, orientation: Orientation = .up) {
        self.cgImage = cgImage
        self.scale = scale
        imageOrientation = orientation
    }

    fileprivate init() {
        cgImage = nil
        scale = 1
        imageOrientation = .up
    }

    func draw(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        drawPixels(in: rect, context: context)
    }

    func draw(in rect: CGRect, blendMode: CGBlendMode, alpha: CGFloat) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(blendMode)
        context.setAlpha(alpha)
        drawPixels(in: rect, context: context)
    }

    private func drawPixels(in rect: CGRect, context: CGContext) {
        guard let cgImage else { return }
        // Production drawing coordinates have their origin at the top left.
        // CGImage's native Quartz orientation therefore needs this local flip.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: rect.size))
    }
}

private final class HostGraphicsContextStack: NSObject {
    var contexts: [CGContext] = []
}

private let hostGraphicsContextKey = "app.aidoku.image-translation.graphics-context-stack"

func UIGraphicsPushContext(_ context: CGContext) {
    let dictionary = Thread.current.threadDictionary
    let stack = dictionary[hostGraphicsContextKey] as? HostGraphicsContextStack ?? HostGraphicsContextStack()
    stack.contexts.append(context)
    dictionary[hostGraphicsContextKey] = stack
}

func UIGraphicsPopContext() {
    let dictionary = Thread.current.threadDictionary
    guard let stack = dictionary[hostGraphicsContextKey] as? HostGraphicsContextStack else { return }
    _ = stack.contexts.popLast()
    if stack.contexts.isEmpty { dictionary.removeObject(forKey: hostGraphicsContextKey) }
}

func UIGraphicsGetCurrentContext() -> CGContext? {
    (Thread.current.threadDictionary[hostGraphicsContextKey] as? HostGraphicsContextStack)?.contexts.last
}

final class UIGraphicsImageRendererFormat {
    enum Range { case standard }
    var scale: CGFloat = 1
    var opaque = false
    var preferredRange: Range = .standard
}

struct UIGraphicsImageRendererContext {
    let cgContext: CGContext
}

struct UIGraphicsImageRenderer {
    let size: CGSize
    let format: UIGraphicsImageRendererFormat

    func image(actions: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let width = ceil(size.width * format.scale), height = ceil(size.height * format.scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 16_384, height <= 16_384, width * height <= 12_000_000,
              format.scale.isFinite, format.scale > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                  bitsPerComponent: 8, bytesPerRow: Int(width) * 4, space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                      (format.opaque ? CGImageAlphaInfo.noneSkipFirst.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue)) else {
            return UIImage()
        }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: format.scale, y: -format.scale)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        actions(UIGraphicsImageRendererContext(cgContext: context))
        guard let image = context.makeImage() else { return UIImage() }
        return UIImage(cgImage: image, scale: format.scale)
    }
}

/// A macOS command-line process has no UIKit window-associated recording
/// capability. Decline only that optional live-display fast path. Offline export
/// calls the production PDF painter and retains all restoration/image features.
@MainActor enum NativeSourceCanvasHierarchyCompositor {
    nonisolated struct Request: Sendable {
        let prefix: CGImage
        let source: CGImage
        let viewport: CGSize
        let scale: CGFloat
        let sourceFrame: CGRect
        var opacity: CGFloat = 1
        var blendMode: CGBlendMode = .normal
        var outputSize: CGSize? = nil
    }

    static func compose(_ request: Request,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> CGImage? {
        try checkCancellation()
        return nil
    }
}

extension CGRect {
    func inset(by insets: UIEdgeInsets) -> CGRect {
        CGRect(x: minX + insets.left, y: minY + insets.top,
               width: width - insets.left - insets.right, height: height - insets.top - insets.bottom)
    }
}
