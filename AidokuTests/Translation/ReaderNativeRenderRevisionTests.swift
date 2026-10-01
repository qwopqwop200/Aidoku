import Foundation
import SQLite3
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor struct ReaderNativeRenderRevisionTests {
    private let page = "native-live-paint-cache-fixture"
    private let size = CGSize(width: 2, height: 2)
    private var regions: [ReaderTranslationRegion] {
        [.init(id: "one", rect: CGRect(x: 0, y: 0, width: 1, height: 1), source: "原文", translation: "번역")]
    }
    private func keys(_ settings: ReaderTranslationSettings, previousRevision: String) -> (old: String, current: String) {
        let crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        let historical = ReaderTranslationCacheIdentity.encoded([
            previousRevision, ReaderTranslationCacheIdentity.translation(page: page, settings: settings),
            ReaderTranslationCacheIdentity.encoded(settings.overlay), ReaderTranslationCacheIdentity.encoded(size),
            ReaderTranslationCacheIdentity.encoded(size), String(Double(1)), String(true),
            ReaderTranslationCacheIdentity.encoded(crop), String(false),
            "balanced-columns-v15-visible-balloon-fit", "source-rotation-v7-native-balloon-fit",
            "cache-revision-fixture-font", ProcessInfo.processInfo.operatingSystemVersionString
        ])
        return (historical, ReaderTranslationCacheIdentity.render(page: page, settings: settings, imageSize: size,
            viewport: size, scale: 1, aspectFit: true, crop: crop, dark: false, letteringFontKey: "cache-revision-fixture-font"))
    }
    private func settings() -> ReaderTranslationSettings {
        var result = ReaderTranslationSettings()
        result.includePageImage = false
        return result
    }
    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }
    private func plan() throws -> Data {
        try JSONEncoder().encode(NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: []))
    }
    private func asset(_ image: UIImage) throws -> ReaderTranslationRenderAsset {
        let digest: String = try #require(ReaderTranslationRenderAsset.digestSource(image))
        return .init(typography: try #require(image.pngData()), layers: .init(masks: [], surfaces: [], paintBounds: []),
            displayRect: CGRect(origin: .zero, size: size), sourceSize: size, regions: regions,
            sourceDigest: digest, typographySize: size)
    }

    @Test(arguments: ["reader-render-v154-native-composition", "reader-render-v155-native-final-paint",
                      "reader-render-v156-native-live-paint", "reader-render-v157-native-restoration-quality"])
    func completedPreviousRenderBitmapAssetAndPlanCannotSatisfyCurrentReaderKeys(previousRevision: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = self.settings(), keys = self.keys(settings, previousRevision: previousRevision), disk = ReaderTranslationDiskCache(directory: directory)
        try await disk.synchronizeSettings(settings)
        let generation = await disk.currentGeneration(), cache = ReaderTranslationRenderCache(disk: disk)
        let image = self.image(), asset = try self.asset(image), plan = try self.plan()
        let oldSnapshot = ReaderTranslationRenderCache.snapshotKey(renderKey: keys.old, regions: regions)
        let oldPlan = ReaderTranslationRenderCache.layoutKey(renderKey: keys.old, regions: regions)
        let oldLoaded = ReaderTranslationRenderCache.loadedImageKey(renderKey: keys.old, regionsDigest: asset.regionsDigest,
            sourceDigest: try #require(asset.sourceDigest), size: size)
        await cache.store(image, key: oldSnapshot, pageIdentity: page, diskGeneration: generation)
        await cache.storeLayout(plan, key: oldPlan, diskGeneration: generation)
        await cache.storeRenderAsset(asset, key: keys.old, diskGeneration: generation)
        cache.storeLoadedImage(image, key: oldLoaded, pageIdentity: page, context: cache.renderAssetStorageContext(settings: settings))
        // Historical entries are genuine usable native payloads. Only their
        // render namespace changes; neither translation nor asset schema changes.
        #expect(asset.isValid)
        #expect(cache.cachedImage(for: oldSnapshot) === image)
        #expect(cache.cachedImage(for: oldLoaded) === image)
        #expect(await cache.layoutData(for: oldPlan) == plan)
        #expect(await cache.renderAsset(for: keys.old) != nil)
        #expect(keys.old != keys.current)
        #expect(await cache.load(ReaderTranslationRenderCache.snapshotKey(renderKey: keys.current, regions: regions), pageIdentity: page) == nil)
        #expect(await cache.layoutData(for: ReaderTranslationRenderCache.layoutKey(renderKey: keys.current, regions: regions)) == nil)
        #expect(await cache.renderAsset(for: keys.current) == nil)
        #expect(cache.cachedImage(for: ReaderTranslationRenderCache.loadedImageKey(renderKey: keys.current,
            regionsDigest: asset.regionsDigest, sourceDigest: try #require(asset.sourceDigest), size: size)) == nil)
    }

    @Test(arguments: ["reader-render-v154-native-composition", "reader-render-v155-native-final-paint",
                      "reader-render-v156-native-live-paint", "reader-render-v157-native-restoration-quality"])
    func persistedPreviousRenderPolicyRetiresRenderBytesAndLateWritesWhilePreservingOCRTranslationAndMetadata(previousRevision: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = self.settings(), keys = self.keys(settings, previousRevision: previousRevision), disk = ReaderTranslationDiskCache(directory: directory)
        try await disk.synchronizeSettings(settings)
        let generation = await disk.currentGeneration()
        let oldPlan = ReaderTranslationRenderCache.layoutKey(renderKey: keys.old, regions: regions)
        let oldAsset = ReaderTranslationRenderCache.renderAssetStorageKey(keys.old)
        try await disk.store(try plan(), for: oldPlan, kind: .layout, generation: generation)
        try await disk.store(try JSONEncoder().encode(asset(image())), for: oldAsset, kind: .layout, generation: generation)
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .metadata] {
            try await disk.store(Data("durable".utf8), for: "preserved", kind: kind,
                generation: await disk.currentGeneration(kind: kind))
        }
        let historicalPolicy = ReaderTranslationCacheIdentity.encoded([
            previousRevision, ReaderTranslationCacheIdentity.encoded(settings.overlay)
        ])
        var handle: OpaquePointer?
        #expect(sqlite3_open(directory.appendingPathComponent("cache.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "UPDATE cache_policy SET value='\(historicalPolicy)' WHERE name='layout'", nil, nil, nil) == SQLITE_OK)
        let reopened = ReaderTranslationDiskCache(directory: directory)
        try await reopened.synchronizeSettings(settings)
        #expect(try await reopened.data(for: oldPlan, kind: .layout) == nil)
        #expect(try await reopened.data(for: oldAsset, kind: .layout) == nil)
        for kind in [ReaderTranslationDiskCache.Kind.ocr, .translation, .metadata] {
            #expect(try await reopened.data(for: "preserved", kind: kind) == Data("durable".utf8))
        }
        #expect(await reopened.currentGeneration() != generation)
        try await reopened.store(try plan(), for: "late-old-plan", kind: .layout, generation: generation)
        #expect(try await reopened.data(for: "late-old-plan", kind: .layout) == nil)
        let currentGeneration = await reopened.currentGeneration()
        let currentPlan = try plan()
        try await reopened.store(currentPlan, for: "new-plan", kind: .layout, generation: currentGeneration)
        // Compare the actual bytes stored, not a second JSON serialization.
        #expect(try await reopened.data(for: "new-plan", kind: .layout) == currentPlan)
    }
}
