import AsyncDisplayKit
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationInitialPresentationTests {
    @Test(arguments: [false, true])
    func durableAssetReplaysWithoutAWindowAndClipsTypography(aspectFit: Bool) async throws {
        let fixture = FirstDisplayFixture()
        let viewport = CGSize(width: 120, height: 120)
        let rect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: fixture.source.size, bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit)
        let asset = try fixture.asset(displayRect: rect)
        let key = fixture.key(viewport: viewport, aspectFit: aspectFit)
        let original = ReaderTranslationRenderCache(disk: fixture.disk)
        await original.storeRenderAsset(asset, key: key, diskGeneration: 0)
        original.clearMemory()
        let reopened = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: fixture.root))
        defer { reopened.clearMemory() }
        #expect(reopened.cachedImage(for: key) == nil)
        let restored = try #require(await reopened.renderAsset(for: key))
        #expect(restored.typography == asset.typography)
        #expect(restored.layers.masks.first?.png == asset.layers.masks.first?.png)
        let identity = ReaderTranslationCacheIdentity.translation(page: fixture.page().translationCacheKey, settings: fixture.settings)
        let image = try await ReaderTranslationImageExporter.renderLoadedImage(image: fixture.source,
            regions: [FirstDisplayFixture.region], settings: fixture.settings, viewport: viewport, scale: 1,
            aspectFit: aspectFit, dark: false, host: nil, cache: reopened, key: key, pageIdentity: identity)
        #expect(image.size.width * 120 == image.size.height * 80)
        // The PDF deliberately paints its whole page blue. Only its measured
        // text bounds may overwrite the original or the separate repair layer.
        #expect(try pixel(image, at: CGPoint(x: 12, y: 12)) == [255, 0, 0])
        #expect(try pixel(image, at: CGPoint(x: 55, y: 25)) == [0, 0, 255])
        #expect(try pixel(image, at: CGPoint(x: 5, y: 5)) == [0, 255, 0])
        #expect(try pixel(image, at: CGPoint(x: 55, y: 75)) == [0, 255, 0])
        let again = try await ReaderTranslationImageExporter.renderLoadedImage(image: fixture.source,
            regions: [FirstDisplayFixture.region], settings: fixture.settings, viewport: viewport, scale: 1,
            aspectFit: aspectFit, dark: false, host: nil, cache: reopened, key: key, pageIdentity: identity)
        #expect(again === image, "A second nearby load reuses the finished bitmap instead of compositing again")
    }

    @Test(arguments: [false, true])
    func exportedAssetReplaysIdenticalPixelsAfterCacheReopens(webtoon: Bool) async throws {
        guard #available(iOS 18.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let fixture = FirstDisplayFixture()
        let encodedSource = try #require(ReaderTranslationPersistentPipelineTests.image().pngData())
        let source = try #require(UIImage(data: encodedSource))
        let regions = [ReaderTranslationPersistentPipelineTests.region]
        let viewport = webtoon ? CGSize(width: 320, height: 320 * source.size.height / source.size.width)
                              : CGSize(width: 320, height: 480)
        let key = ReaderTranslationCacheIdentity.render(page: fixture.page().translationCacheKey, settings: fixture.settings,
            imageSize: source.size, viewport: viewport, scale: 1, aspectFit: !webtoon,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: false)
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        let coldStart = ProcessInfo.processInfo.systemUptime
        let cold = try await ReaderTranslationImageExporter.renderLoadedImage(image: source, regions: regions,
            settings: fixture.settings, viewport: viewport, scale: 1, aspectFit: !webtoon, dark: false,
            host: window, cache: cache, key: key)
        let coldMS = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
        let deadline = Date().addingTimeInterval(10)
        while try await !fixture.disk.contains(ReaderTranslationRenderCache.renderAssetStorageKey(key), kind: .layout) {
            if Date() >= deadline { throw FirstDisplayError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        cache.clearMemory()
        ReaderTranslationImageExporter.clearIdleRenderer()
        let reopened = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: fixture.root))
        let reloadedSource = try #require(UIImage(data: encodedSource))
        #expect(reloadedSource !== source, "Restart validation must decode the source again")
        let warmStart = ProcessInfo.processInfo.systemUptime
        let replay = try await ReaderTranslationImageExporter.renderLoadedImage(image: reloadedSource, regions: regions,
            settings: fixture.settings, viewport: viewport, scale: 1, aspectFit: !webtoon, dark: false,
            host: nil, cache: reopened, key: key)
        let warmMS = (ProcessInfo.processInfo.systemUptime - warmStart) * 1000
        #expect(replay.pngData() == cold.pngData(), "Disk asset replay must preserve the complete exported page")
        try #require(cold.pngData()).write(to: URL.documentsDirectory.appendingPathComponent("asset-cold-\(webtoon).png"))
        try #require(replay.pngData()).write(to: URL.documentsDirectory.appendingPathComponent("asset-replay-\(webtoon).png"))
        print("ASSET_REPLAY webtoon=\(webtoon) cold_ms=\(coldMS) warm_ms=\(warmMS)")
        reopened.clearMemory()
    }

    @Test func changedTranslationGeometryAndRendererSettingsCannotReuseAnAsset() async throws {
        let fixture = FirstDisplayFixture()
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        defer { cache.clearMemory() }
        let key = fixture.key()
        await cache.storeRenderAsset(try fixture.asset(), key: key, diskGeneration: 0)
        let digest = ReaderTranslationRenderAsset.digestSource(fixture.source)
        #expect(await cache.renderAsset(for: key, regions: [FirstDisplayFixture.region],
            sourceSize: fixture.source.size, sourceDigest: digest) != nil)
        var revised = FirstDisplayFixture.region
        revised.translation = "An edited translation"
        #expect(ReaderTranslationRenderCache.layoutKey(renderKey: key, regions: [FirstDisplayFixture.region])
            != ReaderTranslationRenderCache.layoutKey(renderKey: key, regions: [revised]))
        #expect(await cache.renderAsset(for: key, regions: [revised], sourceSize: fixture.source.size, sourceDigest: digest) == nil)
        #expect(await cache.renderAsset(for: key, regions: [FirstDisplayFixture.region],
            sourceSize: CGSize(width: 81, height: 120), sourceDigest: digest) == nil)
        #expect(await cache.renderAsset(for: key, regions: [FirstDisplayFixture.region], sourceSize: fixture.source.size,
            sourceDigest: ReaderTranslationRenderAsset.digestSource(FirstDisplayFixture.image(.black))) == nil)
        var settings = fixture.settings
        settings.targetLanguage = "fr"
        #expect(await cache.renderAsset(for: fixture.key(settings: settings)) == nil)
        #expect(await cache.renderAsset(for: fixture.key(viewport: CGSize(width: 80, height: 121))) == nil)
        #expect(await cache.renderAsset(for: fixture.key(crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))) == nil)
    }

    @Test func malformedVersionAndOversizedAssetsAreRejected() async throws {
        let fixture = FirstDisplayFixture()
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        defer { cache.clearMemory() }
        let encoded = try JSONEncoder().encode(fixture.asset())
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old["version"] = ReaderTranslationRenderAsset.currentVersion + 1
        let inputs = [Data("{invalid".utf8), try JSONSerialization.data(withJSONObject: old),
                      Data(repeating: 32, count: ReaderTranslationRenderAsset.maximumEncodedBytes + 1)]
        for (index, data) in inputs.enumerated() {
            let key = "invalid-\(index)"
            try await fixture.disk.store(data, for: ReaderTranslationRenderCache.renderAssetStorageKey(key), kind: .layout, generation: 0)
            #expect(await cache.renderAsset(for: key) == nil)
        }
        let asset = try fixture.asset()
        let oversized = ReaderTranslationRenderAsset(
            typography: Data(repeating: 0, count: ReaderTranslationRenderAsset.maximumContentBytes + 1),
            layers: asset.layers, displayRect: asset.displayRect, sourceSize: asset.sourceSize,
            regions: [FirstDisplayFixture.region], sourceDigest: asset.sourceDigest)
        #expect(!oversized.isValid)
        await cache.storeRenderAsset(oversized, key: "oversized", diskGeneration: 0)
        #expect(await cache.renderAsset(for: "oversized") == nil)
        #expect(cache.renderAssetBytes == 0)
    }

    @Test func clearRejectsLateMemoryAndDiskAssetWriters() async throws {
        let fixture = FirstDisplayFixture()
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        defer { cache.clearMemory() }
        let asset = try fixture.asset()
        let context = cache.renderAssetStorageContext(settings: fixture.settings)
        cache.clearMemory()
        cache.storeRenderAssetAfterDisplay(asset, key: "late-memory", context: context)
        #expect(cache.renderAssetBytes == 0)
        #expect(await cache.renderAsset(for: "late-memory") == nil)
        let generation = await fixture.disk.currentGeneration()
        try await fixture.disk.clear()
        await cache.storeRenderAsset(asset, key: "late-disk", diskGeneration: generation)
        #expect(await cache.renderAsset(for: "late-disk") == nil)
        #expect(try await fixture.disk.statistics().entries == 0)
    }

    @Test func brokenPDFIsEvictedInsteadOfPublishingUntranslatedPixels() async throws {
        let fixture = FirstDisplayFixture()
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        defer { cache.clearMemory() }
        let asset = try fixture.asset()
        let broken = ReaderTranslationRenderAsset(typography: Data("not a PDF".utf8), layers: asset.layers,
            displayRect: asset.displayRect, sourceSize: asset.sourceSize,
            regions: [FirstDisplayFixture.region], sourceDigest: asset.sourceDigest)
        await cache.storeRenderAsset(broken, key: fixture.key(), diskGeneration: 0)
        do {
            _ = try await ReaderTranslationImageExporter.renderLoadedImage(image: fixture.source,
                regions: [FirstDisplayFixture.region], settings: fixture.settings, viewport: fixture.source.size, scale: 1,
                aspectFit: true, dark: false, host: nil, cache: cache, key: fixture.key())
            Issue.record("An unusable PDF must not be reported as a completed translation")
        } catch ReaderTranslationImageExporter.ExportError.unavailable {}
        #expect(await cache.renderAsset(for: fixture.key()) == nil)
    }

    @Test func coordinatorRestoresWarmImageBeforeActivationWithoutOCRProviderOrWindow() async throws {
        guard #available(iOS 18.0, *) else { return }
        let fixture = FirstDisplayFixture()
        let cache = ReaderTranslationRenderCache(disk: fixture.disk)
        try await fixture.disk.storeRegions([FirstDisplayFixture.region],
            for: ReaderTranslationCacheIdentity.translation(page: fixture.page().translationCacheKey, settings: fixture.settings),
            kind: .translation, generation: 0)
        await cache.storeRenderAsset(try fixture.asset(), key: fixture.key(), diskGeneration: 0)
        cache.clearMemory()
        var probes = 0, processing = 0
        let session = ReaderTranslationSession(validate: { _ in probes += 1 },
            process: { _, _, _ in processing += 1; return [] }, diskCache: fixture.disk, renderCache: cache)
        let owner = FirstDisplayOwner(page: fixture.page())
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { fixture.settings }, setEnabled: { _ in })
        defer { coordinator.close() }
        let geometry = ReaderTranslationImageGeometry(viewport: fixture.source.size, scale: 1, aspectFit: true, dark: false)
        let prepared = try #require(await coordinator.prepareCachedImage(image: fixture.source, page: fixture.page(), geometry: { geometry }))
        #expect(prepared.isCurrent())
        #expect(try pixel(prepared.image, at: CGPoint(x: 55, y: 25)) == [0, 0, 255])
        #expect(session.state == .off)
        #expect(probes == 0 && processing == 0)
        #expect(try await coordinator.prepareCachedImage(image: fixture.source, page: fixture.page(1), geometry: { geometry }) == nil)
        fixture.settings.targetLanguage = "fr"
        #expect(!prepared.isCurrent())
        #expect(try await session.cachedRegions(for: fixture.page(), settings: fixture.settings) == nil)
        #expect(probes == 0 && processing == 0)
    }

    @Test func completedCanvasSurvivesSessionStartupAndProbeFailureUntilExplicitOff() async throws {
        let fixture = FirstDisplayFixture()
        let view = UIImageView(image: fixture.source)
        view.frame = CGRect(origin: .zero, size: fixture.source.size)
        let page = ReaderTranslationPage(imageView: view)
        page.sourcePage = fixture.page()
        page.displayLoadedImage(.init(image: FirstDisplayFixture.image(.blue),
            regions: [FirstDisplayFixture.region], settings: fixture.settings))
        let canvas = try #require(view.subviews.first { $0.accessibilityIdentifier == "reader.translation.cachedOverlay" })
        let gate = FirstDisplayGate()
        var failures = 0
        let session = ReaderTranslationSession(validate: { _ in await gate.wait(); throw FirstDisplayError.failed },
            process: { _, _, _ in Issue.record("A failed probe must not start OCR/API"); return [] })
        defer { session.close(); gate.release() }
        session.onFailure = { _ in failures += 1 }
        session.update(items: [.init(fixture.page())], visible: [page], context: "startup")
        #expect(!canvas.isHidden && canvas.superview === view)
        session.enable(settings: fixture.settings)
        try await waitUntil { gate.started }
        #expect(session.state == .checking && !canvas.isHidden && canvas.superview === view)
        gate.release()
        try await waitUntil { failures == 1 }
        #expect(session.state == .off && !canvas.isHidden && canvas.superview === view)
        #expect(page.hasLoadedCachedPresentation)
        session.disable()
        #expect(canvas.superview == nil && !page.hasLoadedCachedPresentation)
        #expect(view.image === fixture.source)
    }

    @Test func pagedLoadPublishesSourceAndPreparedCanvasInOneCommit() async throws {
        let fixture = FirstDisplayFixture()
        let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore())
        let gate = FirstDisplayGate(), rendered = FirstDisplayFixture.image(.blue)
        view.prepareTranslationForDisplay = { image, page in
            #expect(image === fixture.source && page.translationCacheKey == fixture.page().translationCacheKey)
            await gate.wait()
            return .init(image: rendered, regions: [FirstDisplayFixture.region], settings: fixture.settings)
        }
        let events = FirstDisplayEvents(page: fixture.page(), view: view.imageView) { view.translationPage.hasLoadedCachedPresentation }
        let load = Task { await view.setPage(fixture.page(), skipProcessing: true) }
        defer { load.cancel(); gate.release(); view.releasePageResources() }
        try await waitUntil { gate.started }
        #expect(view.imageView.image == nil && !view.progressView.isHidden)
        #expect(events.sources.isEmpty && events.preparedAtCommit.isEmpty)
        gate.release()
        #expect(await load.value)
        #expect(view.imageView.image === fixture.source, "OCR and dictionary lookup retain the original UIImage")
        #expect(events.sources.count == 1 && events.sources.first === fixture.source)
        #expect(events.preparedAtCommit == [true])
        let canvas = view.imageView.subviews.first { $0.accessibilityIdentifier == "reader.translation.cachedOverlay" } as? UIImageView
        #expect(canvas?.image === rendered)
        #expect(view.progressView.isHidden)
    }

    @Test func emptyPortraitSpreadHasGeometryBeforeEitherSourceIsAssigned() throws {
        let store = ReaderTemporaryPageStore()
        let first = ReaderPageViewController(type: .page, delegate: nil, temporaryPageStore: store)
        let second = ReaderPageViewController(type: .page, delegate: nil, temporaryPageStore: store)
        let spread = ReaderDoublePageViewController(firstPage: first, secondPage: second, direction: .ltr)
        spread.loadViewIfNeeded()
        spread.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        spread.viewWillAppear(false)
        spread.view.layoutIfNeeded()
        defer { spread.viewDidDisappear(false) }
        for controller in [first, second] {
            let view = try #require(controller.pageView)
            #expect(view.imageView.image == nil)
            #expect(view.bounds.width > 0 && view.bounds.height > 0)
            let geometry = try #require(view.translationImageGeometry(for: FirstDisplayFixture.image(.green)))
            #expect(geometry.isValid, "Cached composition cannot depend on raw-image intrinsic sizing")
        }
    }

    @Test(arguments: [false, true], [false, true])
    func cancelledOrReplacedPageCannotPublishALateComposite(replace: Bool, throwsOnResume: Bool) async throws {
        let fixture = FirstDisplayFixture()
        let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore())
        let gate = FirstDisplayGate()
        view.prepareTranslationForDisplay = { _, page in
            guard page.index == 0 else { return nil }
            await gate.wait()
            if throwsOnResume { throw FirstDisplayError.failed }
            return .init(image: FirstDisplayFixture.image(.blue), regions: [FirstDisplayFixture.region], settings: fixture.settings)
        }
        let old = Task { await view.setPage(fixture.page(), skipProcessing: true) }
        defer { old.cancel(); gate.release(); view.releasePageResources() }
        try await waitUntil { gate.started }
        let replacement = FirstDisplayFixture.image(.yellow)
        if replace {
            var next = fixture.page(1); next.image = replacement
            #expect(await view.setPage(next, skipProcessing: true))
        } else { old.cancel() }
        gate.release()
        #expect(await old.value == false)
        #expect(replace ? view.imageView.image === replacement : view.imageView.image == nil)
        #expect(!view.translationPage.hasLoadedCachedPresentation)
    }

    @Test(arguments: [false, true])
    func cacheMissAndFailedCompositionPreserveDecodedSource(fails: Bool) async {
        let fixture = FirstDisplayFixture()
        let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore())
        defer { view.releasePageResources() }
        view.prepareTranslationForDisplay = { _, _ in
            if fails { throw FirstDisplayError.failed }
            return nil
        }
        #expect(await view.setPage(fixture.page(), skipProcessing: true))
        #expect(view.imageView.image === fixture.source)
        #expect(view.progressView.isHidden && !view.translationPage.isUsingCachedRendering)
    }

    @Test func webtoonFailedCompositionPreservesDecodedSource() async throws {
        let fixture = FirstDisplayFixture()
        let node = ReaderWebtoonPageNode(source: nil, page: fixture.page(), temporaryPageStore: ReaderTemporaryPageStore(),
            pillarboxLayoutState: ReaderPillarboxLayoutState())
        node.prepareTranslationForDisplay = { _, _ in throw FirstDisplayError.failed }
        await node.loadPage()
        #expect(node.image === fixture.source)
        node.displayPage()
        let backing = try #require(node.imageNode.view as? UIImageView)
        try await waitUntil { backing.image === fixture.source }
        #expect(node.translationPage?.hasLoadedCachedPresentation != true)
        node.imageNode.reset()
        node.translationPage?.reset()
    }

    @Test(arguments: [false, true])
    func layoutWaitReleasesItsHostAfterGeometryChangeOrCancellation(cancel: Bool) async throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        var ready = false
        let waiting = Task { try await ReaderTranslationLayoutAwaiter.wait(in: host) { ready } }
        defer { waiting.cancel() }
        try await waitUntil { host.subviews.contains { $0 is ReaderTranslationLayoutAwaiter } }
        if cancel {
            waiting.cancel()
        } else {
            ready = true
            NotificationCenter.default.post(name: ReaderTranslationLayoutAwaiter.geometryChanged, object: host)
        }
        do {
            try await waiting.value
            #expect(!cancel)
        } catch is CancellationError {
            #expect(cancel)
        }
        #expect(host.subviews.isEmpty)
    }

    @Test func translationPreloaderBypassesPresentationPreparation() async {
        let fixture = FirstDisplayFixture()
        let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore())
        defer { view.releasePageResources() }
        view.isTranslationPreload = true
        view.prepareTranslationForDisplay = { _, _ in
            Issue.record("An OCR preloader cannot wait for its own translated presentation")
            return nil
        }
        #expect(await view.setPage(fixture.page(), skipProcessing: true))
        #expect(view.imageView.image === fixture.source)
        #expect(!view.translationPage.hasLoadedCachedPresentation)
    }

    @Test func webtoonPreparesBeforeItsDelayedBackingViewAndCommitsIdempotently() async throws {
        let fixture = FirstDisplayFixture()
        let node = ReaderWebtoonPageNode(source: nil, page: fixture.page(), temporaryPageStore: ReaderTemporaryPageStore(),
            pillarboxLayoutState: ReaderPillarboxLayoutState())
        let gate = FirstDisplayGate()
        var preparations = 0
        node.prepareTranslationForDisplay = { _, _ in
            preparations += 1
            await gate.wait()
            return .init(image: FirstDisplayFixture.image(.blue), regions: [FirstDisplayFixture.region], settings: fixture.settings)
        }
        let load = Task { await node.loadPage() }
        defer { load.cancel(); gate.release(); node.imageNode.reset(); node.translationPage?.reset() }
        try await waitUntil { gate.started }
        #expect(node.image == nil && node.imageNode.imageView == nil)
        gate.release()
        await load.value
        #expect(node.image === fixture.source && node.imageNode.imageView == nil)
        node.displayPage()
        let backing = try #require(node.imageNode.view as? UIImageView)
        #expect(backing.image == nil)
        let events = FirstDisplayEvents(page: fixture.page(), view: backing) { node.translationPage?.hasLoadedCachedPresentation == true }
        try await waitUntil { node.translationPage?.hasLoadedCachedPresentation == true }
        let canvas = try #require(backing.subviews.first { $0.accessibilityIdentifier == "reader.translation.cachedOverlay" })
        #expect(backing.image === fixture.source && preparations == 1)
        #expect(!events.preparedAtCommit.isEmpty && events.preparedAtCommit.allSatisfy { $0 })
        node.imageNode.commitImage()
        #expect(canvas.superview === backing && preparations == 1)
        #expect(node.translationPage?.hasLoadedCachedPresentation == true)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { throw FirstDisplayError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let pixels = try #require(image.cgImage)
        let x = point.x * CGFloat(pixels.width) / 80, y = point.y * CGFloat(pixels.height) / 120
        let cropped = try #require(pixels.cropping(to: CGRect(x: floor(x), y: floor(y), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Array(bytes.prefix(3))
    }
}

@MainActor private final class FirstDisplayFixture {
    static let region = ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.125, y: 0.125, width: 0.5, height: 0.25),
        source: "Original", translation: "Cached translation", sourceOrientation: .horizontal)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("initial-display-" + UUID().uuidString)
    let suite = "initial-display-" + UUID().uuidString
    let source = FirstDisplayFixture.image(.green)
    lazy var disk = ReaderTranslationDiskCache(directory: root)
    lazy var settings: ReaderTranslationSettings = {
        var value = ReaderTranslationSettings(defaults: UserDefaults(suiteName: suite)!)
        value.automaticallyTranslate = true
        value.overlay.visible = true
        value.targetLanguage = "ko"
        return value
    }()
    func page(_ index: Int = 0) -> Page { Page(sourceId: suite, chapterId: "chapter", index: index, image: source) }
    func key(settings: ReaderTranslationSettings? = nil, viewport: CGSize = CGSize(width: 80, height: 120),
             aspectFit: Bool = true, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> String {
        ReaderTranslationCacheIdentity.render(page: page().translationCacheKey, settings: settings ?? self.settings,
            imageSize: source.size, viewport: viewport, scale: 1, aspectFit: aspectFit, crop: crop, dark: false)
    }
    func asset(displayRect: CGRect = CGRect(x: 0, y: 0, width: 80, height: 120)) throws -> ReaderTranslationRenderAsset {
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: displayRect.size)).pdfData { context in
            context.beginPage()
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: displayRect.size))
        }
        func frame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGFloat] {
            [displayRect.minX + x * displayRect.width / 80, displayRect.minY + y * displayRect.height / 120,
             width * displayRect.width / 80, height * displayRect.height / 120]
        }
        let png = try #require(Self.image(.red).pngData()).base64EncodedString()
        let layers = ReaderTranslationImageExporter.ExportLayers(
            masks: [.init(frame: frame(8, 8, 20, 20), opacity: 1, png: "data:image/png;base64," + png)],
            surfaces: [], paintBounds: [frame(50, 20, 20, 30)])
        return ReaderTranslationRenderAsset(typography: pdf, layers: layers, displayRect: displayRect,
            sourceSize: source.size, regions: [Self.region], sourceDigest: ReaderTranslationRenderAsset.digestSource(source))
    }
    static func image(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
        }
    }
    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

private enum FirstDisplayError: Error { case failed, timeout }

// Deliberately ignores cancellation so race tests can deliver a stale result.
@MainActor private final class FirstDisplayGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { started = true; continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor private final class FirstDisplayOwner: ReaderTranslationOwner {
    let navigationItem = UINavigationItem()
    let translationUpcomingPages: [Page]
    var translationVisiblePages: [ReaderTranslationPage] { [] }
    var translationChapterKey: String { "startup" }
    init(page: Page) { translationUpcomingPages = [page] }
}

@MainActor private final class FirstDisplayEvents {
    private var observers: [NSObjectProtocol] = []
    private(set) var sources: [UIImage] = []
    private(set) var preparedAtCommit: [Bool] = []
    init(page: Page, view: UIImageView, prepared: @escaping @MainActor () -> Bool) {
        observers.append(NotificationCenter.default.addObserver(forName: ReaderTranslationPage.sourceImageReady,
            object: nil, queue: .main) { [weak self] notification in
                guard let source = notification.object as? ReaderTranslationPage.LoadedSource,
                      source.page.translationCacheKey == page.translationCacheKey else { return }
                MainActor.assumeIsolated { self?.sources.append(source.image) }
            })
        observers.append(NotificationCenter.default.addObserver(forName: ReaderTranslationPage.imageChanged,
            object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.preparedAtCommit.append(prepared()) }
            })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
