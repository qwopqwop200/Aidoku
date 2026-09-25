import AidokuRunner
import AsyncDisplayKit
import Testing
import UIKit
import Vision
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationPersistentPipelineTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("ReportedCurrentPage/source.png").path)))
    func reportedWebtoonCurrentPageRestoresAfterCancelledPrerenders() async throws {
        let fixture = URL.documentsDirectory.appendingPathComponent("ReportedCurrentPage")
        let source = try #require(UIImage(contentsOfFile: fixture.appendingPathComponent("source.png").path))
        let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
            from: Data(contentsOf: fixture.appendingPathComponent("regions.json"))).map(\.region)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let store = ReaderTemporaryPageStore()
        let controller = ReaderWebtoonViewController(source: nil,
            manga: .init(sourceKey: "reported", key: "current", title: "Current page"), temporaryPageStore: store)
        controller.readingMode = .webtoon
        let chapter = AidokuRunner.Chapter(key: UUID().uuidString)
        let pages = (0..<24).map { index in
            var page = Page(sourceId: "reported", chapterId: chapter.key, index: index)
            page.image = source
            return page
        }
        controller.viewModel.preloadedChapter = chapter
        controller.viewModel.preloadedPages = pages
        let owner = CurrentWebtoonTestOwner(controller: controller, pages: pages)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache)
        var settings = ReaderTranslationSettings()
        settings.overlay = try JSONDecoder().decode(IPhoneOverlaySettings.self,
            from: Data(contentsOf: fixture.appendingPathComponent("overlay.json")))
        settings.automaticallyTranslate = true; settings.overlay.visible = true
        settings.targetLanguage = "ko"; settings.rightToLeftPanelOrder = false
        for page in pages {
            try await disk.storeRegions(regions,
                for: ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings),
                kind: .translation, generation: 0)
        }
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return regions },
            diskCache: disk, renderCache: cache, prepareLayout: { page, regions, settings in
                guard let visible = controller.translationPages().first, let view = visible.imageView else { return }
                try await preparer.prepare(page: page, regions: regions, settings: settings,
                    geometry: ReaderTranslationLayoutGeometry(page: visible, imageView: view), window: window)
            }, availableMemory: { UInt64.max })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { settings }, setEnabled: { _ in })
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            coordinator.close(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            Task { await store.removeAll(); try? await disk.clear(); try? FileManager.default.removeItem(at: root) }
        }
        controller.setChapter(chapter, startPage: 1); coordinator.resume()
        try await waitUntil { !controller.translationPages().isEmpty }
        for destination in [1, 2, 3, 4, 5, 6, 5, 4, 3, 4, 5, 6] {
            let path = IndexPath(item: destination + 1, section: 0)
            let attributes = try #require(controller.collectionNode.collectionViewLayout.layoutAttributesForItem(at: path))
            controller.scrollView.setContentOffset(CGPoint(x: 0, y: attributes.frame.minY - 100), animated: false)
            controller.view.layoutIfNeeded(); coordinator.visiblePagesDidChange()
            if let node = controller.collectionNode.nodeForItem(at: path) as? ReaderWebtoonPageNode,
               let view = node.imageNode.imageView, view.image != nil, view.window === window,
               view.convert(view.bounds, to: window).intersects(window.bounds) {
                #expect(controller.translationPages().contains { $0.sourcePage?.index == destination },
                        "A displayed webtoon image must remain a translation demand even before Texture visibility catches up")
            }
            try await Task.sleep(for: .milliseconds(230))
        }
        try await waitUntil {
            controller.translationPages().contains { $0.sourcePage?.index == 6 && $0.isUsingCachedRendering }
        }
        #expect(calls == 0, "Already translated current page must not invoke OCR/provider")
        let directory = URL.documentsDirectory.appendingPathComponent("AuditWebtoon")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let label = "mode-707-cached"
        let screen = directory.appendingPathComponent(label + "-external-screen.png")
        try? FileManager.default.removeItem(at: screen)
        try await Task.sleep(for: .seconds(1))
        try Data(label.utf8).write(to: directory.appendingPathComponent("capture-ready"), options: .atomic)
        let deadline = Date().addingTimeInterval(40)
        while !FileManager.default.fileExists(atPath: screen.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let pixels = try #require(UIImage(contentsOfFile: screen.path)?.cgImage)
        let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["ko-KR", "ja-JP"]
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().filter { !$0.isWhitespace }
        print("REPORTED_CURRENT_PAGE_SCREEN=\(text)")
        #expect(text.contains("컨디션") && text.contains("눈동자"), "Current page must visibly contain cached Korean translations")
    }

    @Test func pagedReaderExposesLaidOutNeighborsBeforeTransition() throws {
        let pager = ReaderPagedViewController(source: nil,
            manga: .init(sourceKey: "preview-test", key: UUID().uuidString, title: "Preview"),
            temporaryPageStore: ReaderTemporaryPageStore())
        pager.loadViewIfNeeded()
        pager.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        pager.view.layoutIfNeeded()
        let uiPager = try #require(pager.children.compactMap { $0 as? UIPageViewController }.first)
        let fixture = PersistentFixture()
        let controllers = (0..<3).map { index in
            let controller = ReaderPageViewController(type: .page, delegate: nil, temporaryPageStore: ReaderTemporaryPageStore())
            controller.pageView?.setPageImage(Self.image())
            controller.pageView?.translationPage.sourcePage = fixture.page(index)
            return controller
        }
        pager.pageViewControllers = controllers
        uiPager.setViewControllers([controllers[1]], direction: .forward, animated: false)
        let previews = pager.translationPreviewPages()
        #expect(previews.count == 2)
        #expect(previews.map { $0.sourcePage?.index } == [0, 2])
        #expect(previews.allSatisfy { ($0.imageView?.bounds.width ?? 0) > 0 && ($0.imageView?.bounds.height ?? 0) > 0 })
        #expect(pager.translationPages().first === controllers[1].pageView?.translationPage)
    }

    @Test func neighboringCompositesAreMountedBeforeDraggingAndSurviveCancelledSwipe() async throws {
        let fixture = PersistentFixture()
        let pages = (0..<3).map { fixture.page($0) }
        for page in pages {
            let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: fixture.settings)
            try await fixture.disk.storeRegions([Self.region], for: key, kind: .translation, generation: 0)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        scroll.contentSize = CGSize(width: 1170, height: 800)
        scroll.contentOffset.x = 390
        root.view.addSubview(scroll)
        let controllers = pages.enumerated().map { index, page in
            let controller = ReaderPageViewController(type: .page, delegate: nil, temporaryPageStore: ReaderTemporaryPageStore())
            root.addChild(controller)
            controller.view.frame = CGRect(x: CGFloat(index) * 390, y: 0, width: 390, height: 800)
            scroll.addSubview(controller.view); controller.didMove(toParent: root)
            controller.pageView?.setPageImage(page.image)
            controller.view.layoutIfNeeded()
            controller.pageView?.fixImageSize(); controller.pageView?.layoutIfNeeded()
            controller.pageView?.translationPage.sourcePage = page
            return controller
        }
        let readers = try controllers.map { try #require($0.pageView?.translationPage) }
        let imageView = try #require(controllers[1].pageView?.imageView)
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache)
        var calls = 0
        let session = ReaderTranslationSession(process: { _, _, _ in calls += 1; return [] }, diskCache: fixture.disk,
            renderCache: cache, prepareLayout: { page, regions, settings in
                try await preparer.prepare(page: page, regions: regions, settings: settings,
                    geometry: .init(page: readers[1], imageView: imageView), window: window)
            })
        defer { session.close() }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [readers[1]], context: "swipe", currentPageIndex: 1)
        session.refreshVisiblePages([readers[1]], previews: [readers[0], readers[2]])
        session.enable(settings: fixture.settings)
        try await waitUntil { readers.allSatisfy(\.isUsingCachedRendering) }
        let incoming = try #require(controllers[2].pageView?.imageView.subviews.first)
        #expect(incoming.accessibilityIdentifier == "reader.translation.cachedOverlay")
        #expect(calls == 0)
        // Expose a quarter of the next page without a page-index change or a
        // didFinishAnimating callback. It must already contain translated pixels.
        scroll.contentOffset.x = 487.5
        scroll.layoutIfNeeded()
        #expect(controllers[2].pageView?.imageView.subviews.first === incoming)
        #expect(readers[2].isUsingCachedRendering)
        #expect(controllers.allSatisfy { $0.pageView?.imageView.subviews.contains { $0 is ReaderTranslationOverlayView } == false })
        let screenshot = UIGraphicsImageRenderer(bounds: scroll.bounds).image { _ in
            scroll.drawHierarchy(in: scroll.bounds, afterScreenUpdates: true)
        }
        let directory = URL.documentsDirectory.appendingPathComponent("TranslationValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(screenshot.pngData()).write(to: directory.appendingPathComponent("swipe-preview-quarter.png"))
        scroll.contentOffset.x = 390 // Cancel the gesture.
        session.refreshVisiblePages([readers[1]], previews: [readers[0], readers[2]])
        #expect(controllers[2].pageView?.imageView.subviews.first === incoming)
        session.pauseForPageTurn(preservingRecognitionFor: pages[2])
        session.refreshVisiblePages([readers[2]], previews: [readers[1]])
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [readers[2]], context: "swipe", currentPageIndex: 2)
        #expect(readers[2].isUsingCachedRendering)
        #expect(controllers[2].pageView?.imageView.subviews.first === incoming)
        #expect(calls == 0)
    }

    @Test func previewCacheMissDoesNotStartWebKitOrCancelPrerender() async throws {
        let fixture = PersistentFixture()
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        let view = UIImageView(image: Self.image())
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = fixture.page(1); page.renderCache = cache
        let key = ReaderTranslationCacheIdentity.render(page: fixture.page(1).translationCacheKey, settings: fixture.settings,
            imageSize: Self.image().size, viewport: view.bounds.size, scale: view.traitCollection.displayScale,
            aspectFit: false, crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: view.traitCollection.userInterfaceStyle == .dark)
        let gate = PersistentLayoutGate()
        var wasCancelled = false
        let task = Task { try await cache.prepare(key) { await gate.wait(); wasCancelled = Task.isCancelled } }
        defer { task.cancel(); page.reset(); Task { await gate.release() } }
        try await waitUntil { await gate.started }
        page.displayPreparedSnapshot([Self.region], settings: fixture.settings)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.subviews.isEmpty)
        #expect(!page.hasCompletedTranslation(settings: fixture.settings))
        await gate.release()
        try await task.value
        #expect(!wasCancelled)
    }

    @Test func failedTranslationKeepsOriginalAndToggleOn() async throws {
        let fixture = PersistentFixture()
        let sourcePage = fixture.page(0)
        let image = Self.image()
        let view = UIImageView(image: image)
        let visible = ReaderTranslationPage(imageView: view)
        visible.sourcePage = sourcePage
        var raw = Self.region
        raw.translation = nil
        let fallback = raw
        var notices = 0
        var retryDelays: [UInt64] = []
        let session = ReaderTranslationSession(process: { _, _, _ in
            throw ReaderTranslationOCRFallback(regions: [fallback], underlying: URLError(.timedOut))
        }, diskCache: fixture.disk, waitForAPIRetry: { delay in
            retryDelays.append(delay)
            await Task.yield()
            try Task.checkCancellation()
        })
        defer { session.close() }
        session.onFailure = { _ in notices += 1 }
        session.update(items: [.init(sourcePage)], visible: [visible], context: "fallback")
        session.enable(settings: fixture.settings)
        try await waitUntil { notices == 1 }
        #expect(retryDelays == [1_000_000_000, 3_000_000_000])
        #expect(session.state == .on)
        #expect(visible.regions.isEmpty)
        #expect(view.image === image)
        #expect(view.subviews.isEmpty)
        #expect(!visible.hasCompletedTranslation(settings: fixture.settings))
        #expect(!visible.canExportTranslation)
        #expect(try await fixture.disk.translatedRegions(page: sourcePage.translationCacheKey, settings: fixture.settings) == nil)
    }

    @Test func preparationFansOutToBothChapterEndsAndReprioritizes() {
        let pages = (0..<8).map { Aidoku.Page(sourceId: "test", chapterId: "chapter", index: $0) }
        let items = pages.map(ReaderTranslationSession.Item.init)
        #expect(ReaderTranslationSession.ordered(items, anchor: 3).map(\.page.index) == [3, 4, 2, 5, 1, 6, 0, 7])
        #expect(ReaderTranslationSession.ordered(items, anchor: 0).map(\.page.index) == Array(0..<8))
        #expect(ReaderTranslationSession.ordered(items, anchor: 7).map(\.page.index) == Array((0..<8).reversed()))
        #expect(ReaderTranslationSession.ordered(items, anchor: 5).map(\.page.index) == [5, 6, 4, 7, 3, 2, 1, 0])
    }

    @Test func aNewReaderUsesSavedTranslationsWithoutCallingOCRorTheAPI() async throws {
        let fixture = PersistentFixture()
        let pages = (0..<5).map { fixture.page($0) }
        var calls: [Int] = []
        let first = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in calls.append(page.index); return [Self.region] },
                                             diskCache: fixture.disk)
        first.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [], context: "chapter", currentPageIndex: 2)
        first.enable(settings: fixture.settings)
        let lastKey = ReaderTranslationCacheIdentity.translation(page: pages[0].translationCacheKey, settings: fixture.settings)
        try await waitUntil { try await fixture.disk.regions(for: lastKey, kind: .translation) != nil }
        #expect(calls == [2, 3, 1, 4, 0])
        first.close()
        let reopened = ReaderTranslationDiskCache(directory: fixture.root)
        var newCalls = 0
        let imageView = UIImageView(image: Self.image())
        let page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = pages[2]
        let second = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in newCalls += 1; return [] }, diskCache: reopened)
        defer { second.close() }
        second.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [page], context: "chapter")
        second.enable(settings: fixture.settings)
        try await waitUntil { page.hasCompletedTranslation(settings: fixture.settings) }
        #expect(page.regions.first?.translation == Self.region.translation)
        #expect(newCalls == 0)
    }

    @Test func OCRIsSavedBeforeAnAPIFailureAndReusedAfterRestart() async throws {
        let fixture = PersistentFixture()
        let page = fixture.page(0)
        let first = ReaderTranslationPreloader(diskCache: fixture.disk, translator: { _, _, _ in throw PersistentTestError.api })
        do {
            _ = try await first.translate(page, settings: fixture.settings)
            Issue.record("Expected OCR fallback")
        } catch let fallback as ReaderTranslationOCRFallback {
            #expect(!fallback.regions.isEmpty)
            #expect(fallback.regions.allSatisfy { $0.translation == nil })
        }
        let translationKey = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: fixture.settings)
        #expect(try await fixture.disk.regions(for: translationKey, kind: .translation) == nil)
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: fixture.settings)
        let saved = try #require(try await fixture.disk.regions(for: key, kind: .ocr))
        #expect(!saved.isEmpty)
        var withoutImage = page
        withoutImage.image = nil // A miss would fail loading; an OCR hit needs no image/network.
        var changed = fixture.settings
        changed.targetLanguage = "en"
        let reopened = ReaderTranslationDiskCache(directory: fixture.root)
        let second = ReaderTranslationPreloader(diskCache: reopened, translator: { regions, _, _ in
            regions.map { var region = $0; region.translation = "cached OCR"; return region }
        })
        let result = try await second.translate(withoutImage, settings: changed)
        #expect(result.map(\.source) == saved.map(\.source))
        #expect(result.allSatisfy { $0.translation == "cached OCR" })
        await ReaderOCRService.shared.purge()
    }

    @Test func newlyVisibleWebtoonPageStartsProcessingWithoutAnchorChange() async throws {
        let fixture = PersistentFixture()
        let views = (0..<2).map { _ in UIImageView(image: Self.image()) }
        // ReaderTranslationPage deliberately holds its view weakly. A Release
        // build can otherwise end these unattached views' lifetimes after map().
        defer { withExtendedLifetime(views) {} }
        let visible = views.enumerated().map { index, view in
            let page = ReaderTranslationPage(imageView: view)
            page.sourcePage = fixture.page(index)
            return page
        }
        var processed: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            processed.append(page.index)
            return [Self.region]
        }, availableMemory: { UInt64.max })
        defer { session.close() }
        session.update(items: [.init(fixture.page(0))], visible: [visible[0]], context: "webtoon", currentPageIndex: 0)
        session.enable(settings: fixture.settings)
        try await waitUntil { visible[0].hasCompletedTranslation(settings: fixture.settings) }
        // The leading page remains current while the next page enters the viewport.
        session.update(items: [fixture.page(0), fixture.page(1)].map(ReaderTranslationSession.Item.init),
                       visible: visible, context: "webtoon", currentPageIndex: 0)
        try await waitUntil { visible[1].hasCompletedTranslation(settings: fixture.settings) }
        #expect(processed == [0, 1])
        #expect(visible.allSatisfy { $0.regions.first?.translation == Self.region.translation })
    }

    @Test func fractionalWebtoonGeometryDoesNotRestartRendering() async throws {
        let fixture = PersistentFixture()
        let viewport = CGSize(width: 430, height: 430 * 1440 / 1020)
        let overlay = ReaderTranslationOverlayView()
        overlay.bounds.size = CGSize(width: viewport.width, height: viewport.height.nextUp)
        var invalidations = 0
        overlay.onCacheGeometryChanged = { invalidations += 1 }
        overlay.update(regions: [Self.region], imageSize: Self.image().size, aspectFit: true,
                       settings: fixture.settings,
                       snapshotTarget: .init(cache: ReaderTranslationRenderCache(disk: fixture.disk),
                                             key: "fractional", pageIdentity: "fractional", diskGeneration: 0,
                                             viewport: viewport, dark: overlay.traitCollection.userInterfaceStyle == .dark))
        for _ in 0..<5 { overlay.setNeedsLayout(); overlay.layoutIfNeeded() }
        #expect(invalidations == 0)
        overlay.bounds.size.height += 1
        overlay.setNeedsLayout()
        overlay.layoutIfNeeded()
        #expect(invalidations == 1)
    }

    @Test func reusedWebtoonOverlayRecoversFromStaleViewport() async throws {
        let fixture = PersistentFixture()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let imageView = UIImageView(image: Self.image())
        imageView.frame = CGRect(x: 0, y: 100, width: 430, height: 430 * 1440 / 1020)
        imageView.contentMode = .scaleAspectFit
        controller.view.addSubview(imageView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = fixture.page(0)
        page.renderCache = ReaderTranslationRenderCache(disk: fixture.disk)
        page.displayPrepared([Self.region], settings: fixture.settings)
        try await waitUntil { imageView.subviews.contains { $0 is ReaderTranslationOverlayView } }
        let overlay = try #require(imageView.subviews.compactMap { $0 as? ReaderTranslationOverlayView }.first)
        // Simulate an existing cell overlay retaining its old viewport during reuse.
        overlay.bounds.size = CGSize(width: 320, height: 450)
        overlay.setNeedsLayout()
        overlay.layoutIfNeeded()
        try await waitUntil { page.isUsingCachedRendering }
        #expect(ReaderTranslationGeometry.sameViewport(overlay.bounds.size, imageView.bounds.size))
        let canvas = try #require(imageView.subviews.first)
        canvas.bounds.size.height = canvas.bounds.height.nextUp
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        #expect(page.isUsingCachedRendering)
        page.reset()
    }

    @Test(arguments: [false, true]) func nearbyBitmapIsInstantAndRestartReusesSavedLayout(dark: Bool) async throws {
        let fixture = PersistentFixture()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let source = Self.image()
        let imageView = UIImageView(image: source)
        imageView.frame = CGRect(x: 0, y: 100, width: 320, height: 600)
        imageView.contentMode = .scaleAspectFit
        controller.view.addSubview(imageView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        let page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = fixture.page(0)
        page.renderCache = cache
        page.displayPrepared([Self.region], settings: fixture.settings)
        let key = ReaderTranslationCacheIdentity.render(page: fixture.page(0).translationCacheKey, settings: fixture.settings,
                                                        imageSize: source.size, viewport: imageView.bounds.size,
                                                        scale: imageView.traitCollection.displayScale, aspectFit: true,
                                                        crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: dark)
        let displayed = [Self.region].compactMap { $0.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let layoutKey = ReaderTranslationRenderCache.layoutKey(renderKey: key, regions: displayed)
        try await waitUntil {
            imageView.layoutIfNeeded()
            return cache.cachedImage(for: key) != nil
        }
        try await waitUntil { page.isUsingCachedRendering }
        #expect(!imageView.subviews.contains { $0 is ReaderTranslationOverlayView })
        #expect(try await fixture.disk.data(for: layoutKey, kind: .layout) != nil)
        #expect(cache.cachedLayout(for: layoutKey) != nil, "Visible rendering must promote its saved layout into memory")
        page.releaseOverlay()
        let began = ProcessInfo.processInfo.systemUptime
        page.showCompletedTranslation(settings: fixture.settings)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        print("TRANSLATION_CACHED_PAGE_MAIN_SECONDS=\(elapsed)")
        #expect(elapsed < 0.05)
        #expect(page.isUsingCachedRendering)
        #expect(!imageView.subviews.contains { $0 is ReaderTranslationOverlayView })
        #expect(imageView.image === source)
        page.showOriginal()
        #expect(imageView.subviews.isEmpty)
        let reopenedCache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: fixture.root))
        let restored = ReaderTranslationPage(imageView: imageView)
        restored.sourcePage = fixture.page(0)
        restored.renderCache = reopenedCache
        restored.displayPrepared([Self.region], settings: fixture.settings)
        #expect(reopenedCache.cachedImage(for: key) == nil)
        try await waitUntil { reopenedCache.cachedImage(for: key) != nil }
        #expect(try await reopenedCache.disk.data(for: layoutKey, kind: .layout) != nil)
        #expect(reopenedCache.cachedLayout(for: layoutKey) != nil)
        restored.releaseOverlay()
        restored.showCompletedTranslation(settings: fixture.settings)
        #expect(restored.isUsingCachedRendering)
        #expect(!imageView.subviews.contains { $0 is ReaderTranslationOverlayView })
        let directory = URL.documentsDirectory.appendingPathComponent("TranslationValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenshot = UIGraphicsImageRenderer(bounds: imageView.bounds).image { _ in
            imageView.drawHierarchy(in: imageView.bounds, afterScreenUpdates: true)
        }
        try #require(screenshot.pngData()).write(to: directory.appendingPathComponent("persistent-render-cache-\(dark ? "dark" : "light").png"))
        imageView.frame.size.width = 360
        imageView.setNeedsLayout()
        imageView.layoutIfNeeded()
        try await waitUntil { imageView.subviews.contains { $0 is ReaderTranslationOverlayView } }
        #expect(!restored.isUsingCachedRendering)
        restored.reset()
    }

    @Test func offCancelsAColdSnapshotLookup() async throws {
        let fixture = PersistentFixture()
        let imageView = UIImageView(image: Self.image())
        imageView.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
        let page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = fixture.page(0)
        page.renderCache = ReaderTranslationRenderCache(disk: fixture.disk)
        page.displayPrepared([Self.region], settings: fixture.settings)
        page.showOriginal()
        try await Task.sleep(for: .milliseconds(80))
        #expect(imageView.subviews.isEmpty)
    }

    @Test func cacheLimitChoicesPersistAndRejectUnsupportedValues() throws {
        let suite = "cache-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(settings.cacheLimitBytes == 1_000_000_000)
        for limit: Int64 in [100_000_000, 200_000_000, 500_000_000, 1_000_000_000, 2_000_000_000,
                             5_000_000_000, 10_000_000_000, 20_000_000_000, 100_000_000_000] {
            settings.cacheLimitBytes = limit
            try settings.save(defaults: defaults)
            #expect(ReaderTranslationSettings(defaults: defaults).cacheLimitBytes == limit)
        }
        settings.cacheLimitBytes = 11_000_000_000
        #expect(throws: (any Error).self) { try settings.save(defaults: defaults) }
        #expect(ReaderTranslationSettings(defaults: defaults).cacheLimitBytes == 100_000_000_000)
    }

    @Test func slowLayoutPreparationDoesNotBlockOCRAndTranslationOfOtherPages() async throws {
        let fixture = PersistentFixture()
        let gate = PersistentLayoutGate()
        var calls = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in calls += 1; return [Self.region] },
                                               prepareLayout: { _, _, _ in await gate.wait() })
        session.update(items: (0..<5).map { .init(fixture.page($0)) }, visible: [], context: "chapter", currentPageIndex: 2)
        session.enable(settings: fixture.settings)
        try await waitUntil { await gate.started && calls == 5 }
        session.close()
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.state == .off)
        #expect(calls == 5)
    }

    @Test func unseenPageIsRenderedInAdvanceAndPageTurnsDoNotTranslateAgain() async throws {
        let fixture = PersistentFixture()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let reader = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore())
        reader.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        controller.view.addSubview(reader)
        var next = fixture.page(1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        next.image = UIGraphicsImageRenderer(size: CGSize(width: 620, height: 903), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 620, height: 903))
            ("NEXT PAGE" as NSString).draw(at: CGPoint(x: 60, y: 130), withAttributes: [.font: UIFont.systemFont(ofSize: 40)])
        }
        let pages = [fixture.page(0), next]
        reader.setPageImage(pages[0].image)
        reader.layoutIfNeeded()
        reader.translationPage.sourcePage = pages[0]
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache)
        var calls: [Int] = []
        var prepared: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            calls.append(page.index)
            return [Self.region]
        }, diskCache: fixture.disk, renderCache: cache, prepareLayout: { page, regions, settings in
            try await preparer.prepare(page: page, regions: regions, settings: settings,
                                       geometry: .init(page: reader.translationPage, imageView: reader.imageView), window: window)
            prepared.append(page.index)
        })
        defer { session.close() }
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [reader.translationPage], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { prepared.contains(1) }
        reader.translationPage.reset()
        reader.translationPage.sourcePage = next
        reader.setPageImage(next.image)
        reader.layoutIfNeeded()
        let start = ProcessInfo.processInfo.systemUptime
        session.refreshVisiblePages([reader.translationPage])
        session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [reader.translationPage],
                       context: "chapter", currentPageIndex: 1)
        print("UNSEEN_PREPARED_PAGE_MAIN_SECONDS=\(ProcessInfo.processInfo.systemUptime - start)")
        #expect(reader.translationPage.isUsingCachedRendering)
        #expect(!reader.imageView.subviews.contains { $0 is ReaderTranslationOverlayView })
        #expect(calls == [0, 1])
        let directory = URL.documentsDirectory.appendingPathComponent("TranslationValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = UIGraphicsImageRenderer(bounds: reader.imageView.bounds).image { _ in
            reader.imageView.drawHierarchy(in: reader.imageView.bounds, afterScreenUpdates: true)
        }
        try #require(snapshot.pngData()).write(to: directory.appendingPathComponent("unseen-prefetched-page.png"))
        // A cold reader reuses text/layout instructions and redraws the page.
        cache.clearMemory()
        reader.translationPage.reset()
        let reopenedCache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: fixture.root))
        reader.translationPage.renderCache = reopenedCache
        reader.translationPage.displayPrepared([Self.region], settings: fixture.settings)
        try await waitUntil { reader.imageView.subviews.contains { $0 is ReaderTranslationOverlayView } }
        #expect(reader.translationPage.hasCompletedTranslation(settings: fixture.settings))
        #expect(calls == [0, 1])
        session.disable()
        session.enable(settings: fixture.settings)
        try await waitUntil { session.state == .on && reader.translationPage.hasCompletedTranslation(settings: fixture.settings) }
        #expect(calls == [0, 1])
    }

    @Test func persistedTranslationsStillPrepareMissingRenders() async throws {
        let fixture = PersistentFixture()
        let page = fixture.page(0)
        let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: fixture.settings)
        try await fixture.disk.storeRegions([Self.region], for: key, kind: .translation, generation: 0)
        var calls = 0
        var prepared = false
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in calls += 1; return [] },
                                               diskCache: fixture.disk, prepareLayout: { _, _, _ in prepared = true })
        defer { session.close() }
        session.update(items: [.init(page)], visible: [], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { prepared }
        #expect(calls == 0)
    }

    @Test func previouslyPreparedPagesGetFreshPixelsWhenTheyBecomeNeighbors() async throws {
        let fixture = PersistentFixture()
        let pages = (0..<10).map { fixture.page($0) }
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        var translated: [Int] = []
        var prepared: [Int] = []
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, _, _ in
            translated.append(page.index)
            return [Self.region]
        }, diskCache: fixture.disk, renderCache: cache, prepareLayout: { page, _, settings in
            prepared.append(page.index)
            await cache.store(Self.image(), key: "pixels-\(page.index)",
                              pageIdentity: ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings),
                              diskGeneration: 0)
        })
        defer { session.close() }
        let items = pages.map(ReaderTranslationSession.Item.init)
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 0)
        session.enable(settings: fixture.settings)
        try await waitUntil { prepared.count == cache.nearbyPageCount }
        #expect(cache.cachedImage(for: "pixels-1") != nil)
        #expect(cache.cachedImage(for: "pixels-9") == nil)
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 9)
        // The nearest bitmap now becomes ready before farther translations.
        // Wait for both independent milestones before asserting total calls.
        try await waitUntil { cache.cachedImage(for: "pixels-9") != nil && translated.count == 10 }
        #expect(cache.cachedImage(for: "pixels-1") == nil)
        #expect(translated.count == 10)
        cache.clearMemory()
        session.update(items: items, visible: [], context: "chapter", currentPageIndex: 9)
        try await waitUntil { cache.cachedImage(for: "pixels-9") != nil }
        #expect(translated.count == 10)
        session.close()
        #expect(cache.cachedImage(for: "pixels-9") == nil)
    }

    @Test func switchingOffAndOnResumesCancelledRenderingWithoutAnotherTranslation() async throws {
        let fixture = PersistentFixture()
        var calls = 0
        var attempts = 0
        let session = ReaderTranslationSession(validate: { _ in }, process: { _, _, _ in calls += 1; return [Self.region] },
                                               diskCache: fixture.disk, prepareLayout: { _, _, _ in
            attempts += 1
            if attempts == 1 { try await Task.sleep(for: .seconds(30)) }
        })
        defer { session.close() }
        session.update(items: [.init(fixture.page(0))], visible: [], context: "chapter")
        session.enable(settings: fixture.settings)
        try await waitUntil { attempts == 1 }
        session.disable()
        session.enable(settings: fixture.settings)
        try await waitUntil { attempts == 2 }
        try await Task.sleep(for: .milliseconds(20))
        session.disable()
        var changed = fixture.settings
        changed.overlay.opacity = 0.5
        session.enable(settings: changed)
        try await waitUntil { attempts == 3 }
        #expect(calls == 1)
    }

    @Test func visiblePageCancelsSpeculativeRenderAndDisplaysLiveWithoutWaiting() async throws {
        let fixture = PersistentFixture()
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        let image = Self.image()
        let view = UIImageView(image: image)
        view.bounds.size = CGSize(width: 320, height: 480)
        view.contentMode = .scaleAspectFit
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = fixture.page(0)
        page.renderCache = cache
        let key = ReaderTranslationCacheIdentity.render(page: fixture.page(0).translationCacheKey, settings: fixture.settings,
                                                        imageSize: image.size, viewport: view.bounds.size,
                                                        scale: view.traitCollection.displayScale, aspectFit: true,
                                                        crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                        dark: view.traitCollection.userInterfaceStyle == .dark)
        let gate = PersistentLayoutGate()
        let work = Task {
            try await cache.prepare(key) {
                await gate.wait()
                await cache.store(image, key: key, pageIdentity: "page", diskGeneration: 0)
            }
        }
        try await waitUntil { await gate.started }
        page.displayPrepared([Self.region], settings: fixture.settings)
        #expect(view.subviews.contains { $0 is ReaderTranslationOverlayView },
                "Visible WebKit startup must not wait for disk generation or an asynchronous bitmap lookup")
        #expect(!page.isUsingCachedRendering)
        await gate.release()
        _ = try? await work.value
        // The cancelled speculative result cannot replace the current live view.
        #expect(cache.cachedImage(for: key) == nil)
        #expect(view.subviews.contains { $0 is ReaderTranslationOverlayView })
        page.reset()
    }

    static let region = ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.08, y: 0.12, width: 0.7, height: 0.15), source: "HELLO WORLD",
                                                translation: "저장된 번역을 바로 표시합니다", sourceOrientation: .horizontal)
    static func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            ("HELLO WORLD" as NSString).draw(at: CGPoint(x: 50, y: 100),
                                             withAttributes: [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black])
        }
    }
    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while try await !condition() {
            if Date() > deadline { throw PersistentTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum PersistentTestError: Error { case api, timeout }
private actor PersistentLayoutGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { started = true; continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private final class PersistentFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("persistent-pipeline-" + UUID().uuidString)
    let suite = "persistent-settings-" + UUID().uuidString
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    var settings: ReaderTranslationSettings { ReaderTranslationSettings(defaults: UserDefaults(suiteName: suite)!) }
    func page(_ index: Int) -> Aidoku.Page {
        Aidoku.Page(sourceId: "cache-test", chapterId: "chapter", index: index, image: ReaderTranslationPersistentPipelineTests.image())
    }
    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

@MainActor private final class CurrentWebtoonTestOwner: ReaderTranslationOwner {
    let controller: ReaderWebtoonViewController
    let translationUpcomingPages: [Aidoku.Page]
    let navigationItem = UINavigationItem()
    var translationVisiblePages: [ReaderTranslationPage] { controller.translationPages() }
    var translationChapterKey: String { "reported-current-page" }
    var translationCurrentPageIndex: Int { max(0, controller.getCurrentPage() - 1) }
    init(controller: ReaderWebtoonViewController, pages: [Aidoku.Page]) {
        self.controller = controller; translationUpcomingPages = pages
    }
}
