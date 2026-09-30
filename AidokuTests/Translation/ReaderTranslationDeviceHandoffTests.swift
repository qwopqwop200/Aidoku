import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Opt-in device handoff check. Never prints credentials or server configuration.
@MainActor
struct ReaderTranslationDeviceHandoffTests {
    @Test
    func realPageLateAssetsPreserveEveryPixel() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("PipelineSpeed/candidate/page-0.regions.json").path), "Required local replay fixture is missing")
        let root = URL.documentsDirectory.appendingPathComponent("PipelineSpeed")
        let output = root.appendingPathComponent("late-assets")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let settings = ReaderTranslationSettings()
        var measurements: [[String: Any]] = []
        for index in 0..<3 {
            let image = try #require(UIImage(contentsOfFile: URL.documentsDirectory.appendingPathComponent(
                "OptimizationFixtures/comic-000\(index + 1).png").path))
            let stored = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: Data(contentsOf:
                root.appendingPathComponent("candidate/page-\(index).regions.json")))
            let regions = stored.map(\.region)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let disk = ReaderTranslationDiskCache(directory: directory)
            let coldCache = ReaderTranslationRenderCache(disk: disk)
            defer { coldCache.clearMemory(); try? FileManager.default.removeItem(at: directory) }
            let start = ProcessInfo.processInfo.systemUptime
            let cold = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: image, imageSize: image.size, regions: regions, settings: settings,
                viewport: window.bounds.size, scale: 2, aspectFit: true, host: window, dark: false,
                preparedLayout: nil, assetCache: coldCache, assetKey: "cold")
            let coldMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            while coldCache.pendingAssetWrites > 0 { try await Task.sleep(for: .milliseconds(5)) }
            let asset = try #require(await coldCache.renderAsset(for: "cold"))
            let lateCache = ReaderTranslationRenderCache(disk: disk)
            defer { lateCache.clearMemory() }
            let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
            var acquired = false
            var released = false
            let blocker = Task {
                try await limiter.withPermit { @MainActor in
                    acquired = true
                    while !released { try await Task.sleep(for: .milliseconds(5)) }
                }
            }
            defer { blocker.cancel() }
            while !acquired { try await Task.sleep(for: .milliseconds(5)) }
            let pending = Task {
                try await ReaderTranslationImageExporter.renderCacheSnapshot(
                    image: image, imageSize: image.size, regions: regions, settings: settings,
                    viewport: window.bounds.size, scale: 2, aspectFit: true, host: UIView(), dark: false,
                    preparedLayout: nil, assetCache: lateCache, assetKey: "late", captureGate: limiter)
            }
            defer { pending.cancel() }
            let deadline = Date().addingTimeInterval(10)
            while await limiter.queuedRequestCount != 1 {
                try #require(Date() < deadline); try await Task.sleep(for: .milliseconds(5))
            }
            await lateCache.storeRenderAsset(asset, key: "late", diskGeneration: await disk.currentGeneration(settings: settings))
            let resumedAt = ProcessInfo.processInfo.systemUptime
            released = true
            let replay = try await pending.value
            let replayMS = (ProcessInfo.processInfo.systemUptime - resumedAt) * 1_000
            try await blocker.value
            #expect(cold.size == replay.size)
            #expect(try Self.rgba(cold) == Self.rgba(replay), "Every rendered pixel must survive late-cache reuse")
            try #require(cold.pngData()).write(to: output.appendingPathComponent("page-\(index)-cold.png"))
            try #require(replay.pngData()).write(to: output.appendingPathComponent("page-\(index)-replay.png"))
            measurements.append(["page": index, "regions": regions.count, "coldMS": coldMS,
                "replayAfterAdmissionMS": replayMS, "identicalPixels": true,
                "availableMiB": ReaderTranslationSession.processAvailableMemory() / 1_048_576])
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("measurements.json"), options: .atomic)
        }
    }

    private static func rgba(_ image: UIImage) throws -> Data {
        let pixels = try #require(image.cgImage)
        var bytes = Data(count: pixels.width * pixels.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: pixels.width, height: pixels.height,
                bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setBlendMode(.copy)
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        }
        return bytes
    }

    @Test
    func realPagesAcrossRepeatedDemandHandoff() async throws {
        try #require(FileManager.default.fileExists(atPath:
            URL.documentsDirectory.appendingPathComponent("PipelineSpeed/run.json").path), "Required local replay fixture is missing")
        let root = URL.documentsDirectory.appendingPathComponent("PipelineSpeed")
        let config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("run.json"))) as? [String: String])
        let phase = try #require(config["phase"])
        #expect(["baseline", "candidate"].contains(phase))
        let output = root.appendingPathComponent(phase)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let settings = ReaderTranslationSettings()
        #expect(settings.targetLanguage == "ko")
        #expect(settings.configuration.model == "gemma-4-26b-a4b-it")
        let owner = UUID()
        await ReaderTranslationService.shared.setReaderActive(true, owner: owner)
        defer { Task { await ReaderTranslationService.shared.setReaderActive(false, owner: owner) } }
        let fixtures = ["comic-0001.png", "comic-0002.png", "comic-0003.png"]
        let pages = fixtures.enumerated().map { index, name in
            Page(sourceId: "", chapterId: "pipeline-speed-" + phase, index: index,
                 imageURL: URL.documentsDirectory.appendingPathComponent("OptimizationFixtures/" + name).absoluteString)
        }
        let loader = ReaderTranslationImageLoader()
        let preloader = ReaderTranslationPreloader(retainImage: { _ in false }, loader: loader)
        preloader.nextPage = { page in page.index + 1 < pages.count ? pages[page.index + 1] : nil }
        defer { preloader.cancel(); ReaderTranslationImageExporter.clearIdleRenderer() }
        let started = ProcessInfo.processInfo.systemUptime
        let progress = DeviceHandoffProgress()
        var firstFinished = false
        let first = Task {
            defer { firstFinished = true }
            return try await preloader.translate(pages[0], settings: settings, onProgress: { _ in await progress.markReady() })
        }
        defer { first.cancel() }
        // Reproduce the pause and anchor-update pair during a real API wait.
        while !(await progress.ready) && !firstFinished { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .seconds(2))
        try #require(!firstFinished, "The handoff must occur during demand, not after it completed")
        preloader.cancel(preservingRecognitionFor: pages[0])
        preloader.cancel(preservingRecognitionFor: pages[0])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var measurements: [[String: Any]] = []
        for page in pages {
            let begin = ProcessInfo.processInfo.systemUptime
            let regions = try await preloader.translate(page, settings: settings)
            let translatedAt = ProcessInfo.processInfo.systemUptime
            #expect(!regions.isEmpty)
            #expect(regions.contains { $0.translation != nil && $0.translation != $0.source })
            try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init)).write(to: output.appendingPathComponent("page-\(page.index).regions.json"))
            let image = try await loader.load(page, cacheInMemory: false)
            let rendered = try await ReaderTranslationImageExporter.render(image: image, regions: regions, settings: settings,
                viewport: window.bounds.size, aspectFit: true, host: window)
            let renderedAt = ProcessInfo.processInfo.systemUptime
            try #require(rendered.pngData()).write(to: output.appendingPathComponent("page-\(page.index).png"))
            measurements.append(["fixture": fixtures[page.index], "regions": regions.count,
                "translationWaitMS": (translatedAt - begin) * 1000,
                "renderAndLoadMS": (renderedAt - translatedAt) * 1000,
                "elapsedMS": (renderedAt - started) * 1000,
                "availableMiB": ReaderTranslationSession.processAvailableMemory() / 1_048_576])
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("measurements.json"), options: .atomic)
        }
        // Old observers must resolve without killing the adopted provider work.
        _ = try? await first.value
    }
}

private actor DeviceHandoffProgress {
    private(set) var ready = false
    func markReady() { ready = true }
}
