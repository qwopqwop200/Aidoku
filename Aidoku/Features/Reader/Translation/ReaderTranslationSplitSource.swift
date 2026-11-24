import CryptoKit
import UIKit

/// Identity of a displayed half of one wide page raster; keys, crops and sizes are only locators.
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

    private final class WeakImage: @unchecked Sendable {
        weak var image: UIImage?
        init(_ image: UIImage) { self.image = image }
    }

    private final class StoredSide: @unchecked Sendable {
        let digest: SHA256.Digest
        private let lock = NSLock()
        private weak var decoded: UIImage?

        init(digest: SHA256.Digest) { self.digest = digest }

        func decodeVerified(_ data: Data) -> UIImage? {
            if let existing = lock.withLock({ decoded }) { return existing }
            guard let image = UIImage(data: data) else { return nil }
            return lock.withLock {
                if let decoded { return decoded }
                decoded = image
                return image
            }
        }
    }

    private enum Binding: Sendable {
        case inline(WeakImage)
        case png(StoredSide)
    }

    private let binding: Binding

    private init(binding: Binding) {
        self.binding = binding
    }

    static func == (lhs: ReaderTranslationSplitSource, rhs: ReaderTranslationSplitSource) -> Bool {
        lhs === rhs
    }

    static func makeSides(from image: UIImage, originalKey: String?) -> Sides? {
        let leftCrop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let rightCrop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        guard let left = ReaderTranslationSplitGeometry.image(image, crop: leftCrop),
              let right = ReaderTranslationSplitGeometry.image(image, crop: rightCrop) else { return nil }
        func half(_ image: UIImage, crop: CGRect) -> Half {
            Half(image: image, crop: crop,
                 source: originalKey == nil ? nil : ReaderTranslationSplitSource(binding: .inline(WeakImage(image))))
        }
        return Sides(left: half(left, crop: leftCrop), right: half(right, crop: rightCrop), originalKey: originalKey)
    }

    func sealPNG(from image: UIImage) -> SealedPNG? {
        guard case .inline(let expected) = binding, expected.image === image,
              !Task.isCancelled, let data = image.pngData() else { return nil }
        let digest = SHA256.hash(data: data)
        return SealedPNG(data: data,
                         source: ReaderTranslationSplitSource(binding: .png(StoredSide(digest: digest))),
                         filenameDigest: digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Verify and decode the same bytes; a mismatch still displays but loses this half's identity.
    func decodeStoredPNG(_ data: Data) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if case .png(let expected) = binding, SHA256.hash(data: data) == expected.digest {
            guard !Task.isCancelled else { return nil }
            return expected.decodeVerified(data)
        }
        return UIImage(data: data)
    }
}
