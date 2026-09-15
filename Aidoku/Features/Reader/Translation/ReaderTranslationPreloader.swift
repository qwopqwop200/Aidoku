import Nuke
import UIKit

struct ReaderTranslationOCRFallback: Error {
    let regions: [ReaderTranslationRegion]
    let underlying: Error
}

/// Prepares a demand page and at most one following page without reader views.
/// OCR remains serial; spare provider capacity can translate the following page.
@MainActor
final class ReaderTranslationPreloader {
    typealias Recognizer = @Sendable (Page, ReaderTranslationSettings) async throws -> [ReaderTranslationRegion]
    private struct PreparedPage {
        let key: String
        let pageKey: String
        let recognition: Task<[ReaderTranslationRegion]?, Error>
        let progress: ReaderTranslationPreparedProgress
        let promotion: TranslationRequestPromotion
        var translation: Task<[ReaderTranslationRegion]?, Error>?

        func cancel() { recognition.cancel(); translation?.cancel() }
    }
    /// Cancellation belongs to the consumer until navigation hands its work to
    /// the next consumer. Old cancellation handlers must not kill adopted work.
    private final class DemandLease: @unchecked Sendable {
        private let lock = NSLock()
        private var retained = false
        private let cancelWork: @Sendable () -> Void

        init(_ work: PreparedPage) { cancelWork = { work.cancel() } }
        var isRetained: Bool { lock.withLock { retained } }
        func retain() { lock.withLock { retained = true } }
        func cancel() { lock.withLock { if !retained { cancelWork() } } }
    }

    // Acquire before decoding, not after images have accumulated waiting for OCR.
    private static let imagePreparationGate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private let loader = ReaderTranslationImageLoader()
    private let translator: ReaderTranslationPage.ProgressiveTranslator?
    private let recognizer: Recognizer?
    private let diskCache: ReaderTranslationDiskCache?
    private var operation: Task<[ReaderTranslationRegion], Error>?
    private var preparedPage: PreparedPage?
    private var currentDemand: (work: PreparedPage, lease: DemandLease)?
    private var generation = UUID()
    var nextPage: ((Page) -> Page?)?

    init(
        diskCache: ReaderTranslationDiskCache? = nil,
        translator: ReaderTranslationPage.ProgressiveTranslator? = nil,
        recognizer: Recognizer? = nil
    ) {
        self.translator = translator
        self.diskCache = diskCache
        self.recognizer = recognizer
    }

    deinit { operation?.cancel(); preparedPage?.cancel() }

    func translate(
        _ page: Page, settings: ReaderTranslationSettings, onProgress: ReaderTranslationService.Progress? = nil
    ) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        operation?.cancel()
        generation = UUID()
        let issued = generation
        let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
        var work: PreparedPage
        if let preparedPage, preparedPage.key == key {
            work = preparedPage
            self.preparedPage = nil
        } else {
            preparedPage?.cancel()
            preparedPage = nil
            work = makeWork(page, settings: settings, speculative: false)
        }
        work.promotion.promote()
        if work.translation == nil {
            work.translation = translationTask(work, page: page, settings: settings, speculative: false)
        }
        let demand = work
        let lease = DemandLease(demand)
        currentDemand = (demand, lease)
        let task = Task { [weak self] in
            try await demand.progress.observe { [weak lease] regions in
                guard let lease, !lease.isRetained else { return }
                do { try await onProgress?(regions) }
                catch {
                    // Navigation can invalidate the observer while it awaits MainActor.
                    if !lease.isRetained { throw error }
                }
            }
            // Wait for this OCR before preparing another, retaining serial recognition.
            let recognized = try await withTaskCancellationHandler { try await demand.recognition.value } onCancel: { lease.cancel() }
            try Task.checkCancellation()
            if recognized != nil, self?.generation == issued { self?.prepareNext(after: page, settings: settings) }
            let result = try await withTaskCancellationHandler {
                try await demand.translation?.value
            } onCancel: { lease.cancel() }
            try Task.checkCancellation()
            if let result { return result }
            if let stored = try? await self?.diskCache?.translatedRegions(page: page.translationCacheKey, settings: settings) {
                try Task.checkCancellation()
                if self?.generation == issued { self?.prepareNext(after: page, settings: settings) }
                return stored
            }
            // A translated disk hit skipped speculative OCR, but the entry was
            // evicted before demand arrived. Obtain real OCR and translation now.
            guard let fallback = self?.makeWork(page, settings: settings, speculative: false) else { throw CancellationError() }
            try await fallback.progress.observe(onProgress)
            return try await withTaskCancellationHandler {
                _ = try await fallback.recognition.value
                try Task.checkCancellation()
                if self?.generation == issued { self?.prepareNext(after: page, settings: settings) }
                return try await fallback.translation?.value ?? []
            } onCancel: { fallback.cancel() }
        }
        operation = task
        defer { if generation == issued { operation = nil; currentDemand = nil } }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            lease.cancel()
            if generation == issued { preparedPage?.cancel(); preparedPage = nil }
            throw error
        }
    }

    private func makeWork(_ page: Page, settings: ReaderTranslationSettings, speculative: Bool) -> PreparedPage {
        let promotion = TranslationRequestPromotion()
        if !speculative { promotion.promote() }
        var work = PreparedPage(
            key: ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings),
            pageKey: page.translationCacheKey,
            recognition: recognitionTask(page, settings: settings, skipTranslated: speculative, promotion: promotion),
            progress: ReaderTranslationPreparedProgress(),
            promotion: promotion
        )
        // A one-request setting preserves OCR-only lookahead, with no queued API prefetch.
        if !speculative || settings.maximumConcurrentRequests > 1 {
            work.translation = translationTask(work, page: page, settings: settings, speculative: speculative)
        }
        return work
    }

    private func translationTask(
        _ work: PreparedPage, page: Page, settings: ReaderTranslationSettings, speculative: Bool
    ) -> Task<[ReaderTranslationRegion]?, Error> {
        let translate = translator
        return Task.detached(priority: speculative ? .utility : .userInitiated) { [diskCache, loader] in
            let diskGeneration = await diskCache?.currentGeneration() ?? 0
            guard let regions = try await withTaskCancellationHandler(operation: { try await work.recognition.value },
                                                                      onCancel: { work.recognition.cancel() }) else { return nil }
            try Task.checkCancellation()
            let eligible = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
            let result: [ReaderTranslationRegion]
            if eligible.isEmpty {
                result = []
            } else {
                do {
                    if let translate {
                        result = try await translate(eligible, settings) { try await work.progress.publish($0) }
                    } else {
                        let image = settings.includePageImage ? try await loader.load(page) : nil
                        result = try await ReaderTranslationService.shared.translate(
                            regions: eligible, settings: settings, image: image,
                            onProgress: { try await work.progress.publish($0) },
                            priority: .promotable(work.promotion)
                        )
                    }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    throw ReaderTranslationOCRFallback(regions: regions.map {
                        var value = $0
                        value.translation = nil
                        value.translationReuseIdentity = nil
                        return value
                    }, underlying: error)
                }
            }
            try Task.checkCancellation()
            if speculative {
                // A fully translated lookahead survives leaving before the session consumes it.
                try? await diskCache?.storeRegions(result, for: work.key, kind: .translation, generation: diskGeneration)
            }
            return result
        }
    }

    private func prepareNext(after page: Page, settings: ReaderTranslationSettings) {
        guard let next = nextPage?(page), next.translationCacheKey != page.translationCacheKey else { return }
        let key = ReaderTranslationCacheIdentity.translation(page: next.translationCacheKey, settings: settings)
        guard preparedPage?.key != key else { return }
        preparedPage?.cancel()
        preparedPage = makeWork(next, settings: settings, speculative: true)
    }

    private func recognitionTask(
        _ page: Page, settings: ReaderTranslationSettings, skipTranslated: Bool = false,
        promotion: TranslationRequestPromotion
    ) -> Task<[ReaderTranslationRegion]?, Error> {
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings)
        let admission = Self.imagePreparationGate
        return Task.detached(priority: .utility) { [diskCache, loader, recognizer] in
            try await admission.withPermit(priority: .promotable(promotion)) {
            try Task.checkCancellation()
            let diskGeneration = await diskCache?.currentGeneration() ?? 0
            if skipTranslated, let diskCache,
               try await diskCache.translatedRegions(page: page.translationCacheKey, settings: settings) != nil { return nil }
            if let stored = try? await diskCache?.regions(for: key, kind: .ocr) {
                guard settings.rightToLeftPanelOrder || ReaderJapaneseSFXImageEvidence.requiresSampling(stored, settings: settings) else { return stored }
                let image = try await loader.load(page)
                try Task.checkCancellation()
                let prepared = ReaderTranslationImagePreparation.apply(stored, image: image, settings: settings)
                try? await diskCache?.storeRegions(prepared, for: key, kind: .ocr, generation: diskGeneration)
                return prepared
            }
            let regions: [ReaderTranslationRegion]
            var evidenceImage: UIImage?
            if let recognizer {
                regions = try await recognizer(page, settings)
                if settings.rightToLeftPanelOrder || ReaderJapaneseSFXImageEvidence.requiresSampling(regions, settings: settings) {
                    evidenceImage = try await loader.load(page)
                }
            } else {
                guard #available(iOS 18.0, *) else { return [] }
                var phaseStart = ProcessInfo.processInfo.systemUptime
                let image = try await loader.load(page)
                if settings.rightToLeftPanelOrder || settings.filterJapaneseSFX { evidenceImage = image }
                TranslationPerformanceDiagnostics.clientPhaseCompleted(
                    phase: "reader_image_load", segmentCount: 0,
                    elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: phaseStart)
                )
                try Task.checkCancellation()
                let pixels = try autoreleasepool { () throws -> CGImage in
                    if image.imageOrientation == .up, let pixels = image.cgImage { return pixels }
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = image.scale
                    let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
                    guard let pixels = normalized.cgImage else { throw NativeCoreMLDetectorError.imageConversionFailed }
                    return pixels
                }
                phaseStart = ProcessInfo.processInfo.systemUptime
                regions = try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration)
                TranslationPerformanceDiagnostics.clientPhaseCompleted(
                    phase: skipTranslated ? "reader_ocr_ahead" : "reader_ocr", segmentCount: regions.count,
                    elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: phaseStart)
                )
            }
            try Task.checkCancellation()
            let prepared = evidenceImage.map { ReaderTranslationImagePreparation.apply(regions, image: $0, settings: settings) } ?? regions
            try? await diskCache?.storeRegions(prepared, for: key, kind: .ocr, generation: diskGeneration)
            return prepared
            }
        }
    }

    func cancel(preservingRecognitionFor page: Page? = nil) {
        generation = UUID()
        if let currentDemand, let page, currentDemand.work.pageKey == page.translationCacheKey {
            currentDemand.lease.retain()
            preparedPage?.cancel()
            preparedPage = currentDemand.work
        }
        currentDemand = nil
        operation?.cancel()
        operation = nil
        // A page turn promotes both OCR and API work. OFF/exit/settings changes
        // pass nil and stop all work; a different destination discards the lookahead.
        if page?.translationCacheKey != preparedPage?.pageKey {
            preparedPage?.cancel()
            preparedPage = nil
        }
    }
}

/// Keeps the newest completed-batch snapshot while offscreen. Promotion replays
/// it immediately, then forwards later batches through the reader's generation fence.
private actor ReaderTranslationPreparedProgress {
    private var latest: [ReaderTranslationRegion]?
    private var observer: ReaderTranslationService.Progress?

    func publish(_ regions: [ReaderTranslationRegion]) async throws {
        try Task.checkCancellation()
        latest = regions
        try await observer?(regions)
    }

    func observe(_ observer: ReaderTranslationService.Progress?) async throws {
        try Task.checkCancellation()
        self.observer = observer
        if let latest { try await observer?(latest) }
    }
}

/// Image decoding, raw-image processing, archive I/O and source interception
/// stay outside MainActor. URL requests retain the normal reader's auth/context.
actor ReaderTranslationImageLoader {
    private let temporaryStore = ReaderTemporaryPageStore()
    deinit { Task { [temporaryStore] in await temporaryStore.removeAll() } }

    func load(_ page: Page) async throws -> UIImage {
        try Task.checkCancellation()
        if let image = page.image { return try await processRaw(image) }
        if let archive = page.zipURL, let url = URL(string: archive), let path = page.imageURL {
            guard let extracted = await temporaryStore.storeArchiveEntry(from: url, path: path) else {
                throw URLError(.cannotDecodeContentData)
            }
            return try await loadURL(extracted, page: page)
        }
        if let address = page.imageURL, let url = URL(string: address) { return try await loadURL(url, page: page) }
        if let base64 = page.base64 {
            guard let data = Data(base64Encoded: base64), let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            return try await processRaw(image)
        }
        throw URLError(.cannotDecodeContentData)
    }

    private func processRaw(_ image: UIImage) async throws -> UIImage {
        let processors: [any ImageProcessing] = await MainActor.run {
            var processors: [any ImageProcessing] = []
            if UserDefaults.standard.bool(forKey: "Reader.cropBorders") { processors.append(CropBordersProcessor()) }
            if UserDefaults.standard.bool(forKey: "Reader.downsampleImages") {
                processors.append(DownsampleProcessor(width: UIScreen.main.bounds.width))
            } else if UserDefaults.standard.bool(forKey: "Reader.upscaleImages") { processors.append(UpscaleProcessor()) }
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

    private func loadURL(_ url: URL, page: Page) async throws -> UIImage {
        var request = await ReaderPageView.imageRequest(url: url, context: page.context, sourceKey: page.sourceId)
        try Task.checkCancellation()
        request.priority = .low
        let task = ImagePipeline.shared.imageTask(with: request)
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
