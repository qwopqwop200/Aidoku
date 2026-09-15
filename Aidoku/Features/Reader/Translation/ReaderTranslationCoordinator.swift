import UIKit

@MainActor
protocol ReaderTranslationOwner: AnyObject {
    var navigationItem: UINavigationItem { get }
    var translationUpcomingPages: [Page] { get }
    var translationVisiblePages: [ReaderTranslationPage] { get }
    var translationChapterKey: String { get }
    var translationCurrentPageIndex: Int { get }
    var translationReadsRightToLeft: Bool { get }
}

extension ReaderTranslationOwner {
    var translationReadsRightToLeft: Bool { false }
    var translationCurrentPageIndex: Int {
        guard let key = translationVisiblePages.first?.sourcePage?.translationCacheKey else { return 0 }
        return translationUpcomingPages.firstIndex { $0.translationCacheKey == key } ?? 0
    }
}

extension ReaderViewController: ReaderTranslationOwner {
    var translationReadsRightToLeft: Bool { readingMode == .rtl }
    var translationVisiblePages: [ReaderTranslationPage] { reader?.translationPages() ?? [] }
    var translationChapterKey: String { chapter.key }
}

@MainActor
final class ReaderTranslationCoordinator {
    private weak var owner: (any ReaderTranslationOwner)?
    private let preloader = ReaderTranslationPreloader(diskCache: .shared)
    private let layoutPreparer = ReaderTranslationLayoutPreparer()
    private lazy var button = UIBarButtonItem(image: UIImage(systemName: "character.bubble"), style: .plain, target: self, action: #selector(toggle))
    private var observers: [NSObjectProtocol] = []
    private var isVisible = false
    private var synchronizationTask: Task<Void, Never>?
    private var navigationIdentity: String?
    private var failureNotice: UIView?
    private var failureNoticeTask: Task<Void, Never>?
    private let session: ReaderTranslationSession
    private let readSettings: () -> ReaderTranslationSettings
    private let setEnabled: (Bool) -> Void

    init(
        owner: any ReaderTranslationOwner,
        session: ReaderTranslationSession? = nil,
        readSettings: @escaping () -> ReaderTranslationSettings = { ReaderTranslationSettings() },
        setEnabled: @escaping (Bool) -> Void = { ReaderTranslationSettings.setAutomaticTranslation($0) }
    ) {
        self.owner = owner
        self.readSettings = readSettings
        self.setEnabled = setEnabled
        self.session = session ?? ReaderTranslationSession(
            process: { [preloader] page, settings, progress in
                try await preloader.translate(page, settings: settings, onProgress: progress)
            },
            cancelProcessing: { [preloader] in preloader.cancel() },
            cancelProcessingForPage: { [preloader] page in preloader.cancel(preservingRecognitionFor: page) },
            diskCache: .shared, renderCache: .shared,
            prepareLayout: { [weak owner, layoutPreparer] page, regions, settings in
                guard let visible = owner?.translationVisiblePages.first, let imageView = visible.imageView,
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
            // A failed request stops this session, not the user's saved preference.
            button.accessibilityHint = error.localizedDescription
            showFailureNotice()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
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
                self?.session.suspendWorkForResourcePressure()
                ReaderTranslationRenderCache.shared.clearMemory()
                if #available(iOS 18.0, *) { await ReaderOCRService.shared.purge() }
                // A warning may arrive after the last navigation callback. Resume
                // through the settling delay instead of waiting for another swipe.
                self?.visiblePagesDidChange()
            }
        })
    }

    deinit {
        synchronizationTask?.cancel()
        failureNoticeTask?.cancel()
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

    private func showFailureNotice() {
        guard isVisible, let view = (owner as? UIViewController)?.viewIfLoaded,
              view.window != nil else { return }
        dismissFailureNotice()
        let notice = UIView()
        notice.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        notice.layer.cornerRadius = 10
        notice.isUserInteractionEnabled = false
        notice.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = NSLocalizedString("TRANSLATION_CONNECTION_FAILED_NOTICE", comment: "")
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        notice.addSubview(label)
        view.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            notice.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -72),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            label.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: notice.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: notice.bottomAnchor, constant: -10)
        ])
        failureNotice = notice
        UIAccessibility.post(notification: .announcement, argument: label.text)
        failureNoticeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            self?.dismissFailureNotice()
        }
    }

    private func dismissFailureNotice() {
        failureNoticeTask?.cancel()
        failureNoticeTask = nil
        failureNotice?.removeFromSuperview()
        failureNotice = nil
    }

    @objc func toggle() {
        dismissFailureNotice()
        if session.state != .off {
            session.disable()
            setEnabled(false)
        } else {
            button.accessibilityHint = nil
            setEnabled(true)
            visiblePagesDidChange()
        }
    }

    func resume() { isVisible = true; visiblePagesDidChange() }
    func suspend() { dismissFailureNotice(); isVisible = false; session.disable(reason: "reader_left") }
    func cancel(reason: String = "cancelled") { session.suspendWorkForResourcePressure() }
    func close() {
        dismissFailureNotice()
        isVisible = false
        session.close()
        if #available(iOS 18.0, *) { Task { await ReaderOCRService.shared.purge() } }
    }

    func visiblePagesDidChange() {
        guard isVisible, let owner else { return }
        let identity = owner.translationChapterKey + ":" + String(owner.translationCurrentPageIndex)
        let moved = navigationIdentity != identity
        if moved {
            navigationIdentity = identity
            session.pauseForPageTurn()
            synchronizationTask?.cancel()
            synchronizationTask = nil
        }
        // Existing results can display immediately without starting OCR.
        session.refreshVisiblePages(owner.translationVisiblePages)
        guard synchronizationTask == nil else { return }
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
        if settings.automaticallyTranslate { session.enable(settings: settings) } else { session.disable() }
    }
}
