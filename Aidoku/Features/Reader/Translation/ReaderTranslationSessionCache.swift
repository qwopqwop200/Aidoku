import CryptoKit
import Foundation

extension Page {
    var translationCacheKey: String {
        if let translationOriginalKey { return translationOriginalKey }
        let settingsKey = ImageProcessingSettingsKey.getProcessorSettingsKey()
        var parts = [sourceId, chapterId, String(index), imageURL ?? "", zipURL ?? "", settingsKey]
        // Sources may choose different image bytes/headers from the same URL
        // using page context. Keep legacy nil/empty-context keys stable, while
        // separating any contextual source request before OCR/cache hydration.
        if let context, !context.isEmpty {
            parts.append("page-context-v1")
            for key in context.keys.sorted() {
                parts.append(key)
                parts.append(context[key] ?? "")
            }
        }
        if imageURL == nil, zipURL == nil, let base64Identity = $base64 {
            parts.append(base64Identity)
        }
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ReaderTranslationRegion {
    func cropped(to crop: CGRect) -> Self? {
        guard crop.width > 0, crop.height > 0, crop.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
        let clipped = rect.intersection(crop)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        var result = Self(id: id, rect: CGRect(
            x: (clipped.minX - crop.minX) / crop.width, y: (clipped.minY - crop.minY) / crop.height,
            width: clipped.width / crop.width, height: clipped.height / crop.height),
            source: source, translation: translation, confidence: confidence,
            sourceImageAspectRatio: sourceImageAspectRatio, translationOrder: translationOrder,
            translationOrderVersion: translationOrderVersion, sourceOrientation: sourceOrientation,
            sourceSingleVerticalColumn: sourceSingleVerticalColumn, translationReuseIdentity: translationReuseIdentity)
        result.polygon = polygon.map { CGPoint(x: ($0.x - crop.minX) / crop.width, y: ($0.y - crop.minY) / crop.height) }
        result.auxiliaryInkRects = auxiliaryInkRects.compactMap { rect in
            let clipped = rect.intersection(crop)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return CGRect(x: (clipped.minX - crop.minX) / crop.width, y: (clipped.minY - crop.minY) / crop.height,
                width: clipped.width / crop.width, height: clipped.height / crop.height)
        }
        result.auxiliaryInkPolygons = auxiliaryInkPolygons.compactMap { polygon in
            guard let first = polygon.first else { return nil }
            let bounds = polygon.dropFirst().reduce(CGRect(origin: first, size: .zero)) { bounds, point in
                CGRect(x: min(bounds.minX, point.x), y: min(bounds.minY, point.y),
                       width: max(bounds.maxX, point.x) - min(bounds.minX, point.x),
                       height: max(bounds.maxY, point.y) - min(bounds.minY, point.y))
            }
            guard bounds.intersects(crop) else { return nil }
            // Match the primary polygon: retain its exact shape, including
            // crossing edges, and let the cropped image canvas clip the paint.
            return polygon.map { CGPoint(x: ($0.x - crop.minX) / crop.width, y: ($0.y - crop.minY) / crop.height) }
        }
        return result
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
        var cost = 128 + key.utf8.count
        var reuseKeys: Set<TranslationCacheKey> = []
        for region in regions {
            cost += 512 + region.id.utf8.count + region.source.utf8.count + (region.translation?.utf8.count ?? 0)
            cost += region.translationOrderVersion?.utf8.count ?? 0
            cost += region.polygon.count * MemoryLayout<CGPoint>.stride
            cost += region.auxiliaryInkRects.count * MemoryLayout<CGRect>.stride
            for polygon in region.auxiliaryInkPolygons {
                cost += 32 + polygon.count * MemoryLayout<CGPoint>.stride
            }
            if let identity = region.translationReuseIdentity {
                cost += identity.segmentID.utf8.count
                // The archive interns the batch identity across its regions.
                // Charge its retained request once, without serializing it on UIKit.
                if reuseKeys.insert(identity.cacheKey).inserted { cost += identity.cacheKey.sessionByteCost }
            }
            guard cost <= Self.byteLimit else { return }
        }
        // Replacing an entry does not consume a second slot or retain the old
        // bytes. Reject before removal so oversized updates preserve valid data.
        guard cost <= Self.byteLimit else { return }
        let existingCost = values[key]?.cost ?? 0
        let projectedCount = values.count + (values[key] == nil ? 1 : 0)
        if !evict, bytes - existingCost + cost > Self.byteLimit || projectedCount > 64 { return }
        remove(key)
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

private extension TranslationCacheKey {
    var sessionByteCost: Int {
        let strings = [imageDigest, sfxPolicy, backgroundPolicy, endpointNamespace, model,
                       credentialAccount, sourceLanguage, targetLanguage, instructions]
        var cost = 512 + strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        cost += segments.reduce(0) { $0 + 64 + $1.id.utf8.count + $1.text.utf8.count + ($1.bounds?.count ?? 0) * 8 }
        cost += context.reduce(0) { $0 + 32 + $1.utf8.count }
        cost += glossary.reduce(0) { $0 + 64 + $1.source.utf8.count + $1.target.utf8.count }
        return cost
    }
}
