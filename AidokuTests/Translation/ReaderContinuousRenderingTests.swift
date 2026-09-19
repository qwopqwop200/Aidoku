import Darwin
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderContinuousRenderingTests {
    /// Deterministic simulator soak of the actual renderer/cache, without model or API variability.
    @Test func longPagePrerenderMemorySoak() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.overlay.visible = true
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var available: UInt64 = 2_048 * 1_024 * 1_024
        let session = ReaderTranslationSession(process: { _, _, _ in [] }, renderCache: cache,
                                                availableMemory: { available })
        defer { session.close() }
        let output = URL.documentsDirectory.appendingPathComponent("ReaderMemoryInvestigation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        let initial = Self.footprintMiB()
        let monitor = Task.detached { () -> [Double] in
            var samples: [Double] = []
            while !Task.isCancelled {
                samples.append(Self.footprintMiB())
                try? await Task.sleep(for: .milliseconds(20))
            }
            return samples
        }
        defer { monitor.cancel() }
        for index in 0..<30 {
            let keys = (max(0, index - 6)...index).reversed().map { "soak-\($0)" }
            available = (index >= 10 && index < 15 ? 1_280 : 2_048) * 1_024 * 1_024
            cache.setNearbyPages(pageKeys: keys, settings: settings, availableMemory: available)
            try await Self.renderSyntheticLongPage(index: index, settings: settings, window: window,
                                                   cache: cache, output: output)
            #expect(cache.bitmapBytes <= cache.currentBitmapByteLimit)
            #expect(window.rootViewController?.view.subviews.isEmpty == true)
            if index == 14 {
                _ = session.handleMemoryWarning()
                #expect(cache.bitmapBytes == 0)
                #expect(cache.layoutBytes == 0)
            }
            try await Task.sleep(for: .milliseconds(100))
            rows.append(["page": index + 1, "footprintMiB": Self.footprintMiB(),
                         "bitmapMiB": Double(cache.bitmapBytes) / 1_048_576,
                         "budgetMiB": Double(cache.currentBitmapByteLimit) / 1_048_576,
                         "nearbyPages": cache.nearbyPageCount])
            print("PRERENDER_SOAK page=\(index + 1) footprintMiB=\(Self.footprintMiB()) bitmapBytes=\(cache.bitmapBytes)")
        }
        let early = rows[5..<10].compactMap { $0["footprintMiB"] as? Double }.max() ?? initial
        let late = rows[25..<30].compactMap { $0["footprintMiB"] as? Double }.max() ?? initial
        #expect(late - early < 128, "Warm app footprint must not grow without bound across repeated full-page rendering")
        session.close()
        #expect(cache.bitmapBytes == 0)
        #expect(cache.layoutBytes == 0)
        ReaderTranslationImageExporter.clearIdleRenderer()
        try await Task.sleep(for: .milliseconds(500))
        monitor.cancel()
        let samples = await monitor.value
        let report: [String: Any] = ["initialMiB": initial, "afterCloseMiB": Self.footprintMiB(),
            "sampledPeakMiB": samples.max() ?? initial, "samplingIntervalMS": 20, "samplesMiB": samples,
            "warmGrowthMiB": late - early, "rows": rows,
            "scope": "Synthetic 600x6000 pages; real WebKit and bitmap cache. App physical footprint only, excluding WebKit child processes. Injected headroom; no OCR/provider or device Jetsam simulation."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("prerender-soak.json"), options: .atomic)
    }

    private static func renderSyntheticLongPage(index: Int, settings: ReaderTranslationSettings,
        window: UIWindow, cache: ReaderTranslationRenderCache, output: URL) async throws {
        let size = CGSize(width: 600, height: 6000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            for row in 0..<10 {
                UIColor(white: row % 2 == 0 ? 0.8 : 0.95, alpha: 1).setFill()
                context.fill(CGRect(x: 20, y: row * 600 + 30, width: 560, height: 400))
            }
        }
        let regions = (0..<10).map { row in
            ReaderTranslationRegion(id: "r-\(row)", rect: CGRect(x: 0.15, y: Double(row) / 10 + 0.02, width: 0.7, height: 0.035),
                source: "Long page \(index) row \(row)", translation: "긴 페이지 메모리 검증 \(index) · \(row)")
        }
        let key = "soak-\(index)"
        let viewport = CGSize(width: 320, height: 3200)
        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
        window.rootViewController?.view.addSubview(overlay)
        defer { overlay.cancelWork(); overlay.removeFromSuperview() }
        overlay.update(regions: regions, imageSize: size, aspectFit: false, settings: settings, image: image,
            snapshotTarget: .init(cache: cache, key: key,
                pageIdentity: ReaderTranslationCacheIdentity.translation(page: key, settings: settings),
                diskGeneration: await cache.disk.currentGeneration(settings: settings), viewport: viewport, dark: false))
        let deadline = Date().addingTimeInterval(30)
        while !overlay.didStoreSnapshot {
            try #require(Date() < deadline, "Long-page snapshot timed out")
            if case .failed = overlay.lastDiagnostic?.outcome { throw URLError(.cannotDecodeContentData) }
            overlay.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        let snapshot = try #require(cache.cachedImage(for: key))
        #expect(snapshot.size.height / snapshot.size.width > 9)
        if index == 29 {
            try #require(snapshot.pngData()).write(to: output.appendingPathComponent("prerender-soak-last.png"))
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("LookaheadDevice/manifest.json").path)))
    func continuousOCRAndRendering() async throws {
        try await run(rootName: "LookaheadDevice", count: 18, delay: 150, outputName: "rendering")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("ReaderSoak/manifest.json").path)))
    func sustainedOCRAndRendering() async throws {
        try await run(rootName: "ReaderSoak", count: 600, delay: 500, outputName: "soak")
    }

    private func run(rootName: String, count: Int, delay: Int, outputName: String) async throws {
        struct Fixture: Decodable { let id: String; let image: String }
        let root = URL.documentsDirectory.appendingPathComponent(rootName)
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try #require(!fixtures.isEmpty, "Rendering memory investigation requires at least one fixture")
        let output = URL.documentsDirectory.appendingPathComponent("ReaderMemoryInvestigation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let disk = ReaderTranslationDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let cache = ReaderTranslationRenderCache(disk: disk)
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.overlay.visible = true
        var rows: [[String: Any]] = []
        await ReaderOCRService.shared.purge()
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            let fixture = fixtures[index % fixtures.count]
            let regionCount = try await Self.render(root.appendingPathComponent(fixture.image), index: index, settings: settings,
                                  window: window, cache: cache, output: output, last: index == count - 1, cancelFirst: outputName == "soak" && index % 10 == 0)
            try await Task.sleep(for: .milliseconds(delay))
            rows.append(["page": index + 1, "fixture": fixture.id, "regions": regionCount, "footprintMiB": Self.footprintMiB(),
                         "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                         "availableMiB": Double(os_proc_available_memory()) / 1_048_576,
                         "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
            if index % 20 == 19 { print("SOAK_PROGRESS page=\(index + 1) footprint=\(Self.footprintMiB())") }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("\(outputName).json"), options: .atomic)
        }
        if count >= 600 {
            let early = rows[100..<200].compactMap { $0["footprintMiB"] as? Double }.sorted()
            let late = rows[(count - 100)..<count].compactMap { $0["footprintMiB"] as? Double }.sorted()
            #expect(late[50] - early[50] < 128, "Sustained footprint growth exceeds 128 MiB")
        }
        cache.clearMemory()
        // Drop the test-only persistent cache's SQLite handle and temporary files,
        // then release the visible hierarchy before measuring post-exit recovery.
        try await disk.clear()
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
        await ReaderOCRService.shared.purge()
        try await Task.sleep(for: .milliseconds(500))
        rows.append(["afterPurgeMiB": Self.footprintMiB(),
                     "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("\(outputName).json"), options: .atomic)
    }

    private static func render(_ url: URL, index: Int, settings: ReaderTranslationSettings,
                               window: UIWindow, cache: ReaderTranslationRenderCache, output: URL, last: Bool, cancelFirst: Bool) async throws -> Int {
        let image = try #require(UIImage(contentsOfFile: url.path))
        let pixels = try #require(image.cgImage)
        let regions = try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration).map {
            var value = $0
            value.translation = "메모리 검증용 한국어 문장이랍니다."
            return value
        }
        let page = "memory-render-\(index)"
        cache.setNearbyPages(pageKeys: [page], settings: settings)
        let identity = ReaderTranslationCacheIdentity.translation(page: page, settings: settings)
        let viewport = CGSize(width: 390, height: 650)
        if cancelFirst {
            let cancelled = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
            cancelled.overrideUserInterfaceStyle = .light
            window.rootViewController?.view.addSubview(cancelled)
            cancelled.update(regions: regions, imageSize: image.size, aspectFit: true, settings: settings, image: image)
            cancelled.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            cancelled.cancelWork()
            cancelled.removeFromSuperview()
        }
        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
        overlay.overrideUserInterfaceStyle = .light
        window.rootViewController?.view.addSubview(overlay)
        defer { overlay.cancelWork(); overlay.removeFromSuperview() }
        overlay.update(regions: regions, imageSize: image.size, aspectFit: true, settings: settings, image: image,
            snapshotTarget: .init(cache: cache, key: page, pageIdentity: identity,
                diskGeneration: await cache.disk.currentGeneration(settings: settings), viewport: viewport, dark: false))
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !overlay.didStoreSnapshot && !(regions.isEmpty && overlay.lastDiagnostic?.outcome == .cleared) && ProcessInfo.processInfo.systemUptime < deadline {
            overlay.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        if regions.isEmpty {
            try #require(overlay.lastDiagnostic?.outcome == .cleared)
            return 0
        }
        if !overlay.didStoreSnapshot {
            print("RENDER_STATE app=\(UIApplication.shared.applicationState.rawValue) scene=\(window.windowScene?.activationState.rawValue ?? -99) key=\(window.isKeyWindow) progress=\(overlay.webView.estimatedProgress) loading=\(overlay.webView.isLoading)")
            do {
                let state = try await overlay.webView.evaluateJavaScript("JSON.stringify({ready:document.readyState, image:document.getElementById('reader-source-image')?.complete, width:innerWidth, height:innerHeight})")
                print("RENDER_DOCUMENT \(String(describing: state))")
            } catch { print("RENDER_DOCUMENT_ERROR \(error)") }
        }
        try #require(overlay.lastDiagnostic?.outcome == .committed)
        try #require(overlay.didStoreSnapshot)
        if last {
            try #require(cache.cachedImage(for: page)?.pngData()).write(to: output.appendingPathComponent("last-render.png"))
        }
        return regions.count
    }

    private nonisolated static func footprintMiB() -> Double {
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
