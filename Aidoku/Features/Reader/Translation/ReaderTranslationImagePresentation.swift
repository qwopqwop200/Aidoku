import UIKit

/// A cached translated bitmap, ready to attach together with its source UIImage.
@MainActor
struct ReaderTranslationPreparedImage {
    let image: UIImage
    let settings: ReaderTranslationSettings
    /// Set for a cached pipeline page bitmap: the pipeline cache key it was stored under.
    var pipelineCacheKey: String? = nil
    var isCurrent: @MainActor () -> Bool = { true }
    var matchesSourceImage: @MainActor (UIImage) -> Bool = { _ in true }

    func isCurrent(for sourceImage: UIImage) -> Bool {
        matchesSourceImage(sourceImage) && isCurrent()
    }
}

typealias ReaderTranslationImagePreparer = @MainActor (UIImage, Page) async throws -> ReaderTranslationPreparedImage?
