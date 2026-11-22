import CryptoKit
import Foundation
import Nuke

/// Content-addressed keys survive launches and cannot alias pages across sources; hashing never decodes pixels.
enum ReaderImageContentIdentity {
    /// File paths can be reused, so match the page revision before Nuke returns old pixels.
    static func localFileRequestIdentity(_ url: URL) async -> String? {
        guard url.isFileURL else { return nil }
        let parts = [url.absoluteString, ReaderLocalPageIdentity.fileRevision(url)]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return "reader-local-pixels-v1-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hitomi rotates routing hosts for the same hash-addressed image: reuse bytes across rotations, keeping request isolation.
    static func applyStableRemoteIdentity(to request: inout ImageRequest, sourceKey: String?) {
        guard var canonical = request.urlRequest, let url = canonical.url,
              let canonicalURL = stableRemoteURL(url, sourceKey: sourceKey) else { return }
        canonical.url = canonicalURL
        if let identity = ImageRequest(urlRequest: canonical).imageID {
            request.imageID = "reader-hitomi-content-v1-" + identity
        }
    }

    /// Shared with OCR/translation lookups; only routing fields of validated Hitomi URLs are removed.
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

/// Caches the base64 content identity so translation lookups never rehash the payload.
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
