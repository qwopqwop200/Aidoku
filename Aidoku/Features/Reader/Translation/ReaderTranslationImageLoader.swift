import AidokuRunner
import ImageIO
import Nuke
import UIKit

/// Image decoding, raw-image processing, archive I/O and source interception
/// stay outside MainActor. URL requests retain the normal reader's auth/context.
actor ReaderTranslationImageLoader {
    private let temporaryStore: ReaderTemporaryPageStore
    private let pipeline = ImagePipeline.shared
    // One decode at a time: concurrent look-ahead decodes would all pass the same headroom check.
    private let serial = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    init(temporaryStore: ReaderTemporaryPageStore) { self.temporaryStore = temporaryStore }

    func load(_ page: Page) async throws -> UIImage {
        try await serial.withPermit(priority: .prefetch) { try await self.decode(page) }
    }

    private func decode(_ page: Page) async throws -> UIImage {
        try await ReaderTranslationDiagnostics.measure("source_decode_load") {
            try Task.checkCancellation()
            if let image = page.image { return try await processRaw(image) }
            if let archive = page.zipURL, let url = URL(string: archive), let path = page.imageURL {
                if let source = await temporaryStore.archiveImageSource(from: url, path: path) {
                    return try await loadURL(url, page: page, archiveSource: source)
                }
                guard let extracted = await temporaryStore.storeArchiveEntry(from: url, path: path) else {
                    throw URLError(.cannotDecodeContentData)
                }
                return try await loadURL(extracted, page: page)
            }
            if let address = page.imageURL, let url = URL(string: address) {
                return try await loadURL(url, page: page)
            }
            if let base64 = page.base64 {
                guard let data = Data(base64Encoded: base64) else { throw URLError(.cannotDecodeContentData) }
                // Admit and decode by the header: an over-cap page decodes as a bounded thumbnail.
                try TranslationImageWorkBudget.shared.checkHeadroom(
                    decodedBytes: ImagePixelCap.cappedDecodedBytes(TranslationImageWorkBudget.decodedBytes(in: data)))
                guard let image = ImagePixelCap.decodeImage(data) else { throw URLError(.cannotDecodeContentData) }
                return try await processRaw(image)
            }
            throw URLError(.cannotDecodeContentData)
        }
    }

    private func processRaw(_ image: UIImage) async throws -> UIImage {
        let processors: [any ImageProcessing] = await MainActor.run {
            var processors: [any ImageProcessing] = []
            if UserDefaults.standard.bool(forKey: "Reader.cropBorders") { processors.append(CropBordersProcessor()) }
            if UserDefaults.standard.bool(forKey: "Reader.downsampleImages") {
                processors.append(DownsampleProcessor(width: UIScreen.main.bounds.width))
            }
            return processors
        }
        return try Self.apply(processors, to: image)
    }

    static func apply(_ processors: [any ImageProcessing], to image: UIImage) throws -> UIImage {
        try autoreleasepool {
            var result = image
            for processor in processors {
                try Task.checkCancellation()
                result = processor.process(result) ?? result
            }
            try Task.checkCancellation()
            return result
        }
    }

    private static func headerPixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return ImagePixelCap.pixelSize(of: source)
    }

    private func loadURL(_ url: URL, page: Page,
                         archiveSource: ReaderTemporaryPageStore.ArchiveImageSource? = nil) async throws -> UIImage {
        try Task.checkCancellation()
        var request = await ReaderPageView.imageRequest(url: url, context: page.context, sourceKey: page.sourceId, archiveRequest: archiveSource?.request)
        try Task.checkCancellation()
        if url.isFileURL {
            // The complete, unprocessed cached image supplies the same source dimensions.
            if request.processors.isEmpty, let hit = pipeline.cache.cachedImage(for: request, caches: .memory),
               !hit.isPreview, let raster = hit.image.cgImage {
                let bytes = TranslationImageWorkBudget.decodedBytes(width: UInt64(raster.width), height: UInt64(raster.height))
                try TranslationImageWorkBudget.shared.checkHeadroom(decodedBytes: bytes)
                try Task.checkCancellation()
                return hit.image
            }
            let bytes: UInt64
            if let archiveSource {
                try TranslationImageWorkBudget.shared.checkHeadroom(decodedBytes: 0)
                bytes = try await archiveSource.decodedBytes()
            } else {
                bytes = TranslationImageWorkBudget.decodedBytes(at: url)
                // An over-cap file decodes as a bounded thumbnail on any pipeline, not
                // only through the app pipeline's capped decoder (which covers archives).
                if request.thumbnail == nil, let size = Self.headerPixelSize(at: url),
                   let thumbnail = ImagePixelCap.thumbnailOptions(width: size.width, height: size.height) {
                    request.thumbnail = thumbnail
                }
            }
            // The decode never exceeds the pixel cap, so admit the capped size.
            try TranslationImageWorkBudget.shared.checkHeadroom(decodedBytes: ImagePixelCap.cappedDecodedBytes(bytes))
        }
        try Task.checkCancellation()
        request.priority = .low
        let task = pipeline.imageTask(with: request)
        return try await withTaskCancellationHandler {
            do {
                let response = try await task.response
                try Task.checkCancellation()
                return response.image
            } catch {
                try Task.checkCancellation()
                // Preserve sources that produce an image from an otherwise undecodable response.
                if let error = error as? ImagePipeline.Error,
                   let processor = request.processors.first(where: { $0 is PageInterceptorProcessor }) as? PageInterceptorProcessor {
                    switch error {
                    case .dataLoadingFailed, .dataIsEmpty, .decodingFailed:
                        if let result = try? processor.processWithoutImage(request: request) {
                            try Task.checkCancellation()
                            return result.image
                        }
                    default: break
                    }
                }
                throw error
            }
        } onCancel: { task.cancel() }
    }
}
