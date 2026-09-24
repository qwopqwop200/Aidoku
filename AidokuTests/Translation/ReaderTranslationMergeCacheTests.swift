import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationMergeCacheTests {
    @Test(arguments: ["reader-ocr-v56-merged-rotation", "reader-ocr-v52-mixed-orientation-reaction", "reader-ocr-v51-short-staggered-reaction", "reader-ocr-v49-independent-stacked-columns", "reader-ocr-v47-padded-adjacent-columns", "reader-ocr-v46-translucent-balloon-columns", "reader-ocr-v40-han-span-ruby-separator", "reader-ocr-v39-cross-panel-separator", "reader-ocr-v38-sfx-seeds", "reader-ocr-v1", "reader-ocr-v2-regular-spacing", "reader-ocr-v8-whole-page-supplement", "reader-ocr-v9-local-baselines", "reader-ocr-v10-vertical-ruby", "reader-ocr-v11-tile-overlap", "reader-ocr-v12-text-boundaries", "reader-ocr-v13-tile-padding", "reader-ocr-v14-weak-bridge"])
    func oldMergedOCRIsRecomputedOnceAndUpdatedResultsSurviveRestart(previousVersion: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-version-" + UUID().uuidString)
        let suite = "merge-version-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let disk = ReaderTranslationDiskCache(directory: root)
        let page = Page(sourceId: "merge-test", chapterId: "chapter", index: 0, imageURL: "https://example.invalid/page")
        let oldKey = ReaderTranslationCacheIdentity.encoded([
            previousVersion, page.translationCacheKey, ReaderTranslationCacheIdentity.encoded(settings.ocrConfiguration)
        ])
        let old = ReaderTranslationRegion(id: "old", rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), source: "split")
        let joined = ReaderTranslationRegion(id: "joined", rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.4), source: "joined sentence")
        try await disk.storeRegions([old], for: oldKey, kind: .ocr, generation: 0)
        let first = ReaderTranslationPreloader(diskCache: disk, translator: { regions, _, _ in regions }, recognizer: { _, _ in [joined] })
        #expect(try await first.translate(page, settings: settings) == [joined])
        first.cancel()
        let reopened = ReaderTranslationPreloader(diskCache: ReaderTranslationDiskCache(directory: root),
                                                  translator: { regions, _, _ in regions }, recognizer: { _, _ in
            Issue.record("Current merger results must remain reusable after restart")
            return []
        })
        #expect(try await reopened.translate(page, settings: settings) == [joined])
        reopened.cancel()
    }
}
