import CoreGraphics
import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationRenderSpeedTests {
    @Test(arguments: [false, true]) @MainActor
    func loadedReaderImageIsComposedBeforePageEntersWindow(webtoon: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        let image = ReaderTranslationPersistentPipelineTests.image()
        let page = Page(sourceId: "borrowed-raster", chapterId: root.lastPathComponent, index: 1,
                        imageURL: "file:///must-not-reload-decoded-reader-image.png")
        let view = UIImageView(image: image)
        view.contentMode = webtoon ? .scaleToFill : .scaleAspectFit
        view.bounds.size = webtoon ? CGSize(width: 320, height: 320 * image.size.height / image.size.width)
                                  : CGSize(width: 320, height: 480)
        let reader = ReaderTranslationPage(imageView: view)
        reader.sourcePage = page; reader.renderCache = cache
        let geometry = ReaderTranslationLayoutGeometry(page: reader, imageView: view)
        let settings = ReaderTranslationSettings()
        let regions = [ReaderTranslationPersistentPipelineTests.region]
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache,
            imageBudget: TranslationImageWorkBudget(availableMemory: { .max }))
        preparer.sourceDidLoad(image, page: page)
        let start = ProcessInfo.processInfo.systemUptime
        try await preparer.prepare(page: page, regions: regions, settings: settings, geometry: geometry, window: window)
        let renderMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        #expect(view.window == nil, "Composition must finish before the target view is visible")
        let attach = ProcessInfo.processInfo.systemUptime
        reader.displayPreparedSnapshot(regions, settings: settings, memoryOnly: true)
        #expect(reader.isUsingCachedRendering)
        #expect(!view.subviews.contains { $0 is ReaderTranslationOverlayView })
        let attachMS = (ProcessInfo.processInfo.systemUptime - attach) * 1000
        window.rootViewController?.view.addSubview(view)
        let bitmap = try #require((view.subviews.first as? UIImageView)?.image)
        let artifact = URL.documentsDirectory.appendingPathComponent("prerender-before-visible-\(webtoon).png")
        try #require(bitmap.pngData()).write(to: artifact)
        print("PRERENDER_BEFORE_VISIBLE webtoon=\(webtoon) render_ms=\(renderMS) attach_ms=\(attachMS)")
    }

    @Test @MainActor func repeatedLayoutMeasurementsPreserveCompletePayload() async throws {
        let size = CGSize(width: 800, height: 1200)
        let viewport = CGSize(width: 390, height: 780)
        let source = CGRect(x: 0, y: 0, width: 390, height: 585)
        let items = (0..<12).map { index in
            BrowserOverlayItem(rect: CGRect(x: 40 + index % 3 * 250, y: 40 + index / 3 * 260, width: 170, height: 180),
                sourceText: "同じ文字をもう一度測定する必要はない", translatedText: "같은 글자를 다시 측정할 필요는 없지요. \(index)",
                confidence: 1, sourceOrientation: .vertical)
        }
        let cache = BrowserOverlayTextMeasurementCache()
        var freshTime = 0.0, reusedTime = 0.0
        for pass in 0..<8 {
            var settings = ReaderTranslationSettings.defaultOverlay
            if pass % 3 == 1 { settings.mode = .originalAndTranslation }
            let selected = Array(items.prefix(pass < 4 ? 3 + pass * 3 : 12))
            let start = ProcessInfo.processInfo.systemUptime
            let fresh = BrowserPageImageOverlayRenderer.layoutPayload(items: selected, imageSize: size, sourceRect: source,
                settings: settings, targetLanguage: "ko", viewport: viewport)
            freshTime += ProcessInfo.processInfo.systemUptime - start
            let reusedStart = ProcessInfo.processInfo.systemUptime
            let reused = BrowserPageImageOverlayRenderer.layoutPayload(items: selected, imageSize: size, sourceRect: source,
                settings: settings, targetLanguage: "ko", viewport: viewport, measurementCache: cache)
            reusedTime += ProcessInfo.processInfo.systemUptime - reusedStart
            let expected = try JSONSerialization.data(withJSONObject: fresh, options: [.sortedKeys])
            #expect(try JSONSerialization.data(withJSONObject: reused, options: [.sortedKeys]) == expected)
            let worker = try await BrowserPageImageOverlayRenderer.prepareLayoutData(items: selected, imageSize: size,
                sourceRect: source, settings: settings, targetLanguage: "ko", viewport: viewport)
            let object = try JSONSerialization.jsonObject(with: worker)
            #expect(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) == expected)
        }
        #expect(cache.passHits > 0)
        print("LAYOUT_REUSE_BENCH fresh_ms=\(freshTime * 1000) reused_ms=\(reusedTime * 1000)")
    }

    @Test func preparedCollisionEdgesMatchCoreGraphics() {
        var rects: [CGRect] = (0..<600).map { index in
            let x = CGFloat(index * 73 % 390) / 1.7 - 12
            let y = CGFloat(index * 131 % 780) / 1.3 - 8
            let width = CGFloat(index * 37 % 170) / 1.1
            let height = CGFloat(index * 61 % 250) / 2.1
            return CGRect(x: x, y: y, width: width, height: height)
        }
        rects += [.null, .zero, .infinite, CGRect(x: 15, y: 30, width: -12, height: -18)]
        for delta: CGFloat in [0, 0.2499, 0.25, 0.2501] {
            rects.append(CGRect(x: 100 - delta, y: 100 - delta, width: 100, height: 100))
        }
        rects.append(CGRect(x: 0, y: 0, width: 100, height: 100))
        let geometry = rects.map(BrowserOverlayCollisionGeometry.init)
        for threshold: CGFloat in [0, 0.25] {
            for left in rects.indices {
                for right in rects.indices {
                    let intersection = rects[left].intersection(rects[right])
                    let expected: CGFloat = !intersection.isNull && intersection.width > threshold && intersection.height > threshold
                        ? intersection.width * intersection.height : 0
                    #expect(geometry[left].overlapArea(with: geometry[right], minimumExtent: threshold) == expected)
                }
            }
        }
    }

    @Test func earlyOverlapDetectionMatchesExhaustiveCoreGraphics() {
        func reference(_ rects: [CGRect], external: [CGRect]) -> Bool {
            var pairs = 0
            func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
                let intersection = a.intersection(b)
                return !intersection.isNull && intersection.width > 0.25 && intersection.height > 0.25
            }
            for left in rects.indices {
                for right in rects.indices where right > left {
                    if overlaps(rects[left], rects[right]) { pairs += 1 }
                }
                for obstacle in external {
                    if overlaps(rects[left], obstacle) { pairs += 1 }
                }
            }
            return pairs > 0
        }
        var cases: [[CGRect]] = [[], [.zero], [.null, .infinite],
            [CGRect(x: 15, y: 30, width: -12, height: -18), .zero]]
        for count in [1, 2, 8, 50] {
            for stride in [3, 35, 150] {
                cases.append((0..<count).map { index in
                    CGRect(x: CGFloat(index * stride), y: CGFloat(index % 3 * 17), width: 30, height: 45)
                })
            }
        }
        for delta: CGFloat in [0, 0.2499, 0.25, 0.2501] {
            cases.append([CGRect(x: 0, y: 0, width: 100, height: 100),
                          CGRect(x: 100 - delta, y: 100 - delta, width: 100, height: 100)])
        }
        for rects in cases {
            for external in [[], [CGRect(x: 10, y: 10, width: 10, height: 10)], Array(rects.prefix(2))] {
                #expect(BrowserOverlayCollisionGeometry.hasOverlap(in: rects, external: external)
                        == reference(rects, external: external))
            }
        }
    }

    @Test @MainActor func rendererJoinsPreparedLayoutAndRejectsSupersededOutput() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        var committed: [String] = []
        let renderer = BrowserPageImageOverlayRenderer { _, _, arguments in
            let items = arguments["items"] as? [[String: Any]] ?? []
            committed.append(contentsOf: items.compactMap { $0["text"] as? String })
            return ["status": "committed", "revision": arguments["revision"] ?? "", "itemCount": items.count]
        }
        let gate = RenderLayoutGate()
        let old = Task { try await gate.value() }
        defer { old.cancel(); Task { await gate.release(Data("[]".utf8)) } }
        var obsoleteFinished = false
        renderer.render(on: webView, items: [], imageSize: webView.bounds.size, sourceRect: webView.bounds,
                        settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", preparedLayout: old) {
            obsoleteFinished = $0.outcome == .stale
        }
        await Task.yield()
        let payload = try JSONSerialization.data(withJSONObject: [["text": "준비된 번역", "x": 12, "y": 18]])
        let fresh = Task<Data, Error> { payload }
        var freshFinished = false
        renderer.render(on: webView, items: [], imageSize: webView.bounds.size, sourceRect: webView.bounds,
                        settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", preparedLayout: fresh) {
            freshFinished = $0.outcome == .committed
        }
        let deadline = Date().addingTimeInterval(3)
        while !freshFinished {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        await gate.release(try JSONSerialization.data(withJSONObject: [["text": "오래된 번역"]]))
        while !obsoleteFinished {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(committed == ["준비된 번역"])
        // Late completion of the old shared task must not invalidate the
        // current revision's pending bitmap capture.
        #expect(renderer.lastDiagnostic?.outcome == .committed)
    }

    @Test @MainActor func renderCommitsBeforeCacheGenerationAndLayoutPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let gate = RenderLayoutGate()
        let generation = Task<UInt64, Never> { _ = try? await gate.value(); return 0 }
        defer { generation.cancel(); Task { await gate.release(Data()) } }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let renderer = BrowserPageImageOverlayRenderer { _, _, arguments in
            let persisted = try await disk.contains("visible-layout", kind: .layout)
            #expect(!persisted,
                    "Disk persistence must follow, not precede, screen rendering")
            return ["status": "committed", "revision": arguments["revision"] ?? "", "itemCount": 0]
        }
        renderer.render(on: webView, items: [], imageSize: webView.bounds.size, sourceRect: webView.bounds,
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko",
            layoutCache: disk, layoutCacheKey: "visible-layout", cacheGenerationTask: generation)
        let deadline = Date().addingTimeInterval(3)
        while renderer.lastDiagnostic?.outcome != .committed {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await !disk.contains("visible-layout", kind: .layout))
        await gate.release(Data())
        while try await !disk.contains("visible-layout", kind: .layout) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(renderer.lastDiagnostic?.outcome == .committed)
    }

    @Test @MainActor func offscreenWebKitLoadsWhileLayoutIsStillBlocked() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = RenderCountingWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory, byteLimit: 10_000_000)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let viewport = CGSize(width: 320, height: 480)
        let image = UIGraphicsImageRenderer(size: viewport).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: viewport))
        }
        let imageView = UIImageView(image: image)
        imageView.frame = CGRect(origin: .zero, size: viewport)
        imageView.contentMode = .scaleAspectFit
        controller.view.addSubview(imageView)
        let reader = ReaderTranslationPage(imageView: imageView)
        var page = Page(sourceId: "render-speed-test", chapterId: UUID().uuidString, index: 0)
        page.image = image
        reader.sourcePage = page
        let region = ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2),
                                             source: "source", translation: "준비된 번역")
        var settings = ReaderTranslationSettings()
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        let payload = try await BrowserPageImageOverlayRenderer.prepareLayoutData(
            items: [region.overlayItem(index: 0, imageSize: viewport)], imageSize: viewport,
            sourceRect: CGRect(origin: .zero, size: viewport), settings: settings.overlay,
            targetLanguage: settings.targetLanguage, viewport: viewport
        )
        let gate = RenderLayoutGate()
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache) { _, _, _, _, _, _ in
            try await gate.value()
        }
        let geometry = ReaderTranslationLayoutGeometry(page: reader, imageView: imageView)
        let preparation = Task {
            try await preparer.prepare(page: page, regions: [region], settings: settings, geometry: geometry, window: window)
        }
        defer { preparation.cancel(); Task { await gate.release(payload) } }
        let deadline = Date().addingTimeInterval(10)
        var loadedOverlay: ReaderTranslationOverlayView?
        while loadedOverlay == nil {
            guard Date() < deadline else { throw URLError(.timedOut) }
            if await gate.started,
               let overlay = window.subviews.compactMap({ $0 as? ReaderTranslationOverlayView }).first {
                overlay.layoutIfNeeded()
                let loaded = try? await overlay.webView.evaluateJavaScript(
                    "document.getElementById('reader-source-image')?.naturalWidth > 0"
                ) as? Bool
                if loaded == true { loadedOverlay = overlay }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(loadedOverlay?.didStoreSnapshot == false)
        #expect(loadedOverlay?.lastDiagnostic == nil)
        await gate.release(payload)
        try await preparation.value
        let key = ReaderTranslationCacheIdentity.render(page: page.translationCacheKey, settings: settings,
            imageSize: image.size, viewport: viewport, scale: geometry.scale, aspectFit: true,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: geometry.dark)
        #expect(cache.cachedImage(for: key) != nil)
        #expect(window.overlayInsertions == 1, "Prerender must not render a live overlay before rendering its cache bitmap")
        #expect(await gate.calls == 1)
        ReaderTranslationImageExporter.clearIdleRenderer()
    }
    @Test @MainActor func distantPageSavesOnlyLayoutAndBecomesAnImageWithoutRecalculating() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let image = ReaderTranslationPersistentPipelineTests.image()
        let imageView = UIImageView(image: image)
        imageView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        imageView.contentMode = .scaleAspectFit
        let reader = ReaderTranslationPage(imageView: imageView)
        let page = Page(sourceId: "layout-only", chapterId: "chapter", index: 9, image: image)
        reader.sourcePage = page
        let settings = ReaderTranslationSettings()
        let regions = [ReaderTranslationPersistentPipelineTests.region]
        let geometry = ReaderTranslationLayoutGeometry(page: reader, imageView: imageView)
        let key = ReaderTranslationCacheIdentity.render(page: page.translationCacheKey, settings: settings,
                                                        imageSize: image.size, viewport: imageView.bounds.size,
                                                        scale: geometry.scale, aspectFit: true,
                                                        crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: geometry.dark)
        // Text-only preparation consumes dimensions recorded when OCR processed
        // the page; a brand-new cache deliberately cannot infer them from pixels.
        let generation = await disk.currentGeneration(settings: settings)
        try await disk.storeImageSize(image.size, page: page.translationCacheKey, generation: generation)
        cache.setNearbyPages(pageKeys: ["some other page"], settings: settings)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache)
        try await preparer.prepare(page: page, regions: regions, settings: settings, geometry: geometry, window: window)
        let saved = try #require(try await disk.data(for: key, kind: .layout))
        #expect(cache.cachedImage(for: key) == nil)
        #expect(window.subviews.allSatisfy { !($0 is ReaderTranslationOverlayView) })
        #expect(try await disk.imageSize(page: page.translationCacheKey) == image.size)
        #expect(try await disk.contains(key, kind: .layout))
        #expect(try await disk.contains(key, kind: .snapshot) == false)
        #expect(try await disk.statistics().entries == 2)
        cache.setNearbyPages(pageKeys: [page.translationCacheKey], settings: settings)
        let restored = ReaderTranslationLayoutPreparer(renderCache: cache) { _, _, _, _, _, _ in
            Issue.record("Revisiting must reuse the saved layout, without computing it again")
            throw URLError(.cannotDecodeContentData)
        }
        try await restored.prepare(page: page, regions: regions, settings: settings, geometry: geometry, window: window)
        #expect(cache.cachedImage(for: key) != nil)
        var replayMilliseconds: [Double] = []
        for _ in 0..<5 {
            ReaderTranslationImageExporter.clearIdleRenderer()
            let reopened = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
            let replay = ReaderTranslationLayoutPreparer(renderCache: reopened) { _, _, _, _, _, _ in
                Issue.record("Disk layout replay must not recalculate typography")
                throw URLError(.cannotDecodeContentData)
            }
            let start = ProcessInfo.processInfo.systemUptime
            try await replay.prepare(page: page, regions: regions, settings: settings, geometry: geometry, window: window)
            replayMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let bitmap = try #require(reopened.cachedImage(for: key))
            #expect(bitmap.size.width > 0 && bitmap.size.height > 0)
            #expect(reopened.cachedLayout(for: key) == saved)
            let output = URL.documentsDirectory.appendingPathComponent("cache-replay.png")
            try #require(bitmap.pngData()).write(to: output)
        }
        print("DISK_LAYOUT_REPLAY_MS=\(replayMilliseconds) median=\(replayMilliseconds.sorted()[2])")
        ReaderTranslationImageExporter.clearIdleRenderer()
        #expect(try await disk.data(for: key, kind: .layout) == saved)
        #expect(try await disk.imageSize(page: page.translationCacheKey) == image.size)
        #expect(try await disk.contains(key, kind: .layout))
        #expect(try await disk.contains(key, kind: .snapshot) == false)
        #expect(try await disk.statistics().entries == 2)
    }

    /// Compare both paths in one binary so concurrent workspace changes and
    /// separate build/run startup cannot masquerade as a cache speed improvement.
    @Test @MainActor func cachedSnapshotSinglePassMatchesLegacyPixels() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = RenderCountingWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        let viewport = CGSize(width: 320, height: 480)
        let image = ReaderTranslationPersistentPipelineTests.image()
        let regions = [ReaderTranslationPersistentPipelineTests.region]
        var settings = ReaderTranslationSettings()
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        let rect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: image.size, bounds: CGRect(origin: .zero, size: viewport), aspectFit: true)
        let data = try await BrowserPageImageOverlayRenderer.prepareLayoutData(
            items: ReaderTranslationRegion.overlayItems(regions, imageSize: image.size), imageSize: image.size,
            sourceRect: rect, settings: settings.overlay, targetLanguage: settings.targetLanguage, viewport: viewport)
        let prepared = Task<Data, Error> { data }
        var legacyTimes: [Double] = [], directTimes: [Double] = []
        for index in 0..<5 {
            ReaderTranslationImageExporter.clearIdleRenderer()
            let key = "legacy-\(index)"
            await cache.storeLayout(data, key: key, diskGeneration: 0)
            let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
            overlay.overrideUserInterfaceStyle = .light
            let legacyStart = ProcessInfo.processInfo.systemUptime
            let initialInsertions = window.overlayInsertions
            window.insertSubview(overlay, at: 0)
            overlay.update(regions: regions, imageSize: image.size, aspectFit: true, settings: settings, image: image,
                snapshotTarget: .init(cache: cache, key: key, pageIdentity: key, diskGeneration: 0,
                    viewport: viewport, dark: false, preparedLayout: prepared))
            let deadline = Date().addingTimeInterval(20)
            while !overlay.didStoreSnapshot {
                guard Date() < deadline else { overlay.cancelWork(); throw URLError(.timedOut) }
                overlay.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
            }
            legacyTimes.append((ProcessInfo.processInfo.systemUptime - legacyStart) * 1000)
            #expect(window.overlayInsertions - initialInsertions == 2)
            let legacy = try #require(cache.cachedImage(for: key)?.cgImage)
            overlay.cancelWork(); overlay.removeFromSuperview()
            ReaderTranslationImageExporter.clearIdleRenderer()
            let directStart = ProcessInfo.processInfo.systemUptime
            let directInsertions = window.overlayInsertions
            let direct = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: image, imageSize: image.size, regions: regions, settings: settings,
                viewport: viewport, scale: window.traitCollection.displayScale, aspectFit: true,
                host: window, dark: false, preparedLayout: prepared)
            directTimes.append((ProcessInfo.processInfo.systemUptime - directStart) * 1000)
            #expect(window.overlayInsertions - directInsertions == 1)
            let pixels = try #require(direct.cgImage)
            #expect(legacy.width == pixels.width && legacy.height == pixels.height)
            #expect(legacy.dataProvider?.data as Data? == pixels.dataProvider?.data as Data?)
        }
        print("SAME_BINARY_CACHE_RENDER_MS legacy=\(legacyTimes) direct=\(directTimes) legacyMedian=\(legacyTimes.sorted()[2]) directMedian=\(directTimes.sorted()[2])")
    }
}

@MainActor private final class RenderCountingWindow: UIWindow {
    var overlayInsertions = 0
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        if subview is ReaderTranslationOverlayView { overlayInsertions += 1 }
    }
}

private actor RenderLayoutGate {
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Data?
    private(set) var started = false
    private(set) var calls = 0
    func value() async throws -> Data {
        started = true
        calls += 1
        if let result { return result }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release(_ data: Data) {
        result = data
        continuation?.resume(returning: data)
        continuation = nil
    }
}
