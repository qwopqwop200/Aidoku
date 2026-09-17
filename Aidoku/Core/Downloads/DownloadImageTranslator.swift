import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Serializes image decoding, OCR and export across source download queues.
/// The saved pixels remain translated without the reader's cache or network.
@MainActor
enum DownloadImageTranslator {
    private static let gate = TranslationImageWorkBudget.shared
    private static let pipelineGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 2)
    private struct Prepared: Sendable {
        let regions: [ReaderTranslationRegion]
        let imageJPEG: Data?
    }

    typealias Processor = @MainActor (UIImage, ReaderTranslationSettings) async throws -> [ReaderTranslationRegion]

    static func translate(_ data: Data, settings: ReaderTranslationSettings) async throws -> Data {
        try await pipelineGate.withPermit(priority: .prefetch) {
            let prepared = try await gate.withPermit(priority: .prefetch,
                decodedBytes: TranslationImageWorkBudget.decodedBytes(in: data)) {
                try await prepare(data, settings: settings)
            }
            // No decoded image crosses the provider wait. Only compact regions
            // and the optional bounded JPEG are retained while another page OCRs.
            let regions = try await ReaderTranslationService.shared.translate(regions: prepared.regions,
                settings: settings, preparedImageJPEG: prepared.imageJPEG, priority: .prefetch)
            guard !regions.isEmpty else { return data }
            return try await translate(data, settings: settings) { _, _ in regions }
        }
    }

    static func translate(_ data: Data, settings: ReaderTranslationSettings, process: @escaping Processor) async throws -> Data {
        let decodedBytes = TranslationImageWorkBudget.decodedBytes(in: data)
        return try await gate.withPermit(priority: .prefetch, decodedBytes: decodedBytes) {
            try await render(data, settings: settings, process: process)
        }
    }

    nonisolated static func fileExtension(for data: Data, fallback: String = "png") -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), let ext = UTType(type as String)?.preferredFilenameExtension else { return fallback }
        return ext
    }

    private nonisolated static func prepare(_ data: Data, settings: ReaderTranslationSettings) async throws -> Prepared {
        guard #available(iOS 18.0, *) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        let image = try decode(data)
        guard let pixels = image.cgImage else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        let recognized = try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration)
        let regions = ReaderTranslationImagePreparation.apply(recognized, image: image, settings: settings)
        let jpeg = try settings.includePageImage ? ReaderTranslationImagePreparation.translationJPEG(image) : nil
        return Prepared(regions: regions, imageJPEG: jpeg)
    }

    private nonisolated static func decode(_ data: Data) throws -> UIImage {
        try Task.checkCancellation()
        guard let decoded = UIImage(data: data) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        return autoreleasepool {
            guard decoded.imageOrientation != .up else { return decoded }
            let format = UIGraphicsImageRendererFormat()
            format.scale = decoded.scale
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: decoded.size, format: format).image { _ in decoded.draw(at: .zero) }
        }
    }

    private static func render(_ data: Data, settings: ReaderTranslationSettings, process: Processor) async throws -> Data {
        guard #available(iOS 18.0, *) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        try Task.checkCancellation()
        // WebKit export needs an active window. Background downloads wait here and
        // remain cancellable instead of saving an untranslated page as a success.
        _ = try await activeHost()
        let image = try decode(data)
        let regions = try await process(image, settings)
        try Task.checkCancellation()
        let output: UIImage
        if ReaderTranslationRegion.overlayItems(regions, imageSize: image.size).isEmpty {
            // No overlay means there are no changed pixels to encode. Preserve
            // the original format, orientation metadata and compressed bytes.
            return data
        } else {
            let currentHost = try await activeHost()
            let viewport = CGSize(width: max(1, currentHost.bounds.width), height: max(1, currentHost.bounds.height))
            output = try await ReaderTranslationImageExporter.render(
                image: image, regions: regions, settings: settings, viewport: viewport, aspectFit: true, host: currentHost, hasImagePermit: true
            )
        }
        try Task.checkCancellation()
        let encoding = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let png = output.pngData() else { throw ReaderTranslationImageExporter.ExportError.renderFailed }
                try Task.checkCancellation()
                return png
            }
        }
        return try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
    }

    private static func activeHost() async throws -> UIView {
        while true {
            try Task.checkCancellation()
            if UIApplication.shared.applicationState == .active,
               let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?.keyWindow,
               let host = window.rootViewController?.view, host.window != nil {
                return host
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
