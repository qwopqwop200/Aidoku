import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Standalone opt-in harness; copy to AidokuTests only for a centrally scheduled build.
/// Exercises production memory-only presentation lookup, not OCR/API or actual webtoon gestures.
@Suite(.serialized) @MainActor
struct FullAuditRenderIdentityCostTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("FullAuditRenderIdentity/enabled").path)))
    func repeatedMissAndPreparedMemoryHit() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("FullAuditRenderIdentity")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view.backgroundColor = .white
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
            UIColor.black.setFill(); context.fill(CGRect(x: 20, y: 30, width: 80, height: 40))
        }
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(x: 20, y: 100, width: 240, height: 360)
        host.view.addSubview(imageView)
        let page = ReaderTranslationPage(imageView: imageView, recognize: { _, _ in
            Issue.record("OCR must not execute in cache-only cost harness"); return []
        }, translate: { _, _ in
            Issue.record("API must not execute in cache-only cost harness"); return []
        })
        let sourcePage = Aidoku.Page(sourceId: "audit-cost", chapterId: "one", index: 0, image: image)
        page.sourcePage = sourcePage
        let disk = ReaderTranslationDiskCache(directory: directory.appendingPathComponent(UUID().uuidString))
        let cache = ReaderTranslationRenderCache(disk: disk)
        page.renderCache = cache
        let suite = "FullAuditRenderIdentity-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let regions = [ReaderTranslationRegion(id: "r", rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.1), source: "Hello", translation: "안녕")]
        var rows: [[String: Any]] = []
        func save() throws {
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "scope": "Real displayed image and production memory-only lookup; fixed mocked regions; no OCR/API; synchronous burst costs are not end-to-end scroll timings",
                "rows": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("cost.json"), options: .atomic)
        }
        try await CostFrames().wait()
        try #require(imageView.window === window)
        for scenario in ["empty_memory_cache", "prepared_memory_hit"] {
            if scenario == "prepared_memory_hit" {
                let key = ReaderTranslationCacheIdentity.render(page: sourcePage.translationCacheKey, settings: settings,
                    imageSize: image.size, viewport: imageView.bounds.size, scale: imageView.traitCollection.displayScale,
                    aspectFit: true, crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: imageView.traitCollection.userInterfaceStyle == .dark)
                // A known source-identical prepared fixture isolates presentation lookup;
                // it is deliberately not claimed as a translated render-quality test.
                await cache.store(image, key: key, pageIdentity: ReaderTranslationCacheIdentity.translation(page: sourcePage.translationCacheKey, settings: settings), diskGeneration: await disk.currentGeneration())
                try #require(cache.cachedImage(for: key) != nil)
            }
            for batch in 0..<5 {
                let probe = CostFrames()
                let queuedAt = CACurrentMediaTime()
                var callbackDelay = 0.0
                let callback = Task { @MainActor in callbackDelay = (CACurrentMediaTime() - queuedAt) * 1000 }
                let start = CACurrentMediaTime()
                for _ in 0..<30 { page.displayPreparedSnapshot(regions, settings: settings, memoryOnly: true) }
                let ms = (CACurrentMediaTime() - start) * 1000
                await callback.value
                try await probe.wait()
                #expect(imageView.image === image)
                #expect(page.isUsingCachedRendering == (scenario == "prepared_memory_hit"))
                rows.append(["scenario": scenario, "batch": batch, "phase": batch == 0 ? "warmup" : "measured",
                    "calls": 30, "synchronousBatchMS": ms, "mainActorCallbackDelayMS": callbackDelay,
                    "postBatchDisplayFrameGapsMS": probe.gaps, "sourceImageUnchanged": imageView.image === image,
                    "cachedOverlay": page.isUsingCachedRendering])
                try save()
            }
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(screenshot.pngData()).write(to: directory.appendingPathComponent(scenario + ".png"), options: .atomic)
        }
        try #require(image.pngData()).write(to: directory.appendingPathComponent("source.png"), options: .atomic)
    }
}

@MainActor private final class CostFrames: NSObject {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var previous = 0.0
    private(set) var gaps: [Double] = []
    func wait() async throws {
        try await withCheckedThrowingContinuation { pending in
            continuation = pending; previous = CACurrentMediaTime()
            link = CADisplayLink(target: self, selector: #selector(tick)); link?.add(to: .main, forMode: .common)
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finish(error: CostError.timeout)
            }
        }
    }
    @objc private func tick() {
        let now = CACurrentMediaTime(); gaps.append((now - previous) * 1000); previous = now
        if gaps.count == 2 { finish(error: nil) }
    }
    private func finish(error: Error?) {
        link?.invalidate(); link = nil; timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
private enum CostError: Error { case timeout }
