import UIKit

@MainActor
protocol ReaderTranslationOwner: AnyObject {
    var navigationItem: UINavigationItem { get }
    var translationUpcomingPages: [Page] { get }
    var translationVisiblePages: [ReaderTranslationPage] { get }
    var translationChapterKey: String { get }
    var translationCurrentPageIndex: Int { get }
    var translationReadsRightToLeft: Bool { get }
    var translationPersistsCache: Bool { get }
}

extension ReaderTranslationOwner {
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
    var translationChapterKey: String { chapter.key }
}

@MainActor
final class ReaderTranslationCoordinator {
    private weak var owner: (any ReaderTranslationOwner)?
    private let preloader: ReaderTranslationPreloader
    private let layoutPreparer = ReaderTranslationLayoutPreparer()
    private lazy var button = UIBarButtonItem(image: UIImage(systemName: "character.bubble"), style: .plain, target: self, action: #selector(toggle))
    private var observers: [NSObjectProtocol] = []
    private var isVisible = false
    private var synchronizationTask: Task<Void, Never>?
    private var memoryRecoveryTask: Task<Void, Never>?
    private var navigationIdentity: String?
    private var isScrubbing = false
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
            }
        )
        preloader.nextPage = { [weak session = self.session] page in session?.nextPageForRecognition(after: page) }
        self.session.onStateChanged = { [weak self] state in
            self?.button.image = UIImage(systemName: state == .on ? "character.bubble.fill" : "character.bubble")
            self?.button.tintColor = state == .on ? .systemGreen : .secondaryLabel
            self?.button.accessibilityValue = state == .on ? "ON" : "OFF"
        }
        self.session.onFailure = { [weak self] error in
            guard let self else { return }
            // Automatic recovery is silent; keep failure details available to accessibility.
            button.accessibilityHint = error.localizedDescription
        }
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
        memoryRecoveryTask?.cancel()
        synchronizationTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
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

    @objc func toggle() {
        if session.state != .off || readSettings().automaticallyTranslate {
            synchronizationTask?.cancel()
            synchronizationTask = nil
            session.disable(preservingVisibleRendering: true)
            setEnabled(false)
        } else {
            button.accessibilityHint = nil
            setEnabled(true)
            visiblePagesDidChange()
        }
    }

    func resume() { isVisible = true; visiblePagesDidChange() }
    func suspend() { isVisible = false; session.disable(reason: "reader_left") }
    func cancel(reason: String = "cancelled") { session.suspendWorkForResourcePressure() }
    func close() {
        memoryRecoveryTask?.cancel()
        memoryRecoveryTask = nil
        isVisible = false
        session.close()
        // The selected OCR models remain warm across readers. Memory pressure
        // and OCR configuration changes are the resource-release boundaries.
    }

    func sliderInteractionBegan() {
        isScrubbing = true
        synchronizationTask?.cancel()
        synchronizationTask = nil
        session.pauseForPageTurn()
    }

    func sliderInteractionEnded() {
        isScrubbing = false
        navigationIdentity = nil
        visiblePagesDidChange()
    }

    func visiblePagesDidChange() {
        guard isVisible, let owner else { return }
        let identity = owner.translationChapterKey + ":" + String(owner.translationCurrentPageIndex)
        let moved = navigationIdentity != identity
        if moved {
            navigationIdentity = identity
            let pages = owner.translationUpcomingPages
            let index = owner.translationCurrentPageIndex
            let destination = pages.indices.contains(index) ? pages[index] : nil
            session.pauseForPageTurn(preservingRecognitionFor: destination)
            synchronizationTask?.cancel()
            synchronizationTask = nil
        }
        // Existing results can display immediately without starting OCR.
        session.refreshVisiblePages(owner.translationVisiblePages)
        guard !isScrubbing, synchronizationTask == nil else { return }
        synchronizationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: moved ? 350_000_000 : 80_000_000) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            synchronizationTask = nil
            synchronizeVisiblePages()
        }
    }

    private func synchronizeVisiblePages() {
        guard #available(iOS 18.0, *), let owner, isVisible, UIApplication.shared.applicationState == .active else { return }
        let visible = owner.translationVisiblePages
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
