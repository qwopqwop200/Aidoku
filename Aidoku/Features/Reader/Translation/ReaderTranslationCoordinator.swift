import UIKit

extension ReaderViewController {
    var translationPersistsCache: Bool { !isTemporaryImageSession }
    var translationReadingDirection: PipelineReadingDirection {
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

// Only isolated adjacent turns use the shorter debounce; startup, jumps, scrubbing and reversals wait longer.
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

// Reading pace and translation cost as moving averages, turned into how many pages to keep in flight.
struct ReaderTranslationLookaheadPace {
    private(set) var secondsPerPage: Double?
    private(set) var secondsPerTranslation: Double?
    private(set) var secondsLatency: Double?
    private var previous: (chapter: String, index: Int, time: TimeInterval)?
    private var lastFinish: TimeInterval?
    private static let weight = 0.3

    private static func average(_ old: Double?, _ sample: Double) -> Double {
        old.map { $0 + weight * (sample - $0) } ?? sample
    }

    // Only forward turns of one or two pages (spreads) are reading; jumps and reversals are not.
    mutating func pageChanged(chapter: String, index: Int, now: TimeInterval) {
        defer { previous = (chapter, index, now) }
        guard let previous, previous.chapter == chapter, (1...2).contains(index - previous.index) else { return }
        let sample = min(60, max(0.5, (now - previous.time) / Double(index - previous.index)))
        secondsPerPage = Self.average(secondsPerPage, sample)
    }

    // Throughput: time since the later of this start and the previous finish (parallel pages count once).
    mutating func pageTranslated(started: TimeInterval, now: TimeInterval) {
        let sample = min(120, max(0.05, now - max(started, lastFinish ?? started)))
        lastFinish = now
        secondsPerTranslation = Self.average(secondsPerTranslation, sample)
        secondsLatency = Self.average(secondsLatency, min(120, max(0.05, now - started)))
    }

    // `growth`: extra pages memory allows. Never above `limit` (nil = unlimited), never below min(base, 2).
    func count(base: Int, limit: Int?, growth: Int) -> Int {
        let ceiling = min(limit ?? .max, base + max(0, growth))
        guard let secondsPerPage, let secondsPerTranslation else { return min(base, ceiling) }
        let cost = max(secondsPerTranslation, secondsLatency ?? 0)
        let needed = Int(min(64, (cost / secondsPerPage).rounded(.up))) + 1
        return min(ceiling, max(min(base, 2), needed))
    }
}

/// Translates visible reader pages through `ReaderTranslationPipelineService` and pre-translates the next pages.
@MainActor
final class ReaderTranslationCoordinator {
    private weak var owner: ReaderViewController?
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
    private let pipelinePages = NSHashTable<ReaderTranslationPage>.weakObjects()
    /// Look-ahead tasks by whole-page pipeline cache key.
    private var pipelineLookahead: [String: Task<Void, Never>] = [:]
    private var pipelineLookaheadFinished: Set<String> = []
    private var lookaheadPace = ReaderTranslationLookaheadPace()
    private var pipelineLookaheadCount = 0
    private let pipelineLoader: ReaderTranslationImageLoader

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

    init(owner: ReaderViewController, temporaryPageStore: ReaderTemporaryPageStore) {
        self.pipelineLoader = ReaderTranslationImageLoader(temporaryStore: temporaryPageStore)
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
            Task { @MainActor in self?.cancelPipelineLookahead() }
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
        pipelineLookahead.values.forEach { $0.cancel() }
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
        guard isVisible, let host = owner?.viewIfLoaded, host.window != nil else { return }
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
            owner?.translationVisiblePages.forEach { $0.retryPipeline() }
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
        // Start the model load at viewDidLoad, not after the push transition (viewDidAppear).
        if ReaderTranslationSettings().shouldProcessReaderPages {
            Task(priority: .userInitiated) { await ReaderTranslationPipelineService.shared.prewarm() }
        }
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
        ReaderTranslationSettings.setAutomaticTranslation(!ReaderTranslationSettings().showsTranslation)
        visiblePagesDidChange()
    }

    func resume() { isVisible = true; visiblePagesDidChange() }

    func suspend() {
        // Returning re-presents the released bitmaps from the pipeline memory cache.
        stop { $0.hidePipeline() }
        navigationDebounce.reset()
        navigationIdentity = nil
        initialSynchronizationPending = true
    }

    /// Chapter change: look-ahead is pruned by the next sync, so a next-chapter page in flight is kept.
    func cancel() {
        pipelinePages.allObjects.forEach { $0.cancelPipelineWork() }
    }

    /// The pipeline models remain warm across readers; memory pressure releases them.
    func close() {
        stop { $0.cancelPipelineWork() }
        owner = nil
    }

    private func stop(_ releasePage: (ReaderTranslationPage) -> Void) {
        cancelScrollVisibility()
        dismissFailureNotice()
        cancelSynchronization()
        isVisible = false
        updateMetadataActivity(active: false)
        pipelinePages.allObjects.forEach(releasePage)
        pipelinePages.removeAllObjects()
        cancelPipelineLookahead()
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
        if #available(iOS 16.0, *) { button.isHidden = !settings.translatePages }
        updateMetadataActivity(active: settings.shouldProcessReaderPages)
        let visible = owner.translationVisiblePages
        // Pages that scrolled away stop their pipeline (and provider) work.
        for page in pipelinePages.allObjects where !visible.contains(where: { $0 === page }) {
            page.cancelPipelineWork()
            pipelinePages.remove(page)
        }
        let identity = owner.translationChapterKey + ":" + String(owner.translationCurrentPageIndex)
        var delay: UInt64 = 80_000_000
        if navigationIdentity != identity {
            dismissFailureNotice()
            navigationIdentity = identity
            let now = ProcessInfo.processInfo.systemUptime
            lookaheadPace.pageChanged(chapter: owner.translationChapterKey, index: owner.translationCurrentPageIndex, now: now)
            prunePipelineLookahead()
            delay = navigationDebounce.delay(chapter: owner.translationChapterKey,
                                             index: owner.translationCurrentPageIndex,
                                             now: now)
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
            guard settings.automaticallyTranslate else { page.hidePipeline(); continue }
            pipelinePages.add(page)
            page.processPipeline(settings: settings, persistsCache: persistsCache, onPresented: { [weak self] in
                // Visible pages done: widen the look-ahead.
                self?.updatePipelineLookahead()
            }, onFailure: { [weak self] error in
                guard let self else { return }
                button.accessibilityHint = error.localizedDescription
                showFailureNotice(error)
            })
        }
        updatePipelineLookahead()
    }

    // MARK: Cached presentation

    /// A cached page bitmap to attach in the same commit as the source image (no source flash).
    func prepareCachedImage(image: UIImage, page: Page) async throws -> ReaderTranslationPreparedImage? {
        guard #available(iOS 18.0, *), let owner else { return nil }
        let settings = pageSettings()
        guard settings.automaticallyTranslate, settings.overlay.visible else { return nil }
        let crop = page.translationSourceRect ?? ReaderTranslationSplitGeometry.unit
        let key = ReaderTranslationPipelineService.cacheKey(page: page.translationCacheKey, crop: crop, settings: settings)
        let cached = await ReaderTranslationPipelineService.shared.cachedPage(cacheKey: key, persists: owner.translationPersistsCache)
        try Task.checkCancellation()
        guard let cached else {
            ReaderTranslationDiagnostics.record("loaded_translation_miss")
            return nil
        }
        guard ReaderTranslationPage.fits(cached, source: image) else { return nil }
        ReaderTranslationDiagnostics.record("loaded_translation_hit")
        return ReaderTranslationPreparedImage(
            image: UIImage(cgImage: cached, scale: image.scale, orientation: .up), settings: settings, pipelineCacheKey: key,
            isCurrent: { [weak self] in
                guard let self, self.owner != nil else { return false }
                let current = self.pageSettings()
                return current.automaticallyTranslate && current.overlay.visible &&
                    ReaderTranslationPipelineService.cacheKey(page: page.translationCacheKey, crop: crop, settings: current) == key
            }, matchesSourceImage: { [weak image] candidate in candidate === image })
    }
}

// MARK: - Look-ahead

extension ReaderTranslationCoordinator {
    /// One page ahead while visible pages are pending, two once presented (or background-only), plus the
    /// profile's extra pages; then pace and memory adjust it. Wide pages shown as halves translate per half.
    private func updatePipelineLookahead() {
        guard #available(iOS 18.0, *), let owner, isVisible, owner.translationPersistsCache else {
            cancelPipelineLookahead()
            return
        }
        let settings = pageSettings()
        guard settings.shouldProcessReaderPages else { cancelPipelineLookahead(); return }
        let (base, grows) = Self.pipelineLookaheadBaseCount(visible: owner.translationVisiblePages, settings: settings)
        pipelineLookaheadCount = lookaheadPace.count(
            base: base, limit: nil, growth: grows ? Self.pipelineLookaheadMemoryGrowth(base: base) : 0)
        let targets = Self.pipelineLookaheadPages(
            upcoming: owner.translationUpcomingPages, visible: owner.translationVisiblePages,
            currentIndex: owner.translationCurrentPageIndex, settings: settings, count: pipelineLookaheadCount)
        let unit = ReaderTranslationSplitGeometry.unit
        func key(_ page: Page, _ crop: CGRect = unit) -> String {
            ReaderTranslationPipelineService.cacheKey(page: page.translationCacheKey, crop: crop, settings: settings)
        }
        retainPipelineLookahead(targets, owner: owner, settings: settings)
        for page in targets {
            let taskKey = key(page)
            guard pipelineLookahead[taskKey] == nil, !pipelineLookaheadFinished.contains(taskKey) else { continue }
            let splitsWidePages = owner.translationWidePageLayout(for: page) == .halves
            let direction = settings.readingDirection
            let loader = pipelineLoader
            pipelineLookahead[taskKey] = Task { [weak self] in
                defer { if let self, !Task.isCancelled { self.pipelineLookahead[taskKey] = nil } }
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    // Pages rendered before (reopened reader, resumed look-ahead) need no source decode.
                    let probe = splitsWidePages
                        ? Self.pipelineLookaheadCrops(imageSize: CGSize(width: 2, height: 1), splitsWidePages: true, direction: direction) : [unit]
                    var cached = true
                    for crop in probe where cached {
                        cached = await ReaderTranslationPipelineService.shared.cachedPage(cacheKey: key(page, crop)) != nil
                    }
                    try Task.checkCancellation()
                    let image: UIImage? = try await cached ? nil : loader.load(page)
                    try Task.checkCancellation()
                    let crops = image.map {
                        Self.pipelineLookaheadCrops(imageSize: $0.size, splitsWidePages: splitsWidePages, direction: direction)
                    } ?? probe
                    for crop in crops {
                        guard let image, let part = ReaderTranslationSplitGeometry.image(image, crop: crop) else { continue }
                        let pixels = await Task.detached(priority: .utility) {
                            ReaderTranslationImagePreparation.uprightSourceImage(part).cgImage
                        }.value
                        try Task.checkCancellation()
                        guard let pixels else { continue }
                        let output = try await ReaderTranslationPipelineService.shared.translatePage(
                            pixels, cacheKey: key(page, crop), settings: settings, priority: .prefetch)
                        try Task.checkCancellation()
                        for (stage, ms) in output.timings?.stages ?? [:] {
                            ReaderTranslationDiagnostics.record("stage_" + stage, page: page.index + 1, elapsedMilliseconds: ms)
                        }
                        self?.presentFinished(output.image, key: key(page, crop))
                    }
                    if let self, !Task.isCancelled {
                        if image != nil { lookaheadPace.pageTranslated(started: started, now: ProcessInfo.processInfo.systemUptime) }
                        if pipelineLookaheadFinished.count >= 256 { pipelineLookaheadFinished.removeAll() }
                        pipelineLookaheadFinished.insert(taskKey)
                    }
                    ReaderTranslationDiagnostics.record("pipeline_lookahead_finished", page: page.index + 1, count: crops.count)
                } catch {
                    // Offscreen failures never surface; the page retries when visible.
                }
            }
        }
    }

    /// The whole page, or both halves (reading order first) when the reader splits wide pages.
    private nonisolated static func pipelineLookaheadCrops(
        imageSize: CGSize, splitsWidePages: Bool, direction: PipelineReadingDirection
    ) -> [CGRect] {
        guard splitsWidePages, imageSize.height > 0, imageSize.width / imageSize.height > 1 else {
            return [ReaderTranslationSplitGeometry.unit]
        }
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        return direction == .rightToLeft ? [right, left] : [left, right]
    }

    /// The fixed count, and whether pace may raise it (only once visible pages no longer compete).
    private static func pipelineLookaheadBaseCount(
        visible: [ReaderTranslationPage], settings: ReaderTranslationSettings
    ) -> (count: Int, grows: Bool) {
        let visiblePresented = !visible.isEmpty && visible.allSatisfy(\.isPresentingPipeline)
        let backgroundOnly = settings.translatePages && !settings.showsTranslation
        let grows = backgroundOnly || visiblePresented
        return (PipelinePerformanceProfile.current.lookaheadCount(automatic: grows ? 2 : 1), grows)
    }

    /// Up to `base` extra pages, one per 64 MB above the decode headroom (each holds its decoded source).
    private static func pipelineLookaheadMemoryGrowth(base: Int) -> Int {
        let available = ProcessMemory.available()
        let required = TranslationImageWorkBudget.requiredHeadroom(decodedBytes: 0)
        return available > required ? min(base, Int((available - required) / (64 << 20))) : 0
    }

    private static func pipelineLookaheadPages(
        upcoming: [Page], visible: [ReaderTranslationPage], currentIndex: Int, settings: ReaderTranslationSettings, count: Int
    ) -> [Page] {
        guard settings.shouldProcessReaderPages else { return [] }
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        let backgroundOnly = settings.translatePages && !settings.showsTranslation
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

    /// Attach now instead of after the post-turn sync debounce.
    private func presentFinished(_ output: CGImage, key: String) {
        let settings = pageSettings()
        guard isVisible, settings.automaticallyTranslate, settings.overlay.visible else { return }
        ReaderTranslationPage.presentFinished(output, key: key, settings: settings)
    }

    /// Cancels look-ahead outside `targets`; visible pages join (and promote) any look-ahead already running for them.
    @available(iOS 18.0, *)
    private func retainPipelineLookahead(_ targets: [Page], owner: ReaderViewController, settings: ReaderTranslationSettings) {
        func key(_ page: Page) -> String {
            ReaderTranslationPipelineService.cacheKey(page: page.translationCacheKey, crop: ReaderTranslationSplitGeometry.unit, settings: settings)
        }
        let retained = Set(targets.map(key)).union(owner.translationVisiblePages.compactMap { $0.sourcePage.map(key) })
        for (stale, task) in pipelineLookahead where !retained.contains(stale) {
            task.cancel()
            pipelineLookahead[stale] = nil
        }
    }

    /// A turn cancels look-ahead behind the reader or beyond the window (plus one page) without waiting
    /// for the debounce, which rapid flips keep restarting.
    private func prunePipelineLookahead() {
        guard #available(iOS 18.0, *), !pipelineLookahead.isEmpty, let owner else { return }
        let settings = pageSettings()
        let keep = Self.pipelineLookaheadPages(
            upcoming: owner.translationUpcomingPages, visible: owner.translationVisiblePages,
            currentIndex: owner.translationCurrentPageIndex, settings: settings, count: pipelineLookaheadCount + 1)
        retainPipelineLookahead(keep, owner: owner, settings: settings)
    }

    private func cancelPipelineLookahead() {
        pipelineLookahead.values.forEach { $0.cancel() }
        pipelineLookahead.removeAll()
        pipelineLookaheadFinished.removeAll()
    }
}
