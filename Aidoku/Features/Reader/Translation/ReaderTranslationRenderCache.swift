import UIKit

/// Only current/nearby pages retain decoded pixels. Disk stores the compact
/// OCR, translation and layout instructions used to recreate these images.
@MainActor
final class ReaderTranslationRenderCache {
    static let shared = ReaderTranslationRenderCache(disk: .shared)
    let disk: ReaderTranslationDiskCache
    private let images = NSCache<NSString, UIImage>()
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
        images.totalCostLimit = 64 * 1_024 * 1_024
        images.countLimit = 10 // Five pages, up to two crops/viewport variants each.
    }

    deinit { preparations.values.forEach { $0.task.cancel() } }

    func cachedImage(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    func load(_ key: String) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cachedImage(for: key) { return image }
        // A visible page must not wait for a speculative WebKit snapshot (up to
        // 30 seconds). Cancel that preparation and let the caller render live.
        preparations[key]?.task.cancel()
        return nil
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
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        guard cost <= images.totalCostLimit else { return }
        images.setObject(image, forKey: key as NSString, cost: cost)
        var keys = variants[pageIdentity, default: []].filter { $0 != key }
        keys.insert(key, at: 0)
        for obsolete in keys.dropFirst(2) { images.removeObject(forKey: obsolete as NSString) }
        variants[pageIdentity] = Array(keys.prefix(2))
    }

    func shouldKeepImage(for pageIdentity: String) -> Bool {
        nearbyPages?.contains(pageIdentity) ?? true
    }

    func needsImage(for pageIdentity: String) -> Bool {
        shouldKeepImage(for: pageIdentity) && !variants[pageIdentity, default: []].contains { cachedImage(for: $0) != nil }
    }

    func setNearbyPages(pageKeys: [String], settings: ReaderTranslationSettings) {
        nearbyPages = Set(pageKeys.prefix(5).map { ReaderTranslationCacheIdentity.translation(page: $0, settings: settings) })
        for page in Array(variants.keys) where !shouldKeepImage(for: page) {
            for key in variants.removeValue(forKey: page) ?? [] { images.removeObject(forKey: key as NSString) }
        }
    }

    func clearMemory() {
        generation = UUID()
        nearbyPages = [] // Late snapshots cannot refill memory after leaving the reader.
        preparations.values.forEach { $0.task.cancel() }
        preparations.removeAll()
        images.removeAllObjects()
        variants.removeAll()
    }
}
