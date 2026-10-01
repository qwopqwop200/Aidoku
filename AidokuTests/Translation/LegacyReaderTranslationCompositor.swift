import UIKit
import CoreImage
import ImageIO
@testable import Aidoku

enum LegacyReaderTranslationCompositor {
    typealias ExportLayers = ReaderTranslationImageExporter.ExportLayers
    enum ExportError: Error { case renderFailed }
    /// Core Image contexts are thread-safe and expensive to create; the
    /// composite gate already serializes production use.
    nonisolated(unsafe) private static let compositeContext = CIContext(options: [.workingColorSpace: NSNull()])

    nonisolated static func composite(image: UIImage, typography: Data, layers: ExportLayers,
                                             displayRect: CGRect, size: CGSize) throws -> UIImage {
        try Task.checkCancellation()
        guard displayRect.minX.isFinite, displayRect.minY.isFinite,
              displayRect.width.isFinite, displayRect.height.isFinite, displayRect.width > 0, displayRect.height > 0,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw ExportError.renderFailed }
        let scale = size.width / displayRect.width
        let scaleY = size.height / displayRect.height
        guard scale.isFinite, scaleY.isFinite else { throw ExportError.renderFailed }
        func outputFrame(_ values: [CGFloat]) throws -> CGRect {
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                throw ExportError.renderFailed
            }
            let frame = CGRect(x: (values[0] - displayRect.minX) * scale,
                               y: (values[1] - displayRect.minY) * scaleY,
                               width: values[2] * scale, height: values[3] * scaleY)
            guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else {
                throw ExportError.renderFailed
            }
            return frame
        }
        var maskPixels = 0
        let masks = try layers.masks.map { mask -> (UIImage, CGRect, CGFloat) in
            try Task.checkCancellation()
            guard mask.opacity.isFinite, (0...1).contains(mask.opacity),
                  mask.png.hasPrefix("data:image/png;base64,"),
                  let encoded = mask.png.split(separator: ",", maxSplits: 1).last,
                  let data = Data(base64Encoded: String(encoded)),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= 8_192, height <= 8_192,
                  width * height <= 4_000_000, maskPixels + width * height <= 16_000_000,
                  let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ExportError.renderFailed
            }
            maskPixels += width * height
            return (UIImage(cgImage: pixels), try outputFrame(mask.frame), mask.opacity)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let destination = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let surfaces = try layers.surfaces.map { surface in
            guard surface.radius.isFinite, surface.radius >= 0, surface.blur.isFinite, surface.blur >= 0,
                  surface.saturation.isFinite, surface.saturation >= 0 else { throw ExportError.renderFailed }
            return (surface, try outputFrame(surface.frame))
        }
        let paintBounds = try layers.paintBounds.map(outputFrame)
        guard (layers.sourceRestorations?.count ?? 0) <= 1_024 else { throw ExportError.renderFailed }
        let sourceRestorations = try (layers.sourceRestorations ?? []).map(outputFrame)
        guard let provider = CGDataProvider(data: typography as CFData),
              let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { throw ExportError.renderFailed }
        let pageBounds = page.getBoxRect(.mediaBox)
        guard pageBounds.minX.isFinite, pageBounds.minY.isFinite, pageBounds.width.isFinite, pageBounds.height.isFinite,
              pageBounds.width > 0, pageBounds.height > 0 else { throw ExportError.renderFailed }
        // Original pixels bypass WebKit's 4 MP background copy entirely.
        func drawCleaned() {
            image.draw(in: destination)
            for (mask, rect, opacity) in masks { mask.draw(in: rect, blendMode: .normal, alpha: opacity) }
        }
        // A malformed export layer must never overwrite unrelated artwork.
        // Clip even the vector page to the measured translation/text bounds.
        func drawTypography(_ context: CGContext) {
            guard !paintBounds.isEmpty else { return }
            context.saveGState()
            context.addRects(paintBounds)
            context.clip()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: size.width / pageBounds.width, y: -size.height / pageBounds.height)
            context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
        func restoreSource(_ context: CGContext) {
            guard !sourceRestorations.isEmpty, !paintBounds.isEmpty else { return }
            context.saveGState()
            context.addRects(paintBounds)
            context.clip()
            context.addRects(sourceRestorations)
            context.clip()
            image.draw(in: destination)
            context.restoreGState()
        }
        // Without backdrop surfaces nothing samples the cleaned page, so paint
        // it straight into the output: the same draws in the same order and
        // format, without a second full-page bitmap and copy.
        if surfaces.isEmpty {
            let output = renderer.image { drawing in
                drawCleaned()
                drawTypography(drawing.cgContext)
                restoreSource(drawing.cgContext)
            }
            try Task.checkCancellation()
            return output
        }
        let cleaned = renderer.image { _ in drawCleaned() }
        guard let cgImage = cleaned.cgImage else { throw ExportError.renderFailed }
        let source = CIImage(cgImage: cgImage).clampedToExtent()
        let context = compositeContext
        var failure = false
        let output = renderer.image { drawing in
            cleaned.draw(in: destination)
            for (surface, frame) in surfaces {
                let crop = frame.integral.intersection(destination)
                guard !crop.isEmpty else { continue }
                let filtered = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: surface.blur * scale])
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: surface.saturation])
                let ciRect = CGRect(x: crop.minX, y: size.height - crop.maxY, width: crop.width, height: crop.height)
                guard let patch = context.createCGImage(filtered, from: ciRect) else { failure = true; continue }
                drawing.cgContext.saveGState()
                UIBezierPath(roundedRect: frame, cornerRadius: surface.radius * scale).addClip()
                UIImage(cgImage: patch).draw(in: crop)
                drawing.cgContext.restoreGState()
            }
            drawTypography(drawing.cgContext)
            restoreSource(drawing.cgContext)
        }
        guard !failure else { throw ExportError.renderFailed }
        try Task.checkCancellation()
        return output
    }

}
