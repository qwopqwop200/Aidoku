import UIKit
import CryptoKit

/// The source artwork stays in the image pipeline. Only the settled typography
/// and source-repair patches persist, so a reload needs no WebKit document.
struct ReaderTranslationRenderAsset: Codable, Sendable {
    static let currentVersion = 1
    static let maximumContentBytes = 16 * 1_024 * 1_024
    static let maximumEncodedBytes = 24 * 1_024 * 1_024

    let version: Int
    let typography: Data
    let layers: ReaderTranslationImageExporter.ExportLayers
    let displayRect: CGRect
    let sourceSize: CGSize
    let regionsDigest: String
    let sourceDigest: String?

    init(typography: Data, layers: ReaderTranslationImageExporter.ExportLayers,
         displayRect: CGRect, sourceSize: CGSize, regions: [ReaderTranslationRegion], sourceDigest: String?) {
        version = Self.currentVersion
        self.typography = typography
        self.layers = layers
        self.displayRect = displayRect
        self.sourceSize = sourceSize
        regionsDigest = Self.digest(regions)
        self.sourceDigest = sourceDigest
    }

    static func digest(_ regions: [ReaderTranslationRegion]) -> String {
        ReaderTranslationCacheIdentity.encoded(regions.map(ReaderTranslationStoredRegion.init))
    }

    /// Hash existing provider bytes; no PNG/JPEG encoding or redraw is needed.
    /// Call off MainActor, because a provider may lazily decode its source.
    static func digestSource(_ image: UIImage) -> String? {
        guard !Task.isCancelled else { return nil }
        // A UIImage and its CGImage are immutable: a digest per instance is
        // stable, so repeated displays skip copying and hashing every pixel.
        if let cached = sourceDigests.value(for: image) { return cached }
        guard let digest = computeSourceDigest(image) else { return nil }
        sourceDigests.store(digest, for: image)
        return digest
    }

    /// Weakly keyed by image identity; 64-byte values, bounded entry count.
    static let sourceDigests = ReaderTranslationImageIdentityCache<String>(capacity: 32)

    private static func computeSourceDigest(_ image: UIImage) -> String? {
        guard !Task.isCancelled, let pixels = image.cgImage, let bytes = pixels.dataProvider?.data else { return nil }
        let colorSpace = pixels.colorSpace
        let name = colorSpace?.name.map { $0 as String } ?? ""
        let description = "\(pixels.width),\(pixels.height),\(pixels.bytesPerRow),\(pixels.bitsPerPixel),\(pixels.bitsPerComponent),"
            + "\(pixels.bitmapInfo.rawValue),\(image.scale),\(image.imageOrientation.rawValue),\(colorSpace?.model.rawValue ?? -1),\(name)"
        var digest = SHA256()
        digest.update(data: Data(description.utf8))
        if let profile = colorSpace?.copyICCData() { digest.update(data: profile as Data) }
        digest.update(data: bytes as Data)
        guard !Task.isCancelled else { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var byteCost: Int {
        typography.count + layers.masks.reduce(0) { $0 + $1.png.utf8.count + 64 }
            + layers.surfaces.count * 96 + layers.paintBounds.count * 32
            + regionsDigest.utf8.count + (sourceDigest?.utf8.count ?? 0) + 256
    }

    var isValid: Bool {
        func validFrame(_ values: [CGFloat]) -> Bool {
            values.count == 4 && values.allSatisfy(\.isFinite) && values[2] > 0 && values[3] > 0
        }
        return version == Self.currentVersion && !typography.isEmpty && !regionsDigest.isEmpty && sourceDigest != nil
            && byteCost <= Self.maximumContentBytes
            && sourceSize.width.isFinite && sourceSize.height.isFinite && sourceSize.width > 0 && sourceSize.height > 0
            && validFrame([displayRect.minX, displayRect.minY, displayRect.width, displayRect.height])
            && layers.masks.allSatisfy { validFrame($0.frame) && $0.opacity.isFinite && (0...1).contains($0.opacity) }
            && layers.surfaces.allSatisfy {
                validFrame($0.frame) && $0.radius.isFinite && $0.radius >= 0
                    && $0.blur.isFinite && $0.blur >= 0 && $0.saturation.isFinite && $0.saturation >= 0
            }
            && layers.paintBounds.allSatisfy(validFrame)
    }

    func matches(regions: [ReaderTranslationRegion], sourceSize: CGSize, sourceDigest: String?) -> Bool {
        isValid && self.sourceSize == sourceSize && regionsDigest == Self.digest(regions)
            && sourceDigest != nil && self.sourceDigest == sourceDigest
    }
}

/// A tiny, thread-safe cache of values derived from immutable `UIImage`
/// instances. Keys are held weakly and compared by identity; an entry is
/// dropped as soon as its image deallocates, on memory warnings, or when
/// the least-recently-used slot is needed. Values are recomputable, so a
/// miss only costs the original work.
final class ReaderTranslationImageIdentityCache<Value>: @unchecked Sendable {
    private final class Entry {
        weak var image: UIImage?
        let value: Value
        init(image: UIImage, value: Value) {
            self.image = image
            self.value = value
        }
    }

    /// Associated with the keyed image; its release removes the entry.
    private final class Sentinel {
        weak var cache: ReaderTranslationImageIdentityCache?
        weak var entry: Entry?
        init(cache: ReaderTranslationImageIdentityCache, entry: Entry) {
            self.cache = cache
            self.entry = entry
        }
        deinit {
            // An image may deallocate while this cache's lock is held (a weak
            // load inside the lock can be its final release). Remove later.
            guard let cache, let entry else { return }
            DispatchQueue.global(qos: .utility).async { cache.remove(entry) }
        }
    }

    let capacity: Int
    private let lock = NSLock()
    private var entries: [Entry] = [] // Least recently used first.
    private var warningObserver: NSObjectProtocol?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.removeAll() }
    }

    deinit {
        if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.image != nil }.count
    }

    func value(for image: UIImage) -> Value? {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.image == nil }
        guard let index = entries.lastIndex(where: { $0.image === image }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.value
    }

    func store(_ value: Value, for image: UIImage) {
        let entry = Entry(image: image, value: value)
        lock.lock()
        entries.removeAll { $0.image == nil || $0.image === image }
        while entries.count >= capacity { entries.removeFirst() }
        entries.append(entry)
        lock.unlock()
        // Each image carries one sentinel per cache; replacing it releases the
        // previous sentinel, which removes only its own (already replaced) entry.
        objc_setAssociatedObject(image, Unmanaged.passUnretained(self).toOpaque(),
                                 Sentinel(cache: self, entry: entry), .OBJC_ASSOCIATION_RETAIN)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    private func remove(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0 === entry }
    }
}
