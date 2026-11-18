import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationSplitCacheGeometryTests {
    @Test func neighboringPortraitAndWidePagesWarmOnlyTheirOwnReaderCrops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: directory))
        actor LayoutInputs {
            var sizes: [CGSize] = []
            func append(_ size: CGSize) { sizes.append(size) }
            func take() -> [CGSize] { defer { sizes.removeAll() }; return sizes }
        }
        let inputs = LayoutInputs()
        let preparer = ReaderTranslationLayoutPreparer(renderCache: cache) { items, size, rect, settings, language, viewport in
            await inputs.append(size)
            return try await NativeTranslationLayoutPlanner.prepareLayoutData(
                items: items, imageSize: size, sourceRect: rect, settings: settings, targetLanguage: language, viewport: viewport)
        }
        let settings = ReaderTranslationSettings()
        let unit = ReaderTranslationSplitGeometry.unit
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 160, height: 200))
        view.contentMode = .scaleAspectFit
        let visible = ReaderTranslationPage(imageView: view)
        let regions = [left, right].enumerated().map { index, crop in
            ReaderTranslationRegion(id: "text-\(index)", rect: crop.insetBy(dx: 0.05, dy: 0.2), source: "Source", translation: "번역")
        }
        for (index, width) in [51, 201].enumerated() {
            let image = UIImage(cgImage: try makePixels(width: width))
            let page = Page(sourceId: "target-crops", chapterId: "chapter", index: index, image: image)
            visible.sourcePage = Page(sourceId: "target-crops", chapterId: "chapter", index: 20,
                                      translationSourceRect: width < 100 ? left : nil)
            let geometry = ReaderTranslationLayoutGeometry(page: visible, imageView: view, widePageLayout: .halves)
            let expected = width < 100 ? [unit] : [left, right]
            #expect(try geometry.targetCrops(for: image) == expected)
            #expect(try ReaderTranslationLayoutGeometry(page: visible, imageView: view).targetCrops(for: image) == [unit])
            let saturated = ReaderTranslationLayoutGeometry(page: visible, imageView: view, widePageLayout: .pendingSplit)
            if width < 100 {
                #expect(try saturated.targetCrops(for: image) == [unit])
            } else {
                #expect(throws: CancellationError.self) { try saturated.targetCrops(for: image) }
            }
            let claim = try #require(ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: image))
            preparer.sourceDidLoad(image, page: page)
            cache.setNearbyPages(pageKeys: [page.translationCacheKey], settings: settings)
            try await preparer.prepare(page: page, regions: regions, settings: settings, geometry: geometry, expectedSource: claim)
            let expectedSizes = try expected.map { try #require(ReaderTranslationSplitGeometry.image(image, crop: $0)).size }
            #expect(await inputs.take() == expectedSizes)
            for crop in [unit, left, right] {
                let pixels = try #require(ReaderTranslationSplitGeometry.image(image, crop: crop))
                let key = ReaderTranslationCacheIdentity.render(page: page.translationCacheKey, settings: settings,
                    imageSize: pixels.size, viewport: geometry.viewport(for: pixels.size), scale: geometry.scale,
                    aspectFit: true, crop: crop, dark: geometry.dark)
                let snapshot = ReaderTranslationRenderCache.snapshotKey(renderKey: key, regions: regions.compactMap { $0.cropped(to: crop) })
                let hit = await cache.loadSnapshot(snapshot, source: pixels)
                #expect((hit != nil) == expected.contains(crop))
            }
        }
    }

    @Test func preparedSplitSizesAndKeysMatchReaderCrops() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.includePageImage = false
        let viewport = CGSize(width: 390, height: 600)
        for width in [1000, 1001] {
            let pixels = try makePixels(width: width)
            for scale: CGFloat in [1, 2, 3] {
                for orientation: UIImage.Orientation in [.up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored] {
                    let source = UIImage(cgImage: pixels, scale: scale, orientation: orientation)
                    for x: CGFloat in [0, 0.5] {
                        let crop = CGRect(x: x, y: 0, width: 0.5, height: 1)
                        // Match the established reader split: crop encoded pixels, then display with the original orientation.
                        let readerPixels = try #require(pixels.cropping(to: CGRect(
                            x: x * CGFloat(width), y: 0, width: CGFloat(width) / 2, height: CGFloat(pixels.height))))
                        let reader = UIImage(cgImage: readerPixels, scale: scale, orientation: orientation)
                        let prepared = try #require(ReaderTranslationSplitGeometry.image(source, crop: crop))
                        #expect(prepared.size == reader.size)
                        #expect(prepared.scale == reader.scale)
                        #expect(prepared.imageOrientation == source.imageOrientation)
                        let visible = try #require(ReaderTranslationImagePreparation.uprightSourceImage(prepared).cgImage)
                        let baseline = try #require(ReaderTranslationImagePreparation.uprightSourceImage(reader).cgImage)
                        #expect(try rgba(visible) == rgba(baseline))
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

    @Test func inlineSplitIsNotDownsampledAgainWhenLoadedWithoutSkipFlag() async throws {
        let defaults = UserDefaults.standard
        let key = "Reader.downsampleImages"
        let oldValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(oldValue, forKey: key) }

        let fallbackWidth = Int(max(800, UIScreen.main.bounds.width * 2))
        let full = UIImage(cgImage: try makePixels(width: fallbackWidth * 2 + 1))
        let original = Page(sourceId: "split-source", chapterId: "reopen", index: 0, image: full)
        let rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let half = try #require(ReaderTranslationSplitGeometry.image(full, crop: rect))
        let split = Page(sourceId: original.sourceId, chapterId: original.chapterId, index: original.index,
                         image: half, translationOriginalKey: original.translationCacheKey, translationSourceRect: rect)
        let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore())
        defer { view.releasePageResources() }
        #expect(await view.setPage(split))
        #expect(view.imageView.image === half)
        #expect(view.imageView.image?.cgImage?.width == half.cgImage?.width)
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
        let geometry = ReaderTranslationLayoutGeometry(page: page, imageView: imageView, widePageLayout: .halves)
        try await disk.storeImageSize(full.size, page: original.translationCacheKey, generation: 0)
        let preparer = ReaderTranslationLayoutPreparer(renderCache: renderCache, layoutPreparation: { _, _, _, _, _, _ in
            Issue.record("Legacy point dimensions do not identify integral pixel crops")
            return Data("[]".utf8)
        })
        let regions = [ReaderTranslationRegion(id: "text", rect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                                              source: "Original", translation: "번역")]
        try await preparer.prepareTextOnly(page: original, regions: regions, settings: ReaderTranslationSettings(), geometry: geometry)
    }

    @Test func exactInlineSidesOnlyAttestTheirOwnFullRasterAndCrop() async throws {
        let key = "same-page-locator"
        let fullA = UIImage(cgImage: try makePixels(width: 1001, fill: .red), scale: 2, orientation: .rightMirrored)
        let fullB = UIImage(cgImage: try makePixels(width: 1001, fill: .blue), scale: 2, orientation: .rightMirrored)
        let claimA = try #require(await Task.detached { ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: fullA) }.value)
        let claimB = try #require(await Task.detached { ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: fullB) }.value)
        #expect(claimA != claimB)
        let a = try #require(ReaderTranslationSplitSource.makeSides(from: fullA, originalKey: key))
        let b = try #require(ReaderTranslationSplitSource.makeSides(from: fullB, originalKey: key))
        let left = try #require(a.left.source)
        let right = try #require(a.right.source)
        #expect(a.left.image.size == b.left.image.size)
        #expect(a.left.image.imageOrientation == fullA.imageOrientation)
        #expect(await left.claim(for: a.left.image, originalKey: key, crop: a.left.crop) == claimA)
        #expect(await right.claim(for: a.right.image, originalKey: key, crop: a.right.crop) == claimA)
        #expect(left.memoizedClaim(for: b.left.image, originalKey: key, crop: a.left.crop) == nil)
        #expect(left.memoizedClaim(for: a.left.image, originalKey: key, crop: a.right.crop) == nil)
        #expect(left.memoizedClaim(for: a.left.image, originalKey: "other-locator", crop: a.left.crop) == nil)
        #expect(left.sealPNG(from: b.left.image) == nil)
    }

    @Test func persistedSideDecodesAndVerifiesOnePNGSnapshotBeforePresentation() async throws {
        let store = ReaderTemporaryPageStore()
        defer { Task { await store.removeAll() } }
        let original = Page(sourceId: "split-source", chapterId: "same-locator", index: 1)
        let key = original.translationCacheKey
        let fullA = UIImage(cgImage: try makePixels(width: 1001, fill: .red), scale: 2, orientation: .rightMirrored)
        let fullB = UIImage(cgImage: try makePixels(width: 1001, fill: .blue), scale: 2, orientation: .rightMirrored)
        let claimA = try #require(await Task.detached { ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: fullA) }.value)
        let claimB = try #require(await Task.detached { ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: fullB) }.value)
        #expect(claimA != claimB)
        func splitPages(from image: UIImage) throws -> [Page] {
            let sides = try #require(ReaderTranslationSplitSource.makeSides(from: image, originalKey: key))
            return [sides.left, sides.right].map {
                Page(sourceId: original.sourceId, chapterId: original.chapterId, index: original.index,
                     image: $0.image, translationOriginalKey: key, translationSourceRect: $0.crop, translationSplitSource: $0.source)
            }
        }
        let inlineA = try splitPages(from: fullA)
        let inlineB = try splitPages(from: fullB)
        let a = try #require(await store.storeSplitPages(inlineA, chapterKey: original.chapterId, pageIndex: 1))
        let b = try #require(await store.storeSplitPages(inlineB, chapterKey: original.chapterId, pageIndex: 1))
        let fileA = try #require(a.first?.imageURL.flatMap(URL.init(string:)))
        let fileB = try #require(b.first?.imageURL.flatMap(URL.init(string:)))
        let pageA = a[0]
        let oldProof = try #require(pageA.translationSplitSource)
        let crop = try #require(pageA.translationSourceRect)
        #expect(pageA.image == nil)
        #expect(fileA != fileB)
        let rawPNG = try Data(contentsOf: fileA)
        let otherPNG = try Data(contentsOf: fileB)
        #expect(rawPNG != otherPNG)
        let unrelatedDecode = try #require(UIImage(data: rawPNG))
        #expect(oldProof.memoizedClaim(for: unrelatedDecode, originalKey: key, crop: crop) == nil)

        let view = ReaderPageView(temporaryPageStore: store)
        defer { view.releasePageResources() }
        #expect(await view.setPage(pageA))
        let confirmed = try #require(view.imageView.image)
        // Stored split PNGs reopen at the decoder's default point scale, including a 2x source.
        #expect(confirmed.scale == unrelatedDecode.scale && confirmed.size == unrelatedDecode.size)
        #expect(confirmed.imageOrientation == unrelatedDecode.imageOrientation)
        #expect(confirmed.scale == 1)
        #expect(oldProof.memoizedClaim(for: confirmed, originalKey: key, crop: crop) == claimA)
        let rebound = ReaderPageView(temporaryPageStore: store)
        #expect(await rebound.setPage(pageA))
        #expect(rebound.imageView.image === confirmed)
        #expect(try rgba(#require(rebound.imageView.image?.cgImage)) == rgba(#require(unrelatedDecode.cgImage)))
        rebound.releasePageResources()
        view.releasePageResources()
        weak var released: UIImage?
        autoreleasepool {
            let readOnce = b[0].translationSplitSource?.decodeStoredPNG(otherPNG)
            released = readOnce
            #expect(readOnce != nil)
        }
        #expect(released == nil)

        // Simulate same-path bytes changing despite content-addressed naming.
        try otherPNG.write(to: fileA, options: .atomic)
        #expect(await view.setPage(pageA))
        let unconfirmed = try #require(view.imageView.image)
        let replacement = try #require(UIImage(data: otherPNG))
        #expect(unconfirmed.size == replacement.size && unconfirmed.imageOrientation == replacement.imageOrientation)
        #expect(try rgba(#require(unconfirmed.cgImage)) == rgba(#require(replacement.cgImage)))
        #expect(oldProof.memoizedClaim(for: unconfirmed, originalKey: key, crop: crop) == nil)
        #expect(oldProof.memoizedClaim(for: confirmed, originalKey: key, crop: crop) == claimA)
    }

    @Test func cachedRegionsRequireExactFullOrBoundSplitPixelsForTheSameKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let session = ReaderTranslationSession(processRecord: { _, _, _ in throw CancellationError() }, diskCache: disk)
        let settings = ReaderTranslationSettings()
        let a = UIImage(cgImage: try makePixels(width: 601, fill: .white))
        let b = UIImage(cgImage: try makePixels(width: 601, fill: .black))
        let aClaim = try #require(await Task.detached { ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: a) }.value)
        let bClaim = try #require(await Task.detached { ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: b) }.value)
        #expect(aClaim != bClaim && a.size == b.size)
        let page = Page(sourceId: "source-proof", chapterId: "chapter", index: 0)
        let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
        let records = [ReaderTranslationRegion(id: "source", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
                                               source: "こんにちは", translation: "안녕")]
        try await disk.storeRegions(records, for: key, kind: .translation,
            generation: await disk.currentGeneration(settings: settings), sourceRasterClaim: aClaim)
        #expect(try await session.cachedRegions(for: page, settings: settings) == nil)
        #expect(try await session.cachedRegions(for: page, settings: settings, sourceImage: b) == nil)
        #expect(try await session.cachedRegions(for: page, settings: settings, sourceImage: a) == records)
        let sa = try #require(ReaderTranslationSplitSource.makeSides(from: a, originalKey: page.translationCacheKey))
        let sb = try #require(ReaderTranslationSplitSource.makeSides(from: b, originalKey: page.translationCacheKey))
        var split = page
        split.translationOriginalKey = page.translationCacheKey
        split.translationSourceRect = sa.left.crop
        split.translationSplitSource = sa.left.source
        #expect(try await session.cachedRegions(for: split, settings: settings, sourceImage: sa.left.image) == records)
        #expect(try await session.cachedRegions(for: split, settings: settings, sourceImage: sa.right.image) == nil)
        #expect(try await session.cachedRegions(for: split, settings: settings, sourceImage: sb.left.image) == nil)
        split.translationSplitSource = sb.left.source
        #expect(try await session.cachedRegions(for: split, settings: settings, sourceImage: sb.left.image) == nil)
    }

    @Test func deferredCompositeCannotMountOnDifferentPixelsOfTheSameSize() throws {
        let a = UIImage(cgImage: try makePixels(width: 501, fill: .white))
        let b = UIImage(cgImage: try makePixels(width: 501, fill: .black))
        let translated = [ReaderTranslationRegion(id: "text", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
                                                  source: "こんにちは", translation: "안녕")]
        let prepared = ReaderTranslationPreparedImage(image: a, regions: translated, settings: .init(),
            matchesSourceImage: { [weak a] candidate in a === candidate })
        let view = UIImageView(image: b)
        let page = ReaderTranslationPage(imageView: view)
        page.displayLoadedImage(prepared)
        #expect(page.regions.isEmpty)
        #expect(!page.canExportTranslation)
        view.image = a
        page.displayLoadedImage(prepared)
        #expect(page.regions == translated.compactMap { $0.cropped(to: ReaderTranslationSplitGeometry.unit) })
        #expect(page.canExportTranslation)
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    private func makePixels(width: Int, fill: UIColor? = nil) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if let fill {
            context.setFillColor(fill.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: 100))
        } else {
            // Distinct corners distinguish swapped sides and quarter turns of uniform-size crops.
            for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: index % 2 * (width / 2), y: index / 2 * 50, width: (width + 1) / 2, height: 50))
            }
        }
        return try #require(context.makeImage())
    }
}
