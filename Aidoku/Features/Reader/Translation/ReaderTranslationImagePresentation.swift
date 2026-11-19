import UIKit

/// A source-aspect bitmap, ready to attach together with the original UIImage.
/// The loader retains the original for OCR, dictionary lookup and image export.
@MainActor
struct ReaderTranslationPreparedImage {
    let image: UIImage
    let settings: ReaderTranslationSettings
    /// Set for a cached V2 page bitmap: the V2 cache key it was stored under.
    var v2CacheKey: String? = nil
    var isCurrent: @MainActor () -> Bool = { true }
    var matchesSourceImage: @MainActor (UIImage) -> Bool = { _ in true }

    func isCurrent(for sourceImage: UIImage) -> Bool {
        matchesSourceImage(sourceImage) && isCurrent()
    }
}

typealias ReaderTranslationImagePreparer = @MainActor (UIImage, Page) async throws -> ReaderTranslationPreparedImage?
