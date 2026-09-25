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

    struct RenderEnvironment: Sendable {
        var currentHost: @MainActor @Sendable () -> UIView?
        var wait: @Sendable () async throws -> Void
        var render: @MainActor @Sendable (UIImage, [ReaderTranslationRegion], ReaderTranslationSettings, UIView) async throws -> UIImage

        static let live = RenderEnvironment(currentHost: {
            guard UIApplication.shared.applicationState == .active,
                  let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })?.keyWindow,
                  let host = window.rootViewController?.view, host.window != nil else { return nil }
            return host
        }, wait: {
            try await Task.sleep(nanoseconds: 250_000_000)
        }, render: { image, regions, settings, host in
            let viewport = CGSize(width: max(1, host.bounds.width), height: max(1, host.bounds.height))
            return try await ReaderTranslationImageExporter.render(image: image, regions: regions, settings: settings,
                viewport: viewport, aspectFit: true, host: host, hasImagePermit: true)
        })
    }

    private enum RenderAttempt: Sendable {
        case finished(Data)
        case waitingForHost([ReaderTranslationRegion]?)
    }

    static func translate(_ data: Data, settings: ReaderTranslationSettings,
                          imageBudget: TranslationImageWorkBudget = gate,
                          environment: RenderEnvironment = .live,
                          process: @escaping Processor) async throws -> Data {
        let decodedBytes = TranslationImageWorkBudget.decodedBytes(in: data)
        var preparedRegions: [ReaderTranslationRegion]?
        while true {
            // Host readiness retains compressed input and compact regions only.
            // It must never reserve the reader's sole decode/OCR image slot.
            _ = try await activeHost(environment: environment)
            let previousRegions = preparedRegions
            let result = try await imageBudget.withPermit(priority: .prefetch, decodedBytes: decodedBytes) {
                try await render(data, settings: settings, preparedRegions: previousRegions,
                                 environment: environment, process: process)
            }
            switch result {
            case .finished(let output): return output
            case .waitingForHost(let regions): preparedRegions = regions
            }
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
        let jpeg = try settings.shouldAttachPageImage ? ReaderTranslationImagePreparation.translationJPEG(image) : nil
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

    private static func render(_ data: Data, settings: ReaderTranslationSettings,
                               preparedRegions: [ReaderTranslationRegion]?, environment: RenderEnvironment,
                               process: Processor) async throws -> RenderAttempt {
        guard #available(iOS 18.0, *) else { throw ReaderTranslationImageExporter.ExportError.unavailable }
        try Task.checkCancellation()
        // Activation may have changed while waiting for admission. Do not decode
        // or wait for a window while holding the permit.
        guard environment.currentHost() != nil else { return .waitingForHost(preparedRegions) }
        let image = try decode(data)
        let regions: [ReaderTranslationRegion]
        if let preparedRegions { regions = preparedRegions }
        else { regions = try await process(image, settings) }
        try Task.checkCancellation()
        let output: UIImage
        if ReaderTranslationRegion.overlayItems(regions, imageSize: image.size).isEmpty {
            // No overlay means there are no changed pixels to encode. Preserve
            // the original format, orientation metadata and compressed bytes.
            return .finished(data)
        } else {
            guard let currentHost = environment.currentHost() else { return .waitingForHost(regions) }
            do {
                output = try await environment.render(image, regions, settings, currentHost)
            } catch ReaderTranslationImageExporter.ExportError.unavailable {
                try Task.checkCancellation()
                // The exporter may have queued behind another WebKit operation.
                // Retry readiness only, preserving the one completed process call.
                guard environment.currentHost() == nil else {
                    throw ReaderTranslationImageExporter.ExportError.unavailable
                }
                return .waitingForHost(regions)
            }
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
        let encoded = try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
        return .finished(encoded)
    }

    private static func activeHost(environment: RenderEnvironment) async throws -> UIView {
        while true {
            try Task.checkCancellation()
            if let host = environment.currentHost() { return host }
            try await environment.wait()
        }
    }
}
