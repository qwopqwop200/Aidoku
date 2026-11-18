import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationPreviewInvalidationTests {
    @Test func repeatedSplitPreviewRestoresItsBitmapUntilTheSourceOrCropChanges() async throws {
        let size = CGSize(width: 48, height: 40)
        let bounds = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let source = renderer.image { context in
            UIColor.white.setFill()
            context.fill(bounds)
        }
        let bitmap = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(bounds)
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 2, y: 3, width: 9, height: 14))
        }
        let view = UIImageView(image: source)
        view.frame = bounds
        let page = ReaderTranslationPage(imageView: view)
        var original = Page(sourceId: "split-preview", chapterId: "chapter", index: 0)
        let crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        original.translationSourceRect = crop
        page.sourcePage = original
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        page.renderCache = cache
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.automaticallyTranslate = true
        var inside = ReaderTranslationRegion(id: "inside", rect: CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.3),
                                             source: "Right", translation: "오른쪽")
        inside.unitMemberRects = [inside.rect]
        inside.polygon = [CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.8, y: 0.4)]
        let outside = ReaderTranslationRegion(id: "outside", rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1),
                                              source: "Left", translation: "왼쪽")
        let regions = [outside, inside]
        let displayed = regions.compactMap { $0.cropped(to: crop) }
        let renderKey = ReaderTranslationCacheIdentity.render(page: original.translationCacheKey, settings: settings,
            imageSize: source.size, viewport: size, scale: view.traitCollection.displayScale, aspectFit: false, crop: crop,
            dark: view.traitCollection.userInterfaceStyle == .dark)
        let key = ReaderTranslationRenderCache.snapshotKey(renderKey: renderKey, regions: displayed)
        await cache.store(bitmap, key: key, pageIdentity: original.translationCacheKey,
                          diskGeneration: await disk.currentGeneration(), source: source)
        page.displayPreparedSnapshot(regions, settings: settings, memoryOnly: true)
        let canvas = try #require(view.subviews.first as? UIImageView)
        #expect(page.regions == displayed)
        page.hidePreparedTranslation()
        #expect(canvas.isHidden)
        page.displayPreparedSnapshot(regions, settings: settings, memoryOnly: true)
        #expect(view.subviews.first === canvas && canvas.image === bitmap && !canvas.isHidden)
        let visible = renderer.image { view.layer.render(in: $0.cgContext) }
        let actual = try #require(visible.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        let expected = try #require(bitmap.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        #expect(actual.bytes == expected.bytes)

        var otherHalfChanged = regions
        otherHalfChanged[0].translation = "새 번역"
        page.displayPreparedSnapshot(otherHalfChanged, settings: settings, memoryOnly: true)
        #expect(view.subviews.first === canvas && page.regions == displayed)
        view.image = bitmap
        page.displayPreparedSnapshot(regions, settings: settings, memoryOnly: true)
        #expect(!page.isUsingCachedRendering)
        view.image = source
        page.displayPreparedSnapshot(regions, settings: settings, memoryOnly: true)
        #expect(page.isUsingCachedRendering)
        original.translationSourceRect = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        page.sourcePage = original
        page.displayPreparedSnapshot(regions, settings: settings, memoryOnly: true)
        #expect(!page.isUsingCachedRendering && page.regions.isEmpty)
    }

    @Test(arguments: [false, true])
    func finalResultChangeDropsStalePreviewOnMemoryMiss(empty: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let source = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let view = UIImageView(image: source)
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        let page = ReaderTranslationPage(imageView: view)
        let original = Page(sourceId: "preview-source", chapterId: "chapter", index: 0)
        page.sourcePage = original
        page.renderCache = cache
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.includePageImage = false
        let old = ReaderTranslationRegion(id: "region", rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                          source: "Original", translation: "이전 번역")
        let crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        let displayed = [old].compactMap { $0.cropped(to: crop) }
        let renderKey = ReaderTranslationCacheIdentity.render(page: original.translationCacheKey, settings: settings,
            imageSize: source.size, viewport: view.bounds.size, scale: view.traitCollection.displayScale,
            aspectFit: false, crop: crop, dark: view.traitCollection.userInterfaceStyle == .dark)
        let key = ReaderTranslationRenderCache.snapshotKey(renderKey: renderKey, regions: displayed)
        await cache.store(source, key: key,
            pageIdentity: ReaderTranslationCacheIdentity.translation(page: original.translationCacheKey, settings: settings),
            diskGeneration: await disk.currentGeneration(), source: source)
        page.displayPreparedSnapshot([old], settings: settings, memoryOnly: true)
        #expect(page.isUsingCachedRendering)
        #expect(page.hasCompletedTranslation(settings: settings))
        let revised = ReaderTranslationRegion(id: old.id, rect: old.rect, source: old.source, translation: "수정된 번역")
        page.displayPreparedSnapshot(empty ? [] : [revised], settings: settings, memoryOnly: true)
        #expect(!page.isUsingCachedRendering)
        #expect(!page.hasCompletedTranslation(settings: settings))
        #expect(!view.subviews.contains { $0.accessibilityIdentifier == "reader.translation.cachedOverlay" })
    }
}
