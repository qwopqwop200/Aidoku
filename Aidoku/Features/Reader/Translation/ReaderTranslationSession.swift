import UIKit

/// Activation is gated by a real API probe. One cancellable consumer drains
/// the chapter; its preloader can overlap one following page's OCR and API work.
@MainActor
final class ReaderTranslationSession {
    typealias Processor = (Page, ReaderTranslationSettings, ReaderTranslationService.Progress?) async throws -> [ReaderTranslationRegion]
    enum State: Equatable { case off, checking, on }
    struct Item {
        let key: String
        let page: Page
        let position: Int
        init(_ page: Page) { self.init(page, position: page.index) }
        init(_ page: Page, position: Int) { self.page = page; key = page.translationCacheKey; self.position = position }
    }
    static func chapterItems(_ pages: [Page]) -> [Item] {
        pages.enumerated().map { Item($0.element, position: $0.offset) }
    }
    private(set) var state: State = .off
    private let validate: (ReaderTranslationSettings) async throws -> Void
    private let process: Processor
    private let cancelProcessing: () -> Void
    private let cancelProcessingForPage: ((Page) -> Void)?
    private let cache = ReaderTranslationSessionCache()
    private let diskCache: ReaderTranslationDiskCache?
    private let renderCache: ReaderTranslationRenderCache?
    private let prepareLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)?
    private var finished: Set<String> = []
    private var settings: ReaderTranslationSettings?
    private var items: [Item] = []
    private var visible: [ReaderTranslationPage] = []
    private let knownPages = NSHashTable<ReaderTranslationPage>.weakObjects()
    private var attempted: Set<String> = []
    private var context: String?
    private var activation = UUID()
    private var workGeneration = UUID()
    private var probeTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var activeKey: String?
    private var activeRegions: [ReaderTranslationRegion]?
    private var layoutQueue: [String: Item] = [:]
    private var layoutTask: Task<Void, Never>?
    private var layoutGeneration = UUID()
    private var preparedLayouts: Set<String> = []
    private var renderContext = ""
    private var touchedPages: Set<String> = []
    private var currentPosition: Int?
    var onStateChanged: ((State) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(
        validate: @escaping (ReaderTranslationSettings) async throws -> Void = {
            try await ReaderTranslationAPIValidator.shared.validateFreshForActivation($0)
        },
        process: @escaping Processor,
        cancelProcessing: @escaping () -> Void = {},
        cancelProcessingForPage: ((Page) -> Void)? = nil,
        diskCache: ReaderTranslationDiskCache? = nil,
        renderCache: ReaderTranslationRenderCache? = nil,
        prepareLayout: ((Page, [ReaderTranslationRegion], ReaderTranslationSettings) async throws -> Void)? = nil
    ) {
        self.validate = validate
        self.process = process
        self.cancelProcessing = cancelProcessing
        self.cancelProcessingForPage = cancelProcessingForPage
        self.diskCache = diskCache
        self.renderCache = renderCache
        self.prepareLayout = prepareLayout
    }

    deinit { probeTask?.cancel(); worker?.cancel(); layoutTask?.cancel() }

    func refreshVisiblePages(_ pages: [ReaderTranslationPage]) {
        let ids = Set(pages.map(ObjectIdentifier.init))
        visible.filter { !ids.contains(ObjectIdentifier($0)) }.forEach { $0.releaseOverlay() }
        visible = pages
        pages.forEach { $0.renderCache = renderCache; knownPages.add($0) }
        if state == .on { displayPreparedPages() }
    }

    func update(items: [Item], visible: [ReaderTranslationPage], context: String, currentPageIndex: Int? = nil, renderContext: String? = nil) {
        if self.context != context {
            stopWorker()
            cancelLayout(clearQueue: true)
            attempted.removeAll()
            finished.removeAll()
            preparedLayouts.removeAll()
            self.context = context
        }
        if let renderContext, self.renderContext != renderContext {
            cancelLayout(clearQueue: true)
            preparedLayouts.removeAll()
            self.renderContext = renderContext
        }
        let visibleIDs = Set(visible.map(ObjectIdentifier.init))
        self.visible.filter { !visibleIDs.contains(ObjectIdentifier($0)) }.forEach { $0.releaseOverlay() }
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        let anchor = currentPageIndex ?? items.first(where: { visibleKeys.contains($0.key) })?.position ?? items.first?.position ?? 0
        if currentPosition != anchor || self.items.count != items.count {
            ReaderTranslationDiagnostics.record("queue", page: anchor + 1, count: items.count)
            currentPosition = anchor
        }
        self.items = Self.ordered(items, anchor: anchor, visibleKeys: visibleKeys)
        self.visible = visible
        visible.forEach { $0.renderCache = renderCache; knownPages.add($0) }
        if state == .on {
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
            visible.forEach { $0.showOriginal() }
        }
    }

    func enable(settings: ReaderTranslationSettings) {
        if let previous = self.settings, previous.hasSameTranslation(as: settings), state != .off {
            if previous.overlay != settings.overlay { cancelLayout(clearQueue: true); preparedLayouts.removeAll() }
            if previous.maximumConcurrentRequests != settings.maximumConcurrentRequests { stopWorker() }
            self.settings = settings
            if state == .on { displayPreparedPages(); drain(); enqueuePreparedLayouts(); drainLayout() }
            return
        }
        disable()
        if self.settings?.overlay != settings.overlay { preparedLayouts.removeAll() }
        if self.settings?.hasSameTranslation(as: settings) == false { cache.clear(); finished.removeAll(); preparedLayouts.removeAll() }
        self.settings = settings
        attempted.removeAll()
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
                disable()
                if !(error is CancellationError) { onFailure?(error) }
            }
        }
    }

    func disable(reason: String = "off") {
        if state != .off { ReaderTranslationDiagnostics.record(reason, page: (currentPosition ?? -1) + 1) }
        activation = UUID()
        probeTask?.cancel()
        probeTask = nil
        stopWorker()
        cancelLayout(clearQueue: true)
        renderCache?.clearMemory()
        knownPages.allObjects.forEach { $0.showOriginal() }
        state = .off
        onStateChanged?(state)
    }

    func close() {
        disable(reason: "reader_closed")
        items = []
        visible = []
        knownPages.removeAllObjects()
        cache.clear()
        finished.removeAll()
        preparedLayouts.removeAll()
    }

    private func stopWorker(preservingRecognitionFor page: Page? = nil) {
        if let activeKey {
            ReaderTranslationDiagnostics.record("worker_cancelled", page: (items.first { $0.key == activeKey }?.position ?? -1) + 1)
        }
        workGeneration = UUID()
        worker?.cancel()
        worker = nil
        activeKey = nil
        activeRegions = nil
        if let page, let cancelProcessingForPage { cancelProcessingForPage(page) } else { cancelProcessing() }
    }

    private func cancelLayout(clearQueue: Bool) {
        layoutGeneration = UUID()
        layoutTask?.cancel()
        layoutTask = nil
        if clearQueue { layoutQueue.removeAll() }
    }

    private func drainLayout() {
        guard state == .on, layoutTask == nil, let prepareLayout, let settings, !layoutQueue.isEmpty else { return }
        let issued = layoutGeneration
        layoutTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            while state == .on, layoutGeneration == issued, !Task.isCancelled,
                  let item = items.first(where: { layoutQueue[$0.key] != nil }) {
                let isVisible = visible.contains { $0.sourcePage?.translationCacheKey == item.key }
                if !isVisible {
                    var regions = cache.regions(for: item.key)
                    if regions == nil { regions = try? await diskCache?.translatedRegions(page: item.key, settings: settings) }
                    if let regions {
                        do {
                            ReaderTranslationDiagnostics.record("render_start", page: item.position + 1, count: regions.count)
                            try await prepareLayout(item.page, regions, settings)
                            guard layoutGeneration == issued, !Task.isCancelled else { return }
                            preparedLayouts.insert(item.key)
                            ReaderTranslationDiagnostics.record("render_finished", page: item.position + 1)
                        } catch {
                            ReaderTranslationDiagnostics.record("render_failed", page: item.position + 1, code: (error as NSError).code)
                        }
                    }
                }
                guard layoutGeneration == issued, !Task.isCancelled else { return }
                layoutQueue.removeValue(forKey: item.key)
            }
            if layoutGeneration == issued { layoutTask = nil }
        }
    }

    private func enqueuePreparedLayouts() {
        guard prepareLayout != nil, let settings else { return }
        let visibleKeys = Set(visible.compactMap { $0.sourcePage?.translationCacheKey })
        for item in items where !visibleKeys.contains(item.key) &&
            (finished.contains(item.key) || cache.contains(item.key)) {
            let identity = ReaderTranslationCacheIdentity.translation(page: item.key, settings: settings)
            if !preparedLayouts.contains(item.key) || renderCache?.needsImage(for: identity) == true {
                layoutQueue[item.key] = item
            }
        }
    }

    private func displayPreparedPages() {
        guard state == .on, let settings else { return }
        renderCache?.setNearbyPages(pageKeys: items.map(\.key), settings: settings)
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
            } else if key == activeKey, let activeRegions {
                page.displayPrepared(activeRegions, settings: settings, completed: false)
            }
        }
    }

    private func publishProgress(_ regions: [ReaderTranslationRegion], key: String, generation: UUID) throws {
        try Task.checkCancellation()
        guard state == .on, workGeneration == generation, activeKey == key else { throw CancellationError() }
        // Keep the original image until there is translated text to paint.
        guard regions.contains(where: { $0.translation?.isEmpty == false }) else { return }
        activeRegions = regions
        displayPreparedPages()
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
        guard state == .on else { return nil }
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

    private func drain() {
        guard state == .on, worker == nil, let settings, nextItem() != nil else { return }
        let issued = workGeneration
        worker = Task { [weak self] in
            guard let self else { return }
            while state == .on, workGeneration == issued, !Task.isCancelled, let item = nextItem() {
                activeKey = item.key
                ReaderTranslationDiagnostics.record("page_start", page: item.position + 1)
                activeRegions = nil
                do {
                    let key = item.key
                    let diskKey = ReaderTranslationCacheIdentity.translation(page: key, settings: settings)
                    let diskGeneration = await diskCache?.currentGeneration() ?? 0
                    let stored = try? await diskCache?.translatedRegions(page: item.key, settings: settings)
                    let regions: [ReaderTranslationRegion]
                    if let stored {
                        ReaderTranslationDiagnostics.record("translation_cache_hit", page: item.position + 1, count: stored.count)
                        regions = stored
                    } else {
                        ReaderTranslationDiagnostics.record("translation_start", page: item.position + 1)
                        regions = try await process(item.page, settings) { [weak self] regions in
                            try await self?.publishProgress(regions, key: key, generation: issued)
                        }
                    }
                    try Task.checkCancellation()
                    guard workGeneration == issued else { return }
                    try cache.store(regions, for: item.key)
                    finished.insert(item.key)
                    ReaderTranslationDiagnostics.record("translation_finished", page: item.position + 1, count: regions.count)
                    displayPreparedPages()
                    if stored == nil {
                        if let diskCache {
                            // Completed API work must survive a page turn cancelling this worker.
                            await Task(priority: .utility) {
                                try? await diskCache.storeRegions(regions, for: diskKey, kind: .translation, generation: diskGeneration)
                            }.value
                        }
                    }
                    guard workGeneration == issued, !Task.isCancelled else { return }
                    if prepareLayout != nil, !visible.contains(where: { $0.sourcePage?.translationCacheKey == item.key }) {
                        layoutQueue[item.key] = item
                        drainLayout()
                    }
                } catch {
                    guard workGeneration == issued, !Task.isCancelled else { return }
                    ReaderTranslationDiagnostics.record("page_failed", page: item.position + 1, code: (error as NSError).code)
                    if error is RemoteTranslationError || error is TranslationCredentialStoreError {
                        disable()
                        onFailure?(error)
                        return
                    }
                    // A broken image must not stop preparation of the remaining chapter.
                    attempted.insert(item.key)
                }
                activeKey = nil
                activeRegions = nil
            }
            if workGeneration == issued { worker = nil }
        }
    }
}
