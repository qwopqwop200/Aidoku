import UIKit
import WebKit

enum ReaderTranslationDOM {
    // Retain one world object for all calls: the revision watermark lives in its globals.
    @MainActor static let contentWorld = WKContentWorld.world(name: "AidokuReaderTranslation")
}

struct ReaderTranslationSnapshotTarget {
    let cache: ReaderTranslationRenderCache
    let key: String
    let pageIdentity: String
    let diskGeneration: UInt64
    let viewport: CGSize
    let dark: Bool
    var preparedLayout: Task<Data, Error>?
}

/// Hosts the translation layout planner and DOM renderer over the reader image.
/// The image and this view share the reader's scroll/zoom transform. Page pixels stay in this local document.
@MainActor
final class ReaderTranslationOverlayView: UIView, WKNavigationDelegate {
    private static let encodingGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    let webView: WKWebView
    private let renderer = BrowserPageImageOverlayRenderer()
    private var ready = false
    private weak var preparedImage: UIImage?
    private var imageTask: Task<Void, Never>?
    private var imageGeneration = UUID()
    private var imageDataURL: String?
    private var dirty = true
    private var renderedSize = CGSize.zero
    private var imageSize = CGSize.zero
    private var aspectFit = true
    private var items: [BrowserOverlayItem] = []
    private var settings = ReaderTranslationSettings()
    private var snapshotTarget: ReaderTranslationSnapshotTarget?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotGeneration = UUID()
    var onCacheGeometryChanged: (() -> Void)?
    var canCacheRendering: Bool { snapshotTarget != nil }
    private(set) var lastDiagnostic: BrowserPageImageOverlayDiagnostic?
    private(set) var didStoreSnapshot = false

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
        addSubview(webView)
        renderer.onDiagnostic = { [weak self] diagnostic in
            guard let self else { return }
            lastDiagnostic = diagnostic
            if diagnostic.outcome == .committed { captureCompletedRender(revision: diagnostic.revision) }
        }
        loadDocument()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { imageTask?.cancel(); snapshotTask?.cancel() }

    func cancelWork() {
        snapshotGeneration = UUID()
        snapshotTask?.cancel()
        snapshotTask = nil
        imageGeneration = UUID()
        imageTask?.cancel()
        imageTask = nil
        renderer.cancelPendingRender()
        webView.stopLoading()
    }

    func update(
        regions: [ReaderTranslationRegion], imageSize: CGSize, aspectFit: Bool,
        settings: ReaderTranslationSettings, image: UIImage? = nil, snapshotTarget: ReaderTranslationSnapshotTarget? = nil
    ) {
        self.snapshotTarget = snapshotTarget
        didStoreSnapshot = false
        snapshotGeneration = UUID()
        snapshotTask?.cancel()
        self.imageSize = imageSize
        self.aspectFit = aspectFit
        self.settings = settings
        items = ReaderTranslationRegion.overlayItems(regions, imageSize: imageSize)
        dirty = true
        if let image, preparedImage !== image { prepareBackground(image) }
        setNeedsLayout()
    }

    private func prepareBackground(_ image: UIImage) {
        preparedImage = image
        imageTask?.cancel()
        imageGeneration = UUID()
        let issued = imageGeneration
        ready = false
        webView.isHidden = true
        let gate = Self.encodingGate
        imageTask = Task { [weak self] in
            let encoding = Task.detached(priority: .utility) { () throws -> String? in
                try await gate.withPermit {
                try Task.checkCancellation()
                return try autoreleasepool {
                    let data: Data?
                    if image.imageOrientation == .up { data = image.pngData() } else {
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = image.scale
                        data = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.pngData()
                    }
                    try Task.checkCancellation()
                    return data.map { "data:image/png;base64," + $0.base64EncodedString() }
                }
                }
            }
            let dataURL = await withTaskCancellationHandler {
                try? await encoding.value
            } onCancel: { encoding.cancel() }
            guard !Task.isCancelled, let self, imageGeneration == issued else { return }
            imageDataURL = dataURL
            loadDocument()
            imageTask = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        if let snapshotTarget, snapshotTarget.viewport != bounds.size || snapshotTarget.dark != (traitCollection.userInterfaceStyle == .dark) {
            snapshotTask?.cancel()
            onCacheGeometryChanged?()
            return
        }
        guard ready, bounds.width > 0, bounds.height > 0, dirty || renderedSize != bounds.size else { return }
        dirty = false
        renderedSize = bounds.size
        renderer.render(
            on: webView, items: settings.overlay.visible ? items : [], imageSize: imageSize,
            sourceRect: ReaderTranslationGeometry.displayRect(
                CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: imageSize,
                bounds: CGRect(origin: .zero, size: bounds.size), aspectFit: aspectFit
            ),
            settings: settings.overlay, targetLanguage: settings.targetLanguage,
            layoutCache: snapshotTarget?.cache.disk, layoutCacheKey: snapshotTarget?.key,
            cacheGeneration: snapshotTarget?.diskGeneration, preparedLayout: snapshotTarget?.preparedLayout
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { dirty = true; setNeedsLayout() }
    }

    private func captureCompletedRender(revision: UInt64) {
        guard let target = snapshotTarget, bounds.width > 0, bounds.height > 0 else { return }
        snapshotTask?.cancel()
        let issued = snapshotGeneration
        let size = bounds.size
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await webView.callAsyncJavaScript(
                    """
                    await Promise.race([
                      new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
                      new Promise(resolve => setTimeout(resolve, 150))
                    ])
                    """,
                    arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld
                )
                try Task.checkCancellation()
                guard snapshotGeneration == issued, lastDiagnostic?.revision == revision, bounds.size == size else { return }
                let configuration = WKSnapshotConfiguration()
                // Bound bitmap memory for unusually tall webtoon pages.
                let scale = max(1, traitCollection.displayScale)
                configuration.snapshotWidth = NSNumber(value: Double(min(size.width, sqrt(12_000_000 * size.width / size.height) / scale)))
                let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                    webView.takeSnapshot(with: configuration) { image, error in
                        if let image { continuation.resume(returning: image) } else {
                            continuation.resume(throwing: error ?? CancellationError())
                        }
                    }
                }
                try Task.checkCancellation()
                guard snapshotGeneration == issued, lastDiagnostic?.revision == revision, bounds.size == size else { return }
                // Keep completed pixels only while the page belongs to the
                // reader's nearby working set. No image encoding or disk write.
                Task(priority: .utility) { [weak self] in
                    await target.cache.store(snapshot, key: target.key, pageIdentity: target.pageIdentity, diskGeneration: target.diskGeneration)
                    if let self, snapshotGeneration == issued { didStoreSnapshot = true }
                }
            } catch { /* Snapshot caching is optional; the live translated page stays visible. */ }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard imageTask == nil else { return }
        ready = true
        webView.isHidden = false
        dirty = true
        setNeedsLayout()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadDocument() }

    private func loadDocument() {
        ready = false
        let background = imageDataURL.map {
            """
            <img id="reader-source-image" alt="" aria-hidden="true" src="\($0)"
              style="position:absolute;inset:0;width:100%;height:100%;object-fit:\(aspectFit ? "contain" : "fill");pointer-events:none;">
            """
        } ?? ""
        webView.loadHTMLString("""
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden;}</style>
        </head><body>\(background)</body></html>
        """, baseURL: nil)
    }
}
