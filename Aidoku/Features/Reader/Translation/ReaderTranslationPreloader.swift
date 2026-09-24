import Nuke
import UIKit

struct ReaderTranslationOCRFallback: Error {
    let regions: [ReaderTranslationRegion]
    let underlying: Error
}

/// Prepares a demand page and at most one offscreen page without reader views.
/// Started lookahead can finish across navigation; OCR and provider admission stay bounded.
@MainActor
final class ReaderTranslationPreloader {
    typealias DataPrefetcher = @Sendable (Page) async throws -> Void
    typealias Recognizer = @Sendable (Page, ReaderTranslationSettings) async throws -> [ReaderTranslationRegion]
    typealias PreparedTranslationStore = @Sendable ([ReaderTranslationRegion], String, UInt64) async -> Void
    typealias RecognitionStore = @Sendable ([ReaderTranslationRegion], String, UInt64) async -> Void
    typealias ImageRetention = @MainActor @Sendable (Page) -> Bool
    private final class WorkLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var finished = false
        private var retained = false
        var isRunning: Bool { lock.withLock { started && !finished } }
        var isRetained: Bool { lock.withLock { retained } }
        func start() { lock.withLock { started = true } }
        func finish() { lock.withLock { finished = true } }
        func retain() { lock.withLock { retained = true } }
    }
    /// A small lock-protected slot shared by a page's recognition and translation tasks.
    private final class LockedSlot<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        func store(_ newValue: Value?) { lock.withLock { value = newValue } }
        /// Consumes the value so a bounded JPEG is never retained past its one use.
        func take() -> Value? { lock.withLock { defer { value = nil }; return value } }
    }
    private struct RecognitionOutput: Sendable {
        let regions: [ReaderTranslationRegion]?
        let persist: Bool
    }
    private struct PreparedPage {
        let key: String
        let pageKey: String
        let recognition: Task<[ReaderTranslationRegion]?, Error>
        let progress: ReaderTranslationPreparedProgress
        let promotion: TranslationRequestPromotion
        let lifetime: WorkLifetime
        let settings: ReaderTranslationSettings
        /// Provider JPEG encoded from OCR's already-decoded image, inside the OCR permit.
        let preparedImageJPEG: LockedSlot<Data>
        var translation: Task<[ReaderTranslationRegion]?, Error>?

        func cancel() { recognition.cancel(); translation?.cancel(); _ = preparedImageJPEG.take() }
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
    private static let imagePreparationGate = TranslationImageWorkBudget.shared
    private let loader = ReaderTranslationImageLoader()
    private let translator: ReaderTranslationPage.ProgressiveTranslator?
    private let recognizer: Recognizer?
    private let dataPrefetcher: DataPrefetcher?
    private let availableMemory: @Sendable () -> UInt64
    private let diskCache: ReaderTranslationDiskCache?
    private let storePreparedTranslation: PreparedTranslationStore
    private let storeRecognition: RecognitionStore
    private let retainImage: ImageRetention
    private var operation: Task<[ReaderTranslationRegion], Error>?
    private var preparedPage: PreparedPage?
    private var currentDemand: (work: PreparedPage, lease: DemandLease)?
    private var generation = UUID()
    var nextPage: ((Page) -> Page?)?
    var onPrepared: (@MainActor @Sendable (Page, [ReaderTranslationRegion], ReaderTranslationSettings) -> Void)?

    init(
        diskCache: ReaderTranslationDiskCache? = nil,
        translator: ReaderTranslationPage.ProgressiveTranslator? = nil,
        recognizer: Recognizer? = nil,
        dataPrefetcher: DataPrefetcher? = nil,
        availableMemory: @escaping @Sendable () -> UInt64 = { ReaderTranslationSession.processAvailableMemory() },
        retainImage: @escaping ImageRetention = { _ in true },
        storePreparedTranslation: PreparedTranslationStore? = nil,
        storeRecognition: RecognitionStore? = nil
    ) {
        self.translator = translator
        self.diskCache = diskCache
        self.recognizer = recognizer
        self.dataPrefetcher = dataPrefetcher
        self.availableMemory = availableMemory
        self.retainImage = retainImage
        self.storePreparedTranslation = storePreparedTranslation ?? { regions, key, generation in
            try? await diskCache?.storeRegions(regions, for: key, kind: .translation, generation: generation)
        }
        self.storeRecognition = storeRecognition ?? { regions, key, generation in
            try? await diskCache?.storeRegions(regions, for: key, kind: .ocr, generation: generation)
        }
    }

    deinit { operation?.cancel(); preparedPage?.cancel(); currentDemand?.work.cancel() }

    func translate(
        _ page: Page, settings: ReaderTranslationSettings, onProgress: ReaderTranslationService.Progress? = nil
    ) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
        // A repeated demand replaces its observer, not the OCR/provider operation.
        // Transfer ownership before cancelling the old consumer.
        let adopted = currentDemand.flatMap { demand -> PreparedPage? in
            guard demand.work.key == key,
                  demand.work.settings.maximumConcurrentRequests == settings.maximumConcurrentRequests else { return nil }
            demand.lease.retain()
            return demand.work
        }
        if canFinishLookahead(settings: settings) { preparedPage?.lifetime.retain() }
        operation?.cancel()
        generation = UUID()
        let issued = generation
        var work: PreparedPage
        if let adopted {
            work = adopted
        } else if let preparedPage, preparedPage.key == key,
                  preparedPage.settings.maximumConcurrentRequests == settings.maximumConcurrentRequests {
            work = preparedPage
            self.preparedPage = nil
        } else {
            if !canFinishLookahead(settings: settings) {
                preparedPage?.cancel()
                preparedPage = nil
            }
            work = makeWork(page, settings: settings, speculative: false)
        }
        work.promotion.promote()
        if work.translation == nil {
            work.translation = translationTask(work, page: page, settings: settings, speculative: false)
        }
        let demand = work
        let lease = DemandLease(demand)
        currentDemand = (demand, lease)
        // Download only compressed data during demand OCR. The following OCR
        // still waits for demand recognition and the shared decoding permit.
        prepareNext(after: page, settings: settings, afterRecognition: demand.recognition)
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

    private func makeWork(
        _ page: Page, settings: ReaderTranslationSettings, speculative: Bool,
        afterRecognition: Task<[ReaderTranslationRegion]?, Error>? = nil
    ) -> PreparedPage {
        let promotion = TranslationRequestPromotion()
        let lifetime = WorkLifetime()
        let preparedImageJPEG = LockedSlot<Data>()
        if !speculative { promotion.promote() }
        var work = PreparedPage(
            key: ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings),
            pageKey: page.translationCacheKey,
            recognition: recognitionTask(page, settings: settings, skipTranslated: speculative, promotion: promotion,
                                         lifetime: lifetime, preparedImageJPEG: preparedImageJPEG,
                                         afterRecognition: afterRecognition),
            progress: ReaderTranslationPreparedProgress(),
            promotion: promotion, lifetime: lifetime, settings: settings, preparedImageJPEG: preparedImageJPEG
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
        let onPrepared = onPrepared
        let storePreparedTranslation = storePreparedTranslation
        let imageAdmission = Self.imagePreparationGate
        return Task.detached(priority: speculative ? .utility : .userInitiated) { [diskCache, loader, retainImage] in
            defer { work.lifetime.finish() }
            let diskGeneration = await diskCache?.currentGeneration(settings: settings) ?? 0
            guard let regions = try await withTaskCancellationHandler(operation: { try await work.recognition.value },
                                                                      onCancel: { work.recognition.cancel() }) else { return nil }
            try Task.checkCancellation()
            let eligible = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
            // Publish before image encoding, provider admission, or network work.
            // The progress store also replays OCR when lookahead becomes visible.
            try await work.progress.publish(eligible)
            let result: [ReaderTranslationRegion]
            if eligible.isEmpty {
                result = []
            } else {
                do {
                    if let translate {
                        result = try await translate(eligible, settings) { try await work.progress.publish($0) }
                    } else {
                        let imageJPEG: Data?
                        if settings.shouldAttachPageImage, let prepared = work.preparedImageJPEG.take() {
                            // Same encoder and source image as below, without a second decode/permit.
                            imageJPEG = prepared
                        } else if settings.shouldAttachPageImage {
                            imageJPEG = try await imageAdmission.withPermit(priority: .promotable(work.promotion)) {
                                let image = try await loader.load(page, cacheInMemory: await retainImage(page))
                                try Task.checkCancellation()
                                return try autoreleasepool { try ReaderTranslationImagePreparation.translationJPEG(image) }
                            }
                        } else {
                            imageJPEG = nil
                        }
                        // Keep only the bounded JPEG while waiting for the provider,
                        // rather than retaining the decoded source for every batch.
                        result = try await ReaderTranslationService.shared.translate(
                            regions: eligible, settings: settings, preparedImageJPEG: imageJPEG,
                            onProgress: { try await work.progress.publish($0) },
                            priority: .promotable(work.promotion)
                        )
                    }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    throw ReaderTranslationOCRFallback(regions: await work.progress.snapshot() ?? regions.map {
                        var value = $0
                        value.translation = nil
                        value.translationReuseIdentity = nil
                        return value
                    }, underlying: error)
                }
            }
            try Task.checkCancellation()
            if speculative {
                // Display completed text before persistence finishes. Keep the
                // write independent of navigation cancellation, but join it here
                // so this bounded lookahead cannot create a growing write queue.
                let persistence = Task(priority: .utility) {
                    await storePreparedTranslation(result, work.key, diskGeneration)
                }
                await onPrepared?(page, result, settings)
                await persistence.value
                try Task.checkCancellation()
            }
            return result
        }
    }

    private func prepareNext(
        after page: Page, settings: ReaderTranslationSettings,
        afterRecognition: Task<[ReaderTranslationRegion]?, Error>? = nil
    ) {
        guard let next = nextPage?(page), next.translationCacheKey != page.translationCacheKey else { return }
        let key = ReaderTranslationCacheIdentity.translation(page: next.translationCacheKey, settings: settings)
        guard preparedPage?.key != key else { return }
        guard !canFinishLookahead(settings: settings) else { return }
        preparedPage?.cancel()
        preparedPage = makeWork(next, settings: settings, speculative: true, afterRecognition: afterRecognition)
    }

    /// One already-started background page may finish even after a distant jump.
    /// Never preserve old foreground priority, changed settings, or work under pressure.
    /// This uses the existing lookahead slot, so navigation cannot grow a work queue.
    private func canFinishLookahead(settings: ReaderTranslationSettings? = nil) -> Bool {
        guard let preparedPage, preparedPage.translation != nil,
              !preparedPage.promotion.isForeground, preparedPage.lifetime.isRunning,
              availableMemory() >= TranslationImageWorkBudget.minimumHeadroom else { return false }
        guard let settings else { return true }
        return preparedPage.settings.hasSameTranslation(as: settings)
            && preparedPage.settings.maximumConcurrentRequests == settings.maximumConcurrentRequests
    }

    private func recognitionTask(
        _ page: Page, settings: ReaderTranslationSettings, skipTranslated: Bool = false,
        promotion: TranslationRequestPromotion,
        lifetime: WorkLifetime,
        preparedImageJPEG: LockedSlot<Data>,
        afterRecognition: Task<[ReaderTranslationRegion]?, Error>? = nil
    ) -> Task<[ReaderTranslationRegion]?, Error> {
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings)
        let admission = Self.imagePreparationGate
        // Only the built-in provider path consumes the page JPEG.
        let encodesJPEG = translator == nil && settings.shouldAttachPageImage
        return Task.detached(priority: .utility) { [diskCache, loader, recognizer, dataPrefetcher, availableMemory, retainImage,
                                                    storeRecognition] in
            try Task.checkCancellation()
            if skipTranslated, let diskCache,
               try await diskCache.translatedRegions(page: page.translationCacheKey, settings: settings) != nil { return nil }
            let diskGeneration = await diskCache?.currentGeneration(settings: settings) ?? 0
            let cachedOCR = try? await diskCache?.regions(for: key, kind: .ocr)
            // Prepared text has no image allocation. Do not queue it behind an
            // unrelated, potentially non-interruptible OCR inference. Image-context
            // requests keep the normal barrier before their later image load.
            if let cachedOCR, !settings.shouldAttachPageImage,
               !ReaderTranslationImagePreparation.needsImage(cachedOCR, settings: settings) {
                try Task.checkCancellation()
                lifetime.start()
                return cachedOCR
            }
            if skipTranslated, !promotion.isForeground,
               availableMemory() < TranslationImageWorkBudget.minimumHeadroom { return nil }
            lifetime.start()
            if skipTranslated {
                // Best effort: source interception/decode fallback remains in load().
                let needsImage = cachedOCR.map {
                    settings.shouldAttachPageImage || ReaderTranslationImagePreparation.needsImage($0, settings: settings)
                } ?? true
                if needsImage {
                    if let dataPrefetcher { try? await dataPrefetcher(page) }
                    else if recognizer == nil { try? await loader.prefetchData(page) }
                }
                try Task.checkCancellation()
                do {
                    _ = try await afterRecognition?.value
                } catch {
                    try Task.checkCancellation()
                    // The failed demand will discard its lookahead. Avoid starting
                    // OCR just to cancel/repeat it; nil is retried on actual demand.
                    if !promotion.isForeground, !lifetime.isRetained { return nil }
                }
                try Task.checkCancellation()
            }
            /// Encode the provider JPEG while the decoded image is already resident
            /// under this permit. Failure leaves the translation task's original path.
            @Sendable func prepareJPEG(_ regions: [ReaderTranslationRegion], image: UIImage) {
                guard encodesJPEG, !Task.isCancelled,
                      !ReaderTranslationLanguageFilter.apply(regions, settings: settings).isEmpty else { return }
                preparedImageJPEG.store(try? autoreleasepool { try ReaderTranslationImagePreparation.translationJPEG(image) })
            }
            // SQLite writes happen after the permit is released, so the next page's
            // decode/OCR never waits for this page's disk I/O.
            let loadedImageSize = LockedSlot<CGSize>()
            let output: RecognitionOutput
            do {
                output = try await admission.withPermit(priority: .promotable(promotion)) {
                try Task.checkCancellation()
                // Headroom can fall while downloading or waiting for the OCR permit.
                if skipTranslated, !promotion.isForeground,
                   availableMemory() < 1_280 * 1_024 * 1_024 { return RecognitionOutput(regions: nil, persist: false) }
                if let stored = cachedOCR {
                    guard ReaderTranslationImagePreparation.needsImage(stored, settings: settings) else {
                        return RecognitionOutput(regions: stored, persist: false)
                    }
                    let image = try await loader.load(page, cacheInMemory: await retainImage(page))
                    try Task.checkCancellation()
                    let prepared = ReaderTranslationImagePreparation.apply(stored, image: image, settings: settings)
                    prepareJPEG(prepared, image: image)
                    return RecognitionOutput(regions: prepared, persist: true)
                }
                let regions: [ReaderTranslationRegion]
                var evidenceImage: UIImage?
                var jpegSource: UIImage?
                if let recognizer {
                    regions = try await recognizer(page, settings)
                    if ReaderTranslationImagePreparation.needsImage(regions, settings: settings) {
                        evidenceImage = try await loader.load(page, cacheInMemory: await retainImage(page))
                        jpegSource = evidenceImage
                    }
                } else {
                    guard #available(iOS 18.0, *) else { return RecognitionOutput(regions: [], persist: false) }
                    var phaseStart = ProcessInfo.processInfo.systemUptime
                    let image = try await loader.load(page, cacheInMemory: await retainImage(page))
                    if settings.rightToLeftPanelOrder { evidenceImage = image }
                    jpegSource = image
                    loadedImageSize.store(image.size)
                    TranslationPerformanceDiagnostics.clientPhaseCompleted(
                        phase: "reader_image_load", segmentCount: 0,
                        elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: phaseStart)
                    )
                    try Task.checkCancellation()
                    // Scope the normalized copy so it is released before JPEG encoding.
                    do {
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
                    }
                    TranslationPerformanceDiagnostics.clientPhaseCompleted(
                        phase: skipTranslated ? "reader_ocr_ahead" : "reader_ocr", segmentCount: regions.count,
                        elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: phaseStart)
                    )
                }
                try Task.checkCancellation()
                let prepared = evidenceImage.map { ReaderTranslationImagePreparation.apply(regions, image: $0, settings: settings) } ?? regions
                if let jpegSource { prepareJPEG(prepared, image: jpegSource) }
                return RecognitionOutput(regions: prepared, persist: true)
                }
            } catch {
                if let size = loadedImageSize.take() {
                    try? await diskCache?.storeImageSize(size, page: page.translationCacheKey, generation: diskGeneration)
                }
                throw error
            }
            if let size = loadedImageSize.take() {
                try? await diskCache?.storeImageSize(size, page: page.translationCacheKey, generation: diskGeneration)
            }
            if output.persist, let regions = output.regions, !Task.isCancelled {
                await storeRecognition(regions, key, diskGeneration)
            }
            return output.regions
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
        if page != nil, canFinishLookahead() { preparedPage?.lifetime.retain() }
        operation?.cancel()
        operation = nil
        // A page turn promotes both OCR and API work. OFF/exit/settings changes
        // pass nil and stop all work. A different destination can leave one
        // started, unpromoted lookahead to finish and persist its result.
        if page == nil || (page?.translationCacheKey != preparedPage?.pageKey && !canFinishLookahead()) {
            preparedPage?.cancel()
            preparedPage = nil
        }
    }
}

/// Keeps the newest completed-batch snapshot while offscreen. Promotion replays
/// it immediately, then forwards later batches through the reader's generation fence.
private actor ReaderTranslationPreparedProgress {
    private var latest: [ReaderTranslationRegion]?

    func snapshot() -> [ReaderTranslationRegion]? { latest }
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
    private let pipeline: ImagePipeline
    init(pipeline: ImagePipeline = .shared) { self.pipeline = pipeline }
    deinit { Task { [temporaryStore] in await temporaryStore.removeAll() } }

    /// Uses Nuke's data-only path: no decoding, image processors, or UIImage retention.
    func prefetchData(_ page: Page) async throws {
        guard page.image == nil, page.zipURL == nil, page.base64 == nil,
              let address = page.imageURL, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        var request = await ReaderPageView.imageRequest(url: url, context: page.context, sourceKey: page.sourceId)
        try Task.checkCancellation()
        // Without reusable disk data, warming would just download the page twice.
        guard pipeline.configuration.dataCache != nil,
              !request.options.contains(.disableDiskCacheReads),
              !request.options.contains(.disableDiskCacheWrites) else { return }
        request.priority = .veryLow
        _ = try await pipeline.data(for: request)
        try Task.checkCancellation()
    }

    func load(_ page: Page, cacheInMemory: Bool = true) async throws -> UIImage {
        try Task.checkCancellation()
        if let image = page.image { return try await processRaw(image) }
        if let archive = page.zipURL, let url = URL(string: archive), let path = page.imageURL {
            guard let extracted = await temporaryStore.storeArchiveEntry(from: url, path: path) else {
                throw URLError(.cannotDecodeContentData)
            }
            return try await loadURL(extracted, page: page, cacheInMemory: cacheInMemory)
        }
        if let address = page.imageURL, let url = URL(string: address) {
            return try await loadURL(url, page: page, cacheInMemory: cacheInMemory)
        }
        if let base64 = page.base64 {
            guard let data = Data(base64Encoded: base64), let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            try TranslationImageWorkBudget.shared.checkHeadroom(decodedBytes: TranslationImageWorkBudget.decodedBytes(in: data))
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

    private func loadURL(_ url: URL, page: Page, cacheInMemory: Bool) async throws -> UIImage {
        if url.isFileURL {
            let compressed = try Data(contentsOf: url, options: .mappedIfSafe)
            try TranslationImageWorkBudget.shared.checkHeadroom(decodedBytes: TranslationImageWorkBudget.decodedBytes(in: compressed))
        }
        var request = await ReaderPageView.imageRequest(url: url, context: page.context, sourceKey: page.sourceId)
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
