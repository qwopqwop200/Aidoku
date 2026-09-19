import UIKit

/// Only current/nearby pages retain decoded pixels. Text/layout data has a
/// separate small budget. Only compact layout instructions persist on disk.
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

    deinit { preparations.values.forEach { $0.task.cancel() } }

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
        variants.removeAll()
    }
}
