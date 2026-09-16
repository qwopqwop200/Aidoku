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
