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
    private final class Regions: NSObject {
        let values: [ReaderTranslationRegion]
        init(_ values: [ReaderTranslationRegion]) { self.values = values }
    }
    private let values = NSCache<NSString, Regions>()

    init() {
        values.totalCostLimit = 16 * 1_024 * 1_024
        values.countLimit = 128 // Empty OCR results also consume keys and wrapper objects.
    }
    func contains(_ key: String) -> Bool { values.object(forKey: key as NSString) != nil }
    func store(_ regions: [ReaderTranslationRegion], for key: String) throws {
        let cost = regions.reduce(128 + key.utf8.count) { $0 + $1.source.utf8.count + ($1.translation?.utf8.count ?? 0) + 512 + $1.polygon.count * 16 }
        values.setObject(Regions(regions), forKey: key as NSString, cost: cost)
    }
    func regions(for key: String) -> [ReaderTranslationRegion]? { values.object(forKey: key as NSString)?.values }
    func clear() { values.removeAllObjects() }
}
