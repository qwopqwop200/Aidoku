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
    private let renderCache: ReaderTranslationRenderCache
    private let layoutPreparation: LayoutPreparation

    init(renderCache: ReaderTranslationRenderCache? = nil, layoutPreparation: @escaping LayoutPreparation = {
        try await BrowserPageImageOverlayRenderer.prepareLayoutData(
            items: $0, imageSize: $1, sourceRect: $2, settings: $3, targetLanguage: $4, viewport: $5
        )
    }) {
        self.renderCache = renderCache ?? .shared
        self.layoutPreparation = layoutPreparation
    }

    func prepare(page: Page, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
                 geometry: ReaderTranslationLayoutGeometry, window: UIWindow? = nil) async throws {
        guard !regions.isEmpty, geometry.viewport.width > 0, geometry.viewport.height > 0 else { return }
        let loader = loader
        let cache = renderCache.disk
        let operation = Task.detached(priority: .utility) { try await loader.load(page) }
        let image = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        let generation = await cache.currentGeneration()
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
                    if let data = try? await cache.data(for: key, kind: .layout),
                       (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) != nil { return data }
                    let layoutStart = ProcessInfo.processInfo.systemUptime
                    let sourceRect = ReaderTranslationGeometry.displayRect(unit, imageSize: size, bounds: CGRect(origin: .zero, size: viewport),
                                                                           aspectFit: geometry.aspectFit)
                    let data = try await layoutPreparation(items, size, sourceRect, settings.overlay, settings.targetLanguage, viewport)
                    TranslationPerformanceDiagnostics.clientPhaseCompleted(
                        phase: "reader_layout", segmentCount: items.count,
                        elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - layoutStart) * 1_000
                    )
                    try Task.checkCancellation()
                    try? await cache.store(data, for: key, kind: .layout, generation: generation)
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
                let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
                let snapshotStart = ProcessInfo.processInfo.systemUptime
                overlay.overrideUserInterfaceStyle = geometry.dark ? .dark : .light
                overlay.accessibilityElementsHidden = true
                // Behind the reader's opaque root view; never cover/intercept reading UI.
                window.insertSubview(overlay, at: 0)
                defer { overlay.cancelWork(); overlay.removeFromSuperview() }
                overlay.update(regions: displayed, imageSize: size, aspectFit: geometry.aspectFit, settings: settings, image: source,
                               snapshotTarget: .init(cache: renderCache, key: key, pageIdentity: identity, diskGeneration: generation,
                                                     viewport: viewport, dark: geometry.dark, preparedLayout: layout))
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                while !overlay.didStoreSnapshot {
                    guard overlay.contentTerminationCount == 0 else { throw URLError(.cannotDecodeContentData) }
                    try Task.checkCancellation()
                    if case .failed = overlay.lastDiagnostic?.outcome {
                        _ = try await layout.value
                        throw URLError(.cannotDecodeContentData)
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                    overlay.layoutIfNeeded()
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                TranslationPerformanceDiagnostics.clientPhaseCompleted(
                    phase: "reader_snapshot", segmentCount: items.count,
                    elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - snapshotStart) * 1_000
                )
            }
        }
    }
}
