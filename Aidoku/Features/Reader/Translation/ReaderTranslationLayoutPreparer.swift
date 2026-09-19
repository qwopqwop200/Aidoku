import UIKit

struct ReaderTranslationLayoutGeometry: Sendable {
    let viewport: CGSize
    let scale: CGFloat
    let aspectFit: Bool
    let crop: CGRect
    let dark: Bool
    private let pageContainer: CGSize?
    private let fitHeight: Bool

    @MainActor init(page: ReaderTranslationPage, imageView: UIImageView) {
        viewport = imageView.bounds.size
        scale = imageView.traitCollection.displayScale
        aspectFit = imageView.contentMode == .scaleAspectFit
        crop = page.sourcePage?.translationSourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        dark = imageView.traitCollection.userInterfaceStyle == .dark
        pageContainer = (imageView.superview as? ReaderPageView)?.bounds.size
        fitHeight = UIScreen.main.bounds.width > UIScreen.main.bounds.height
    }

    var context: String {
        let container = pageContainer ?? (aspectFit ? viewport : CGSize(width: viewport.width, height: 0))
        return ReaderTranslationCacheIdentity.encoded([
            ReaderTranslationCacheIdentity.encoded(container), String(Double(scale)), String(aspectFit),
            String(fitHeight), String(dark), String(Double(crop.width))
        ])
    }

    func viewport(for image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        if let pageContainer {
            // Match ReaderPageView.fixImageSize using THIS image, not the previous page's height.
            let height = image.height * pageContainer.width / image.width
            if height > pageContainer.height || fitHeight {
                return CGSize(width: image.width * pageContainer.height / image.height, height: pageContainer.height)
            }
            return CGSize(width: pageContainer.width, height: height)
        }
        if aspectFit { return viewport }
        return CGSize(width: viewport.width, height: viewport.width * image.height / image.width)
    }
}

/// One cancellable offscreen renderer prepares the actual translation overlay pixels.
/// Geometry/image encoding stay off MainActor; OCR/API work has its own queue.
@MainActor
final class ReaderTranslationLayoutPreparer {
    typealias LayoutPreparation = @Sendable (
        [BrowserOverlayItem], CGSize, CGRect, IPhoneOverlaySettings, String, CGSize
    ) async throws -> Data
    private let loader = ReaderTranslationImageLoader()
    private let imageBudget: TranslationImageWorkBudget
    private let renderCache: ReaderTranslationRenderCache
    private let layoutPreparation: LayoutPreparation

    init(renderCache: ReaderTranslationRenderCache? = nil, imageBudget: TranslationImageWorkBudget = .shared, layoutPreparation: @escaping LayoutPreparation = {
        try await BrowserPageImageOverlayRenderer.prepareLayoutData(
            items: $0, imageSize: $1, sourceRect: $2, settings: $3, targetLanguage: $4, viewport: $5
        )
    }) {
        self.renderCache = renderCache ?? .shared
        self.imageBudget = imageBudget
        self.layoutPreparation = layoutPreparation
    }

    func prepare(page: Page, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
                 geometry: ReaderTranslationLayoutGeometry, window: UIWindow? = nil) async throws {
        guard !regions.isEmpty, geometry.viewport.width > 0, geometry.viewport.height > 0 else { return }
        let identity = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
        guard renderCache.shouldKeepImage(for: identity) else {
            try await prepareTextOnly(page: page, regions: regions, settings: settings, geometry: geometry)
            return
        }
        // An already prepared bitmap needs neither source-image decoding nor WebKit.
        if window != nil, let imageSize = try? await renderCache.disk.imageSize(page: page.translationCacheKey) {
            var restored = true
            for crop in crops(geometry) {
                let size = CGSize(width: imageSize.width * crop.width, height: imageSize.height * crop.height)
                let key = renderKey(page, settings, geometry, size, crop)
                if await renderCache.load(key, pageIdentity: identity) == nil { restored = false; break }
            }
            if restored { return }
        }
        // Admit before loading pixels and hold admission through WebKit capture.
        // Network-only translation may continue, but OCR/download image work
        // cannot accumulate alongside a speculative full-page renderer.
        try await imageBudget.withPermit(priority: .prefetch) {
            try await self.prepareAdmitted(page: page, regions: regions, settings: settings,
                                           geometry: geometry, window: window)
        }
    }

    /// Uses the processed image's saved dimensions, never the image itself.
    /// Unknown geometry is a cheap miss; nearby/visible rendering records it.
    func prepareTextOnly(page: Page, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
                         geometry: ReaderTranslationLayoutGeometry) async throws {
        guard !regions.isEmpty, geometry.viewport.width > 0, geometry.viewport.height > 0,
              let imageSize = try await renderCache.disk.imageSize(page: page.translationCacheKey) else { return }
        let generation = await renderCache.disk.currentGeneration(settings: settings)
        for crop in crops(geometry) {
            try Task.checkCancellation()
            let size = CGSize(width: imageSize.width * crop.width, height: imageSize.height * crop.height)
            let viewport = geometry.viewport(for: size)
            let key = renderKey(page, settings, geometry, size, crop)
            if await renderCache.layoutData(for: key) != nil { continue }
            let displayed = regions.compactMap { $0.cropped(to: crop) }
            let items = ReaderTranslationRegion.overlayItems(displayed, imageSize: size)
            let sourceRect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: size,
                bounds: CGRect(origin: .zero, size: viewport), aspectFit: geometry.aspectFit)
            let data = try await layoutPreparation(items, size, sourceRect, settings.overlay, settings.targetLanguage, viewport)
            try Task.checkCancellation()
            await renderCache.storeLayout(data, key: key, diskGeneration: generation)
        }
    }

    private func crops(_ geometry: ReaderTranslationLayoutGeometry) -> [CGRect] {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return geometry.crop == unit ? [unit] : [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
    }

    private func renderKey(_ page: Page, _ settings: ReaderTranslationSettings, _ geometry: ReaderTranslationLayoutGeometry,
                           _ size: CGSize, _ crop: CGRect) -> String {
        ReaderTranslationCacheIdentity.render(page: page.translationCacheKey, settings: settings, imageSize: size,
            viewport: geometry.viewport(for: size), scale: geometry.scale, aspectFit: geometry.aspectFit, crop: crop, dark: geometry.dark)
    }

    private func prepareAdmitted(page: Page, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
                                 geometry: ReaderTranslationLayoutGeometry, window: UIWindow?) async throws {
        try Task.checkCancellation()
        let loader = loader
        let cache = renderCache.disk
        let operation = Task.detached(priority: .utility) { try await loader.load(page) }
        let image = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        let generation = await cache.currentGeneration(settings: settings)
        try? await cache.storeImageSize(image.size, page: page.translationCacheKey, generation: generation)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let crops = geometry.crop == unit ? [unit] : [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        for crop in crops {
            try Task.checkCancellation()
            let size = CGSize(width: image.size.width * crop.width, height: image.size.height * crop.height)
            let viewport = geometry.viewport(for: size)
            let key = ReaderTranslationCacheIdentity.render(page: page.translationCacheKey, settings: settings, imageSize: size,
                                                            viewport: viewport, scale: geometry.scale, aspectFit: geometry.aspectFit,
                                                            crop: crop, dark: geometry.dark)
            if renderCache.cachedImage(for: key) != nil { continue }
            let identity = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
            let displayed = regions.compactMap { $0.cropped(to: crop) }
            try await renderCache.prepare(key) { [renderCache, layoutPreparation] in
                let items = ReaderTranslationRegion.overlayItems(displayed, imageSize: size)
                // Start layout immediately, while the source image is cropped,
                // encoded and loaded into WebKit. The renderer joins this exact
                // task, so a slow layout can never start a duplicate calculation.
                let layout = Task { () throws -> Data in
                    if let data = await renderCache.layoutData(for: key) { return data }
                    let layoutStart = ProcessInfo.processInfo.systemUptime
                    let sourceRect = ReaderTranslationGeometry.displayRect(unit, imageSize: size, bounds: CGRect(origin: .zero, size: viewport),
                                                                           aspectFit: geometry.aspectFit)
                    let data = try await layoutPreparation(items, size, sourceRect, settings.overlay, settings.targetLanguage, viewport)
                    TranslationPerformanceDiagnostics.clientPhaseCompleted(
                        phase: "reader_layout", segmentCount: items.count,
                        elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - layoutStart) * 1_000
                    )
                    try Task.checkCancellation()
                    await renderCache.storeLayout(data, key: key, diskGeneration: generation)
                    return data
                }
                defer { layout.cancel() }
                try Task.checkCancellation()
                guard let window, renderCache.shouldKeepImage(for: identity) else {
                    _ = try await withTaskCancellationHandler { try await layout.value } onCancel: { layout.cancel() }
                    return
                }
                let cropTask = Task.detached(priority: .utility) {
                    try ReaderTranslationBackgroundImage.prepare(image, crop: crop)
                }
                let source = try await withTaskCancellationHandler { try await cropTask.value } onCancel: { cropTask.cancel() }
                try Task.checkCancellation()
                let snapshotStart = ProcessInfo.processInfo.systemUptime
                // This page is offscreen: produce the final cache bitmap directly.
                // Attaching a live overlay first would render the same source and
                // translation twice, because its capture starts the PDF renderer.
                // Keep the shared image permit and serialized full-page exporter.
                let snapshot = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                    image: source, imageSize: size, regions: displayed, settings: settings,
                    viewport: viewport, scale: geometry.scale, aspectFit: geometry.aspectFit,
                    host: window, dark: geometry.dark, preparedLayout: layout
                )
                try Task.checkCancellation()
                await renderCache.store(snapshot, key: key, pageIdentity: identity, diskGeneration: generation)
                TranslationPerformanceDiagnostics.clientPhaseCompleted(
                    phase: "reader_snapshot", segmentCount: items.count,
                    elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - snapshotStart) * 1_000
                )
            }
        }
    }
}
