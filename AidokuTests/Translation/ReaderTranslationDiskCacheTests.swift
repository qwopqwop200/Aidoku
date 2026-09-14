import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct ReaderTranslationDiskCacheTests {
    @Test(arguments: ["reader-render-v3-source-coverage", "reader-render-v4-visible-source-bands", "reader-render-v5-normal-font-floor", "reader-render-v6-korean-balanced-wrap", "reader-render-v7-resolved-font", "reader-render-v8-source-ink", "reader-render-v9-small-text", "reader-render-v9-word-safe-small-text", "reader-render-v10-fragment-line-profile", "reader-render-v11-balloon-contained-type"])
    func earlierLayoutsCannotBeReusedAfterRendererRevision(revision: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let settings = ReaderTranslationSettings()
        let size = CGSize(width: 390, height: 780)
        let crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        let legacyKey = ReaderTranslationCacheIdentity.encoded([
            revision,
            ReaderTranslationCacheIdentity.translation(page: "real-comic", settings: settings),
            ReaderTranslationCacheIdentity.encoded(settings.overlay),
            ReaderTranslationCacheIdentity.encoded(size), ReaderTranslationCacheIdentity.encoded(size),
            String(Double(3)), String(true), ReaderTranslationCacheIdentity.encoded(crop), String(false),
            ProcessInfo.processInfo.operatingSystemVersionString
        ])
        try await cache.store(Data("[{\"x\":-205}]".utf8), for: legacyKey, kind: .layout, generation: 0)
        let currentKey = ReaderTranslationCacheIdentity.render(page: "real-comic", settings: settings,
            imageSize: size, viewport: size, scale: 3, aspectFit: true, crop: crop, dark: false)
        #expect(currentKey != legacyKey)
        #expect(try await cache.data(for: legacyKey, kind: .layout) != nil)
        #expect(try await cache.data(for: currentKey, kind: .layout) == nil)
    }

    @Test func earlierMergedRubyRegionsCannotBeReused() {
        let settings = ReaderTranslationSettings()
        let oldKey = ReaderTranslationCacheIdentity.encoded([
            "reader-ocr-v15-image-separators", "page", ReaderTranslationCacheIdentity.encoded(settings.ocrConfiguration)
        ])
        #expect(oldKey != ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings))
    }

    @Test func durableRegionsSurviveANewCacheInstanceAndPreserveGeometry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let regions = [ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2), source: "hello",
                                               translation: "안녕", polygon: [CGPoint(x: 0.1, y: 0.2)], confidence: 0.98,
                                               sourceOrientation: .vertical, sourceSingleVerticalColumn: true)]
        try await cache.storeRegions(regions, for: "book/chapter/page", kind: .translation, generation: 0)
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: "book/chapter/page", kind: .translation) == regions)
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func recentlyUsedEntriesSurviveEvictionAcrossRestart() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root, byteLimit: 300)
        for key in ["first", "second", "third"] {
            try await cache.store(Data(repeating: 1, count: 100), for: key, kind: .layout, generation: 0)
        }
        _ = try await cache.data(for: "first", kind: .layout)
        let reopened = ReaderTranslationDiskCache(directory: root, byteLimit: 300)
        try await reopened.store(Data(repeating: 2, count: 100), for: "fourth", kind: .ocr, generation: 0)
        #expect(try await reopened.data(for: "second", kind: .layout) == nil)
        #expect(try await reopened.data(for: "first", kind: .layout) != nil)
        #expect(try await reopened.statistics().bytes == 300)
        try await reopened.setByteLimit(100)
        #expect(try await reopened.statistics().bytes == 100)
        #expect(try await reopened.data(for: "first", kind: .layout) != nil)
    }

    @Test(arguments: [false, true])
    func shrinkingLimitEvictsLeastRecentlyUsedAcrossKinds(reopen: Bool) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ReaderTranslationDiskCache(directory: root, byteLimit: 1_000)
        try await original.store(Data(repeating: 1, count: 100), for: "ocr", kind: .ocr, generation: 0)
        try await original.store(Data(repeating: 2, count: 150), for: "translation", kind: .translation, generation: 0)
        try await original.store(Data(repeating: 3, count: 200), for: "layout", kind: .layout, generation: 0)
        // A memory-cache hit must also protect its backing disk entry.
        try await original.markUsed("ocr", kind: .ocr)
        let cache = reopen ? ReaderTranslationDiskCache(directory: root, byteLimit: 1_000) : original
        try await cache.setByteLimit(350)
        #expect(try await cache.statistics().bytes == 300)
        #expect(try await cache.contains("translation", kind: .translation) == false)
        #expect(try await cache.contains("layout", kind: .layout))
        #expect(try await cache.contains("ocr", kind: .ocr))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
        try await cache.setByteLimit(150)
        #expect(try await cache.statistics().bytes == 100)
        #expect(try await cache.contains("layout", kind: .layout) == false)
        #expect(try await cache.contains("ocr", kind: .ocr))
        try await cache.setByteLimit(100_000_000_000)
        #expect(try await cache.statistics().limit == 100_000_000_000)
        #expect(try await cache.statistics().bytes == 100)
        try await cache.setByteLimit(0)
        #expect(try await cache.statistics().entries == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func clearingRejectsOldWritersAndOversizedFilesDoNotExceedQuota() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root, byteLimit: 100)
        let oldGeneration = await cache.currentGeneration()
        try await cache.store(Data(repeating: 1, count: 150), for: "too-large", kind: .layout, generation: oldGeneration)
        #expect(try await cache.statistics().bytes == 0)
        try await cache.clear()
        try await cache.store(Data(repeating: 1, count: 50), for: "late", kind: .layout, generation: oldGeneration)
        #expect(try await cache.statistics().entries == 0)
        let current = await cache.currentGeneration()
        try await cache.store(Data(repeating: 1, count: 50), for: "new", kind: .layout, generation: current)
        #expect(try await cache.statistics().bytes == 50)
        try await cache.setByteLimit(200_000_000_000)
        #expect(try await cache.statistics().limit == 100_000_000_000)
    }

    @Test func translationSettingsAndRenderGeometryHaveSeparateIdentities() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = ReaderTranslationSettings(defaults: defaults)
        let key = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        let ocrKey = ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings)
        for change in 0..<5 {
            var changed = settings
            switch change {
            case 0: changed.targetLanguage = "en"
            case 1: changed.model = "different-model"
            case 2: changed.reasoningEffort = .high
            case 3: changed.instructions = "different prompt"
            default: changed.credentialGeneration += 1
            }
            #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: changed) != key)
            #expect(ReaderTranslationCacheIdentity.ocr(page: "page", settings: changed) == ocrKey)
        }
        var changed = settings
        changed.overlay.opacity = 0.5
        changed.cacheLimitBytes = 10_000_000_000
        #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: changed) == key)
        changed.ocr.detectorMaximumSide = 800
        #expect(ReaderTranslationCacheIdentity.ocr(page: "page", settings: changed) != ocrKey)
        func render(_ settings: ReaderTranslationSettings, width: CGFloat = 390, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> String {
            ReaderTranslationCacheIdentity.render(page: "page", settings: settings, imageSize: CGSize(width: 600, height: 800),
                                                  viewport: CGSize(width: width, height: 800), scale: 3, aspectFit: true, crop: crop, dark: false)
        }
        #expect(render(settings) != render(settings, width: 430))
        #expect(render(settings) != render(settings, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        #expect(render(settings) != render(changed))
    }

    @Test func corruptRegionsAreDiscardedWithoutPoisoningFutureWrites() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        try await cache.store(Data("invalid json".utf8), for: "corrupt", kind: .ocr, generation: 0)
        #expect(try await cache.regions(for: "corrupt", kind: .ocr) == nil)
        #expect(try await cache.statistics().entries == 0)
        try await cache.storeRegions([], for: "corrupt", kind: .ocr, generation: 0)
        #expect(try await cache.regions(for: "corrupt", kind: .ocr)?.isEmpty == true)
    }

    @Test func legacyJSONCompactsWithoutLosingTextOrGeometry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let regions = (0..<30).map { index in
            ReaderTranslationRegion(id: String(index), rect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1),
                                    source: String(repeating: "Long repeated OCR text ", count: 20), translation: "압축 뒤에도 그대로 유지되는 번역")
        }
        let raw = try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
        let url = root.appendingPathComponent("translation-" + ReaderTranslationCacheIdentity.digest("legacy") + ".cache")
        try raw.write(to: url)
        let cache = ReaderTranslationDiskCache(directory: root)
        #expect(try await cache.regions(for: "legacy", kind: .translation) == regions)
        try await cache.compact()
        #expect(try await cache.statistics().bytes < Int64(raw.count / 4))
        #expect(ReaderTranslationCacheCodec.isPacked(try Data(contentsOf: url)))
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.regions(for: "legacy", kind: .translation) == regions)
        try await reopened.store(Data("ATZ1invalid".utf8), for: "broken", kind: .layout, generation: 0)
        #expect(try await reopened.data(for: "broken", kind: .layout) == nil)
    }

    @Test @MainActor func renderedVariantsStayOnlyInMemoryAndKeepDurableLayouts() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let render = ReaderTranslationRenderCache(disk: disk)
        let image = ReaderTranslationPersistentPipelineTests.image()
        for index in 0..<5 {
            try await disk.store(Data("[]".utf8), for: String(index), kind: .layout, generation: 0)
            await render.store(image, key: String(index), pageIdentity: "page", diskGeneration: 0)
        }
        for index in 0..<3 { #expect(render.cachedImage(for: String(index)) == nil) }
        #expect(render.cachedImage(for: "4") != nil)
        #expect(render.cachedImage(for: "3") != nil)
        #expect(try await disk.statistics().bytes == 10)
        #expect(try await disk.statistics().entries == 5)
        let reopened = ReaderTranslationRenderCache(disk: ReaderTranslationDiskCache(directory: root))
        #expect(await reopened.load("4") == nil)
        for index in 0..<5 { #expect(try await disk.data(for: String(index), kind: .layout) != nil) }
    }

    @Test @MainActor func preparingFarPagesKeepsOnlyNeighborsInMemory() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let render = ReaderTranslationRenderCache(disk: disk)
        let settings = ReaderTranslationSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        render.setNearbyPages(pageKeys: ["near"], settings: settings)
        let near = ReaderTranslationCacheIdentity.translation(page: "near", settings: settings)
        let far = ReaderTranslationCacheIdentity.translation(page: "far", settings: settings)
        let image = ReaderTranslationPersistentPipelineTests.image()
        await render.store(image, key: "near-render", pageIdentity: near, diskGeneration: 0)
        await render.store(image, key: "far-render", pageIdentity: far, diskGeneration: 0)
        #expect(render.cachedImage(for: "near-render") != nil)
        #expect(render.cachedImage(for: "far-render") == nil)
        #expect(try await disk.statistics().bytes == 0)
        render.setNearbyPages(pageKeys: ["far"], settings: settings)
        #expect(await render.load("far-render") == nil)
        #expect(render.needsImage(for: far))
        #expect(render.cachedImage(for: "near-render") == nil)
        await render.store(image, key: "far-render", pageIdentity: far, diskGeneration: 0)
        #expect(render.cachedImage(for: "far-render") != nil)
        render.clearMemory()
        await render.store(image, key: "late-render", pageIdentity: far, diskGeneration: 0)
        #expect(render.cachedImage(for: "far-render") == nil)
        #expect(render.cachedImage(for: "late-render") == nil)
    }

    @Test func migrationRemovesOnlyLegacyImagesBeforeEnforcingTheMetadataQuota() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        let regions = [ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                               source: "hello", translation: "안녕")]
        try await cache.storeRegions(regions, for: "page", kind: .ocr, generation: 0)
        try await cache.storeRegions(regions, for: "page", kind: .translation, generation: 0)
        try await cache.store(Data("[{\"x\":1}]".utf8), for: "page", kind: .layout, generation: 0)
        let size = try await cache.statistics().bytes
        for name in ["render-old.cache", "renderIndex-old.cache"] {
            try Data(repeating: 7, count: 1_000_000).write(to: root.appendingPathComponent(name))
        }
        let unrelated = root.appendingPathComponent("unrelated.cache")
        try Data("leave me alone".utf8).write(to: unrelated)
        let reopened = ReaderTranslationDiskCache(directory: root, byteLimit: size)
        try await reopened.compact()
        #expect(try await reopened.statistics().bytes == size)
        #expect(try await reopened.regions(for: "page", kind: .ocr) == regions)
        #expect(try await reopened.regions(for: "page", kind: .translation) == regions)
        #expect(try await reopened.data(for: "page", kind: .layout) == Data("[{\"x\":1}]".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("render-old.cache").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("renderIndex-old.cache").path))
        #expect(try Data(contentsOf: unrelated) == Data("leave me alone".utf8))
        #expect(try await ReaderTranslationDiskCache(directory: root).statistics().bytes == size)
    }

    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("translation-cache-test-" + UUID().uuidString) }
}
