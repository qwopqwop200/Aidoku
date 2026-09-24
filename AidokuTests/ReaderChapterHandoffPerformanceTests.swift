import AidokuRunner
import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Same source/test in both variants. Root-controlled 127.0.0.1:18762 Komga replay.
/// Measures the actual view model and visible page; does not synthesize a page list.
@Suite(.serialized) @MainActor
struct ReaderChapterHandoffPerformanceTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("ReaderChapterHandoff/enabled").path)))
    func preloadCancellationToForegroundDisplayedImage() async throws {
#if targetEnvironment(simulator)
        let root = URL.documentsDirectory.appendingPathComponent("ReaderChapterHandoff")
        let marker = try String(contentsOf: root.appendingPathComponent("enabled"), encoding: .utf8)
        try #require(marker.trimmingCharacters(in: .whitespacesAndNewlines) == "dedicated-audit-simulator")
        let defaults = UserDefaults.standard
        let keys = ["Reader.translation.automatic", "Reader.liveText", "Dictionary.enable", "Reader.cropBorders",
                    "Reader.downsampleImages", "Reader.upscaleImages"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        keys.forEach { defaults.set(false, forKey: $0) }
        defer { for key in keys { if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let oldWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; oldWindow?.makeKey() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var rows: [[String: Any]] = []
        for iteration in 0..<5 {
            let token = UUID().uuidString
            let base = try #require(URL(string: "http://127.0.0.1:18762/flow/\(token)/"))
            func stats() async throws -> [String: Any] {
                let (data, response) = try await session.data(from: base.appendingPathComponent("audit-stats"))
                try #require((response as? HTTPURLResponse)?.statusCode == 200)
                return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
            let sourceKey = try #require(await SourceManager.shared.createCustomSource(.komga(.init(
                name: "Chapter handoff \(token)", server: base, username: "fixture", password: "fixture"))))
            let source = try #require(await SourceManager.shared.source(for: sourceKey))
            let search = try await source.getSearchMangaList(query: "Full Audit", page: 1, filters: [])
            let manga = try await source.getMangaUpdate(manga: #require(search.entries.first), needsDetails: true, needsChapters: true)
            let chapter = try #require(manga.chapters?.first)
            let store = ReaderTemporaryPageStore()
            let model = ReaderPagedViewModel(source: source, manga: manga, temporaryPageStore: store)
            let preload = Task { await model.preload(chapter: chapter) }
            var before: [String: Any] = [:]
            let startDeadline = Date().addingTimeInterval(10)
            repeat {
                before = try await stats()
                if (before["count"] as? Int ?? 0) > 0 && (before["elapsedMS"] as? Double ?? 0) >= 800 { break }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < startDeadline
            try #require(before["count"] as? Int == 1)
            try #require((before["active"] as? Int ?? 0) == 1, "Preload must still be in flight at adoption")
            let started = CACurrentMediaTime()
            let handoff = model.takePendingPreload(for: chapter)
            preload.cancel() // Same synchronous transfer-before-cancel order as setChapter.
            await model.loadPages(chapter: chapter, handoff: handoff)
            let loadedMS = (CACurrentMediaTime() - started) * 1000
            try #require(model.pages.count == 3)
            let order = model.pages.map { URL(string: $0.imageURL ?? "")?.lastPathComponent ?? "missing" }
            #expect(order == ["1", "2", "3"])
            let view = ReaderPageView(parent: host, temporaryPageStore: store)
            view.frame = host.view.bounds
            host.view.addSubview(view)
            try #require(await view.setPage(#require(model.pages.first), sourceId: sourceKey))
            host.view.layoutIfNeeded()
            try #require(view.imageView.window === window)
            try await HandoffFrames.wait()
            let displayedMS = (CACurrentMediaTime() - started) * 1000
            let image = try #require(view.imageView.image)
            let png = try #require(image.pngData())
            try png.write(to: directory.appendingPathComponent("displayed-\(iteration).png"), options: .atomic)
            let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(screen.pngData()).write(to: directory.appendingPathComponent("screen-\(iteration).png"), options: .atomic)
            let (expectedData, _) = try await session.data(from: base.appendingPathComponent("api/v1/books/audit-book/pages/1"))
            let expected = try #require(UIImage(data: expectedData))
            #expect(try pixels(image) == pixels(expected))
            try expectedData.write(to: directory.appendingPathComponent("expected-\(iteration).png"), options: .atomic)
            _ = await preload.value
            var after = try await stats()
            let settleDeadline = Date().addingTimeInterval(5)
            while (after["active"] as? Int ?? 0) > 0, Date() < settleDeadline {
                try await Task.sleep(for: .milliseconds(20)); after = try await stats()
            }
            #expect(after["active"] as? Int == 0)
            #expect(after["count"] as? Int == 1, "Foreground must adopt the exact in-flight page-list request")
            #expect(after["maximumActive"] as? Int == 1, "Handoff must not add another in-flight request")
            rows.append(["iteration": iteration, "before": before, "after": after, "pageOrder": order,
                "foregroundToPagesMS": loadedMS, "foregroundToVisibleImageMS": displayedMS,
                "pngSHA256": digest(png), "pixelSHA256": digest(try pixels(image)), "exactExpectedPixels": try pixels(image) == pixels(expected)])
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier, "rows": rows,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "scope": "Real Komga runner/view model/network/page view; controlled 1000ms page-list response, adoption at >=800ms, n5, first page plus two display callbacks. No physical gesture, no OCR/upscale, no external service.",
                "timingLimit": "Loopback delay is synthetic. Counts/adoption and exact pixels establish mechanism; improvement is not a general reader speed claim."], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
            view.removeFromSuperview()
            await store.removeAll()
        }
#else
        Issue.record("Dedicated simulator required")
#endif
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func pixels(_ image: UIImage) throws -> Data {
        let cg = try #require(image.cgImage)
        var data = Data(count: cg.width * cg.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let ctx = try #require(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return data
    }
}

@MainActor private final class HandoffFrames: NSObject {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Error>?
    private var count = 0
    private var timeout: Task<Void, Never>?
    static func wait() async throws {
        let observer = HandoffFrames()
        try await withCheckedThrowingContinuation { continuation in
            observer.continuation = continuation
            observer.link = CADisplayLink(target: observer, selector: #selector(tick))
            observer.link?.add(to: .main, forMode: .common)
            observer.timeout = Task { @MainActor [weak observer] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                observer?.finish(error: CancellationError())
            }
        }
    }
    @objc private func tick() { count += 1; if count >= 2 { finish(error: nil) } }
    private func finish(error: Error?) {
        link?.invalidate(); link = nil; timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
