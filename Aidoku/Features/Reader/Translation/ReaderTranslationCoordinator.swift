import UIKit

@MainActor
protocol ReaderTranslationOwner: AnyObject {
    var navigationItem: UINavigationItem { get }
    var translationUpcomingPages: [Page] { get }
    var translationVisiblePages: [ReaderTranslationPage] { get }
    var translationPreviewPages: [ReaderTranslationPage] { get }
    var translationChapterKey: String { get }
    var translationCurrentPageIndex: Int { get }
    var translationReadingDirection: V2ReadingDirection { get }
    var translationPersistsCache: Bool { get }
    func translationWidePageLayout(for page: Page?) -> ReaderTranslationWidePageLayout
}

extension ReaderViewController: ReaderTranslationOwner {
    var translationPersistsCache: Bool { !isTemporaryImageSession }
    var translationReadingDirection: V2ReadingDirection {
        switch readingMode {
        case .rtl: .rightToLeft
        case .ltr: .leftToRight
        case .vertical, .webtoon, .continuous: .topToBottom
        }
    }
    var translationVisiblePages: [ReaderTranslationPage] { reader?.translationPages() ?? [] }
    var translationPreviewPages: [ReaderTranslationPage] { reader?.translationPreviewPages() ?? [] }
    var translationChapterKey: String { chapter.key }
    func translationWidePageLayout(for page: Page?) -> ReaderTranslationWidePageLayout {
        (reader as? ReaderPagedViewController)?.translationWidePageLayout(for: page) ?? .whole
    }
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

/// Reader page translation: every visible page renders through
/// `ReaderTranslationV2Service`, and the next
/// pages are pre-translated into the V2 caches.
@MainActor
final class ReaderTranslationCoordinator {
    private weak var owner: (any ReaderTranslationOwner)?
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
    private var navigationIdentity: String?
    /// Reader open/resume has no navigation to settle; its first populated viewport uses the short delay.
    private var initialSynchronizationPending = true
    private var isScrubbing = false
    private var navigationDebounce = ReaderTranslationNavigationDebounce()
    private let v2Pages = NSHashTable<ReaderTranslationPage>.weakObjects()
    /// V2 look-ahead consumers by the whole-page V2 cache key (pages after the viewport).
    private var v2Lookahead: [String: Task<Void, Never>] = [:]
    /// Look-ahead keys already translated in this session, so synchronization never re-decodes them.
    private var v2LookaheadFinished: Set<String> = []
    private let v2Loader: ReaderTranslationImageLoader

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

    init(owner: any ReaderTranslationOwner, temporaryPageStore: ReaderTemporaryPageStore) {
        self.v2Loader = ReaderTranslationImageLoader(temporaryStore: temporaryPageStore)
        self.owner = owner
        for name in [ReaderTranslationPage.sourceImageReady, ReaderTranslationSettings.changed,
                     ReaderTranslationPage.imageChanged, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isScrubbing else { return }
                    self.visiblePagesDidChange()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Visible pages keep their work; offscreen look-ahead restarts later.
            Task { @MainActor in self?.cancelV2Lookahead() }
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
        synchronizationTask?.cancel()
        v2Lookahead.values.forEach { $0.cancel() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func cancelSynchronization() {
        synchronizationTask?.cancel()
        synchronizationTask = nil
    }

    private func cancelScrollVisibility() {
        scrollVisibilityTask?.cancel()
        scrollVisibilityTask = nil
        scrollVisibility = nil
    }

    /// Scroll callbacks run at display frequency; read the latest viewport at a bounded cadence.
    func scrollVisibilityDidChange() {
        guard isVisible, scrollVisibilityTask == nil else { return }
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
        label.text = NSLocalizedString("TRANSLATION_TITLE") + ": " + error.localizedDescription
        let retry = UIButton(type: .system)
        retry.setTitle(NSLocalizedString("RETRY"), for: .normal)
        retry.accessibilityIdentifier = "reader.translation.retry"
        retry.setContentCompressionResistancePriority(.required, for: .horizontal)
        retry.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            dismissFailureNotice()
            button.accessibilityHint = nil
            owner?.translationVisiblePages.forEach { $0.retryV2() }
            visiblePagesDidChange()
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
        if #available(iOS 26.0, *) { items.forEach { $0.sharesBackground = true } }
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
        button.accessibilityHint = nil
        // The settings notification resynchronizes (or hides) visible pages.
        ReaderTranslationSettings.setAutomaticTranslation(!ReaderTranslationSettings().automaticallyTranslate)
        visiblePagesDidChange()
    }

    func resume() { isVisible = true; visiblePagesDidChange() }

    func suspend() {
        // A completed departure releases the attached bitmaps; returning to the
        // reader re-presents them from the V2 memory cache.
        stop { $0.hideV2() }
        navigationDebounce.reset()
        navigationIdentity = nil
        initialSynchronizationPending = true
    }

    /// Chapter changes: stop page work for the old chapter.
    func cancel() {
        v2Pages.allObjects.forEach { $0.cancelV2Work() }
        cancelV2Lookahead()
    }

    /// The V2 models remain warm across readers; memory pressure releases them.
    func close() {
        stop { $0.cancelV2Work() }
        owner = nil
    }

    private func stop(_ releasePage: (ReaderTranslationPage) -> Void) {
        cancelScrollVisibility()
        dismissFailureNotice()
        cancelSynchronization()
        isVisible = false
        updateMetadataActivity(active: false)
        v2Pages.allObjects.forEach(releasePage)
        v2Pages.removeAllObjects()
        cancelV2Lookahead()
    }

    func sliderInteractionBegan() {
        cancelScrollVisibility()
        isScrubbing = true
        navigationDebounce.reset()
        cancelSynchronization()
    }

    func sliderInteractionEnded() {
        isScrubbing = false
        navigationDebounce.reset()
        navigationIdentity = nil
        visiblePagesDidChange()
    }

    fileprivate func applyButtonState(enabled: Bool) {
        button.image = UIImage(systemName: enabled ? "character.bubble.fill" : "character.bubble")
        button.tintColor = enabled ? .systemGreen : .secondaryLabel
        button.accessibilityValue = NSLocalizedString(enabled ? "TRANSLATION_STATE_ON" : "TRANSLATION_STATE_OFF")
    }

    /// Settings for reader pages: the saved preferences plus this reader's direction.
    private func pageSettings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings()
        if let owner { settings.readingDirection = owner.translationReadingDirection }
        return settings
    }

    func visiblePagesDidChange() {
        guard isVisible, let owner else { return }
        let settings = ReaderTranslationSettings()
        applyButtonState(enabled: settings.automaticallyTranslate)
        updateMetadataActivity(active: settings.shouldProcessReaderPages)
        let visible = owner.translationVisiblePages
        // Pages that scrolled away stop their pipeline (and provider) work.
        for page in v2Pages.allObjects where !visible.contains(where: { $0 === page }) {
            page.cancelV2Work()
            v2Pages.remove(page)
        }
        let identity = owner.translationChapterKey + ":" + String(owner.translationCurrentPageIndex)
        var delay: UInt64 = 80_000_000
        if navigationIdentity != identity {
            dismissFailureNotice()
            navigationIdentity = identity
            delay = navigationDebounce.delay(chapter: owner.translationChapterKey,
                                             index: owner.translationCurrentPageIndex,
                                             now: ProcessInfo.processInfo.systemUptime)
            if initialSynchronizationPending {
                delay = 80_000_000
                if !visible.isEmpty { initialSynchronizationPending = false }
            }
            cancelSynchronization()
        }
        guard !isScrubbing, synchronizationTask == nil else { return }
        synchronizationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            synchronizationTask = nil
            synchronizeVisiblePages()
        }
    }

    private func synchronizeVisiblePages() {
        guard let owner, isVisible, UIApplication.shared.applicationState == .active else { return }
        let settings = pageSettings()
        let persistsCache = owner.translationPersistsCache
        for page in owner.translationVisiblePages {
            guard settings.automaticallyTranslate else { page.hideV2(); continue }
            v2Pages.add(page)
            page.processV2(settings: settings, persistsCache: persistsCache, onPresented: { [weak self] in
                // Visible pages done: widen the look-ahead.
                self?.updateV2Lookahead()
            }, onFailure: { [weak self] error in
                guard let self else { return }
                button.accessibilityHint = error.localizedDescription
                showFailureNotice(error)
            })
        }
        updateV2Lookahead()
    }

    // MARK: Cached presentation

    /// A cached V2 page bitmap to attach in the same commit as the source image (no source flash).
    /// A miss returns nil and the page translates once it is visible.
    func prepareCachedImage(image: UIImage, page: Page) async throws -> ReaderTranslationPreparedImage? {
        guard #available(iOS 18.0, *), let owner else { return nil }
        let settings = pageSettings()
        guard settings.automaticallyTranslate, settings.overlay.visible else { return nil }
        let crop = page.translationSourceRect ?? ReaderTranslationSplitGeometry.unit
        let key = ReaderTranslationV2Service.cacheKey(page: page.translationCacheKey, crop: crop, settings: settings)
        let cached = await ReaderTranslationV2Service.shared.cachedPage(cacheKey: key, persists: owner.translationPersistsCache)
        try Task.checkCancellation()
        guard let cached else {
            ReaderTranslationDiagnostics.record("loaded_translation_miss")
            return nil
        }
        // The cached bitmap is the upright source; it must match the source size.
        let upright = [.up, .upMirrored, .down, .downMirrored].contains(image.imageOrientation)
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let expected = upright ? pixelSize : CGSize(width: pixelSize.height, height: pixelSize.width)
        guard abs(CGFloat(cached.width) - expected.width) <= 1, abs(CGFloat(cached.height) - expected.height) <= 1 else {
            return nil
        }
        ReaderTranslationDiagnostics.record("loaded_translation_hit")
        return ReaderTranslationPreparedImage(
            image: UIImage(cgImage: cached, scale: image.scale, orientation: .up), settings: settings, v2CacheKey: key,
            isCurrent: { [weak self] in
                guard let self, self.owner != nil else { return false }
                let current = self.pageSettings()
                return current.automaticallyTranslate && current.overlay.visible &&
                    ReaderTranslationV2Service.cacheKey(page: page.translationCacheKey, crop: crop, settings: current) == key
            }, matchesSourceImage: { [weak image] candidate in candidate === image })
    }
}

// MARK: - Look-ahead

extension ReaderTranslationCoordinator {
    /// One page after the viewport while visible pages are pending, two once they are presented
    /// (or in background-only mode), plus the performance profile's extra pages, bounded by the
    /// pretranslation limit. A page that becomes visible joins its running computation. Wide
    /// pages shown as halves are translated per half.
    private func updateV2Lookahead() {
        guard #available(iOS 18.0, *), let owner, isVisible, owner.translationPersistsCache else {
            cancelV2Lookahead()
            return
        }
        let settings = pageSettings()
        guard settings.shouldProcessReaderPages else { cancelV2Lookahead(); return }
        let targets = Self.v2LookaheadPages(
            upcoming: owner.translationUpcomingPages, visible: owner.translationVisiblePages,
            currentIndex: owner.translationCurrentPageIndex, settings: settings)
        let unit = ReaderTranslationSplitGeometry.unit
        func key(_ page: Page, _ crop: CGRect = unit) -> String {
            ReaderTranslationV2Service.cacheKey(page: page.translationCacheKey, crop: crop, settings: settings)
        }
        // Visible pages join (and promote) any look-ahead already running for them.
        let retained = Set(targets.map { key($0) }).union(owner.translationVisiblePages.compactMap { $0.sourcePage.map { key($0) } })
        for (stale, task) in v2Lookahead where !retained.contains(stale) {
            task.cancel()
            v2Lookahead[stale] = nil
        }
        for page in targets {
            let taskKey = key(page)
            guard v2Lookahead[taskKey] == nil, !v2LookaheadFinished.contains(taskKey) else { continue }
            let splitsWidePages = owner.translationWidePageLayout(for: page) == .halves
            let direction = settings.readingDirection
            let loader = v2Loader
            v2Lookahead[taskKey] = Task { [weak self] in
                defer { if let self, !Task.isCancelled { self.v2Lookahead[taskKey] = nil } }
                do {
                    let image = try await loader.load(page)
                    try Task.checkCancellation()
                    let crops = Self.v2LookaheadCrops(imageSize: image.size, splitsWidePages: splitsWidePages, direction: direction)
                    for crop in crops {
                        guard let part = ReaderTranslationSplitGeometry.image(image, crop: crop) else { continue }
                        let pixels = await Task.detached(priority: .utility) {
                            ReaderTranslationImagePreparation.uprightSourceImage(part).cgImage
                        }.value
                        try Task.checkCancellation()
                        guard let pixels else { continue }
                        _ = try await ReaderTranslationV2Service.shared.translatePage(
                            pixels, cacheKey: key(page, crop), settings: settings, priority: .prefetch)
                    }
                    if let self, !Task.isCancelled {
                        if v2LookaheadFinished.count >= 256 { v2LookaheadFinished.removeAll() }
                        v2LookaheadFinished.insert(taskKey)
                    }
                    ReaderTranslationDiagnostics.record("v2_lookahead_finished", page: page.index + 1, count: crops.count)
                } catch {
                    // Offscreen failures never surface; the page retries when visible.
                }
            }
        }
    }

    /// The whole page, or both halves (reading order first) when the reader splits wide pages.
    private nonisolated static func v2LookaheadCrops(
        imageSize: CGSize, splitsWidePages: Bool, direction: V2ReadingDirection
    ) -> [CGRect] {
        guard splitsWidePages, imageSize.height > 0, imageSize.width / imageSize.height > 1 else {
            return [ReaderTranslationSplitGeometry.unit]
        }
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        return direction == .rightToLeft ? [right, left] : [left, right]
    }

    private static func v2LookaheadPages(
        upcoming: [Page], visible: [ReaderTranslationPage], currentIndex: Int, settings: ReaderTranslationSettings
    ) -> [Page] {
        guard settings.shouldProcessReaderPages else { return [] }
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        let visiblePresented = !visible.isEmpty && visible.allSatisfy(\.isPresentingV2)
        let backgroundOnly = !settings.automaticallyTranslate && settings.translateInBackground
        var count = backgroundOnly || visiblePresented ? 2 : 1
        count = V2PerformanceProfile.current.lookaheadCount(automatic: count)
        if let limit = settings.maximumPretranslatedPages { count = min(count, limit) }
        let unit = ReaderTranslationSplitGeometry.unit
        func whole(_ page: Page) -> Bool { page.translationSourceRect == nil || page.translationSourceRect == unit }
        // Background-only mode also prepares the visible pages without presenting them.
        let visiblePages = backgroundOnly ? upcoming.filter { visibleKeys.contains($0.translationCacheKey) && whole($0) } : []
        let last = upcoming.lastIndex { visibleKeys.contains($0.translationCacheKey) } ?? currentIndex
        guard count > 0, last + 1 < upcoming.count else { return visiblePages }
        var seen = visibleKeys
        var next: [Page] = []
        for page in upcoming[(last + 1)...] where next.count < count && whole(page) {
            guard seen.insert(page.translationCacheKey).inserted else { continue }
            next.append(page)
        }
        return visiblePages + next
    }

    private func cancelV2Lookahead() {
        v2Lookahead.values.forEach { $0.cancel() }
        v2Lookahead.removeAll()
        v2LookaheadFinished.removeAll()
    }
}
