import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderDecodeDownsampleTests {
    private func withSettings(crop: Bool, downsample: Bool, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let keys = ["Reader.cropBorders", "Reader.downsampleImages"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(crop, forKey: "Reader.cropBorders")
        defaults.set(downsample, forKey: "Reader.downsampleImages")
        try await body()
    }

    @Test func downsampleDecodesWithoutFullResolutionBitmapAndKeepsProcessorDimensions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 400), format: format).image {
            UIColor.gray.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 3000, height: 400))
        }
        let url = root.appendingPathComponent("wide.png")
        try #require(source.pngData()).write(to: url)

        try await withSettings(crop: false, downsample: true) {
            let request = await ReaderPageView.imageRequest(url: url, source: nil)
            #expect(request.thumbnail != nil)
            let pipeline = ImagePipeline { $0.imageCache = nil; $0.dataCache = nil }
            let decoded = try await pipeline.image(for: request)
            let expected = try #require(DownsampleProcessor(width: UIScreen.main.bounds.width).process(source))
            let decodedRaster = try #require(decoded.cgImage)
            let expectedRaster = try #require(expected.cgImage)
            #expect(decodedRaster.width == expectedRaster.width)
            #expect(abs(decodedRaster.height - expectedRaster.height) <= 1)
            #expect(decoded.scale == expected.scale)
        }
    }

    @Test func fullPixelProcessorsKeepFullDecode() async throws {
        let url = URL(fileURLWithPath: "/unused.png")
        try await withSettings(crop: true, downsample: true) {
            #expect(await ReaderPageView.imageRequest(url: url, source: nil).thumbnail == nil)
        }
        try await withSettings(crop: false, downsample: false) {
            #expect(await ReaderPageView.imageRequest(url: url, source: nil).thumbnail == nil)
        }
        #expect(DownsampleProcessor.decodeThumbnail(width: 0) == nil)
        #expect(DownsampleProcessor.decodeThumbnail(width: .nan) == nil)
    }
}
