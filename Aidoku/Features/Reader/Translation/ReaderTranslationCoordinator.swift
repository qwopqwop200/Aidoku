import UIKit

@MainActor
protocol ReaderTranslationOwner: AnyObject {
    var navigationItem: UINavigationItem { get }
    var translationUpcomingPages: [Page] { get }
    var translationVisiblePages: [ReaderTranslationPage] { get }
    var translationPreviewPages: [ReaderTranslationPage] { get }
    var translationChapterKey: String { get }
    var translationCurrentPageIndex: Int { get }
    var translationReadsRightToLeft: Bool { get }
    var translationPersistsCache: Bool { get }
}

extension ReaderTranslationOwner {
    var translationPreviewPages: [ReaderTranslationPage] { [] }
    var translationReadsRightToLeft: Bool { false }
    var translationPersistsCache: Bool { true }
    var translationCurrentPageIndex: Int {
        guard let key = translationVisiblePages.first?.sourcePage?.translationCacheKey else { return 0 }
        return translationUpcomingPages.firstIndex { $0.translationCacheKey == key } ?? 0
    }
}

extension ReaderViewController: ReaderTranslationOwner {
    var translationPersistsCache: Bool { !isTemporaryImageSession }
    var translationReadsRightToLeft: Bool { readingMode == .rtl }
    var translationVisiblePages: [ReaderTranslationPage] { reader?.translationPages() ?? [] }
    var translationPreviewPages: [ReaderTranslationPage] { reader?.translationPreviewPages() ?? [] }
    var translationChapterKey: String { chapter.key }
}

// Only isolated adjacent turns use the shorter debounce. Keep startup, jumps,
// scrubbing and rapid reversals conservative without retaining any page images.
struct ReaderTranslationNavigationDebounce {
    private var previous: (chapter: String, index: Int, time: TimeInterval)?

    mutating func reset() { previous = nil }

    mutating func delay(chapter: String, index: Int, now: TimeInterval) -> UInt64 {
        defer { previous = (chapter, index, now) }
        guard let previous, previous.chapter == chapter,
              abs(index - previous.index) == 1,
              now - previous.time >= 0.7 else { return 350_000_000 }
        return 180_000_000
    }
}

@MainActor
final class ReaderTranslationCoordinator {
    private weak var owner: (any ReaderTranslationOwner)?
    private let preloader: ReaderTranslationPreloader
    private let layoutPreparer = ReaderTranslationLayoutPreparer()
    private lazy var button = UIBarButtonItem(image: UIImage(systemName: "character.bubble"), style: .plain, target: self, action: #selector(toggle))
    private var observers: [NSObjectProtocol] = []
    private var failureNotice: UIView?
    private var failureNoticeTask: Task<Void, Never>?
    private let metadataOwner = UUID()
    private var metadataActivityTask: Task<Void, Never>?
    private var metadataPaused = false
    private var isVisible = false
    private var synchronizationTask: Task<Void, Never>?
    private var scrollVisibilityTask: Task<Void, Never>?
    private var scrollVisibility: ScrollVisibility?

    private struct ScrollVisibility: Equatable {
        struct PageState: Equatable {
            let page: ObjectIdentifier
            let image: ObjectIdentifier?
            let size: CGSize?
            let sourceKey: String?
            @MainActor init(_ page: ReaderTranslationPage) {
                self.page = ObjectIdentifier(page)
                image = page.imageView?.image.map(ObjectIdentifier.init)
                size = page.imageView?.bounds.size
                sourceKey = page.sourcePage?.translationCacheKey
            }
        }
        let chapter: String
        let index: Int
        let pages: [PageState]
        let previews: [PageState]
    }

    private func cancelScrollVisibility() {
        scrollVisibilityTask?.cancel()
        scrollVisibilityTask = nil
        scrollVisibility = nil
    }

    /// Scroll callbacks run at display frequency. Read the latest viewport at a
    /// bounded cadence, without rehashing/reordering the chapter on every frame.
    /// Image/settings notifications still use the immediate restoration path.
    func scrollVisibilityDidChange() {
        guard isVisible else { return }
        // Already rendered pages need no navigation debounce or image admission.
        // Keep the expensive visibility/queue refresh on the existing cadence.
        if let owner { session.displayCachedVisiblePages(owner.translationVisiblePages) }
        guard scrollVisibilityTask == nil else { return }
        scrollVisibilityTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            guard let self, !Task.isCancelled, isVisible, let owner else { return }
            scrollVisibilityTask = nil
            let current = ScrollVisibility(chapter: owner.translationChapterKey,
                index: owner.translationCurrentPageIndex,
                pages: owner.translationVisiblePages.map(ScrollVisibility.PageState.init),
                previews: owner.translationPreviewPages.map(ScrollVisibility.PageState.init))
            guard current != scrollVisibility else { return }
            scrollVisibility = current
            visiblePagesDidChange()
        }
    }
    private var memoryRecoveryTask: Task<Void, Never>?
    private var navigationIdentity: String?
    private var diagnosticVisibleKeys: [String] = []
    private var isScrubbing = false
    private var navigationDebounce = ReaderTranslationNavigationDebounce()
    private let session: ReaderTranslationSession
    private let readSettings: () -> ReaderTranslationSettings
    private let setEnabled: (Bool) -> Void

    init(
        owner: any ReaderTranslationOwner,
        session: ReaderTranslationSession? = nil,
        readSettings: @escaping () -> ReaderTranslationSettings = { ReaderTranslationSettings() },
        setEnabled: @escaping (Bool) -> Void = { ReaderTranslationSettings.setAutomaticTranslation($0) }
    ) {
        let persistsCache = owner.translationPersistsCache
        self.preloader = ReaderTranslationPreloader(diskCache: persistsCache ? .shared : nil)
        self.owner = owner
        self.readSettings = readSettings
        self.setEnabled = setEnabled
        self.session = session ?? ReaderTranslationSession(
            process: { [preloader] page, settings, progress in
                try await preloader.translate(page, settings: settings, onProgress: progress)
            },
            cancelProcessing: { [preloader] in preloader.cancel() },
            cancelProcessingForPage: { [preloader] page in preloader.cancel(preservingRecognitionFor: page) },
            diskCache: persistsCache ? .shared : nil, renderCache: persistsCache ? .shared : nil,
            prepareLayout: { [weak owner, layoutPreparer] page, regions, settings in
                guard persistsCache, let visible = owner?.translationVisiblePages.first, let imageView = visible.imageView,
                      let window = imageView.window, imageView.bounds.width > 0, imageView.bounds.height > 0 else { throw CancellationError() }
                try await layoutPreparer.prepare(
                    page: page, regions: regions, settings: settings,
                    geometry: ReaderTranslationLayoutGeometry(page: visible, imageView: imageView), window: window
                )
            },
            prepareTextLayout: { [weak owner, layoutPreparer] page, regions, settings in
                guard persistsCache, let visible = owner?.translationVisiblePages.first, let imageView = visible.imageView else { return }
                try await layoutPreparer.prepareTextOnly(page: page, regions: regions, settings: settings,
                    geometry: ReaderTranslationLayoutGeometry(page: visible, imageView: imageView))
            }
        )
        preloader.nextPage = { [weak session = self.session] page in session?.nextPageForRecognition(after: page) }
        preloader.onPrepared = { [weak session = self.session] page, regions, settings in
            session?.receivePrepared(page, regions: regions, settings: settings)
        }
        self.session.onStateChanged = { [weak self] state in
            self?.button.image = UIImage(systemName: state == .on ? "character.bubble.fill" : "character.bubble")
            self?.button.tintColor = state == .on ? .systemGreen : .secondaryLabel
            self?.button.accessibilityValue = NSLocalizedString(state == .on ? "TRANSLATION_STATE_ON" : "TRANSLATION_STATE_OFF")
        }
        self.session.onFailure = { [weak self] error in
            guard let self else { return }
            button.accessibilityHint = error.localizedDescription
            showFailureNotice(error)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: ReaderTranslationPage.sourceImageReady, object: nil, queue: .main
        ) { [weak self] notification in
            guard let source = notification.object as? ReaderTranslationPage.LoadedSource else { return }
            Task { @MainActor [weak self] in
                guard let self, isVisible, !isScrubbing else { return }
                self.layoutPreparer.sourceDidLoad(source.image, page: source.page)
                self.session.sourceImageDidLoad(source.page)
            }
        })
        for name in [ReaderTranslationSettings.changed, ReaderTranslationPage.imageChanged, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.visiblePagesDidChange() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.cancel(reason: "app_inactive") } })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Inspect every warning, including escalation during a recovery.
                guard self.session.handleMemoryWarning() else { return }
                guard self.memoryRecoveryTask == nil else { return }
                self.memoryRecoveryTask = Task { [weak self] in
                    guard let self else { return }
                    ReaderTranslationRenderCache.shared.clearMemory()
                    if #available(iOS 18.0, *) { await ReaderOCRService.shared.purge() }
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    self.memoryRecoveryTask = nil
                    self.visiblePagesDidChange()
                }
            }
        })
    }

    deinit {
        scrollVisibilityTask?.cancel()
        let previous = metadataActivityTask
        let owner = metadataOwner
        Task {
            await previous?.value
            await ReaderTranslationService.shared.setReaderActive(false, owner: owner)
        }
        failureNoticeTask?.cancel()
        memoryRecoveryTask?.cancel()
        synchronizationTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func dismissFailureNotice() {
        failureNoticeTask?.cancel()
        failureNoticeTask = nil
        failureNotice?.removeFromSuperview()
        failureNotice = nil
    }

    private func showFailureNotice(_ error: Error) {
        guard isVisible, let host = (owner as? UIViewController)?.viewIfLoaded,
              host.window != nil else { return }
        dismissFailureNotice()
        let notice = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        notice.accessibilityIdentifier = "reader.translation.failure"
        notice.layer.cornerRadius = 12
        notice.clipsToBounds = true
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 3
        label.text = error is ReaderTranslationOCRFallback
            ? NSLocalizedString("TRANSLATION_CONNECTION_FAILED_NOTICE")
            : NSLocalizedString("TRANSLATION_TITLE") + ": " + error.localizedDescription
        let retry = UIButton(type: .system)
        retry.setTitle(NSLocalizedString("RETRY"), for: .normal)
        retry.accessibilityIdentifier = "reader.translation.retry"
        retry.setContentCompressionResistancePriority(.required, for: .horizontal)
        retry.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            dismissFailureNotice()
            button.accessibilityHint = nil
            session.retryVisibleFailures()
        }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, retry])
        stack.spacing = 12
        stack.alignment = .center
        notice.contentView.addSubview(stack)
        host.addSubview(notice)
        notice.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            notice.leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            notice.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            notice.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: notice.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: notice.contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: notice.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: notice.contentView.bottomAnchor, constant: -8),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        failureNotice = notice
        UIAccessibility.post(notification: .announcement, argument: label.text)
        failureNoticeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            self?.dismissFailureNotice()
        }
    }

    func install() {
        guard #available(iOS 18.0, *), let owner else { return }
        button.accessibilityLabel = NSLocalizedString("TRANSLATION_TITLE")
        button.accessibilityIdentifier = "reader.translation.toggle"
        button.tintColor = .secondaryLabel
        let items = (owner.navigationItem.rightBarButtonItems ?? []) + [button]
        if #available(iOS 26.0, *) {
            items.forEach { $0.sharesBackground = true }
        }
        owner.navigationItem.rightBarButtonItems = items
    }

    private func updateMetadataActivity(active: Bool) {
        guard metadataPaused != active else { return }
        metadataPaused = active
        let previous = metadataActivityTask
        let owner = metadataOwner
        metadataActivityTask = Task {
            await previous?.value
            await ReaderTranslationService.shared.setReaderActive(active, owner: owner)
        }
    }

    @objc func toggle() {
        dismissFailureNotice()
        if session.state != .off || readSettings().automaticallyTranslate {
            synchronizationTask?.cancel()
            synchronizationTask = nil
            session.disable(preservingVisibleRendering: true)
            setEnabled(false)
            updateMetadataActivity(active: false)
        } else {
            button.accessibilityHint = nil
            setEnabled(true)
            visiblePagesDidChange()
        }
    }

    func resume() { isVisible = true; visiblePagesDidChange() }
    func suspend() {
        cancelScrollVisibility()
        dismissFailureNotice()
        isVisible = false
        updateMetadataActivity(active: false)
        synchronizationTask?.cancel()
        synchronizationTask = nil
        navigationDebounce.reset()
        navigationIdentity = nil
        session.disable(reason: "reader_left")
    }
    func cancel(reason: String = "cancelled") { session.suspendWorkForResourcePressure() }
    func close() {
        cancelScrollVisibility()
        dismissFailureNotice()
        memoryRecoveryTask?.cancel()
        memoryRecoveryTask = nil
        synchronizationTask?.cancel()
        synchronizationTask = nil
        isVisible = false
        updateMetadataActivity(active: false)
        session.close()
        owner = nil
        NotificationCenter.default.post(name: ReaderTranslationLayoutAwaiter.invalidated, object: nil)
        // The selected OCR models remain warm across readers. Memory pressure
        // and OCR configuration changes are the resource-release boundaries.
    }

    func sliderInteractionBegan() {
        cancelScrollVisibility()
        isScrubbing = true
        navigationDebounce.reset()
        synchronizationTask?.cancel()
        synchronizationTask = nil
        session.pauseForPageTurn()
    }

    func sliderInteractionEnded() {
        isScrubbing = false
        navigationDebounce.reset()
        navigationIdentity = nil
        visiblePagesDidChange()
    }

    func visiblePagesDidChange() {
        guard isVisible, let owner else { return }
        updateMetadataActivity(active: readSettings().automaticallyTranslate)
        let identity = owner.translationChapterKey + ":" + String(owner.translationCurrentPageIndex)
        let moved = navigationIdentity != identity
        var delay: UInt64 = 80_000_000
        if moved {
            dismissFailureNotice()
            delay = navigationDebounce.delay(chapter: owner.translationChapterKey,
                                             index: owner.translationCurrentPageIndex,
                                             now: ProcessInfo.processInfo.systemUptime)
            navigationIdentity = identity
            let pages = owner.translationUpcomingPages
            let index = owner.translationCurrentPageIndex
            let destination = pages.indices.contains(index) ? pages[index] : nil
            session.pauseForPageTurn(preservingRecognitionFor: destination)
            synchronizationTask?.cancel()
            synchronizationTask = nil
        }
        // Existing results can display immediately without starting OCR.
        session.refreshVisiblePages(owner.translationVisiblePages,
            previews: readSettings().automaticallyTranslate ? owner.translationPreviewPages : [])
        // Cache-only preparation follows navigation immediately. Otherwise rapid
        // scrolling keeps cancelling lookahead and postponing its restart by 350ms.
        // OCR/provider work stays paused until the navigation debounce expires.
        if moved, !isScrubbing, session.state == .on, !owner.translationVisiblePages.isEmpty,
           readSettings().automaticallyTranslate {
            let visible = owner.translationVisiblePages
            let context = visible.first.flatMap { page in
                page.imageView.map { ReaderTranslationLayoutGeometry(page: page, imageView: $0).context }
            }
            session.update(items: ReaderTranslationSession.chapterItems(owner.translationUpcomingPages),
                visible: visible, context: owner.translationChapterKey,
                currentPageIndex: owner.translationCurrentPageIndex, renderContext: context,
                processUncachedPages: false)
        }
        guard !isScrubbing, synchronizationTask == nil else { return }
        synchronizationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            synchronizationTask = nil
            synchronizeVisiblePages()
        }
    }

    private func synchronizeVisiblePages() {
        guard #available(iOS 18.0, *), let owner, isVisible, UIApplication.shared.applicationState == .active else { return }
        let visible = owner.translationVisiblePages
        let visibleKeys = visible.compactMap { $0.sourcePage?.translationCacheKey }
        if visibleKeys != diagnosticVisibleKeys {
            diagnosticVisibleKeys = visibleKeys
            ReaderTranslationDiagnostics.record("visible_window", page: owner.translationCurrentPageIndex + 1, count: visible.count)
            for page in visible {
                ReaderTranslationDiagnostics.record("visible_page", page: (page.sourcePage?.index ?? -2) + 1,
                    count: Int(page.imageView?.bounds.width ?? 0), code: Int(page.imageView?.bounds.height ?? 0))
            }
        }
        session.refreshVisiblePages(visible, previews: readSettings().automaticallyTranslate ? owner.translationPreviewPages : [])
        let pages = owner.translationUpcomingPages
        let renderContext = visible.first.flatMap { page in
            page.imageView.map { ReaderTranslationLayoutGeometry(page: page, imageView: $0).context }
        }
        session.update(items: ReaderTranslationSession.chapterItems(pages), visible: visible, context: owner.translationChapterKey,
                       currentPageIndex: owner.translationCurrentPageIndex, renderContext: renderContext)
        var settings = readSettings()
        settings.rightToLeftPanelOrder = owner.translationReadsRightToLeft
        if settings.automaticallyTranslate { session.enable(settings: settings) } else { session.disable(preservingVisibleRendering: true) }
    }
}

extension ReaderTranslationCoordinator {
    /// These observers belong to one render request. Turning translation off or
    /// closing the reader cancels even a queued exporter, releasing its source.
    private func performImagePreparation(
        _ operation: @escaping @MainActor () async throws -> UIImage
    ) async throws -> UIImage {
        let rendering = Task { try await operation() }
        let names = [ReaderTranslationSettings.changed, ReaderTranslationLayoutAwaiter.invalidated,
                     UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification]
        let observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in rendering.cancel() }
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }
        return try await withTaskCancellationHandler { try await rendering.value } onCancel: { rendering.cancel() }
    }

    private func imagePreparationSettings() -> ReaderTranslationSettings? {
        guard let owner else { return nil }
        var settings = readSettings()
        guard settings.automaticallyTranslate, settings.overlay.visible else { return nil }
        settings.rightToLeftPanelOrder = owner.translationReadsRightToLeft
        return settings
    }

    /// Return a finished source-aspect image before the loader exposes the source.
    /// Warm render assets replay without a window; only legacy text-only entries
    /// wait for a host, using layout/activation events instead of polling UIKit.
    func prepareCachedImage(
        image: UIImage, page: Page,
        geometry: @escaping @MainActor () -> ReaderTranslationImageGeometry?
    ) async throws -> ReaderTranslationPreparedImage? {
        guard #available(iOS 18.0, *) else { return nil }
        let pageKey = page.translationCacheKey
        let crop = page.translationSourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        func renderKey(_ settings: ReaderTranslationSettings, _ geometry: ReaderTranslationImageGeometry) -> String {
            ReaderTranslationCacheIdentity.render(page: pageKey, settings: settings, imageSize: image.size,
                viewport: geometry.viewport, scale: geometry.scale, aspectFit: geometry.aspectFit, crop: crop, dark: geometry.dark)
        }
        while true {
            try Task.checkCancellation()
            guard owner != nil else { throw CancellationError() }
            guard let settings = imagePreparationSettings() else { return nil }
            let result = try await session.cachedRegions(for: page, settings: settings)
            try Task.checkCancellation()
            guard owner != nil else { throw CancellationError() }
            guard imagePreparationSettings() == settings else { continue }
            guard let result else { return nil }
            let regions = result.compactMap { $0.cropped(to: crop) }
            guard !regions.isEmpty else { return nil }
            guard let current = geometry(), current.isValid else {
                guard let host = (owner as? UIViewController)?.viewIfLoaded else {
                    throw ReaderTranslationImageExporter.ExportError.unavailable
                }
                try await ReaderTranslationLayoutAwaiter.wait(in: host) { [weak self] in
                    self?.imagePreparationSettings() != settings || geometry()?.isValid == true
                }
                continue
            }
            let key = renderKey(settings, current)
            let host = (owner as? UIViewController)?.viewIfLoaded
            let activeHost = UIApplication.shared.applicationState == .active && host?.window?.windowScene != nil ? host : nil
            let cache = owner?.translationPersistsCache == true ? session.renderCache : nil
            let rendered: UIImage
            do {
                rendered = try await performImagePreparation {
                    try await ReaderTranslationImageExporter.renderLoadedImage(
                        image: image, regions: regions, settings: settings, viewport: current.viewport,
                        scale: current.scale, aspectFit: current.aspectFit, dark: current.dark,
                        host: activeHost, cache: cache, key: key,
                        pageIdentity: ReaderTranslationCacheIdentity.translation(page: pageKey, settings: settings)
                    )
                }
            } catch is CancellationError {
                try Task.checkCancellation()
                guard owner != nil else { throw CancellationError() }
                // A request event cancelled the child. Re-read settings so OFF
                // can return the source immediately and background can use RAM.
                continue
            } catch ReaderTranslationImageExporter.ExportError.unavailable {
                try Task.checkCancellation()
                guard owner != nil else { throw CancellationError() }
                if imagePreparationSettings() != settings || geometry() != current { continue }
                // A warm asset does not need this condition. A cache miss asks
                // for WebKit only after its attached, active host becomes ready.
                guard let host else { throw ReaderTranslationImageExporter.ExportError.unavailable }
                guard UIApplication.shared.applicationState != .active || host.window?.windowScene == nil else {
                    throw ReaderTranslationImageExporter.ExportError.unavailable
                }
                try await ReaderTranslationLayoutAwaiter.wait(in: host) { [weak self, weak host] in
                    guard self?.imagePreparationSettings() == settings, let latest = geometry(), latest.isValid,
                          renderKey(settings, latest) == key else { return true }
                    return host?.window?.windowScene != nil && UIApplication.shared.applicationState == .active
                }
                continue
            } catch {
                try Task.checkCancellation()
                guard owner != nil else { throw CancellationError() }
                if imagePreparationSettings() != settings || geometry() != current { continue }
                throw error
            }
            try Task.checkCancellation()
            guard owner != nil else { throw CancellationError() }
            guard imagePreparationSettings() == settings, let latest = geometry(), latest.isValid,
                  renderKey(settings, latest) == key else { continue }
            return ReaderTranslationPreparedImage(image: rendered, regions: result, settings: settings,
                isCurrent: { [weak self] in
                    guard self?.imagePreparationSettings() == settings, let latest = geometry(), latest.isValid else { return false }
                    return renderKey(settings, latest) == key
                })
        }
    }
}
