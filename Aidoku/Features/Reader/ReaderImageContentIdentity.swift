import CryptoKit
import Foundation
import Nuke

/// Content-addressed keys survive launches and cannot alias pages from different
/// sources that happen to share a chapter ID/index. Hash without decoding pixels
/// or allocating a second full copy of the base64 payload.
enum ReaderImageContentIdentity {
    /// File paths can be reused after a download or local comic replacement.
    /// Match the page revision before Nuke can return pixels for the old file.
    static func localFileRequestIdentity(_ url: URL) async -> String? {
        guard url.isFileURL else { return nil }
        let parts = [url.absoluteString, ReaderLocalPageIdentity.fileRevision(url)]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return "reader-local-pixels-v1-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hitomi rotates routing epochs and shards without changing the hash-addressed
    /// image. Keep transport URLs intact, but reuse bytes across those rotations.
    /// Derive the key through Nuke so headers, method and body remain isolated.
    static func applyStableRemoteIdentity(to request: inout ImageRequest, sourceKey: String?) {
        guard var canonical = request.urlRequest, let url = canonical.url,
              let canonicalURL = stableRemoteURL(url, sourceKey: sourceKey) else { return }
        canonical.url = canonicalURL
        if let identity = ImageRequest(urlRequest: canonical).imageID {
            request.imageID = "reader-hitomi-content-v1-" + identity
        }
    }

    /// Share the same content identity with persistent OCR/translation lookups.
    /// Only routing fields of validated hash-addressed Hitomi URLs may be removed.
    static func stableRemoteURL(_ url: URL, sourceKey: String?) -> URL? {
        guard sourceKey == "multi.hitomi",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.port == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["a1.gold-usergeneratedcontent.net", "a2.gold-usergeneratedcontent.net"].contains(components.host) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let imageID = Int(parts[1]), (0..<4096).contains(imageID) else { return nil }
        let filename = String(parts[2])
        let hash = String(filename.prefix(64))
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
              ["\(hash).avif", "\(hash).webp"].contains(filename),
              Int(String(hash.suffix(1)) + String(hash.suffix(3).prefix(2)), radix: 16) == imageID else { return nil }
        components.host = "a1.gold-usergeneratedcontent.net"
        components.path = "/content/\(filename)"
        return components.url
    }

    static func base64Key(_ base64: String, processorSettingsKey: String) -> String {
        var hasher = SHA256()
        let contiguous = base64.utf8.withContiguousStorageIfAvailable { bytes in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(bytes))
            return true
        }
        if contiguous == nil {
            var chunk = Data()
            chunk.reserveCapacity(64 * 1024)
            for byte in base64.utf8 {
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    hasher.update(data: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "reader-base64-v2-\(digest)-\(processorSettingsKey)"
    }
}

/// A page carries its content identity with its base64 payload so repeated
/// translation-cache lookups never rehash the full encoded image on UIKit.
@propertyWrapper
struct HashedReaderBase64: Hashable, Sendable {
    var wrappedValue: String? {
        didSet { projectedValue = Self.identity(wrappedValue) }
    }
    private(set) var projectedValue: String?

    init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
        projectedValue = Self.identity(wrappedValue)
    }

    private static func identity(_ value: String?) -> String? {
        value.map { ReaderImageContentIdentity.base64Key($0, processorSettingsKey: "") }
    }
}
