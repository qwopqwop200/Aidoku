import UIKit

/// Only current/nearby pages retain decoded pixels. Text/layout data has a
/// separate small budget. Layout instructions and reusable overlay layers persist
/// on disk without another full copy of the source artwork.
@MainActor
final class ReaderTranslationRenderCache {
    static let shared = ReaderTranslationRenderCache(disk: .shared)
    let disk: ReaderTranslationDiskCache
    private struct Bitmap {
        let image: UIImage
        let bytes: Int
        let pageIdentity: String
    }
    nonisolated static let bitmapByteLimit = 32 * 1_024 * 1_024
    private(set) var currentBitmapByteLimit = bitmapByteLimit
    private(set) var nearbyPageCount = 3
    private var nearbyOrder: [String] = []
    private var images: [String: Bitmap] = [:]
    private var imageOrder: [String] = []
    private(set) var bitmapBytes = 0
    nonisolated static let layoutByteLimit = 2 * 1_024 * 1_024
    private var layouts: [String: Data] = [:]
    private var layoutOrder: [String] = []
    private(set) var layoutBytes = 0

    nonisolated static let renderAssetByteLimit = 16 * 1_024 * 1_024
    private var renderAssets: [String: ReaderTranslationRenderAsset] = [:]
    private var renderAssetOrder: [String] = []
    private(set) var renderAssetBytes = 0
    private struct AssetWrite {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var assetWrites: [String: AssetWrite] = [:]

    struct AssetStorageContext {
        fileprivate let generation: UUID
        fileprivate let diskGeneration: Task<UInt64, Never>
    }

    private var generation = UUID()
    private struct Preparation {
        let id = UUID()
        let task: Task<Void, Error>
    }
    private var preparations: [String: Preparation] = [:]
    private var nearbyPages: Set<String>?
    private var variants: [String: [String]] = [:]

    init(disk: ReaderTranslationDiskCache) {
        self.disk = disk
    }

    deinit {
        preparations.values.forEach { $0.task.cancel() }
        assetWrites.values.forEach { $0.task.cancel() }
    }

    func cachedImage(for key: String) -> UIImage? {
        guard let entry = images[key] else { return nil }
        imageOrder.removeAll { $0 == key }
        imageOrder.append(key)
        return entry.image
    }

    func cachedLayout(for key: String) -> Data? {
        guard let data = layouts[key] else { return nil }
        layoutOrder.removeAll { $0 == key }; layoutOrder.append(key)
        return data
    }

    private func retainLayout(_ data: Data, key: String) {
        guard data.count <= Self.layoutByteLimit else { return }
        if let old = layouts.removeValue(forKey: key) { layoutBytes -= old.count }
        layoutOrder.removeAll { $0 == key }
        while layoutBytes + data.count > Self.layoutByteLimit || layouts.count >= 66, let oldest = layoutOrder.first {
            if let old = layouts.removeValue(forKey: oldest) { layoutBytes -= old.count }
            layoutOrder.removeFirst()
        }
        layouts[key] = data; layoutBytes += data.count; layoutOrder.append(key)
    }

    func layoutData(for key: String) async -> Data? {
        if let data = cachedLayout(for: key) { return data }
        let issued = generation
        guard let data = try? await disk.data(for: key, kind: .layout), !Task.isCancelled, generation == issued,
              (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) != nil else { return nil }
        retainLayout(data, key: key)
        return data
    }

    func storeLayout(_ data: Data, key: String, diskGeneration: UInt64) async {
        let issued = generation
        guard !Task.isCancelled, await disk.currentGeneration() == diskGeneration, generation == issued else { return }
        retainLayout(data, key: key)
        try? await disk.store(data, for: key, kind: .layout, generation: diskGeneration)
    }

    /// Layout payloads contain the translated text as well as geometry. A page
    /// retranslated under the same settings must not replay an older payload.
    nonisolated static func layoutKey(renderKey: String, regions: [ReaderTranslationRegion]) -> String {
        ReaderTranslationCacheIdentity.encoded([
            "reader-layout-content-v1", renderKey, ReaderTranslationRenderAsset.digest(regions)
        ])
    }

    /// This namespace shares layout invalidation/eviction, but never goes through
    /// layoutData's JSON-array decoder. Text-only layouts remain independently usable.
    nonisolated static func renderAssetStorageKey(_ key: String) -> String {
        "reader-render-asset-v1-" + key
    }

    private func retainRenderAsset(_ asset: ReaderTranslationRenderAsset, key: String) {
        guard asset.isValid, asset.byteCost <= Self.renderAssetByteLimit else { return }
        removeMemoryRenderAsset(key)
        while renderAssetBytes + asset.byteCost > Self.renderAssetByteLimit || renderAssets.count >= 16,
              let oldest = renderAssetOrder.first {
            removeMemoryRenderAsset(oldest)
        }
        renderAssets[key] = asset
        renderAssetBytes += asset.byteCost
        renderAssetOrder.append(key)
    }

    private func removeMemoryRenderAsset(_ key: String) {
        if let old = renderAssets.removeValue(forKey: key) { renderAssetBytes -= old.byteCost }
        renderAssetOrder.removeAll { $0 == key }
    }

    func renderAsset(for key: String) async -> ReaderTranslationRenderAsset? {
        guard !Task.isCancelled else { return nil }
        if let asset = renderAssets[key] {
            renderAssetOrder.removeAll { $0 == key }; renderAssetOrder.append(key)
            return asset
        }
        let issued = generation
        guard let data = try? await disk.data(for: Self.renderAssetStorageKey(key), kind: .layout),
              data.count <= ReaderTranslationRenderAsset.maximumEncodedBytes,
              !Task.isCancelled, generation == issued else { return nil }
        let decoding = Task.detached(priority: .userInitiated) { () -> ReaderTranslationRenderAsset? in
            guard !Task.isCancelled, let asset = try? JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: data),
                  asset.isValid else { return nil }
            return asset
        }
        let asset = await withTaskCancellationHandler { await decoding.value } onCancel: { decoding.cancel() }
        guard let asset, !Task.isCancelled, generation == issued else { return nil }
        retainRenderAsset(asset, key: key)
        return asset
    }

    func renderAsset(for key: String, regions: [ReaderTranslationRegion], sourceSize: CGSize,
                     sourceDigest: String?) async -> ReaderTranslationRenderAsset? {
        guard let asset = await renderAsset(for: key),
              asset.matches(regions: regions, sourceSize: sourceSize, sourceDigest: sourceDigest) else { return nil }
        return asset
    }

    func removeRenderAsset(for key: String) async {
        assetWrites.removeValue(forKey: key)?.task.cancel()
        removeMemoryRenderAsset(key)
        try? await disk.remove(Self.renderAssetStorageKey(key), kind: .layout)
    }

    /// Capture both lifetimes before rendering; a later clear/settings change
    /// must not authorize a late result to repopulate the cache.
    func renderAssetStorageContext(settings: ReaderTranslationSettings) -> AssetStorageContext {
        AssetStorageContext(generation: generation, diskGeneration: Task { [disk] in
            await disk.currentGeneration(settings: settings)
        })
    }

    nonisolated static func loadedImageKey(renderKey: String, regionsDigest: String, sourceDigest: String, size: CGSize) -> String {
        ReaderTranslationCacheIdentity.encoded([
            "reader-loaded-composite-v1", renderKey, regionsDigest, sourceDigest, ReaderTranslationCacheIdentity.encoded(size)
        ])
    }

    /// Loaded composites share the existing nearby-page bitmap budget. Their
    /// key includes source/content digests; legacy viewport snapshots cannot hit it.
    func storeLoadedImage(_ image: UIImage, key: String, pageIdentity: String, context: AssetStorageContext) {
        guard !Task.isCancelled, generation == context.generation, shouldKeepImage(for: pageIdentity) else { return }
        retain(image, key: key, pageIdentity: pageIdentity)
    }

    /// Optional serialization and disk persistence are bounded background work,
    /// never a display barrier. Both cache generations are checked before retention.
    func storeRenderAssetAfterDisplay(_ asset: ReaderTranslationRenderAsset, key: String, context: AssetStorageContext) {
        guard !Task.isCancelled, generation == context.generation, asset.isValid else { return }
        assetWrites.removeValue(forKey: key)?.task.cancel()
        guard assetWrites.count < 4 else { return }
        let id = UUID()
        let task = Task(priority: .utility) { [weak self] in
            let diskGeneration = await context.diskGeneration.value
            guard let self, !Task.isCancelled, self.generation == context.generation else { return }
            await self.storeRenderAsset(asset, key: key, diskGeneration: diskGeneration)
            if self.assetWrites[key]?.id == id { self.assetWrites.removeValue(forKey: key) }
        }
        assetWrites[key] = AssetWrite(id: id, task: task)
    }

    func storeRenderAsset(_ asset: ReaderTranslationRenderAsset, key: String, diskGeneration: UInt64) async {
        let issued = generation
        guard !Task.isCancelled, asset.isValid, await disk.currentGeneration() == diskGeneration,
              generation == issued else { return }
        let encoding = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled else { return nil }
            return try? JSONEncoder().encode(asset)
        }
        let data = await withTaskCancellationHandler { await encoding.value } onCancel: { encoding.cancel() }
        guard let data, data.count <= ReaderTranslationRenderAsset.maximumEncodedBytes, !Task.isCancelled,
              await disk.currentGeneration() == diskGeneration, generation == issued else { return }
        retainRenderAsset(asset, key: key)
        try? await disk.store(data, for: Self.renderAssetStorageKey(key), kind: .layout, generation: diskGeneration)
    }

    func load(_ key: String, pageIdentity: String? = nil, cancelPreparation: Bool = true) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cachedImage(for: key) { return image }
        if cancelPreparation { preparations[key]?.task.cancel() }
        // Rebuild cold renders from durable text/layout data, without duplicating
        // the source artwork as a multi-megabyte PNG for every rendered variant.
        return nil
    }

    func cancelPreparation(for key: String) {
        preparations[key]?.task.cancel()
    }

    func prepare(_ key: String, operation: @escaping @MainActor () async throws -> Void) async throws {
        if let existing = preparations[key] { try await existing.task.value; return }
        let entry = Preparation(task: Task { try await operation() })
        preparations[key] = entry
        defer {
            if preparations[key]?.id == entry.id { preparations.removeValue(forKey: key) }
        }
        try await withTaskCancellationHandler { try await entry.task.value } onCancel: { entry.task.cancel() }
    }

    func store(_ image: UIImage, key: String, pageIdentity: String, diskGeneration: UInt64) async {
        let issued = generation
        guard !Task.isCancelled, await disk.currentGeneration() == diskGeneration, generation == issued,
              shouldKeepImage(for: pageIdentity) else { return }
        retain(image, key: key, pageIdentity: pageIdentity)
    }

    private func removeImage(_ key: String) {
        if let value = images.removeValue(forKey: key) { bitmapBytes -= value.bytes }
        imageOrder.removeAll { $0 == key }
    }

    private func retain(_ image: UIImage, key: String, pageIdentity: String) {
        guard let pixels = image.cgImage else { return }
        let cost = pixels.bytesPerRow * pixels.height
        guard cost <= currentBitmapByteLimit else { return }
        removeImage(key)
        // Never evict a nearer page just to retain speculative pixels farther away.
        let rank = nearbyOrder.firstIndex(of: pageIdentity) ?? 0
        while bitmapBytes + cost > currentBitmapByteLimit {
            guard let victim = imageOrder.max(by: {
                (nearbyOrder.firstIndex(of: images[$0]?.pageIdentity ?? "") ?? 0)
                    < (nearbyOrder.firstIndex(of: images[$1]?.pageIdentity ?? "") ?? 0)
            }), let entry = images[victim],
            (nearbyOrder.firstIndex(of: entry.pageIdentity) ?? 0) >= rank else { return }
            removeImage(victim)
        }
        images[key] = Bitmap(image: image, bytes: cost, pageIdentity: pageIdentity)
        bitmapBytes += cost
        imageOrder.append(key)
        var keys = variants[pageIdentity, default: []].filter { $0 != key }
        keys.insert(key, at: 0)
        for obsolete in keys.dropFirst(2) { removeImage(obsolete) }
        variants[pageIdentity] = Array(keys.prefix(2))
    }

    func shouldKeepImage(for pageIdentity: String) -> Bool {
        nearbyPages?.contains(pageIdentity) ?? true
    }

    func needsImage(for pageIdentity: String) -> Bool {
        shouldKeepImage(for: pageIdentity) && !variants[pageIdentity, default: []].contains { cachedImage(for: $0) != nil }
    }

    func setNearbyPages(pageKeys: [String], settings: ReaderTranslationSettings,
                        availableMemory: UInt64 = ReaderTranslationSession.processAvailableMemory()) {
        // Reserve OCR/decode headroom and use only a quarter of the excess.
        // Include our existing pixels so allocations do not shrink their own budget.
        let spare = availableMemory > TranslationImageWorkBudget.minimumHeadroom
            ? availableMemory - TranslationImageWorkBudget.minimumHeadroom : 0
        let allowance = min(UInt64(192 * 1_024 * 1_024), spare / 4 + UInt64(bitmapBytes) / 4)
        currentBitmapByteLimit = max(Self.bitmapByteLimit, Int(allowance))
        nearbyPageCount = max(3, min(7, currentBitmapByteLimit / (24 * 1_024 * 1_024)))
        nearbyOrder = pageKeys.prefix(nearbyPageCount).map {
            ReaderTranslationCacheIdentity.translation(page: $0, settings: settings)
        }
        nearbyPages = Set(nearbyOrder)
        for page in Array(variants.keys) where !shouldKeepImage(for: page) {
            for key in variants.removeValue(forKey: page) ?? [] { removeImage(key) }
        }
        // A falling memory budget evicts distant pages first.
        while bitmapBytes > currentBitmapByteLimit,
              let page = nearbyOrder.reversed().first(where: { identity in
                  images.values.contains { $0.pageIdentity == identity }
              }), let key = imageOrder.first(where: { images[$0]?.pageIdentity == page }) {
            removeImage(key)
        }
    }

    func clearMemory() {
        generation = UUID()
        nearbyPages = [] // Late snapshots cannot refill memory after leaving the reader.
        preparations.values.forEach { $0.task.cancel() }
        preparations.removeAll()
        images.removeAll(); imageOrder.removeAll(); bitmapBytes = 0
        layouts.removeAll(); layoutOrder.removeAll(); layoutBytes = 0
        assetWrites.values.forEach { $0.task.cancel() }; assetWrites.removeAll()
        renderAssets.removeAll(); renderAssetOrder.removeAll(); renderAssetBytes = 0
        variants.removeAll()
    }
}
