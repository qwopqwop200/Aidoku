import UIKit
import CoreImage
import ImageIO

@MainActor
enum ReaderTranslationImageExporter {
    enum ExportError: Error { case unavailable, renderFailed }
    private static let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private static let compositeGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private struct RenderedPage {
        let image: UIImage
        let asset: ReaderTranslationRenderAsset
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
                       viewport: CGSize, aspectFit: Bool, host: UIView, hasImagePermit: Bool = false,
                       onNativeDiagnostic: (@MainActor @Sendable (Data) throws -> Void)? = nil,
                       onNativePDFCapture: (@MainActor @Sendable (Data) throws -> Void)? = nil,
                       onNativeLayersCapture: (@MainActor @Sendable (Data) throws -> Void)? = nil) async throws -> UIImage {
        if !hasImagePermit {
            let bytes = image.cgImage.map { UInt64($0.bytesPerRow) * UInt64($0.height) } ?? 0
            return try await TranslationImageWorkBudget.shared.withPermit(decodedBytes: bytes) {
                try await render(image: image, regions: regions, settings: settings, viewport: viewport,
                                 aspectFit: aspectFit, host: host, hasImagePermit: true, onNativeDiagnostic: onNativeDiagnostic,
                                 onNativePDFCapture: onNativePDFCapture, onNativeLayersCapture: onNativeLayersCapture)
            }
        }
        return try await gate.withPermit {
            try await renderSerial(image: image, regions: regions, settings: settings,
                                   viewport: viewport, aspectFit: aspectFit, host: host, onNativeDiagnostic: onNativeDiagnostic,
                                   capturePDF: true, pdfDeviceScale: host.window?.screen.scale ?? UIScreen.main.scale,
                                   onNativePDFCapture: onNativePDFCapture, onNativeLayersCapture: onNativeLayersCapture).image
        }
    }

    /// Complete an already-loaded source before presenting it. Replaying a
    /// settled asset uses only Core Graphics/Core Image and works without a window.
    /// A legacy text/layout-only cache needs one export to create that asset.
    // swiftlint:disable:next function_parameter_count
    static func renderLoadedImage(
        image: UIImage, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
        viewport: CGSize, scale: CGFloat, aspectFit: Bool, dark: Bool,
        host: UIView?, cache: ReaderTranslationRenderCache?, key: String, pageIdentity: String? = nil,
        priority: TranslationRequestPriority = .foreground
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
        let fingerprint = Task.detached(priority: priority.isForeground ? .userInitiated : .utility) {
            (source: cache == nil ? nil : ReaderTranslationRenderAsset.digestSource(image),
             regions: ReaderTranslationRenderAsset.digest(regions))
        }
        defer { fingerprint.cancel() }
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
        // A completed bitmap needs no asset I/O or decoding. Start the optional
        // disk replay only after the content/source-aware memory lookup misses.
        let assetRead = Task { await cache?.renderAsset(for: key, priority: priority) }
        defer { assetRead.cancel() }
        let candidate = await withTaskCancellationHandler { await assetRead.value } onCancel: { assetRead.cancel() }
        try Task.checkCancellation()
        ReaderTranslationDiagnostics.record(candidate == nil ? "render_asset_miss" : "render_asset_candidate")
        let cached = candidate.flatMap {
            $0.sourceSize == image.size && $0.displayRect == rect && $0.supportsOutputSize(size)
                && $0.regionsDigest == digests.regions && sourceDigest != nil && $0.sourceDigest == sourceDigest ? $0 : nil
        }
        if candidate != nil, cached == nil { ReaderTranslationDiagnostics.record("render_asset_identity_mismatch") }
        // Completed overlay replay bypasses the native layout/render queue.
        // Only the bounded native composite stage is shared with cold rendering.
        if let cached {
            do {
                let result = try await compositeLoadedImage(image, asset: cached, size: size, priority: priority)
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
        let queuedAt = ProcessInfo.processInfo.systemUptime
        ReaderTranslationDiagnostics.record("export_queued")
        return try await gate.withPermit(priority: priority) { @MainActor in
            ReaderTranslationDiagnostics.record("export_admitted", elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - queuedAt) * 1000)
            try Task.checkCancellation()
            if let bitmapKey, let image = cache?.cachedImage(for: bitmapKey) { return image }
            // A prefetch may have completed while this request waited for
            // native rendering. Its viewport bitmap has a different key, but its settled
            // asset can still satisfy this load without another document render.
            let prepared = await cache?.renderAsset(for: key, priority: priority)
            try Task.checkCancellation()
            if let prepared, prepared.sourceSize == image.size, prepared.displayRect == rect, prepared.supportsOutputSize(size),
               prepared.regionsDigest == digests.regions,
               sourceDigest != nil, prepared.sourceDigest == sourceDigest {
                do {
                    let result = try await compositeLoadedImage(image, asset: prepared, size: size, priority: priority)
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
            let layout = Task { () throws -> Data in
                let layoutKey = ReaderTranslationRenderCache.layoutKey(renderKey: key, regions: regions)
                if let data = await cache?.layoutData(for: layoutKey) { return data }
                return try await NativeTranslationLayoutPlanner.prepareLayoutData(
                    items: ReaderTranslationRegion.layoutItems(regions, imageSize: image.size),
                    imageSize: image.size, sourceRect: rect, settings: settings.overlay,
                    targetLanguage: settings.targetLanguage, viewport: viewport)
            }
            defer { layout.cancel() }
            let result = try await renderSerial(image: image, regions: regions, settings: settings,
                viewport: viewport, aspectFit: aspectFit, host: host, pixelSize: size,
                preparedLayout: layout, dark: dark, sourceDigest: sourceDigest, priority: priority)
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

    static func compositeLoadedImage(_ image: UIImage, asset: ReaderTranslationRenderAsset, size: CGSize,
                                     priority: TranslationRequestPriority,
                                     limiter: TranslationProviderRequestLimiter = compositeGate) async throws -> UIImage {
        // Lock order is layout/render -> composite for cold work; warm work takes only
        // native. Neither path waits for the shared image/OCR admission permit.
        try await ReaderTranslationDiagnostics.measure("native_composite") {
            try await limiter.withPermit(priority: priority) {
                let operation = Task.detached(priority: priority.isForeground ? .userInitiated : .utility) {
                    try composite(image: image, typography: asset.typography, layers: asset.layers,
                                  displayRect: asset.displayRect, size: size,
                                  nativeBitmap: asset.version == ReaderTranslationRenderAsset.currentVersion && asset.typographySize != nil)
                }
                let result = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
                try Task.checkCancellation()
                return result
            }
        }
    }

    /// Capture every translated region, including tiles outside the screen. The
    /// input is already decoded by the reader/preloader; do not reacquire its
    /// image permit (the preloader holds it until this capture completes).
    /// The export gate serializes the extra renderer and composite at 4 MP.
    // swiftlint:disable:next function_parameter_count
    static func renderCacheSnapshot(
        image: UIImage, imageSize: CGSize, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
        viewport: CGSize, scale: CGFloat, aspectFit: Bool, host: UIView?, dark: Bool,
        preparedLayout: Task<Data, Error>?, assetCache: ReaderTranslationRenderCache? = nil, assetKey: String? = nil,
        assetSourceDigest: String? = nil, priority: TranslationRequestPriority = .prefetch,
        captureGate: TranslationProviderRequestLimiter = gate,
        onNativeDiagnostic: (@MainActor @Sendable (Data) throws -> Void)? = nil
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
        try Task.checkCancellation()
        let sourceDigest = await withTaskCancellationHandler { await fingerprint.value } onCancel: { fingerprint.cancel() }
        try Task.checkCancellation()
        let pageSize = CGSize(width: max(1, floor(frame.width)), height: max(1, floor(frame.height)))
        // A bitmap evicted from the nearby-page budget can still have a settled
        // overlay asset. Replay it before joining the cold layout/render queue,
        // just as the visible-image path does; do not repeat layout or text painting.
        let replayAsset: @MainActor @Sendable () async throws -> UIImage? = {
            guard let assetCache, let assetKey, let sourceDigest,
                  let asset = await assetCache.renderAsset(for: assetKey, priority: priority),
                  asset.matches(regions: regions, sourceSize: imageSize, sourceDigest: sourceDigest),
                  asset.displayRect == rect, asset.supportsOutputSize(pageSize) else { return nil }
            do {
                let page = try await compositeLoadedImage(image, asset: asset, size: pageSize, priority: priority)
                try Task.checkCancellation()
                ReaderTranslationDiagnostics.record("snapshot_asset_replayed")
                return snapshotCanvas(page: page, viewport: viewport, rect: rect, canvasSize: canvasSize, frame: frame)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Invalid overlay/mask data is a miss, not a permanently broken page.
                await assetCache.removeRenderAsset(for: assetKey)
                return nil
            }
        }
        if let replay = try await replayAsset() { return replay }
        // Cache snapshots yield to a visible page waiting for its first presentation.
        ReaderTranslationDiagnostics.renderingProfile("profile_capture_gate_wait", count: regions.count)
        let queuedAt = ProcessInfo.processInfo.systemUptime
        ReaderTranslationDiagnostics.record("export_queued")
        return try await captureGate.withPermit(priority: priority) { @MainActor in
            ReaderTranslationDiagnostics.record("export_admitted", elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - queuedAt) * 1000)
            ReaderTranslationDiagnostics.renderingProfile("profile_capture_gate_acquired", count: regions.count)
            defer { ReaderTranslationDiagnostics.renderingProfile("profile_capture_gate_released", count: regions.count) }
            try Task.checkCancellation()
            // A visible renderer may have completed this exact asset while
            // the offscreen snapshot waited. Recheck all identities before
            // allocating another layout, transparent overlay and composite.
            if let replay = try await replayAsset() {
                ReaderTranslationDiagnostics.record("snapshot_asset_replayed_after_wait")
                return replay
            }
            let result = try await renderSerial(image: image, regions: regions, settings: settings,
                viewport: viewport, aspectFit: aspectFit, host: host, logicalImageSize: imageSize,
                pixelSize: pageSize,
                preparedLayout: preparedLayout, dark: dark, sourceDigest: sourceDigest, priority: priority,
                onNativeDiagnostic: onNativeDiagnostic)
            try Task.checkCancellation()
            if let assetCache, let assetKey, let storage {
                assetCache.storeRenderAssetAfterDisplay(result.asset, key: assetKey, context: storage)
            }
            return snapshotCanvas(page: result.image, viewport: viewport, rect: rect, canvasSize: canvasSize, frame: frame)
        }
    }

    private static func snapshotCanvas(page: UIImage, viewport: CGSize, rect: CGRect, canvasSize: CGSize, frame: CGRect) -> UIImage {
        if rect == CGRect(origin: .zero, size: viewport) { return page }
        // Keep the original bitmap geometry and transparent letterbox on both
        // cold export and replay; replay must never stretch a page to the viewport.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { _ in page.draw(in: frame) }
    }

    private static func renderSerial(image: UIImage, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
                                     viewport: CGSize, aspectFit: Bool, host: UIView?, logicalImageSize: CGSize? = nil,
                                     pixelSize: CGSize? = nil, preparedLayout: Task<Data, Error>? = nil, dark: Bool? = nil,
                                     sourceDigest: String? = nil, priority: TranslationRequestPriority = .foreground,
                                     onNativeDiagnostic: (@MainActor @Sendable (Data) throws -> Void)? = nil,
                                     capturePDF: Bool = false, pdfDeviceScale: CGFloat = 1,
                                     onNativePDFCapture: (@MainActor @Sendable (Data) throws -> Void)? = nil,
                                     onNativeLayersCapture: (@MainActor @Sendable (Data) throws -> Void)? = nil) async throws -> RenderedPage {
        try await ReaderTranslationDiagnostics.measure("export_render") {
            try Task.checkCancellation()
            guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
                throw ExportError.unavailable
            }
            let imageSize = logicalImageSize ?? image.size
            let rect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
                imageSize: imageSize, bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit)
            let size = pixelSize ?? outputSize(for: image)
            guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { throw ExportError.unavailable }
            let layoutData: Data?
            do { layoutData = try await preparedLayout?.value }
            catch is CancellationError { throw CancellationError() }
            catch {
                ReaderTranslationDiagnostics.record("renderer_export_layout_failed", code: (error as NSError).code)
                throw ExportError.renderFailed
            }
            try Task.checkCancellation()
            var overlaySettings = settings.overlay
            overlaySettings.visible = true
            let rendered = try await NativeTranslationRenderer.render(image: image, imageSize: imageSize,
                items: ReaderTranslationRegion.layoutItems(regions, imageSize: imageSize), settings: overlaySettings,
                targetLanguage: settings.targetLanguage, viewport: viewport, scale: size.width / rect.width,
                aspectFit: aspectFit, dark: dark ?? (host?.traitCollection.userInterfaceStyle == .dark),
                preparedLayout: layoutData, renderBounds: rect, composeSource: false, outputPixelSize: size,
                collectDiagnostics: onNativeDiagnostic != nil || onNativePDFCapture != nil,
                capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale)
            try Task.checkCancellation()
            if let onNativeDiagnostic, let data = rendered.diagnosticData { try onNativeDiagnostic(data) }
            if let onNativePDFCapture, let data = rendered.exportPDFData { try onNativePDFCapture(data) }
            // Saving composites the vector capture directly over source pixels,
            // avoiding an extra 8-bit transparent-raster rounding. Live cache
            // routes continue to persist their native bitmap overlay.
            let typography: Data
            if let pdf = rendered.exportPDFData {
                typography = pdf
            } else {
                let overlayImage = rendered.overlayImage
                let encoding = Task.detached(priority: priority.isForeground ? .userInitiated : .utility) {
                    try encodeTypography(overlayImage, size: size)
                }
                typography = try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
            }
            try Task.checkCancellation()
            let patches = rendered.sourcePatches
            let masks: [ExportLayers.Mask]
            if patches.isEmpty {
                masks = []
            } else {
                let encoding = Task.detached(priority: priority.isForeground ? .userInitiated : .utility) {
                    try encodeSourceMasks(patches)
                }
                masks = try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
            }
            try Task.checkCancellation()
            let layers = ExportLayers(masks: masks, surfaces: [],
                paintBounds: rendered.paintBounds.map { [$0.minX, $0.minY, $0.width, $0.height] },
                sourceRestorations: rendered.sourceRestorationRects.map { [$0.minX, $0.minY, $0.width, $0.height] })
            if let onNativeLayersCapture { try onNativeLayersCapture(JSONEncoder().encode(layers)) }
            let asset = ReaderTranslationRenderAsset(typography: typography, layers: layers, displayRect: rect,
                sourceSize: imageSize, regions: regions, sourceDigest: sourceDigest, typographySize: rendered.exportPDFData == nil ? size : nil)
            let result = try await compositeLoadedImage(image, asset: asset, size: size, priority: priority)
            try Task.checkCancellation()
            ReaderTranslationDiagnostics.record("renderer_export_finished", count: rendered.renderedItemCount)
            return RenderedPage(image: result, asset: asset)
        }
    }

    /// Source repairs are captured from the same settled render as the vector
    /// page, then composited at their original frames outside its integral crop.
    nonisolated static func encodeSourceMasks(_ patches: [NativeTranslationRenderer.SourcePatch]) throws -> [ExportLayers.Mask] {
        var pixels = 0
        return try patches.map { patch in
            try Task.checkCancellation()
            let width = patch.image.width, height = patch.image.height
            guard width > 0, height > 0, width <= 8_192, height <= 8_192,
                  width * height <= 4_000_000, pixels + width * height <= 16_000_000 else { throw ExportError.renderFailed }
            pixels += width * height
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
                throw ExportError.renderFailed
            }
            CGImageDestinationAddImage(destination, patch.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ExportError.renderFailed }
            try Task.checkCancellation()
            // The original save path reads the canvas's raw PNG and DOM frame.
            // CSS cleanup clipping belongs to live display, not saved masks.
            return ExportLayers.Mask(frame: [patch.rect.minX, patch.rect.minY, patch.rect.width, patch.rect.height],
                opacity: 1, png: "data:image/png;base64," + (data as Data).base64EncodedString())
        }
    }

    nonisolated private static func encodeTypography(_ overlay: UIImage, size: CGSize) throws -> Data {
        try Task.checkCancellation()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let typographyImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            overlay.draw(in: CGRect(origin: .zero, size: size))
        }
        try Task.checkCancellation()
        guard let data = typographyImage.pngData() else { throw ExportError.renderFailed }
        try Task.checkCancellation()
        return data
    }

    struct ExportLayers: Codable, Sendable {
        struct Mask: Codable, Sendable {
            let frame: [CGFloat]
            let opacity: CGFloat
            let png: String
            var cleanupClip: [CGFloat]? = nil
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
        var sourceRestorations: [[CGFloat]]? = nil
    }

    /// Core Image contexts are thread-safe and expensive to create; the
    /// composite gate already serializes production use.
    nonisolated(unsafe) private static let compositeContext = CIContext(options: [.workingColorSpace: NSNull()])

    nonisolated static func composite(image: UIImage, typography: Data, layers: ExportLayers,
                                             displayRect: CGRect, size: CGSize, nativeBitmap: Bool = false) throws -> UIImage {
        try Task.checkCancellation()
        guard displayRect.minX.isFinite, displayRect.minY.isFinite,
              displayRect.width.isFinite, displayRect.height.isFinite, displayRect.width > 0, displayRect.height > 0,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 16_384, size.height <= 16_384, size.width * size.height <= 12_000_000 else {
            throw ExportError.renderFailed
        }
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
        let masks = try layers.masks.map { mask -> (UIImage, CGRect, CGFloat, CGRect?) in
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
            return (UIImage(cgImage: pixels), try outputFrame(mask.frame), mask.opacity, try mask.cleanupClip.map(outputFrame))
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
        let overlayImage: UIImage?
        let pdfPage: CGPDFPage?
        // ImageIO recognizes PDF containers but does not expose raster pixel properties.
        // Keep vector reference pages on Core Graphics' PDF path before image decoding.
        if !typography.starts(with: Data("%PDF-".utf8)),
           let source = CGImageSourceCreateWithData(typography as CFData,
                                                   [kCGImageSourceShouldCache: false] as CFDictionary) {
            guard CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 12_000_000,
                  let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ExportError.renderFailed }
            overlayImage = UIImage(cgImage: pixels)
            pdfPage = nil
        } else {
            // Native image saving and frozen reference pages share Core Graphics
            // vector composition. Live cached overlays retain their native PNG.
            guard let provider = CGDataProvider(data: typography as CFData),
                  let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { throw ExportError.renderFailed }
            let bounds = page.getBoxRect(.mediaBox)
            guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0 else { throw ExportError.renderFailed }
            overlayImage = nil
            pdfPage = page
        }
        // Original pixels are drawn directly; they are never persisted in the overlay.
        func drawCleaned(_ context: CGContext) {
            image.draw(in: destination)
            for (mask, rect, opacity, cleanupClip) in masks {
                context.saveGState()
                if let cleanupClip { context.clip(to: cleanupClip) }
                mask.draw(in: rect, blendMode: .normal, alpha: opacity)
                context.restoreGState()
            }
        }
        // A settled native bitmap already contains bounded source repairs,
        // kept artwork and typography in final paint order. Its alpha is the
        // coverage; text-only bounds would discard repaired canvas margins.
        // Vector captures still use measured typography bounds and separate masks.
        func drawTypography(_ context: CGContext) {
            if nativeBitmap, let overlayImage {
                overlayImage.draw(in: destination)
                return
            }
            guard !paintBounds.isEmpty else { return }
            context.saveGState()
            context.addRects(paintBounds)
            context.clip()
            if let overlayImage {
                overlayImage.draw(in: destination)
            } else if let page = pdfPage {
                let pageBounds = page.getBoxRect(.mediaBox)
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: size.width / pageBounds.width, y: -size.height / pageBounds.height)
                context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
                context.drawPDFPage(page)
            }
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
                drawCleaned(drawing.cgContext)
                drawTypography(drawing.cgContext)
                restoreSource(drawing.cgContext)
            }
            try Task.checkCancellation()
            return output
        }
        let cleaned = renderer.image { drawCleaned($0.cgContext) }
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
