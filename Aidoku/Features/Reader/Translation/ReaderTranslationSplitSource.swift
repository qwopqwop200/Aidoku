import CryptoKit
import UIKit

/// Proof that a displayed half derives from one exact processed full raster.
/// A page key, crop rectangle, and matching point dimensions are only locators.
final class ReaderTranslationSplitSource: Sendable, Equatable {
    struct Half {
        let image: UIImage
        let crop: CGRect
        let source: ReaderTranslationSplitSource?
    }

    struct Sides {
        let left: Half
        let right: Half
        let originalKey: String?
    }

    struct SealedPNG {
        let data: Data
        let source: ReaderTranslationSplitSource
        let filenameDigest: String
    }

    // The image is immutable; neither a split descriptor nor the attestation
    // has to keep it alive after decoded reader resources have been released.
    private final class WeakImage: @unchecked Sendable {
        weak var image: UIImage?
        init(_ image: UIImage) { self.image = image }
    }

    private final class ClaimSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ReaderTranslationSourceRasterClaim?

        init(_ value: ReaderTranslationSourceRasterClaim?) { self.value = value }

        func read() -> ReaderTranslationSourceRasterClaim? { lock.withLock { value } }
        func store(_ claim: ReaderTranslationSourceRasterClaim?) { lock.withLock { value = claim } }
    }

    private final class FullSource: Sendable {
        // Cap queued raster claims as well as active hashing. The normal split
        // path itself can have two in-flight saves plus two chapter previews.
        private final class QueueBound: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0

            func reserve() -> Bool {
                lock.withLock {
                    guard count < 4 else { return false }
                    count += 1
                    return true
                }
            }

            func release() { lock.withLock { count -= 1 } }
        }

        private static let queue = QueueBound()
        private static let hashGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let key: String
        let slot: ClaimSlot
        let task: Task<Void, Never>?

        init(image: UIImage, key: String) {
            self.key = key
            let prior = ReaderTranslationSourceRasterClaim.memoized(fullProcessedSource: image)
            let result = ClaimSlot(prior)
            slot = result
            guard prior == nil, let pixels = image.cgImage, Self.queue.reserve() else {
                task = nil
                return
            }
            let decodedBytes = UInt64(pixels.bytesPerRow) * UInt64(pixels.height)
            task = Task.detached(priority: .utility) { [result, image] in
                defer { Self.queue.release() }
                try? await Self.hashGate.withPermit {
                    try Task.checkCancellation()
                    // Unlike general OCR admission, this optional claim must
                    // not wait on reclamation or retain a decoded page in a loop.
                    try TranslationImageWorkBudget.shared.checkHeadroom(decodedBytes: decodedBytes)
                    result.store(.observe(fullProcessedSource: image))
                }
            }
        }

        deinit { task?.cancel() }
    }

    private final class StoredSide: @unchecked Sendable {
        let digest: SHA256.Digest
        private let lock = NSLock()
        private weak var decoded: UIImage?

        init(digest: SHA256.Digest) { self.digest = digest }

        func decodeVerified(_ data: Data) -> UIImage? {
            if let existing = lock.withLock({ decoded }) { return existing }
            // Decoding may take time. Keep the main-thread attestation lookup independent.
            guard let image = UIImage(data: data) else { return nil }
            return lock.withLock {
                if let decoded { return decoded }
                decoded = image
                return image
            }
        }

        func contains(_ image: UIImage) -> Bool {
            lock.withLock { decoded === image }
        }
    }

    private enum Binding: Sendable {
        case inline(WeakImage)
        case png(StoredSide)
    }

    private let full: FullSource
    private let crop: CGRect
    private let binding: Binding

    private init(full: FullSource, crop: CGRect, binding: Binding) {
        self.full = full
        self.crop = crop
        self.binding = binding
    }

    static func == (lhs: ReaderTranslationSplitSource, rhs: ReaderTranslationSplitSource) -> Bool {
        lhs === rhs
    }

    /// Produce both cropped images from the object we attest, in one call.
    static func makeSides(from image: UIImage, originalKey: String?) -> Sides? {
        let leftCrop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let rightCrop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        guard let left = ReaderTranslationSplitGeometry.image(image, crop: leftCrop),
              let right = ReaderTranslationSplitGeometry.image(image, crop: rightCrop) else { return nil }
        let full = originalKey.map { FullSource(image: image, key: $0) }
        func half(_ image: UIImage, crop: CGRect) -> Half {
            Half(image: image, crop: crop,
                 source: full.map { ReaderTranslationSplitSource(full: $0, crop: crop, binding: .inline(WeakImage(image))) })
        }
        return Sides(left: half(left, crop: leftCrop), right: half(right, crop: rightCrop), originalKey: originalKey)
    }

    func sealPNG(from image: UIImage) -> SealedPNG? {
        guard case .inline(let expected) = binding, expected.image === image,
              !Task.isCancelled, let data = image.pngData() else { return nil }
        let digest = SHA256.hash(data: data)
        return SealedPNG(data: data,
                         source: ReaderTranslationSplitSource(full: full, crop: crop, binding: .png(StoredSide(digest: digest))),
                         filenameDigest: digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Verify and decode the SAME bytes. On mismatch original pixels may still
    /// display, but they cannot acquire this half's full-image authority.
    func decodeStoredPNG(_ data: Data) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if case .png(let expected) = binding, SHA256.hash(data: data) == expected.digest {
            guard !Task.isCancelled else { return nil }
            return expected.decodeVerified(data)
        }
        return UIImage(data: data)
    }

    private func matches(_ image: UIImage, originalKey: String, crop: CGRect) -> Bool {
        guard crop == self.crop, originalKey == full.key else { return false }
        switch binding {
        case .inline(let expected): return expected.image === image
        case .png(let expected): return expected.contains(image)
        }
    }

    func memoizedClaim(for image: UIImage, originalKey: String, crop: CGRect) -> ReaderTranslationSourceRasterClaim? {
        guard matches(image, originalKey: originalKey, crop: crop) else { return nil }
        return full.slot.read()
    }

    func claim(for image: UIImage, originalKey: String, crop: CGRect) async -> ReaderTranslationSourceRasterClaim? {
        guard !Task.isCancelled, matches(image, originalKey: originalKey, crop: crop) else { return nil }
        await full.task?.value
        guard !Task.isCancelled else { return nil }
        return memoizedClaim(for: image, originalKey: originalKey, crop: crop)
    }
}
