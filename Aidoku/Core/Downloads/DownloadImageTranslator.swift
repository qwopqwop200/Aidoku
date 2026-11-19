import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Serializes translated-download page work across source download queues.
/// The saved pixels remain translated without the reader's cache or network.
@MainActor
enum DownloadImageTranslator {
    private static let pipelineGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 2)

    static func translate(_ data: Data, settings: ReaderTranslationSettings) async throws -> Data {
        try await pipelineGate.withPermit(priority: .prefetch) {
            try await translateAdmitted(data, settings: settings)
        }
    }

    static func translate(fileURL: URL, settings: ReaderTranslationSettings) async throws -> Data {
        try await withAdmittedFile(at: fileURL) { data in
            try await translateAdmitted(data, settings: settings)
        }
    }

    /// Waiting downloads own file identities only. Reading/mapping compressed
    /// bytes begins after the same two-pipeline admission used by raw inputs.
    static func withAdmittedFile<Value: Sendable>(
        at url: URL,
        limiter: TranslationProviderRequestLimiter = pipelineGate,
        load: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0, options: .mappedIfSafe) },
        operation: @escaping @MainActor (Data) async throws -> Value
    ) async throws -> Value {
        try await limiter.withPermit(priority: .prefetch) {
            try Task.checkCancellation()
            let reading = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let data = try load(url)
                try Task.checkCancellation()
                return data
            }
            let data = try await withTaskCancellationHandler {
                try await reading.value
            } onCancel: { reading.cancel() }
            try Task.checkCancellation()
            return try await operation(data)
        }
    }

    private static func translateAdmitted(_ data: Data, settings: ReaderTranslationSettings) async throws -> Data {
        guard #available(iOS 18.0, *) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        return try await translateV2(data, settings: settings)
    }

    /// The V2 page pipeline: the rendered page needs no reader host or overlay renderer.
    @available(iOS 18.0, *)
    private nonisolated static func translateV2(_ data: Data, settings: ReaderTranslationSettings) async throws -> Data {
        let image = try await decode(data)
        guard let pixels = image.cgImage else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        let output = try await ReaderTranslationV2Service.shared.translatePage(
            pixels, cacheKey: nil, settings: settings, priority: .prefetch)
        try Task.checkCancellation()
        guard let png = UIImage(cgImage: output.image).pngData() else { throw ReaderTranslationImageExporter.ExportError.renderFailed }
        return png
    }

    nonisolated static func fileExtension(for data: Data, fallback: String = "png") -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), let ext = UTType(type as String)?.preferredFilenameExtension else { return fallback }
        return ext
    }

    /// Downloaded bytes are untrusted: reject pages whose decoded raster can never
    /// fit before any pixels are allocated (the reader loader applies the same budget).
    nonisolated static func admittedDecodedBytes(
        _ data: Data, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) throws -> UInt64 {
        let bytes = TranslationImageWorkBudget.decodedBytes(in: data)
        guard TranslationImageWorkBudget.requiredHeadroom(decodedBytes: bytes) < physicalMemory else {
            throw TranslationImageWorkBudget.AdmissionError.imageTooLarge
        }
        return bytes
    }

    private nonisolated static func decode(_ data: Data) async throws -> UIImage {
        try Task.checkCancellation()
        let bytes = try admittedDecodedBytes(data)
        guard let decoded = UIImage(data: data) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        guard decoded.imageOrientation != .up else { return decoded }
        // The upright redraw allocates a second full raster before the page
        // pipeline's own admission; wait for the same memory headroom first.
        try await TranslationImageWorkBudget.shared.withPermit(priority: .prefetch, decodedBytes: bytes) {}
        try Task.checkCancellation()
        return autoreleasepool {
            guard decoded.imageOrientation != .up else { return decoded }
            let format = UIGraphicsImageRendererFormat()
            format.scale = decoded.scale
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: decoded.size, format: format).image { _ in decoded.draw(at: .zero) }
        }
    }
}
