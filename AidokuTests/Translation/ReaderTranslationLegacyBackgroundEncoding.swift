import UIKit
@testable import Aidoku

/// Test-only source encoding for the frozen web renderer and browser regression fixtures.
extension ReaderTranslationBackgroundImage {
    /// Live and export overlays usually present the same image instance.
    /// Two weakly keyed entries (adjacent webtoon pages encode back to back)
    /// reuse the PNG/base64 encoding without pinning pixels; an entry is
    /// released with its image or on a memory warning.
    static let encodedDataURLs = ReaderTranslationImageIdentityCache<String>(capacity: 2)

    /// The PNG data URL WebKit loads as the page background. Deterministic for
    /// an immutable image, so an identical earlier encoding is reused.
    static func dataURL(for image: UIImage) throws -> String? {
        try Task.checkCancellation()
        if let cached = encodedDataURLs.value(for: image) {
            ReaderTranslationDiagnostics.renderingProfile("profile_background_encoding_hit")
            return cached
        }
        ReaderTranslationDiagnostics.renderingProfile("profile_background_encoding_miss")
        let dataURL: String? = try autoreleasepool {
            let background = try prepare(image)
            let data = background.pngData()
            try Task.checkCancellation()
            return data.map { "data:image/png;base64," + $0.base64EncodedString() }
        }
        if let dataURL { encodedDataURLs.store(dataURL, for: image) }
        return dataURL
    }

    /// A retained encoding needs no image work and must not queue behind a
    /// different page's PNG compression. Misses remain serialized, with a
    /// second lookup in dataURL after admission in case another request filled it.
    static func scheduledDataURL(for image: UIImage, gate: TranslationProviderRequestLimiter) async throws -> String? {
        try Task.checkCancellation()
        if let cached = encodedDataURLs.value(for: image) {
            ReaderTranslationDiagnostics.renderingProfile("profile_background_encoding_hit")
            return cached
        }
        return try await gate.withPermit {
            try Task.checkCancellation()
            ReaderTranslationDiagnostics.record("background_encode_begin")
            defer { ReaderTranslationDiagnostics.record("background_encode_end") }
            return try dataURL(for: image)
        }
    }

}
