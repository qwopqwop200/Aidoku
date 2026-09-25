import Testing
import UIKit
import Photos
import WebKit
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

    @Test func cacheSnapshotPreservesTransparentLetterboxAndLogicalImageSize() async throws {
        let window = try host()
        defer { window.isHidden = true; ReaderTranslationImageExporter.clearIdleRenderer() }
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
        defer { window.isHidden = true; ReaderTranslationImageExporter.clearIdleRenderer() }
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
            ReaderTranslationImageExporter.clearIdleRenderer()
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
            do {
                _ = try await ReaderTranslationImageExporter.renderCacheSnapshot(
                    image: invalid.source, imageSize: invalid.size, regions: invalid.content, settings: settings,
                    viewport: invalid.bounds, scale: 2, aspectFit: !webtoon, host: UIView(), dark: false,
                    preparedLayout: nil, assetCache: cache, assetKey: "snapshot")
                Issue.record("Changed snapshot identity replayed a stale asset")
            } catch ReaderTranslationImageExporter.ExportError.unavailable {
                // A cache miss needs the intentionally absent window.
            }
        }
    }

    @Test func exportExtractsEverySourceRepairBeyondTypographyBounds() async throws {
        let window = try host()
        defer { window.isHidden = true }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        try #require(window.rootViewController?.view).addSubview(webView)
        webView.loadHTMLString("<html><meta name=viewport content=width=device-width><body style=margin:0></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading || webView.url == nil {
            try #require(Date() < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await webView.callAsyncJavaScript("""
        const source = new Image();
        source.id = 'reader-source-image';
        const pixel = document.createElement('canvas');
        pixel.width = pixel.height = 1;
        source.src = pixel.toDataURL();
        document.body.append(source);
        await source.decode();
        for (const [index, kind] of ['source-cleanup', 'source-panel-restoration',
             'source-blur', 'source-readability-blur'].entries()) {
          const layer = document.createElement('canvas');
          layer.width = layer.height = 20;
          layer.setAttribute('data-aidoku-image-ocr-overlay', kind);
          layer.style.cssText = `position:absolute;left:${index * 30}px;top:400px;width:20px;height:20px;opacity:0.5`;
          layer.getContext('2d').fillRect(0, 0, 20, 20);
          document.body.append(layer);
        }
        const text = document.createElement('div');
        text.setAttribute('data-aidoku-image-ocr-overlay', 'item');
        text.style.cssText = 'position:absolute;left:150px;top:50px;width:80px;height:30px';
        text.textContent = 'Translation';
        document.body.append(text);
        """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let raw = try #require(try await webView.callAsyncJavaScript(
            ReaderTranslationImageExporter.prepareExportScript, arguments: [:],
            in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? String)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let masks = try #require(payload["masks"] as? [[String: Any]])
        #expect(masks.count == 4)
        for mask in masks {
            let frame = try #require(mask["frame"] as? [Double])
            #expect(frame[1] == 400)
            #expect((mask["png"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        }
        let visibleRepairs = try await webView.evaluateJavaScript("""
        [...document.querySelectorAll('canvas[data-aidoku-image-ocr-overlay]')]
          .filter(node => getComputedStyle(node).visibility !== 'hidden').length
        """) as? Int
        #expect(visibleRepairs == 0)
        let bounds = webView.bounds
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = bounds
        let typography: Data = try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: pdfConfiguration) { continuation.resume(with: $0) }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
        }
        let layers = try JSONDecoder().decode(ReaderTranslationImageExporter.ExportLayers.self, from: Data(raw.utf8))
        let output = try ReaderTranslationImageExporter.composite(image: original, typography: typography,
            layers: layers, displayRect: bounds, size: bounds.size)
        let pixels = try pixelData(output)
        for index in 0..<4 {
            let offset = (410 * Int(bounds.width) + index * 30 + 10) * 4
            // A single 50% black repair over white is gray. Missing layers are
            // white; accidentally including them in the PDF darkens them twice.
            #expect((120...135).contains(Int(pixels[offset])))
            #expect((120...135).contains(Int(pixels[offset + 1])))
            #expect((120...135).contains(Int(pixels[offset + 2])))
        }
        #expect(pixels[(450 * Int(bounds.width) + 10) * 4] > 245)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #require(output.pngData()).write(to: folder.appendingPathComponent("all-source-repairs-composite.png"))
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
        _ = try await overlay.webView.callAsyncJavaScript(
            "await document.fonts.ready; await new Promise(resolve => setTimeout(resolve, 200));",
            arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let size = ReaderTranslationImageExporter.outputSize(for: image)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: image.size, bounds: overlay.bounds, aspectFit: true)
        configuration.snapshotWidth = NSNumber(value: Double(size.width / max(1, overlay.traitCollection.displayScale)))
        let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
            overlay.webView.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? ReaderTranslationImageExporter.ExportError.renderFailed) }
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            snapshot.draw(in: CGRect(origin: .zero, size: size))
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

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        FileManager.default.documentDirectory.appendingPathComponent("TranslationExportValidation/source.png").path)))
    func realMangaExportWithRecordedKoreanTranslation() async throws {
        let sourceURL = folder.appendingPathComponent("source.png")
        let window = try host()
        defer { window.isHidden = true }
        let source = try #require(UIImage(contentsOfFile: sourceURL.path))
        let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
            from: Data(contentsOf: folder.appendingPathComponent("regions.json"))).map(\.region)
        #expect(regions.contains { $0.translation != nil })
        let output = try await ReaderTranslationImageExporter.render(image: source, regions: regions, settings: settings(),
            viewport: CGSize(width: 390, height: 700), aspectFit: true, host: #require(window.rootViewController?.view))
        #expect(output.size == ReaderTranslationImageExporter.outputSize(for: source))
        #expect(try pixelData(output) != pixelData(source))
        try output.pngData()?.write(to: folder.appendingPathComponent("real-translated-export.png"))
        let reference = try await completeRender(image: source, regions: regions,
            viewport: CGSize(width: 390, height: 700), host: #require(window.rootViewController?.view))
        try reference.pngData()?.write(to: folder.appendingPathComponent("real-render-reference.png"))
        // Opt-in end-to-end Photos validation on a dedicated simulator.
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("verify-photos").path) {
            let authorization = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
            }
            try #require(authorization == .authorized || authorization == .limited)
            let before = PHAsset.fetchAssets(with: .image, options: nil).count
            output.saveToAlbum("Aidoku Export Validation", viewController: try #require(window.rootViewController))
            let deadline = Date().addingTimeInterval(10)
            while PHAsset.fetchAssets(with: .image, options: nil).count == before, Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(PHAsset.fetchAssets(with: .image, options: nil).count == before + 1)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        FileManager.default.documentDirectory.appendingPathComponent("TranslationExportValidation/actual-source.png").path)))
    func actualPageExportPreservesHeaderUnderReaderAndProgressAlert() async throws {
        let source = try #require(UIImage(contentsOfFile: folder.appendingPathComponent("actual-source.png").path))
        let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
            from: Data(contentsOf: folder.appendingPathComponent("actual-regions.json"))).map(\.region)
        let window = try host()
        defer { window.isHidden = true }
        let controller = try #require(window.rootViewController)
        let view = try #require(controller.view)
        let reader = UIImageView(frame: view.bounds)
        reader.image = source
        reader.contentMode = .scaleAspectFit
        reader.backgroundColor = .black
        view.addSubview(reader)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 120))
        header.backgroundColor = .black
        view.addSubview(header)
        let progress = UIAlertController(title: "Saving translation", message: "Loading…", preferredStyle: .alert)
        controller.present(progress, animated: false)
        defer { progress.dismiss(animated: false) }
        try await Task.sleep(for: .milliseconds(250))
        var configuration = settings()
        configuration.overlay.opacity = 0.84
        configuration.overlay.preserveSourceBackgroundColor = true
        configuration.overlay.preserveSourceTextColor = true
        let output = try await ReaderTranslationImageExporter.render(image: source, regions: regions,
            settings: configuration, viewport: CGSize(width: 390, height: 700), aspectFit: true, host: view)
        try output.pngData()?.write(to: folder.appendingPathComponent("actual-export.png"))
        try expectSourcePixelsUnchanged(output, source, rows: 0..<200)
        try expectSourcePixelsUnchanged(output, source, rows: 1134..<1334)
        let cached = try await ReaderTranslationImageExporter.renderCacheSnapshot(
            image: source, imageSize: source.size, regions: regions, settings: configuration,
            viewport: CGSize(width: 390, height: 390 * source.size.height / source.size.width),
            scale: 3, aspectFit: false, host: window, dark: false, preparedLayout: nil)
        let pixels = try #require(cached.cgImage)
        #expect(pixels.width * pixels.height <= 4_000_000)
        try #require(cached.pngData()).write(to: folder.appendingPathComponent("actual-reader-cache.png"))
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

    @Test func idleRendererSurvivesTranslationGapOnlyWithExtraHeadroom() {
        let minimum = TranslationImageWorkBudget.minimumHeadroom
        let comfortable = minimum + 256 * 1_024 * 1_024
        var discarded: [Int] = []
        let slot = ReaderTranslationIdleRendererSlot<Int> { discarded.append($0) }
        // Typical API gaps exceed the old unconditional two-second expiry.
        slot.store(1, now: 0)
        #expect(slot.take(now: 4.8, availableMemory: comfortable, isActive: true) == 1)
        slot.store(2, now: 5)
        #expect(slot.take(now: 13.8, availableMemory: comfortable, isActive: true) == 2)
        #expect(discarded.isEmpty)
        slot.store(3, now: 14)
        #expect(slot.take(now: 24, availableMemory: comfortable, isActive: true) == nil)
        #expect(discarded == [3])
        // Keep the existing short lease on tighter-memory devices.
        slot.store(4, now: 25)
        #expect(slot.take(now: 27, availableMemory: comfortable - 1, isActive: true) == nil)
        #expect(discarded == [3, 4])
    }

    @Test func idleRendererImmediatelyDropsOnPressureAndBackground() {
        let minimum = TranslationImageWorkBudget.minimumHeadroom
        let comfortable = minimum + 256 * 1_024 * 1_024
        var discarded: [Int] = []
        let slot = ReaderTranslationIdleRendererSlot<Int> { discarded.append($0) }
        slot.store(1, now: 0)
        #expect(slot.trim(now: 0.1, availableMemory: minimum - 1, isActive: true))
        #expect(slot.take(now: 0.2, availableMemory: comfortable, isActive: true) == nil)
        slot.store(2, now: 1)
        #expect(slot.trim(now: 1.1, availableMemory: comfortable, isActive: false))
        #expect(slot.take(now: 1.2, availableMemory: comfortable, isActive: true) == nil)
        slot.store(3, now: 2)
        // A high-headroom lease contracts as soon as headroom falls.
        #expect(slot.trim(now: 5, availableMemory: minimum, isActive: true))
        #expect(discarded == [1, 2, 3])
    }

    @Test func idleRendererSlotNeverRetainsMoreThanOneAndClearsOnce() {
        let comfortable = TranslationImageWorkBudget.minimumHeadroom + 256 * 1_024 * 1_024
        var discarded: [Int] = []
        let slot = ReaderTranslationIdleRendererSlot<Int> { discarded.append($0) }
        slot.store(1, now: 0)
        slot.store(2, now: 1)
        #expect(discarded == [1])
        #expect(slot.take(now: 1.1, availableMemory: comfortable, isActive: true) == 2)
        #expect(slot.take(now: 1.2, availableMemory: comfortable, isActive: true) == nil)
        slot.store(3, now: 2)
        #expect(slot.clear())
        #expect(!slot.clear())
        #expect(discarded == [1, 3])
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
