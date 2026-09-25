import Darwin
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Explicit device opt-in: real local fixtures, default OCR and saved live provider.
/// No source downloads, simulated translations, saved-setting writes or user-cache purge.
@Suite(.serialized) @MainActor
struct ReaderSustainedPipelineDeviceTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("PipelineOptimization/sustained.json").path)))
    func sustainedLivePipelineNavigation() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("PipelineOptimization")
        let marker = output.appendingPathComponent("sustained.json")
        defer { try? FileManager.default.removeItem(at: marker) }
        struct RunConfiguration: Decodable { var cycles: Int?; var dwellMilliseconds: Int? }
        let runConfiguration = try JSONDecoder().decode(RunConfiguration.self, from: Data(contentsOf: marker))
        let cycles = min(20, max(1, runConfiguration.cycles ?? 1))
        let dwellMilliseconds = min(5000, max(0, runConfiguration.dwellMilliseconds ?? 0))
        #if targetEnvironment(simulator)
        throw SustainedFailure.physicalDeviceRequired
        #else
        struct Fixture: Decodable { let id: String; let image: String }
        let fixtureRoot = URL.documentsDirectory.appendingPathComponent("LookaheadDevice")
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("manifest.json")))
        try #require(fixtures.count >= 3)
        var settings = ReaderTranslationSettings()
        settings.overlay.visible = true // Local value only; never persisted.
        try #require(try KeychainTranslationCredentialStore().containsSecret(for: settings.selectedCredentialAccount))
        _ = try settings.configuration.validatedEndpoint()
        let runID = UUID().uuidString
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sustained-" + runID)
        let disk = ReaderTranslationDiskCache(directory: cacheRoot)
        let renderCache = ReaderTranslationRenderCache(disk: disk)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: renderCache)
        let preloader = ReaderTranslationPreloader(diskCache: disk)
        let loader = ReaderTranslationImageLoader()
        let pages = (0..<12).map { index in
            Page(sourceId: "sustained-device", chapterId: runID, index: index,
                 imageURL: fixtureRoot.appendingPathComponent(fixtures[index % 3].image).absoluteString)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let imageView = UIImageView(frame: window.bounds)
        imageView.contentMode = .scaleAspectFit
        window.rootViewController?.view.addSubview(imageView)
        var reader = ReaderTranslationPage(imageView: imageView)
        let monitor = SustainedMemoryMonitor()
        let warning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in monitor.warning() }
        let sampling = Task.detached {
            while !Task.isCancelled {
                monitor.sample()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        var rows: [[String: Any]] = []
        let startedAt = Date().timeIntervalSince1970
        var failureCode: Int?
        let session = ReaderTranslationSession(process: { page, value, progress in
            try await preloader.translate(page, settings: value, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() },
           cancelProcessingForPage: { preloader.cancel(preservingRecognitionFor: $0) },
           diskCache: disk, renderCache: renderCache, prepareLayout: { page, regions, value in
            try await preparer.prepare(page: page, regions: regions, settings: value,
                geometry: ReaderTranslationLayoutGeometry(page: reader, imageView: imageView), window: window)
        })
        session.onFailure = { failureCode = ($0 as NSError).code }
        preloader.nextPage = { [weak session] page in session?.nextPageForRecognition(after: page) }
        preloader.onPrepared = { [weak session] page, regions, value in
            session?.receivePrepared(page, regions: regions, settings: value)
        }
        defer {
            session.close()
            preloader.cancel()
            reader.releaseOverlay()
            sampling.cancel()
            NotificationCenter.default.removeObserver(warning)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            // Leave the isolated temporary cache to normal temp cleanup: cancelled
            // disk stores may still be finishing and must not race directory removal.
        }
        func save(_ status: String) throws {
            var result: [String: Any] = [
                "status": status, "rows": rows, "startedAt": startedAt,
                "elapsedSeconds": Date().timeIntervalSince1970 - startedAt,
                "cycles": cycles, "memorySamples": monitor.samples,
                "appFootprintPeakMiB": monitor.peak, "memoryWarnings": monitor.warnings,
                "configuredConcurrency": settings.maximumConcurrentRequests,
                "scope": "Physical device; \(cycles * 12) navigation steps, 3 repeated local image fixtures, unique page identities, "
                    + "real OCR, saved live provider, session lookahead and rendered visible pages. "
                    + "Excludes source image network downloads and WebKit child-process memory. "
                    + "Provider semantic request cache may reuse repeated fixture text. "
                    + "No saved-setting writes or user-cache purge; shared services may update their normal caches.",
                "rendererEventCounts": Self.rendererEvents(since: startedAt)
            ]
            if let failureCode { result["lastFailureCode"] = failureCode }
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("sustained-results.json"), options: .atomic)
        }
        try save("running")
        // Adjacent forward/back, large jumps, then warmed revisits.
        let sequence = Array(repeating: [0, 1, 2, 7, 8, 3, 4, 11, 10, 5, 1, 0], count: cycles).flatMap { $0 }
        do {
            for (step, index) in sequence.enumerated() {
                let began = ProcessInfo.processInfo.systemUptime
                failureCode = nil
                session.pauseForPageTurn(preservingRecognitionFor: pages[index])
                reader.releaseOverlay()
                imageView.image = nil
                let image = try await TranslationImageWorkBudget.shared.withPermit { try await loader.load(pages[index]) }
                imageView.image = image
                reader = ReaderTranslationPage(imageView: imageView)
                reader.sourcePage = pages[index]
                reader.renderCache = renderCache
                preparer.sourceDidLoad(image, page: pages[index])
                session.update(items: ReaderTranslationSession.chapterItems(pages), visible: [reader],
                               context: runID, currentPageIndex: index)
                session.enable(settings: settings)
                let deadline = ProcessInfo.processInfo.systemUptime + max(90, settings.configuration.timeout + 30)
                while !Self.rendered(reader, imageView: imageView, settings: settings) {
                    if let failureCode { throw SustainedFailure.pipeline(failureCode) }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw SustainedFailure.renderTimeout }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try #require(reader.regions.contains { !($0.translation ?? "").isEmpty },
                             "The real fixture must produce completed translation, not an empty skipped page")
                monitor.sample()
                rows.append(["cycle": step / 12, "step": step, "page": index, "fixture": fixtures[index % 3].id,
                             "navigationToRenderMS": (ProcessInfo.processInfo.systemUptime - began) * 1000,
                             "regions": reader.regions.count, "cachedPresentation": reader.hasLoadedCachedPresentation,
                             "appFootprintMiB": SustainedMemoryMonitor.footprint(),
                             "availableMiB": Double(os_proc_available_memory()) / 1_048_576,
                             "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
                try save("running")
                try await Task.sleep(for: .milliseconds(max(dwellMilliseconds, step % 3 == 1 ? 3200 : 200)))
            }
            session.pauseForPageTurn()
            await session.flushPendingDiskStores()
            session.close()
            preloader.cancel()
            reader.releaseOverlay()
            imageView.image = nil
            // Observe retention after release without forcing synthetic memory pressure.
            try await Task.sleep(for: .seconds(10))
            monitor.sample()
            try save("completed")
        } catch {
            failureCode = (error as NSError).code
            try? save("failed")
            throw error
        }
        #endif
    }

    private static func rendered(_ page: ReaderTranslationPage, imageView: UIImageView,
                                 settings: ReaderTranslationSettings) -> Bool {
        guard page.hasCompletedTranslation(settings: settings) else { return false }
        if page.hasLoadedCachedPresentation || page.regions.isEmpty { return true }
        if imageView.subviews.contains(where: {
            $0.accessibilityIdentifier == "reader.translation.cachedOverlay" && !$0.isHidden
        }) { return true }
        return imageView.subviews.compactMap { $0 as? ReaderTranslationOverlayView }
            .contains { $0.lastDiagnostic?.outcome == .committed && !$0.webView.isHidden && !$0.isHidden }
    }

    private static func rendererEvents(since startedAt: TimeInterval) -> [String: Int] {
        let events = ["renderer_idle_created", "renderer_idle_reused", "renderer_export_finished", "render_asset_replayed"]
        var counts = Dictionary(uniqueKeysWithValues: events.map { ($0, 0) })
        for name in ["reader-memory-events.log", "reader-memory-events.previous.log"] {
            let text = (try? String(contentsOf: URL.documentsDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: " ").map(String.init)
                guard fields.contains("pid=\(ProcessInfo.processInfo.processIdentifier)"),
                      let time = fields.first(where: { $0.hasPrefix("time=") }).flatMap({ Double($0.dropFirst(5)) }),
                      time >= startedAt else { continue }
                for event in events where fields.contains("reader_event=" + event) { counts[event, default: 0] += 1 }
            }
        }
        return counts
    }
}

private enum SustainedFailure: Error { case physicalDeviceRequired, renderTimeout, pipeline(Int) }

private final class SustainedMemoryMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: Double = 0
    private var warningCount = 0
    private var observations: [[String: Double]] = []
    private var lastObservation: TimeInterval = 0
    var samples: [[String: Double]] { lock.withLock { observations } }
    var peak: Double { lock.withLock { maximum } }
    var warnings: Int { lock.withLock { warningCount } }
    func warning() { lock.withLock { warningCount += 1 } }
    func sample() {
        let value = Self.footprint()
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            maximum = max(maximum, value)
            if now - lastObservation >= 1 {
                observations.append(["uptime": now, "footprintMiB": value,
                    "availableMiB": Double(os_proc_available_memory()) / 1_048_576])
                lastObservation = now
            }
        }
    }
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
