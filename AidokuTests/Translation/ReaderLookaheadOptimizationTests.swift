import AsyncDisplayKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderLookaheadOptimizationTests {
    @Test(arguments: [1, 9, -1])
    func navigationKeepsOnlyUsefulInFlightRaster(destination: Int) async throws {
        let pages = (0..<12).map { Page(sourceId: "keep-raster", chapterId: "chapter", index: $0) }
        let cache = ReaderTranslationSessionCache()
        try cache.store([ReaderTranslationPersistentPipelineTests.region], for: pages[2].translationCacheKey)
        let gate = LookaheadTestGate()
        var completed = false, cancelled = false, finished = false
        var starts = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            Issue.record("Cache-only navigation must not invoke OCR/API")
            return []
        }, prepareLayout: { _, _, _ in
            starts += 1
            defer { finished = true }
            await gate.wait()
            do { try Task.checkCancellation(); completed = true }
            catch { cancelled = true; throw error }
        }, availableMemory: { .max }, cache: cache)
        defer { session.close(); Task { await gate.release() } }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "chapter",
                       currentPageIndex: 0, processUncachedPages: false)
        session.enable(settings: ReaderTranslationSettings())
        try await waitUntil { await gate.started }
        session.pauseForPageTurn(preservingRecognitionFor: destination < 0 ? nil : pages[destination])
        if destination >= 0 {
            session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "chapter",
                           currentPageIndex: destination, processUncachedPages: false)
        }
        await gate.release()
        try await waitUntil { finished }
        #expect(completed == (destination == 1))
        #expect(cancelled == (destination != 1))
        #expect(starts == 1, "Useful rendering must continue without restarting")
    }

    @Test func webtoonPreloadPublishesPixelsBeforeCreatingItsView() async throws {
        let image = ReaderTranslationPersistentPipelineTests.image()
        let page = Page(sourceId: "preloaded-node", chapterId: "chapter", index: 1, image: image)
        let node = ReaderWebtoonPageNode(source: nil, page: page, temporaryPageStore: ReaderTemporaryPageStore(),
                                        pillarboxLayoutState: ReaderPillarboxLayoutState())
        var received = false
        let observer = NotificationCenter.default.addObserver(forName: ReaderTranslationPage.sourceImageReady,
            object: nil, queue: .main) { notification in
                guard let source = notification.object as? ReaderTranslationPage.LoadedSource else { return }
                if source.page.translationCacheKey == page.translationCacheKey, source.image === image { received = true }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        await node.loadPage()
        try await waitUntil { received }
        #expect(!node.isNodeLoaded, "Image-ready delivery must not instantiate offscreen UIKit views")
    }

    @Test func imageReadyRetriesPrerenderWithoutWaitingForNavigation() async throws {
        let pages = (0..<2).map { Page(sourceId: "image-ready", chapterId: "chapter", index: $0) }
        let cache = ReaderTranslationSessionCache()
        try cache.store([ReaderTranslationPersistentPipelineTests.region], for: pages[1].translationCacheKey)
        var attempts = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            Issue.record("Image readiness must not start OCR/API")
            return []
        }, prepareLayout: { _, _, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.fileDoesNotExist) }
        }, availableMemory: { .max }, cache: cache)
        defer { session.close() }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "chapter",
                       processUncachedPages: false)
        session.enable(settings: ReaderTranslationSettings())
        try await waitUntil { attempts == 1 }
        session.sourceImageDidLoad(pages[1])
        try await waitUntil { attempts == 2 }
    }

    @Test func loadedSourcesAreBorrowedAndBounded() {
        let preparer = ReaderTranslationLayoutPreparer()
        let page = Page(sourceId: "weak-source", chapterId: "test", index: 0)
        autoreleasepool {
            let image = ReaderTranslationPersistentPipelineTests.image()
            preparer.sourceDidLoad(image, page: page)
            #expect(preparer.loadedImage(for: page) === image)
        }
        #expect(preparer.loadedImage(for: page) == nil, "Reader releases must not be defeated by prerender metadata")
        let held = ReaderTranslationPersistentPipelineTests.image()
        preparer.sourceDidLoad(held, page: page)
        for index in 1...8 {
            preparer.sourceDidLoad(held, page: Page(sourceId: "weak-source", chapterId: "test", index: index))
        }
        #expect(preparer.loadedImage(for: page) == nil)
    }

    @Test(arguments: [false, true])
    func cachedNavigationPreparesBeforeDebounceWithoutStartingOCR(lowMemory: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let settings = ReaderTranslationSettings()
        let pages = (0..<12).map { Page(sourceId: "fast-scroll", chapterId: root.lastPathComponent, index: $0) }
        let generation = await disk.currentGeneration(settings: settings)
        let key = ReaderTranslationCacheIdentity.translation(page: pages[9].translationCacheKey, settings: settings)
        try await disk.storeRegions([ReaderTranslationPersistentPipelineTests.region], for: key,
                                    kind: .translation, generation: generation)
        let cache = ReaderTranslationSessionCache()
        var calls = 0
        var layouts: [Int] = []
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [] }, diskCache: disk,
            prepareLayout: { page, _, _ in layouts.append(page.index) },
            availableMemory: { lowMemory ? 256 * 1_024 * 1_024 : .max }, cache: cache)
        defer { session.close() }
        session.enable(settings: settings)
        // Jump outside the old raster window. Never deliver the debounced update:
        // cached lookahead must progress even while navigation remains paused.
        session.pauseForPageTurn(preservingRecognitionFor: pages[8])
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "fast-scroll",
                       currentPageIndex: 8, processUncachedPages: false)
        try await waitUntil { cache.contains(pages[9].translationCacheKey) }
        if lowMemory {
            try await Task.sleep(for: .milliseconds(100))
            #expect(layouts.isEmpty)
        } else {
            try await waitUntil { layouts.contains(9) }
        }
        #expect(calls == 0)
        #expect(session.nextPageForRecognition(after: pages[8]) == nil)
        if !lowMemory {
            session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "fast-scroll",
                           currentPageIndex: 8)
            try await waitUntil { calls > 0 }
        }
    }

    @Test func wideTextWindowWarmsWithoutImagesOrOCRUnderHeavyWorkPressure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let settings = ReaderTranslationSettings()
        let pages = (0..<45).map { Page(sourceId: "text-window", chapterId: root.lastPathComponent, index: $0,
                                       imageURL: "file:///must-not-load-this-image.png") }
        for page in pages {
            let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
            try await disk.storeRegions([ReaderTranslationPersistentPipelineTests.region], for: key, kind: .translation, generation: 0)
        }
        let cache = ReaderTranslationSessionCache()
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [] }, diskCache: disk,
            availableMemory: { 512 * 1_024 * 1_024 }, cache: cache)
        defer { session.close() }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "text-window")
        session.enable(settings: settings)
        try await waitUntil { cache.contains(pages[32].translationCacheKey) }
        #expect(!cache.contains(pages[33].translationCacheKey))
        #expect(calls == 0)
        #expect(cache.bytes <= ReaderTranslationSessionCache.byteLimit)
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "text-window", currentPageIndex: 44)
        try await waitUntil { cache.contains(pages[44].translationCacheKey) }
        #expect(!cache.contains(pages[0].translationCacheKey))
        #expect(calls == 0)
    }

    @Test func textLayoutUsesSavedDimensionsWithoutDecodingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let settings = ReaderTranslationSettings()
        let page = Page(sourceId: "layout-only", chapterId: "test", index: 8, imageURL: "file:///must-not-load.png")
        let size = CGSize(width: 620, height: 903)
        try await disk.storeImageSize(size, page: page.translationCacheKey, generation: 0)
        cache.setNearbyPages(pageKeys: ["other-page"], settings: settings)
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        view.contentMode = .scaleAspectFit
        let reader = ReaderTranslationPage(imageView: view)
        reader.sourcePage = page
        let geometry = ReaderTranslationLayoutGeometry(page: reader, imageView: view)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache,
            imageBudget: TranslationImageWorkBudget(availableMemory: { 0 }))
        try await preparer.prepare(page: page, regions: [ReaderTranslationPersistentPipelineTests.region], settings: settings, geometry: geometry)
        let key = ReaderTranslationCacheIdentity.render(page: page.translationCacheKey, settings: settings, imageSize: size,
            viewport: geometry.viewport(for: size), scale: geometry.scale, aspectFit: true,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: geometry.dark)
        let regions = [ReaderTranslationPersistentPipelineTests.region].compactMap {
            $0.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let data = try #require(cache.cachedLayout(for: ReaderTranslationRenderCache.layoutKey(renderKey: key, regions: regions)))
        let layout = try JSONDecoder().decode(NativeTranslationLayout.self, from: data)
        #expect(layout.version == NativeTranslationLayout.currentVersion)
        #expect(layout.imageSize == size)
        #expect(layout.viewport == geometry.viewport(for: size))
        #expect(!layout.items.isEmpty)
        #expect(layout.items.contains { $0.text == ReaderTranslationPersistentPipelineTests.region.translation })
        #expect(layout.items.allSatisfy { $0.sourceFrame == [layout.sourceRect.minX, layout.sourceRect.minY,
            layout.sourceRect.width, layout.sourceRect.height] })
        #expect(cache.bitmapBytes == 0)
        let hit = ReaderTranslationLayoutPreparer(renderCache: cache, layoutPreparation: { _, _, _, _, _, _ in
            Issue.record("A cached text layout must not be measured again")
            throw URLError(.unknown)
        })
        try await hit.prepareTextOnly(page: page, regions: [ReaderTranslationPersistentPipelineTests.region], settings: settings, geometry: geometry)
        #expect(cache.bitmapBytes == 0)
    }

    @Test func renderedPagesStayInMemoryWithoutDuplicatingArtworkOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let source = ReaderTranslationPersistentPipelineTests.image()
        let viewport = CGSize(width: 390, height: 800)
        let frame = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: source.size, bounds: CGRect(origin: .zero, size: viewport), aspectFit: true)
        let layout = try await NativeTranslationLayoutPlanner.prepareLayoutData(
            items: ReaderTranslationRegion.layoutItems([ReaderTranslationPersistentPipelineTests.region], imageSize: source.size),
            imageSize: source.size, sourceRect: frame, settings: ReaderTranslationSettings.defaultOverlay,
            targetLanguage: "ko", viewport: viewport)
        await cache.storeLayout(layout, key: "snapshot", diskGeneration: 0)
        await cache.store(source, key: "snapshot", pageIdentity: "page", diskGeneration: 0)
        #expect(cache.cachedImage(for: "snapshot") === source)
        #expect(try await !disk.contains("snapshot", kind: .snapshot))
        cache.clearMemory()
        let reopened = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        #expect(await reopened.load("snapshot") == nil)
        let reopenedLayout = try #require(await reopened.layoutData(for: "snapshot"))
        #expect(reopenedLayout == layout, "The valid native text layout must persist byte-for-byte independently of artwork")
        #expect(try JSONDecoder().decode(NativeTranslationLayout.self, from: reopenedLayout).items.isEmpty == false)
        #expect(reopened.bitmapBytes == 0)
    }

    @Test func bitmapAndTextCachesHaveHardByteBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2048, height: 2048), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2048, height: 2048))
        }
        for index in 0..<12 {
            await cache.store(image, key: "image-\(index)", pageIdentity: "page-\(index)", diskGeneration: 0)
            #expect(cache.bitmapBytes <= ReaderTranslationRenderCache.bitmapByteLimit)
        }
        #expect(cache.cachedImage(for: "image-0") == nil)
        #expect(cache.cachedImage(for: "image-11") != nil)
        for index in 0..<40 {
            await cache.storeLayout(Data(repeating: 32, count: 100_000), key: "layout-\(index)", diskGeneration: 0)
            #expect(cache.layoutBytes <= ReaderTranslationRenderCache.layoutByteLimit)
        }
        #expect(cache.cachedLayout(for: "layout-0") == nil)
        #expect(cache.cachedLayout(for: "layout-39") != nil)
        let text = ReaderTranslationSessionCache()
        var region = ReaderTranslationPersistentPipelineTests.region
        region.translation = String(repeating: "가", count: 100_000)
        for index in 0..<40 {
            try text.store([region], for: String(index))
            #expect(text.bytes <= ReaderTranslationSessionCache.byteLimit)
        }
        #expect(!text.contains("0"))
        #expect(text.contains("39"))
        cache.clearMemory(); text.clear()
        #expect(cache.bitmapBytes == 0)
        #expect(cache.layoutBytes == 0)
        #expect(text.bytes == 0)
    }

    @Test func preparedLookaheadRespectsMemoryPressureAndOffState() async throws {
        let pages = (0..<2).map { Page(sourceId: "render-admission", chapterId: "test", index: $0) }
        var memory = UInt64.max
        var layouts: [Int] = []
        let settings = ReaderTranslationSettings()
        let session = ReaderTranslationSession(process: { _, _, _ in [] },
            prepareLayout: { page, _, _ in layouts.append(page.index) }, availableMemory: { memory })
        defer { session.close() }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "test")
        memory = 0
        session.enable(settings: settings)
        session.receivePrepared(pages[1], regions: [ReaderTranslationPersistentPipelineTests.region], settings: settings)
        try await Task.sleep(for: .milliseconds(50))
        #expect(layouts.isEmpty)
        session.disable()
        memory = .max
        session.receivePrepared(pages[1], regions: [ReaderTranslationPersistentPipelineTests.region], settings: settings)
        try await Task.sleep(for: .milliseconds(50))
        #expect(layouts.isEmpty)
    }

    @Test(arguments: [false, true])
    func nextPageRendersWhileVisibleTranslationIsWaiting(cached: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer {
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.maximumConcurrentRequests = 2
        settings.includePageImage = false
        settings.rightToLeftPanelOrder = false
        settings.translationSourceLanguages = []
        let disk = ReaderTranslationDiskCache(directory: root)
        let pages = (0..<2).map { Page(sourceId: "early-render", chapterId: root.lastPathComponent, index: $0) }
        if cached {
            let key = ReaderTranslationCacheIdentity.translation(page: pages[1].translationCacheKey, settings: settings)
            let generation = await disk.currentGeneration(settings: settings)
            try await disk.storeRegions([ReaderTranslationPersistentPipelineTests.region], for: key, kind: .translation, generation: generation)
        }
        let gate = LookaheadTestGate()
        let preloader = ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, _ in
            if regions.first?.id == "0" { await gate.wait() }
            return regions.map { var region = $0; region.translation = "미리 준비한 번역"; return region }
        }, recognizer: { page, _ in
            let region = ReaderTranslationRegion(id: String(page.index), rect: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.1),
                                                 source: "HELLO WORLD", sourceOrientation: .horizontal)
            return [region]
        }, availableMemory: { .max })
        var layouts: [Int] = []
        let imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let visible = ReaderTranslationPage(imageView: imageView)
        visible.sourcePage = pages[0]
        let session = ReaderTranslationSession(process: { page, settings, progress in
            try await preloader.translate(page, settings: settings, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() }, diskCache: disk,
            prepareLayout: { page, _, _ in layouts.append(page.index) }, availableMemory: { .max })
        preloader.nextPage = { [weak session] in session?.nextPageForRecognition(after: $0) }
        preloader.onPrepared = { [weak session] in session?.receivePrepared($0, regions: $1, settings: $2) }
        defer { session.close(); Task { await gate.release() } }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [visible], context: "early-render")
        session.enable(settings: settings)
        try await waitUntil { await gate.started }
        try await waitUntil { layouts.contains(1) }
        #expect(!visible.hasCompletedTranslation(settings: settings))
        #expect(layouts == [1])
    }

    @Test func completedLookaheadDisplaysBeforePersistenceAndStillSavesAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.maximumConcurrentRequests = 2
        settings.includePageImage = false; settings.rightToLeftPanelOrder = false
        settings.translationSourceLanguages = []
        let disk = ReaderTranslationDiskCache(directory: root)
        let demandGate = LookaheadTestGate(), writeGate = LookaheadTestGate()
        let pages = (0..<2).map { Page(sourceId: "display-before-save", chapterId: root.lastPathComponent, index: $0) }
        let preloader = ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, _ in
            if regions.first?.id == "0" { await demandGate.wait() }
            return regions.map { var value = $0; value.translation = "준비된 번역"; return value }
        }, recognizer: { page, _ in
            [ReaderTranslationRegion(id: String(page.index), rect: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.1),
                source: "HELLO WORLD", sourceOrientation: .horizontal)]
        }, availableMemory: { .max }, storePreparedTranslation: { regions, key, generation in
            await writeGate.wait()
            try? await disk.storeRegions(regions, for: key, kind: .translation, generation: generation)
        })
        preloader.nextPage = { $0.index == 0 ? pages[1] : nil }
        let textCache = ReaderTranslationSessionCache()
        let session = ReaderTranslationSession(process: { _, _, _ in
            Issue.record("Delivery of completed lookahead must not start OCR/API work"); return []
        }, availableMemory: { 0 }, cache: textCache)
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "display-before-save")
        session.enable(settings: settings)
        try await waitUntil { session.state == .on }
        preloader.onPrepared = { [weak session] in session?.receivePrepared($0, regions: $1, settings: $2) }
        let demand = Task { try await preloader.translate(pages[0], settings: settings) }
        defer {
            preloader.cancel(); demand.cancel(); session.close()
            Task { await writeGate.release(); await demandGate.release() }
        }
        try await waitUntil { await writeGate.started }
        try await waitUntil { textCache.contains(pages[1].translationCacheKey) }
        #expect(textCache.regions(for: pages[1].translationCacheKey)?.first?.translation == "준비된 번역")
        let key = ReaderTranslationCacheIdentity.translation(page: pages[1].translationCacheKey, settings: settings)
        #expect(try await !disk.contains(key, kind: .translation))
        preloader.cancel()
        await writeGate.release()
        try await waitUntil { (try? await disk.contains(key, kind: .translation)) == true }
        #expect(try await disk.regions(for: key, kind: .translation)?.first?.translation == "준비된 번역")
        await demandGate.release()
        _ = try? await demand.value
    }

    @Test(arguments: [false, true])
    func nextLayoutDoesNotWaitForFartherTranslation(overlap: Bool) async throws {
        let gate = LookaheadTestGate()
        var layouts: [Int] = []
        let pages = (0..<3).map { Page(sourceId: "lookahead-unit", chapterId: UUID().uuidString, index: $0) }
        let session = ReaderTranslationSession(process: { page, _, _ in
            if page.index == 2 { await gate.wait() }
            return [ReaderTranslationPersistentPipelineTests.region]
        }, prepareLayout: { page, _, _ in layouts.append(page.index) },
            overlapsLayoutWithTranslation: overlap, availableMemory: { .max })
        defer { session.close(); Task { await gate.release() } }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "test", currentPageIndex: 0)
        session.enable(settings: ReaderTranslationSettings())
        try await waitUntil { await gate.started }
        if overlap { try await waitUntil { layouts.contains(1) } }
        else { #expect(layouts.isEmpty) }
        await gate.release()
        try await waitUntil { layouts.contains(1) }
    }

    @Test func queuedLayoutCancelsBeforeLoadingSourcePixels() async throws {
        let budget = TranslationImageWorkBudget(availableMemory: { .max })
        let gate = LookaheadTestGate()
        let holder = Task { try await budget.withPermit { await gate.wait() } }
        defer { holder.cancel(); Task { await gate.release() } }
        try await waitUntil { await gate.started }
        let imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let page = Page(sourceId: "lookahead-budget", chapterId: "test", index: 0,
                        imageURL: "file:///this-image-must-not-be-loaded.png")
        let reader = ReaderTranslationPage(imageView: imageView); reader.sourcePage = page
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = ReaderTranslationLayoutPreparer(
            renderCache: ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root)), imageBudget: budget)
        let geometry = ReaderTranslationLayoutGeometry(page: reader, imageView: imageView)
        var finished = false
        let task = Task {
            defer { finished = true }
            try await preparer.prepare(page: page, regions: [ReaderTranslationPersistentPipelineTests.region],
                                       settings: ReaderTranslationSettings(), geometry: geometry)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(!finished, "Source loading must wait outside the decoded-image budget")
        task.cancel()
        do { try await task.value; Issue.record("Queued layout should be cancelled") }
        catch { #expect(error is CancellationError) }
    }

    private func waitUntil(seconds: Double = 8, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
private actor LookaheadTestGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
