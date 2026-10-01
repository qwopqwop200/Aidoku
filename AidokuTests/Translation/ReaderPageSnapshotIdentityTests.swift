import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderPageSnapshotIdentityTests {
    @Test(arguments: ["direct", "preview", "session"])
    func revisedTranslationReplacesCompletedCachedPresentation(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let cache = ReaderTranslationRenderCache(disk: disk)
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 60))
        view.contentMode = .scaleAspectFit
        let source = image(.white)
        view.image = source
        let page = ReaderTranslationPage(imageView: view)
        defer { page.reset() }
        page.sourcePage = Page(sourceId: "snapshot-content", chapterId: "chapter")
        page.renderCache = cache
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let old = ReaderTranslationRegion(id: "same", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.3),
                                          source: "Original", translation: "이전 번역")
        var revised = old
        revised.translation = "수정한 번역"
        let base = ReaderTranslationCacheIdentity.render(page: page.sourcePage!.translationCacheKey, settings: settings,
            imageSize: source.size, viewport: view.bounds.size, scale: view.traitCollection.displayScale,
            aspectFit: true, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
            dark: view.traitCollection.userInterfaceStyle == .dark)
        let oldBitmap = image(.red), newBitmap = image(.blue)
        let session = ReaderTranslationSession(process: { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }, renderCache: cache, availableMemory: { .max })
        defer { session.close() }
        if mode == "session" {
            session.update(items: [.init(page.sourcePage!)], visible: [page], context: "snapshot", processUncachedPages: false)
            session.enable(settings: settings)
        }
        let generation = await disk.currentGeneration()
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for (region, bitmap) in [(old, oldBitmap), (revised, newBitmap)] {
            let displayed = [region].compactMap { $0.cropped(to: unit) }
            let key = ReaderTranslationRenderCache.snapshotKey(renderKey: base, regions: displayed)
            await cache.store(bitmap, key: key, pageIdentity: ReaderTranslationCacheIdentity.translation(page: page.sourcePage!.translationCacheKey, settings: settings),
                              diskGeneration: generation)
        }
        func present(_ region: ReaderTranslationRegion) {
            switch mode {
            case "preview": page.displayPreparedSnapshot([region], settings: settings, memoryOnly: true)
            case "session": session.receivePrepared(page.sourcePage!, regions: [region], settings: settings)
            default: page.displayPrepared([region], settings: settings)
            }
        }
        present(old)
        #expect((view.subviews.first as? UIImageView)?.image === oldBitmap)
        present(revised)
        #expect((view.subviews.first as? UIImageView)?.image === newBitmap)
        #expect(page.regions.first?.translation == revised.translation)
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        }
    }
}
