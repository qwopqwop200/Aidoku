import CryptoKit
import Foundation
import Nuke
import Testing
import UIKit
@testable import Aidoku

/// Diagnostic fixture only. Requires the matching opt-in UpscaleProcessor profile patch.
/// Root runs this serially in an isolated simulator with Swin; optional explicit setup uses the production bundled installer.
@Suite(.serialized) @MainActor
struct ReaderUpscaleURLDuplicationTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("UpscaleURLDuplication/enabled").path)))
    func displayedURLImageSurvivesEvictionBeforeTranslationLoad() async throws {
#if targetEnvironment(simulator)
        let root = URL.documentsDirectory.appendingPathComponent("UpscaleURLDuplication")
        let marker = try String(contentsOf: root.appendingPathComponent("enabled"), encoding: .utf8)
        try #require(marker.trimmingCharacters(in: .whitespacesAndNewlines) == "dedicated-audit-simulator")
        // Must exist BEFORE process launch: diagnostics caches this switch on first use.
        try #require(FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("DisplayPerformance/run.json").path))
        let modelName = "SwinUNetV3Art2x.mlpackage"
        var installed = await ModelManager.shared.getInstalledModels()
        if !installed.contains(where: { $0.file == modelName }),
           FileManager.default.fileExists(atPath: root.appendingPathComponent("allow-bundled-swin-install").path) {
            let bundled = await ModelManager.shared.bundledModels()
            let model = try #require(bundled.first { $0.file == modelName })
            let setupStart = CACurrentMediaTime()
            try await ModelManager.shared.downloadModel(model)
            try JSONSerialization.data(withJSONObject: ["model": modelName, "installationMS": (CACurrentMediaTime() - setupStart) * 1000,
                "scope": "Production bundled installer; excluded from inference measurements"], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("installation.json"), options: .atomic)
            installed = await ModelManager.shared.getInstalledModels()
        }
        try #require(installed.contains { $0.file == modelName }, "Swin must be installed before measurement")
        let defaults = UserDefaults.standard
        let keys = ["Reader.translation.automatic", "Reader.liveText", "Dictionary.enable", "Reader.cropBorders",
                    "Reader.downsampleImages", "Reader.upscaleImages", "Reader.upscaleMaxHeight", "Data.enabledModelFile"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        for key in keys.prefix(5) { defaults.set(false, forKey: key) }
        defaults.set(true, forKey: "Reader.upscaleImages")
        defaults.set(1_000, forKey: "Reader.upscaleMaxHeight")
        ModelManager.shared.setEnabledModel(fileName: modelName)
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
        let source = makeSource()
        let sourcePNG = try #require(source.pngData())
        try sourcePNG.write(to: directory.appendingPathComponent("source.png"))
        var rows: [[String: Any]] = []
        for iteration in 0..<3 {
            let url = directory.appendingPathComponent("input-\(iteration).png")
            try sourcePNG.write(to: url, options: .atomic)
            let page = Page(sourceId: "audit-url-upscale", chapterId: UUID().uuidString, index: 0, imageURL: url.absoluteString)
            let store = ReaderTemporaryPageStore()
            let view = ReaderPageView(parent: host, temporaryPageStore: store)
            view.frame = host.view.bounds
            host.view.addSubview(view)
            let profileID = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
            ReaderTranslationDiagnostics.renderingProfile("upscale_probe_start", count: iteration, revision: profileID)
            let start = CACurrentMediaTime()
            try #require(await view.setPage(page, sourceId: page.sourceId))
            host.view.layoutIfNeeded()
            try #require(view.imageView.window === window)
            try await UpscaleProbeFrames.wait()
            let firstDisplayMS = (CACurrentMediaTime() - start) * 1_000
            let displayed = try #require(view.imageView.image)
            try #require(displayed.cgImage?.width == 34 && displayed.cgImage?.height == 58,
                         "The real 2x model must actually run; returning original is not a pass")
            let request = await ReaderPageView.imageRequest(url: url, context: page.context, sourceKey: page.sourceId)
            let hadCachedImage = ImagePipeline.shared.cache.containsCachedImage(for: request)
            // Controlled eviction is the independent variable; decoded visible image is retained.
            ImagePipeline.shared.configuration.imageCache?.removeAll()
            #expect(!ImagePipeline.shared.cache.containsCachedImage(for: request))
            #expect(view.imageView.image === displayed)
            ReaderTranslationDiagnostics.renderingProfile("upscale_probe_evicted", count: iteration, revision: profileID)
            let loader = ReaderTranslationImageLoader()
            let loaderStart = CACurrentMediaTime()
            let loaded = try await TranslationImageWorkBudget.shared.withPermit {
                try await loader.load(page)
            }
            let loaderMS = (CACurrentMediaTime() - loaderStart) * 1_000
            ReaderTranslationDiagnostics.renderingProfile("upscale_probe_end", count: iteration, revision: profileID)
            let displayedPixels = try pixels(displayed)
            let loadedPixels = try pixels(loaded)
            #expect(displayedPixels == loadedPixels)
            #expect(displayed.scale == loaded.scale)
            #expect(displayed.imageOrientation == loaded.imageOrientation)
            #expect(displayed.cgImage?.width == loaded.cgImage?.width)
            #expect(displayed.cgImage?.height == loaded.cgImage?.height)
            try #require(displayed.pngData()).write(to: directory.appendingPathComponent("displayed-\(iteration).png"))
            try #require(loaded.pngData()).write(to: directory.appendingPathComponent("loader-\(iteration).png"))
            let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(screen.pngData()).write(to: directory.appendingPathComponent("screen-\(iteration).png"))
            let events = try await profileEvents(id: profileID)
            let begins = events.filter { $0.contains("reader_event=upscale_model_begin ") }
            let ends = events.filter { $0.contains("reader_event=upscale_model_end ") }
            let weakHits = events.filter { $0.contains("reader_event=upscale_model_weak_hit ") }
            try #require(begins.count == ends.count && begins.count + weakHits.count == 2,
                         "Both display and loader must perform inference or exact completed-result reuse")
            #expect((0...2).contains(begins.count), "Repeated identical fixtures may reuse an earlier still-owned output")
            rows.append(["iteration": iteration, "profileID": profileID, "sourceSHA256": hash(sourcePNG),
                "firstDisplayMS": firstDisplayMS, "translationLoaderMS": loaderMS,
                "hadCachedImageBeforeEviction": hadCachedImage, "modelCalls": begins.count, "weakHits": weakHits.count,
                "displayedPixelSHA256": hash(displayedPixels), "loaderPixelSHA256": hash(loadedPixels),
                "exactPixels": displayedPixels == loadedPixels, "width": displayed.cgImage?.width ?? 0,
                "height": displayed.cgImage?.height ?? 0, "scale": displayed.scale,
                "orientation": displayed.imageOrientation.rawValue, "profileEvents": events])
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
                "model": modelName, "rows": rows, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "scope": "Real URL ReaderPageView + visible retained UIImage + controlled Nuke memory-cache eviction + real ReaderTranslationImageLoader + installed Swin, serial n3. No OCR/provider execution. First-display time includes model cold preparation on first iteration; no claim of natural eviction frequency or FDAT speed.",
                "memory": "Event footprints are point samples, not transient peak. Root may use same external sampler on both snapshots."], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
            view.removeFromSuperview()
            await store.removeAll()
        }
#else
        Issue.record("Dedicated simulator required")
#endif
    }

    private func profileEvents(id: UInt64) async throws -> [String] {
        let file = URL.documentsDirectory.appendingPathComponent("reader-memory-events.log")
        let pid = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<200 {
            let lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            let own = lines.filter { $0.contains("pid=\(pid) ") }
            if let first = own.firstIndex(where: { $0.contains("reader_event=upscale_probe_start ") && $0.contains("code=\(id) ") }),
               let last = own.lastIndex(where: { $0.contains("reader_event=upscale_probe_end ") && $0.contains("code=\(id) ") }), last >= first {
                return Array(own[first...last])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func makeSource() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 17, height: 29), format: format).image { context in
            for y in 0..<29 { for x in 0..<17 {
                UIColor(red: CGFloat((x * 11 + y * 3) % 256) / 255,
                        green: CGFloat((x * 5 + y * 7) % 256) / 255,
                        blue: CGFloat((x * 3 + y * 13) % 256) / 255, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            } }
        }
    }
    private func pixels(_ image: UIImage) throws -> Data {
        let cg = try #require(image.cgImage)
        var data = Data(count: cg.width * cg.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return data
    }
}

@MainActor private final class UpscaleProbeFrames: NSObject {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Error>?
    private var count = 0
    private var timeout: Task<Void, Never>?
    static func wait() async throws {
        let observer = UpscaleProbeFrames()
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
