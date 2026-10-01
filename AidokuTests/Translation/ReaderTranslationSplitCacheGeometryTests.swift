import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationSplitCacheGeometryTests {
    @Test func preparedSplitSizesAndKeysMatchReaderCrops() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.includePageImage = false
        let viewport = CGSize(width: 390, height: 600)
        for width in [1000, 1001] {
            let pixels = try makePixels(width: width)
            for scale: CGFloat in [1, 2, 3] {
                for orientation: UIImage.Orientation in [.up, .down, .left, .right, .upMirrored, .rightMirrored] {
                    let source = UIImage(cgImage: pixels, scale: scale, orientation: orientation)
                    for x: CGFloat in [0, 0.5] {
                        let crop = CGRect(x: x, y: 0, width: 0.5, height: 1)
                        // Independent oracle: these are the actual ReaderPageView.splitImage operations.
                        let readerPixels = try #require(pixels.cropping(to: CGRect(
                            x: x * CGFloat(width), y: 0, width: CGFloat(width) / 2, height: CGFloat(pixels.height))))
                        let reader = UIImage(cgImage: readerPixels, scale: scale, orientation: orientation)
                        let prepared = try #require(ReaderTranslationSplitGeometry.image(source, crop: crop))
                        #expect(prepared.size == reader.size)
                        #expect(prepared.scale == reader.scale)
                        #expect(prepared.imageOrientation == reader.imageOrientation)
                        func key(_ size: CGSize) -> String {
                            ReaderTranslationCacheIdentity.render(page: "split-source", settings: settings, imageSize: size,
                                viewport: viewport, scale: 3, aspectFit: true, crop: crop, dark: false)
                        }
                        #expect(key(prepared.size) == key(reader.size))
                        if width == 1001 && scale == 1 && orientation == .up {
                            #expect(prepared.size.width == 501)
                            #expect(key(CGSize(width: 500.5, height: CGFloat(pixels.height))) != key(reader.size))
                        }
                    }
                }
            }
        }
    }

    @Test func splitCannotOverwriteBorrowedFullSource() throws {
        let preparer = ReaderTranslationLayoutPreparer()
        let full = UIImage(cgImage: try makePixels(width: 1001))
        let original = Page(sourceId: "split-source", chapterId: "chapter", index: 0)
        let crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let half = try #require(ReaderTranslationSplitGeometry.image(full, crop: crop))
        let split = Page(sourceId: original.sourceId, chapterId: original.chapterId, index: original.index,
                         image: half, translationOriginalKey: original.translationCacheKey, translationSourceRect: crop)
        preparer.sourceDidLoad(full, page: original)
        preparer.sourceDidLoad(half, page: split)
        #expect(preparer.loadedImage(for: original) === full)
        #expect(preparer.loadedImage(for: split) === full)
    }

    @Test func legacyPointSizeCannotInventSplitLayout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let renderCache = ReaderTranslationRenderCache(disk: disk)
        let original = Page(sourceId: "split-source", chapterId: "chapter", index: 0)
        let full = UIImage(cgImage: try makePixels(width: 1001), scale: 2, orientation: .up)
        let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let half = try #require(ReaderTranslationSplitGeometry.image(full, crop: crop))
        let split = Page(sourceId: original.sourceId, chapterId: original.chapterId, index: original.index,
                         image: half, translationOriginalKey: original.translationCacheKey, translationSourceRect: crop)
        let imageView = UIImageView(image: half)
        imageView.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = split
        let geometry = ReaderTranslationLayoutGeometry(page: page, imageView: imageView)
        try await disk.storeImageSize(full.size, page: original.translationCacheKey, generation: 0)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: renderCache, layoutPreparation: { _, _, _, _, _, _ in
            Issue.record("Legacy point dimensions do not identify integral pixel crops")
            return Data("[]".utf8)
        })
        let regions = [ReaderTranslationRegion(id: "text", rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                                              source: "Original", translation: "번역")]
        try await preparer.prepareTextOnly(page: original, regions: regions, settings: ReaderTranslationSettings(), geometry: geometry)
    }

    private func makePixels(width: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
}
