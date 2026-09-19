import Darwin
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderContinuousRenderingTests {
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

    private static func footprintMiB() -> Double {
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
