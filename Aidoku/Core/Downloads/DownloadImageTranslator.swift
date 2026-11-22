import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Translates downloaded pages, shared across all source download queues.
@MainActor
enum DownloadImageTranslator {
    private static let pipelineGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 2)

    /// Pages in the V2 pipeline at once: enough to keep all but one provider slot busy (the one
    /// left serves the reader), never fewer than 2. Waiting pages hold no pixels.
    nonisolated static func pipelineWidth(settings: ReaderTranslationSettings) -> Int {
        max(2, V2PerformanceProfile.current.providerConcurrency(setting: settings.maximumConcurrentRequests) - 1)
    }

    static func translate(_ data: Data, settings: ReaderTranslationSettings) async throws -> Data {
        await pipelineGate.setMaximumConcurrentRequests(pipelineWidth(settings: settings))
        let output = try await pipelineGate.withPermit(priority: .prefetch) {
            try await translateAdmitted(data, settings: settings)
        }
        return try await encode(output)
    }

    /// Waiting downloads hold only file URLs; bytes are read after admission.
    static func translate(fileURL url: URL, settings: ReaderTranslationSettings) async throws -> Data {
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
            return try await translateAdmitted(data, settings: settings)
        }
        return try await encode(output)
    }

    /// The V2 page pipeline: the rendered page needs no reader host or overlay renderer.
    private nonisolated static func translateAdmitted(_ data: Data, settings: ReaderTranslationSettings) async throws -> CGImage {
        guard #available(iOS 18.0, *) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        let image = try await decode(data)
        guard let pixels = image.cgImage else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        let output = try await ReaderTranslationV2Service.shared.translatePage(
            pixels, cacheKey: nil, settings: settings, priority: .prefetch)
        try Task.checkCancellation()
        return output.image
    }

    /// The PNG encode (hundreds of ms per page) runs after the pipeline permit is returned,
    /// so the next page's decode and S1-S4 overlap it.
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
