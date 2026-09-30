import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationPreviewInvalidationTests {
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
            diskGeneration: await disk.currentGeneration())
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
