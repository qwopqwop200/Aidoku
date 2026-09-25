import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationLoadedMemoryHitTests {
    @Test func loadedCompositeHitDoesNotStartAssetReadOrDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loaded-hit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ReaderTranslationDiskCache(directory: root)
        let decoder = LoadedHitDecodeCounter()
        let cache = ReaderTranslationRenderCache(disk: disk, decodeAsset: { data in
            decoder.increment()
            return try? JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: data)
        })
        let size = CGSize(width: 80, height: 120)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: size, format: format).image {
            UIColor.green.setFill(); $0.fill(CGRect(origin: .zero, size: size))
        }
        // Preseed source digest. Large metadata makes a speculative asset-read
        // race observable independently of source pixel hashing or WebKit work.
        let sourceDigest = try #require(ReaderTranslationRenderAsset.digestSource(source))
        let text = String(repeating: "cached metadata ", count: 32_768)
        let regions = (0..<16).map { index in
            ReaderTranslationRegion(id: "\(index)", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
                source: text, translation: "Cached")
        }
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { $0.beginPage() }
        let asset = ReaderTranslationRenderAsset(typography: pdf,
            layers: .init(masks: [], surfaces: [], paintBounds: []),
            displayRect: CGRect(origin: .zero, size: size), sourceSize: size, regions: regions, sourceDigest: sourceDigest)
        let settings = ReaderTranslationSettings()
        let key = "loaded-hit-\(UUID().uuidString)"
        let pageKey = "loaded-hit-page"
        let identity = ReaderTranslationCacheIdentity.translation(page: pageKey, settings: settings)
        let generation = await disk.currentGeneration(settings: settings)
        await cache.storeRenderAsset(asset, key: key, diskGeneration: generation)
        cache.clearMemory()
        let replayStart = CACurrentMediaTime()
        let cold = try await ReaderTranslationImageExporter.renderLoadedImage(image: source, regions: regions,
            settings: settings, viewport: size, scale: 1, aspectFit: true, dark: false,
            host: nil, cache: cache, key: key, pageIdentity: identity)
        let replayMS = (CACurrentMediaTime() - replayStart) * 1000
        #expect(decoder.count == 1, "Disk replay must still decode exactly one valid asset")
        cache.clearMemory()
        cache.setNearbyPages(pageKeys: [pageKey], settings: settings)
        let bitmapKey = ReaderTranslationRenderCache.loadedImageKey(renderKey: key,
            regionsDigest: ReaderTranslationRenderAsset.digest(regions), sourceDigest: sourceDigest, size: size)
        cache.storeLoadedImage(cold, key: bitmapKey, pageIdentity: identity,
            context: cache.renderAssetStorageContext(settings: settings))
        try #require(cache.cachedImage(for: bitmapKey) === cold)
        decoder.reset()
        var completed = false
        var maximumPending = 0
        let start = CACurrentMediaTime()
        let render = Task { @MainActor in
            defer { completed = true }
            return try await ReaderTranslationImageExporter.renderLoadedImage(image: source, regions: regions,
                settings: settings, viewport: size, scale: 1, aspectFit: true, dark: false,
                host: nil, cache: cache, key: key, pageIdentity: identity)
        }
        while !completed {
            maximumPending = max(maximumPending, cache.pendingAssetReads)
            await Task.yield()
        }
        let hit = try await render.value
        #expect(hit === cold, "RAM hit must return the exact completed bitmap")
        #expect(decoder.count == 0, "RAM hit must not speculatively decode a disk asset")
        #expect(maximumPending == 0, "RAM hit must not even start an asset read")
        print("LOADED_MEMORY_HIT replay_ms=\(replayMS) hit_ms=\((CACurrentMediaTime() - start) * 1000) asset_decodes=\(decoder.count) maximum_pending=\(maximumPending)")
        cache.clearMemory()
    }
}

private final class LoadedHitDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func reset() { lock.lock(); value = 0; lock.unlock() }
}
