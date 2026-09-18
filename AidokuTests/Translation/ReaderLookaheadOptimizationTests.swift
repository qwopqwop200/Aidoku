import Darwin
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderLookaheadOptimizationTests {
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
        let data = try #require(cache.cachedLayout(for: key))
        #expect((try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.isEmpty == false)
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
        await cache.storeLayout(Data("[]".utf8), key: "snapshot", diskGeneration: 0)
        await cache.store(source, key: "snapshot", pageIdentity: "page", diskGeneration: 0)
        #expect(cache.cachedImage(for: "snapshot") === source)
        #expect(try await !disk.contains("snapshot", kind: .snapshot))
        cache.clearMemory()
        let reopened = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        #expect(await reopened.load("snapshot") == nil)
        #expect(await reopened.layoutData(for: "snapshot") == Data("[]".utf8))
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
        settings.filterJapaneseSFX = false
        settings.filterJapaneseSFXContext = false
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

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("LookaheadDevice/manifest.json").path)))
    func physicalDeviceLookaheadSnapshotsAndMemory() async throws {
        struct Fixture: Decodable { let id: String; let image: String }
        let root = URL.documentsDirectory.appendingPathComponent("LookaheadDevice")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"; settings.sourceLanguage = "ja"
        settings.translationSourceLanguages = []; settings.maximumConcurrentRequests = 2
        let hasCredential = (try? KeychainTranslationCredentialStore().containsSecret(for: settings.selectedCredentialAccount)) == true
        let configuration = settings.ocrConfiguration
        var frozen: [Int: [ReaderTranslationRegion]] = [:]
        var acquisition: [[String: Any]] = []
        let pages = fixtures.enumerated().map { index, fixture in
            Page(sourceId: "lookahead-device", chapterId: "isolated-fixtures", index: index,
                 imageURL: root.appendingPathComponent(fixture.image).absoluteString)
        }
        let startFootprint = Self.footprintMiB()
        let monitor = Task.detached { () -> [Double] in
            var samples: [Double] = []
            while !Task.isCancelled {
                samples.append(Self.footprintMiB())
                try? await Task.sleep(for: .milliseconds(20))
            }
            return samples
        }
        defer { monitor.cancel() }
        let loader = ReaderTranslationImageLoader()
        for page in pages {
            let began = ProcessInfo.processInfo.systemUptime
            let raw = try await TranslationImageWorkBudget.shared.withPermit {
                let image = try await loader.load(page)
                guard let pixels = image.cgImage else { throw URLError(.cannotDecodeContentData) }
                return try await ReaderOCRService.shared.recognize(image: pixels, configuration: configuration)
            }
            let regions = raw.enumerated().map { index, region in
                ReaderTranslationRegion(id: "p\(page.index)-\(index)", rect: region.rect, source: region.source,
                    polygon: region.polygon, confidence: region.confidence,
                    sourceImageAspectRatio: region.sourceImageAspectRatio, translationOrder: region.translationOrder,
                    translationOrderVersion: region.translationOrderVersion, sourceOrientation: region.sourceOrientation,
                    sourceSingleVerticalColumn: region.sourceSingleVerticalColumn,
                    translationReuseIdentity: region.translationReuseIdentity, sfxEnclosedBackground: region.sfxEnclosedBackground)
            }
            #expect(!regions.isEmpty)
            let ocrMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
            var mode = "fixed Korean test translations; credential unavailable"
            let apiStart = ProcessInfo.processInfo.systemUptime
            if hasCredential {
                let imageJPEG: Data?
                if settings.includePageImage {
                    imageJPEG = try await TranslationImageWorkBudget.shared.withPermit {
                        let image = try await loader.load(page)
                        return try autoreleasepool { try ReaderTranslationImagePreparation.translationJPEG(image) }
                    }
                } else { imageJPEG = nil }
                frozen[page.index] = try await ReaderTranslationService.shared.translate(
                    regions: regions, settings: settings, preparedImageJPEG: imageJPEG)
                mode = "saved provider; real OCR and Korean output"
            } else {
                frozen[page.index] = regions.map { region in
                    var value = region; value.translation = "미리 준비한 번역 문장입니다."; return value
                }
            }
            acquisition.append(["page": page.index, "ocrMS": ocrMS, "apiMS": (ProcessInfo.processInfo.systemUptime - apiStart) * 1000,
                                "mode": mode, "regions": regions.count])
            try JSONSerialization.data(withJSONObject: acquisition, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("acquisition.json"), options: .atomic)
        }
        // Reuse identical provider output for A/B scheduling: far-page latency
        // is controlled, while page decoding and WebKit rendering remain real.
        let translations = frozen
        settings.includePageImage = false
        settings.rightToLeftPanelOrder = false
        settings.filterJapaneseSFX = false; settings.filterJapaneseSFXContext = false
        let benchmarkSettings = settings
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        var rows: [[String: Any]] = []
        for overlap in [false, true] {
            let directory = root.appendingPathComponent(overlap ? "optimized-cache" : "reference-cache")
            try? FileManager.default.removeItem(at: directory)
            let disk = ReaderTranslationDiskCache(directory: directory)
            let renderCache = ReaderTranslationRenderCache(disk: disk)
            let preparer = ReaderTranslationLayoutPreparer(renderCache: renderCache)
            let imageView = UIImageView(frame: window.bounds); imageView.contentMode = .scaleAspectFit
            imageView.image = try await TranslationImageWorkBudget.shared.withPermit { try await loader.load(pages[0]) }
            window.rootViewController?.view.addSubview(imageView)
            let reader = ReaderTranslationPage(imageView: imageView); reader.sourcePage = pages[0]
            let geometry = ReaderTranslationLayoutGeometry(page: reader, imageView: imageView)
            let preloader = ReaderTranslationPreloader(diskCache: disk,
                translator: { regions, _, progress in
                    let index = Int(regions.first?.id.split(separator: "-").first?.dropFirst() ?? "0") ?? 0
                    try await Task.sleep(for: .milliseconds(index == 2 ? 2500 : 50))
                    let result = translations[index] ?? []
                    try await progress?(result)
                    return result
                }, recognizer: { page, _ in
                    (translations[page.index] ?? []).map { var row = $0; row.translation = nil; return row }
                })
            var nextReady: Double?
            let started = ProcessInfo.processInfo.systemUptime
            let session = ReaderTranslationSession(process: { page, settings, progress in
                try await preloader.translate(page, settings: settings, onProgress: progress)
            }, cancelProcessing: { preloader.cancel() }, cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) },
                diskCache: disk, renderCache: renderCache, prepareLayout: { page, regions, settings in
                    try await preparer.prepare(page: page, regions: regions, settings: settings, geometry: geometry, window: window)
                    if page.index == 1 { nextReady = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
                }, overlapsLayoutWithTranslation: overlap)
            preloader.nextPage = { [weak session] (page: Page) in session?.nextPageForRecognition(after: page) }
            session.update(items: pages.map(ReaderTranslationSession.Item.init), visible: [reader], context: "lookahead", currentPageIndex: 0)
            session.enable(settings: benchmarkSettings)
            do {
                try await waitUntil(seconds: 40) { nextReady != nil }
                let source = try await TranslationImageWorkBudget.shared.withPermit { try await loader.load(pages[1]) }
                session.pauseForPageTurn(preservingRecognitionFor: pages[1])
                imageView.image = source; reader.sourcePage = pages[1]
                let turn = ProcessInfo.processInfo.systemUptime
                reader.displayPrepared(translations[1] ?? [], settings: benchmarkSettings)
                try await waitUntil { reader.isUsingCachedRendering }
                rows.append(["overlap": overlap, "nextSnapshotReadyMS": nextReady!,
                    "cachedTurnMS": (ProcessInfo.processInfo.systemUptime - turn) * 1000,
                    "footprintMiB": Self.footprintMiB(), "cachedRendering": reader.isUsingCachedRendering])
                let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try screenshot.pngData()?.write(to: root.appendingPathComponent(overlap ? "optimized.png" : "reference.png"))
                // Exercise warning/close paths without forcing Jetsam.
                _ = session.handleMemoryWarning()
                renderCache.clearMemory()
                #expect(window.subviews.filter { $0 is ReaderTranslationOverlayView }.count <= 1)
            } catch {
                session.close(); preloader.nextPage = nil; reader.releaseOverlay(); imageView.removeFromSuperview()
                throw error
            }
            session.close(); preloader.nextPage = nil; reader.releaseOverlay(); imageView.removeFromSuperview()
            try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("scheduling.json"), options: .atomic)
        }
        monitor.cancel()
        let samples = await monitor.value
        try JSONSerialization.data(withJSONObject: ["startFootprintMiB": startFootprint,
            "peakFootprintMiB": samples.max() ?? 0, "endFootprintMiB": Self.footprintMiB(), "samples": samples,
            "scope": "App physical footprint only; excludes WebKit child process. Real OCR, optional saved provider acquisition, controlled 2500ms far-page replay, real WebKit snapshots."], options: [.sortedKeys])
            .write(to: root.appendingPathComponent("memory.json"), options: .atomic)
        await ReaderOCRService.shared.purge()
    }

    private func waitUntil(seconds: Double = 8, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private nonisolated static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
private actor LookaheadTestGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
