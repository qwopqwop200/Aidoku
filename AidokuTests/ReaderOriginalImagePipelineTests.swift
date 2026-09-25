import AidokuRunner
import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderOriginalImagePipelineTests {
    @Test func retiredSettingsCannotEnableProcessingOrReuseOldCache() async throws {
        let defaults = UserDefaults.standard
        let keys = ["Reader.cropBorders", "Reader.downsampleImages", "Reader.upscaleImages", "Reader.upscaleMaxHeight", "Data.enabledModelFile"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: "Reader.cropBorders")
        defaults.set(false, forKey: "Reader.downsampleImages")
        let key = ImageProcessingSettingsKey.getProcessorSettingsKey()
        defaults.set(true, forKey: "Reader.upscaleImages")
        defaults.set(4000, forKey: "Reader.upscaleMaxHeight")
        defaults.set("SwinUNetV3Art2x.mlpackage", forKey: "Data.enabledModelFile")
        #expect(key == ImageProcessingSettingsKey.getProcessorSettingsKey())
        #expect(key != "false-false-true-4000")
        let request = await ReaderPageView.imageRequest(url: URL(fileURLWithPath: "/unused.png"), source: nil)
        #expect(request.processors.isEmpty)
        func visit(_ settings: [Setting]) {
            for setting in settings {
                #expect(!setting.key.lowercased().contains("upscal"))
                switch setting.value {
                case .group(let group): visit(group.items)
                case .page(let page): visit(page.items)
                default: break
                }
            }
        }
        visit(Settings.settings)
        #expect(Bundle.main.url(forResource: "UpscaleModels", withExtension: "json") == nil)
        #expect(Bundle.main.url(forResource: "Upscale-SwinUNetV3Art2x.mlpackage", withExtension: "zip") == nil)
    }

    @Test func fullSizeOriginalReachesReaderAndTranslationLoaderUnchanged() async throws {
        let defaults = UserDefaults.standard
        let keys = ["Reader.cropBorders", "Reader.downsampleImages", "Reader.upscaleImages", "Reader.upscaleMaxHeight", "Data.enabledModelFile", "Reader.liveText", "Dictionary.enable", "Reader.translation.automatic"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.set(false, forKey: key) }
        defaults.set(true, forKey: "Reader.upscaleImages")
        defaults.set(4000, forKey: "Reader.upscaleMaxHeight")
        defaults.set("SwinUNetV3Art2x.mlpackage", forKey: "Data.enabledModelFile")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 2000), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 2000))
            UIColor.red.setFill(); context.fill(CGRect(x: 17, y: 23, width: 391, height: 701))
            UIColor.black.setFill(); context.fill(CGRect(x: 811, y: 37, width: 1, height: 1901))
        }
        let root = URL.documentsDirectory.appendingPathComponent("OriginalImagePipeline/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = try #require(source.pngData()); try png.write(to: root.appendingPathComponent("source.png"))
        let pages = [
            Page(sourceId: "original", chapterId: "raw", index: 0, image: source),
            Page(sourceId: "original", chapterId: "file", index: 0, imageURL: root.appendingPathComponent("source.png").absoluteString),
            Page(sourceId: "original", chapterId: "base64", index: 0, base64: png.base64EncodedString())
        ]
        let expected = try pixels(source)
        for (index, page) in pages.enumerated() {
            let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore())
            view.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
            #expect(await view.setPage(page))
            let displayed = try #require(view.imageView.image)
            #expect(displayed.cgImage?.width == 1600 && displayed.cgImage?.height == 2000)
            #expect(try pixels(displayed) == expected)
            let loaded = try await ReaderTranslationImageLoader().load(page, cacheInMemory: false)
            #expect(try pixels(loaded) == expected)
            try displayed.pngData()?.write(to: root.appendingPathComponent("reader-\(index).png"))
            try loaded.pngData()?.write(to: root.appendingPathComponent("loader-\(index).png"))
            view.releasePageResources()
        }
    }

    private func pixels(_ image: UIImage) throws -> Data {
        let cg = try #require(image.cgImage)
        var bytes = Data(count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }
}
