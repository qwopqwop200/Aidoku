import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// macOS drawing adapter for ReaderTranslationImageExporter.composite.
/// ExportLayers is extracted from that production source; its inputs come from
/// the native renderer’s actual PDF capture and source repair images.
/// The original, repair masks, bounded backdrop crops, PDF text, and source restoration
/// are painted in the same order; no GPU snapshot or matte-derived alpha is involved.
enum HostExportCompositor {
    private static let compositeContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Match ReaderTranslationImageExporter.encodeSourceMasks without serializing UIKit images.
    static func layers(for rendered: NativeTranslationRenderer.Result) throws -> HostProductionExporter.ExportLayers {
        var pixels = 0
        let masks = try rendered.sourcePatches.map { patch -> HostProductionExporter.ExportLayers.Mask in
            try Task.checkCancellation()
            try validateSourcePatch(patch, pixels: &pixels)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                throw failed("Cannot encode native source repair")
            }
            CGImageDestinationAddImage(destination, patch.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw failed("Cannot encode native source repair") }
            return .init(frame: [patch.rect.minX, patch.rect.minY, patch.rect.width, patch.rect.height],
                opacity: 1, png: "data:image/png;base64," + (data as Data).base64EncodedString())
        }
        return geometry(for: rendered, masks: masks)
    }

    /// Composite native patches directly; PNG/Base64 is only needed for the saved layer artifact.
    static func composite(image: CGImage, rendered: NativeTranslationRenderer.Result, typography: Data,
                          displayRect: CGRect, size: CGSize) throws -> CGImage {
        try composite(image: image, layers: geometry(for: rendered, masks: []), typography: typography,
            displayRect: displayRect, size: size, sourcePatches: rendered.sourcePatches)
    }

    static func composite(image: CGImage, layers: HostProductionExporter.ExportLayers, typography: Data,
                          displayRect: CGRect, size: CGSize) throws -> CGImage {
        try composite(image: image, layers: layers, typography: typography, displayRect: displayRect, size: size, sourcePatches: nil)
    }

    private static func geometry(for rendered: NativeTranslationRenderer.Result,
                                 masks: [HostProductionExporter.ExportLayers.Mask]) -> HostProductionExporter.ExportLayers {
        func values(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
        return .init(masks: masks, surfaces: [], paintBounds: rendered.paintBounds.map(values),
            sourceRestorations: rendered.sourceRestorationRects.map(values))
    }

    private static func validateSourcePatch(_ patch: NativeTranslationRenderer.SourcePatch, pixels: inout Int) throws {
        let width = patch.image.width, height = patch.image.height
        guard width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= 4_000_000, pixels + width * height <= 16_000_000 else {
            throw failed("Invalid native source repair dimensions")
        }
        pixels += width * height
    }

    private static func composite(image: CGImage, layers: HostProductionExporter.ExportLayers, typography: Data,
                                  displayRect: CGRect, size: CGSize,
                                  sourcePatches: [NativeTranslationRenderer.SourcePatch]?) throws -> CGImage {
        try Task.checkCancellation()
        guard displayRect.minX.isFinite, displayRect.minY.isFinite,
              displayRect.width.isFinite, displayRect.height.isFinite, displayRect.width > 0, displayRect.height > 0,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 16_384, size.height <= 16_384, size.width * size.height <= 12_000_000 else {
            throw failed("Invalid export dimensions")
        }
        let scale = size.width / displayRect.width, scaleY = size.height / displayRect.height
        guard scale.isFinite, scaleY.isFinite else { throw failed("Invalid export scale") }
        func outputFrame(_ values: [CGFloat]) throws -> CGRect {
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                throw failed("Invalid export layer frame")
            }
            let frame = CGRect(x: (values[0] - displayRect.minX) * scale,
                y: (values[1] - displayRect.minY) * scaleY, width: values[2] * scale, height: values[3] * scaleY)
            guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else {
                throw failed("Invalid export layer frame")
            }
            return frame
        }
        var maskPixels = 0
        let masks: [(CGImage, CGRect, CGFloat)]
        if let sourcePatches {
            masks = try sourcePatches.map { patch in
                try Task.checkCancellation()
                try validateSourcePatch(patch, pixels: &maskPixels)
                let rect = patch.rect
                return (patch.image, try outputFrame([rect.minX, rect.minY, rect.width, rect.height]), 1)
            }
        } else {
            masks = try layers.masks.map { mask -> (CGImage, CGRect, CGFloat) in
                try Task.checkCancellation()
                guard mask.opacity.isFinite, (0...1).contains(mask.opacity), mask.png.hasPrefix("data:image/png;base64,"),
                      let encoded = mask.png.split(separator: ",", maxSplits: 1).last,
                      let data = Data(base64Encoded: String(encoded)),
                      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      width > 0, height > 0, width <= 8_192, height <= 8_192,
                      width * height <= 4_000_000, maskPixels + width * height <= 16_000_000,
                      let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw failed("Invalid export repair mask") }
                maskPixels += width * height
                return (pixels, try outputFrame(mask.frame), mask.opacity)
            }
        }
        let surfaces = try layers.surfaces.map { surface in
            guard surface.radius.isFinite, surface.radius >= 0, surface.blur.isFinite, surface.blur >= 0,
                  surface.saturation.isFinite, surface.saturation >= 0 else { throw failed("Invalid export backdrop") }
            return (surface, try outputFrame(surface.frame))
        }
        let paintBounds = try layers.paintBounds.map(outputFrame)
        guard (layers.sourceRestorations?.count ?? 0) <= 1_024 else { throw failed("Too many source restorations") }
        let sourceRestorations = try (layers.sourceRestorations ?? []).map(outputFrame)
        guard let provider = CGDataProvider(data: typography as CFData), let pdf = CGPDFDocument(provider),
              let page = pdf.page(at: 1) else { throw failed("Invalid typography PDF") }
        let pageBounds = page.getBoxRect(.mediaBox)
        guard pageBounds.minX.isFinite, pageBounds.minY.isFinite, pageBounds.width.isFinite, pageBounds.height.isFinite,
              pageBounds.width > 0, pageBounds.height > 0 else { throw failed("Invalid typography PDF bounds") }
        let destination = CGRect(origin: .zero, size: size)
        let output = try bitmapContext(size: size)
        func drawCleaned(_ context: CGContext) {
            draw(image, in: destination, context: context)
            for (mask, rect, opacity) in masks { draw(mask, in: rect, context: context, opacity: opacity) }
        }
        func drawTypography(_ context: CGContext) {
            guard !paintBounds.isEmpty else { return }
            context.saveGState()
            context.addRects(paintBounds); context.clip()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: size.width / pageBounds.width, y: -size.height / pageBounds.height)
            context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
        func restoreSource(_ context: CGContext) {
            guard !sourceRestorations.isEmpty, !paintBounds.isEmpty else { return }
            context.saveGState()
            context.addRects(paintBounds); context.clip()
            context.addRects(sourceRestorations); context.clip()
            draw(image, in: destination, context: context)
            context.restoreGState()
        }
        drawCleaned(output)
        if !surfaces.isEmpty {
            guard let cleaned = output.makeImage() else { throw failed("Cannot create cleaned export bitmap") }
            let source = CIImage(cgImage: cleaned).clampedToExtent()
            for (surface, frame) in surfaces {
                try Task.checkCancellation()
                let crop = frame.integral.intersection(destination)
                guard !crop.isEmpty else { continue }
                let filtered = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: surface.blur * scale])
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: surface.saturation])
                let ciRect = CGRect(x: crop.minX, y: size.height - crop.maxY, width: crop.width, height: crop.height)
                guard let patch = compositeContext.createCGImage(filtered, from: ciRect) else { throw failed("Cannot bake export backdrop") }
                output.saveGState()
                output.addPath(CGPath(roundedRect: frame, cornerWidth: surface.radius * scale,
                    cornerHeight: surface.radius * scale, transform: nil))
                output.clip()
                draw(patch, in: crop, context: output)
                output.restoreGState()
            }
        }
        drawTypography(output)
        restoreSource(output)
        try Task.checkCancellation()
        guard let result = output.makeImage() else { throw failed("Cannot create export bitmap") }
        return result
    }

    /// Match UIKit's top-left drawing coordinates while preserving CGImage orientation.
    private static func bitmapContext(size: CGSize) throws -> CGContext {
        guard let context = CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failed("Cannot allocate export bitmap") }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private static func draw(_ image: CGImage, in rect: CGRect, context: CGContext, opacity: CGFloat = 1) {
        context.saveGState()
        context.setAlpha(opacity)
        context.setBlendMode(.normal)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func failed(_ message: String) -> NSError {
        NSError(domain: "HostExportCompositor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
