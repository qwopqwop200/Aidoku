import UIKit
import os

/// Activation is local. One cancellable consumer drains
/// the chapter; its preloader can overlap one following page's OCR and API work.
@MainActor
final class ReaderTranslationSession {
    typealias Processor = (Page, ReaderTranslationSettings, ReaderTranslationService.Progress?) async throws -> [ReaderTranslationRegion]
    typealias BoundProcessor = (Page, ReaderTranslationSettings, ReaderTranslationService.Progress?) async throws -> ReaderTranslationRegionArchive.Record
    typealias TranslationStore = @Sendable ([ReaderTranslationRegion], String, UInt64) async -> Void
    enum State: Equatable { case off, checking, on }
    struct Item {
        let key: String
        let page: Page
        let position: Int
        init(_ page: Page) { self.init(page, position: page.index) }
        init(_ page: Page, position: Int) { self.page = page; key = page.translationCacheKey; self.position = position }
    }
    nonisolated static func processAvailableMemory() -> UInt64 {
        let reported = UInt64(os_proc_available_memory())
        #if targetEnvironment(simulator)
        // Simulator reports zero when process headroom is unavailable. Explicit
        // test budgets and all physical-device values still use the normal gate.
        return reported == 0 ? UInt64.max : reported
        #else
        return reported
        #endif
    }

    static func chapterItems(_ pages: [Page]) -> [Item] {
        pages.enumerated().map { Item($0.element, position: $0.offset) }
    }
    private(set) var state: State = .off
    private(set) var presentsTranslation = true

    func setTranslationVisible(_ enabled: Bool) {
        guard presentsTranslation != enabled else { return }
        presentsTranslation = enabled
        if enabled {
            restoreVisibleDiskCache()
            displayPreparedPages()
        } else {
            cancelVisibleCacheRestore()
            discardPendingNavigation()
            knownPages.allObjects.forEach { $0.hidePreparedTranslation() }
        }
        onStateChanged?(state)
    }
    private let validate: ((ReaderTranslationSettings) async throws -> Void)?
    private let process: BoundProcessor
    private let usesBoundProcessor: Bool
    private let cancelProcessing: () -> Void
    private let cancelProcessingForPage: ((Page) -> Void)?
    private let cache: ReaderTranslationSessionCache
    private let diskCache: ReaderTranslationDiskCache?
    let renderCache: ReaderTranslationRenderCache?
    private let prepareLayout: ((Page, ReaderTranslationRegionArchive.Record, ReaderTranslationSettings) async throws -> Void)?
    private let prepareTextLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)?
    private var textWarmTask: Task<Void, Never>?
    private var textWarmGeneration = UUID()
    private var warmedTextWindow: [String] = []
    private var activeTextWindow: [String] = []
    static let textWindowCount = 33
    private let overlapsLayoutWithTranslation: Bool
    private var finished: Set<String> = []
    private let availableMemory: () -> UInt64
    private let reclaimMemory: () async -> Void
    private let waitForMemoryRetry: () async throws -> Void
    private let waitForAPIRetry: (UInt64) async throws -> Void
    private var attemptedMemoryReclaim = false
    private var memoryRetryTask: Task<Void, Never>?
    private var memoryNotBefore = Date.distantPast

    private var settings: ReaderTranslationSettings?
    // Settings values alone cannot capture a capability revision that changes in place.
    private var translationIdentity: String?
    private var imageSupportSnapshot: TranslationImageSupport.Snapshot?
    private var items: [Item] = []
    private var visible: [ReaderTranslationPage] = []
    private var previews: [ReaderTranslationPage] = []
    private let knownPages = NSHashTable<ReaderTranslationPage>.weakObjects()
    private var attempted: Set<String> = []
    private var demandedVisibleKeys: Set<String> = []
    private var recheckedVisibleSources: [String: ReaderTranslationSourceRasterClaim] = [:]
    private var retryCounts: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var didReportTranslationFailure = false
    private var context: String?
    private var activation = UUID()
    private var workGeneration = UUID()
    private var probeTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var navigationRetainedWorkKey: String?
    private var visibleCacheTask: Task<Void, Never>?
    private var visibleCacheKeys: Set<String> = []
    private var visibleCacheGeneration = UUID()
    private var activeKey: String?
    private var layoutQueue: [String: Item] = [:]
    private var layoutTask: Task<Void, Never>?
    private var activeLayoutKey: String?
    private var layoutGeneration = UUID()
    private var preparedLayouts: Set<String> = []
    /// Bounded with the existing raster preparation window, not the wider text cache.
    private var preparedEvidence: [String: ReaderTranslationPreparedEvidence] = [:]
    private var renderContext = ""
    private var touchedPages: Set<String> = []
    private var currentPosition: Int?
    private var navigationPaused = false
    private let storeTranslation: (@Sendable (ReaderTranslationRegionArchive.Record, String, UInt64) async -> Void)?
    /// Completed translations whose disk write has not finished, keyed by disk identity.
    /// Lookups consult this first, so a pending write can never cause duplicate OCR/API work.
    private var pendingDiskStores: [String: (id: UUID, record: ReaderTranslationRegionArchive.Record, task: Task<Void, Never>)] = [:]
    private var pendingDiskStoreOrder: [String] = []
    /// Compact text only; bounds the write queue when disk I/O is slower than translation.
    static let maximumPendingDiskStores = 4
    var onStateChanged: ((State) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(
        validate: ((ReaderTranslationSettings) async throws -> Void)? = nil,
        process: Processor? = nil,
        processRecord: BoundProcessor? = nil,
        cancelProcessing: @escaping () -> Void = {},
        cancelProcessingForPage: ((Page) -> Void)? = nil,
        diskCache: ReaderTranslationDiskCache? = nil,
        renderCache: ReaderTranslationRenderCache? = nil,
        prepareLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)? = nil,
        prepareRecordLayout: ((Page, ReaderTranslationRegionArchive.Record, ReaderTranslationSettings) async throws -> Void)? = nil,
        prepareTextLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)? = nil,
        overlapsLayoutWithTranslation: Bool = true,
        availableMemory: @escaping () -> UInt64 = { ReaderTranslationSession.processAvailableMemory() },
        reclaimMemory: @escaping () async -> Void = { await TranslationImageWorkBudget.reclaimIdleResources() },
        waitForMemoryRetry: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) },
        waitForAPIRetry: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        cache: ReaderTranslationSessionCache? = nil,
        storeTranslation: TranslationStore? = nil
    ) {
        self.validate = validate
        self.usesBoundProcessor = processRecord != nil
        self.process = processRecord ?? { page, settings, progress in
            guard let process else { throw CancellationError() }
            return .init(regions: try await process(page, settings, progress), sourceRasterClaim: nil)
        }
        self.cancelProcessing = cancelProcessing
        self.cancelProcessingForPage = cancelProcessingForPage
        self.diskCache = diskCache
        self.renderCache = renderCache
        self.prepareLayout = prepareRecordLayout ?? prepareLayout.map { legacy in
            { page, record, settings in try await legacy(page, record.regions, settings) }
        }
        self.prepareTextLayout = prepareTextLayout
        self.overlapsLayoutWithTranslation = overlapsLayoutWithTranslation
        self.availableMemory = availableMemory
        self.reclaimMemory = reclaimMemory
        self.waitForMemoryRetry = waitForMemoryRetry
        self.waitForAPIRetry = waitForAPIRetry
        self.cache = cache ?? ReaderTranslationSessionCache()
        if let storeTranslation {
            self.storeTranslation = { @Sendable record, key, generation in
                await storeTranslation(record.regions, key, generation)
            }
        } else {
            self.storeTranslation = diskCache.map { diskCache in
                { @Sendable record, key, generation in
                    try? await diskCache.storeRegions(record.regions, for: key, kind: .translation, generation: generation,
                                                      sourceRasterClaim: record.sourceRasterClaim)
                }
            }
        }
    }

    deinit {
        probeTask?.cancel(); worker?.cancel(); layoutTask?.cancel(); visibleCacheTask?.cancel(); memoryRetryTask?.cancel(); textWarmTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
    }

    /// Display-frequency fast path: mount only existing bitmaps. Cache misses
    /// must not start disk reads, native rendering, OCR, or change the scheduling window.
    func displayCachedVisiblePages(_ pages: [ReaderTranslationPage]) {
        guard state == .on, presentsTranslation, let settings, let renderCache else { return }
        for page in pages {
            guard let key = page.sourcePage?.translationCacheKey,
                  let record = cache.record(for: key), canPresent(record, on: page) else { continue }
            page.renderCache = renderCache
            knownPages.add(page)
            page.displayPreparedSnapshot(record.regions, settings: settings, memoryOnly: true)
        }
    }

    func refreshVisiblePages(_ pages: [ReaderTranslationPage], previews: [ReaderTranslationPage] = []) {
        // Keep only the incoming and outgoing sets during animation. A transient
        // empty callback must not erase the outgoing page or retain an entire swipe history.
        guard !pages.isEmpty else { return }
        self.previews = Array(previews.prefix(2))
        let retained = Set((visible + pages + self.previews).map(ObjectIdentifier.init))
        knownPages.allObjects.filter { !retained.contains(ObjectIdentifier($0)) }.forEach { $0.releaseOverlay() }
        if let pendingNavigationPage, !pages.contains(where: { $0 === pendingNavigationPage }) {
            discardPendingNavigation()
        }
        cancelLayoutForVisiblePages(pages)
        visible = pages
        let keys = Set(pages.compactMap { $0.sourcePage?.translationCacheKey })
        recheckedVisibleSources = recheckedVisibleSources.filter { keys.contains($0.key) }
        (pages + self.previews).forEach { $0.renderCache = renderCache; knownPages.add($0) }
        if state == .on {
            restoreVisibleDiskCache()
            displayPreparedPages()
        }
    }

    private func cancelVisibleCacheRestore() {
        visibleCacheGeneration = UUID()
        visibleCacheTask?.cancel()
        visibleCacheTask = nil
        visibleCacheKeys.removeAll()
    }

    // Cache-only demand bypasses the OCR navigation debounce. One cancellable
    // task reads compact region records; a miss never starts OCR or translation.
    private func restoreVisibleDiskCache() {
        guard state == .on, presentsTranslation, let settings, let diskCache else { return }
        let keys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        // Page identity only coalesces an active read. NSCache can evict data
        // without a memory-warning callback, including before the image arrives.
        guard visibleCacheTask == nil || keys != visibleCacheKeys else { return }
        cancelVisibleCacheRestore()
        visibleCacheKeys = keys
        let issued = visibleCacheGeneration
        let missing = keys.filter { !cache.contains($0) }.sorted()
        guard !missing.isEmpty else { return }
        visibleCacheTask = Task { [weak self] in
            for key in missing {
                guard !Task.isCancelled else { return }
                let record = await self?.storedTranslationRecord(page: key, settings: settings, diskCache: diskCache)
                guard !Task.isCancelled, let self, visibleCacheGeneration == issued,
                      state == .on, presentsTranslation, self.settings?.hasSameTranslation(as: settings) == true else { return }
                guard let record else {
                    displayPreparedPages()
                    continue
                }
                try? cache.store(record, for: key)
                // Deliver the loaded value directly: cache admission is best effort.
                for page in visible where page.sourcePage?.translationCacheKey == key && canPresent(record, on: page) {
                    page.displayPrepared(record.regions, settings: settings)
                }
                displayPreparedPages()
            }
            if let self, visibleCacheGeneration == issued { visibleCacheTask = nil }
        }
    }

    func update(items: [Item], visible: [ReaderTranslationPage], context: String, currentPageIndex: Int? = nil, renderContext: String? = nil, processUncachedPages: Bool = true) {
        navigationPaused = !processUncachedPages
        if self.context != context {
            stopWorker()
            cancelLayout(clearQueue: true)
            preparedEvidence.removeAll()
            attempted.removeAll()
            demandedVisibleKeys.removeAll()
            recheckedVisibleSources.removeAll()
            retryCounts.removeAll()
            finished.removeAll()
            preparedLayouts.removeAll()
            self.context = context
        }
        if let renderContext, self.renderContext != renderContext {
            cancelTextWarm()
            cancelLayout(clearQueue: true)
            preparedLayouts.removeAll()
            self.renderContext = renderContext
        }
        let visibleIDs = Set((visible + previews).map(ObjectIdentifier.init))
        knownPages.allObjects.filter { !visibleIDs.contains(ObjectIdentifier($0)) }.forEach { $0.releaseOverlay() }
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        let anchor = currentPageIndex ?? items.first(where: { visibleKeys.contains($0.key) })?.position ?? items.first?.position ?? 0
        let orderedItems = Self.ordered(items, anchor: anchor, visibleKeys: visibleKeys)
        if currentPosition != anchor {
            // A webtoon anchor can advance while the preceding page is still
            // on screen. Its OCR/API work remains foreground demand; replacing
            // it on every boundary crossing only repeats useful work.
            if activeKey.map({ visibleKeys.contains($0) }) != true {
                stopWorkerForNavigation(to: items.first { $0.position == anchor }?.page, in: items)
            }
            retainUsefulLayout(in: orderedItems)
        }
        // Visibility can arrive after the page-index callback (or change within a
        // spread). Track demand independently of refreshVisiblePages, which runs first.
        let freshKeys = currentPosition != anchor ? visibleKeys : visibleKeys.subtracting(demandedVisibleKeys)
        for key in freshKeys {
            attempted.remove(key)
            retryCounts.removeValue(forKey: key)
        }
        demandedVisibleKeys = visibleKeys
        if currentPosition != anchor || self.items.count != items.count {
            ReaderTranslationDiagnostics.record("queue", page: anchor + 1, count: items.count)
            currentPosition = anchor
        }
        self.items = orderedItems
        if let pendingNavigationPage, !visible.contains(where: { $0 === pendingNavigationPage }) {
            discardPendingNavigation()
        }
        cancelLayoutForVisiblePages(visible)
        self.visible = visible
        enforcePreparationLimit()
        visible.forEach { $0.renderCache = renderCache; knownPages.add($0) }
        if state == .on {
            restoreVisibleDiskCache()
            displayPreparedPages()
            // Page turns must not wait for an offscreen page's slowest API batch.
            if let activeKey, !visibleKeys.contains(activeKey),
               let next = nextItem(), visibleKeys.contains(next.key) {
                stopWorker(preservingRecognitionFor: next.page)
            }
            drain()
            enqueuePreparedLayouts()
            drainLayout()
        } else {
            // The image loader may finish before the session's startup debounce.
            // Its completed canvas is already valid and needs no provider probe.
            visible.forEach { $0.hidePreparedTranslation(preservingLoadedPresentation: presentsTranslation) }
        }
    }

    func refreshImageSupport() {
        guard state != .off, let settings, settings.includePageImage,
              translationIdentity != ReaderTranslationCacheIdentity.translation(page: "session", settings: settings) else { return }
        enable(settings: settings)
    }

    func enable(settings: ReaderTranslationSettings) {
        let identity = ReaderTranslationCacheIdentity.translation(page: "session", settings: settings)
        let capability = TranslationImageSupport.shared.snapshot(for: settings.configuration)
        let acceptsFallback = settings.includePageImage && capability.status == .unsupported &&
            imageSupportSnapshot.map { $0.status != .unsupported && capability.revision == $0.revision + 1 } == true
        let sameSettings = self.settings?.hasSameTranslation(as: settings) == true
        let invalidatedByCapability = sameSettings && translationIdentity != identity && !acceptsFallback
        let sameTranslation = sameSettings && !invalidatedByCapability
        translationIdentity = identity
        imageSupportSnapshot = capability
        if let previous = self.settings, sameTranslation, state != .off {
            if previous.overlay != settings.overlay { cancelTextWarm(); cancelLayout(clearQueue: true); preparedLayouts.removeAll() }
            if previous.maximumConcurrentRequests != settings.maximumConcurrentRequests { stopWorker() }
            if previous.maximumPretranslatedPages != settings.maximumPretranslatedPages {
                stopWorker()
                cancelLayout(clearQueue: true)
                cancelTextWarm()
            }
            self.settings = settings
            setTranslationVisible(settings.automaticallyTranslate)
            if state == .on { displayPreparedPages(); drain(); enqueuePreparedLayouts(); drainLayout() }
            return
        }
        disable(preservingVisibleRendering: sameTranslation,
                preservingCachedPresentationFor: invalidatedByCapability ? nil : settings)
        if self.settings?.overlay != settings.overlay { preparedLayouts.removeAll() }
        if invalidatedByCapability || (self.settings != nil && !sameSettings) {
            cache.clear(); finished.removeAll(); preparedLayouts.removeAll(); preparedEvidence.removeAll()
        }
        self.settings = settings
        setTranslationVisible(settings.automaticallyTranslate)
        attempted.removeAll()
        retryCounts.removeAll()
        didReportTranslationFailure = false
        guard let validate else {
            state = .on
            ReaderTranslationDiagnostics.record("enabled", page: (currentPosition ?? -1) + 1, count: items.count)
            onStateChanged?(state)
            displayPreparedPages()
            drain()
            enqueuePreparedLayouts()
            drainLayout()
            return
        }
        state = .checking
        onStateChanged?(state)
        let issued = activation
        probeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await validate(settings)
                try Task.checkCancellation()
                guard activation == issued else { return }
                probeTask = nil
                state = .on
                ReaderTranslationDiagnostics.record("enabled", page: (currentPosition ?? -1) + 1, count: items.count)
                onStateChanged?(state)
                displayPreparedPages()
                drain()
                enqueuePreparedLayouts()
                drainLayout()
            } catch {
                guard activation == issued else { return }
                disable(preservingCachedPresentationFor: settings)
                if !(error is CancellationError) { onFailure?(error) }
            }
        }
    }

    /// A user retry preserves completed translations while failed pages keep their source image.
    func retryVisibleFailures() {
        guard let settings else { return }
        if state == .off { enable(settings: settings); return }
        guard state == .on else { return }
        for page in visible where !page.hasCompletedTranslation(settings: settings) {
            guard let key = page.sourcePage?.translationCacheKey, key != activeKey else { continue }
            retryTasks.removeValue(forKey: key)?.cancel()
            retryCounts.removeValue(forKey: key)
            attempted.remove(key)
        }
        didReportTranslationFailure = false
        drain()
    }

    func disable(reason: String = "off", preservingVisibleRendering: Bool = false,
                 preservingCachedPresentationFor settings: ReaderTranslationSettings? = nil) {
        if state != .off { ReaderTranslationDiagnostics.record(reason, page: (currentPosition ?? -1) + 1) }
        activation = UUID()
        cancelVisibleCacheRestore()
        probeTask?.cancel()
        probeTask = nil
        stopWorker()
        cancelLayout(clearQueue: true)
        renderCache?.clearMemory()
        preparedEvidence.removeAll()
        let visibleIDs = Set(visible.map(ObjectIdentifier.init))
        knownPages.allObjects.forEach {
            if let settings, settings.automaticallyTranslate,
               $0.hasLoadedCachedPresentation, $0.hasCompletedTranslation(settings: settings) { return }
            if preservingVisibleRendering, visibleIDs.contains(ObjectIdentifier($0)) { $0.hidePreparedTranslation() }
            else { $0.showOriginal() }
        }
        state = .off
        onStateChanged?(state)
    }

    /// Cancel obsolete work while navigation settles, retaining the destination's
    /// lookahead. A nil destination (slider scrubbing) discards all pending work.
    func pauseForPageTurn(preservingRecognitionFor page: Page? = nil,
                          visiblePages: [ReaderTranslationPage] = []) {
        navigationPaused = true
        cancelVisibleCacheRestore()
        let activePage = items.first { $0.key == activeKey }?.page
        let keepsVisibleWork = page.map { destination in
            activePage.map { active in
                active.sourceId == destination.sourceId && active.chapterId == destination.chapterId
                    && visiblePages.contains { $0.sourcePage?.translationCacheKey == active.translationCacheKey }
            } == true
        } == true
        if !keepsVisibleWork { stopWorkerForNavigation(to: page, in: items) }
        if activeLayoutKey != nil, let key = page?.translationCacheKey, let destination = items.first(where: { $0.key == key }) {
            retainUsefulLayout(in: Self.ordered(items, anchor: destination.position))
        } else {
            cancelLayout(clearQueue: true)
        }
    }

    /// A warning can be emitted for the model's temporary allocation even with
    /// ample process headroom. Reloading that model on every warning livelocks
    /// the same page. Trim expendable work first; reserve cancellation for a
    /// critically low budget. New OCR still uses the larger admission threshold.
    @discardableResult
    func handleMemoryWarning() -> Bool {
        discardPendingNavigation()
        guard availableMemory() >= 512 * 1_024 * 1_024 else {
            suspendWorkForResourcePressure()
            return true
        }
        ReaderTranslationDiagnostics.record("memory_warning_trim", page: (currentPosition ?? -1) + 1)
        memoryNotBefore = Date().addingTimeInterval(3)
        cancelTextWarm()
        cancelLayout(clearQueue: true)
        cache.clear()
        preparedEvidence.removeAll()
        cancelVisibleCacheRestore()
        renderCache?.clearMemory()
        preparedLayouts.removeAll()
        let visibleIDs = Set(visible.map(ObjectIdentifier.init))
        knownPages.allObjects.filter { !visibleIDs.contains(ObjectIdentifier($0)) }.forEach { $0.releaseOverlay() }
        restoreVisibleDiskCache()
        displayPreparedPages()
        scheduleMemoryRetry()
        return false
    }

    /// Release expensive work without changing the user's ON/OFF choice.
    func suspendWorkForResourcePressure() {
        ReaderTranslationDiagnostics.record("memory_warning", page: (currentPosition ?? -1) + 1)
        memoryNotBefore = Date().addingTimeInterval(3)
        cancelVisibleCacheRestore()
        stopWorker()
        cancelLayout(clearQueue: true)
        cache.clear()
        preparedEvidence.removeAll()
        attempted.removeAll()
        finished.removeAll()
        preparedLayouts.removeAll()
        renderCache?.clearMemory()
        let visibleIDs = Set(visible.map(ObjectIdentifier.init))
        knownPages.allObjects.filter {
            !visibleIDs.contains(ObjectIdentifier($0)) || (state != .on && !$0.hasLoadedCachedPresentation)
        }.forEach { $0.releaseOverlay() }
    }

    func close() {
        disable(reason: "reader_closed")
        items = []
        visible = []
        previews = []
        knownPages.removeAllObjects()
        cache.clear()
        preparedEvidence.removeAll()
        finished.removeAll()
        preparedLayouts.removeAll()
    }

    /// Crossing completed pages should not restart the same upcoming work.
    /// Reuse the preloader's existing destination slot; retain only its identity
    /// here so the pause and subsequent anchor update make the same decision.
    private func stopWorkerForNavigation(to destination: Page?, in candidates: [Item]) {
        let workKey = activeKey ?? navigationRetainedWorkKey
        var retained: Page?
        if state == .on, canStartHeavyWork, let destination,
           cache.contains(destination.translationCacheKey),
           let anchor = candidates.first(where: { $0.key == destination.translationCacheKey }),
           let work = candidates.first(where: { $0.key == workKey }),
           abs(work.position - anchor.position) < preparationWindowCount,
           work.page.sourceId == destination.sourceId, work.page.chapterId == destination.chapterId {
            let next = Self.ordered(candidates, anchor: anchor.position).first {
                !finished.contains($0.key) && !attempted.contains($0.key) && !cache.contains($0.key)
            }
            if next?.key == work.key { retained = work.page }
        }
        stopWorker(preservingRecognitionFor: retained ?? destination)
        navigationRetainedWorkKey = retained?.translationCacheKey
    }

    private func stopWorker(preservingRecognitionFor page: Page? = nil) {
        navigationRetainedWorkKey = nil
        discardPendingNavigation()
        cancelTextWarm()
        memoryRetryTask?.cancel()
        memoryRetryTask = nil
        attemptedMemoryReclaim = false
        for (key, task) in retryTasks {
            task.cancel()
            attempted.remove(key)
        }
        retryTasks.removeAll()
        if let activeKey {
            ReaderTranslationDiagnostics.record("worker_cancelled", page: (items.first { $0.key == activeKey }?.position ?? -1) + 1)
        }
        workGeneration = UUID()
        discardProvisionalTranslations()
        // Transfer destination ownership before parent cancellation can reach it.
        if let page, let cancelProcessingForPage { cancelProcessingForPage(page) } else { cancelProcessing() }
        worker?.cancel()
        worker = nil
        activeKey = nil
    }

    private func retainUsefulLayout(in orderedItems: [Item]) {
        let keys = Set(orderedItems.prefix(preparationWindowCount).map(\.key))
        guard let activeLayoutKey, keys.contains(activeLayoutKey) else {
            cancelLayout(clearQueue: true)
            return
        }
        layoutQueue = layoutQueue.filter { keys.contains($0.key) }
    }

    func sourceImageDidLoad(_ page: Page) {
        guard state == .on else { return }
        let key = page.translationCacheKey
        // Translation can finish before the reader assigns its decoded image.
        // That publication has no image to attach to; source readiness must
        // retry presentation without waiting for another navigation callback.
        if visible.contains(where: { $0.sourcePage?.translationCacheKey == key }) {
            ReaderTranslationDiagnostics.record("visible_source_ready", page: page.index + 1)
            restoreVisibleDiskCache()
            displayPreparedPages()
        }
        guard preparationItems.prefix(preparationWindowCount).contains(where: { $0.key == key }) else { return }
        enqueuePreparedLayouts()
        drainLayout()
    }

    /// The visible page now owns final presentation. Do not leave a second
    /// offscreen export of the same page competing for its image/render permit.
    /// Completed snapshots remain in the render cache and are reused normally.
    private func cancelLayoutForVisiblePages(_ pages: [ReaderTranslationPage]) {
        guard let activeLayoutKey,
              pages.contains(where: { $0.sourcePage?.translationCacheKey == activeLayoutKey }) else { return }
        cancelLayout(clearQueue: false)
    }

    private func cancelLayout(clearQueue: Bool) {
        layoutGeneration = UUID()
        layoutTask?.cancel()
        layoutTask = nil
        activeLayoutKey = nil
        if clearQueue { layoutQueue.removeAll() }
    }

    private func scheduleMemoryRetry() {
        guard state == .on, memoryRetryTask == nil else { return }
        memoryRetryTask = Task { [weak self] in
            guard let self else { return }
            if worker == nil, availableMemory() < TranslationImageWorkBudget.minimumHeadroom,
               !attemptedMemoryReclaim {
                attemptedMemoryReclaim = true
                cancelLayout(clearQueue: true)
                cancelProcessing()
                let visibleIDs = Set(visible.map(ObjectIdentifier.init))
                knownPages.allObjects.filter { !visibleIDs.contains(ObjectIdentifier($0)) }.forEach { $0.releaseOverlay() }
                renderCache?.clearMemory()
                preparedLayouts.removeAll()
                await reclaimMemory()
            }
            do { try await waitForMemoryRetry() } catch { return }
            guard !Task.isCancelled, state == .on else { return }
            memoryRetryTask = nil
            drain()
            drainLayout()
        }
    }

    private var canStartHeavyWork: Bool {
        Date() >= memoryNotBefore && availableMemory() >= TranslationImageWorkBudget.minimumHeadroom
    }

    private func cancelTextWarm() {
        textWarmGeneration = UUID()
        textWarmTask?.cancel(); textWarmTask = nil
        warmedTextWindow = []
        activeTextWindow = []
    }

    /// Compact cache reads never call the image loader, OCR or provider. Scan a
    /// much wider window than raster preparation, one record at a time.
    private func warmTextCache() {
        guard state == .on, let settings, let diskCache, textWarmTask == nil,
              Date() >= memoryNotBefore, availableMemory() >= 128 * 1_024 * 1_024 else { return }
        let window = Array(preparationItems.prefix(Self.textWindowCount))
        let keys = window.map(\.key)
        guard warmedTextWindow != keys else { return }
        cache.retainPages(Set(keys))
        let issued = textWarmGeneration
        activeTextWindow = keys
        textWarmTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if textWarmGeneration == issued { textWarmTask = nil; activeTextWindow = [] }
            }
            for item in window {
                guard !Task.isCancelled, textWarmGeneration == issued, availableMemory() >= 128 * 1_024 * 1_024 else { return }
                if !cache.contains(item.key), let record = await storedTranslationRecord(page: item.key, settings: settings, diskCache: diskCache) {
                    guard !Task.isCancelled, textWarmGeneration == issued else { return }
                    try? cache.store(record, for: item.key, evict: false)
                    if preparationItems.prefix(preparationWindowCount).contains(where: { $0.key == item.key }) {
                        enqueuePreparedLayouts()
                        drainLayout()
                    }
                    if (visible + previews).contains(where: { $0.sourcePage?.translationCacheKey == item.key }) { displayPreparedPages() }
                }
                await Task.yield()
            }
            // Only a completed scan can suppress the next warm-up. Memory
            // pressure may stop this task midway without changing navigation;
            // once headroom recovers, resume the same window's missing records.
            guard !Task.isCancelled, textWarmGeneration == issued else { return }
            warmedTextWindow = keys
            enqueuePreparedLayouts()
            drainLayout()
            guard let prepareTextLayout, let renderCache else { return }
            for item in window {
                guard !Task.isCancelled, textWarmGeneration == issued, availableMemory() >= 256 * 1_024 * 1_024 else { return }
                // Missing text has no layout. Avoid building its translation identity on MainActor.
                guard cache.contains(item.key) else { continue }
                let identity = ReaderTranslationCacheIdentity.translation(page: item.key, settings: settings)
                // Nearby full snapshots already prepare their own layouts.
                guard !renderCache.shouldKeepImage(for: identity),
                      let regions = cache.regions(for: item.key) else { continue }
                try? await prepareTextLayout(item.page, regions, settings)
                await Task.yield()
            }
        }
    }

    private var preparationWindowCount: Int { renderCache?.nearbyPageCount ?? 5 }

    private func drainLayout() {
        guard state == .on, (overlapsLayoutWithTranslation || worker == nil), layoutTask == nil, let prepareLayout, let settings, !layoutQueue.isEmpty else { return }
        guard canStartHeavyWork else { scheduleMemoryRetry(); return }
        let issued = layoutGeneration
        layoutTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while state == .on, layoutGeneration == issued, !Task.isCancelled,
                  let item = preparationItems.prefix(preparationWindowCount).first(where: { layoutQueue[$0.key] != nil }) {
                guard canStartHeavyWork, overlapsLayoutWithTranslation || worker == nil else {
                    layoutTask = nil
                    scheduleMemoryRetry()
                    return
                }
                let isVisible = visible.contains { $0.sourcePage?.translationCacheKey == item.key }
                if !isVisible {
                    var record = cache.record(for: item.key)
                    if record == nil, let diskCache {
                        record = await storedTranslationRecord(page: item.key, settings: settings, diskCache: diskCache)
                    }
                    guard layoutGeneration == issued, !Task.isCancelled else { return }
                    // A lookahead can publish to RAM while the disk lookup is
                    // suspended, before its independent persistence finishes.
                    // Recheck before removing the queue entry it just renewed.
                    if record == nil { record = cache.record(for: item.key) }
                    if let record, !usesBoundProcessor || record.sourceRasterClaim != nil {
                        do {
                            let evidence = preparedEvidence[item.key]
                            defer { withExtendedLifetime(evidence) {} }
                            activeLayoutKey = item.key
                            ReaderTranslationDiagnostics.record("render_start", page: item.position + 1, count: record.regions.count)
                            let diagnostic = ReaderTranslationDiagnostics.makeContext(pageKey: item.key, page: item.position + 1)
                            try await ReaderTranslationDiagnostics.measure("page_render", context: diagnostic) {
                                try await prepareLayout(item.page, record, settings)
                            }
                            guard layoutGeneration == issued, !Task.isCancelled else { return }
                            preparedLayouts.insert(item.key)
                            displayPreparedPages()
                            ReaderTranslationDiagnostics.record("render_finished", page: item.position + 1)
                        } catch is CancellationError {
                            ReaderTranslationDiagnostics.record("render_cancelled", page: item.position + 1)
                        } catch {
                            ReaderTranslationDiagnostics.record("render_failed", page: item.position + 1, code: (error as NSError).code)
                        }
                    }
                }
                guard layoutGeneration == issued, !Task.isCancelled else { return }
                activeLayoutKey = nil
                layoutQueue.removeValue(forKey: item.key)
            }
            if layoutGeneration == issued { layoutTask = nil }
        }
    }

    private func enqueuePreparedLayouts() {
        guard prepareLayout != nil, let settings else { return }
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        // Probe compact disk records independently of the translation worker.
        // A cached next page must not wait behind the visible page's API request.
        for item in preparationItems.prefix(preparationWindowCount) where !visibleKeys.contains(item.key) {
            let identity = ReaderTranslationCacheIdentity.translation(page: item.key, settings: settings)
            if !preparedLayouts.contains(item.key) || renderCache?.needsImage(for: identity) == true {
                layoutQueue[item.key] = item
            }
        }
    }

    func receivePreparedEvidence(_ evidence: ReaderTranslationPreparedEvidence, page: Page, settings: ReaderTranslationSettings,
                                 sourceRasterClaim: ReaderTranslationSourceRasterClaim? = nil) {
        guard !Task.isCancelled, state == .on, self.settings?.hasSameTranslation(as: settings) == true else { return }
        let key = page.translationCacheKey
        guard acceptsCommittedSource(sourceRasterClaim, pageKey: key),
              preparationItems.prefix(preparationWindowCount).contains(where: { $0.key == key }) else { return }
        preparedEvidence[key] = evidence
    }

    func receivePrepared(_ page: Page, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) {
        receivePrepared(page, record: .init(regions: regions, sourceRasterClaim: nil), settings: settings)
    }

    func receivePrepared(_ page: Page, record: ReaderTranslationRegionArchive.Record, settings: ReaderTranslationSettings) {
        guard !Task.isCancelled, state == .on, self.settings?.hasSameTranslation(as: settings) == true else { return }
        let key = page.translationCacheKey
        guard acceptsCommittedSource(record.sourceRasterClaim, pageKey: key),
              preparationItems.contains(where: { $0.key == key }) else { return }
        if displayUnresolvedRecovery(record, key: key, settings: settings) { return }
        if shouldKeepTextInMemory(key) {
            try? cache.store(record, for: key)
        }
        finished.insert(key)
        displayPreparedPages()
        enqueuePreparedLayouts()
        drainLayout()
    }

    /// Keep partial text visible without promoting it to a completed page/cache.
    private func displayUnresolvedRecovery(_ record: ReaderTranslationRegionArchive.Record, key: String,
                                           settings: ReaderTranslationSettings) -> Bool {
        let regions = record.regions
        let unresolved = regions.filter { $0.translationRecoveryFailure != nil }
        guard !unresolved.isEmpty else { return false }
        // The explicit-failure store gate also removes any prior completed entry.
        try? cache.store(regions, for: key)
        finished.remove(key)
        attempted.insert(key) // Bound this attempt; a later demand may retry.
        discardPendingNavigation()
        ReaderTranslationDiagnostics.record("translation_partial_recovery", count: unresolved.count)
        for page in visible where page.sourcePage?.translationCacheKey == key && canPresent(record, on: page) {
            if page.hasCompletedTranslation(settings: settings) { page.reset() }
            page.displayProvisional(regions, settings: settings, evidence: preparedEvidence[key])
            provisionalPage = page
        }
        return true
    }

    private func canPresent(_ record: ReaderTranslationRegionArchive.Record, on page: ReaderTranslationPage) -> Bool {
        guard usesBoundProcessor else { return true }
        guard let expected = record.sourceRasterClaim, let source = page.sourcePage, let image = page.imageView?.image else { return false }
        return source.memoizedTranslationSource(for: image) == expected
    }

    private func acceptsCommittedSource(_ claim: ReaderTranslationSourceRasterClaim?, pageKey: String) -> Bool {
        guard usesBoundProcessor else { return true }
        guard let claim else { return false }
        for page in visible {
            guard let source = page.sourcePage, source.translationCacheKey == pageKey,
                  let image = page.imageView?.image, let actual = source.memoizedTranslationSource(for: image) else { continue }
            if actual != claim { return false }
        }
        return true
    }

    private func admissibleForDisplay(_ record: ReaderTranslationRegionArchive.Record, on page: ReaderTranslationPage) -> Bool {
        if canPresent(record, on: page) { return true }
        if usesBoundProcessor, record.sourceRasterClaim != nil,
           let source = page.sourcePage, let image = page.imageView?.image {
            if let actual = source.memoizedTranslationSource(for: image) {
                let key = source.translationCacheKey
                if visible.contains(where: { $0 === page }), finished.contains(key),
                   recheckedVisibleSources[key] != actual {
                    recheckedVisibleSources[key] = actual
                    finished.remove(key)
                    attempted.remove(key)
                    preparedLayouts.remove(key)
                    preparedEvidence.removeValue(forKey: key)
                    drain()
                }
            } else {
                page.observeCurrentSource { [weak self] in self?.displayPreparedPages() }
            }
        }
        return false
    }

    private func displayPreparedPages() {
        guard state == .on, let settings else { return }
        guard presentsTranslation else {
            knownPages.allObjects.forEach { $0.hidePreparedTranslation() }
            return
        }
        let visibleKeys = visible.compactMap { $0.sourcePage?.translationCacheKey }
        let nearbyKeys = visibleKeys + items.map(\.key).filter { !visibleKeys.contains($0) }
        renderCache?.setNearbyPages(pageKeys: nearbyKeys, settings: settings, availableMemory: availableMemory())
        let identities = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        if identities != touchedPages, let diskCache {
            touchedPages = identities
            Task(priority: .utility) {
                for page in identities {
                    try? await diskCache.markUsed(ReaderTranslationCacheIdentity.ocr(page: page, settings: settings), kind: .ocr)
                    try? await diskCache.markUsed(ReaderTranslationCacheIdentity.translation(page: page, settings: settings), kind: .translation)
                }
            }
        }
        for page in visible {
            if let key = page.sourcePage?.translationCacheKey, let record = cache.record(for: key) {
                // A fresh result under unchanged settings can replace completed
                // text. Let the page compare content before reusing its canvas.
                if admissibleForDisplay(record, on: page) {
                    page.displayPrepared(record.regions, settings: settings, evidence: preparedEvidence[key])
                }
            } else if page.hasCompletedTranslation(settings: settings) {
                page.showCompletedTranslation(settings: settings)
            }
        }
        // The bitmap is mounted before UIKit exposes a neighboring page. These
        // views never start their own rendering/OCR/API work, and cancelled swipes
        // leave the already composed preview attached.
        if Date() >= memoryNotBefore {
            let visibleIDs = Set(visible.map(ObjectIdentifier.init))
            for page in previews where !visibleIDs.contains(ObjectIdentifier(page)) {
                guard let key = page.sourcePage?.translationCacheKey, let record = cache.record(for: key),
                      admissibleForDisplay(record, on: page) else { continue }
                page.displayPreparedSnapshot(record.regions, settings: settings)
            }
        }
    }

    private func handleProgress(key: String, generation: UUID, regions: [ReaderTranslationRegion] = []) throws {
        try Task.checkCancellation()
        guard state == .on, workGeneration == generation, activeKey == key else { throw CancellationError() }
        // The initial callback runs after OCR admission is released and before
        // provider work. Reserve at most one future native presentation view.
        if presentsTranslation, !regions.isEmpty, !navigationPaused, canStartHeavyWork, let settings,
           let page = visible.first(where: { $0.sourcePage?.translationCacheKey == key }) {
            if pendingNavigationPage !== page { discardPendingNavigation() }
            if page.preparePendingOverlayNavigation(settings: settings) { pendingNavigationPage = page }
        }
        // Progress validates the active request but must not replace the source.
        // Only the completed translation and its final render may become visible.
        // OCR has released image admission before this callback.
        drainLayout()
    }

    private func discardPendingNavigation() {
        pendingNavigationPage?.discardPendingOverlayNavigation()
        pendingNavigationPage = nil
    }

    private weak var pendingNavigationPage: ReaderTranslationPage?
    private weak var provisionalPage: ReaderTranslationPage?

    /// Provisional text belongs to the running translation of that page; a
    /// cancelled or failed run must not leave it on screen.
    private func discardProvisionalTranslations() {
        provisionalPage?.discardProvisionalTranslation()
        provisionalPage = nil
    }

    // Sweep the entire chapter with one consumer. Only nearby compact text stays
    // resident; distant completed pages live in the disk cache, not decoded images.
    private func shouldKeepTextInMemory(_ key: String) -> Bool {
        visible.contains { $0.sourcePage?.translationCacheKey == key }
            || preparationItems.prefix(Self.textWindowCount).contains { $0.key == key }
    }

    private func hasReusableMemory(_ key: String) -> Bool {
        // Warming decodes archives, but only a producer has inspected the
        // actual source. A warm row must not preempt that verification.
        cache.contains(key) && (!usesBoundProcessor || finished.contains(key))
    }

    private func nextItem() -> Item? {
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        let isPending: (Item) -> Bool = { !self.attempted.contains($0.key) && !self.hasReusableMemory($0.key) }
        let displayedKeys = Set(visible.filter { page in settings.map { page.hasCompletedTranslation(settings: $0) } == true }
            .compactMap { $0.sourcePage?.translationCacheKey })
        return preparationItems.first { visibleKeys.contains($0.key) && !displayedKeys.contains($0.key) && isPending($0) }
            ?? preparationItems.first { !finished.contains($0.key) && isPending($0) }
    }

    /// Selects bounded lookahead work while current API requests run. Exclusions
    /// preserve the live reader priority order across multiple preparation slots.
    func nextPageForRecognition(after page: Page, excluding: Set<String> = []) -> Page? {
        guard state == .on, !navigationPaused, canStartHeavyWork else { return nil }
        let key = page.translationCacheKey
        return preparationItems.first {
            $0.key != key && !excluding.contains($0.key)
                && !finished.contains($0.key) && !attempted.contains($0.key) && !hasReusableMemory($0.key)
        }?.page
    }

    // A moving window, not a lifetime quota. Visible spreads/webtoon pages are
    // always demand; finite limits take the first N offscreen pages in the same
    // forward-biased priority order, including the nearby backward safety net.
    private var preparationItems: [Item] {
        guard let limit = settings?.maximumPretranslatedPages else { return items }
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        let anchor = currentPosition ?? items.first?.position ?? 0
        var remaining = max(0, limit)
        return items.filter {
            if visibleKeys.contains($0.key) || (visibleKeys.isEmpty && $0.position == anchor) { return true }
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    private func enforcePreparationLimit() {
        let evidenceKeys = Set(preparationItems.prefix(preparationWindowCount).map(\.key))
        preparedEvidence = preparedEvidence.filter { evidenceKeys.contains($0.key) }
        guard settings?.maximumPretranslatedPages != nil else { return }
        let allowed = Set(preparationItems.map(\.key))
        if let activeKey, !allowed.contains(activeKey) { stopWorker() }
        if let navigationRetainedWorkKey, !allowed.contains(navigationRetainedWorkKey) { stopWorker() }
        if let activeLayoutKey, !allowed.contains(activeLayoutKey) { cancelLayout(clearQueue: true) }
        layoutQueue = layoutQueue.filter { allowed.contains($0.key) }
        // Repeated visibility updates must not restart the same disk/layout scan.
        // Cancel only when its ordered window changes, including a changed limit.
        let textWindow = preparationItems.prefix(Self.textWindowCount).map(\.key)
        let existingWindow = textWarmTask == nil ? warmedTextWindow : activeTextWindow
        if textWindow != existingWindow { cancelTextWarm() }
    }

    static let nearbyTranslationRadius = 3

    static func ordered(_ items: [Item], anchor: Int, visibleKeys: Set<String> = []) -> [Item] {
        func priority(_ item: Item) -> (phase: Int, offset: Int) {
            let offset = item.position - anchor
            let radius = nearbyTranslationRadius
            // First secure +1...+3, then alternate -1,+4,-2,+5,-3.
            // All remaining forward pages precede the distant backward tail.
            if (0...radius).contains(offset) { return (0, offset) }
            if (-radius..<0).contains(offset) { return (1, (-offset - 1) * 2) }
            if offset > radius, offset < radius * 2 { return (1, (offset - radius) * 2 - 1) }
            return offset > 0 ? (2, offset) : (3, -offset)
        }
        return items.sorted { left, right in
            if visibleKeys.contains(left.key) != visibleKeys.contains(right.key) { return visibleKeys.contains(left.key) }
            let leftPriority = priority(left), rightPriority = priority(right)
            if leftPriority.phase != rightPriority.phase { return leftPriority.phase < rightPriority.phase }
            return leftPriority.offset < rightPriority.offset
        }
    }

    @discardableResult
    private func scheduleTransientRetry(_ error: Error, key: String) -> Bool {
        var cause = (error as? ReaderTranslationOCRFallback)?.underlying ?? error
        if let remote = cause as? RemoteTranslationError, case .transport(let code) = remote {
            cause = URLError(code)
        }
        if let remote = cause as? RemoteTranslationError, remote == .privateTailnetUnavailable {
            cause = URLError(.cannotConnectToHost)
        }
        let transient: Bool
        if cause is CancellationError {
            transient = true
        } else if let url = cause as? URLError {
            transient = [.cancelled, .timedOut, .networkConnectionLost, .notConnectedToInternet,
                         .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(url.code)
        } else if let remote = cause as? RemoteTranslationError {
            switch remote {
            case .httpStatus(let status, _): transient = [408, 409, 425, 429].contains(status) || (500...599).contains(status)
            case .invalidResponse: transient = true
            default: transient = false
            }
        } else {
            transient = cause is DecodingError
        }
        guard transient, visible.contains(where: { $0.sourcePage?.translationCacheKey == key }),
              retryTasks[key] == nil, retryCounts[key, default: 0] < 2 else { return false }
        retryCounts[key, default: 0] += 1
        let delay = retryCounts[key] == 1 ? 1 : 3
        ReaderTranslationDiagnostics.record("api_retry_scheduled", page: (items.first { $0.key == key }?.position ?? -1) + 1,
                                            count: retryCounts[key, default: 0])
        let issued = workGeneration
        let waitForAPIRetry = waitForAPIRetry
        retryTasks[key] = Task { [weak self] in
            do { try await waitForAPIRetry(UInt64(delay) * 1_000_000_000) } catch { return }
            guard let self, state == .on, workGeneration == issued, !Task.isCancelled else { return }
            retryTasks.removeValue(forKey: key)
            attempted.remove(key)
            // Current-page recovery should not wait behind an offscreen API batch.
            if let activeKey, activeKey != key { stopWorker() }
            drain()
        }
        return true
    }

    private func pendingTranslation(page key: String, settings: ReaderTranslationSettings) -> ReaderTranslationRegionArchive.Record? {
        guard !pendingDiskStores.isEmpty else { return nil }
        return pendingDiskStores[ReaderTranslationCacheIdentity.translation(page: key, settings: settings)]?.record
    }

    private func storedTranslation(page key: String, settings: ReaderTranslationSettings,
                                   diskCache: ReaderTranslationDiskCache) async -> [ReaderTranslationRegion]? {
        await storedTranslationRecord(page: key, settings: settings, diskCache: diskCache)?.regions
    }

    private func storedTranslationRecord(page key: String, settings: ReaderTranslationSettings,
                                         diskCache: ReaderTranslationDiskCache) async -> ReaderTranslationRegionArchive.Record? {
        if let pending = pendingTranslation(page: key, settings: settings) { return pending }
        return try? await diskCache.translatedRegionRecord(page: key, settings: settings, persistDerived: !usesBoundProcessor)
    }

    /// Starts a write that outlives worker cancellation. At most
    /// `maximumPendingDiskStores` writes are in flight; beyond that the worker
    /// waits for the oldest, so a slow disk cannot grow an unbounded queue.
    func persistPreparedRecord(_ record: ReaderTranslationRegionArchive.Record, page: Page,
                               destination: ReaderTranslationDiskCache.TranslationWriteDestination) async {
        await persistTranslation(record, pageKey: page.translationCacheKey, diskKey: destination.key, generation: destination.generation)
    }

    private func persistTranslation(_ record: ReaderTranslationRegionArchive.Record, pageKey: String,
                                    diskKey: String, generation: UInt64) async {
        let regions = record.regions
        guard !regions.contains(where: { $0.translationRecoveryFailure != nil }) else { return }
        guard let storeTranslation, acceptsCommittedSource(record.sourceRasterClaim, pageKey: pageKey) else { return }
        while let predecessor = pendingDiskStores[diskKey] != nil ? diskKey :
            (pendingDiskStores.count >= Self.maximumPendingDiskStores ? pendingDiskStoreOrder.first : nil),
              let entry = pendingDiskStores[predecessor] {
            await entry.task.value
            finishDiskStore(predecessor, id: entry.id)
        }
        guard acceptsCommittedSource(record.sourceRasterClaim, pageKey: pageKey) else { return }
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            await storeTranslation(record, diskKey, generation)
            self?.finishDiskStore(diskKey, id: id)
        }
        pendingDiskStoreOrder.removeAll { $0 == diskKey }
        pendingDiskStoreOrder.append(diskKey)
        pendingDiskStores[diskKey] = (id, record, task)
    }

    private func finishDiskStore(_ diskKey: String, id: UUID) {
        guard pendingDiskStores[diskKey]?.id == id else { return }
        pendingDiskStores.removeValue(forKey: diskKey)
        pendingDiskStoreOrder.removeAll { $0 == diskKey }
    }

    var pendingDiskStoreCount: Int { pendingDiskStores.count }

    /// Waits until every started translation write has finished.
    func flushPendingDiskStores() async {
        while let (key, entry) = pendingDiskStores.first {
            await entry.task.value
            finishDiskStore(key, id: entry.id)
        }
    }

    private func drain() {
        warmTextCache()
        guard state == .on, !navigationPaused, worker == nil, let settings, nextItem() != nil else { return }
        let issued = workGeneration
        worker = Task { [weak self] in
            guard let self else { return }
            while state == .on, !navigationPaused, workGeneration == issued, !Task.isCancelled, let item = nextItem() {
                activeKey = item.key
                let diagnostic = ReaderTranslationDiagnostics.makeContext(pageKey: item.key, page: item.position + 1)
                let startedAt = ProcessInfo.processInfo.systemUptime
                ReaderTranslationDiagnostics.record("page_start", page: item.position + 1, context: diagnostic)
                do {
                    let key = item.key
                    let diskWrite = await diskCache?.captureTranslationWrite(settings: settings)
                    var stored: [ReaderTranslationRegion]?
                    // The production Preloader checks a translated record against
                    // the admitted source before reusing it, never by locator alone.
                    if !usesBoundProcessor, let diskCache {
                        stored = await storedTranslation(page: item.key, settings: settings, diskCache: diskCache)
                    }
                    // Actor cache reads can resume after navigation has replaced
                    // this worker. Do not let that stale miss enter the shared
                    // preloader and displace the new destination's request.
                    try Task.checkCancellation()
                    guard workGeneration == issued else { return }
                    let record: ReaderTranslationRegionArchive.Record
                    if let stored {
                        ReaderTranslationDiagnostics.record("translation_cache_hit", page: item.position + 1, count: stored.count, context: diagnostic)
                        record = .init(regions: stored, sourceRasterClaim: nil)
                    } else {
                        guard canStartHeavyWork else {
                            activeKey = nil; worker = nil
                            ReaderTranslationDiagnostics.record("memory_deferred", page: item.position + 1)
                            scheduleMemoryRetry()
                            return
                        }
                        attemptedMemoryReclaim = false
                        // Offscreen API waits can overlap the one prepared renderer.
                        // Its image work shares admission with OCR; visible demand
                        // still preempts an obsolete speculative snapshot.
                        if !overlapsLayoutWithTranslation || visible.contains(where: {
                            $0.sourcePage?.translationCacheKey == item.key
                        }) { cancelLayout(clearQueue: false) }
                        ReaderTranslationDiagnostics.record("translation_start", page: item.position + 1)
                        record = try await ReaderTranslationDiagnostics.measure("page_translation", context: diagnostic) {
                            try await process(item.page, settings) { [weak self] progress in
                                try await self?.handleProgress(key: key, generation: issued, regions: progress)
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard workGeneration == issued else { return }
                    let regions = record.regions
                    if displayUnresolvedRecovery(record, key: item.key, settings: settings) {
                        activeKey = nil
                        continue
                    }
                    if shouldKeepTextInMemory(item.key) { try cache.store(record, for: item.key) }
                    finished.insert(item.key)
                    attempted.insert(item.key) // NSCache eviction must not spin the same completed demand.
                    retryCounts.removeValue(forKey: item.key)
                    didReportTranslationFailure = false
                    ReaderTranslationDiagnostics.record("translation_finished", page: item.position + 1, count: regions.count,
                        context: diagnostic, elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                    displayPreparedPages()
                    if stored == nil, !record.wasReadFromTranslationCache, let diskCache, let diskWrite,
                       let destination = await diskCache.resolveTranslationWrite(page: key, settings: settings, token: diskWrite) {
                        // A successful image fallback changes the durable identity. Rebase
                        // only through the token so clear/settings changes still reject old work.
                        // The write outlives navigation; lookups read the pending value.
                        await persistTranslation(record, pageKey: key, diskKey: destination.key, generation: destination.generation)
                    }
                    guard workGeneration == issued, !Task.isCancelled else { return }
                    if prepareLayout != nil, preparationItems.prefix(preparationWindowCount).contains(where: { $0.key == item.key }), !visible.contains(where: { $0.sourcePage?.translationCacheKey == item.key }) {
                        // Cache warming may have completed this render while the
                        // translation worker was reading the same disk record.
                        enqueuePreparedLayouts()
                        drainLayout()
                    }
                } catch {
                    // A superseded worker's provisional state was discarded by stopWorker.
                    guard workGeneration == issued, !Task.isCancelled else { return }
                    discardPendingNavigation()
                    discardProvisionalTranslations()
                    let cause = (error as? ReaderTranslationOCRFallback)?.underlying ?? error
                    let code: Int
                    switch cause {
                    case RemoteTranslationError.httpStatus(let status, _): code = status
                    case RemoteTranslationError.transport(let transport): code = transport.rawValue
                    default: code = (cause as NSError).code
                    }
                    ReaderTranslationDiagnostics.record("page_failed", page: item.position + 1, code: code, context: diagnostic, outcome: 2)
                    attempted.insert(item.key)
                    // Failed/partial pages keep their source image and never enter completed caches.
                    if scheduleTransientRetry(error, key: item.key) {
                        activeKey = nil
                        continue
                    }
                    let isVisibleFailure = visible.isEmpty || visible.contains { $0.sourcePage?.translationCacheKey == item.key }
                    let isTranslationFailure = error is ReaderTranslationOCRFallback || error is RemoteTranslationError
                        || error is TranslationCredentialStoreError || error is URLError
                    // An offscreen prefetch failure must not consume the visible page's notice.
                    if isVisibleFailure, isTranslationFailure, !didReportTranslationFailure {
                        onFailure?(error)
                        didReportTranslationFailure = true
                    }
                    // A broken image must not stop preparation of the remaining chapter.
                }
                discardPendingNavigation()
                activeKey = nil
            }
            if workGeneration == issued { worker = nil; drainLayout() }
        }
    }
}

extension ReaderTranslationSession {
    /// Uses already-computed item keys: logging must not rehash every chapter page on each load.
    func diagnosticContext(pageKey: String) -> ReaderTranslationDiagnostics.Context {
        let position = items.first { $0.key == pageKey }?.position
        return ReaderTranslationDiagnostics.makeContext(pageKey: pageKey, page: position.map { $0 + 1 } ?? -1)
    }

    /// Image loading can restore a completed translation before session startup.
    /// This lookup never recognizes an image, probes a provider, or starts work.
    func cachedRegions(for page: Page, settings: ReaderTranslationSettings, sourceImage: UIImage? = nil) async throws -> [ReaderTranslationRegion]? {
        try Task.checkCancellation()
        let key = page.translationCacheKey
        let identity = ReaderTranslationCacheIdentity.translation(page: "session", settings: settings)
        // Capability notifications arrive asynchronously. Image loading must not
        // relabel old memory regions with the recovered capability's render key.
        let usesCurrentMemory = self.settings?.hasSameTranslation(as: settings) == true && translationIdentity == identity
        if usesBoundProcessor {
            guard let sourceImage else { return nil }
            let memory = usesCurrentMemory ? cache.record(for: key) : nil
            let pending = usesCurrentMemory ? pendingTranslation(page: key, settings: settings) : nil
            if let claim = page.memoizedTranslationSource(for: sourceImage),
               let record = [memory, pending].compactMap({ $0 }).first(where: { $0.sourceRasterClaim == claim }) {
                return record.regions
            }
            let generation = await diskCache?.currentGeneration(settings: settings)
            let hasDiskCandidate = (try? await diskCache?.containsTranslationCandidate(page: key, settings: settings)) == true
            guard memory?.sourceRasterClaim != nil || pending?.sourceRasterClaim != nil || hasDiskCandidate else { return nil }
            guard let claim = await page.observeTranslationSource(for: sourceImage) else { return nil }
            let stored = hasDiskCandidate ? try? await diskCache?.translatedRegionRecord(page: key, settings: settings, matching: claim) : nil
            try Task.checkCancellation()
            guard identity == ReaderTranslationCacheIdentity.translation(page: "session", settings: settings),
                  generation == (await diskCache?.currentGeneration(settings: settings)) else { return nil }
            try Task.checkCancellation()
            let memoryIsCurrent = self.settings?.hasSameTranslation(as: settings) == true && translationIdentity == identity
            guard let record = (memoryIsCurrent ? [memory, pending, stored] : [stored])
                .compactMap({ $0 }).first(where: { $0.sourceRasterClaim == claim }) else { return nil }
            if memoryIsCurrent { try? cache.store(record, for: key) }
            return record.regions
        }
        if usesCurrentMemory, let regions = cache.regions(for: key) {
            return regions
        }
        guard let diskCache else { return nil }
        if usesCurrentMemory, let pending = pendingTranslation(page: key, settings: settings) {
            try? cache.store(pending, for: key)
            return pending.regions
        }
        let generation = await diskCache.currentGeneration(settings: settings)
        let record = try? await diskCache.translatedRegionRecord(page: key, settings: settings)
        try Task.checkCancellation()
        let current = await diskCache.currentGeneration(settings: settings)
        try Task.checkCancellation()
        guard generation == current, let record else { return nil }
        if self.settings?.hasSameTranslation(as: settings) == true, translationIdentity == identity,
           identity == ReaderTranslationCacheIdentity.translation(page: "session", settings: settings) {
            try? cache.store(record, for: key)
        }
        return record.regions
    }
}
