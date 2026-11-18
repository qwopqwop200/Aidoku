import UIKit
import CryptoKit

extension UIImage {
    var translationStaticPixels: CGImage? { images == nil ? cgImage : nil }
}

private enum ReaderTranslationSourceObservation {
    static let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
}

extension Page {
    func memoizedTranslationSource(for image: UIImage) -> ReaderTranslationSourceRasterClaim? {
        if let crop = translationSourceRect, crop != ReaderTranslationSplitGeometry.unit {
            return translationSplitSource?.memoizedClaim(for: image, originalKey: translationCacheKey, crop: crop)
        }
        return .memoized(fullProcessedSource: image)
    }

    func observeTranslationSource(for image: UIImage) async -> ReaderTranslationSourceRasterClaim? {
        if let claim = memoizedTranslationSource(for: image) { return claim }
        if let crop = translationSourceRect, crop != ReaderTranslationSplitGeometry.unit {
            return await translationSplitSource?.claim(for: image, originalKey: translationCacheKey, crop: crop)
        }
        guard let pixels = image.cgImage, !Task.isCancelled else { return nil }
        let decodedBytes = UInt64(pixels.bytesPerRow) * UInt64(pixels.height)
        let budget = TranslationImageWorkBudget.shared
        let observation = Task.detached(priority: .utility) {
            // Display already owns these pixels. Do not wait on the decode
            // permit, whose owner may be waiting for this presentation.
            try? await ReaderTranslationSourceObservation.gate.withPermit {
                try Task.checkCancellation()
                try budget.checkHeadroom(decodedBytes: decodedBytes)
                return ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: image)
            }
        }
        return await withTaskCancellationHandler { await observation.value } onCancel: { observation.cancel() }
    }
}

extension ReaderTranslationSourceRasterClaim {
    /// UI-safe lookup of a previously measured *full* processed raster.
    static func memoized(fullProcessedSource image: UIImage) -> Self? {
        ReaderTranslationRenderAsset.sourceDigests.value(for: image).flatMap { Self(processedFullSourceSHA256: $0) }
    }

    /// Call outside MainActor under existing admitted image work. This may
    /// access lazily decoded bytes. A split image cannot attest a full record.
    static func observe(fullProcessedSource image: UIImage) -> Self? {
        ReaderTranslationRenderAsset.digestSource(image).flatMap { Self(processedFullSourceSHA256: $0) }
    }
}

/// The source artwork stays in the image pipeline. Only the settled typography
/// and source-repair patches persist as a native PNG, so reloads avoid layout work.
struct ReaderTranslationRenderAsset: Codable, Equatable, Sendable {
    // Version 3 stores the native transparent overlay, never a WebKit PDF.
    static let currentVersion = 3
    static let maximumContentBytes = 16 * 1_024 * 1_024
    static let maximumEncodedBytes = 24 * 1_024 * 1_024

    let version: Int
    let typography: Data
    /// Native PNG density; a larger viewport must rerender rather than upscale lettering.
    let typographySize: CGSize?
    let layers: ReaderTranslationImageExporter.ExportLayers
    let displayRect: CGRect
    let sourceSize: CGSize
    let regionsDigest: String
    let sourceDigest: String?

    init(typography: Data, layers: ReaderTranslationImageExporter.ExportLayers,
         displayRect: CGRect, sourceSize: CGSize, regions: [ReaderTranslationRegion], sourceDigest: String?,
         typographySize: CGSize? = nil) {
        version = Self.currentVersion
        self.typography = typography
        self.typographySize = typographySize
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
        if let cached = sourceDigests.value(for: image) { return cached }
        guard let digest = computeSourceDigest(image) else { return nil }
        sourceDigests.store(digest, for: image)
        return digest
    }

    /// The hash includes the static CGImage's contents plus the wrapper's scale and orientation.
    static let sourceDigests = ReaderTranslationImageIdentityCache<String>(capacity: 32, matchStaticBacking: true)

    private static func computeSourceDigest(_ image: UIImage) -> String? {
        guard !Task.isCancelled, let pixels = image.translationStaticPixels, let bytes = pixels.dataProvider?.data else { return nil }
        let colorSpace = pixels.colorSpace
        let name = colorSpace?.name.map { $0 as String } ?? ""
        let description = "source-visible-rows-v2,\(pixels.width),\(pixels.height),\(pixels.bitsPerPixel),\(pixels.bitsPerComponent),"
            + "\(pixels.bitmapInfo.rawValue),\(image.scale),\(image.imageOrientation.rawValue),\(colorSpace?.model.rawValue ?? -1),\(name),"
            + "\(pixels.renderingIntent.rawValue),\(pixels.shouldInterpolate)"
        // Decoder allocations may use different strides or uninitialized row
        // padding. Those bytes do not describe the image and must not invalidate
        // a persisted asset after decoding the same page again.
        let rowBytes = (pixels.width * pixels.bitsPerPixel + 7) / 8
        guard rowBytes > 0, rowBytes <= pixels.bytesPerRow,
              CFDataGetLength(bytes) >= (pixels.height - 1) * pixels.bytesPerRow + rowBytes,
              let pointer = CFDataGetBytePtr(bytes) else { return nil }
        defer { withExtendedLifetime(bytes) {} }
        var digest = SHA256()
        digest.update(data: Data(description.utf8))
        if let profile = colorSpace?.copyICCData() { digest.update(data: profile as Data) }
        if let decode = pixels.decode, let colorSpace {
            let values = (0..<(colorSpace.numberOfComponents * 2)).map { String(Double(decode[$0])) }
            digest.update(data: Data(values.joined(separator: ",").utf8))
        }
        for row in 0..<pixels.height {
            guard !Task.isCancelled else { return nil }
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: pointer + row * pixels.bytesPerRow, count: rowBytes))
        }
        guard !Task.isCancelled else { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var byteCost: Int {
        typography.count + layers.masks.reduce(0) { $0 + $1.png.utf8.count + 64 }
            + layers.surfaces.count * 96 + layers.paintBounds.count * 32
            + (layers.sourceRestorations?.count ?? 0) * 32
            + regionsDigest.utf8.count + (sourceDigest?.utf8.count ?? 0) + 256
    }

    var isValid: Bool {
        func validFrame(_ values: [CGFloat]) -> Bool {
            values.count == 4 && values.allSatisfy(\.isFinite) && values[2] > 0 && values[3] > 0
        }
        return version == Self.currentVersion && !typography.isEmpty && !regionsDigest.isEmpty && sourceDigest != nil
            && (typographySize.map { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 } ?? true)
            && byteCost <= Self.maximumContentBytes
            && sourceSize.width.isFinite && sourceSize.height.isFinite && sourceSize.width > 0 && sourceSize.height > 0
            && validFrame([displayRect.minX, displayRect.minY, displayRect.width, displayRect.height])
            && layers.masks.allSatisfy { validFrame($0.frame) && $0.opacity.isFinite && (0...1).contains($0.opacity) }
            && layers.surfaces.allSatisfy {
                validFrame($0.frame) && $0.radius.isFinite && $0.radius >= 0
                    && $0.blur.isFinite && $0.blur >= 0 && $0.saturation.isFinite && $0.saturation >= 0
            }
            && layers.paintBounds.allSatisfy(validFrame)
            && (layers.sourceRestorations?.count ?? 0) <= 1_024
            && (layers.sourceRestorations ?? []).allSatisfy(validFrame)
    }

    func supportsOutputSize(_ size: CGSize) -> Bool {
        guard let typographySize else { return true } // Reference PDF fixtures are resolution independent.
        return typographySize.width >= size.width && typographySize.height >= size.height
    }

    func matches(regions: [ReaderTranslationRegion], sourceSize: CGSize, sourceDigest: String?) -> Bool {
        isValid && self.sourceSize == sourceSize && regionsDigest == Self.digest(regions)
            && sourceDigest != nil && self.sourceDigest == sourceDigest
    }
}

extension ReaderTranslationRenderAsset {
    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    private var isSettledPNG: Bool {
        guard let sourceDigest, ReaderTranslationSourceRasterClaim(processedFullSourceSHA256: sourceDigest) != nil else { return false }
        return isValid && typographySize != nil && typography.starts(with: Self.pngSignature)
            && layers.includesSourcePage == true && layers.validSettledSource(displayRect: displayRect, hasSourcePatches: false)
    }

    /// Preserve the original PNG as binary data; bind its bytes and all replay metadata together.
    func encodeForDisk() -> Data? {
        guard isSettledPNG else { return try? JSONEncoder().encode(self) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard var payload = try? encoder.encode(self) else { return nil }
        let checksum = SHA256.hash(data: payload)
        payload.append(contentsOf: checksum)
        payload.append(ReaderTranslationCacheCodec.settledRenderTrailer)
        return payload
    }

    static func decodeFromDisk(_ data: Data) -> Self? {
        guard data.count <= maximumEncodedBytes else { return nil }
        guard ReaderTranslationCacheCodec.isSettledRenderArchive(data) else {
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        let checksumEnd = data.endIndex - ReaderTranslationCacheCodec.settledRenderTrailer.count
        guard checksumEnd - data.startIndex >= SHA256.Digest.byteCount else { return nil }
        let checksumStart = checksumEnd - SHA256.Digest.byteCount
        let payload = data[..<checksumStart]
        guard SHA256.hash(data: payload).elementsEqual(data[checksumStart..<checksumEnd]),
              let asset = try? PropertyListDecoder().decode(Self.self, from: payload), asset.isSettledPNG else { return nil }
        return asset
    }
}


/// Weak, bounded LRU for recomputable image values. A static raster digest may
/// outlive its first UIImage wrapper while the same CGImage is still in use.
final class ReaderTranslationImageIdentityCache<Value>: @unchecked Sendable {
    private struct Key {
        let object: AnyObject
        let scale: CGFloat
        let orientation: UIImage.Orientation
    }

    private final class Entry {
        weak var object: AnyObject?
        let scale: CGFloat
        let orientation: UIImage.Orientation
        let value: Value

        init(key: Key, value: Value) {
            object = key.object
            scale = key.scale
            orientation = key.orientation
            self.value = value
        }

        func matches(_ key: Key) -> Bool {
            object === key.object && scale == key.scale && orientation == key.orientation
        }
    }

    /// Release wrapper-only entries promptly. Dead raster keys are also pruned on access.
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
            DispatchQueue.global(qos: .utility).async { cache.removeIfExpired(entry) }
        }
    }

    let capacity: Int
    private let matchStaticBacking: Bool
    private let lock = NSLock()
    private var entries: [Entry] = [] // Least recently used first.
    private var warningObserver: NSObjectProtocol?

    init(capacity: Int, matchStaticBacking: Bool = false) {
        self.capacity = max(1, capacity)
        self.matchStaticBacking = matchStaticBacking
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.removeAll() }
    }

    deinit {
        if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.object == nil }
        return entries.count
    }

    private func key(for image: UIImage) -> Key {
        if matchStaticBacking, let pixels = image.translationStaticPixels {
            return Key(object: pixels, scale: image.scale, orientation: image.imageOrientation)
        }
        return Key(object: image, scale: 1, orientation: .up)
    }

    func value(for image: UIImage) -> Value? {
        let key = key(for: image)
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.object == nil }
        guard let index = entries.lastIndex(where: { $0.matches(key) }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.value
    }

    func store(_ value: Value, for image: UIImage) {
        let key = key(for: image)
        let entry = Entry(key: key, value: value)
        lock.lock()
        entries.removeAll { $0.object == nil || $0.matches(key) }
        while entries.count >= capacity { entries.removeFirst() }
        entries.append(entry)
        // Each image carries one sentinel per cache; replacing it releases the
        // previous sentinel, which removes only its own (already replaced) entry.
        objc_setAssociatedObject(image, Unmanaged.passUnretained(self).toOpaque(),
                                 Sentinel(cache: self, entry: entry), .OBJC_ASSOCIATION_RETAIN)
        // Associate under the same lock as replacement: concurrent stores must
        // not attach an older sentinel after a newer entry was inserted.
        lock.unlock()
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    private func removeIfExpired(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        if entry.object == nil { entries.removeAll { $0 === entry } }
    }
}
