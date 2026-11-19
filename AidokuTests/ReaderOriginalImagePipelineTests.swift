import AidokuRunner
import Nuke
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderOriginalImagePipelineTests {
    @Test(arguments: [false, true])
    func coldArchiveBytesShareTheDisplayDecoder(deflated: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        defer { url.removeItem() }
        let store = ReaderTemporaryPageStore()
        let pipeline = ImagePipeline { $0.imageCache = ImageCache() }
        let loader = ReaderTranslationImageLoader(pipeline: pipeline, temporaryStore: store)
        let page = Page(sourceId: "", chapterId: "archive", imageURL: "page.png", zipURL: url.absoluteString)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 19, height: 11), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 19, height: 11))
        }
        let png = try #require(image.pngData())
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "page.png", type: .file, uncompressedSize: Int64(png.count),
                             compressionMethod: deflated ? .deflate : .none) { start, length in
            png.subdata(in: Int(start)..<(Int(start) + length))
        }
        try archive.addEntry(with: "empty.gif", type: .file, uncompressedSize: Int64(0)) { _, _ in Data() }
        #expect(await store.archiveImageSource(from: url, path: "empty.gif") == nil)
        let empty = try #require(await store.storeArchiveEntry(from: url, path: "empty.gif"))
        #expect(try await pipeline.data(for: ImageRequest(url: empty)).0.isEmpty)
        let source = try #require(await store.archiveImageSource(from: url, path: "page.png"))
        let request = await ReaderPageView.imageRequest(url: url, sourceKey: page.sourceId, archiveRequest: source.request)
        #expect(request.url == nil)
        #expect(try await source.decodedBytes() == 19 * 11 * 4)
        let data = try await pipeline.data(for: source.request).0
        #expect(data == png)
        let translated = try await loader.load(page)
        let displayed = try await pipeline.image(for: request)
        #expect(translated === displayed)
        await store.removeAll()
    }

    @Test func translationAndDisplayShareExtractedPixelsAndRespectArchiveReplacement() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ReaderTemporaryPageStore()
        let pipeline = ImagePipeline { $0.imageCache = ImageCache() }
        let loader = ReaderTranslationImageLoader(pipeline: pipeline, temporaryStore: store)
        let page = Page(sourceId: "", chapterId: "archive", imageURL: "page.png", zipURL: url.absoluteString)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for width in [8, 24] {
            let size = CGSize(width: width, height: 8)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let png = try #require(image.pngData())
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let archive = try Archive(url: url, accessMode: .create)
            try archive.addEntry(with: "page.png", type: .file, uncompressedSize: Int64(png.count)) { start, length in
                png.subdata(in: Int(start)..<(Int(start) + length))
            }
            let extracted = try #require(await store.storeArchiveEntry(from: url, path: "page.png"))
            let request = await ReaderPageView.imageRequest(url: extracted, sourceKey: page.sourceId)
            let displayed = try await pipeline.image(for: request)
            let translated = try await loader.load(page)
            #expect(translated === displayed)
            #expect(TranslationImageWorkBudget.decodedBytes(at: extracted) == UInt64(width * 8 * 4))
            #expect(try Data(contentsOf: extracted) == png)
        }
        await store.removeAll()
    }

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
        let keys = ["Reader.cropBorders", "Reader.downsampleImages", "Reader.liveText", "Dictionary.enable", "Reader.translation.automatic"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.set(false, forKey: key) }
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
            let loaded = try await ReaderTranslationImageLoader().load(page)
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
