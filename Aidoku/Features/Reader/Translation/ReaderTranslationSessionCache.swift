import CryptoKit
import Foundation

extension Page {
    var translationCacheKey: String {
        if let translationOriginalKey { return translationOriginalKey }
        let parts = [sourceId, chapterId, String(index), imageURL ?? "", zipURL ?? "", ImageProcessingSettingsKey.getProcessorSettingsKey()]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ReaderTranslationRegion {
    func cropped(to crop: CGRect) -> Self? {
        guard crop.width > 0, crop.height > 0, crop.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
        let clipped = rect.intersection(crop)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return Self(
            id: id,
            rect: CGRect(x: (clipped.minX - crop.minX) / crop.width, y: (clipped.minY - crop.minY) / crop.height,
                         width: clipped.width / crop.width, height: clipped.height / crop.height),
            source: source, translation: translation,
            polygon: polygon.map { CGPoint(x: ($0.x - crop.minX) / crop.width, y: ($0.y - crop.minY) / crop.height) },
            confidence: confidence, sourceOrientation: sourceOrientation, sourceSingleVerticalColumn: sourceSingleVerticalColumn,
            translationReuseIdentity: translationReuseIdentity
        )
    }
}

/// Small session working set. Durable storage belongs to ReaderTranslationDiskCache.
@MainActor
final class ReaderTranslationSessionCache {
    static let byteLimit = 4 * 1_024 * 1_024
    private struct Entry {
        let regions: [ReaderTranslationRegion]
        let cost: Int
    }
    private var values: [String: Entry] = [:]
    private var order: [String] = []
    private(set) var bytes = 0

    func contains(_ key: String) -> Bool { values[key] != nil }
    func store(_ regions: [ReaderTranslationRegion], for key: String, evict: Bool = true) throws {
        let cost = regions.reduce(128 + key.utf8.count) { $0 + $1.source.utf8.count + ($1.translation?.utf8.count ?? 0) + 512 + $1.polygon.count * 16 }
        if !evict, bytes + cost > Self.byteLimit || values.count >= 64 { return }
        remove(key)
        guard cost <= Self.byteLimit else { return }
        while bytes + cost > Self.byteLimit || values.count >= 64, let oldest = order.first { remove(oldest) }
        values[key] = Entry(regions: regions, cost: cost)
        order.append(key)
        bytes += cost
    }
    func regions(for key: String) -> [ReaderTranslationRegion]? {
        guard let entry = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return entry.regions
    }
    func retainPages(_ keys: Set<String>) {
        for key in Array(values.keys) where !keys.contains(key) { remove(key) }
    }
    private func remove(_ key: String) {
        if let entry = values.removeValue(forKey: key) { bytes -= entry.cost }
        order.removeAll { $0 == key }
    }
    func clear() { values.removeAll(); order.removeAll(); bytes = 0 }
}
