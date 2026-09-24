import UIKit
import CoreImage
import ImageIO
import WebKit

@MainActor
enum ReaderTranslationImageExporter {
    enum ExportError: Error { case unavailable, renderFailed }
    private static let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private static let compositeGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private static var idleOverlay: ReaderTranslationOverlayView?
    private static var eviction: Task<Void, Never>?
    private static var warningObserver: NSObjectProtocol?
    private struct RenderedPage {
        let image: UIImage
        let asset: ReaderTranslationRenderAsset
    }

    static func clearIdleRenderer() {
        eviction?.cancel(); eviction = nil
        idleOverlay?.cancelWork(); idleOverlay = nil
    }

    private static func release(_ overlay: ReaderTranslationOverlayView) {
        overlay.removeFromSuperview()
        guard overlay.contentTerminationCount == 0,
              ReaderTranslationSession.processAvailableMemory() >= TranslationImageWorkBudget.minimumHeadroom else {
            overlay.cancelWork()
            return
        }
        overlay.resetForExportReuse()
        idleOverlay = overlay
        eviction?.cancel()
        eviction = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            clearIdleRenderer()
        }
    }

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
                       viewport: CGSize, aspectFit: Bool, host: UIView, hasImagePermit: Bool = false) async throws -> UIImage {
        if !hasImagePermit {
            let bytes = image.cgImage.map { UInt64($0.bytesPerRow) * UInt64($0.height) } ?? 0
            return try await TranslationImageWorkBudget.shared.withPermit(decodedBytes: bytes) {
                try await render(image: image, regions: regions, settings: settings, viewport: viewport,
                                 aspectFit: aspectFit, host: host, hasImagePermit: true)
            }
        }
        return try await gate.withPermit {
            try await renderSerial(image: image, regions: regions, settings: settings,
                                   viewport: viewport, aspectFit: aspectFit, host: host).image
        }
    }

    /// Complete an already-loaded source before presenting it. Replaying a
    /// settled asset uses only Core Graphics/Core Image and works without a window.
    /// A legacy text/layout-only cache needs one export to create that asset.
    static func renderLoadedImage(
        image: UIImage, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
        viewport: CGSize, scale: CGFloat, aspectFit: Bool, dark: Bool,
        host: UIView?, cache: ReaderTranslationRenderCache?, key: String, pageIdentity: String? = nil
    ) async throws -> UIImage {
        try Task.checkCancellation()
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              scale.isFinite, image.size.width > 0, image.size.height > 0 else { throw ExportError.unavailable }
        let rect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: image.size, bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit)
        let pixelScale = max(rect.width / image.size.width, rect.height / image.size.height) * max(1, scale)
        let size = ReaderTranslationBackgroundImage.pixelSize(for: CGSize(
            width: image.size.width * pixelScale, height: image.size.height * pixelScale))
        guard size.width > 0, size.height > 0 else { throw ExportError.unavailable }
        let storage = cache?.renderAssetStorageContext(settings: settings)
        let fingerprint = Task.detached(priority: .userInitiated) {
            (source: cache == nil ? nil : ReaderTranslationRenderAsset.digestSource(image),
             regions: ReaderTranslationRenderAsset.digest(regions))
        }
        defer { fingerprint.cancel() }
        let assetRead = Task { await cache?.renderAsset(for: key) }
        defer { assetRead.cancel() }
        let digests = await withTaskCancellationHandler { await fingerprint.value } onCancel: { fingerprint.cancel() }
        let sourceDigest = digests.source
        let bitmapKey = sourceDigest.map {
            ReaderTranslationRenderCache.loadedImageKey(renderKey: key, regionsDigest: digests.regions, sourceDigest: $0, size: size)
        }
        try Task.checkCancellation()
        if let bitmapKey, let image = cache?.cachedImage(for: bitmapKey) {
            ReaderTranslationDiagnostics.record("loaded_composite_memory_hit")
            return image
        }
        let candidate = await withTaskCancellationHandler { await assetRead.value } onCancel: { assetRead.cancel() }
        try Task.checkCancellation()
        let cached = candidate.flatMap {
            $0.sourceSize == image.size && $0.regionsDigest == digests.regions && sourceDigest != nil && $0.sourceDigest == sourceDigest ? $0 : nil
        }
        // Native replay must not wait behind an offscreen WebKit/PDF render.
        // Only the bounded native composite stage is shared with cold rendering.
        if let cached {
            do {
                let result = try await compositeLoadedImage(image, asset: cached, size: size)
                if let cache, let storage, let bitmapKey, let pageIdentity {
                    cache.storeLoadedImage(result, key: bitmapKey, pageIdentity: pageIdentity, context: storage)
                }
                ReaderTranslationDiagnostics.record("render_asset_replayed")
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Corrupt disk data is a cache miss. Do not retry the same
                // broken recipe on every image-load attempt.
                await cache?.removeRenderAsset(for: key)
            }
        }
        // The reader already owns decoded pixels. Reacquiring the shared OCR/
        // image permit here could deadlock against a preloader awaiting display.
        guard host != nil else { throw ExportError.unavailable }
        return try await gate.withPermit { @MainActor in
            try Task.checkCancellation()
            if let bitmapKey, let image = cache?.cachedImage(for: bitmapKey) { return image }
            // A prefetch may have completed while this request waited for
            // WebKit. Its viewport bitmap has a different key, but its settled
            // asset can still satisfy this load without another document render.
            let prepared = await cache?.renderAsset(for: key)
            try Task.checkCancellation()
            if let prepared, prepared.sourceSize == image.size, prepared.regionsDigest == digests.regions,
               sourceDigest != nil, prepared.sourceDigest == sourceDigest {
                do {
                    let result = try await compositeLoadedImage(image, asset: prepared, size: size)
                    if let cache, let storage, let bitmapKey, let pageIdentity {
                        cache.storeLoadedImage(result, key: bitmapKey, pageIdentity: pageIdentity, context: storage)
                    }
                    ReaderTranslationDiagnostics.record("render_asset_replayed")
                    return result
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await cache?.removeRenderAsset(for: key)
                }
            }
            try Task.checkCancellation()
            guard let host, UIApplication.shared.applicationState == .active else { throw ExportError.unavailable }
            let layout = Task { () throws -> Data in
                let layoutKey = ReaderTranslationRenderCache.layoutKey(renderKey: key, regions: regions)
                if let data = await cache?.layoutData(for: layoutKey) { return data }
                return try await BrowserPageImageOverlayRenderer.prepareLayoutData(
                    items: ReaderTranslationRegion.overlayItems(regions, imageSize: image.size),
                    imageSize: image.size, sourceRect: rect, settings: settings.overlay,
                    targetLanguage: settings.targetLanguage, viewport: viewport)
            }
            defer { layout.cancel() }
            let result = try await renderSerial(image: image, regions: regions, settings: settings,
                viewport: viewport, aspectFit: aspectFit, host: host, pixelSize: size,
                preparedLayout: layout, dark: dark, sourceDigest: sourceDigest)
            try Task.checkCancellation()
            if let cache, let storage {
                cache.storeRenderAssetAfterDisplay(result.asset, key: key, context: storage)
                if let bitmapKey, let pageIdentity {
                    cache.storeLoadedImage(result.image, key: bitmapKey, pageIdentity: pageIdentity, context: storage)
                }
            }
            return result.image
        }
    }

    private static func compositeLoadedImage(_ image: UIImage, asset: ReaderTranslationRenderAsset, size: CGSize) async throws -> UIImage {
        // Lock order is WebKit -> native for cold work; warm work takes only
        // native. Neither path waits for the shared image/OCR admission permit.
        try await compositeGate.withPermit {
            let operation = Task.detached(priority: .userInitiated) {
                try composite(image: image, typography: asset.typography, layers: asset.layers,
                              displayRect: asset.displayRect, size: size)
            }
            let result = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            return result
        }
    }

    /// Capture every translated region, including tiles outside the screen. The
    /// input is already decoded by the reader/preloader; do not reacquire its
    /// image permit (the preloader holds it until this capture completes).
    /// The export gate serializes the extra renderer and composite at 4 MP.
    static func renderCacheSnapshot(
        image: UIImage, imageSize: CGSize, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
        viewport: CGSize, scale: CGFloat, aspectFit: Bool, host: UIView, dark: Bool,
        preparedLayout: Task<Data, Error>?, assetCache: ReaderTranslationRenderCache? = nil, assetKey: String? = nil,
        assetSourceDigest: String? = nil
    ) async throws -> UIImage {
        guard viewport.width > 0, viewport.height > 0 else { throw ExportError.unavailable }
        let factor = min(max(1, scale), sqrt(4_000_000 / viewport.width / viewport.height))
        let canvasSize = CGSize(width: max(1, floor(viewport.width * factor)), height: max(1, floor(viewport.height * factor)))
        let rect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: imageSize, bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit)
        let frame = CGRect(x: rect.minX * canvasSize.width / viewport.width,
            y: rect.minY * canvasSize.height / viewport.height,
            width: rect.width * canvasSize.width / viewport.width,
            height: rect.height * canvasSize.height / viewport.height)
        let storage = assetCache?.renderAssetStorageContext(settings: settings)
        let fingerprint = Task.detached(priority: .utility) {
            assetSourceDigest ?? (assetCache == nil ? nil : ReaderTranslationRenderAsset.digestSource(image))
        }
        defer { fingerprint.cancel() }
        return try await gate.withPermit { @MainActor in
            try Task.checkCancellation()
            let sourceDigest = await withTaskCancellationHandler { await fingerprint.value } onCancel: { fingerprint.cancel() }
            let result = try await renderSerial(image: image, regions: regions, settings: settings,
                viewport: viewport, aspectFit: aspectFit, host: host, logicalImageSize: imageSize,
                pixelSize: CGSize(width: max(1, floor(frame.width)), height: max(1, floor(frame.height))),
                preparedLayout: preparedLayout, dark: dark, sourceDigest: sourceDigest)
            try Task.checkCancellation()
            if let assetCache, let assetKey, let storage {
                assetCache.storeRenderAssetAfterDisplay(result.asset, key: assetKey, context: storage)
            }
            let page = result.image
            if rect == CGRect(origin: .zero, size: viewport) { return page }
            // Paged aspect-fit readers cache the entire viewport, including its
            // transparent letterbox, rather than stretching the cropped page.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: canvasSize, format: format).image { _ in page.draw(in: frame) }
        }
    }

    private static func renderSerial(image: UIImage, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
                                     viewport: CGSize, aspectFit: Bool, host: UIView, logicalImageSize: CGSize? = nil,
                                     pixelSize: CGSize? = nil, preparedLayout: Task<Data, Error>? = nil, dark: Bool? = nil,
                                     sourceDigest: String? = nil) async throws -> RenderedPage {
        try Task.checkCancellation()
        guard viewport.width > 0, viewport.height > 0,
              (host.window ?? (host as? UIWindow))?.windowScene != nil else { throw ExportError.unavailable }
        if warningObserver == nil {
            warningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil, queue: .main) { _ in Task { @MainActor in clearIdleRenderer() } }
        }
        eviction?.cancel(); eviction = nil
        let overlay = idleOverlay ?? ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
        idleOverlay = nil
        overlay.frame = CGRect(origin: .zero, size: viewport)
        overlay.overrideUserInterfaceStyle = dark.map { $0 ? .dark : .light } ?? .unspecified
        // A separate renderer avoids changing the reader's zoom, cached rendering, or visible DOM.
        host.insertSubview(overlay, at: 0)
        var completed = false
        defer {
            if completed { release(overlay) }
            else { overlay.cancelWork(); overlay.removeFromSuperview() }
        }
        let events = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        overlay.onRenderCommitted = { events.continuation.yield(true) }
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            events.continuation.yield(false)
        }
        defer { timeout.cancel(); overlay.onRenderCommitted = nil; events.continuation.finish() }
        var exportSettings = settings
        exportSettings.overlay.visible = true
        overlay.update(regions: regions, imageSize: logicalImageSize ?? image.size, aspectFit: aspectFit,
                       settings: exportSettings, image: image, preparedLayout: preparedLayout)
        overlay.layoutIfNeeded()
        let ready = await withTaskCancellationHandler {
            var iterator = events.stream.makeAsyncIterator()
            return await iterator.next() ?? false
        } onCancel: { events.continuation.finish() }
        try Task.checkCancellation()
        guard ready, !overlay.hasExhaustedRecovery else { throw ExportError.renderFailed }
        // WKWebView snapshots can spread backdrop-filter blur beyond the card,
        // including over translated glyphs. Bake only the bounded backdrop crops
        // with Core Image, and capture typography with all backdrop filters off.
        guard overlay.contentTerminationCount == 0 else { throw ExportError.renderFailed }
        let payload = try await overlay.webView.callAsyncJavaScript(Self.prepareExportScript,
            arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        guard let json = payload as? String, let data = json.data(using: .utf8) else { throw ExportError.renderFailed }
        let layers = try JSONDecoder().decode(ExportLayers.self, from: data)
        let rect = ReaderTranslationGeometry.displayRect(
            CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: logicalImageSize ?? image.size,
            bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit
        )
        let size = pixelSize ?? outputSize(for: image)
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
        let asset = ReaderTranslationRenderAsset(typography: typography, layers: layers, displayRect: rect,
            sourceSize: logicalImageSize ?? image.size, regions: regions, sourceDigest: sourceDigest)
        let result = try await compositeLoadedImage(image, asset: asset, size: size)
        try Task.checkCancellation()
        completed = true
        return RenderedPage(image: result, asset: asset)
    }

    struct ExportLayers: Codable, Sendable {
        struct Mask: Codable, Sendable {
            let frame: [CGFloat]
            let opacity: CGFloat
            let png: String
        }
        struct Surface: Codable, Sendable {
            let frame: [CGFloat]
            let radius: CGFloat
            let blur: CGFloat
            let saturation: CGFloat
        }
        let masks: [Mask]
        let surfaces: [Surface]
        let paintBounds: [[CGFloat]]
    }

    static let prepareExportScript = #"""
    await document.fonts.ready;
    const source = document.getElementById('reader-source-image');
    if (!source) throw new Error('Missing export background');
    await source.decode();
    const frame = node => {
      const r = node.getBoundingClientRect();
      return [r.x, r.y, r.width, r.height];
    };
    // Every source-pixel repair belongs to the image composite. PDF typography
    // is clipped to text/card bounds, which need not contain the original ink.
    const sourceLayers = [...document.querySelectorAll([
      'source-cleanup', 'source-panel-restoration', 'source-blur', 'source-readability-blur'
    ].map(kind => `[data-aidoku-image-ocr-overlay="${kind}"]`).join(','))];
    const masks = sourceLayers.map(node => ({
      frame: frame(node), opacity: Number(getComputedStyle(node).opacity), png: node.toDataURL('image/png')
    }));
    const surfaces = [];
    // Readability plates are vector surfaces, not repaired source pixels. Keep
    // them in the PDF and include their padding in the typography clipping union.
    const paintBounds = [...document.querySelectorAll(
      '[data-aidoku-image-ocr-overlay="source-readability-panel"]'
    )].map(frame);
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
    for (const node of sourceLayers) {
      node.style.visibility = 'hidden';
    }
    await Promise.race([
      new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
      new Promise(resolve => setTimeout(resolve, 150))
    ]);
    return JSON.stringify({masks, surfaces, paintBounds});
    """#

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
        // Without backdrop surfaces nothing samples the cleaned page, so paint
        // it straight into the output: the same draws in the same order and
        // format, without a second full-page bitmap and copy.
        if surfaces.isEmpty {
            let output = renderer.image { drawing in
                drawCleaned()
                drawTypography(drawing.cgContext)
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
