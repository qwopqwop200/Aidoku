import CoreGraphics
import CryptoKit
import Foundation

/// Owned by one immutable model instance. Retains no output pixels or model.
final class ReaderUpscaleCanonicalReuse: @unchecked Sendable {
    static let maximumHashBytes = 16 * 1_024 * 1_024
    struct Key: Equatable {
        let width: Int
        let height: Int
        let digest: SHA256.Digest
    }
    private final class Entry {
        let key: Key
        weak var image: CGImage?
        init(key: Key, image: CGImage) { self.key = key; self.image = image }
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int
    init(capacity: Int = 8) { self.capacity = max(0, min(8, capacity)) }

    /// Borrow the model's already-allocated canonical buffer. No Data, provider
    /// copy, extra bitmap, or model lifetime extends beyond this call.
    static func key(bytes: UnsafeRawBufferPointer, width: Int, height: Int) -> Key? {
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        let (expected, byteOverflow) = area.multipliedReportingOverflow(by: 4)
        guard !Task.isCancelled, width > 0, height > 0, !overflow, !byteOverflow,
              expected > 0, bytes.count == expected, expected <= maximumHashBytes else { return nil }
        var hash = SHA256()
        hash.update(bufferPointer: bytes)
        return Key(width: width, height: height, digest: hash.finalize())
    }

    func image(for key: Key) -> CGImage? {
        lock.withLock {
            entries.removeAll { $0.image == nil }
            guard let index = entries.firstIndex(where: { $0.key == key }),
                  let image = entries[index].image else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return image
        }
    }

    func store(_ image: CGImage, for key: Key) {
        lock.withLock {
            entries.removeAll { $0.image == nil || $0.key == key }
            guard capacity > 0 else { return }
            entries.append(Entry(key: key, image: image))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
    }

    var liveEntryCount: Int {
        lock.withLock {
            entries.removeAll { $0.image == nil }
            return entries.count
        }
    }
}
