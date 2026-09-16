import UIKit

/// Serializes image decoding, OCR and export across source download queues.
/// The saved pixels remain translated without the reader's cache or network.
@MainActor
enum DownloadImageTranslator {
    private static let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)

    typealias Processor = @MainActor (UIImage, ReaderTranslationSettings) async throws -> [ReaderTranslationRegion]

    static func translate(_ data: Data, settings: ReaderTranslationSettings) async throws -> Data {
        try await translate(data, settings: settings, process: recognizeAndTranslate)
    }

    static func translate(_ data: Data, settings: ReaderTranslationSettings, process: @escaping Processor) async throws -> Data {
        try await gate.withPermit {
            try await render(data, settings: settings, process: process)
        }
    }

    private static func recognizeAndTranslate(_ image: UIImage, settings: ReaderTranslationSettings) async throws -> [ReaderTranslationRegion] {
        guard #available(iOS 18.0, *), let pixels = image.cgImage else {
            throw ReaderTranslationImageExporter.ExportError.unavailable
        }
        let recognized = try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration)
        let prepared = ReaderTranslationImagePreparation.apply(recognized, image: image, settings: settings)
        return try await ReaderTranslationService.shared.translate(regions: prepared, settings: settings, image: image)
    }

    private static func render(_ data: Data, settings: ReaderTranslationSettings, process: Processor) async throws -> Data {
        guard #available(iOS 18.0, *) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        try Task.checkCancellation()
        // WebKit export needs an active window. Background downloads wait here and
        // remain cancellable instead of saving an untranslated page as a success.
        _ = try await activeHost()
        guard let decoded = UIImage(data: data) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        let image: UIImage = autoreleasepool {
            guard decoded.imageOrientation != .up else { return decoded }
            let format = UIGraphicsImageRendererFormat()
            format.scale = decoded.scale
            return UIGraphicsImageRenderer(size: decoded.size, format: format).image { _ in decoded.draw(at: .zero) }
        }
        let regions = try await process(image, settings)
        try Task.checkCancellation()
        let output: UIImage
        if ReaderTranslationRegion.overlayItems(regions, imageSize: image.size).isEmpty {
            output = image
        } else {
            let currentHost = try await activeHost()
            let viewport = CGSize(width: max(1, currentHost.bounds.width), height: max(1, currentHost.bounds.height))
            output = try await ReaderTranslationImageExporter.render(
                image: image, regions: regions, settings: settings, viewport: viewport, aspectFit: true, host: currentHost
            )
        }
        try Task.checkCancellation()
        guard let png = output.pngData() else { throw ReaderTranslationImageExporter.ExportError.renderFailed }
        return png
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
