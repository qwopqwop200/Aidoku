import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Translates downloaded pages, shared across all source download queues.
@MainActor
enum DownloadImageTranslator {
    private static let pipelineGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 2)

    /// Pages in the pipeline at once: all provider slots but one (kept for the reader), at least 2.
    nonisolated static func pipelineWidth(settings: ReaderTranslationSettings) -> Int {
        max(2, PipelinePerformanceProfile.current.providerConcurrency(setting: settings.maximumConcurrentRequests) - 1)
    }

    /// The reader's cache key for the whole page when the reader decodes the same raster (no image or page
    /// processors, a remote URL or base64 page, not a temporary shared-image session); nil skips the cache.
    nonisolated static func readerCacheKey(
        for page: Page, processesPages: Bool, settings: ReaderTranslationSettings, defaults: UserDefaults = .standard
    ) -> String? {
        guard #available(iOS 18.0, *), !processesPages, page.image == nil, page.zipURL == nil,
              !page.sourceId.hasPrefix(TemporarySharedImageSession.sourcePrefix),
              !["Reader.cropBorders", "Reader.downsampleImages", "Reader.upscaleImages"].contains(where: defaults.bool(forKey:))
        else { return nil }
        if let address = page.imageURL {
            guard let url = URL(string: address), !url.isFileURL else { return nil }
        } else if page.base64 == nil {
            return nil
        }
        return ReaderTranslationPipelineService.cacheKey(page: page.translationCacheKey, crop: ReaderTranslationSplitGeometry.unit,
                                                   settings: settings)
    }

    static func translate(_ data: Data, settings: ReaderTranslationSettings, cacheKey: String? = nil) async throws -> Data {
        await pipelineGate.setMaximumConcurrentRequests(pipelineWidth(settings: settings))
        let output = try await pipelineGate.withPermit(priority: .prefetch) {
            try await translateAdmitted(data, settings: settings, cacheKey: cacheKey)
        }
        return try await encode(output)
    }

    /// Waiting downloads hold only file URLs; bytes are read after admission.
    static func translate(fileURL url: URL, settings: ReaderTranslationSettings, cacheKey: String? = nil) async throws -> Data {
        await pipelineGate.setMaximumConcurrentRequests(pipelineWidth(settings: settings))
        let output = try await pipelineGate.withPermit(priority: .prefetch) {
            try Task.checkCancellation()
            let reading = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                try Task.checkCancellation()
                return data
            }
            let data = try await withTaskCancellationHandler {
                try await reading.value
            } onCancel: { reading.cancel() }
            try Task.checkCancellation()
            return try await translateAdmitted(data, settings: settings, cacheKey: cacheKey)
        }
        return try await encode(output)
    }

    /// With the reader's key, stored translations are replayed without a provider call and new ones are stored.
    private nonisolated static func translateAdmitted(
        _ data: Data, settings: ReaderTranslationSettings, cacheKey: String?
    ) async throws -> CGImage {
        guard #available(iOS 18.0, *) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        // An over-cap page is decoded differently by the reader (Nuke) and here: never share its rows.
        let key = ImagePixelCap.pixelSize(of: data).map { ImagePixelCap.exceeds(width: $0.width, height: $0.height) } == false
            ? cacheKey : nil
        let image = try await decode(data)
        guard let pixels = image.cgImage else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        let output = try await ReaderTranslationPipelineService.shared.translatePage(
            pixels, cacheKey: key, settings: settings, priority: .prefetch, reusesImage: false)
        try Task.checkCancellation()
        return output.image
    }

    /// Runs after the pipeline permit is returned, so the next page overlaps this slow PNG encode.
    private nonisolated static func encode(_ image: CGImage) async throws -> Data {
        try Task.checkCancellation()
        guard let png = autoreleasepool(invoking: { UIImage(cgImage: image).pngData() }) else {
            throw ReaderTranslationImageExporter.ExportError.renderFailed
        }
        return png
    }

    nonisolated static func fileExtension(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), let ext = UTType(type as String)?.preferredFilenameExtension else { return "png" }
        return ext
    }

    /// Rejects pages whose decoded raster can never fit, before allocating pixels.
    nonisolated static func admittedDecodedBytes(
        _ data: Data, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) throws -> UInt64 {
        // `decode` never exceeds the pixel cap (an over-cap page decodes as a bounded thumbnail).
        let bytes = ImagePixelCap.cappedDecodedBytes(TranslationImageWorkBudget.decodedBytes(in: data))
        guard TranslationImageWorkBudget.requiredHeadroom(decodedBytes: bytes) < physicalMemory else {
            throw TranslationImageWorkBudget.AdmissionError.imageTooLarge
        }
        return bytes
    }

    private nonisolated static func decode(_ data: Data) async throws -> UIImage {
        try Task.checkCancellation()
        let bytes = try admittedDecodedBytes(data)
        // Header-checked: above the pixel cap this is an upright ImageIO thumbnail, never a full decode.
        guard let decoded = ImagePixelCap.decodeImage(data) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        guard decoded.imageOrientation != .up else { return decoded }
        // The upright redraw allocates a second raster; wait for memory headroom first.
        try await TranslationImageWorkBudget.shared.withPermit(priority: .prefetch, decodedBytes: bytes) {}
        try Task.checkCancellation()
        return autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = decoded.scale
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: decoded.size, format: format).image { _ in decoded.draw(at: .zero) }
        }
    }
}
