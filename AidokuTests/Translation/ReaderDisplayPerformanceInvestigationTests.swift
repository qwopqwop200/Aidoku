import Darwin
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Runtime-only real image + frozen translated region investigation; no OCR/API calls.
/// Execute baseline/candidate with identical run.json and source files.
@Suite(.serialized)
@MainActor
struct ReaderDisplayPerformanceInvestigationTests {
    private nonisolated static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("DisplayPerformance")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.json").path)))
    func realPageColdWarmAndVisibleCapture() async throws {
        let folder = Self.directory
        let config = try JSONDecoder().decode(Configuration.self,
            from: Data(contentsOf: folder.appendingPathComponent("run.json")))
        let count = config.repetitions ?? 5
        try #require((1...10).contains(count))
        let bytes = try Data(contentsOf: folder.appendingPathComponent(config.sourceImage))
        let records = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
            from: Data(contentsOf: folder.appendingPathComponent(config.regions)))
        let regions = records.map(\.region)
        try #require(!regions.isEmpty)
        try #require(regions.allSatisfy { $0.translation?.isEmpty == false })
        let suite = "AidokuTests.DisplayInvestigation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.targetLanguage = config.targetLanguage ?? "ko"
        if let value = config.preserveSourceTextColor { settings.overlay.preserveSourceTextColor = value }
        if let value = config.preserveSourceBackgroundColor { settings.overlay.preserveSourceBackgroundColor = value }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let output = folder.appendingPathComponent(config.label)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        let source = try #require(UIImage(data: bytes))
        let viewportWidth = config.viewportWidth ?? 430
        let viewport = CGSize(width: viewportWidth,
            height: config.viewportHeight ?? (viewportWidth * source.size.height / source.size.width))
        let scale = config.scale ?? 1
        let aspectFit = config.aspectFit ?? false
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayAudit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        func save(_ image: UIImage, name: String) throws -> Data {
            let data = try #require(image.pngData())
            try data.write(to: output.appendingPathComponent(name))
            if let reference = config.referenceDirectory {
                let expected = try Data(contentsOf: folder.appendingPathComponent(reference).appendingPathComponent(name))
                #expect(data == expected, "Exact PNG equality against same-input baseline; no tolerance")
            }
            return data
        }
        func writeReport() throws {
            let report: [String: Any] = [
                "samples": results, "regionCount": regions.count,
                "viewportWidth": viewport.width, "viewportHeight": viewport.height, "scale": scale,
                "aspectFit": aspectFit, "repetitions": count,
                "sourcePixelWidth": source.cgImage?.width ?? 0, "sourcePixelHeight": source.cgImage?.height ?? 0,
                "memorySampling": "10ms main-actor samples; sampled peak can miss blocked-main-thread/transient peaks",
                "scope": "frozen real translated regions; no actual OCR/API; host window display and isolated disk caches",
                "coldDefinition": "fresh disk/cache/source identity/idle exporter; shared text-measurement and WebKit process may remain warm",
                "instrumentationLimit": "cache byte/counter metrics only; no internal planner invocation counter exposed",
                "referenceDirectory": config.referenceDirectory as Any? ?? NSNull()
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("measurements.json"))
        }

        for iteration in 0..<count {
            ReaderTranslationImageExporter.clearIdleRenderer()
            let image = try #require(UIImage(data: bytes))
            let diskRoot = temporaryRoot.appendingPathComponent("loaded-\(iteration)")
            let disk = ReaderTranslationDiskCache(directory: diskRoot)
            let cache = ReaderTranslationRenderCache(disk: disk)
            let page = "display-investigation-\(iteration)"
            let key = ReaderTranslationCacheIdentity.render(page: page, settings: settings,
                imageSize: image.size, viewport: viewport, scale: scale, aspectFit: aspectFit,
                crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: false)
            let coldMemory = MemoryProbe()
            let coldStart = ProcessInfo.processInfo.systemUptime
            let cold = try await ReaderTranslationImageExporter.renderLoadedImage(
                image: image, regions: regions, settings: settings, viewport: viewport, scale: scale,
                aspectFit: aspectFit, dark: false, host: window, cache: cache, key: key, pageIdentity: page)
            let coldSeconds = ProcessInfo.processInfo.systemUptime - coldStart
            coldMemory.stop()
            let coldPNG = try save(cold, name: "loaded-cold-\(iteration).png")
            results.append(sample("loaded-cold", iteration, coldSeconds, coldMemory, cache))
            try writeReport()

            let deadline = Date().addingTimeInterval(15)
            while try await !disk.contains(ReaderTranslationRenderCache.renderAssetStorageKey(key), kind: .layout) {
                try #require(Date() < deadline, "Durable render asset was not written")
                try await Task.sleep(for: .milliseconds(10))
            }
            cache.clearMemory()
            ReaderTranslationImageExporter.clearIdleRenderer()
            let reopened = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: diskRoot))
            let freshImage = try #require(UIImage(data: bytes))
            let warmMemory = MemoryProbe()
            let warmStart = ProcessInfo.processInfo.systemUptime
            let warm = try await ReaderTranslationImageExporter.renderLoadedImage(
                image: freshImage, regions: regions, settings: settings, viewport: viewport, scale: scale,
                aspectFit: aspectFit, dark: false, host: nil, cache: reopened, key: key, pageIdentity: page)
            let warmSeconds = ProcessInfo.processInfo.systemUptime - warmStart
            warmMemory.stop()
            let warmPNG = try save(warm, name: "loaded-disk-replay-\(iteration).png")
            #expect(warmPNG == coldPNG, "Disk replay must exactly preserve output")
            results.append(sample("loaded-disk-replay", iteration, warmSeconds, warmMemory, reopened))
            let hitMemory = MemoryProbe()
            let hitStart = ProcessInfo.processInfo.systemUptime
            let hit = try await ReaderTranslationImageExporter.renderLoadedImage(
                image: freshImage, regions: regions, settings: settings, viewport: viewport, scale: scale,
                aspectFit: aspectFit, dark: false, host: nil, cache: reopened, key: key, pageIdentity: page)
            let hitSeconds = ProcessInfo.processInfo.systemUptime - hitStart
            hitMemory.stop()
            #expect(hit.pngData() == warmPNG)
            results.append(sample("loaded-memory-hit", iteration, hitSeconds, hitMemory, reopened))
            cache.clearMemory(); reopened.clearMemory()
            try writeReport()

            ReaderTranslationImageExporter.clearIdleRenderer()
            let visibleDisk = ReaderTranslationDiskCache(directory: temporaryRoot.appendingPathComponent("visible-\(iteration)"))
            let visibleCache = ReaderTranslationRenderCache(disk: visibleDisk)
            let generation = await visibleDisk.currentGeneration(settings: settings)
            let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
            overlay.overrideUserInterfaceStyle = .light
            window.addSubview(overlay)
            defer { overlay.cancelWork(); overlay.removeFromSuperview(); visibleCache.clearMemory() }
            let visibleMemory = MemoryProbe()
            let visibleStart = ProcessInfo.processInfo.systemUptime
            var committedAt: Double?
            var snapshot: UIImage?
            var snapshotAt: Double?
            overlay.onRenderCommitted = { committedAt = ProcessInfo.processInfo.systemUptime }
            overlay.onSnapshotStored = {
                snapshot = $0
                snapshotAt = ProcessInfo.processInfo.systemUptime
            }
            overlay.update(regions: regions, imageSize: image.size, aspectFit: aspectFit,
                settings: settings, image: image,
                snapshotTarget: ReaderTranslationSnapshotTarget(cache: visibleCache, key: key,
                    pageIdentity: page, diskGeneration: generation, viewport: viewport, dark: false))
            overlay.layoutIfNeeded()
            let visibleDeadline = Date().addingTimeInterval(40)
            while committedAt == nil {
                try #require(Date() < visibleDeadline, "Visible render did not commit")
                try await Task.sleep(for: .milliseconds(5))
            }
            _ = try await overlay.webView.callAsyncJavaScript(
                "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
            let paintAt = ProcessInfo.processInfo.systemUptime
            while snapshot == nil {
                try #require(Date() < visibleDeadline, "Visible completed snapshot was not stored")
                try await Task.sleep(for: .milliseconds(5))
            }
            visibleMemory.stop()
            _ = try save(try #require(snapshot), name: "visible-snapshot-\(iteration).png")
            var visible = sample("visible-update-to-capture", iteration,
                try #require(snapshotAt) - visibleStart, visibleMemory, visibleCache)
            visible["actualDisplayScale"] = overlay.traitCollection.displayScale
            visible["commitSeconds"] = try #require(committedAt) - visibleStart
            visible["twoRAFSeconds"] = paintAt - visibleStart
            visible["commitToSnapshotSeconds"] = try #require(snapshotAt) - (try #require(committedAt))
            results.append(visible)
            overlay.cancelWork(); overlay.removeFromSuperview()
            visibleCache.clearMemory()
            ReaderTranslationImageExporter.clearIdleRenderer()
            try writeReport()
        }
    }

    private func sample(_ stage: String, _ iteration: Int, _ seconds: Double,
                        _ memory: MemoryProbe, _ cache: ReaderTranslationRenderCache) -> [String: Any] {
        ["stage": stage, "iteration": iteration, "seconds": seconds,
         "startFootprintBytes": memory.start, "sampledPeakFootprintBytes": memory.peak,
         "endFootprintBytes": memory.end, "availableMemoryBytes": os_proc_available_memory(),
         "bitmapBytes": cache.bitmapBytes, "layoutBytes": cache.layoutBytes,
         "renderAssetBytes": cache.renderAssetBytes, "activeAssetEncodings": cache.activeAssetEncodings,
         "queuedAssetEncodings": cache.queuedAssetEncodings]
    }

    @MainActor private final class MemoryProbe {
        let start: UInt64
        var peak: UInt64
        var end: UInt64
        private var sampler: Task<Void, Never>?
        init() {
            start = Self.footprint(); peak = start; end = start
            sampler = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard let self, !Task.isCancelled else { return }
                    peak = max(peak, Self.footprint())
                }
            }
        }
        func stop() {
            sampler?.cancel(); sampler = nil
            end = Self.footprint(); peak = max(peak, end)
        }
        deinit { sampler?.cancel() }
        static func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }
    }

    private struct Configuration: Decodable {
        let sourceImage: String
        let regions: String
        let label: String
        let repetitions: Int?
        let targetLanguage: String?
        let viewportWidth: CGFloat?
        let viewportHeight: CGFloat?
        let scale: CGFloat?
        let aspectFit: Bool?
        let preserveSourceTextColor: Bool?
        let preserveSourceBackgroundColor: Bool?
        let referenceDirectory: String?
    }
}
