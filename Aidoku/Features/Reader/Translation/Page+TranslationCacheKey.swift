import CryptoKit
import Foundation

/// The stable page identity behind V2 cache keys and look-ahead bookkeeping.
extension Page {
    var translationCacheKey: String {
        if let translationOriginalKey { return translationOriginalKey }
        let settingsKey = ImageProcessingSettingsKey.getProcessorSettingsKey()
        let imageIdentity = imageContentIdentity ?? imageURL.flatMap { URL(string: $0) }
            .flatMap { ReaderImageContentIdentity.stableRemoteURL($0, sourceKey: sourceId) }?.absoluteString ?? imageURL ?? ""
        var parts = [sourceId, chapterId, String(index), imageIdentity, zipURL ?? "", settingsKey]
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
