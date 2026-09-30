import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Opt-in, same-binary ABBA trial. Uses existing real pages and the configured
/// provider; no credentials or response bodies are printed to the test log.
@MainActor
struct ReaderTranslationDepthDeviceTests {
    @Test
    func realPageThroughputAndMemory() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("PipelineSpeed/depth-run.json").path), "Required local replay fixture is missing")
        try await run(fixedResponses: false)
    }

    @Test
    func fixedResponsesPreserveEveryPixel() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("PipelineSpeed/depth/measurements.json").path), "Required local replay fixture is missing")
        try await run(fixedResponses: true)
    }

    @Test
    func chromaticOptimizationPreservesRecordedPixels() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("PipelineSpeed/chromatic-reference/phase-0-page-0.png").path), "Required local replay fixture is missing")
        try await run(fixedResponses: true, comparesRecordedPixels: true)
    }

    private func run(fixedResponses: Bool, comparesRecordedPixels: Bool = false) async throws {
        let liveRoot = URL.documentsDirectory.appendingPathComponent("PipelineSpeed/depth")
        let root = comparesRecordedPixels ? URL.documentsDirectory.appendingPathComponent("PipelineSpeed/chromatic-candidate")
            : fixedResponses ? liveRoot.appendingPathComponent("replay") : liveRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let indices = [1, 4, 7, 10, 13, 16, 19, 22, 25, 28, 31, 34]
        let referenceRoot = comparesRecordedPixels
            ? URL.documentsDirectory.appendingPathComponent("PipelineSpeed/chromatic-reference") : liveRoot
        let fixedRegions: [[ReaderTranslationRegion]] = try fixedResponses ? indices.indices.map { index in
            try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
                from: Data(contentsOf: referenceRoot.appendingPathComponent("phase-0-page-\(index).json"))).map(\.region)
        } : []
        let translator: ReaderTranslationPage.ProgressiveTranslator?
        if fixedResponses {
            translator = { regions, _, progress in
                let matching = fixedRegions.first { stored in
                    guard stored.count == regions.count else { return false }
                    for (old, actual) in zip(stored, regions) {
                        if old.id != actual.id || old.source != actual.source || old.rect != actual.rect { return false }
                    }
                    return true
                }
                let expected = try #require(matching, "Replay must use the same recognized source page")
                var translated = regions
                for index in translated.indices {
                    var actual = regions[index], old = expected[index]
                    #expect(abs(actual.confidence - old.confidence) <= 0.001)
                    actual.translation = nil; old.translation = nil
                    actual.translationReuseIdentity = nil; old.translationReuseIdentity = nil
                    actual.confidence = 0; old.confidence = 0
                    #expect(actual == old, "Recorded OCR, merge and balloon metadata must remain unchanged")
                    translated[index].translation = expected[index].translation
                    translated[index].translationReuseIdentity = expected[index].translationReuseIdentity
                }
                // Exercise overlap without making a new stochastic provider call.
                try await Task.sleep(for: .milliseconds(150))
                try await progress?(translated)
                return translated
            }
        } else { translator = nil }
        let settings = ReaderTranslationSettings()
        try #require(settings.shouldAttachPageImage && settings.maximumConcurrentRequests >= 3)
        let owner = UUID()
        await ReaderTranslationService.shared.setReaderActive(true, owner: owner)
        defer { Task { await ReaderTranslationService.shared.setReaderActive(false, owner: owner) } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let imageView = UIImageView(frame: window.bounds)
        imageView.contentMode = .scaleAspectFit
        window.rootViewController?.view.addSubview(imageView)
        let readerPage = ReaderTranslationPage(imageView: imageView)
        let geometry = ReaderTranslationLayoutGeometry(page: readerPage, imageView: imageView)
        var reference: [[ReaderTranslationRegion]] = []
        var measurements: [[String: Any]] = []
        // Keep the normal model residency across phases. ABBA exposes warm-up
        // and accumulation instead of purging them away between candidates.
        let depths: [Int] = fixedResponses ? [1, 2] : [1, 2, 2, 1]
        for (phase, depth) in depths.enumerated() {
            try await ReaderTranslationService.shared.clearCache()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let disk = ReaderTranslationDiskCache(directory: directory)
            let cache = ReaderTranslationRenderCache(disk: disk)
            let preparer = ReaderTranslationLayoutPreparer(renderCache: cache)
            // SQLite may still hold queued touch writes. Leave this bounded
            // temporary directory to normal cleanup rather than unlink live DBs.
            defer { cache.clearMemory() }
            let pages = indices.enumerated().map { index, fixture in
                Page(sourceId: "", chapterId: "depth-\(phase)", index: index,
                     imageURL: URL.documentsDirectory.appendingPathComponent(
                        String(format: "ReaderSoak/comic-%04d.png", fixture)).absoluteString)
            }
            let preloader = ReaderTranslationPreloader(translator: translator, retainImage: { _ in false })
            preloader.lookaheadLimit = { _, _ in depth }
            preloader.nextPageExcluding = { current, excluded in
                pages.first { $0.index > current.index && !excluded.contains($0.translationCacheKey) }
            }
            defer { preloader.cancel() }
            var peak = Self.footprintMiB()
            var minimumAvailable = ReaderTranslationSession.processAvailableMemory() / 1_048_576
            var maximumPrepared = 0
            let sampler = Task { @MainActor in
                while !Task.isCancelled {
                    peak = max(peak, Self.footprintMiB())
                    minimumAvailable = min(minimumAvailable, ReaderTranslationSession.processAvailableMemory() / 1_048_576)
                    maximumPrepared = max(maximumPrepared, preloader.preparedPageCount)
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            defer { sampler.cancel() }
            let start = ProcessInfo.processInfo.systemUptime
            var pageRows: [[String: Any]] = []
            for page in pages {
                let pageStart = ProcessInfo.processInfo.systemUptime
                let regions = try await preloader.translate(page, settings: settings)
                let translated = ProcessInfo.processInfo.systemUptime
                try #require(ReaderTranslationService.plans(regions: regions, settings: settings).count <= 1,
                    "Keep provider batch width constant while comparing page lookahead depth")
                if phase == 0 {
                    reference.append(regions)
                } else {
                    let expected = reference[page.index]
                    try #require(regions.count == expected.count, "OCR count changed in fixture \(indices[page.index])")
                    for (actual, old) in zip(regions, expected) {
                        var a = actual, b = old
                        #expect(abs(a.confidence - b.confidence) <= 0.001)
                        a.translation = nil; b.translation = nil
                        a.translationReuseIdentity = nil; b.translationReuseIdentity = nil
                        a.confidence = 0; b.confidence = 0
                        #expect(a == b, "Only provider wording may vary; OCR/merge geometry must stay identical")
                    }
                }
                let nearby = pages[max(0, page.index - 1)...min(pages.count - 1, page.index + 1)]
                cache.setNearbyPages(pageKeys: nearby.map(\.translationCacheKey), settings: settings)
                try await preparer.prepare(page: page, regions: regions, settings: settings, geometry: geometry, window: window)
                let finished = ProcessInfo.processInfo.systemUptime
                let prefix = "phase-\(phase)-page-\(page.index)"
                try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
                    .write(to: root.appendingPathComponent(prefix + ".json"))
                if !regions.isEmpty {
                    let size = try #require(try await disk.imageSize(page: page.translationCacheKey))
                    let key = ReaderTranslationCacheIdentity.render(page: page.translationCacheKey, settings: settings,
                        imageSize: size, viewport: geometry.viewport(for: size), scale: geometry.scale,
                        aspectFit: geometry.aspectFit, crop: geometry.crop, dark: geometry.dark)
                    let bitmap = try #require(cache.cachedImage(for: key))
                    let png = try #require(bitmap.pngData())
                    try png.write(to: root.appendingPathComponent(prefix + ".png"))
                    if comparesRecordedPixels {
                        let reference = URL.documentsDirectory.appendingPathComponent(
                            "PipelineSpeed/chromatic-reference/phase-0-page-\(page.index).png")
                        #expect(png == (try Data(contentsOf: reference)), "Optimized chromatic search must preserve every recorded PNG byte")
                    }
                    if fixedResponses, phase > 0 {
                        let baseline = try Data(contentsOf: root.appendingPathComponent("phase-0-page-\(page.index).png"))
                        #expect(png == baseline, "Changing lookahead depth must preserve every rendered PNG byte")
                    }
                }
                pageRows.append(["fixture": indices[page.index], "regions": regions.count,
                    "translationWaitMS": (translated - pageStart) * 1_000,
                    "renderMS": (finished - translated) * 1_000,
                    "elapsedMS": (finished - start) * 1_000,
                    "footprintMiB": Self.footprintMiB(), "availableMiB": ReaderTranslationSession.processAvailableMemory() / 1_048_576])
                try JSONSerialization.data(withJSONObject: pageRows, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("phase-\(phase)-pages.json"), options: .atomic)
            }
            sampler.cancel()
            await sampler.value
            preloader.cancel()
            while cache.pendingAssetWrites > 0 { try await Task.sleep(for: .milliseconds(5)) }
            try await disk.clear()
            measurements.append(["phase": phase, "depth": depth, "pages": pages.count,
                "elapsedMS": (ProcessInfo.processInfo.systemUptime - start) * 1_000,
                "sampledPeakMiB": peak, "minimumAvailableMiB": minimumAvailable, "maximumPrepared": maximumPrepared])
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("measurements.json"), options: .atomic)
            print("DEPTH_TRIAL phase=\(phase) depth=\(depth) pages=\(pages.count) peakMiB=\(peak)")
        }
    }

    private static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
