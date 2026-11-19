import AidokuRunner
import ImageIO
import Nuke
import UIKit

/// Image decoding, raw-image processing, archive I/O and source interception
/// stay outside MainActor. URL requests retain the normal reader's auth/context.
actor ReaderTranslationImageLoader {
    private let temporaryStore: ReaderTemporaryPageStore
    private let ownsTemporaryStore: Bool
    private let pipeline: ImagePipeline
    private let downloadAdmission: BulkDownloadAdmission
    private let sourceLookup: @Sendable (String) async -> AidokuRunner.Source?
    init(pipeline: ImagePipeline = .shared, downloadAdmission: BulkDownloadAdmission = .shared,
         temporaryStore: ReaderTemporaryPageStore? = nil,
         sourceLookup: @escaping @Sendable (String) async -> AidokuRunner.Source? = { await SourceManager.shared.source(for: $0) }) {
        self.sourceLookup = sourceLookup
        self.pipeline = pipeline
        self.downloadAdmission = downloadAdmission
        self.temporaryStore = temporaryStore ?? ReaderTemporaryPageStore()
        ownsTemporaryStore = temporaryStore == nil
    }
    deinit {
        if ownsTemporaryStore { Task { [temporaryStore] in await temporaryStore.removeAll() } }
    }

    /// The inline branch precedes URL/archive. When actual processRaw would
    /// run a processor, the supplied object is not already the processed source.
    func alreadyProcessedInlineSource(_ page: Page) async -> UIImage? {
        guard let image = page.image else { return nil }
        return await MainActor.run { Self.inlineProcessorSettingsEnabled ? nil : image }
    }

    @MainActor private static var inlineProcessorSettingsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "Reader.cropBorders") || UserDefaults.standard.bool(forKey: "Reader.downsampleImages")
    }

    func promote(_ handoff: ReaderTranslationImageRequestHandoff) async throws {
        try await handoff.promote(admission: downloadAdmission)
    }

    private func remoteRequest(_ url: URL, page: Page, source: AidokuRunner.Source?) async -> ImageRequest {
        if source == nil, page.sourceId.hasPrefix(TemporarySharedImageSession.sourcePrefix) {
            return await ReaderPageView.imageRequest(url: url, context: page.context, sourceKey: page.sourceId)
        }
        return await ReaderPageView.imageRequest(url: url, context: page.context, source: source)
    }

    /// Uses Nuke's data-only path: no decoding, image processors, or UIImage retention.
    func prefetchData(_ page: Page, priority: ImageRequest.Priority = .veryLow,
                      handoff: ReaderTranslationImageRequestHandoff? = nil) async throws {
        defer { handoff?.finishTransfer() }
        try Task.checkCancellation()
        // Some sources resolve an image URL via an API. Avoid that request when
        // the pipeline cannot retain an original response for the later decode.
        guard pipeline.configuration.dataCache != nil else { return }
        if case .storeEncodedImages = pipeline.configuration.dataCachePolicy { return }
        guard page.image == nil, page.zipURL == nil, page.base64 == nil,
              let address = page.imageURL, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let source = await sourceLookup(page.sourceId)
        let authority = if handoff != nil {
            await ReaderTranslationImageRequestHandoff.Authority.capture(url: url, page: page, source: source)
        } else { nil as ReaderTranslationImageRequestHandoff.Authority? }
        var request = await remoteRequest(url, page: page, source: source)
        try Task.checkCancellation()
        func offerCachedRequest() async {
            // A raw viewer URL may be the source's transient error fallback.
            guard let handoff, let authority, request.urlRequest?.url != url,
                  await ReaderTranslationImageRequestHandoff.Authority.capture(url: url, page: page, source: source) == authority else { return }
            handoff.save(request, authority: authority, source: source)
        }
        if pipeline.cache.cachedImage(for: request, caches: .memory) != nil {
            await offerCachedRequest()
            return
        }
        // Without reusable disk data, warming would just download the page twice.
        guard !request.options.contains(.disableDiskCacheReads),
              !request.options.contains(.disableDiskCacheWrites) else { return }
        // Nuke's data-only path cannot produce an encoded/processed cache entry.
        // Warming under these policies would finish without reusable bytes, then
        // download the same image again when OCR asks for decoded pixels.
        if case .automatic = pipeline.configuration.dataCachePolicy, !request.processors.isEmpty { return }
        // Warming is complete when either reusable disk identity already exists.
        // Do not read and discard the whole compressed image here only to read it
        // again during load(). Eviction between this check and load remains safe:
        // the normal image pipeline fetches missing bytes on demand.
        guard ReaderImageDownloadCache.needsNetwork(request: request, pipeline: pipeline) else {
            await offerCachedRequest()
            return
        }
        request.priority = priority
        let admission = downloadAdmission
        if let handoff {
            try Task.checkCancellation()
            let task = pipeline.loadData(with: request) { _ in }
            try await handoff.startTransfer(task, foreground: priority >= .high, admission: admission)
            _ = try await ReaderTranslationDiagnostics.measure("source_download") { try await task.response }
        } else {
            let demand = if priority >= .high { try await admission.acquireReaderDemand() } else { nil as UUID? }
            defer { if let demand { Task { await admission.releaseReaderDemand(demand) } } }
            try Task.checkCancellation()
            _ = try await ReaderTranslationDiagnostics.measure("source_download") { try await pipeline.data(for: request) }
        }
        try Task.checkCancellation()
        await offerCachedRequest()
    }

    func load(_ page: Page, cacheInMemory: Bool = true, handoff: ReaderTranslationImageRequestHandoff? = nil) async throws -> UIImage {
        return try await ReaderTranslationDiagnostics.measure("source_decode_load") {
            try Task.checkCancellation()
            if let image = page.image { return try await processRaw(image) }
            if let archive = page.zipURL, let url = URL(string: archive), let path = page.imageURL {
                if let source = await temporaryStore.archiveImageSource(from: url, path: path) {
                    return try await loadURL(url, page: page, cacheInMemory: cacheInMemory, archiveSource: source)
                }
                guard let extracted = await temporaryStore.storeArchiveEntry(from: url, path: path) else {
                    throw URLError(.cannotDecodeContentData)
                }
                return try await loadURL(extracted, page: page, cacheInMemory: cacheInMemory)
            }
            if let address = page.imageURL, let url = URL(string: address) {
                return try await loadURL(url, page: page, cacheInMemory: cacheInMemory, handoff: handoff)
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
        return try autoreleasepool {
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

    private func loadURL(_ url: URL, page: Page, cacheInMemory: Bool,
                         archiveSource: ReaderTemporaryPageStore.ArchiveImageSource? = nil,
                         handoff: ReaderTranslationImageRequestHandoff? = nil) async throws -> UIImage {
        try Task.checkCancellation()
        var request: ImageRequest
        if let handoff, !url.isFileURL, archiveSource == nil {
            var source = await sourceLookup(page.sourceId)
            let authority = if handoff.hasPreparedRequest {
                await ReaderTranslationImageRequestHandoff.Authority.capture(url: url, page: page, source: source)
            } else { nil as ReaderTranslationImageRequestHandoff.Authority? }
            if var cached = handoff.take(for: authority, source: source) {
                cached.priority = .low
                if !cacheInMemory { cached.options.insert(.disableMemoryCacheWrites) }
                let image = try? await pipeline.image(for: cached)
                try Task.checkCancellation()
                source = await sourceLookup(page.sourceId)
                if let image, await ReaderTranslationImageRequestHandoff.Authority.capture(url: url, page: page, source: source) == authority {
                    try Task.checkCancellation()
                    return image
                }
            }
            request = await remoteRequest(url, page: page, source: source)
        } else {
            request = await ReaderPageView.imageRequest(url: url, context: page.context, sourceKey: page.sourceId, archiveRequest: archiveSource?.request)
        }
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
        // Distant chapter work may borrow cached reader pixels but must not
        // evict nearby images by filling the memory cache with one-use bitmaps.
        // Original compressed data remains in the bounded disk cache.
        if !cacheInMemory { request.options.insert(.disableMemoryCacheWrites) }
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
