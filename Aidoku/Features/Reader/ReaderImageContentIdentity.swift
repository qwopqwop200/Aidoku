import CryptoKit
import Foundation

/// Content-addressed keys survive launches and cannot alias pages from different
/// sources that happen to share a chapter ID/index. Hash without decoding pixels
/// or allocating a second full copy of the base64 payload.
enum ReaderImageContentIdentity {
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
