import UIKit
import CoreImage
import WebKit

@MainActor
enum ReaderTranslationImageExporter {
    enum ExportError: Error { case unavailable, renderFailed }

    // Full pages, including tall webtoons, stay within a bounded bitmap allocation.
    static func outputSize(for image: UIImage) -> CGSize {
        outputSize(for: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))
    }

    static func outputSize(for pixels: CGSize) -> CGSize {
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0 else { return .zero }
        let scale = min(1, 16_384 / max(pixels.width, pixels.height), sqrt(12_000_000 / pixels.width / pixels.height))
        return CGSize(width: max(1, floor(pixels.width * scale)), height: max(1, floor(pixels.height * scale)))
    }

    static func render(image: UIImage, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
                       viewport: CGSize, aspectFit: Bool, host: UIView) async throws -> UIImage {
        guard viewport.width > 0, viewport.height > 0, host.window != nil else { throw ExportError.unavailable }
        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
        // A separate renderer avoids changing the reader's zoom, cached rendering, or visible DOM.
        host.insertSubview(overlay, at: 0)
        defer { overlay.cancelWork(); overlay.removeFromSuperview() }
        var exportSettings = settings
        exportSettings.overlay.visible = true
        overlay.update(regions: regions, imageSize: image.size, aspectFit: aspectFit, settings: exportSettings, image: image)
        let deadline = Date().addingTimeInterval(20)
        while overlay.lastDiagnostic?.outcome != .committed {
            try Task.checkCancellation()
            guard Date() < deadline, !overlay.hasExhaustedRecovery else { throw ExportError.renderFailed }
            overlay.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        // WKWebView snapshots can spread backdrop-filter blur beyond the card,
        // including over translated glyphs. Bake only the bounded backdrop crops
        // with Core Image, and capture typography with all backdrop filters off.
        guard overlay.contentTerminationCount == 0 else { throw ExportError.renderFailed }
        let payload = try await overlay.webView.callAsyncJavaScript(Self.prepareExportScript,
            arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        guard let json = payload as? String, let data = json.data(using: .utf8) else { throw ExportError.renderFailed }
        let layers = try JSONDecoder().decode(ExportLayers.self, from: data)
        let rect = ReaderTranslationGeometry.displayRect(
            CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: image.size,
            bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit
        )
        let size = outputSize(for: image)
        // PDF paints DOM text without WebKit's on-screen GPU snapshot layers.
        // The reader may be occluded by the progress alert or scrolled offscreen.
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        let typography: Data = try await withCheckedThrowingContinuation { continuation in
            overlay.webView.createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }
        try Task.checkCancellation()
        guard overlay.contentTerminationCount == 0 else { throw ExportError.renderFailed }
        let result = try await Task.detached(priority: .userInitiated) {
            try composite(image: image, typography: typography, layers: layers, displayRect: rect, size: size)
        }.value
        try Task.checkCancellation()
        return result
    }

    private struct ExportLayers: Decodable, Sendable {
        struct Mask: Decodable, Sendable {
            let frame: [CGFloat]
            let opacity: CGFloat
            let png: String
        }
        struct Surface: Decodable, Sendable {
            let frame: [CGFloat]
            let radius: CGFloat
            let blur: CGFloat
            let saturation: CGFloat
        }
        let masks: [Mask]
        let surfaces: [Surface]
        let paintBounds: [[CGFloat]]
    }

    private static let prepareExportScript = #"""
    await document.fonts.ready;
    const source = document.getElementById('reader-source-image');
    if (!source) throw new Error('Missing export background');
    await source.decode();
    const frame = node => {
      const r = node.getBoundingClientRect();
      return [r.x, r.y, r.width, r.height];
    };
    const masks = [...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-cleanup"]')].map(node => ({
      frame: frame(node), opacity: Number(getComputedStyle(node).opacity), png: node.toDataURL('image/png')
    }));
    const surfaces = [];
    const paintBounds = [];
    for (const node of document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')) {
      const style = getComputedStyle(node);
      const range = document.createRange();
      range.selectNodeContents(node);
      const text = range.getBoundingClientRect();
      const box = node.getBoundingClientRect();
      const left = Math.min(box.left, text.width ? text.left : box.left) - 2;
      const top = Math.min(box.top, text.height ? text.top : box.top) - 2;
      const right = Math.max(box.right, text.width ? text.right : box.right) + 2;
      const bottom = Math.max(box.bottom, text.height ? text.bottom : box.bottom) + 2;
      paintBounds.push([left, top, right - left, bottom - top]);
      const filter = style.backdropFilter || style.webkitBackdropFilter || '';
      const blur = /blur\(([0-9.]+)px\)/.exec(filter);
      const saturation = /saturate\(([0-9.]+)\)/.exec(filter);
      if (blur) surfaces.push({frame: frame(node), radius: parseFloat(style.borderTopLeftRadius) || 0,
        blur: Number(blur[1]), saturation: saturation ? Number(saturation[1]) : 1});
      node.style.setProperty('backdrop-filter', 'none', 'important');
      node.style.setProperty('-webkit-backdrop-filter', 'none', 'important');
    }
    source.style.visibility = 'hidden';
    for (const node of document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-cleanup"]')) {
      node.style.visibility = 'hidden';
    }
    await Promise.race([
      new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
      new Promise(resolve => setTimeout(resolve, 150))
    ]);
    return JSON.stringify({masks, surfaces, paintBounds});
    """#

    private nonisolated static func composite(image: UIImage, typography: Data, layers: ExportLayers,
                                             displayRect: CGRect, size: CGSize) throws -> UIImage {
        let scale = size.width / displayRect.width
        let scaleY = size.height / displayRect.height
        func outputFrame(_ values: [CGFloat]) throws -> CGRect {
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                throw ExportError.renderFailed
            }
            return CGRect(x: (values[0] - displayRect.minX) * scale,
                          y: (values[1] - displayRect.minY) * scaleY,
                          width: values[2] * scale, height: values[3] * scaleY)
        }
        let masks = try layers.masks.map { mask -> (UIImage, CGRect, CGFloat) in
            guard let encoded = mask.png.split(separator: ",", maxSplits: 1).last,
                  let data = Data(base64Encoded: String(encoded)), let image = UIImage(data: data) else {
                throw ExportError.renderFailed
            }
            return (image, try outputFrame(mask.frame), mask.opacity)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let destination = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        // Original pixels bypass WebKit's 4 MP background copy entirely.
        let cleaned = renderer.image { _ in
            image.draw(in: destination)
            for (mask, rect, opacity) in masks { mask.draw(in: rect, blendMode: .normal, alpha: opacity) }
        }
        guard let cgImage = cleaned.cgImage else { throw ExportError.renderFailed }
        let source = CIImage(cgImage: cgImage).clampedToExtent()
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let surfaces = try layers.surfaces.map { surface in (surface, try outputFrame(surface.frame)) }
        let paintBounds = try layers.paintBounds.map(outputFrame)
        guard let provider = CGDataProvider(data: typography as CFData),
              let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { throw ExportError.renderFailed }
        let pageBounds = page.getBoxRect(.mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { throw ExportError.renderFailed }
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
            // A malformed export layer must never overwrite unrelated artwork.
            // Clip even the vector page to the measured translation/text bounds.
            if !paintBounds.isEmpty {
                drawing.cgContext.saveGState()
                drawing.cgContext.addRects(paintBounds)
                drawing.cgContext.clip()
                drawing.cgContext.translateBy(x: 0, y: size.height)
                drawing.cgContext.scaleBy(x: size.width / pageBounds.width, y: -size.height / pageBounds.height)
                drawing.cgContext.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
                drawing.cgContext.drawPDFPage(page)
                drawing.cgContext.restoreGState()
            }
        }
        guard !failure else { throw ExportError.renderFailed }
        try Task.checkCancellation()
        return output
    }

    static func saveAction(page: ReaderTranslationPage?, presenter: UIViewController) -> UIAction {
        UIAction(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"), image: UIImage(systemName: "character.bubble"),
                 attributes: page?.canExportTranslation == true ? [] : [.disabled]) { [weak page, weak presenter] _ in
            guard let page, let presenter else { return }
            Task { @MainActor in
                let progress = UIAlertController(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"),
                    message: NSLocalizedString("LOADING_ELLIPSIS"), preferredStyle: .alert)
                presenter.present(progress, animated: true)
                do {
                    let image = try await page.exportTranslatedImage(host: presenter.view)
                    progress.dismiss(animated: true) { image.saveToAlbum(viewController: presenter) }
                } catch {
                    progress.dismiss(animated: true) {
                        let alert = UIAlertController(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"),
                            message: NSLocalizedString("TRANSLATED_IMAGE_SAVE_FAILED"), preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
                        presenter.present(alert, animated: true)
                    }
                }
            }
        }
    }
}
