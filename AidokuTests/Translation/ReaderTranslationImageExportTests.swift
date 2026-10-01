import Testing
import UIKit
import Photos
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderTranslationImageExportTests {
    private var folder: URL { FileManager.default.documentDirectory.appendingPathComponent("TranslationExportValidation") }

    private func host() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        return window
    }

    private func settings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings()
        settings.targetLanguage = "ko"
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        return settings
    }

    @Test func failedLayoutReleasesExporterWithoutWaitingForWatchdog() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
        }
        let region = ReaderTranslationRegion(id: "failure", rect: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.3),
            source: "Hello", translation: "번역")
        let layout = Task<Data, Error> { throw CocoaError(.coderInvalidValue) }
        let started = CACurrentMediaTime()
        do {
            _ = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: source, imageSize: source.size, regions: [region], settings: settings(),
                viewport: CGSize(width: 240, height: 320), scale: 1, aspectFit: true, host: window,
                dark: false, preparedLayout: layout)
            Issue.record("A failed layout must not produce an export")
        } catch {
            #expect(error is ReaderTranslationImageExporter.ExportError)
        }
        #expect(CACurrentMediaTime() - started < 5, "Known render failures must release the gate before the 20-second watchdog")
        let output = try await ReaderTranslationImageExporter.render(image: source, regions: [region], settings: settings(),
            viewport: CGSize(width: 240, height: 320), aspectFit: true, host: window)
        #expect(output.size == source.size)
        #expect(try pixelData(output) != pixelData(source))
    }

    @Test func temporaryRendererNeverAppearsInTransparentHostOnCreationOrReuse() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let view = ExportVisibilityHost(frame: window.bounds)
        window.addSubview(view)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
        }
        let originalSubviews = view.subviews.map(ObjectIdentifier.init)
        let originalHostAlpha = view.alpha
        let region = ReaderTranslationRegion(id: "visibility", rect: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.3),
            source: "Hello", translation: "번역 표시 검증")
        for _ in 0..<2 {
            let output = try await ReaderTranslationImageExporter.render(image: source, regions: [region], settings: settings(),
                viewport: CGSize(width: 240, height: 320), aspectFit: true, host: view)
            #expect(output.size == source.size)
            #expect(try pixelData(output) != pixelData(source), "Invisible UIKit hosting must still export translated typography")
            #expect(view.renderer == nil, "Native bitmap rendering must not attach a presentation renderer")
            #expect(view.subviews.map(ObjectIdentifier.init) == originalSubviews,
                    "Export must preserve the transparent host on initial rendering and reuse")
            #expect(view.alpha == originalHostAlpha)
        }
        #expect(view.attachmentAlphas.isEmpty && view.addedSubviewCount == 0,
                "Both initial native export and reuse must leave the presentation hierarchy untouched")
    }

    private final class ExportVisibilityHost: UIView {
        var attachmentAlphas: [CGFloat] = []
        var addedSubviewCount = 0
        weak var renderer: ReaderTranslationOverlayView?

        override func didAddSubview(_ subview: UIView) {
            super.didAddSubview(subview)
            addedSubviewCount += 1
            guard let overlay = subview as? ReaderTranslationOverlayView else { return }
            renderer = overlay
            attachmentAlphas.append(overlay.alpha)
        }
    }

    @Test func stretchedViewportExportsFullValidPixelBudgetWithoutOversizedIntermediate() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let sourceSize = CGSize(width: 4_000, height: 3_000)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: sourceSize, format: format).image { context in
            UIColor.green.setFill(); context.fill(CGRect(origin: .zero, size: sourceSize))
            UIColor.blue.setFill(); context.fill(CGRect(x: 3_800, y: 2_800, width: 150, height: 150))
        }
        let region = ReaderTranslationRegion(id: "anisotropic", rect: CGRect(x: 0.25, y: 0.35, width: 0.5, height: 0.2),
            source: "Hello", translation: "서로 다른 축의 출력 배율")
        // The final image is exactly 12 MP. A uniform 4000/390 scale incorrectly
        // allocates 4000 x 7180 pixels for this deliberately stretched viewport.
        let output = try await ReaderTranslationImageExporter.render(image: source, regions: [region], settings: settings(),
            viewport: CGSize(width: 390, height: 700), aspectFit: false, host: window)
        let cgImage = try #require(output.cgImage)
        #expect(cgImage.width == 4_000 && cgImage.height == 3_000)
        #expect(output.size == sourceSize, "Valid output must retain both axes of source density")
        let pixels = try pixelData(output)
        func color(x: Int, y: Int) -> [UInt8] {
            Array(pixels[(y * cgImage.width + x) * 4..<(y * cgImage.width + x) * 4 + 4])
        }
        #expect(color(x: 100, y: 100) == [0, 255, 0, 255])
        #expect(color(x: 3_875, y: 2_875) == [0, 0, 255, 255], "Stretched render must preserve distant source artwork")
        var changed = 0
        for y in 900..<1_900 { for x in 900..<3_100 {
            let offset = (y * cgImage.width + x) * 4
            if pixels[offset] != 0 || pixels[offset + 1] != 255 || pixels[offset + 2] != 0 { changed += 1 }
        } }
        #expect(changed > 100, "The full-density output must include translated native typography")
    }

    @Test func cacheSnapshotPreservesTransparentLetterboxAndLogicalImageSize() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // The preloader may supply fewer source pixels than its logical page size.
        let source = UIGraphicsImageRenderer(size: CGSize(width: 150, height: 200), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
        }
        let region = ReaderTranslationRegion(id: "letterbox", rect: CGRect(x: 0.25, y: 0.35, width: 0.5, height: 0.2),
            source: "Hello", translation: "중앙 번역")
        let output = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: source, imageSize: CGSize(width: 600, height: 800), regions: [region], settings: settings(),
            viewport: CGSize(width: 390, height: 700), scale: 2, aspectFit: true, host: window,
            dark: false, preparedLayout: nil)
        let cgImage = try #require(output.cgImage)
        #expect(cgImage.width == 780 && cgImage.height == 1400)
        let pixels = try pixelData(output)
        // 390x520 page is centered at y=90; the first/last 180 pixel rows stay transparent.
        for y in [0, 100, 1300, 1399] {
            #expect(pixels[(y * cgImage.width + 390) * 4 + 3] == 0)
        }
        for y in [200, 1200] {
            let offset = (y * cgImage.width + 390) * 4
            #expect(pixels[offset] < 10 && pixels[offset + 1] > 240 && pixels[offset + 2] < 10)
            #expect(pixels[offset + 3] == 255)
        }
    }

    @Test func cacheSnapshotBoundsFourMillionPixelsAndPaintsTallPageBottom() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 600), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 600))
        }
        let region = ReaderTranslationRegion(id: "bottom", rect: CGRect(x: 0.15, y: 0.85, width: 0.7, height: 0.07),
            source: "Bottom", translation: "화면 밖 아래쪽 번역")
        let output = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: source, imageSize: CGSize(width: 1000, height: 6000), regions: [region], settings: settings(),
            viewport: CGSize(width: 1000, height: 6000), scale: 3, aspectFit: false, host: window,
            dark: true, preparedLayout: nil)
        let cgImage = try #require(output.cgImage)
        #expect(cgImage.width * cgImage.height <= 4_000_000)
        #expect(cgImage.width > 800 && cgImage.height > 4800)
        let pixels = try pixelData(output)
        var darkPixels = 0
        for y in (cgImage.height * 4 / 5)..<cgImage.height {
            for x in 0..<cgImage.width {
                let offset = (y * cgImage.width + x) * 4
                if pixels[offset] < 100 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 {
                    darkPixels += 1
                }
            }
        }
        // Source is entirely white: lower-page dark pixels must come from the translated DOM.
        #expect(darkPixels > 30)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(output.pngData()).write(to: folder.appendingPathComponent("tall-cache-bottom.png"))
    }

    /// Same-binary cold export versus native asset replay, including a logical
    /// source size different from decoded pixels (the preloader's normal path).
    @Test(arguments: [false, true])
    func snapshotAssetReplayPreservesPixelsAndRejectsChangedIdentity(webtoon: Bool) async throws {
        let window = try host()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        defer {
            cache.clearMemory()
            window.isHidden = true
            try? FileManager.default.removeItem(at: directory)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 150, height: 200), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 150, height: 200))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 9, y: 17, width: 27, height: 33))
        }
        let logicalSize = CGSize(width: 600, height: 800)
        let viewport = webtoon ? CGSize(width: 390, height: 520) : CGSize(width: 390, height: 700)
        let regions = [ReaderTranslationRegion(id: "asset-replay", rect: CGRect(x: 0.3, y: 0.4, width: 0.5, height: 0.2),
            source: "Hello", translation: "동일한 번역")]
        let settings = settings()
        let generation = await disk.currentGeneration(settings: settings)
        let start = ProcessInfo.processInfo.systemUptime
        let original = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: image, imageSize: logicalSize, regions: regions, settings: settings,
            viewport: viewport, scale: 2, aspectFit: !webtoon, host: window, dark: false,
            preparedLayout: nil, assetCache: cache, assetKey: "snapshot")
        let coldMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        let deadline = Date().addingTimeInterval(20)
        while cache.pendingAssetWrites > 0 {
            try #require(Date() < deadline)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let stored = await cache.renderAsset(for: "snapshot")
        let asset = try #require(stored)
        #expect(asset.sourceSize == logicalSize)
        #expect(await disk.currentGeneration() == generation)
        // No window and a failed layout task prove replay needs neither WebKit
        // nor an additional layout pass. The previous implementation throws.
        let unusedLayout = Task<Data, Error> { throw CancellationError() }
        let replayStart = ProcessInfo.processInfo.systemUptime
        let replay = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: image, imageSize: logicalSize, regions: regions, settings: settings,
            viewport: viewport, scale: 2, aspectFit: !webtoon, host: UIView(), dark: false,
            preparedLayout: unusedLayout, assetCache: cache, assetKey: "snapshot")
        let replayMS = (ProcessInfo.processInfo.systemUptime - replayStart) * 1_000
        #expect(replay.size == original.size)
        #expect(try pixelData(replay) == pixelData(original))
        if !webtoon {
            let pixels = try pixelData(replay)
            #expect(pixels[3] == 0, "The viewport letterbox must remain transparent")
        }
        print("SNAPSHOT_ASSET_REPLAY_MS webtoon=\(webtoon) cold=\(coldMS) replay=\(replayMS)")
        // A caller accidentally reusing the same key must not paint stale content.
        let changed = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: image.size))
        }
        let otherRegions = [ReaderTranslationRegion(id: "asset-replay", rect: regions[0].rect,
            source: "Hello", translation: "변경된 번역")]
        struct InvalidSnapshotIdentity {
            let source: UIImage
            let size: CGSize
            let content: [ReaderTranslationRegion]
            let bounds: CGSize
        }
        let cases: [InvalidSnapshotIdentity] = [
            .init(source: changed, size: logicalSize, content: regions, bounds: viewport),
            .init(source: image, size: logicalSize, content: otherRegions, bounds: viewport),
            .init(source: image, size: CGSize(width: 601, height: 800), content: regions, bounds: viewport),
            .init(source: image, size: logicalSize, content: regions,
                  bounds: CGSize(width: viewport.width + 1, height: viewport.height))
        ]
        for invalid in cases {
            let result = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: invalid.source, imageSize: invalid.size, regions: invalid.content, settings: settings,
                viewport: invalid.bounds, scale: 2, aspectFit: !webtoon, host: UIView(), dark: false,
                preparedLayout: nil, assetCache: cache, assetKey: "snapshot")
            let fresh = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: invalid.source, imageSize: invalid.size, regions: invalid.content, settings: settings,
                viewport: invalid.bounds, scale: 2, aspectFit: !webtoon, host: nil, dark: false, preparedLayout: nil)
            #expect(try pixelData(result) == pixelData(fresh), "Changed identity must render current native content")
        }
    }

    @Test(arguments: [true, false])
    func queuedSnapshotRechecksNativeAssetAfterAdmission(matchingSource: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        defer { cache.clearMemory(); try? FileManager.default.removeItem(at: directory) }
        let size = CGSize(width: 120, height: 160)
        let bounds = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(bounds)
            UIColor.blue.setFill(); context.fill(CGRect(x: 4, y: 5, width: 20, height: 30))
        }
        let typography = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.black.setFill(); context.cgContext.fill(CGRect(x: 40, y: 60, width: 25, height: 8))
        }
        let regions = [ReaderTranslationRegion(id: "queued", rect: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.2),
                                               source: "Hello", translation: "같은 결과")]
        let asset = ReaderTranslationRenderAsset(typography: typography,
            layers: .init(masks: [], surfaces: [], paintBounds: []), displayRect: bounds, sourceSize: size,
            regions: regions, sourceDigest: matchingSource ? ReaderTranslationRenderAsset.digestSource(image) : "different-source")
        let value = settings()
        let generation = await disk.currentGeneration(settings: value)
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
        let deadline = Date().addingTimeInterval(5)
        while !acquired { try #require(Date() < deadline); try await Task.sleep(for: .milliseconds(5)) }
        let pending = Task {
            // Native rendering admits this job even without a presentation window.
            try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: image, imageSize: size, regions: regions, settings: value,
                viewport: size, scale: 1, aspectFit: false, host: UIView(), dark: false,
                preparedLayout: nil, assetCache: cache, assetKey: "queued", captureGate: limiter)
        }
        defer { pending.cancel() }
        while await limiter.queuedRequestCount != 1 {
            try #require(Date() < deadline); try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cache.renderAsset(for: "queued") == nil)
        // Another renderer finishes while this snapshot waits for admission.
        await cache.storeRenderAsset(asset, key: "queued", diskGeneration: generation)
        released = true
        try await blocker.value
        if matchingSource {
            let output = try await pending.value
            let expected = try await ReaderTranslationImageExporter.compositeLoadedImage(image, asset: asset,
                size: size, priority: .foreground)
            #expect(try pixelData(output) == pixelData(expected))
        } else {
            let output = try await pending.value
            let fresh = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                image: image, imageSize: size, regions: regions, settings: value, viewport: size,
                scale: 1, aspectFit: false, host: nil, dark: false, preparedLayout: nil)
            #expect(try pixelData(output) == pixelData(fresh), "A mismatched asset must render the current source")
        }
    }

    @Test func fullPageIncludesTranslationWithoutLetterboxingOrUI() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let view = try #require(window.rootViewController?.view)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.white.setFill()
            context.fill(CGRect(x: 100, y: 180, width: 400, height: 220))
        }
        let region = ReaderTranslationRegion(id: "test", rect: CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.2),
            source: "Hello", translation: "안녕하세요. 번역 이미지 저장 테스트랍니다.")
        let output = try await ReaderTranslationImageExporter.render(image: source, regions: [region], settings: settings(),
            viewport: CGSize(width: 390, height: 700), aspectFit: true, host: view)
        #expect(output.size == source.size)
        #expect(output.scale == 1)
        let pixels = try pixelData(output)
        #expect(pixels[0] < 10 && pixels[1] > 240 && pixels[2] < 10)
        let original = try pixelData(source)
        #expect(pixels != original)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try output.pngData()?.write(to: folder.appendingPathComponent("synthetic-export.png"))
    }

    @Test func exportKeepsBackdropErasureInsideTranslationCard() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let view = try #require(window.rootViewController?.view)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            // Fine source strokes make loss of backdrop blur measurable.
            UIColor.black.setFill()
            for x in stride(from: 130, to: 470, by: 6) {
                context.fill(CGRect(x: x, y: 220, width: 2, height: 200))
            }
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 80))
        }
        let regions = [ReaderTranslationRegion(id: "blur", rect: CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.3),
            source: "Original source strokes", translation: "원문 가림과 번역을 함께 저장")]
        let viewport = CGSize(width: 390, height: 700)
        let output = try await ReaderTranslationImageExporter.render(image: source, regions: regions, settings: settings(),
            viewport: viewport, aspectFit: true, host: view)
        let reference = try await completeRender(image: source, regions: regions, viewport: viewport, host: view)
        // Do not use another WebKit snapshot as the oracle: it can share the same blur bug.
        try expectSourcePixelsUnchanged(output, source, rows: 0..<160)
        try expectSourcePixelsUnchanged(output, source, rows: 640..<800)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try output.pngData()?.write(to: folder.appendingPathComponent("backdrop-export.png"))
        try reference.pngData()?.write(to: folder.appendingPathComponent("backdrop-reference.png"))
    }

    private func completeRender(image: UIImage, regions: [ReaderTranslationRegion], viewport: CGSize,
                                host: UIView) async throws -> UIImage {
        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
        host.addSubview(overlay)
        defer { overlay.cancelWork(); overlay.removeFromSuperview() }
        overlay.update(regions: regions, imageSize: image.size, aspectFit: true, settings: settings(), image: image)
        let deadline = Date().addingTimeInterval(20)
        while overlay.lastDiagnostic?.outcome != .committed {
            try #require(Date() < deadline)
            overlay.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let snapshot = try #require(overlay.renderedImage)
        let size = ReaderTranslationImageExporter.outputSize(for: image)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let displayRect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: image.size, bounds: overlay.bounds, aspectFit: true)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            snapshot.draw(in: CGRect(x: -displayRect.minX * size.width / displayRect.width,
                y: -displayRect.minY * size.height / displayRect.height,
                width: viewport.width * size.width / displayRect.width,
                height: viewport.height * size.height / displayRect.height))
        }
    }

    private func expectSourcePixelsUnchanged(_ output: UIImage, _ source: UIImage, rows: Range<Int>) throws {
        let actual = try pixelData(output)
        let expected = try pixelData(source)
        try #require(actual.count == expected.count)
        let rowBytes = Int(output.size.width) * 4
        let range = (rows.lowerBound * rowBytes)..<(rows.upperBound * rowBytes)
        #expect(actual[range].elementsEqual(expected[range]))
    }

    @Test func exportPreservesFineArtworkAboveAndBelowTranslationAtFullResolution() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2040, height: 2880), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2040, height: 2880))
            UIColor.black.setFill()
            for x in stride(from: 0, to: 2040, by: 2) {
                context.fill(CGRect(x: x, y: 0, width: 1, height: 500))
                context.fill(CGRect(x: x, y: 2380, width: 1, height: 500))
            }
        }
        let regions = [ReaderTranslationRegion(id: "sharp", rect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.2),
            source: "Original", translation: "번역 글자는 선명하게")]
        let output = try await ReaderTranslationImageExporter.render(image: source, regions: regions, settings: settings(),
            viewport: CGSize(width: 390, height: 700), aspectFit: true, host: #require(window.rootViewController?.view))
        try expectSourcePixelsUnchanged(output, source, rows: 0..<500)
        try expectSourcePixelsUnchanged(output, source, rows: 2380..<2880)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try output.pngData()?.write(to: folder.appendingPathComponent("fine-artwork-export.png"))
        try source.pngData()?.write(to: folder.appendingPathComponent("fine-artwork-source.png"))
        let reference = try await completeRender(image: source, regions: regions,
            viewport: CGSize(width: 390, height: 700), host: #require(window.rootViewController?.view))
        try reference.pngData()?.write(to: folder.appendingPathComponent("fine-artwork-old-snapshot.png"))
    }

    @Test func unavailableUntilTranslationAndInvalidatedOnImageChange() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 150)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
        }
        let imageView = UIImageView(image: image)
        let page = ReaderTranslationPage(imageView: imageView)
        #expect(!page.canExportTranslation)
        let region = ReaderTranslationRegion(id: "1", rect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4), source: "Hello", translation: "안녕")
        page.displayPrepared([region], settings: settings())
        #expect(page.canExportTranslation)
        page.showOriginal()
        #expect(page.canExportTranslation)
        imageView.image = nil
        #expect(!page.canExportTranslation)
    }

    @Test func largeWebtoonOutputIsBounded() {
        for pixels in [CGSize(width: 4000, height: 20000), CGSize(width: 1, height: 100000), CGSize(width: 20000, height: 4000)] {
            let size = ReaderTranslationImageExporter.outputSize(for: pixels)
            #expect(size.width * size.height <= 12_000_000)
            #expect(max(size.width, size.height) <= 16_384)
            #expect(size.width >= 1 && size.height >= 1)
        }
    }

    @Test func tallWebtoonIncludesBottomTranslation() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 3000), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 3000))
        }
        let region = ReaderTranslationRegion(id: "bottom", rect: CGRect(x: 0.15, y: 0.94, width: 0.7, height: 0.035),
            source: "Bottom of page", translation: "마지막 페이지도 저장")
        let output = try await ReaderTranslationImageExporter.render(image: source, regions: [region], settings: settings(),
            viewport: CGSize(width: 390, height: 2925), aspectFit: false, host: #require(window.rootViewController?.view))
        #expect(output.size == source.size)
        let pixels = try pixelData(output)
        let original = try pixelData(source)
        #expect(pixels != original)
        let rowBytes = Int(output.size.width) * 4
        let bottom = pixels[(2800 * rowBytes)..<(2980 * rowBytes)]
        #expect(bottom.contains { $0 < 100 })
        #expect(pixels.prefix(100 * rowBytes).allSatisfy { $0 > 240 })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try output.pngData()?.write(to: folder.appendingPathComponent("webtoon-export.png"))
    }

    private func pixelData(_ image: UIImage) throws -> [UInt8] {
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }
}
