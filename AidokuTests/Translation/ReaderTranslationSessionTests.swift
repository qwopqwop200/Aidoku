import Testing
import AidokuRunner
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationSessionTests {
    @Test func chapterSweepPersistsDistantPagesWithoutEvictingNearbyText() async throws {
        let fixture = SessionFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let cache = ReaderTranslationSessionCache()
        let pages = (0..<80).map { Aidoku.Page(sourceId: "sweep", chapterId: "chapter", index: $0,
                                             imageURL: "file:///unused-\($0).png") }
        var calls: [Int] = []
        var rendered: [Int] = []
        let session = ReaderTranslationSession(process: { page, _, _ in
            calls.append(page.index)
            return [Self.region]
        }, diskCache: disk, prepareLayout: { page, _, _ in rendered.append(page.index) },
           availableMemory: { UInt64.max }, cache: cache)
        defer { session.close() }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "sweep")
        session.enable(settings: fixture.settings)
        try await waitUntil {
            (try? await disk.translatedRegions(page: pages[79].translationCacheKey, settings: fixture.settings)) != nil
        }
        #expect(calls == Array(0..<80))
        #expect(cache.contains(pages[0].translationCacheKey))
        #expect(!cache.contains(pages[79].translationCacheKey))
        #expect(cache.bytes <= ReaderTranslationSessionCache.byteLimit)
        #expect(rendered.allSatisfy { $0 < 5 })
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "sweep", currentPageIndex: 79)
        session.enable(settings: fixture.settings)
        try await waitUntil { cache.contains(pages[79].translationCacheKey) }
        #expect(calls.count == 80, "A prepared distant page must reopen from disk without repeating OCR/API")
    }

    @Test func pageTurnCancelsDistantInFlightWorkAndStartsDestinationFirst() async throws {
        let fixture = SessionFixture()
        let pages = (0..<16).map { Aidoku.Page(sourceId: "sweep", chapterId: "chapter", index: $0) }
        var calls: [Int] = []
        var cancelled = false
        let session = ReaderTranslationSession(process: { page, _, _ in
            calls.append(page.index)
            if page.index == 6, !cancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled = true; throw error }
            }
            return [Self.region]
        }, availableMemory: { UInt64.max })
        defer { session.close() }
        let items = pages.map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [], context: "sweep")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls.last == 6 }
        session.pauseForPageTurn(preservingRecognitionFor: pages[15])
        session.update(items: items, visible: [], context: "sweep", currentPageIndex: 15)
        try await waitUntil { cancelled && calls.count > 7 }
        #expect(calls[7] == 15)
    }

    @Test func chapterSweepPausesForMemoryAndReprioritizesAfterNavigation() async throws {
        let fixture = SessionFixture()
        let pages = (0..<12).map { Aidoku.Page(sourceId: "sweep", chapterId: "chapter", index: $0) }
        var budget = UInt64.max
        var calls: [Int] = []
        let session = ReaderTranslationSession(process: { page, _, _ in
            calls.append(page.index)
            if calls.count == 6 { budget = 0 }
            return [Self.region]
        }, availableMemory: { budget }, reclaimMemory: {})
        defer { session.close() }
        let items = pages.map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [], context: "sweep")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls.count == 6 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls == Array(0..<6))
        session.pauseForPageTurn()
        budget = UInt64.max
        session.update(items: items, visible: [], context: "sweep", currentPageIndex: 11)
        try await waitUntil { calls.count == 12 }
        #expect(Array(calls.suffix(6)) == [11, 10, 9, 8, 7, 6])
    }


    @Test func scrollBurstCoalescesChapterWorkAndKeepsLatestDestination() async throws {
        let fixture = SessionFixture()
        let pages = (0..<4).map { Self.page($0) }
        let owner = UnindexedChapterOwner(pages: pages, current: 0)
        var settingsReads = 0
        var calls: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            calls.append(page.index)
            return [Self.region]
        }, availableMemory: { UInt64.max })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session, readSettings: {
            settingsReads += 1
            return fixture.settings
        }, setEnabled: { _ in })
        defer { coordinator.close() }
        coordinator.resume()
        let baseline = settingsReads
        for index in 0..<600 {
            owner.page.sourcePage = pages[index % pages.count]
            coordinator.scrollVisibilityDidChange()
        }
        #expect(settingsReads == baseline, "Scroll callbacks must not synchronously load settings or refresh the chapter")
        try await Task.sleep(for: .milliseconds(130))
        #expect(settingsReads > baseline)
        #expect(calls.isEmpty, "The destination still respects OCR navigation debounce")
        let afterFirstRefresh = settingsReads
        for _ in 0..<600 { coordinator.scrollVisibilityDidChange() }
        try await Task.sleep(for: .milliseconds(130))
        #expect(settingsReads == afterFirstRefresh, "An unchanged viewport must not refresh the chapter again")
        try await waitUntil { !calls.isEmpty }
        #expect(calls.first == 3)
        coordinator.suspend()
        let afterSuspend = settingsReads
        coordinator.scrollVisibilityDidChange()
        try await Task.sleep(for: .milliseconds(130))
        #expect(settingsReads == afterSuspend)
    }

    @Test func rapidNavigationStartsCachedLookaheadBeforeOCRDebounce() async throws {
        let fixture = SessionFixture()
        fixture.defaults.set(true, forKey: ReaderTranslationSettings.keyPrefix + "automatic")
        let settings = fixture.settings
        let pages = (0..<12).map { Self.page($0) }
        let owner = UnindexedChapterOwner(pages: pages, current: 0)
        let cache = ReaderTranslationSessionCache()
        try cache.store([Self.region], for: pages[9].translationCacheKey)
        var prepared: [Int] = []
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [] },
            prepareLayout: { page, _, _ in prepared.append(page.index) },
            availableMemory: { .max }, cache: cache)
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { settings }, setEnabled: { _ in })
        defer { coordinator.close() }
        session.enable(settings: settings)
        coordinator.resume()
        owner.page.sourcePage = pages[8]
        let start = ProcessInfo.processInfo.systemUptime
        coordinator.visiblePagesDidChange()
        let deadline = start + 0.25
        while !prepared.contains(9), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(prepared.contains(9), "Cached lookahead must start before the 350ms OCR debounce")
        #expect(calls == 0, "Cache-only navigation must not start OCR or API work")
        print("FAST_SCROLL_CACHED_LOOKAHEAD_MS \( (ProcessInfo.processInfo.systemUptime - start) * 1000)")
    }

    @Test func closingReaderCancelsPendingScrollRefresh() async throws {
        let fixture = SessionFixture()
        let owner = UnindexedChapterOwner(pages: [Self.page(0)], current: 0)
        var reads = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in [] })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session, readSettings: {
            reads += 1
            return fixture.settings
        }, setEnabled: { _ in })
        coordinator.resume()
        coordinator.scrollVisibilityDidChange()
        coordinator.close()
        let baseline = reads
        try await Task.sleep(for: .milliseconds(150))
        #expect(reads == baseline)
    }

    @Test func navigationDebounceOnlyAcceleratesIsolatedAdjacentTurns() {
        var debounce = ReaderTranslationNavigationDebounce()
        #expect(debounce.delay(chapter: "a", index: 0, now: 0) == 350_000_000)
        #expect(debounce.delay(chapter: "a", index: 1, now: 1) == 180_000_000)
        #expect(debounce.delay(chapter: "a", index: 2, now: 1.2) == 350_000_000)
        #expect(debounce.delay(chapter: "a", index: 1, now: 1.4) == 350_000_000)
        #expect(debounce.delay(chapter: "a", index: 8, now: 3) == 350_000_000)
        #expect(debounce.delay(chapter: "b", index: 9, now: 5) == 350_000_000)
        debounce.reset()
        #expect(debounce.delay(chapter: "b", index: 10, now: 7) == 350_000_000)
    }

    @Test func acceleratedPageTurnStillRespectsMemoryAdmission() async throws {
        let fixture = SessionFixture()
        let pages = (0..<3).map { Self.page($0) }
        let owner = UnindexedChapterOwner(pages: pages, current: 0)
        var budget: UInt64 = 600 * 1_024 * 1_024
        var calls: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            calls.append(page.index)
            return [Self.region]
        }, availableMemory: { budget })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { fixture.settings }, setEnabled: { _ in })
        defer { coordinator.close() }
        coordinator.resume()
        try await Task.sleep(for: .milliseconds(750))
        owner.page.sourcePage = pages[1]
        coordinator.visiblePagesDidChange()
        try await Task.sleep(for: .milliseconds(250))
        #expect(calls.isEmpty)
        budget = 2_000 * 1_024 * 1_024
        coordinator.visiblePagesDidChange()
        try await waitUntil { !calls.isEmpty }
        #expect(calls.first == 1)
    }

    @Test func rapidPageTurnsDoNotStartWorkForIntermediatePages() async throws {
        let fixture = SessionFixture()
        let pages = (0..<4).map { Self.page($0) }
        let owner = UnindexedChapterOwner(pages: pages, current: 0)
        var calls: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            calls.append(page.index)
            return [Self.region]
        }, availableMemory: { UInt64.max })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { fixture.settings }, setEnabled: { _ in })
        defer { coordinator.close() }
        coordinator.resume()
        // The first turn precedes the short initial synchronization after open.
        for index in 1...3 {
            if index > 1 { try await Task.sleep(for: .milliseconds(60)) }
            owner.page.sourcePage = pages[index]
            coordinator.visiblePagesDidChange()
        }
        coordinator.visiblePagesDidChange()
        try await Task.sleep(for: .milliseconds(230))
        #expect(calls.isEmpty)
        try await waitUntil { !calls.isEmpty }
        #expect(calls.first == 3)
    }

    @Test func modelAllocationWarningsDoNotCancelTheCurrentPage() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        var budget: UInt64 = 2_000 * 1_024 * 1_024
        var cancellations = 0
        var completions = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            await gate.wait()
            try Task.checkCancellation()
            completions += 1
            return [Self.region]
        }, cancelProcessing: { cancellations += 1 }, availableMemory: { budget })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [], context: "warning")
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started }
        let baseline = cancellations
        budget = 617 * 1_024 * 1_024 // Captured 102nd-page warning headroom.
        for _ in 0..<3 { #expect(!session.handleMemoryWarning()) }
        #expect(cancellations == baseline)
        await gate.release()
        try await waitUntil { completions == 1 }
        #expect(session.state == .on)
        budget = 48 * 1_024 * 1_024
        #expect(session.handleMemoryWarning())
        #expect(cancellations > baseline)
    }

    @Test(arguments: [false, true])
    func redisplayShowsOnlyCompletedTranslationCache(cacheHit: Bool) async throws {
        let fixture = SessionFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let source = Self.page(0)
        let view = UIImageView(image: Self.image())
        let original = ReaderTranslationPage(imageView: view)
        original.sourcePage = source
        var ocr = Self.region
        ocr.translation = nil
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            calls += 1
            throw ReaderTranslationOCRFallback(regions: [ocr],
                underlying: RemoteTranslationError.httpStatus(400, requestID: nil))
        }, diskCache: disk, availableMemory: { UInt64.max })
        defer { session.close() }
        session.update(items: [.init(source)], visible: [original], context: "cache-order")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(original.regions.isEmpty)
        #expect(view.subviews.isEmpty)
        #expect(!original.hasCompletedTranslation(settings: fixture.settings))
        if cacheHit {
            let key = ReaderTranslationCacheIdentity.translation(page: source.translationCacheKey, settings: fixture.settings)
            try await disk.storeRegions([Self.region], for: key, kind: .translation, generation: disk.currentGeneration())
        }
        let replacementView = UIImageView(image: Self.image())
        let replacement = ReaderTranslationPage(imageView: replacementView)
        replacement.sourcePage = source
        session.refreshVisiblePages([replacement])
        // The MainActor has not yielded to the disk read: neither retained OCR
        // nor its overlay may be published before the translation lookup ends.
        #expect(replacement.regions.isEmpty)
        #expect(replacementView.subviews.isEmpty)
        if cacheHit {
            try await waitUntil { replacement.hasCompletedTranslation(settings: fixture.settings) }
        } else {
            try await Task.sleep(for: .milliseconds(100))
            #expect(replacement.regions.isEmpty)
            #expect(replacementView.subviews.isEmpty)
        }
        #expect(replacement.hasCompletedTranslation(settings: fixture.settings) == cacheHit)
        #expect(replacement.regions.first?.translation == (cacheHit ? Self.region.translation : nil))
        #expect(calls == 1)
    }

    @Test func memoryTrimRestoresSamePageAfterItsImageChanges() async throws {
        let fixture = SessionFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let source = Self.page(41)
        let key = ReaderTranslationCacheIdentity.translation(page: source.translationCacheKey, settings: fixture.settings)
        try await disk.storeRegions([Self.region], for: key, kind: .translation, generation: disk.currentGeneration())
        let view = UIImageView(image: Self.image())
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = source
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [] }, diskCache: disk,
            availableMemory: { 659 * 1_024 * 1_024 })
        defer { session.close() }
        session.enable(settings: fixture.settings)
        session.refreshVisiblePages([page])
        try await waitUntil { page.hasCompletedTranslation(settings: fixture.settings) }
        // Same page identity, new decoded UIImage, with no page-turn callback.
        view.image = Self.image()
        #expect(!page.hasCompletedTranslation(settings: fixture.settings))
        #expect(!session.handleMemoryWarning())
        try await waitUntil { page.hasCompletedTranslation(settings: fixture.settings) }
        #expect(!view.subviews.isEmpty)
        #expect(calls == 0)
    }

    @Test func evictedRegionsRestoreWhenCurrentPageImageArrivesLate() async throws {
        let fixture = SessionFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let source = Self.page(24)
        let key = ReaderTranslationCacheIdentity.translation(page: source.translationCacheKey, settings: fixture.settings)
        try await disk.storeRegions([Self.region], for: key, kind: .translation, generation: disk.currentGeneration())
        let view = UIImageView() // Page is visible before its decoded image arrives.
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = source
        let cache = ReaderTranslationSessionCache()
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [] }, diskCache: disk,
            availableMemory: { 659 * 1_024 * 1_024 }, cache: cache)
        defer { session.close() }
        session.enable(settings: fixture.settings)
        session.refreshVisiblePages([page])
        try await waitUntil { cache.contains(source.translationCacheKey) }
        #expect(!page.hasCompletedTranslation(settings: fixture.settings))
        // NSCache eviction does not require our memory-warning handler to run.
        cache.clear()
        view.image = Self.image()
        session.refreshVisiblePages([page]) // Same page key, just like imageChanged.
        try await waitUntil { page.hasCompletedTranslation(settings: fixture.settings) }
        #expect(!view.subviews.isEmpty)
        #expect(calls == 0)
    }

    @Test func lowMemoryDefersNewOCRAndRecoversWithoutTurningOff() async throws {
        let fixture = SessionFixture()
        var budget: UInt64 = 50 * 1_024 * 1_024
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [Self.region] }, availableMemory: { budget })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [], context: "memory")
        session.enable(settings: fixture.settings)
        for _ in 0..<20 { await Task.yield() }
        #expect(calls == 0)
        #expect(session.state == .on)
        budget = 3 * 1_024 * 1_024 * 1_024
        try await waitUntil { calls == 1 }
        #expect(session.state == .on)
    }

    @Test func chapterSweepDoesNotRepeatCompletedPagesAfterNavigation() async throws {
        let fixture = SessionFixture()
        var indices: [Int] = []
        let session = ReaderTranslationSession(process: { page, _, _ in indices.append(page.index); return [Self.region] },
            availableMemory: { UInt64.max })
        defer { session.close() }
        session.update(items: (0..<20).map { .init(Self.page($0)) }, visible: [], context: "bounded", currentPageIndex: 0)
        session.enable(settings: fixture.settings)
        try await waitUntil { indices.count == 20 }
        for _ in 0..<20 { await Task.yield() }
        #expect(indices == Array(0..<20))
        session.update(items: (0..<20).map { .init(Self.page($0)) }, visible: [], context: "bounded", currentPageIndex: 12)
        try await waitUntil { indices.contains(12) }
        #expect(indices.count == 20)
    }

    @Test func visibleDiskCacheRestoresBeforeSettledUpdateWithoutOCR() async throws {
        let fixture = SessionFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let page = Self.page(12)
        let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: fixture.settings)
        try await disk.storeRegions([Self.region], for: key, kind: .translation, generation: disk.currentGeneration())
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = page
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [] }, diskCache: disk,
            availableMemory: { 50 * 1_024 * 1_024 })
        defer { session.close() }
        session.enable(settings: fixture.settings)
        session.pauseForPageTurn()
        // Deliberately never deliver the debounced update: disk restoration must
        // finish independently, and cannot invoke the expensive processor.
        session.refreshVisiblePages([visible])
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls == 0)
        #expect(!view.subviews.isEmpty)
    }

    @Test func movingAwayCancelsCacheRestoreAndCacheMissDoesNotStartOCR() async throws {
        let fixture = SessionFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let old = Self.page(1), next = Self.page(2)
        let key = ReaderTranslationCacheIdentity.translation(page: old.translationCacheKey, settings: fixture.settings)
        try await disk.storeRegions([Self.region], for: key, kind: .translation, generation: disk.currentGeneration())
        let oldView = UIImageView(image: Self.image()), nextView = UIImageView(image: Self.image())
        let oldPage = ReaderTranslationPage(imageView: oldView), nextPage = ReaderTranslationPage(imageView: nextView)
        oldPage.sourcePage = old; nextPage.sourcePage = next
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [] }, diskCache: disk,
            availableMemory: { 50 * 1_024 * 1_024 })
        defer { session.close() }
        session.enable(settings: fixture.settings)
        session.refreshVisiblePages([oldPage])
        session.pauseForPageTurn()
        session.refreshVisiblePages([nextPage])
        // An actor round trip lets queued disk reads run, then yield to their callbacks.
        _ = await disk.currentGeneration()
        for _ in 0..<20 { await Task.yield() }
        #expect(!oldPage.hasCompletedTranslation(settings: fixture.settings))
        #expect(!nextPage.hasCompletedTranslation(settings: fixture.settings))
        #expect(calls == 0)
    }

    @Test func repeatedOffOnReusesVisibleRenderer() async throws {
        let fixture = SessionFixture()
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = Self.page(0)
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [Self.region] })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [visible], context: "toggle")
        session.enable(settings: fixture.settings)
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        let overlay = try #require(view.subviews.first)
        for _ in 0..<40 {
            session.disable(preservingVisibleRendering: true)
            #expect(overlay.isHidden)
            session.enable(settings: fixture.settings)
            #expect(view.subviews.count == 1)
            #expect(view.subviews.first === overlay)
            #expect(!overlay.isHidden)
        }
        #expect(calls == 1)
    }

    @Test(arguments: [true, false])
    func repeatedOffOnKeepsOriginalWhileTranslationIsPending(applySettingsChange: Bool) async throws {
        let fixture = SessionFixture()
        fixture.defaults.set(true, forKey: ReaderTranslationSettings.keyPrefix + "automatic")
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = Self.page(0)
        var ocr = Self.region
        ocr.translation = nil
        let preview = [ocr]
        var progressCount = 0
        let session = ReaderTranslationSession(process: { _, _, progress in
            try await progress?(preview)
            progressCount += 1
            // Keep translation pending while the user rapidly toggles it.
            try await Task.sleep(for: .seconds(30))
            return [Self.region]
        }, availableMemory: { UInt64.max })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [visible], context: "ocr-toggle")
        session.enable(settings: fixture.settings)
        try await waitUntil { progressCount == 1 }
        #expect(view.subviews.isEmpty)
        for attempt in 1...4 {
            session.disable(preservingVisibleRendering: true)
            #expect(view.subviews.isEmpty)
            if applySettingsChange {
                fixture.defaults.set(false, forKey: ReaderTranslationSettings.keyPrefix + "automatic")
                visible.applySettings(fixture.settings)
                fixture.defaults.set(true, forKey: ReaderTranslationSettings.keyPrefix + "automatic")
                visible.applySettings(fixture.settings)
            }
            session.enable(settings: fixture.settings)
            try await waitUntil { progressCount == attempt + 1 }
            #expect(view.subviews.isEmpty)
            #expect(visible.regions.isEmpty)
            #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
            #expect(!visible.canExportTranslation)
        }
    }

    @Test(arguments: [false, true])
    func repeatedBitmapPresentationRestoresHiddenCanvas(loadedImage: Bool) async throws {
        let fixture = SessionFixture()
        let view = UIImageView(image: Self.image())
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = Self.page(0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { page.reset(); try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        page.renderCache = cache
        let settings = fixture.settings
        let prepared = ReaderTranslationPreparedImage(image: Self.image(), regions: [Self.region], settings: settings)
        if !loadedImage {
            try await seedBitmap(prepared.image, page: page, view: view, cache: cache, settings: settings)
        }
        func display() {
            if loadedImage { page.displayLoadedImage(prepared) }
            else { page.displayPreparedSnapshot([Self.region], settings: settings, memoryOnly: true) }
        }
        display()
        let canvas = try #require(view.subviews.first)
        for _ in 0..<4 {
            page.hidePreparedTranslation()
            #expect(canvas.isHidden)
            display()
            #expect(view.subviews.first === canvas)
            #expect(!canvas.isHidden)
        }
    }

    @Test(arguments: [false, true])
    func geometryChangeWhileHiddenDoesNotRevealTranslation(bitmap: Bool) async throws {
        let fixture = SessionFixture()
        let view = UIImageView(image: Self.image())
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = Self.page(0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { page.reset(); try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        page.renderCache = cache
        let settings = fixture.settings
        if bitmap { try await seedBitmap(Self.image(), page: page, view: view, cache: cache, settings: settings) }
        page.displayPrepared([Self.region], settings: settings)
        #expect(page.isUsingCachedRendering == bitmap)
        page.hidePreparedTranslation()
        view.bounds.size = CGSize(width: 320, height: 480)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        for child in view.subviews { child.setNeedsLayout(); child.layoutIfNeeded() }
        #expect(view.subviews.allSatisfy { $0.isHidden }, "Resizing while OFF must not publish a visible replacement")
        page.showCompletedTranslation(settings: settings)
        #expect(view.subviews.contains { !$0.isHidden })
        #expect(page.hasCompletedTranslation(settings: settings))
    }

    private func seedBitmap(_ image: UIImage, page: ReaderTranslationPage, view: UIImageView,
                            cache: ReaderTranslationRenderCache, settings: ReaderTranslationSettings) async throws {
        let source = try #require(page.sourcePage)
        let original = try #require(view.image)
        cache.setNearbyPages(pageKeys: [source.translationCacheKey], settings: settings, availableMemory: .max)
        let key = ReaderTranslationCacheIdentity.render(page: source.translationCacheKey, settings: settings,
            imageSize: original.size, viewport: view.bounds.size, scale: view.traitCollection.displayScale,
            aspectFit: view.contentMode == .scaleAspectFit, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
            dark: view.traitCollection.userInterfaceStyle == .dark)
        await cache.store(image, key: key,
            pageIdentity: ReaderTranslationCacheIdentity.translation(page: source.translationCacheKey, settings: settings),
            diskGeneration: 0)
    }

    @Test func stackedAndAdjacentCaptionsRemainDistinctCases() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [:]
        for number in [1, 2, 3, 6] {
            guard let image = UIImage(contentsOfFile: root.appendingPathComponent("stacked-source-\(number).png").path)?.cgImage else { continue }
            let regions = try await ReaderOCRService.shared.recognize(image: image, tier: .small)
            let relevant = regions.filter { number == 6 ? $0.rect.midX > 0.25 : (number == 2 ? $0.rect.midX > 0.2 : $0.rect.midX > 0.35) }
            #expect(relevant.count == (number <= 2 ? 2 : 1), "Stacked caption fixture \(number)")
            report[String(number)] = regions.map { ["source": $0.source, "x": $0.rect.minX, "y": $0.rect.minY,
                "width": $0.rect.width, "height": $0.rect.height] as [String: Any] }
        }
        if !report.isEmpty { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("stacked-results.json")) }
    }

    @Test func independentCaptionColumnsOnDevice() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [:]
        for number in 1...5 {
            guard let image = UIImage(contentsOfFile: root.appendingPathComponent("gutter-source-\(number).png").path)?.cgImage else { continue }
            let regions = try await ReaderOCRService.shared.recognize(image: image, tier: .small)
            let relevant = regions.filter { number != 4 || $0.rect.midX > 0.2 }
            report[String(number)] = regions.map { ["text": $0.source, "x": $0.rect.minX, "width": $0.rect.width] as [String: Any] }
            #expect(relevant.count == 2, "Caption fixture \(number) must retain its independent columns")
        }
        if !report.isEmpty {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("gutter-results.json"))
        }
    }

    @Test func capturedColumnSpacingDiagnostics() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [:]
        let pipeline = NativeCoreMLOCRPipeline(modelTier: .small, detectorMaximumSide: 1600, recognizerMaximumWidth: 1024)
        for number in [1, 3, 5] {
            let path = root.appendingPathComponent("spacing-source-\(number).png")
            guard let image = UIImage(contentsOfFile: path.path)?.cgImage else { continue }
            let raw = try await pipeline.recognize(image: image, requestID: UUID().uuidString, confidenceThreshold: 0.3)
            let merged = NativeOCRTextLineMerger.merge(raw.lines, imageWidth: image.width, imageHeight: image.height)
            let final = try await ReaderOCRService.shared.recognize(image: image, tier: .small)
            if number == 3 || number == 5 {
                #expect(merged.count == 2)
                #expect(final.count == 2)
            }
            if number == 1 {
                #expect(merged.contains { $0.boundingRect.minY < 30 && $0.boundingRect.maxY > 330 })
                #expect(final.contains { $0.rect.minY < 0.1 && $0.rect.maxY > 0.85 })
            }
            report[String(number)] = ["finalCount": final.count, "raw": raw.lines.map { l in
                ["text": l.text, "polygon": l.polygon.map { [$0.x, $0.y] }] as [String: Any]
            }, "merged": merged.map(\.text)]
        }
        await pipeline.purgeResources()
        if !report.isEmpty {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("spacing-diagnostics.json"))
        }
    }

    @Test func capturedColourCaptionOCRDiagnostics() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var all: [String: Any] = [:]
        for number in [42, 43, 44, 47] {
            let path = root.appendingPathComponent("merge-source-\(number).png")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let image = try #require(UIImage(contentsOfFile: path.path)?.cgImage)
            let crop = try #require(image.cropping(to: CGRect(x: 0, y: CGFloat(image.height) * 0.327,
                width: CGFloat(image.width), height: CGFloat(image.height) * 0.346)))
            let regions = try await ReaderOCRService.shared.recognize(image: crop, tier: .small)
            all[String(number)] = regions.map { r -> [String: Any] in
                let pixelRect = CGRect(x: r.rect.minX * CGFloat(crop.width), y: r.rect.minY * CGFloat(crop.height), width: r.rect.width * CGFloat(crop.width), height: r.rect.height * CGFloat(crop.height))
                let ink = ReaderTranslationBalloonMerger.outlinedInk(in: crop, rect: pixelRect)
                return ["ink": ink.map { [$0.0, $0.1, $0.2] } ?? [], "source": r.source, "x": r.rect.minX, "y": r.rect.minY, "width": r.rect.width,
                 "height": r.rect.height, "single": r.sourceSingleVerticalColumn ?? false]
            }
            #expect(!regions.isEmpty)
            if number == 44 {
                let purple = try #require(regions.first { $0.rect.midX > 0.68 && $0.rect.midX < 0.72 })
                let orange = try #require(regions.first { $0.rect.midX > 0.72 && $0.rect.midX < 0.76 })
                #expect(purple.rect.maxX < orange.rect.minX)
                #expect(purple.rect.width < 0.05 && orange.rect.width < 0.05)
            }
            if number == 47 {
                #expect(regions.contains { $0.source.contains("パン屋") && !$0.source.contains("でも私") })
                #expect(regions.contains { $0.source.contains("でも私") && !$0.source.contains("パン屋") })
            }
            if number == 43 {
                #expect(regions.contains { $0.source.contains("アタシ") && !$0.source.contains("それで") })
                #expect(regions.contains { $0.source.contains("それで") && !$0.source.contains("アタシ") })
                #expect(!regions.contains { $0.source.contains("ごめんな") && $0.source.contains("マリ") })
            }
        }
        if !all.isEmpty {
            try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("merge-caption-result.json"))
        }
    }

    @Test func visibleRenderingDoesNotWaitForSpeculativeSnapshot() async throws {
        let disk = ReaderTranslationDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let cache = ReaderTranslationRenderCache(disk: disk)
        let gate = SessionGate()
        let preparation = Task { try await cache.prepare("pending") { await gate.wait() } }
        try await waitUntil { await gate.started }
        var released = false
        let release = Task {
            try? await Task.sleep(for: .milliseconds(300))
            released = true
            await gate.release()
        }
        #expect(await cache.load("pending") == nil)
        #expect(!released)
        await release.value
        _ = try? await preparation.value
    }

    @Test func exhaustedRetriesShowNoticeAndManualRetryRecovers() async throws {
        let fixture = SessionFixture()
        fixture.defaults.set(true, forKey: ReaderTranslationSettings.keyPrefix + "automatic")
        let source = Self.page(0)
        let imageView = UIImageView(image: Self.image())
        let page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = source
        let owner = SessionToolbarOwner()
        owner.translationUpcomingPages = [source]
        owner.translationVisiblePages = [page]
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = owner
        window.isHidden = false
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            calls += 1
            if calls <= 3 {
                throw ReaderTranslationOCRFallback(regions: [Self.region],
                    underlying: RemoteTranslationError.httpStatus(503, requestID: nil))
            }
            return [Self.region]
        }, availableMemory: { UInt64.max })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { fixture.settings }, setEnabled: { _ in })
        defer { coordinator.close(); window.isHidden = true }
        coordinator.install()
        coordinator.resume()
        try await waitUntil { calls == 1 }
        #expect(!owner.view.subviews.contains { $0.accessibilityIdentifier == "reader.translation.failure" })
        try await waitUntil { calls == 2 }
        #expect(!owner.view.subviews.contains { $0.accessibilityIdentifier == "reader.translation.failure" })
        try await waitUntil { owner.view.subviews.contains { $0.accessibilityIdentifier == "reader.translation.failure" } }
        #expect(calls == 3)
        let notice = try #require(owner.view.subviews.first { $0.accessibilityIdentifier == "reader.translation.failure" } as? UIVisualEffectView)
        let stack = try #require(notice.contentView.subviews.first as? UIStackView)
        let label = try #require(stack.arrangedSubviews.first as? UILabel)
        #expect(label.text == NSLocalizedString("TRANSLATION_TITLE") + ": " +
            RemoteTranslationError.httpStatus(503, requestID: nil).localizedDescription)
        let toggle = try #require(owner.navigationItem.rightBarButtonItems?.first {
            $0.accessibilityIdentifier == "reader.translation.toggle"
        })
        #expect(toggle.accessibilityHint == RemoteTranslationError.httpStatus(503, requestID: nil).localizedDescription)
        #expect(page.regions.isEmpty)
        #expect(imageView.subviews.isEmpty)
        let retry = try #require(stack.arrangedSubviews.last as? UIButton)
        retry.sendActions(for: .touchUpInside)
        try await waitUntil { page.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls == 4)
        #expect(notice.superview == nil)
        #expect(toggle.accessibilityHint == nil)
        #expect(fixture.settings.automaticallyTranslate)
        // Notices must also disappear immediately when the reader leaves.
        session.onFailure?(RemoteTranslationError.missingCredential)
        #expect(owner.view.subviews.contains { $0.accessibilityIdentifier == "reader.translation.failure" })
        coordinator.suspend()
        #expect(!owner.view.subviews.contains { $0.accessibilityIdentifier == "reader.translation.failure" })
    }

    @Test func transientTransportFailureRecoversWithoutAnotherPageTurn() async throws {
        let fixture = SessionFixture()
        let source = Self.page(0)
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = source
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            calls += 1
            if calls == 1 {
                throw ReaderTranslationOCRFallback(regions: [Self.region], underlying: RemoteTranslationError.transport(.timedOut))
            }
            return [Self.region]
        })
        defer { session.close() }
        session.update(items: [.init(source)], visible: [visible], context: "retry")
        session.enable(settings: fixture.settings)
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls == 2)
        #expect(session.state == .on)
    }

    @Test(arguments: [408, 429, 500, 503])
    func apiRetryKeepsOriginalBeforeFailureNotification(status: Int) async throws {
        let fixture = SessionFixture()
        let source = Self.page(0)
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = source
        var calls = 0
        var failures = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            calls += 1
            if calls == 1 {
                var untranslated = Self.region
                untranslated.translation = nil
                throw ReaderTranslationOCRFallback(regions: [untranslated],
                    underlying: RemoteTranslationError.httpStatus(status, requestID: nil))
            }
            return [Self.region]
        })
        defer { session.close() }
        session.onFailure = { _ in failures += 1 }
        session.update(items: [.init(source)], visible: [visible], context: "http-retry")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(visible.regions.isEmpty)
        #expect(view.subviews.isEmpty)
        #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
        #expect(!visible.canExportTranslation)
        let replacement = ReaderTranslationPage(imageView: view)
        replacement.sourcePage = source
        session.refreshVisiblePages([replacement])
        #expect(replacement.regions.isEmpty)
        #expect(view.subviews.isEmpty)
        #expect(failures == 0)
        try await waitUntil { replacement.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls == 2)
        #expect(failures == 0)
    }

    @Test func failedPageRetriesWhenVisibilityArrivesAfterPageIndex() async throws {
        let fixture = SessionFixture()
        let source = Self.page(0)
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = source
        var calls = 0
        var failures = 0
        var offline = true
        let session = ReaderTranslationSession(process: { _, _, _ in
            calls += 1
            if offline {
                throw ReaderTranslationOCRFallback(regions: [Self.region], underlying: URLError(.notConnectedToInternet))
            }
            return [Self.region]
        })
        defer { session.close() }
        session.onFailure = { _ in failures += 1 }
        let items = [ReaderTranslationSession.Item(source)]
        session.update(items: items, visible: [visible], context: "revisit", currentPageIndex: 0)
        session.enable(settings: fixture.settings)
        try await waitUntil { failures == 1 }
        #expect(calls == 3)
        #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
        session.pauseForPageTurn()
        session.update(items: items, visible: [], context: "revisit", currentPageIndex: 1)
        // Index updates first, without a loaded view. This must not consume the retry demand.
        session.update(items: items, visible: [], context: "revisit", currentPageIndex: 0)
        offline = false
        session.refreshVisiblePages([visible])
        session.update(items: items, visible: [visible], context: "revisit", currentPageIndex: 0)
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls == 4)
        #expect(session.state == .on)
    }

    @Test func leavingPageCancelsPendingAPIRetry() async throws {
        let fixture = SessionFixture()
        let source = Self.page(0)
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = source
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            calls += 1
            var untranslated = Self.region
            untranslated.translation = nil
            throw ReaderTranslationOCRFallback(regions: [untranslated], underlying: URLError(.timedOut))
        })
        defer { session.close() }
        session.update(items: [.init(source)], visible: [visible], context: "cancel-retry")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 1 }
        try await Task.sleep(for: .milliseconds(100))
        session.pauseForPageTurn()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(calls == 1)
        #expect(visible.regions.isEmpty)
        #expect(view.subviews.isEmpty)
    }

    @Test func persistentOfflineFailureHasBoundedRetries() async throws {
        let fixture = SessionFixture()
        let source = Self.page(0)
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = source
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in
            calls += 1
            var ocr = Self.region
            ocr.translation = nil
            throw ReaderTranslationOCRFallback(regions: [ocr], underlying: URLError(.notConnectedToInternet))
        })
        defer { session.close() }
        session.update(items: [.init(source)], visible: [visible], context: "offline")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 3 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls == 3)
        #expect(session.state == .on)
        #expect(visible.regions.isEmpty)
        #expect(view.subviews.isEmpty)
        #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
    }

    @Test func cancelledBase64DecodeDoesNotPublishAnImage() async throws {
        let store = ReaderTemporaryPageStore()
        let view = ReaderPageView(temporaryPageStore: store)
        let encoded = try #require(Self.image().pngData()).base64EncodedString()
        let task = Task { await view.setPageImage(base64: encoded, key: UUID().hashValue) }
        task.cancel()
        #expect(await task.value == false)
        #expect(view.imageView.image == nil)
        await store.removeAll()
    }

    @Test func splitPagesPersistWithoutDecodedImagesAndReloadWithIdentity() async throws {
        let store = ReaderTemporaryPageStore()
        var left = Self.page(0)
        left.translationOriginalKey = "original"
        left.translationSourceRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        var right = left
        right.translationSourceRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let stored = try #require(await store.storeSplitPages([left, right], chapterKey: "split-test", pageIndex: 0))
        #expect(stored.allSatisfy { $0.image == nil })
        #expect(stored.map(\.translationSourceRect) == [left.translationSourceRect, right.translationSourceRect])
        #expect(stored.map(\.translationOriginalKey) == ["original", "original"])
        let controller = ReaderPageViewController(type: .page, delegate: nil, temporaryPageStore: store)
        controller.setPage(stored[0])
        try await waitUntil { controller.pageView?.imageView.image != nil }
        #expect(controller.pageView?.imageView.image?.cgImage?.width == left.image?.cgImage?.width)
        #expect(controller.pageView?.imageView.image?.cgImage?.height == left.image?.cgImage?.height)
        controller.clearPage()
        await store.removeAll()
    }

    @Test func sliderScrubbingDefersWorkAndRestartsAtFinalDestination() async throws {
        let fixture = SessionFixture()
        let pages = (0..<12).map { Self.page($0) }
        let owner = UnindexedChapterOwner(pages: pages, current: 0)
        var calls: [Int] = []
        let session = ReaderTranslationSession(process: { page, _, _ in
            calls.append(page.index)
            return [Self.region]
        })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { fixture.settings }, setEnabled: { _ in })
        defer { coordinator.close() }
        coordinator.resume()
        for index in [9, 2, 11, 4, 8] {
            coordinator.sliderInteractionBegan()
            owner.page.sourcePage = pages[index]
            coordinator.visiblePagesDidChange()
        }
        try await Task.sleep(for: .milliseconds(450))
        #expect(calls.isEmpty)
        coordinator.sliderInteractionEnded()
        try await waitUntil { owner.page.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls.first == 8)
        #expect(session.state == .on)
    }

    @Test func clearingPageCancelsPendingLoadAndAllowsImmediateReload() async throws {
        let controller = ReaderPageViewController(type: .page, delegate: nil,
            temporaryPageStore: ReaderTemporaryPageStore())
        let page = Self.page(0)
        controller.setPage(page)
        controller.clearPage()
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.page == nil)
        #expect(controller.pageView?.imageView.image == nil)
        controller.setPage(page)
        try await waitUntil { controller.pageView?.imageView.image != nil }
        controller.clearPage()
        #expect(controller.pageView?.imageView.image == nil)
        #expect(controller.pageView?.translationPage.sourcePage == nil)
    }

    @Test func realSourceAdapterPagesPrepareNeighborsWithoutAnyPageTurn() async throws {
        let fixture = SessionFixture()
        let pages = (0..<8).map { index in
            AidokuRunner.Page(content: .url(url: URL(string: "https://example.invalid/page-\(index).png")!, context: nil),
                              hasDescription: false, description: nil)
                .toOld(sourceId: "test", chapterId: "chapter", language: nil)
        }
        // This is how the actual source adapter constructs pages; the legacy index is always zero.
        #expect(pages.allSatisfy { $0.index == 0 })
        let owner = UnindexedChapterOwner(pages: pages, current: 3)
        #expect(owner.translationCurrentPageIndex == 3)
        var prepared: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            prepared.append(pages.firstIndex { $0.imageURL == page.imageURL }!)
            return [Self.region]
        })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session, readSettings: { fixture.settings }, setEnabled: { _ in })
        coordinator.install()
        coordinator.resume()
        defer { coordinator.close() }
        try await waitUntil { prepared.count == 8 }
        #expect(prepared == [3, 4, 2, 5, 1, 6, 0, 7])
        #expect(session.state == .on)
        #expect(owner.translationVisiblePages.first?.hasCompletedTranslation(settings: fixture.settings) == true)
        // Ordering must not invalidate already persisted page identities.
        #expect(ReaderTranslationSession.chapterItems(pages).map(\.key) == pages.map(\.translationCacheKey))
    }

    @Test(arguments: [false, true])
    func partialTranslationStaysHiddenAfterFailureAndVisibleRefresh(transient: Bool) async throws {
        let fixture = SessionFixture()
        let imageView = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: imageView)
        visible.sourcePage = Self.page(0)
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, progress in
            calls += 1
            try await progress?([Self.region])
            throw ReaderTranslationOCRFallback(regions: [Self.region], underlying: transient
                ? RemoteTranslationError.transport(.timedOut) : RemoteTranslationError.missingCredential)
        }, availableMemory: { UInt64.max })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [visible], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 1 }
        try await Task.sleep(for: .milliseconds(30))
        session.refreshVisiblePages([visible])
        #expect(session.state == .on)
        #expect(visible.regions.isEmpty)
        #expect(imageView.subviews.isEmpty)
        #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
    }

    @Test func partialResultsAreNotCachedAsCompleteAndLateProgressCannotRestoreAnOverlay() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        let imageView = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: imageView)
        visible.sourcePage = Self.page(0)
        var calls = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, progress in
            calls += 1
            var pending = Self.region
            pending.translation = nil
            try await progress?([pending])
            #expect(imageView.subviews.isEmpty)
            #expect(visible.regions.isEmpty)
            #expect(visible.regions.first?.translation == nil)
            #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
            try await progress?([Self.region])
            await gate.wait()
            var final = Self.region
            final.translation = "완료"
            try await progress?([final])
            return [final]
        })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [visible], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started }
        #expect(visible.regions.isEmpty)
        // Translated progress is shown provisionally, never as a completed page.
        try await waitUntil { visible.isShowingProvisionalTranslation }
        #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
        #expect(!visible.canExportTranslation)
        session.disable()
        #expect(imageView.subviews.isEmpty)
        #expect(!visible.isShowingProvisionalTranslation)
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(imageView.subviews.isEmpty)
        #expect(visible.regions.isEmpty)
        #expect(imageView.subviews.isEmpty)
        session.enable(settings: fixture.settings)
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls == 2)
        #expect(visible.regions.first?.translation == "완료")
    }

    @Test func visiblePagePreemptsOffscreenWorkAndRejectsItsLateResult() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        let firstImage = UIImageView(image: Self.image())
        let secondImage = UIImageView(image: Self.image())
        let first = ReaderTranslationPage(imageView: firstImage)
        let second = ReaderTranslationPage(imageView: secondImage)
        first.sourcePage = Self.page(0)
        second.sourcePage = Self.page(1)
        var indices: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, progress in
            indices.append(page.index)
            if indices.count == 1 {
                try await progress?([Self.region])
                await gate.wait()
                var stale = Self.region
                stale.translation = "늦은 응답"
                try await progress?([stale])
                return [stale]
            }
            return [Self.region]
        })
        defer { session.close() }
        let items = [Self.page(0), Self.page(1)].map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [first], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started }
        session.update(items: items, visible: [second], context: "chapter")
        try await waitUntil { second.hasCompletedTranslation(settings: fixture.settings) }
        #expect(Array(indices.prefix(2)) == [0, 1])
        #expect(firstImage.subviews.isEmpty)
        #expect(second.regions.first?.translation == "안녕")
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        session.update(items: items, visible: [first], context: "chapter")
        #expect(first.hasCompletedTranslation(settings: fixture.settings))
        #expect(first.regions.first?.translation == "안녕")
        #expect(indices == [0, 1, 0])
    }

    @Test func probeGatesActivationThenPreparesTheWholeChapterWithSavedEffort() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        var settings = fixture.settings
        settings.reasoningEffort = .high
        var indices: [Int] = []
        var efforts: [OpenAIReasoningEffort] = []
        let session = ReaderTranslationSession(validate: { _ in await gate.wait() }, process: { page, settings, _ in
            indices.append(page.index)
            efforts.append(settings.reasoningEffort)
            return [Self.region]
        })
        defer { session.close() }
        let pages = (0..<8).map { Self.page($0) }
        let imageView = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: imageView)
        visible.sourcePage = pages[2]
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [visible], context: "chapter")
        session.enable(settings: settings)
        try await waitUntil { await gate.started }
        #expect(session.state == .checking)
        #expect(indices.isEmpty)
        await gate.release()
        try await waitUntil { indices.count == 8 }
        #expect(session.state == .on)
        #expect(indices == [2, 3, 1, 4, 0, 5, 6, 7])
        #expect(efforts.allSatisfy { $0 == .high })
        #expect(visible.regions.first?.translation == "안녕")
        session.disable()
        #expect(imageView.subviews.allSatisfy { $0.isHidden })
        session.enable(settings: settings)
        try await waitUntil { session.state == .on }
        #expect(indices.count == 8)
        #expect(imageView.subviews.contains { !$0.isHidden })
    }

    @Test func cancellationRejectsLateProbeAndLateTranslation() async throws {
        for cancelDuringProbe in [true, false] {
            let gate = SessionGate()
            let fixture = SessionFixture()
            var calls = 0
            var cancellations = 0
            let session = ReaderTranslationSession(validate: { _ in
                if cancelDuringProbe { await gate.wait() }
            }, process: { _, _, _ in
                calls += 1
                await gate.wait()
                return [Self.region]
            }, cancelProcessing: { cancellations += 1 })
            let imageView = UIImageView(image: Self.image())
            let visible = ReaderTranslationPage(imageView: imageView)
            visible.sourcePage = Self.page(0)
            session.update(items: [Self.page(0), Self.page(1)].map(ReaderTranslationSession.Item.init), visible: [visible], context: "chapter")
            session.enable(settings: fixture.settings)
            try await waitUntil { await gate.started }
            session.close()
            await gate.release()
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(session.state == .off)
            #expect(calls == (cancelDuringProbe ? 0 : 1))
            #expect(cancellations > 0)
            #expect(visible.regions.isEmpty)
            #expect(imageView.subviews.isEmpty)
        }
    }

    @Test func nextChapterCancelsOldWorkAndNewReaderHasIndependentCache() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        var finished: [String] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            if page.chapterId == "old" { await gate.wait() }
            finished.append(page.chapterId)
            return [Self.region]
        })
        defer { session.close() }
        session.update(items: [.init(Self.page(0, chapter: "old"))], visible: [], context: "old")
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started }
        session.update(items: [.init(Self.page(0, chapter: "new")), .init(Self.page(1, chapter: "new"))], visible: [], context: "new")
        try await waitUntil { finished.count == 2 }
        #expect(finished == ["new", "new"])
        await gate.release()
        session.close()
        var newCalls = 0
        let newSession = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in newCalls += 1; return [Self.region] })
        defer { newSession.close() }
        newSession.update(items: [.init(Self.page(0, chapter: "new"))], visible: [], context: "new")
        newSession.enable(settings: fixture.settings)
        try await waitUntil { newCalls == 1 }
    }

    @Test func pageTurnPauseCancelsOldWorkAndRestartsFromNewAnchor() async throws {
        let fixture = SessionFixture()
        let gate = SessionGate()
        var calls: [Int] = []
        var cancellations = 0
        let session = ReaderTranslationSession(process: { page, _, _ in
            calls.append(page.index)
            if calls.count == 1 { await gate.wait() }
            return [Self.region]
        }, cancelProcessing: { cancellations += 1 })
        defer { session.close() }
        let items = (0..<8).map { ReaderTranslationSession.Item(Self.page($0)) }
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started }
        session.pauseForPageTurn()
        let before = calls.count
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.count == before)
        #expect(session.state == .on)
        #expect(cancellations > 0)
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 6)
        try await waitUntil { calls.count > before }
        #expect(calls[before] == 6)
        await gate.release()
    }

    @Test func resourcePressureAndOCRFallbackKeepAutomaticTranslationOn() async throws {
        let fixture = SessionFixture()
        var calls = 0
        var failures = 0
        var states: [ReaderTranslationSession.State] = []
        let session = ReaderTranslationSession(process: { _, _, _ in
            calls += 1
            throw ReaderTranslationOCRFallback(regions: [Self.region], underlying: URLError(.notConnectedToInternet))
        })
        defer { session.close() }
        session.onFailure = { _ in failures += 1 }
        session.onStateChanged = { states.append($0) }
        session.update(items: (0..<3).map { .init(Self.page($0)) }, visible: [], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 3 }
        #expect(session.state == .on)
        #expect(failures == 1)
        states.removeAll()
        session.suspendWorkForResourcePressure()
        session.update(items: [.init(Self.page(4))], visible: [], context: "chapter", currentPageIndex: 4)
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 4 }
        #expect(session.state == .on)
        #expect(states.isEmpty)
    }

    @Test func failedProbeOrAPIStopsWorkButBrokenImagesAreSkipped() async throws {
        let fixture = SessionFixture()
        for failureAtProbe in [true, false] {
            var calls = 0
            var errors = 0
            let session = ReaderTranslationSession(validate: { _ in
                if failureAtProbe { throw RemoteTranslationError.missingCredential }
            }, process: { page, _, _ in
                calls += 1
                if page.index == 0 { throw URLError(.cannotDecodeContentData) }
                throw RemoteTranslationError.httpStatus(401, requestID: nil)
            })
            defer { session.close() }
            session.onFailure = { _ in errors += 1 }
            session.update(items: (0..<4).map { .init(Self.page($0)) }, visible: [], context: "chapter")
            session.enable(settings: fixture.settings)
            try await waitUntil { errors == 1 }
            if !failureAtProbe { try await waitUntil { calls == 4 } }
            #expect(session.state == (failureAtProbe ? .off : .on))
            #expect(calls == (failureAtProbe ? 0 : 4))
        }
    }

    @Test(arguments: [true, false])
    func failuresPreserveAutomaticPreferenceAndUserCanStillDisable(failureAtProbe: Bool) async throws {
        let fixture = SessionFixture()
        fixture.defaults.set(true, forKey: ReaderTranslationSettings.keyPrefix + "automatic")
        var shouldFail = true
        var failures = 0
        let session = ReaderTranslationSession(validate: { _ in
            if shouldFail && failureAtProbe { throw URLError(.timedOut) }
        }, process: { _, _, _ in
            if shouldFail { throw RemoteTranslationError.httpStatus(500, requestID: nil) }
            return []
        })
        let owner = SessionToolbarOwner()
        let coordinator = ReaderTranslationCoordinator(
            owner: owner, session: session, readSettings: { fixture.settings },
            setEnabled: { fixture.defaults.set($0, forKey: ReaderTranslationSettings.keyPrefix + "automatic") }
        )
        coordinator.install()
        let handleFailure = session.onFailure
        session.onFailure = { error in handleFailure?(error); failures += 1 }
        defer { coordinator.close() }
        session.update(items: [.init(Self.page(0))], visible: [], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { failures == 1 }
        #expect(session.state == (failureAtProbe ? .off : .on))
        #expect(fixture.settings.automaticallyTranslate)
        shouldFail = false
        session.enable(settings: fixture.settings)
        try await waitUntil { session.state == .on }
        coordinator.toggle()
        #expect(!fixture.settings.automaticallyTranslate)
        #expect(session.state == .off)
    }

    @Test func displayChangesReuseResultsButLanguageChangeRetranslates() async throws {
        let fixture = SessionFixture()
        var settings = fixture.settings
        var calls = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in calls += 1; return [Self.region] })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [], context: "chapter")
        session.enable(settings: settings)
        try await waitUntil { calls == 1 }
        settings.overlay.opacity = 0.6
        session.enable(settings: settings)
        #expect(calls == 1)
        settings.targetLanguage = "ja"
        session.enable(settings: settings)
        try await waitUntil { calls == 2 }
    }

    @Test func readerHasOneOnOffButtonAndNoMenu() async throws {
        let owner = SessionToolbarOwner()
        owner.navigationItem.title = "Chapter 1"
        owner.navigationItem.leftBarButtonItems = [
            UIBarButtonItem(systemItem: .close), UIBarButtonItem(image: UIImage(systemName: "list.bullet"))
        ]
        owner.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "safari")), UIBarButtonItem(image: UIImage(systemName: "textformat.size"))
        ]
        let fixture = SessionFixture()
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in [] })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session, readSettings: { fixture.settings }, setEnabled: { _ in })
        coordinator.install()
        defer { coordinator.close() }
        let buttons = try #require(owner.navigationItem.rightBarButtonItems)
        #expect(buttons.count == 3)
        #expect(buttons.allSatisfy { $0.title == nil && $0.image != nil && $0.menu == nil })
        if #available(iOS 26.0, *) { #expect(buttons.allSatisfy { $0.sharesBackground }) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: owner)
        navigation.navigationBar.tintColor = .white
        window.rootViewController = navigation
        window.overrideUserInterfaceStyle = .dark
        owner.view.backgroundColor = .black
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKey() }
        session.enable(settings: fixture.settings)
        try await waitUntil { session.state == .on }
        #expect(buttons.last?.accessibilityValue == NSLocalizedString("TRANSLATION_STATE_ON"))
        let directory = URL.documentsDirectory.appendingPathComponent("TranslationValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in ["on", "off"] {
            if state == "off" { coordinator.toggle() }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(image.pngData()).write(to: directory.appendingPathComponent("reader-translation-\(state).png"))
        }
        #expect(buttons.last?.accessibilityValue == NSLocalizedString("TRANSLATION_STATE_OFF"))
    }

    @Test func transientVisibilityDoesNotRemoveRenderedTextBeforeNavigationSettles() async throws {
        let fixture = SessionFixture()
        let imageView = UIImageView(image: Self.image())
        let first = ReaderTranslationPage(imageView: imageView)
        first.sourcePage = Self.page(0)
        let session = ReaderTranslationSession(process: { _, _, _ in [Self.region] })
        defer { session.close() }
        let items = [ReaderTranslationSession.Item(Self.page(0))]
        session.update(items: items, visible: [first], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { first.hasCompletedTranslation(settings: fixture.settings) }
        let overlay = try #require(imageView.subviews.first)
        for _ in 0..<20 {
            session.pauseForPageTurn()
            session.refreshVisiblePages([])
            #expect(overlay.superview === imageView)
            session.refreshVisiblePages([first])
            #expect(imageView.subviews.first === overlay)
        }
        session.update(items: items, visible: [], context: "chapter")
        #expect(imageView.subviews.isEmpty)
        session.update(items: items, visible: [first], context: "chapter")
        #expect(!imageView.subviews.isEmpty)
    }

    @Test func rapidVisibilityRefreshRetainsOnlyIncomingAndOutgoingOverlays() {
        let fixture = SessionFixture()
        let views = (0..<12).map { _ in UIImageView(image: Self.image()) }
        let pages = views.enumerated().map { index, view in
            let page = ReaderTranslationPage(imageView: view)
            page.sourcePage = Self.page(index)
            return page
        }
        let session = ReaderTranslationSession(process: { _, _, _ in [] })
        defer { session.close() }
        for page in pages {
            page.displayPrepared([Self.region], settings: fixture.settings)
            session.refreshVisiblePages([page])
            #expect(views.filter { !$0.subviews.isEmpty }.count <= 2)
        }
    }

    @Test func memoryWarningPreservesVisibleCompletedOverlay() async throws {
        let fixture = SessionFixture()
        let imageView = UIImageView(image: Self.image())
        let page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = Self.page(0)
        let session = ReaderTranslationSession(process: { _, _, _ in [Self.region] })
        defer { session.close() }
        let items = [ReaderTranslationSession.Item(Self.page(0))]
        session.update(items: items, visible: [page], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { page.hasCompletedTranslation(settings: fixture.settings) }
        let overlay = try #require(imageView.subviews.first)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        session.suspendWorkForResourcePressure()
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.state == .on)
        #expect(page.hasCompletedTranslation(settings: fixture.settings))
        #expect(imageView.subviews.first === overlay)
        session.update(items: items, visible: [page], context: "chapter")
        #expect(imageView.subviews.first === overlay)
    }

    @Test func leavingPagesReleasesOverlaysAndReturningReusesTranslation() async throws {
        let fixture = SessionFixture()
        let firstImage = UIImageView(image: Self.image())
        let secondImage = UIImageView(image: Self.image())
        let first = ReaderTranslationPage(imageView: firstImage)
        let second = ReaderTranslationPage(imageView: secondImage)
        first.sourcePage = Self.page(0)
        second.sourcePage = Self.page(1)
        var calls = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in calls += 1; return [Self.region] })
        defer { session.close() }
        let items = [Self.page(0), Self.page(1)].map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [first], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { calls == 2 && !firstImage.subviews.isEmpty }
        session.update(items: items, visible: [second], context: "chapter")
        #expect(firstImage.subviews.isEmpty)
        #expect(!secondImage.subviews.isEmpty)
        first.applySettings(fixture.settings)
        #expect(firstImage.subviews.isEmpty)
        session.update(items: items, visible: [first], context: "chapter")
        #expect(!firstImage.subviews.isEmpty)
        #expect(secondImage.subviews.isEmpty)
        #expect(calls == 2)
        session.disable()
        #expect(firstImage.subviews.isEmpty && secondImage.subviews.isEmpty)
    }

    @Test func emptyTranslationDoesNotAllocateAnOverlay() {
        let fixture = SessionFixture()
        let imageView = UIImageView(image: Self.image())
        let page = ReaderTranslationPage(imageView: imageView)
        page.displayPrepared([], settings: fixture.settings)
        #expect(page.hasCompletedTranslation(settings: fixture.settings))
        #expect(imageView.subviews.isEmpty)
        page.showCompletedTranslation(settings: fixture.settings)
        #expect(imageView.subviews.isEmpty)
    }

    @Test func temporaryCacheRoundTripsAndSplitPagesMapBoxes() throws {
        let cache = ReaderTranslationSessionCache()
        try cache.store([Self.region], for: "key")
        let restored = try #require(cache.regions(for: "key")?.first)
        #expect(restored.source == Self.region.source)
        #expect(restored.translation == Self.region.translation)
        #expect(restored.rect == Self.region.rect)
        let left = try #require(restored.cropped(to: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        #expect(left.rect.minX == 0.2)
        #expect(abs(left.rect.width - 0.4) < 0.000001)
        #expect(restored.cropped(to: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)) == nil)
        cache.clear()
        #expect(!cache.contains("key"))
        #expect(cache.regions(for: "key") == nil)
    }

    @Test func hiddenPreloaderRunsRealOCRForUnvisitedImageWithoutOverlay() async throws {
        let fixture = SessionFixture()
        let preloader = ReaderTranslationPreloader(translator: { regions, _, _ in
            regions.map { var region = $0; region.translation = "미리 번역"; return region }
        })
        let result = try await preloader.translate(Self.page(0), settings: fixture.settings)
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0.translation == "미리 번역" })
        preloader.cancel()
        await ReaderOCRService.shared.purge()
    }

    // MARK: Provisional (streamed) display

    private func visibleView(_ page: ReaderTranslationPage) -> UIView? { page.imageView?.subviews.first }

    private static func translated(_ text: String) -> ReaderTranslationRegion {
        var region = region
        region.translation = text
        return region
    }

    @Test func streamedProgressShowsOnlyOnVisiblePageAndFinalReplacesIt() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        let visibleView = UIImageView(image: Self.image())
        let offscreenView = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: visibleView)
        let offscreen = ReaderTranslationPage(imageView: offscreenView)
        visible.sourcePage = Self.page(0)
        offscreen.sourcePage = Self.page(1)
        let second = ReaderTranslationRegion(id: "second", rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), source: "World")
        var offscreenProgress = false
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, progress in
            var pendingSecond = second
            pendingSecond.translation = nil
            if page.index == 1 {
                try await progress?([Self.translated("미리"), pendingSecond])
                offscreenProgress = true
                return [Self.translated("미리")]
            }
            try await progress?([Self.translated("스트림"), pendingSecond])
            await gate.wait()
            var finalSecond = second
            finalSecond.translation = "세계"
            return [Self.translated("안녕"), finalSecond]
        }, availableMemory: { UInt64.max })
        defer { session.close() }
        session.update(items: [Self.page(0), Self.page(1)].map(ReaderTranslationSession.Item.init), visible: [visible], context: "stream")
        session.enable(settings: fixture.settings)
        try await waitUntil { visible.isShowingProvisionalTranslation }
        let overlay = try #require(visibleView.subviews.first as? ReaderTranslationOverlayView)
        // Live rendering only: no snapshot target, so no render/layout cache writes.
        #expect(!overlay.canCacheRendering)
        #expect(visible.regions.isEmpty) // Untranslated regions and export state are untouched.
        #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
        await gate.release()
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        #expect(!visible.isShowingProvisionalTranslation)
        #expect(visible.regions.map(\.translation) == ["안녕", "세계"])
        #expect(visibleView.subviews.count == 1)
        try await waitUntil { offscreenProgress }
        #expect(offscreenView.subviews.isEmpty)
        #expect(!offscreen.isShowingProvisionalTranslation)
    }

    @Test func streamedProgressIsThrottled() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        let view = UIImageView(image: Self.image())
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = Self.page(0)
        var published = false
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, progress in
            for index in 0..<20 { try await progress?([Self.translated("부분 \(index)")]) }
            published = true
            await gate.wait()
            return [Self.region]
        }, availableMemory: { UInt64.max })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [visible], context: "throttle")
        session.enable(settings: fixture.settings)
        try await waitUntil { published && visible.isShowingProvisionalTranslation }
        try await Task.sleep(for: .milliseconds(50))
        // Twenty snapshots in one burst produce at most the leading render and one trailing render.
        #expect(visible.provisionalRenderCount <= 2)
        await gate.release()
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        #expect(visible.regions.first?.translation == "안녕")
    }

    @Test func provisionalRenderingNeverWritesCaches() async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let renderCache = ReaderTranslationRenderCache(disk: disk)
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        view.image = Self.image()
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = Self.page(0)
        visible.renderCache = renderCache
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, progress in
            try await progress?([Self.translated("임시")])
            await gate.wait()
            return [Self.region]
        }, diskCache: disk, renderCache: renderCache, availableMemory: { UInt64.max })
        defer { session.close() }
        session.update(items: [.init(Self.page(0))], visible: [visible], context: "nocache")
        #expect(try await disk.statistics().entries == 0)
        session.enable(settings: fixture.settings)
        try await waitUntil { visible.isShowingProvisionalTranslation }
        try await Task.sleep(for: .milliseconds(300))
        // No translation, layout, snapshot or image-size record from a provisional render.
        #expect(try await disk.statistics().entries == 0)
        #expect((visibleView(visible) as? ReaderTranslationOverlayView)?.canCacheRendering == false)
        #expect(try await disk.translatedRegions(page: Self.page(0).translationCacheKey, settings: fixture.settings) == nil)
        await gate.release()
        try await waitUntil { visible.hasCompletedTranslation(settings: fixture.settings) }
        #expect(visible.regions.first?.translation == "안녕")
    }

    @Test(arguments: [false, true])
    func cancelledOrFailedStreamRemovesProvisionalText(fails: Bool) async throws {
        let gate = SessionGate()
        let fixture = SessionFixture()
        let firstView = UIImageView(image: Self.image())
        let secondView = UIImageView(image: Self.image())
        let first = ReaderTranslationPage(imageView: firstView)
        let second = ReaderTranslationPage(imageView: secondView)
        first.sourcePage = Self.page(0)
        second.sourcePage = Self.page(1)
        var lateProgress: ReaderTranslationService.Progress?
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, progress in
            guard page.index == 0 else { return [Self.region] }
            lateProgress = progress
            try await progress?([Self.translated("중간")])
            await gate.wait()
            if fails { throw RemoteTranslationError.refused }
            try await Task.sleep(for: .seconds(30))
            return [Self.region]
        }, availableMemory: { UInt64.max })
        defer { session.close() }
        let items = [Self.page(0), Self.page(1)].map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [first], context: "cancel")
        session.enable(settings: fixture.settings)
        try await waitUntil { first.isShowingProvisionalTranslation }
        if fails {
            await gate.release()
        } else {
            session.pauseForPageTurn()
            session.update(items: items, visible: [second], context: "cancel", currentPageIndex: 1)
        }
        try await waitUntil { !first.isShowingProvisionalTranslation && firstView.subviews.isEmpty }
        // A stale stream callback after cancellation cannot bring the text back.
        try? await lateProgress?([Self.translated("늦음")])
        try await Task.sleep(for: .milliseconds(300))
        #expect(firstView.subviews.isEmpty)
        #expect(!first.hasCompletedTranslation(settings: fixture.settings))
        await gate.release()
    }

    static var region: ReaderTranslationRegion {
        .init(id: "line", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), source: "Hello", translation: "안녕")
    }
    static func page(_ index: Int, chapter: String = "chapter") -> Aidoku.Page {
        Aidoku.Page(sourceId: "unit-test", chapterId: chapter, index: index, image: image())
    }
    static func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            ("HELLO WORLD" as NSString).draw(at: CGPoint(x: 50, y: 90),
                                             withAttributes: [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black])
        }
    }
    @Test(arguments: [false, true])
    func readyBitmapDisplaysSynchronouslyDuringNavigation(scroll: Bool) async throws {
        let fixture = SessionFixture()
        fixture.defaults.set(true, forKey: ReaderTranslationSettings.keyPrefix + "automatic")
        let settings = fixture.settings
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderCache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        let textCache = ReaderTranslationSessionCache()
        var heavyWork = 0
        let session = ReaderTranslationSession(process: { _, _, _ in heavyWork += 1; return [] },
            renderCache: renderCache, availableMemory: { 0 }, cache: textCache)
        let owner = SessionToolbarOwner()
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { settings }, setEnabled: { _ in })
        defer { coordinator.close() }
        session.enable(settings: settings)
        try await waitUntil { session.state == .on }
        let source = Self.page(0), image = Self.image()
        let view = UIImageView(image: image)
        view.bounds.size = CGSize(width: 320, height: 480)
        view.contentMode = .scaleAspectFit
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = source
        let snapshot = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
            UIColor.white.setFill(); context.fill(view.bounds)
            ("즉시 표시된 번역" as NSString).draw(at: CGPoint(x: 20, y: 80),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
        }
        try textCache.store([Self.region], for: source.translationCacheKey)
        renderCache.setNearbyPages(pageKeys: [source.translationCacheKey], settings: settings, availableMemory: .max)
        let key = ReaderTranslationCacheIdentity.render(page: source.translationCacheKey, settings: settings,
            imageSize: image.size, viewport: view.bounds.size, scale: view.traitCollection.displayScale,
            aspectFit: true, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
            dark: view.traitCollection.userInterfaceStyle == .dark)
        await renderCache.store(snapshot, key: key,
            pageIdentity: ReaderTranslationCacheIdentity.translation(page: source.translationCacheKey, settings: settings), diskGeneration: 0)
        coordinator.resume() // Leave the normal delayed synchronization pending.
        owner.translationUpcomingPages = [source]; owner.translationVisiblePages = [page]
        let start = ProcessInfo.processInfo.systemUptime
        if scroll { coordinator.scrollVisibilityDidChange() } else { coordinator.visiblePagesDidChange() }
        // No suspension/yield: the cached pixels must already be mounted.
        #expect(page.isUsingCachedRendering)
        #expect((view.subviews.first as? UIImageView)?.image === snapshot)
        #expect(!view.subviews.contains { $0 is ReaderTranslationOverlayView })
        #expect(heavyWork == 0)
        print("READY_BITMAP_SYNC_MS scroll=\(scroll) ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        // A scroll fast-path miss must leave the source alone, even while the
        // 80ms coalesced refresh is pending and the heavy-work budget is zero.
        if scroll {
            let missing = Self.page(1)
            let missingView = UIImageView(image: image); missingView.frame = view.frame
            let missingPage = ReaderTranslationPage(imageView: missingView); missingPage.sourcePage = missing
            try textCache.store([Self.region], for: missing.translationCacheKey)
            owner.translationVisiblePages = [missingPage]
            coordinator.scrollVisibilityDidChange()
            #expect(missingView.subviews.isEmpty)
            #expect(heavyWork == 0)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await condition()) {
            if Date() > deadline { throw SessionTestError.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum SessionTestError: Error { case timeout }
@MainActor private final class SessionToolbarOwner: UIViewController, ReaderTranslationOwner {
    var translationUpcomingPages: [Aidoku.Page] = []
    var translationVisiblePages: [ReaderTranslationPage] = []
    let translationChapterKey = "chapter"
}
@MainActor private final class SessionFixture {
    let suite = "AidokuTests.Session.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    var settings: ReaderTranslationSettings { ReaderTranslationSettings(defaults: defaults) }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}
private actor SessionGate {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0; started = true }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor private final class UnindexedChapterOwner: UIViewController, ReaderTranslationOwner {
    let translationUpcomingPages: [Aidoku.Page]
    let translationChapterKey = "chapter"
    private let imageView = UIImageView(image: ReaderTranslationSessionTests.image())
    let page: ReaderTranslationPage
    var translationVisiblePages: [ReaderTranslationPage] { [page] }

    init(pages: [Aidoku.Page], current: Int) {
        translationUpcomingPages = pages
        page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = pages[current]
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
