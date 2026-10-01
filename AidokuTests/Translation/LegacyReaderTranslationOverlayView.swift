import UIKit
import WebKit
@testable import Aidoku

// Frozen baseline renderer, used only by the independent image parity oracle.
/// Hosts the translation layout planner and DOM renderer over the reader image.
/// The image and this view share the reader's scroll/zoom transform. Page pixels stay in this local document.
@MainActor
final class LegacyReaderTranslationOverlayView: UIView, WKNavigationDelegate {
    private static let encodingGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    var diagnosticContext: ReaderTranslationDiagnostics.Context?
    let webView: WKWebView
    // Optional instrumentation transforms only this instance's runtime copy;
    // the checked-in frozen oracle and ordinary parity captures stay unchanged.
    var referenceScriptTransform: ((String) throws -> String)?
    // Opt-in same-input oracle: parse the original UTF-8 payload in JavaScript,
    // avoiding NSNumber conversion changing a coordinate across floor/ceil.
    var referenceSerializedLayoutJSON: String?
    static let serializedLayoutInputScript = """
    const aidokuReferencePayload = JSON.parse(aidokuReferenceLayoutJSON);
    items = Array.isArray(aidokuReferencePayload) ? aidokuReferencePayload : aidokuReferencePayload?.items;
    if (!Array.isArray(items)) throw new TypeError("Reference layout must contain an items array");
    """
    private(set) var lastReferenceError: String?
    private lazy var renderer = BrowserPageImageOverlayRenderer(javaScriptEvaluator: { [weak self] webView, script, arguments in
        do {
            self?.lastReferenceError = nil
            var frozen = arguments["items"] == nil ? script : LegacyReaderTranslationRenderScript.renderScript
            if arguments["items"] != nil, let transform = self?.referenceScriptTransform {
                frozen = try transform(frozen)
            }
            var referenceArguments = arguments
            if arguments["items"] != nil, let serialized = self?.referenceSerializedLayoutJSON {
                referenceArguments["aidokuReferenceLayoutJSON"] = serialized
                frozen = Self.serializedLayoutInputScript + "\n" + frozen
            }
            return try await BrowserPageImageOverlayRenderer.evaluateJavaScript(webView, frozen, referenceArguments)
        } catch {
            let failure = error as NSError
            let keys = ["WKJavaScriptExceptionMessage", "WKJavaScriptExceptionLineNumber",
                "WKJavaScriptExceptionColumnNumber", "WKJavaScriptExceptionSourceURL"]
            let details = keys.compactMap { key in failure.userInfo[key].map { "\(key)=\($0)" } }
            self?.lastReferenceError = ([String(reflecting: error), "\(failure.domain):\(failure.code)"] + details).joined(separator: "\n")
            throw error
        }
    })
    private var ready = false
    private var documentReady = false
    private var backgroundTask: Task<Void, Never>?
    private var backgroundRevision = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    private(set) var contentTerminationCount = 0
    var hasExhaustedRecovery: Bool { contentTerminationCount > 2 }
    private weak var preparedImage: UIImage?
    private var imageTask: Task<Void, Never>?
    private var imageGeneration = UUID()
    private var imageDataURL: String?
    private var dirty = true
    private var renderedSize = CGSize.zero
    private var imageSize = CGSize.zero
    private var aspectFit = true
    private var items: [BrowserOverlayItem] = []
    private var regions: [ReaderTranslationRegion] = []
    private var preparedLayout: Task<Data, Error>?
    private var settings = ReaderTranslationSettings()
    private var snapshotTarget: ReaderTranslationSnapshotTarget?
    // Region JSON/digest belongs to an update, not each layout/capture pass.
    private(set) var layoutCacheKey: String?
    private var snapshotTask: Task<Void, Never>?
    private var directSnapshotInFlight = false
    private var snapshotGeneration = UUID()
    var onCacheGeometryChanged: (() -> Void)?
    var onRenderCommitted: (() -> Void)?
    var onRenderCleared: (() -> Void)?
    var onRenderFailed: (() -> Void)?
    var onSnapshotStored: ((UIImage) -> Void)?
    // A PDF composite can rasterize glyphs differently from the live DOM.
    // Readers replacing this view with that composite reveal only the latter.
    var defersPresentationUntilSnapshot = false
    var canCacheRendering: Bool { snapshotTarget != nil }
    private(set) var lastDiagnostic: BrowserPageImageOverlayDiagnostic?
    private(set) var didStoreSnapshot = false

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Source-style Korean faces (serif lettering) are handed to the document on request.
        BrowserOverlayLetterFonts.shared.register(in: configuration, contentWorld: ReaderTranslationDOM.contentWorld)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        accessibilityIdentifier = "reader.translation.overlay"
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.isHidden = true
        addSubview(webView)
        renderer.onDiagnostic = { [weak self] diagnostic in
            guard let self else { return }
            lastDiagnostic = diagnostic
            if diagnostic.outcome == .committed {
                recoveryTask?.cancel(); recoveryTask = nil
                // Reveal only the committed layout, after background sampling,
                // cleanup and typesetting have all completed.
                if !defersPresentationUntilSnapshot || snapshotTarget == nil || !diagnostic.isCacheable {
                    webView.isHidden = false
                }
                ReaderTranslationDiagnostics.record("visible_render_committed", count: diagnostic.renderedItemCount, context: diagnosticContext)
                if diagnostic.isCacheable { captureCompletedRender(revision: diagnostic.revision) }
                onRenderCommitted?()
            } else if diagnostic.outcome == .cleared {
                onRenderCleared?()
            } else if case .failed = diagnostic.outcome {
                ReaderTranslationDiagnostics.record("visible_render_failed", context: diagnosticContext)
                onRenderFailed?()
            }
        }
        loadDocument()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { imageTask?.cancel(); backgroundTask?.cancel(); snapshotTask?.cancel(); recoveryTask?.cancel() }

    func cancelWork() {
        recoveryTask?.cancel(); recoveryTask = nil
        snapshotGeneration = UUID()
        directSnapshotInFlight = false
        snapshotTask?.cancel()
        snapshotTask = nil
        imageGeneration = UUID()
        imageTask?.cancel()
        imageTask = nil
        backgroundRevision += 1
        backgroundTask?.cancel(); backgroundTask = nil
        renderer.cancelPendingRender()
        webView.stopLoading()
    }

    /// Export owns a separate, serialized view. Release page pixels between
    /// exports; a fresh document also discards export-only DOM mutations.
    func resetForExportReuse() {
        cancelWork()
        onRenderCommitted = nil
        onRenderCleared = nil
        onRenderFailed = nil
        snapshotTarget = nil
        layoutCacheKey = nil
        preparedImage = nil
        imageDataURL = nil
        items = []
        regions = []
        preparedLayout = nil
        imageSize = .zero
        renderedSize = .zero
        dirty = true
        loadDocument()
    }

    func update(
        regions: [ReaderTranslationRegion], imageSize: CGSize, aspectFit: Bool,
        settings: ReaderTranslationSettings, image: UIImage? = nil, snapshotTarget: ReaderTranslationSnapshotTarget? = nil,
        preparedLayout: Task<Data, Error>? = nil, retainsCommittedFrame: Bool = false
    ) {
        renderer.cancelPendingRender()
        let backgroundFitChanged = self.aspectFit != aspectFit
        self.regions = regions
        self.preparedLayout = preparedLayout ?? snapshotTarget?.preparedLayout
        self.snapshotTarget = contentTerminationCount == 0 ? snapshotTarget : nil
        layoutCacheKey = self.snapshotTarget.map { ReaderTranslationRenderCache.layoutKey(renderKey: $0.renderKey ?? $0.key, regions: regions) }
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryAttempts = 0
        lastDiagnostic = nil
        scheduleRenderRecovery()
        // Progressive translation replaces one committed layout with the next.
        // The render script is synchronous, so the previous frame stays on
        // screen until the new DOM commits instead of flashing the source.
        if defersPresentationUntilSnapshot || !retainsCommittedFrame || webView.isHidden || preparedImage !== image {
            webView.isHidden = true
        }
        didStoreSnapshot = false
        snapshotGeneration = UUID()
        directSnapshotInFlight = false
        snapshotTask?.cancel()
        self.imageSize = imageSize
        self.aspectFit = aspectFit
        self.settings = settings
        items = ReaderTranslationRegion.layoutItems(regions, imageSize: imageSize)
        dirty = true
        if contentTerminationCount == 0 {
            if let image, defersPresentationUntilSnapshot, self.snapshotTarget != nil, window != nil {
                // The final bitmap is the only visible presentation. Its isolated
                // exporter owns the one DOM render; do not paint this hidden view first.
                preparedImage = image
                imageGeneration = UUID()
                imageTask?.cancel(); imageTask = nil
                backgroundRevision += 1
                backgroundTask?.cancel(); backgroundTask = nil
                recoveryTask?.cancel(); recoveryTask = nil
                imageDataURL = nil
            } else if let image {
                if preparedImage !== image {
                    prepareBackground(image)
                } else if backgroundFitChanged {
                    // The encoded pixels are reusable, but object-fit belongs to
                    // presentation geometry and must follow a reused viewport.
                    ready = false
                    installBackground()
                }
            } else if preparedImage != nil || imageDataURL != nil || imageTask != nil {
                // A text-only presentation must not inherit the previous page's
                // source bitmap, including an encoding still in flight.
                preparedImage = nil
                imageGeneration = UUID()
                imageTask?.cancel()
                imageTask = nil
                imageDataURL = nil
                ready = false
                installBackground()
            }
        }
        setNeedsLayout()
    }

    // Translation data can be complete while WebKit has never committed its
    // pixels. Recover only that presentation, with a bounded retry budget.
    private func scheduleRenderRecovery() {
        guard !hasExhaustedRecovery, recoveryTask == nil, recoveryAttempts < 2 else { return }
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            recoveryTask = nil
            guard items.contains(where: { !$0.keepsSourceLettering }), lastDiagnostic?.outcome != .committed else { return }
            recoveryAttempts += 1
            ReaderTranslationDiagnostics.record("visible_render_retry", count: recoveryAttempts)
            // Encoding already in progress must finish before its document loads.
            if imageTask == nil { loadDocument() }
            scheduleRenderRecovery()
        }
    }

    private func prepareBackground(_ image: UIImage) {
        preparedImage = image
        imageTask?.cancel()
        imageGeneration = UUID()
        let issued = imageGeneration
        ready = false
        backgroundRevision += 1
        backgroundTask?.cancel(); backgroundTask = nil
        renderer.cancelPendingRender()
        webView.isHidden = true
        let gate = Self.encodingGate
        ReaderTranslationDiagnostics.renderingProfile("profile_background_encode_queued", revision: UInt64(backgroundRevision))
        imageTask = Task { [weak self] in
            let encoding = Task.detached(priority: .utility) { () throws -> String? in
                try await ReaderTranslationBackgroundImage.scheduledDataURL(for: image, gate: gate)
            }
            let dataURL = await withTaskCancellationHandler {
                try? await encoding.value
            } onCancel: { encoding.cancel() }
            guard !Task.isCancelled, let self, imageGeneration == issued, contentTerminationCount == 0 else { return }
            imageDataURL = dataURL
            imageTask = nil
            installBackground()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        if let snapshotTarget, !ReaderTranslationGeometry.sameViewport(snapshotTarget.viewport, bounds.size) || snapshotTarget.dark != (traitCollection.userInterfaceStyle == .dark) {
            snapshotTask?.cancel()
            onCacheGeometryChanged?()
            return
        }
        if defersPresentationUntilSnapshot, snapshotTarget != nil, preparedImage != nil, window != nil,
           contentTerminationCount == 0, bounds.width > 0, bounds.height > 0 {
            if !directSnapshotInFlight, !didStoreSnapshot,
               dirty || !ReaderTranslationGeometry.sameViewport(renderedSize, bounds.size) {
                dirty = false
                renderedSize = bounds.size
                captureOnlySnapshot()
            }
            return
        }
        guard ready, bounds.width > 0, bounds.height > 0, dirty || !ReaderTranslationGeometry.sameViewport(renderedSize, bounds.size) else { return }
        dirty = false
        renderedSize = bounds.size
        ReaderTranslationDiagnostics.renderingProfile("profile_overlay_render_ready", count: items.count,
                                                      revision: UInt64(backgroundRevision))
        renderer.render(
            on: webView, items: settings.overlay.visible ? items : [], imageSize: imageSize,
            sourceRect: ReaderTranslationGeometry.displayRect(
                CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: imageSize,
                bounds: CGRect(origin: .zero, size: bounds.size), aspectFit: aspectFit
            ),
            settings: settings.overlay, targetLanguage: settings.targetLanguage,
            layoutCache: snapshotTarget?.cache.disk,
            layoutCacheKey: layoutCacheKey,
            cacheGeneration: snapshotTarget?.diskGeneration,
            cacheGenerationTask: snapshotTarget?.pendingDiskGeneration, preparedLayout: preparedLayout
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { dirty = true; setNeedsLayout() }
    }

    /// A cache-backed visible page needs one full-page export, not a hidden
    /// live render followed by a second export render. Keep this view as the
    /// geometry/cancellation owner until the final bitmap replaces it.
    private func captureOnlySnapshot() {
        guard let target = snapshotTarget, let layoutCacheKey, let image = preparedImage, let host = window else { return }
        snapshotTask?.cancel()
        let issued = snapshotGeneration
        let size = bounds.size
        let regions = regions, settings = settings, imageSize = imageSize, aspectFit = aspectFit
        let items = items
        let sourceRect = ReaderTranslationGeometry.displayRect(
            CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: imageSize,
            bounds: CGRect(origin: .zero, size: size), aspectFit: aspectFit)
        let existingLayout = preparedLayout
        directSnapshotInFlight = true
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if snapshotGeneration == issued { directSnapshotInFlight = false; snapshotTask = nil }
            }
            let layout = Task { () throws -> Data in
                if let existingLayout { return try await existingLayout.value }
                if let cached = await target.cache.layoutData(for: layoutCacheKey) { return cached }
                return try await BrowserPageImageOverlayRenderer.prepareLayoutData(
                    items: items, imageSize: imageSize, sourceRect: sourceRect,
                    settings: settings.overlay, targetLanguage: settings.targetLanguage, viewport: size)
            }
            defer { layout.cancel() }
            ReaderTranslationDiagnostics.record("visible_snapshot_only_begin", count: regions.count)
            do {
                let snapshot = try await ReaderTranslationDiagnostics.measure("visible_snapshot", context: diagnosticContext) {
                    try await ReaderTranslationImageExporter.renderCacheSnapshot(
                        image: image, imageSize: imageSize, regions: regions, settings: settings,
                        viewport: size, scale: traitCollection.displayScale, aspectFit: aspectFit,
                        host: host, dark: target.dark, preparedLayout: layout,
                        assetCache: target.cache, assetKey: target.renderKey ?? target.key, priority: .foreground)
                }
                try Task.checkCancellation()
                guard snapshotGeneration == issued,
                      ReaderTranslationGeometry.sameViewport(bounds.size, size),
                      (traitCollection.userInterfaceStyle == .dark) == target.dark else { return }
                let diskGeneration: UInt64?
                if let ready = target.diskGeneration { diskGeneration = ready }
                else { diskGeneration = await target.pendingDiskGeneration?.value }
                try Task.checkCancellation()
                guard snapshotGeneration == issued else { return }
                guard let diskGeneration else { throw ReaderTranslationImageExporter.ExportError.unavailable }
                // The snapshot-only path bypasses the live renderer's layout
                // persistence. Retain its prepared payload for reuse after restart.
                let completedLayout = try await layout.value
                try Task.checkCancellation()
                guard snapshotGeneration == issued else { return }
                await target.cache.storeLayout(completedLayout, key: layoutCacheKey, diskGeneration: diskGeneration)
                await target.cache.store(snapshot, key: target.key, pageIdentity: target.pageIdentity, diskGeneration: diskGeneration)
                try Task.checkCancellation()
                guard snapshotGeneration == issued else { return }
                guard let cached = target.cache.cachedImage(for: target.key) else {
                    throw ReaderTranslationImageExporter.ExportError.unavailable
                }
                didStoreSnapshot = true
                ReaderTranslationDiagnostics.record("visible_snapshot_only_finished", count: regions.count)
                onRenderCommitted?()
                onSnapshotStored?(cached)
            } catch {
                guard !Task.isCancelled, snapshotGeneration == issued else { return }
                // A failed optional capture still gets a live translated fallback.
                // Disable capture for this update so it cannot loop on the failure.
                ReaderTranslationDiagnostics.record("visible_snapshot_only_fallback")
                snapshotTarget = nil
                self.layoutCacheKey = nil
                dirty = true
                prepareBackground(image)
                scheduleRenderRecovery()
                setNeedsLayout()
            }
        }
    }

    private func captureCompletedRender(revision: UInt64) {
        guard let target = snapshotTarget, let layoutCacheKey, bounds.width > 0, bounds.height > 0 else { return }
        snapshotTask?.cancel()
        let issued = snapshotGeneration
        let size = bounds.size
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // Missing hosts, export failures and cache admission failures
                // still get one complete presentation. Stale/cancelled work
                // must never reveal a replacement page or a partial render.
                if !Task.isCancelled, snapshotGeneration == issued,
                   lastDiagnostic?.revision == revision, lastDiagnostic?.outcome == .committed {
                    webView.isHidden = false
                }
            }
            do {
                guard let image = preparedImage, let host = window else { return }
                // A DOM commit does not mean WebKit has painted tiles outside the
                // screen. GPU snapshots of partially visible pages can permanently
                // freeze untranslated lower regions when they replace the live view.
                // Rasterize the whole document via the isolated PDF export renderer.
                // Promote a live renderer's saved layout into the bounded memory
                // cache; subsequent displays/captures need no disk read or unpack.
                ReaderTranslationDiagnostics.renderingProfile("profile_capture_layout_read_begin", revision: revision)
                let layout = await target.cache.layoutData(for: layoutCacheKey)
                ReaderTranslationDiagnostics.renderingProfile("profile_capture_layout_read_end", count: layout?.count ?? -1, revision: revision)
                try Task.checkCancellation()
                guard snapshotGeneration == issued, lastDiagnostic?.revision == revision, ReaderTranslationGeometry.sameViewport(bounds.size, size) else { return }
                ReaderTranslationDiagnostics.renderingProfile("profile_capture_export_begin", revision: revision)
                let snapshot = try await ReaderTranslationDiagnostics.measure("visible_snapshot", context: diagnosticContext) {
                    try await ReaderTranslationImageExporter.renderCacheSnapshot(
                        image: image, imageSize: imageSize, regions: regions, settings: settings,
                        viewport: size, scale: traitCollection.displayScale, aspectFit: aspectFit,
                        host: host, dark: target.dark,
                        preparedLayout: layout.map { data in Task { data } } ?? preparedLayout,
                        assetCache: target.cache, assetKey: target.renderKey ?? target.key
                )
                }
                ReaderTranslationDiagnostics.renderingProfile("profile_capture_export_end", revision: revision)
                try Task.checkCancellation()
                guard snapshotGeneration == issued, lastDiagnostic?.revision == revision, ReaderTranslationGeometry.sameViewport(bounds.size, size) else { return }
                let diskGeneration: UInt64?
                if let ready = target.diskGeneration { diskGeneration = ready }
                else { diskGeneration = await target.pendingDiskGeneration?.value }
                guard let diskGeneration, !Task.isCancelled, snapshotGeneration == issued else { return }
                await target.cache.store(snapshot, key: target.key, pageIdentity: target.pageIdentity, diskGeneration: diskGeneration)
                guard !Task.isCancelled, snapshotGeneration == issued else { return }
                didStoreSnapshot = true
                if let cached = target.cache.cachedImage(for: target.key) { onSnapshotStored?(cached) }
            } catch {
                if !Task.isCancelled { ReaderTranslationDiagnostics.record("cache_snapshot_failed") }
                // Keep the live translated page visible if optional caching fails.
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ReaderTranslationDiagnostics.renderingProfile("profile_navigation_finish", revision: UInt64(backgroundRevision))
        documentReady = true
        installBackground()
    }

    /// Keep the document and isolated-world state alive across image changes.
    /// Await decoding before cleanup samples pixels or a complete-page snapshot runs.
    private func installBackground() {
        guard documentReady, !hasExhaustedRecovery, imageTask == nil else { return }
        backgroundTask?.cancel()
        backgroundRevision += 1
        let revision = backgroundRevision
        backgroundTask = Task { [weak self] in
            guard let self else { return }
            do {
                ReaderTranslationDiagnostics.renderingProfile("profile_background_install_begin", revision: UInt64(revision))
                let installed = try await webView.callAsyncJavaScript(
                    Self.backgroundScript,
                    arguments: ["source": imageDataURL ?? "", "fit": aspectFit ? "contain" : "fill",
                                "revision": revision],
                    in: nil, contentWorld: ReaderTranslationDOM.contentWorld
                ) as? Bool
                ReaderTranslationDiagnostics.renderingProfile("profile_background_install_end", revision: UInt64(revision))
                guard !Task.isCancelled, backgroundRevision == revision, installed == true else { return }
                backgroundTask = nil
                ready = true
                dirty = true
                setNeedsLayout()
            } catch { /* The bounded render watchdog reloads a stalled document. */ }
        }
    }

    static let backgroundScript = """
    const key = '__aidokuReaderBackgroundRevision';
    globalThis[key] = revision;
    const previous = document.getElementById('reader-source-image');
    if (!source) {
      previous?.remove();
      return true;
    }
    const image = new Image();
    image.id = 'reader-source-image';
    image.alt = '';
    image.setAttribute('aria-hidden', 'true');
    Object.assign(image.style, {
      position: 'absolute', inset: '0', width: '100%', height: '100%',
      objectFit: fit, pointerEvents: 'none'
    });
    image.src = source;
    await image.decode();
    if (globalThis[key] !== revision) return false;
    if (previous) previous.replaceWith(image);
    else document.body.prepend(image);
    return true;
    """

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ReaderTranslationDiagnostics.record("web_content_terminated")
        guard !hasExhaustedRecovery else { return }
        contentTerminationCount += 1
        cancelWork()
        ready = false
        webView.isHidden = true
        imageDataURL = nil
        // Keep the original UIImageView beneath a text-only recovery document.
        // Such a document cannot be cached as a complete page snapshot.
        snapshotTarget = nil
        layoutCacheKey = nil
        lastDiagnostic = nil
        guard !hasExhaustedRecovery else { return }
        loadDocument()
        scheduleRenderRecovery()
    }

    private func loadDocument() {
        guard !hasExhaustedRecovery else { return }
        webView.isHidden = true
        renderer.cancelPendingRender()
        lastDiagnostic = nil
        ready = false
        documentReady = false
        backgroundRevision += 1
        backgroundTask?.cancel(); backgroundTask = nil
        ReaderTranslationDiagnostics.renderingProfile("profile_navigation_begin", revision: UInt64(backgroundRevision))
        webView.loadHTMLString("""
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden;}</style>
        </head><body></body></html>
        """, baseURL: nil)
    }
}
