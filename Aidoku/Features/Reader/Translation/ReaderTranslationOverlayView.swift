import UIKit

struct ReaderTranslationSnapshotTarget {
    let cache: ReaderTranslationRenderCache
    let key: String
    let pageIdentity: String
    let diskGeneration: UInt64?
    let viewport: CGSize
    let dark: Bool
    var preparedLayout: Task<Data, Error>?
    var pendingDiskGeneration: Task<UInt64, Never>? = nil
    // Bitmap keys include text; reusable layout/assets retain their render namespace.
    var renderKey: String? = nil
}

/// Presents a native raster shared with cache and image export. The reader owns
/// scrolling and zooming; this view only commits complete, current page pixels.
@MainActor
final class ReaderTranslationOverlayView: UIView {
    var diagnosticContext: ReaderTranslationDiagnostics.Context?
    let renderedImageView = UIImageView()
    var renderedImage: UIImage? { renderedImageView.image }
    private(set) var renderedLayoutData: Data? {
        didSet { cachedRenderedLayout = nil; decodedRenderedLayout = false }
    }
    private var cachedRenderedLayout: NativeTranslationLayout?
    private var decodedRenderedLayout = false
    var renderedLayout: NativeTranslationLayout? {
        if !decodedRenderedLayout {
            cachedRenderedLayout = renderedLayoutData.flatMap { try? JSONDecoder().decode(NativeTranslationLayout.self, from: $0) }
            decodedRenderedLayout = true
        }
        return cachedRenderedLayout
    }
    private(set) weak var sourceImage: UIImage?
    private(set) var renderedAspectFit = true
    private var renderTask: Task<Void, Never>?
    var isRendering: Bool { renderTask != nil }
    private(set) var needsRendering = false
    private var pendingFrame: UIImage?
    private var generation = UUID()
    private var revision: UInt64 = 0
    private var dirty = false
    private var renderedSize = CGSize.zero
    private var imageSize = CGSize.zero
    private var aspectFit = true
    private var items: [BrowserOverlayItem] = []
    private var regions: [ReaderTranslationRegion] = []
    private var preparedLayout: Task<Data, Error>?
    private var settings = ReaderTranslationSettings()
    private var snapshotTarget: ReaderTranslationSnapshotTarget?
    private(set) var layoutCacheKey: String?
    var onCacheGeometryChanged: (() -> Void)?
    var onRenderCommitted: (() -> Void)?
    var onRenderFailed: (() -> Void)?
    var onSnapshotStored: ((UIImage) -> Void)?
    var defersPresentationUntilSnapshot = false
    var canCacheRendering: Bool { snapshotTarget != nil }
    var hasFailedRendering: Bool {
        guard let lastDiagnostic else { return false }
        if case .failed = lastDiagnostic.outcome { return true }
        return false
    }
    private(set) var lastDiagnostic: BrowserPageImageOverlayDiagnostic?
    private(set) var didStoreSnapshot = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        accessibilityIdentifier = "reader.translation.overlay"
        renderedImageView.backgroundColor = .clear
        renderedImageView.isOpaque = false
        renderedImageView.contentMode = .scaleToFill
        renderedImageView.isUserInteractionEnabled = false
        renderedImageView.isHidden = true
        addSubview(renderedImageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { renderTask?.cancel() }

    func cancelWork() {
        generation = UUID()
        renderTask?.cancel()
        renderTask = nil
        pendingFrame = nil
    }

    func update(
        regions: [ReaderTranslationRegion], imageSize: CGSize, aspectFit: Bool,
        settings: ReaderTranslationSettings, image: UIImage? = nil, snapshotTarget: ReaderTranslationSnapshotTarget? = nil,
        preparedLayout: Task<Data, Error>? = nil, retainsCommittedFrame: Bool = false
    ) {
        cancelWork()
        if !retainsCommittedFrame || sourceImage !== image {
            renderedImageView.isHidden = true
            // Hiding a reused image view does not release its previous page bitmap.
            // Only an explicitly retained provisional presentation needs that frame.
            renderedImageView.image = nil
        }
        self.regions = regions
        self.imageSize = imageSize
        self.aspectFit = aspectFit
        self.settings = settings
        sourceImage = image
        self.preparedLayout = preparedLayout ?? snapshotTarget?.preparedLayout
        self.snapshotTarget = snapshotTarget
        layoutCacheKey = snapshotTarget.map {
            ReaderTranslationRenderCache.layoutKey(renderKey: $0.renderKey ?? $0.key, regions: regions)
        }
        items = ReaderTranslationRegion.layoutItems(regions, imageSize: imageSize)
        lastDiagnostic = nil
        didStoreSnapshot = false
        renderedLayoutData = nil
        dirty = true
        needsRendering = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderedImageView.frame = bounds
        if let target = snapshotTarget,
           !ReaderTranslationGeometry.sameViewport(target.viewport, bounds.size) ||
            target.dark != (traitCollection.userInterfaceStyle == .dark) {
            cancelWork()
            onCacheGeometryChanged?()
            return
        }
        guard bounds.width > 0, bounds.height > 0,
              dirty || !ReaderTranslationGeometry.sameViewport(renderedSize, bounds.size) else { return }
        dirty = false
        renderedSize = bounds.size
        beginRender()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            dirty = true
            needsRendering = true
            setNeedsLayout()
        }
    }

    private func revealUncachedFrame() {
        snapshotTarget = nil
        layoutCacheKey = nil
        if let pendingFrame { renderedImageView.image = pendingFrame }
        pendingFrame = nil
        needsRendering = false
        renderedImageView.isHidden = false
    }

    private func beginRender() {
        cancelWork()
        needsRendering = true
        revision &+= 1
        let issued = generation
        let issuedRevision = revision
        let size = bounds.size
        let image = sourceImage
        let settings = settings, imageSize = imageSize, aspectFit = aspectFit
        let items = settings.overlay.visible ? items : []
        let regions = regions
        let target = snapshotTarget, layoutKey = layoutCacheKey
        let existingLayout = preparedLayout
        let dark = traitCollection.userInterfaceStyle == .dark
        let scale = traitCollection.displayScale
        let diagnosticContext = diagnosticContext
        renderTask = Task { [weak self] in
            // Waiting for a shared prepared layout must not retain a detached view.
            defer { if self?.generation == issued { self?.renderTask = nil } }
            let layout = Task { () throws -> Data in
                try Task.checkCancellation()
                let sourceRect = ReaderTranslationGeometry.displayRect(
                    ReaderTranslationSplitGeometry.unit, imageSize: imageSize,
                    bounds: CGRect(origin: .zero, size: size), aspectFit: aspectFit)
                func matchesGeometry(_ data: Data) -> Bool {
                    guard let candidate = try? JSONDecoder().decode(NativeTranslationLayout.self, from: data) else { return false }
                    return candidate.imageSize == imageSize && candidate.sourceRect == sourceRect &&
                        ReaderTranslationGeometry.sameViewport(candidate.viewport, size)
                }
                if let existingLayout {
                    let data = try await existingLayout.value
                    try Task.checkCancellation()
                    if matchesGeometry(data) { return data }
                }
                if let target, let layoutKey, let cached = await target.cache.layoutData(for: layoutKey) {
                    try Task.checkCancellation()
                    if matchesGeometry(cached) { return cached }
                }
                try Task.checkCancellation()
                return try await NativeTranslationLayoutPlanner.prepareLayoutData(
                    items: items, imageSize: imageSize, sourceRect: sourceRect,
                    settings: settings.overlay, targetLanguage: settings.targetLanguage, viewport: size)
            }
            defer { layout.cancel() }
            do {
                let data = try await withTaskCancellationHandler { try await layout.value } onCancel: { layout.cancel() }
                try Task.checkCancellation()
                let output: UIImage
                var completedLayout = data
                let renderedCount: Int
                if let target, let image {
                    ReaderTranslationDiagnostics.record("visible_snapshot_only_begin", count: regions.count)
                    output = try await ReaderTranslationDiagnostics.measure("visible_snapshot", context: diagnosticContext) {
                        try await ReaderTranslationImageExporter.renderCacheSnapshot(
                            image: image, imageSize: imageSize, regions: regions, settings: settings,
                            viewport: size, scale: scale, aspectFit: aspectFit,
                            host: self?.window ?? self, dark: dark, preparedLayout: layout,
                            assetCache: target.cache, assetKey: target.renderKey ?? target.key, priority: .foreground)
                    }
                    renderedCount = items.filter { !$0.keepsSourceLettering }.count
                } else {
                    let result = try await NativeTranslationRenderer.render(
                        image: image, imageSize: imageSize, items: items, settings: settings.overlay,
                        targetLanguage: settings.targetLanguage, viewport: size,
                        scale: NativeTranslationRenderer.boundedRasterScale(viewport: size, requestedScale: scale),
                        aspectFit: aspectFit, dark: dark, preparedLayout: data, composeSource: false)
                    output = result.overlayImage
                    completedLayout = result.layoutData
                    renderedCount = result.renderedItemCount
                }
                try Task.checkCancellation()
                guard let self, generation == issued, ReaderTranslationGeometry.sameViewport(bounds.size, size),
                      (traitCollection.userInterfaceStyle == .dark) == dark else { return }
                renderedLayoutData = completedLayout
                // Task results retain layout bytes even after completion. Keep the
                // committed bytes once, and release this view's preparation handles.
                preparedLayout = nil
                snapshotTarget?.preparedLayout = nil
                renderedAspectFit = aspectFit
                if defersPresentationUntilSnapshot, target != nil {
                    // Retain a previously committed provisional frame while optional
                    // cache publication prepares the final replacement bitmap.
                    pendingFrame = output
                } else {
                    renderedImageView.image = output
                    renderedImageView.isHidden = false
                    needsRendering = false
                }
                lastDiagnostic = .init(operation: .render, revision: issuedRevision,
                    outcome: .committed, renderedItemCount: renderedCount)
                ReaderTranslationDiagnostics.record("visible_render_committed", count: renderedCount, context: diagnosticContext)
                onRenderCommitted?()
                guard generation == issued, let target, let layoutKey else { return }
                // Cache persistence is optional after a successful native presentation.
                // A stale update may never publish or store the old page's pixels.
                let diskGeneration: UInt64?
                if let ready = target.diskGeneration { diskGeneration = ready }
                else { diskGeneration = await target.pendingDiskGeneration?.value }
                try Task.checkCancellation()
                guard generation == issued else { return }
                guard let diskGeneration else { revealUncachedFrame(); return }
                await target.cache.storeLayout(completedLayout, key: layoutKey, diskGeneration: diskGeneration)
                try Task.checkCancellation()
                guard generation == issued else { return }
                await target.cache.store(output, key: target.key, pageIdentity: target.pageIdentity, diskGeneration: diskGeneration)
                try Task.checkCancellation()
                guard generation == issued else { return }
                guard let cached = target.cache.cachedImage(for: target.key) else { revealUncachedFrame(); return }
                didStoreSnapshot = true
                needsRendering = false
                ReaderTranslationDiagnostics.record("visible_snapshot_only_finished", count: regions.count)
                if let onSnapshotStored {
                    pendingFrame = nil
                    onSnapshotStored(cached)
                } else {
                    if let pendingFrame { renderedImageView.image = pendingFrame }
                    pendingFrame = nil
                    renderedImageView.isHidden = false
                }
            } catch {
                guard let self, !Task.isCancelled, generation == issued else { return }
                // Persistence never invalidates a frame already committed to the reader.
                if lastDiagnostic?.revision == issuedRevision, lastDiagnostic?.outcome == .committed {
                    ReaderTranslationDiagnostics.record("cache_snapshot_failed")
                    revealUncachedFrame()
                    return
                }
                lastDiagnostic = .init(operation: .render, revision: issuedRevision,
                    outcome: .failed(.nativeRenderingFailed), renderedItemCount: 0, isCacheable: false)
                ReaderTranslationDiagnostics.record("visible_render_failed", context: diagnosticContext)
                onRenderFailed?()
            }
        }
    }
}
