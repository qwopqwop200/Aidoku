import Darwin
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderLookaheadOptimizationTests {
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
        let preparer = ReaderTranslationLayoutPreparer(imageBudget: budget)
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
