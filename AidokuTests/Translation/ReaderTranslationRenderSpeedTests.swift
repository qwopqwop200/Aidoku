import CoreGraphics
import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationRenderSpeedTests {
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

    @Test @MainActor func offscreenWebKitLoadsWhileLayoutIsStillBlocked() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
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
        #expect(loadedOverlay?.didStoreSnapshot == true)
        #expect(await gate.calls == 1)
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
        cache.setNearbyPages(pageKeys: ["some other page"], settings: settings)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache)
        try await preparer.prepare(page: page, regions: regions, settings: settings, geometry: geometry, window: window)
        let saved = try #require(try await disk.data(for: key, kind: .layout))
        #expect(cache.cachedImage(for: key) == nil)
        #expect(window.subviews.allSatisfy { !($0 is ReaderTranslationOverlayView) })
        #expect(try await disk.statistics().entries == 1)
        cache.setNearbyPages(pageKeys: [page.translationCacheKey], settings: settings)
        let restored = ReaderTranslationLayoutPreparer(renderCache: cache) { _, _, _, _, _, _ in
            Issue.record("Revisiting must reuse the saved layout, without computing it again")
            throw URLError(.cannotDecodeContentData)
        }
        try await restored.prepare(page: page, regions: regions, settings: settings, geometry: geometry, window: window)
        #expect(cache.cachedImage(for: key) != nil)
        #expect(try await disk.data(for: key, kind: .layout) == saved)
        #expect(try await disk.statistics().entries == 1)
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
