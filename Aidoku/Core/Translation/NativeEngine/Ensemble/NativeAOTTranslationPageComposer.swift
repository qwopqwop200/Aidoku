import CoreGraphics
import Foundation

/// Full-page restoration and complete transparent-text composition. Own on the existing serial render worker;
/// no global restored-image state and no legacy opaque panel paint commands.
final class NativeAOTTranslationPageComposer {
    struct TextLayer {
        let image: CGImage
        let expectedItems: Int
        let paintedItems: Int
        let complete: Bool
        let audit: [String: Any]
    }

    struct Result {
        let image: CGImage
        let restored: CGImage
        let text: CGImage
        let paintedItemCount: Int
        let audit: [String: Any]
        var removalMask: CGImage? = nil
    }

    enum Failure: Error {
        case invalidTextLayer
        case incompleteTranslation
        case allocation
        case cancelled
    }

    // Only Core ML construction needs iOS16. Keep the pure CG composition
    // boundary and its value types usable by the generic glyph painters.
    private let restoreSource: (CGImage, [UInt8], Int, Int) throws -> NativeAOTResult

    @available(iOS 16.0, macOS 13.0, *)
    init(compiledModelURL: URL) throws {
        let backend = try NativeResidentAOT(url: compiledModelURL)
        restoreSource = { source, mask, width, height in
            try backend.restore(source: source, originalMask: mask, maskWidth: width, maskHeight: height)
        }
    }

    /// Text shaping receives BOTH images: original for source-style prediction,
    /// reconstructed for actual background contrast. Its output is a full-page
    /// transparent layer with mandatory BW strokes already painted before fills.
    /// Errors propagate to the caller's existing renderer fallback, never to a
    /// restored page missing translations.
    func render(source: CGImage, removalMask: [UInt8],
                isCancelled: () -> Bool = { false },
                textLayer: (CGImage, CGImage) throws -> TextLayer) throws -> Result {
        let start = Date()
        guard !isCancelled() else { throw Failure.cancelled }
        let reconstruction = try restoreSource(source, removalMask, source.width, source.height)
        guard !isCancelled() else { throw Failure.cancelled }
        let textStart = Date()
        let layer = try textLayer(source, reconstruction.image)
        let textSeconds = Date().timeIntervalSince(textStart)
        guard layer.image.width == source.width, layer.image.height == source.height else {
            throw Failure.invalidTextLayer
        }
        guard layer.complete, layer.expectedItems == layer.paintedItems,
              layer.expectedItems >= 0 else { throw Failure.incompleteTranslation }
        guard !isCancelled() else { throw Failure.cancelled }
        let compositeStart = Date()
        guard let context = CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.allocation }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        // Both are complete CGImage rasters. There is no per-card Y conversion,
        // panel command replay, source patch or post-text erasure in this route.
        context.setBlendMode(.copy)
        context.draw(reconstruction.image, in: bounds)
        context.setBlendMode(.normal)
        context.draw(layer.image, in: bounds)
        guard let image = context.makeImage() else { throw Failure.allocation }
        return Result(image: image, restored: reconstruction.image, text: layer.image, paintedItemCount: layer.paintedItems,
            audit: ["restoration": reconstruction.coordinateAudit, "text": layer.audit,
                "expectedTranslationItems": layer.expectedItems, "paintedTranslationItems": layer.paintedItems,
                "textSeconds": textSeconds, "finalCompositeSeconds": Date().timeIntervalSince(compositeStart),
                "localRenderSeconds": Date().timeIntervalSince(start),
                "timingScope": "AOT through final composite; excludes upstream decode/OCR/RF/mask and LLM",
                "fullLocalPipelineProven": false, "mainApplied": false])
    }
}
