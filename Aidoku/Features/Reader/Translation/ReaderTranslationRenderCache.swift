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
    // Direct callers also suspend during encoding. Track only live operations so
    // removal/replacement invalidates them without retaining per-key tombstones.
    private var assetStores: [String: UUID] = [:]
    private var assetDiskMutations: [String: AssetWrite] = [:]
    var pendingAssetWrites: Int { assetWrites.count }
    private struct AssetRead {
        let id: UUID
        let task: Task<Void, Never>
        let priorities: ReaderAssetReadPriorities
        var consumers: [UUID: CheckedContinuation<ReaderTranslationRenderAsset?, Never>]
    }
    private var assetReads: [String: AssetRead] = [:]
    // Bound admitted reads/decode work to two; both may be speculative.
    // Acquire before disk I/O: queued keys retain no Data.
    private let assetReadGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 2)
    private let decodeAsset: @Sendable (Data) -> ReaderTranslationRenderAsset?
    var pendingAssetReads: Int { assetReads.count }

    private let encodeAsset: @Sendable (ReaderTranslationRenderAsset) -> Data?
    private(set) var activeAssetEncodings = 0
    private struct EncodingWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var encodingWaiters: [EncodingWaiter] = []
    var queuedAssetEncodings: Int { encodingWaiters.count }

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

    init(disk: ReaderTranslationDiskCache,
         encodeAsset: @escaping @Sendable (ReaderTranslationRenderAsset) -> Data? = { try? JSONEncoder().encode($0) },
         decodeAsset: @escaping @Sendable (Data) -> ReaderTranslationRenderAsset? = {
             try? JSONDecoder().decode(ReaderTranslationRenderAsset.self, from: $0)
         }) {
        self.disk = disk
        self.encodeAsset = encodeAsset
        self.decodeAsset = decodeAsset
    }

    deinit {
        preparations.values.forEach { $0.task.cancel() }
        assetWrites.values.forEach { $0.task.cancel() }
        for read in assetReads.values {
            read.task.cancel()
            read.consumers.values.forEach { $0.resume(returning: nil) }
        }
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

    func renderAsset(for key: String, priority: TranslationRequestPriority = .foreground) async -> ReaderTranslationRenderAsset? {
        guard !Task.isCancelled else { return nil }
        if let asset = renderAssets[key] {
            renderAssetOrder.removeAll { $0 == key }; renderAssetOrder.append(key)
            return asset
        }
        let consumer = UUID()
        let result: ReaderTranslationRenderAsset? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if var read = assetReads[key] {
                    read.priorities.set(priority, for: consumer)
                    read.consumers[consumer] = continuation
                    assetReads[key] = read
                    return
                }
                let id = UUID()
                let issued = generation
                let priorities = ReaderAssetReadPriorities()
                priorities.set(priority, for: consumer)
                let promotion = TranslationRequestPromotion(foregroundSource: { priorities.isForeground })
                let task = Task { [weak self, disk, assetReadGate, decodeAsset] in
                    let asset = try? await assetReadGate.withPermit(priority: .promotable(promotion)) {
                        guard !Task.isCancelled,
                              let data = try? await disk.data(for: Self.renderAssetStorageKey(key), kind: .layout,
                                                              maximumBytes: ReaderTranslationRenderAsset.maximumEncodedBytes),
                              data.count <= ReaderTranslationRenderAsset.maximumEncodedBytes,
                              !Task.isCancelled else { return nil as ReaderTranslationRenderAsset? }
                        let decoding = Task.detached(priority: promotion.isForeground ? .userInitiated : .utility) {
                            guard !Task.isCancelled, let asset = decodeAsset(data), asset.isValid,
                                  !Task.isCancelled else { return nil as ReaderTranslationRenderAsset? }
                            return asset
                        }
                        // A synchronous decoder retains its slot until it actually finishes.
                        return await withTaskCancellationHandler { await decoding.value } onCancel: { decoding.cancel() }
                    }
                    guard let self, self.assetReads[key]?.id == id else { return }
                    let read = self.assetReads.removeValue(forKey: key)
                    let result = !Task.isCancelled && self.generation == issued ? asset : nil
                    if let result { self.retainRenderAsset(result, key: key) }
                    read?.consumers.values.forEach { $0.resume(returning: result) }
                }
                assetReads[key] = AssetRead(id: id, task: task, priorities: priorities, consumers: [consumer: continuation])
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAssetRead(key: key, consumer: consumer) }
        }
        return Task.isCancelled ? nil : result
    }

    private func cancelAssetRead(key: String, consumer: UUID? = nil, replacement: ReaderTranslationRenderAsset? = nil) {
        guard var read = assetReads[key] else { return }
        if let consumer {
            read.priorities.remove(consumer)
            read.consumers.removeValue(forKey: consumer)?.resume(returning: nil)
        } else {
            read.priorities.removeAll()
            read.consumers.values.forEach { $0.resume(returning: replacement) }
            read.consumers.removeAll()
        }
        if read.consumers.isEmpty {
            read.task.cancel()
            assetReads.removeValue(forKey: key)
        } else { assetReads[key] = read }
    }

    func renderAsset(for key: String, regions: [ReaderTranslationRegion], sourceSize: CGSize,
                     sourceDigest: String?) async -> ReaderTranslationRenderAsset? {
        guard let asset = await renderAsset(for: key),
              asset.matches(regions: regions, sourceSize: sourceSize, sourceDigest: sourceDigest) else { return nil }
        return asset
    }

    func removeRenderAsset(for key: String) async {
        assetStores.removeValue(forKey: key)
        cancelAssetRead(key: key)
        assetWrites.removeValue(forKey: key)?.task.cancel()
        removeMemoryRenderAsset(key)
        let removal = enqueueAssetDiskMutation(key: key) { [disk] in
            try? await disk.remove(Self.renderAssetStorageKey(key), kind: .layout)
        }
        await removal.value
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
        assetStores[key] = id
        let task = Task(priority: .utility) { [weak self] in
            let diskGeneration = await context.diskGeneration.value
            guard let self else { return }
            defer {
                if self.assetWrites[key]?.id == id { self.assetWrites.removeValue(forKey: key) }
                if self.assetStores[key] == id { self.assetStores.removeValue(forKey: key) }
            }
            guard !Task.isCancelled, self.generation == context.generation, self.assetStores[key] == id else { return }
            await self.storeRenderAsset(asset, key: key, diskGeneration: diskGeneration, issued: context.generation, id: id)
        }
        assetWrites[key] = AssetWrite(id: id, task: task)
    }

    func storeRenderAsset(_ asset: ReaderTranslationRenderAsset, key: String, diskGeneration: UInt64) async {
        let issued = generation
        guard !Task.isCancelled, asset.isValid else { return }
        assetWrites.removeValue(forKey: key)?.task.cancel()
        let id = UUID()
        assetStores[key] = id
        await storeRenderAsset(asset, key: key, diskGeneration: diskGeneration, issued: issued, id: id)
    }

    private func storeRenderAsset(_ asset: ReaderTranslationRenderAsset, key: String, diskGeneration: UInt64,
                                  issued: UUID, id: UUID) async {
        defer { if assetStores[key] == id { assetStores.removeValue(forKey: key) } }
        guard await disk.currentGeneration() == diskGeneration,
              generation == issued, assetStores[key] == id else { return }
        let data = await encodedAsset(asset)
        guard let data, data.count <= ReaderTranslationRenderAsset.maximumEncodedBytes, !Task.isCancelled,
              await disk.currentGeneration() == diskGeneration, generation == issued,
              assetStores[key] == id else { return }
        // A read may already be decoding the previous disk value. It must not
        // overwrite this newer committed value when its decoder returns. Existing
        // consumers can use the replacement without a redundant render on a miss.
        cancelAssetRead(key: key, replacement: asset)
        retainRenderAsset(asset, key: key)
        let write = enqueueAssetDiskMutation(key: key) { [disk] in
            try? await disk.store(data, for: Self.renderAssetStorageKey(key), kind: .layout, generation: diskGeneration)
        }
        await withTaskCancellationHandler { await write.value } onCancel: { write.cancel() }
    }

    // Actor mailboxes need not be FIFO. Chain per-key disk mutations in their
    // MainActor issue order so an earlier delete cannot erase a later store.
    private func enqueueAssetDiskMutation(key: String, operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = assetDiskMutations[key]?.task
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled { await operation() }
            if self?.assetDiskMutations[key]?.id == id { self?.assetDiskMutations.removeValue(forKey: key) }
        }
        assetDiskMutations[key] = AssetWrite(id: id, task: task)
        return task
    }

    private func encodedAsset(_ asset: ReaderTranslationRenderAsset) async -> Data? {
        guard await acquireEncodingSlot() else { return nil }
        // A cancelled synchronous JSON encode still owns its slot until it returns.
        // Key replacement and clearMemory must never reset this lifetime count.
        defer { releaseEncodingSlot() }
        guard !Task.isCancelled else { return nil }
        let encoding = Task.detached(priority: .utility) { [encodeAsset] () -> Data? in
            guard !Task.isCancelled else { return nil }
            return encodeAsset(asset)
        }
        return await withTaskCancellationHandler { await encoding.value } onCancel: { encoding.cancel() }
    }

    private func acquireEncodingSlot() async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeAssetEncodings < 4 {
            activeAssetEncodings += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { encodingWaiters.append(EncodingWaiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.encodingWaiters.firstIndex(where: { $0.id == id }) else { return }
                self.encodingWaiters.remove(at: index).continuation.resume(returning: false)
            }
        }
    }

    private func releaseEncodingSlot() {
        if encodingWaiters.isEmpty { activeAssetEncodings -= 1 }
        else { encodingWaiters.removeFirst().continuation.resume(returning: true) }
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
        for key in Array(assetReads.keys) { cancelAssetRead(key: key) }
        nearbyPages = [] // Late snapshots cannot refill memory after leaving the reader.
        preparations.values.forEach { $0.task.cancel() }
        preparations.removeAll()
        images.removeAll(); imageOrder.removeAll(); bitmapBytes = 0
        layouts.removeAll(); layoutOrder.removeAll(); layoutBytes = 0
        assetWrites.values.forEach { $0.task.cancel() }; assetWrites.removeAll()
        assetStores.removeAll()
        renderAssets.removeAll(); renderAssetOrder.removeAll(); renderAssetBytes = 0
        variants.removeAll()
    }
}

/// Read by the limiter off MainActor; retain only live consumer priorities.
private final class ReaderAssetReadPriorities: @unchecked Sendable {
    private let lock = NSLock()
    private var priorities: [UUID: TranslationRequestPriority] = [:]

    var isForeground: Bool {
        let live = lock.withLock { Array(priorities.values) }
        return live.contains { $0.isForeground }
    }

    func set(_ priority: TranslationRequestPriority, for consumer: UUID) {
        lock.withLock { priorities[consumer] = priority }
    }

    func removeAll() { lock.withLock { priorities.removeAll() } }

    func remove(_ consumer: UUID) {
        _ = lock.withLock { priorities.removeValue(forKey: consumer) }
    }
}
