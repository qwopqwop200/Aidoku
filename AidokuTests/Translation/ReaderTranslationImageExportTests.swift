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
        // Opt-in end-to-end Photos validation on a dedicated simulator.
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("verify-photos").path) {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
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
