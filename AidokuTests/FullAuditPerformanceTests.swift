import AidokuRunner
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Aidoku

/// Opt-in, foreground, dedicated empty simulator only. Copy this SAME file to
/// both snapshots. No external provider/model execution, database writes or resets.
@Suite(.serialized) @MainActor
struct FullAuditPerformanceTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("FullAuditPerformance/enabled").path)))
    func visibleScreensAndReaderImage() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("FullAuditPerformance")
        try #require(AppSettings.browse.sourceLists.get().isEmpty, "External source-list URLs must be absent")
        let loadedSources = await SourceManager.shared.getLoadedSources()
        try #require(loadedSources.allSatisfy { $0.key == LocalSourceRunner.sourceKey },
                     "Only the built-in local source is allowed")
        let counts = await CoreDataManager.shared.container.performBackgroundTask { context in
            [CoreDataManager.shared.getLibraryManga(context: context).count,
             CoreDataManager.shared.getHistory(context: context).count,
             CoreDataManager.shared.getSources(context: context).filter { $0.toData().id != LocalSourceRunner.sourceKey }.count]
        }
        try #require(counts == [0, 0, 0], "Use an empty dedicated simulator; never erase user data for this test")
        // SearchViewController normalizes and persists its source filters on load.
        // Preserve even this incidental setting in the dedicated simulator.
        let savedSearchFilters = UserDefaults.standard.object(forKey: "Search.filters")
        defer {
            if let savedSearchFilters { UserDefaults.standard.set(savedSearchFilters, forKey: "Search.filters") }
            else { UserDefaults.standard.removeObject(forKey: "Search.filters") }
        }
        try #require(!UserDefaults.standard.bool(forKey: "History.lockHistoryTab"))
        try #require(!UserDefaults.standard.bool(forKey: "Reader.liveText"))
        try #require(!AppSettings.dictionary.enable.get())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let oldWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        defer { window.isHidden = true; window.rootViewController = nil; oldWindow?.makeKey() }
        let runID = UUID().uuidString
        let runDirectory = directory.appendingPathComponent(runID)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let names = ["library", "history", "search", "settings"]
        var rows: [[String: Any]] = []
        func save() throws {
            let report: [String: Any] = [
                "schema": 2, "runID": runID, "pid": ProcessInfo.processInfo.processIdentifier,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "device": UIDevice.current.model, "screenScale": window.screen.scale,
                "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
                "processorCount": ProcessInfo.processInfo.processorCount,
                "physicalMemory": ProcessInfo.processInfo.physicalMemory,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "buildOptimization": _isDebugAssertConfiguration() ? "debug assertions enabled" : "optimized assertions",
                "databaseCountsLibraryHistoryExternalSources": counts,
                "loadedSourceKeys": loadedSources.map(\.key).sorted(), "rows": rows,
                "scope": "Real controllers/views attached to foreground window, layout plus two CADisplayLink callbacks. Screenshots captured after timing. Screen attachment is not proof of asynchronous data completion. finalReady is separately instrumented: History requires visible NO_HISTORY text; other screens only prove no visible spinner and three pixel-identical captures.",
                "notMeasured": ["app launch", "populated lists", "search results", "network", "download", "OCR",
                    "translation", "upscale", "full chapter controller", "scroll hitch trace", "true transient peak RSS",
                    "cold disk cache", "background resume", "physical device performance"]
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: runDirectory.appendingPathComponent("measurements.json"), options: .atomic)
        }
        func captureScreen() throws -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(drawn, "Window snapshot did not finish")
            return image
        }
        func screenshot(_ name: String) throws -> String {
            let image = try captureScreen()
            try #require(image.pngData()).write(to: runDirectory.appendingPathComponent(name + ".png"), options: .atomic)
            return try FullAuditPixels.hash(image)
        }
        func finalReady(_ name: String, screen: String, since start: Double) async throws -> [String: Any] {
            let expected = screen == "history" ? Aidoku.NSLocalizedString("NO_HISTORY") : nil
            let deadline = CACurrentMediaTime() + 10
            var previousHash: String?
            var identical = 0
            var captures = 0
            var instrumentationMS = 0.0
            var lastImage: UIImage?
            var lastHash = ""
            var evidence = FullAuditReadiness.Evidence()
            repeat {
                try Task.checkCancellation()
                let frames = FullAuditFrames()
                frames.start()
                defer { frames.cancel() }
                try await frames.finishAfterTwoFrames()
                let captureStart = CACurrentMediaTime()
                evidence = FullAuditReadiness.inspect(window)
                let image = try captureScreen()
                let hash = try FullAuditPixels.hash(image)
                instrumentationMS += (CACurrentMediaTime() - captureStart) * 1000
                captures += 1
                lastImage = image; lastHash = hash
                let semanticReady = expected.map { marker in
                    evidence.labels.contains { $0.contains(marker) }
                } ?? true
                if semanticReady && evidence.spinners == 0 {
                    identical = hash == previousHash ? identical + 1 : 1
                } else {
                    identical = 0
                }
                previousHash = hash
                if identical >= 3 { break }
            } while CACurrentMediaTime() < deadline
            let readyAt = CACurrentMediaTime()
            let ready = identical >= 3
            let filename = name + (ready ? "-final.png" : "-readiness-timeout.png")
            if let lastImage {
                try #require(lastImage.pngData()).write(to: runDirectory.appendingPathComponent(filename), options: .atomic)
            }
            #expect(ready, "Final readiness timed out for \(name); inspect saved PNG and accessibility labels")
            return ["ready": ready, "operationToFinalReadyMS": (readyAt - start) * 1000,
                    "criterion": expected == nil ? "no visible spinner plus three exact pixel-identical captures; semantic completion not asserted" :
                        "visible localized NO_HISTORY marker, no visible spinner, three exact pixel-identical captures",
                    "semanticMarker": expected ?? "not required", "consecutiveIdenticalCaptures": identical,
                    "captures": captures, "captureAndEvidenceInstrumentationMS": instrumentationMS,
                    "timingCaveat": "Includes initial screenshot and readiness capture/hash overhead; not an uninstrumented display latency",
                    "visibleSpinnerCount": evidence.spinners, "accessibilityLabels": evidence.labels.sorted(),
                    "traversalLimitReached": evidence.limitReached,
                    "screenshot": filename, "screenshotPixelSHA256": lastHash]
        }
        func makeController(_ index: Int) -> UIViewController {
            switch index {
            case 0: return LibraryViewController()
            case 1: return UIHostingController(rootView: HistoryView()
                .environmentObject(NavigationCoordinator(rootViewController: nil)))
            case 2: return SearchViewController()
            default: return UIHostingController(rootView: SettingsView()
                .environmentObject(NavigationCoordinator(rootViewController: nil)))
            }
        }
        // Fresh controller presentations: first observation + five repetitions.
        // Services can already be warm; these samples are NOT cold app launches.
        for index in names.indices {
            for iteration in 0..<6 {
                let probe = FullAuditFrames()
                defer { probe.cancel() }
                probe.start()
                let controller = UINavigationController(rootViewController: makeController(index))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                try await probe.finishAfterTwoFrames()
                try #require(controller.view.window === window)
                var row = probe.metrics
                let label = "\(names[index])-presentation-\(iteration)"
                row["scenario"] = names[index] + "_fresh_controller_presentation"
                row["iteration"] = iteration
                row["cacheState"] = iteration == 0 ? "first_observed_services_unspecified" : "same_process_repeat"
                row["screenshot"] = label + ".png"
                row["screenshotPixelSHA256"] = try screenshot(label)
                row["finalReady"] = try await finalReady(label, screen: names[index], since: probe.measurementStart)
                rows.append(row)
                try save()
            }
        }
        // Real tab selection/revisits, including actual appearance transitions.
        let tabs = UITabBarController()
        tabs.viewControllers = names.indices.map { index in
            let nav = UINavigationController(rootViewController: makeController(index))
            nav.tabBarItem = UITabBarItem(title: names[index], image: nil, tag: index)
            return nav
        }
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        let settle = FullAuditFrames(); settle.start(); try await settle.finishAfterTwoFrames()
        for iteration in 0..<6 {
            for index in names.indices.reversed() {
                let probe = FullAuditFrames(); defer { probe.cancel() }; probe.start()
                tabs.selectedIndex = index
                tabs.view.layoutIfNeeded()
                try await probe.finishAfterTwoFrames()
                try #require(tabs.selectedViewController?.view.window === window)
                var row = probe.metrics
                let label = "\(names[index])-tab-\(iteration)"
                row["scenario"] = names[index] + "_tab_selection"
                row["iteration"] = iteration
                row["cacheState"] = iteration == 0 ? "first_tab_cycle" : "same_controller_revisit"
                row["screenshot"] = label + ".png"
                row["screenshotPixelSHA256"] = try screenshot(label)
                row["finalReady"] = try await finalReady(label, screen: names[index], since: probe.measurementStart)
                rows.append(row); try save()
            }
        }
        let fixture = try FullAuditPixels.fixture()
        let sourceHash = try FullAuditPixels.hash(fixture)
        let bytes = try #require(fixture.pngData())
        try bytes.write(to: runDirectory.appendingPathComponent("source.png"), options: .atomic)
        let host = UIViewController()
        host.view.backgroundColor = .white
        window.rootViewController = host
        window.makeKeyAndVisible()
        for iteration in 0..<6 {
            let probe = FullAuditFrames(); defer { probe.cancel() }; probe.start()
            let image = try #require(UIImage(data: bytes))
            let view = ReaderPageView(parent: host, temporaryPageStore: ReaderTemporaryPageStore())
            view.frame = host.view.bounds
            host.view.addSubview(view)
            defer { view.releasePageResources(); view.removeFromSuperview() }
            let page = Aidoku.Page(sourceId: "full-audit-local", chapterId: "fixed-fixture", index: 0, image: image)
            try #require(await view.setPage(page, skipProcessing: true))
            view.layoutIfNeeded()
            try await probe.finishAfterTwoFrames()
            let displayed = try #require(view.imageView.image)
            try #require(view.imageView.window === window)
            let displayedHash = try FullAuditPixels.hash(displayed)
            #expect(displayedHash == sourceHash)
            var row = probe.metrics
            let label = "reader-image-\(iteration)"
            row["scenario"] = "reader_page_png_decode_and_visible_image"
            row["iteration"] = iteration
            row["cacheState"] = "new_UIImage_same_fixed_bytes_no_network_cache"
            row["processing"] = "skipProcessing=true; excludes crop, upscale, OCR and translation"
            row["sourcePixelSHA256"] = sourceHash
            row["displayedImagePixelSHA256"] = displayedHash
            row["sourceEncodedSHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            row["screenshot"] = label + ".png"
            row["screenshotPixelSHA256"] = try screenshot(label)
            row["finalReady"] = try await finalReady(label, screen: "reader", since: probe.measurementStart)
            rows.append(row); try save()
        }
    }
}

/// Main-run-loop heartbeat and resident memory samples; not an Instruments hitch
/// classifier or allocation high-water mark. Screenshot costs excluded from timer.
@MainActor private final class FullAuditFrames: NSObject {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var startTime = 0.0
    private var previousTime = 0.0
    private var gaps: [Double] = []
    private var rss: [Double] = []
    private var callbacksAfterFinish = 0
    private var endTime = 0.0
    var measurementStart: Double { startTime }
    func start() {
        startTime = CACurrentMediaTime(); previousTime = startTime
        rss = [Self.residentMiB()]
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    func finishAfterTwoFrames() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.stop(error: FullAuditError.displayTimeout)
            }
        }
    }
    @objc private func tick() {
        let now = CACurrentMediaTime()
        gaps.append((now - previousTime) * 1_000); previousTime = now
        rss.append(Self.residentMiB())
        if continuation != nil {
            callbacksAfterFinish += 1
            if callbacksAfterFinish >= 2 { stop(error: nil) }
        }
    }
    private func stop(error: Error?) {
        endTime = CACurrentMediaTime()
        link?.invalidate(); link = nil
        timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func cancel() {
        if link != nil { stop(error: CancellationError()) }
    }
    var metrics: [String: Any] {
        ["visibleAfterTwoFramesMS": (endTime - startTime) * 1_000,
         "mainRunLoopCallbackGapsMS": gaps, "largestCallbackGapMS": gaps.max() ?? 0,
         "rssBeforeMiB": rss.first ?? -1, "rssAfterMiB": rss.last ?? -1,
         "sampledPeakRSSMiB": rss.max() ?? -1, "rssSamples": rss.count]
    }
    private static func residentMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}
private enum FullAuditError: Error { case displayTimeout }
@MainActor private enum FullAuditPixels {
    static func fixture() throws -> UIImage {
        let size = CGSize(width: 640, height: 960)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            for y in 0..<24 {
                for x in 0..<16 {
                    UIColor(red: CGFloat(x) / 15, green: CGFloat(y) / 23,
                            blue: (x + y).isMultiple(of: 2) ? 0.2 : 0.8, alpha: 1).setFill()
                    context.fill(CGRect(x: x * 40, y: y * 40, width: 40, height: 40))
                }
            }
        }
    }
    static func hash(_ image: UIImage) throws -> String {
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width,
                height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Read the displayed public UIKit accessibility tree, including SwiftUI's
/// virtual accessibility containers. No view-model/private-state inspection.
@MainActor private enum FullAuditReadiness {
    struct Evidence {
        var labels: Set<String> = []
        var spinners = 0
        var limitReached = false
    }
    static func inspect(_ window: UIWindow) -> Evidence {
        var result = Evidence()
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject) {
            guard visited.count < 4096 else { result.limitReached = true; return }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                guard !view.isHidden, view.alpha > 0.01,
                      view === window || window.convert(view.bounds, from: view).intersects(window.bounds) else { return }
                if let spinner = view as? UIActivityIndicatorView, spinner.isAnimating { result.spinners += 1 }
                if let label = view as? UILabel, let text = label.text, !text.isEmpty { result.labels.insert(text) }
                for child in view.subviews { visit(child) }
            }
            if let label = object.accessibilityLabel, !label.isEmpty { result.labels.insert(label) }
            if let elements = object.accessibilityElements {
                for case let element as NSObject in elements { visit(element) }
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 512 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject { visit(element) }
                }
            } else if count != NSNotFound && count >= 512 { result.limitReached = true }
        }
        visit(window)
        return result
    }
}
