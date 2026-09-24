import UIKit
import os

/// Activation is local. One cancellable consumer drains
/// the chapter; its preloader can overlap one following page's OCR and API work.
@MainActor
final class ReaderTranslationSession {
    typealias Processor = (Page, ReaderTranslationSettings, ReaderTranslationService.Progress?) async throws -> [ReaderTranslationRegion]
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
    private let validate: ((ReaderTranslationSettings) async throws -> Void)?
    private let process: Processor
    private let cancelProcessing: () -> Void
    private let cancelProcessingForPage: ((Page) -> Void)?
    private let cache: ReaderTranslationSessionCache
    private let diskCache: ReaderTranslationDiskCache?
    let renderCache: ReaderTranslationRenderCache?
    private let prepareLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)?
    private let prepareTextLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)?
    private var textWarmTask: Task<Void, Never>?
    private var textWarmGeneration = UUID()
    private var warmedTextWindow: [String] = []
    static let textWindowCount = 33
    private let overlapsLayoutWithTranslation: Bool
    private var finished: Set<String> = []
    private let availableMemory: () -> UInt64
    private let reclaimMemory: () async -> Void
    private var attemptedMemoryReclaim = false
    private var memoryRetryTask: Task<Void, Never>?
    private var memoryNotBefore = Date.distantPast

    private var settings: ReaderTranslationSettings?
    private var items: [Item] = []
    private var visible: [ReaderTranslationPage] = []
    private var previews: [ReaderTranslationPage] = []
    private let knownPages = NSHashTable<ReaderTranslationPage>.weakObjects()
    private var attempted: Set<String> = []
    private var demandedVisibleKeys: Set<String> = []
    private var retryCounts: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var didReportTranslationFailure = false
    private var context: String?
    private var activation = UUID()
    private var workGeneration = UUID()
    private var probeTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var visibleCacheTask: Task<Void, Never>?
    private var visibleCacheKeys: Set<String> = []
    private var visibleCacheGeneration = UUID()
    private var activeKey: String?
    private var layoutQueue: [String: Item] = [:]
    private var layoutTask: Task<Void, Never>?
    private var activeLayoutKey: String?
    private var layoutGeneration = UUID()
    private var preparedLayouts: Set<String> = []
    private var renderContext = ""
    private var touchedPages: Set<String> = []
    private var currentPosition: Int?
    private var navigationPaused = false
    private let storeTranslation: TranslationStore?
    /// Completed translations whose disk write has not finished, keyed by disk identity.
    /// Lookups consult this first, so a pending write can never cause duplicate OCR/API work.
    private var pendingDiskStores: [String: (id: UUID, regions: [ReaderTranslationRegion], task: Task<Void, Never>)] = [:]
    private var pendingDiskStoreOrder: [String] = []
    /// Compact text only; bounds the write queue when disk I/O is slower than translation.
    static let maximumPendingDiskStores = 4
    var onStateChanged: ((State) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(
        validate: ((ReaderTranslationSettings) async throws -> Void)? = nil,
        process: @escaping Processor,
        cancelProcessing: @escaping () -> Void = {},
        cancelProcessingForPage: ((Page) -> Void)? = nil,
        diskCache: ReaderTranslationDiskCache? = nil,
        renderCache: ReaderTranslationRenderCache? = nil,
        prepareLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)? = nil,
        prepareTextLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)? = nil,
        overlapsLayoutWithTranslation: Bool = true,
        availableMemory: @escaping () -> UInt64 = { ReaderTranslationSession.processAvailableMemory() },
        reclaimMemory: @escaping () async -> Void = { await TranslationImageWorkBudget.reclaimIdleResources() },
        cache: ReaderTranslationSessionCache? = nil,
        storeTranslation: TranslationStore? = nil
    ) {
        self.validate = validate
        self.process = process
        self.cancelProcessing = cancelProcessing
        self.cancelProcessingForPage = cancelProcessingForPage
        self.diskCache = diskCache
        self.renderCache = renderCache
        self.prepareLayout = prepareLayout
        self.prepareTextLayout = prepareTextLayout
        self.overlapsLayoutWithTranslation = overlapsLayoutWithTranslation
        self.availableMemory = availableMemory
        self.reclaimMemory = reclaimMemory
        self.cache = cache ?? ReaderTranslationSessionCache()
        self.storeTranslation = storeTranslation ?? diskCache.map { diskCache in
            { @Sendable regions, key, generation in
                try? await diskCache.storeRegions(regions, for: key, kind: .translation, generation: generation)
            }
        }
    }

    deinit {
        probeTask?.cancel(); worker?.cancel(); layoutTask?.cancel(); visibleCacheTask?.cancel(); memoryRetryTask?.cancel(); textWarmTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
    }

    /// Display-frequency fast path: mount only existing bitmaps. Cache misses
    /// must not start disk reads, WebKit, OCR, or change the scheduling window.
    func displayCachedVisiblePages(_ pages: [ReaderTranslationPage]) {
        guard state == .on, let settings, let renderCache else { return }
        for page in pages {
            guard let key = page.sourcePage?.translationCacheKey,
                  let regions = cache.regions(for: key) else { continue }
            page.renderCache = renderCache
            knownPages.add(page)
            page.displayPreparedSnapshot(regions, settings: settings, memoryOnly: true)
        }
    }

    func refreshVisiblePages(_ pages: [ReaderTranslationPage], previews: [ReaderTranslationPage] = []) {
        // Keep only the incoming and outgoing sets during animation. A transient
        // empty callback must not erase the outgoing page or retain an entire swipe history.
        guard !pages.isEmpty else { return }
        self.previews = Array(previews.prefix(2))
        let retained = Set((visible + pages + self.previews).map(ObjectIdentifier.init))
        knownPages.allObjects.filter { !retained.contains(ObjectIdentifier($0)) }.forEach { $0.releaseOverlay() }
        visible = pages
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
        guard state == .on, let settings, let diskCache else { return }
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
                var regions = self?.pendingTranslation(page: key, settings: settings)
                if regions == nil { regions = try? await diskCache.translatedRegions(page: key, settings: settings) }
                guard !Task.isCancelled, let self, visibleCacheGeneration == issued,
                      state == .on, self.settings?.hasSameTranslation(as: settings) == true else { return }
                guard let regions else {
                    displayPreparedPages()
                    continue
                }
                try? cache.store(regions, for: key)
                // Deliver the loaded value directly: cache admission is best effort.
                for page in visible where page.sourcePage?.translationCacheKey == key {
                    page.displayPrepared(regions, settings: settings)
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
            attempted.removeAll()
            demandedVisibleKeys.removeAll()
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
        if currentPosition != anchor {
            stopWorker(preservingRecognitionFor: items.first { $0.position == anchor }?.page)
            retainUsefulLayout(in: Self.ordered(items, anchor: anchor, visibleKeys: visibleKeys))
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
        self.items = Self.ordered(items, anchor: anchor, visibleKeys: visibleKeys)
        self.visible = visible
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
            visible.forEach { $0.hidePreparedTranslation(preservingLoadedPresentation: true) }
        }
    }

    func enable(settings: ReaderTranslationSettings) {
        if let previous = self.settings, previous.hasSameTranslation(as: settings), state != .off {
            if previous.overlay != settings.overlay { cancelTextWarm(); cancelLayout(clearQueue: true); preparedLayouts.removeAll() }
            if previous.maximumConcurrentRequests != settings.maximumConcurrentRequests { stopWorker() }
            self.settings = settings
            if state == .on { displayPreparedPages(); drain(); enqueuePreparedLayouts(); drainLayout() }
            return
        }
        disable(preservingVisibleRendering: self.settings?.hasSameTranslation(as: settings) == true,
                preservingCachedPresentationFor: settings)
        if self.settings?.overlay != settings.overlay { preparedLayouts.removeAll() }
        if self.settings?.hasSameTranslation(as: settings) == false { cache.clear(); finished.removeAll(); preparedLayouts.removeAll() }
        self.settings = settings
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
        let visibleIDs = Set(visible.map(ObjectIdentifier.init))
        knownPages.allObjects.forEach {
            if let settings, $0.hasLoadedCachedPresentation, $0.hasCompletedTranslation(settings: settings) { return }
            if preservingVisibleRendering, visibleIDs.contains(ObjectIdentifier($0)) { $0.hidePreparedTranslation() }
            else { $0.showOriginal() }
        }
        state = .off
        onStateChanged?(state)
    }

    /// Cancel obsolete work while navigation settles, retaining the destination's
    /// lookahead. A nil destination (slider scrubbing) discards all pending work.
    func pauseForPageTurn(preservingRecognitionFor page: Page? = nil) {
        navigationPaused = true
        cancelVisibleCacheRestore()
        stopWorker(preservingRecognitionFor: page)
        if let key = page?.translationCacheKey, let destination = items.first(where: { $0.key == key }) {
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
        guard availableMemory() >= 512 * 1_024 * 1_024 else {
            suspendWorkForResourcePressure()
            return true
        }
        ReaderTranslationDiagnostics.record("memory_warning_trim", page: (currentPosition ?? -1) + 1)
        memoryNotBefore = Date().addingTimeInterval(3)
        cancelTextWarm()
        cancelLayout(clearQueue: true)
        cache.clear()
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
        finished.removeAll()
        preparedLayouts.removeAll()
    }

    private func stopWorker(preservingRecognitionFor page: Page? = nil) {
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
        guard items.prefix(preparationWindowCount).contains(where: { $0.key == key }) else { return }
        enqueuePreparedLayouts()
        drainLayout()
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
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
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
    }

    /// Compact cache reads never call the image loader, OCR or provider. Scan a
    /// much wider window than raster preparation, one record at a time.
    private func warmTextCache() {
        guard state == .on, let settings, let diskCache, textWarmTask == nil,
              Date() >= memoryNotBefore, availableMemory() >= 128 * 1_024 * 1_024 else { return }
        let window = Array(items.prefix(Self.textWindowCount))
        let keys = window.map(\.key)
        guard warmedTextWindow != keys else { return }
        warmedTextWindow = keys
        cache.retainPages(Set(keys))
        let issued = textWarmGeneration
        textWarmTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { if textWarmGeneration == issued { textWarmTask = nil } }
            for item in window {
                guard !Task.isCancelled, textWarmGeneration == issued, availableMemory() >= 128 * 1_024 * 1_024 else { return }
                if !cache.contains(item.key), let regions = await storedTranslation(page: item.key, settings: settings, diskCache: diskCache) {
                    guard !Task.isCancelled, textWarmGeneration == issued else { return }
                    try? cache.store(regions, for: item.key, evict: false)
                    if items.prefix(preparationWindowCount).contains(where: { $0.key == item.key }) {
                        enqueuePreparedLayouts()
                        drainLayout()
                    }
                    if (visible + previews).contains(where: { $0.sourcePage?.translationCacheKey == item.key }) { displayPreparedPages() }
                }
                await Task.yield()
            }
            enqueuePreparedLayouts()
            drainLayout()
            guard let prepareTextLayout else { return }
            for item in window {
                guard !Task.isCancelled, textWarmGeneration == issued, availableMemory() >= 256 * 1_024 * 1_024 else { return }
                let identity = ReaderTranslationCacheIdentity.translation(page: item.key, settings: settings)
                // Nearby full snapshots already prepare their own layouts.
                guard renderCache?.shouldKeepImage(for: identity) == false,
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
                  let item = items.prefix(preparationWindowCount).first(where: { layoutQueue[$0.key] != nil }) {
                guard canStartHeavyWork, overlapsLayoutWithTranslation || worker == nil else {
                    layoutTask = nil
                    scheduleMemoryRetry()
                    return
                }
                let isVisible = visible.contains { $0.sourcePage?.translationCacheKey == item.key }
                if !isVisible {
                    var regions = cache.regions(for: item.key)
                    if regions == nil, let diskCache {
                        regions = await storedTranslation(page: item.key, settings: settings, diskCache: diskCache)
                    }
                    guard layoutGeneration == issued, !Task.isCancelled else { return }
                    // A lookahead can publish to RAM while the disk lookup is
                    // suspended, before its independent persistence finishes.
                    // Recheck before removing the queue entry it just renewed.
                    if regions == nil { regions = cache.regions(for: item.key) }
                    if let regions {
                        do {
                            activeLayoutKey = item.key
                            ReaderTranslationDiagnostics.record("render_start", page: item.position + 1, count: regions.count)
                            try await prepareLayout(item.page, regions, settings)
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
        for item in items.prefix(preparationWindowCount) where !visibleKeys.contains(item.key) {
            let identity = ReaderTranslationCacheIdentity.translation(page: item.key, settings: settings)
            if !preparedLayouts.contains(item.key) || renderCache?.needsImage(for: identity) == true {
                layoutQueue[item.key] = item
            }
        }
    }

    func receivePrepared(_ page: Page, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) {
        guard !Task.isCancelled, state == .on, self.settings?.hasSameTranslation(as: settings) == true,
              items.contains(where: { $0.key == page.translationCacheKey }) else { return }
        if shouldKeepTextInMemory(page.translationCacheKey) {
            try? cache.store(regions, for: page.translationCacheKey)
        }
        finished.insert(page.translationCacheKey)
        displayPreparedPages()
        enqueuePreparedLayouts()
        drainLayout()
    }

    private func displayPreparedPages() {
        guard state == .on, let settings else { return }
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
            if page.hasCompletedTranslation(settings: settings) { page.showCompletedTranslation(settings: settings); continue }
            guard let key = page.sourcePage?.translationCacheKey else { continue }
            if let regions = cache.regions(for: key) {
                page.displayPrepared(regions, settings: settings)
            }
        }
        // The bitmap is mounted before UIKit exposes a neighboring page. These
        // views never start their own WebKit/OCR/API work, and cancelled swipes
        // leave the already composed preview attached.
        if Date() >= memoryNotBefore {
            let visibleIDs = Set(visible.map(ObjectIdentifier.init))
            for page in previews where !visibleIDs.contains(ObjectIdentifier(page)) {
                guard let key = page.sourcePage?.translationCacheKey, let regions = cache.regions(for: key) else { continue }
                page.displayPreparedSnapshot(regions, settings: settings)
            }
        }
    }

    private func handleProgress(key: String, generation: UUID) throws {
        try Task.checkCancellation()
        guard state == .on, workGeneration == generation, activeKey == key else { throw CancellationError() }
        // Progress only schedules cached neighbors; it never changes the visible
        // page. OCR has released image admission before this callback.
        drainLayout()
    }

    // Sweep the entire chapter with one consumer. Only nearby compact text stays
    // resident; distant completed pages live in the disk cache, not decoded images.
    private func shouldKeepTextInMemory(_ key: String) -> Bool {
        visible.contains { $0.sourcePage?.translationCacheKey == key }
            || items.prefix(Self.textWindowCount).contains { $0.key == key }
    }

    private func nextItem() -> Item? {
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        let isPending: (Item) -> Bool = { !self.attempted.contains($0.key) && !self.cache.contains($0.key) }
        let displayedKeys = Set(visible.filter { page in settings.map { page.hasCompletedTranslation(settings: $0) } == true }
            .compactMap { $0.sourcePage?.translationCacheKey })
        return items.first { visibleKeys.contains($0.key) && !displayedKeys.contains($0.key) && isPending($0) }
            ?? items.first { !finished.contains($0.key) && isPending($0) }
    }

    /// Called once current OCR is complete. The API may run while exactly one
    /// following page is recognized and translated, using the live reader priority order.
    func nextPageForRecognition(after page: Page) -> Page? {
        guard state == .on, !navigationPaused, canStartHeavyWork else { return nil }
        let key = page.translationCacheKey
        return items.first {
            $0.key != key && !finished.contains($0.key) && !attempted.contains($0.key) && !cache.contains($0.key)
        }?.page
    }

    static func ordered(_ items: [Item], anchor: Int, visibleKeys: Set<String> = []) -> [Item] {
        items.sorted { left, right in
            if visibleKeys.contains(left.key) != visibleKeys.contains(right.key) { return visibleKeys.contains(left.key) }
            let leftDistance = abs(left.position - anchor)
            let rightDistance = abs(right.position - anchor)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return left.position > right.position // Next page before previous at the same distance.
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
        retryTasks[key] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) } catch { return }
            guard let self, state == .on, workGeneration == issued, !Task.isCancelled else { return }
            retryTasks.removeValue(forKey: key)
            attempted.remove(key)
            // Current-page recovery should not wait behind an offscreen API batch.
            if let activeKey, activeKey != key { stopWorker() }
            drain()
        }
        return true
    }

    private func pendingTranslation(page key: String, settings: ReaderTranslationSettings) -> [ReaderTranslationRegion]? {
        pendingDiskStores[ReaderTranslationCacheIdentity.translation(page: key, settings: settings)]?.regions
    }

    private func storedTranslation(page key: String, settings: ReaderTranslationSettings,
                                   diskCache: ReaderTranslationDiskCache) async -> [ReaderTranslationRegion]? {
        if let pending = pendingTranslation(page: key, settings: settings) { return pending }
        return try? await diskCache.translatedRegions(page: key, settings: settings)
    }

    /// Starts a write that outlives worker cancellation. At most
    /// `maximumPendingDiskStores` writes are in flight; beyond that the worker
    /// waits for the oldest, so a slow disk cannot grow an unbounded queue.
    private func persistTranslation(_ regions: [ReaderTranslationRegion], diskKey: String, generation: UInt64) async {
        guard let storeTranslation else { return }
        while pendingDiskStores.count >= Self.maximumPendingDiskStores,
              let oldest = pendingDiskStoreOrder.first, let entry = pendingDiskStores[oldest] {
            await entry.task.value
            finishDiskStore(oldest, id: entry.id)
        }
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            await storeTranslation(regions, diskKey, generation)
            self?.finishDiskStore(diskKey, id: id)
        }
        pendingDiskStoreOrder.removeAll { $0 == diskKey }
        pendingDiskStoreOrder.append(diskKey)
        pendingDiskStores[diskKey] = (id, regions, task)
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
            while state == .on, workGeneration == issued, !Task.isCancelled, let item = nextItem() {
                activeKey = item.key
                ReaderTranslationDiagnostics.record("page_start", page: item.position + 1)
                do {
                    let key = item.key
                    let diskKey = ReaderTranslationCacheIdentity.translation(page: key, settings: settings)
                    let diskGeneration = await diskCache?.currentGeneration(settings: settings) ?? 0
                    var stored: [ReaderTranslationRegion]?
                    if let diskCache { stored = await storedTranslation(page: item.key, settings: settings, diskCache: diskCache) }
                    let regions: [ReaderTranslationRegion]
                    if let stored {
                        ReaderTranslationDiagnostics.record("translation_cache_hit", page: item.position + 1, count: stored.count)
                        regions = stored
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
                        regions = try await process(item.page, settings) { [weak self] _ in
                            try await self?.handleProgress(key: key, generation: issued)
                        }
                    }
                    try Task.checkCancellation()
                    guard workGeneration == issued else { return }
                    if shouldKeepTextInMemory(item.key) { try cache.store(regions, for: item.key) }
                    finished.insert(item.key)
                    attempted.insert(item.key) // NSCache eviction must not spin the same completed demand.
                    retryCounts.removeValue(forKey: item.key)
                    didReportTranslationFailure = false
                    ReaderTranslationDiagnostics.record("translation_finished", page: item.position + 1, count: regions.count)
                    displayPreparedPages()
                    if stored == nil, diskCache != nil {
                        // Completed API work must survive a page turn cancelling this worker.
                        // The write proceeds in the background; lookups read the pending value.
                        await persistTranslation(regions, diskKey: diskKey, generation: diskGeneration)
                    }
                    guard workGeneration == issued, !Task.isCancelled else { return }
                    if prepareLayout != nil, items.prefix(preparationWindowCount).contains(where: { $0.key == item.key }), !visible.contains(where: { $0.sourcePage?.translationCacheKey == item.key }) {
                        // Cache warming may have completed this render while the
                        // translation worker was reading the same disk record.
                        enqueuePreparedLayouts()
                        drainLayout()
                    }
                } catch {
                    guard workGeneration == issued, !Task.isCancelled else { return }
                    let cause = (error as? ReaderTranslationOCRFallback)?.underlying ?? error
                    let code: Int
                    switch cause {
                    case RemoteTranslationError.httpStatus(let status, _): code = status
                    case RemoteTranslationError.transport(let transport): code = transport.rawValue
                    default: code = (cause as NSError).code
                    }
                    ReaderTranslationDiagnostics.record("page_failed", page: item.position + 1, code: code)
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
                activeKey = nil
            }
            if workGeneration == issued { worker = nil; drainLayout() }
        }
    }
}

extension ReaderTranslationSession {
    /// Image loading can restore a completed translation before session startup.
    /// This lookup never recognizes an image, probes a provider, or starts work.
    func cachedRegions(for page: Page, settings: ReaderTranslationSettings) async throws -> [ReaderTranslationRegion]? {
        try Task.checkCancellation()
        let key = page.translationCacheKey
        if self.settings?.hasSameTranslation(as: settings) == true, let regions = cache.regions(for: key) {
            return regions
        }
        guard let diskCache else { return nil }
        if self.settings?.hasSameTranslation(as: settings) == true, let pending = pendingTranslation(page: key, settings: settings) {
            try? cache.store(pending, for: key)
            return pending
        }
        let generation = await diskCache.currentGeneration(settings: settings)
        let regions = try? await diskCache.translatedRegions(page: key, settings: settings)
        try Task.checkCancellation()
        let current = await diskCache.currentGeneration(settings: settings)
        try Task.checkCancellation()
        guard generation == current, let regions else { return nil }
        if self.settings?.hasSameTranslation(as: settings) == true { try? cache.store(regions, for: key) }
        return regions
    }
}
