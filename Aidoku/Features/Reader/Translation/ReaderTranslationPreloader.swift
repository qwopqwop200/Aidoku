import AidokuRunner
import Nuke
import UIKit

struct ReaderTranslationOCRFallback: Error {
    let regions: [ReaderTranslationRegion]
    let underlying: Error
}

/// Prepares a demand page and a bounded offscreen window without reader views.
/// Started lookahead can finish across navigation; OCR and provider admission stay bounded.
@MainActor
final class ReaderTranslationPreloader {
    private typealias SourceRecord = ReaderTranslationRegionArchive.Record
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
        private var prefetching = false
        var isPrefetching: Bool { lock.withLock { prefetching } }
        func setPrefetching(_ value: Bool) { lock.withLock { prefetching = value } }
        var isRunning: Bool { lock.withLock { started && !finished } }
        var isRetained: Bool { lock.withLock { retained } }
        func start() { lock.withLock { started = true } }
        func finish() { lock.withLock { finished = true } }
        func retain() { lock.withLock { retained = true } }
    }
    /// A small lock-protected slot shared by a page's recognition and translation tasks.
    final class LockedSlot<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        private var discarded = false
        func store(_ newValue: Value?) {
            lock.withLock {
                guard !discarded else { return }
                value = newValue
            }
        }
        /// Consumes the value so a bounded JPEG is never retained past its one use.
        func take() -> Value? { lock.withLock { defer { value = nil }; return value } }
        /// Encoding is synchronous: a producer can finish after cancellation emptied
        /// the slot. Closing it atomically prevents that late result from retaining bytes.
        func discard() { lock.withLock { discarded = true; value = nil } }
    }
    private enum PreparedSource: Sendable {
        case recognized(SourceRecord)
        case alreadyTranslated(SourceRecord)

        var record: SourceRecord {
            switch self {
            case .recognized(let record), .alreadyTranslated(let record): record
            }
        }
    }

    private actor RecognitionDelivery {
        private var result: Result<PreparedSource?, Error>?
        private var waiters: [UUID: CheckedContinuation<PreparedSource?, Error>] = [:]

        func value() async throws -> PreparedSource? {
            try Task.checkCancellation()
            if let result { return try result.get() }
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result { continuation.resume(with: result) }
                    else if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiters[id] = continuation }
                }
            } onCancel: { Task { await self.cancelWaiter(id) } }
        }

        private func cancelWaiter(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }

        func resolve(_ value: Result<PreparedSource?, Error>) {
            guard result == nil else { return }
            result = value
            for waiter in waiters.values { waiter.resume(with: value) }
            waiters.removeAll()
        }
    }

    private struct RecognitionDependency: Sendable {
        let ready: RecognitionDelivery
        let stored: Task<[ReaderTranslationRegion]?, Error>
    }

    private struct RecognitionOutput: Sendable {
        let regions: [ReaderTranslationRegion]?
        let persist: Bool
        var sourceRasterClaim: ReaderTranslationSourceRasterClaim? = nil
        var alreadyTranslated = false

        var prepared: PreparedSource? {
            guard let regions else { return nil }
            let record = SourceRecord(regions: regions, sourceRasterClaim: sourceRasterClaim)
            return alreadyTranslated ? .alreadyTranslated(record) : .recognized(record)
        }
    }

    /// Same-locator inline content can change independently of session keys.
    /// Observe existing exact object/equal proof without retaining another page.
    private final class WorkSource: @unchecked Sendable {
        private struct RemoteLocator: Equatable {
            let source: String
            let chapter: String
            let index: Int
            let address: String
            let context: PageContext?

            init?(_ page: Page) {
                guard page.image == nil, page.zipURL == nil, let address = page.imageURL,
                      let scheme = URL(string: address)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
                source = page.sourceId
                chapter = page.chapterId
                index = page.index
                self.address = address
                context = page.context
            }
        }

        private let remote: RemoteLocator?
        private weak var inlineImage: UIImage?
        private let wasInline: Bool
        private let initialInlineClaim: ReaderTranslationSourceRasterClaim?

        init(_ page: Page) {
            remote = RemoteLocator(page)
            inlineImage = page.image
            wasInline = page.image != nil
            initialInlineClaim = page.image.flatMap { .memoized(fullProcessedSource: $0) }
        }

        func canCoalesce(_ page: Page) -> Bool {
            guard let current = page.image else { return !wasInline && remote == RemoteLocator(page) }
            if inlineImage === current { return true }
            guard let proof = inlineImage.flatMap({ ReaderTranslationSourceRasterClaim.memoized(fullProcessedSource: $0) })
                ?? initialInlineClaim else { return false }
            return proof == .memoized(fullProcessedSource: current)
        }
    }
    private struct PreparedPage {
        let diagnosticContext: ReaderTranslationDiagnostics.Context
        let key: String
        let pageKey: String
        let source: WorkSource
        let requestHandoff: ReaderTranslationImageRequestHandoff
        let recognition: Task<[ReaderTranslationRegion]?, Error>
        let recognitionDelivery: RecognitionDelivery
        let progress: ReaderTranslationPreparedProgress
        let promotion: TranslationRequestPromotion
        let lifetime: WorkLifetime
        let settings: ReaderTranslationSettings
        /// Provider JPEG encoded from OCR's already-decoded image, inside the OCR permit.
        let preparedImageJPEG: LockedSlot<RemoteTranslationPageImage>
        let evidence: ReaderTranslationPreparedEvidence
        var translation: Task<SourceRecord?, Error>?

        var dependency: RecognitionDependency { .init(ready: recognitionDelivery, stored: recognition) }

        func cancel() {
            recognition.cancel()
            translation?.cancel()
            preparedImageJPEG.discard()
            requestHandoff.discard()
        }
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
    // One page may prepare while its predecessor persists. Apply backpressure before decoding,
    // including across cancelled generations whose storage operations are still draining.
    private let recognitionWindow = TranslationProviderRequestLimiter(maximumConcurrentRequests: 2)
    private let imagePreparationGate: TranslationImageWorkBudget
    private let loader: ReaderTranslationImageLoader
    private let translator: ReaderTranslationPage.ProgressiveTranslator?
    private let translationService: ReaderTranslationService
    private let recognizer: Recognizer?
    private let dataPrefetcher: DataPrefetcher?
    private let dataPromoter: DataPrefetcher?
    private let availableMemory: @Sendable () -> UInt64
    private let diskCache: ReaderTranslationDiskCache?
    private let storePreparedTranslation: PreparedTranslationStore?
    private let storeRecognition: RecognitionStore?
    private let fixtureSourceRasterClaim: (@Sendable (Page) -> ReaderTranslationSourceRasterClaim?)?
    private let retainImage: ImageRetention
    private var operation: Task<SourceRecord, Error>?
    private var preparedPages: [PreparedPage] = []
    var preparedPageCount: Int { preparedPages.count }
    private var currentDemand: (work: PreparedPage, lease: DemandLease, page: Page)?
    private var generation = UUID()
    var nextPage: ((Page) -> Page?)?
    var nextPageExcluding: ((Page, Set<String>) -> Page?)?
    /// The reader may allow a second lookahead only after visible work settles.
    var lookaheadLimit: ((Page, ReaderTranslationSettings) -> Int)?
    var onPrepared: (@MainActor @Sendable (Page, [ReaderTranslationRegion], ReaderTranslationSettings) -> Void)?
    var onPreparedRecord: (@MainActor @Sendable (Page, ReaderTranslationRegionArchive.Record, ReaderTranslationSettings) -> Void)?
    var onEvidencePrepared: (@MainActor @Sendable (Page, ReaderTranslationSettings, ReaderTranslationPreparedEvidence, ReaderTranslationSourceRasterClaim?) -> Void)?
    var onPersistPreparedRecord: (@MainActor @Sendable (Page, ReaderTranslationRegionArchive.Record, ReaderTranslationDiskCache.TranslationWriteDestination) async -> Void)?

    init(
        diskCache: ReaderTranslationDiskCache? = nil,
        translator: ReaderTranslationPage.ProgressiveTranslator? = nil,
        translationService: ReaderTranslationService = .shared,
        recognizer: Recognizer? = nil,
        dataPrefetcher: DataPrefetcher? = nil,
        dataPromoter: DataPrefetcher? = nil,
        availableMemory: @escaping @Sendable () -> UInt64 = { ReaderTranslationSession.processAvailableMemory() },
        retainImage: @escaping ImageRetention = { _ in true },
        storePreparedTranslation: PreparedTranslationStore? = nil,
        storeRecognition: RecognitionStore? = nil,
        loader: ReaderTranslationImageLoader = ReaderTranslationImageLoader(),
        imagePreparationGate: TranslationImageWorkBudget = .shared,
        fixtureSourceRasterClaim: (@Sendable (Page) -> ReaderTranslationSourceRasterClaim?)? = nil
    ) {
        self.loader = loader
        self.imagePreparationGate = imagePreparationGate
        self.translator = translator
        self.translationService = translationService
        self.diskCache = diskCache
        self.recognizer = recognizer
        self.fixtureSourceRasterClaim = recognizer == nil ? nil : fixtureSourceRasterClaim
        self.dataPrefetcher = dataPrefetcher
        self.dataPromoter = dataPromoter
        self.availableMemory = availableMemory
        self.retainImage = retainImage
        self.storePreparedTranslation = storePreparedTranslation
        self.storeRecognition = storeRecognition
    }

    deinit { operation?.cancel(); preparedPages.forEach { $0.cancel() }; currentDemand?.work.cancel() }

    func translate(
        _ page: Page, settings: ReaderTranslationSettings, onProgress: ReaderTranslationService.Progress? = nil
    ) async throws -> [ReaderTranslationRegion] {
        try await translateRecord(page, settings: settings, onProgress: onProgress).regions
    }

    func translateRecord(
        _ page: Page, settings: ReaderTranslationSettings, onProgress: ReaderTranslationService.Progress? = nil
    ) async throws -> ReaderTranslationRegionArchive.Record {
        try Task.checkCancellation()
        // The chapter queue supplies the full page. A display-only half shares
        // its key but must never read, attest, or overwrite full-page OCR.
        guard page.translationSourceRect == nil || page.translationSourceRect == ReaderTranslationSplitGeometry.unit else {
            throw RemoteTranslationError.invalidRequest("Translation requires the full source page.")
        }
        let key = ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings)
        // A repeated demand replaces its observer, not the OCR/provider operation.
        // Transfer ownership before cancelling the old consumer.
        let adopted = currentDemand.flatMap { demand -> PreparedPage? in
            guard demand.work.key == key,
                  demand.work.source.canCoalesce(page),
                  demand.work.settings.maximumConcurrentRequests == settings.maximumConcurrentRequests else { return nil }
            demand.lease.retain()
            return demand.work
        }
        // A retained observer no longer owns cancellation. Explicitly retire
        // its work when a different page or configuration replaces it.
        if adopted == nil { currentDemand?.work.cancel() }
        preparedPages.removeAll { work in
            guard work.key == key, !work.source.canCoalesce(page) else { return false }
            work.cancel()
            return true
        }
        for work in preparedPages where canFinishLookahead(work, settings: settings) { work.lifetime.retain() }
        operation?.cancel()
        generation = UUID()
        let issued = generation
        var work: PreparedPage
        if let adopted {
            work = adopted
        } else if let index = preparedPages.firstIndex(where: {
            $0.key == key && $0.settings.maximumConcurrentRequests == settings.maximumConcurrentRequests
        }) {
            work = preparedPages.remove(at: index)
        } else {
            preparedPages.removeAll { work in
                guard !canFinishLookahead(work, settings: settings) else { return false }
                work.cancel()
                return true
            }
            work = makeWork(page, settings: settings, speculative: false)
        }
        ReaderTranslationDiagnostics.record(adopted != nil ? "preload_adopted" : "preload_demand", context: work.diagnosticContext)
        work.promotion.promote()
        if work.translation == nil {
            work.translation = translationTask(work, page: page, settings: settings, speculative: false)
        }
        let demand = work
        let lease = DemandLease(demand)
        currentDemand = (demand, lease, page)
        // Download only compressed data during demand OCR. The following OCR
        // still waits for demand recognition and the shared decoding permit.
        prepareNext(after: page, settings: settings, afterRecognition: demand.dependency)
        let task = Task { [weak self, loader, dataPromoter, recognizer] in
            // Adopting lookahead promotes image admission and provider work, but
            // its already-running data-only Nuke request still has low priority.
            // One observer raises that coalesced transfer while this consumer lives.
            let downloadPromotion: Task<Void, Never>? = if demand.lifetime.isPrefetching {
                Task {
                    if let dataPromoter { try? await dataPromoter(page) }
                    else if recognizer == nil { try? await loader.promote(demand.requestHandoff) }
                }
            } else { nil }
            defer { downloadPromotion?.cancel() }
            try await demand.progress.observe { [weak lease] regions in
                guard let lease, !lease.isRetained else { return }
                do { try await onProgress?(regions) }
                catch {
                    // Navigation can invalidate the observer while it awaits MainActor.
                    if !lease.isRetained { throw error }
                }
            }
            // Wait for this OCR before preparing another, retaining serial recognition.
            let recognized = try await withTaskCancellationHandler {
                try await demand.recognition.value
            } onCancel: { lease.cancel(); downloadPromotion?.cancel() }
            try Task.checkCancellation()
            if recognized != nil, self?.generation == issued { self?.prepareNext(after: page, settings: settings) }
            let result = try await withTaskCancellationHandler {
                try await demand.translation?.value
            } onCancel: { lease.cancel(); downloadPromotion?.cancel() }
            try Task.checkCancellation()
            if let result { return result }
            // A speculative image admission can abstain. A real cache hit is
            // carried as a complete record; never infer it from nil and reread.
            guard let fallback = self?.makeWork(page, settings: settings, speculative: false) else { throw CancellationError() }
            try await fallback.progress.observe(onProgress)
            return try await withTaskCancellationHandler {
                _ = try await fallback.recognition.value
                try Task.checkCancellation()
                if self?.generation == issued { self?.prepareNext(after: page, settings: settings) }
                guard let record = try await fallback.translation?.value else { throw CancellationError() }
                return record
            } onCancel: { fallback.cancel() }
        }
        operation = task
        defer { if generation == issued { operation = nil; currentDemand = nil } }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            lease.cancel()
            if generation == issued { preparedPages.forEach { $0.cancel() }; preparedPages.removeAll() }
            throw error
        }
    }

    private func makeWork(
        _ page: Page, settings: ReaderTranslationSettings, speculative: Bool,
        checkTranslationCache: Bool = true,
        afterRecognition: RecognitionDependency? = nil
    ) -> PreparedPage {
        let promotion = TranslationRequestPromotion()
        let lifetime = WorkLifetime()
        let requestHandoff = ReaderTranslationImageRequestHandoff()
        let preparedImageJPEG = LockedSlot<RemoteTranslationPageImage>()
        let evidence = ReaderTranslationPreparedEvidence()
        let delivery = RecognitionDelivery()
        if !speculative { promotion.promote() }
        let diagnostic = ReaderTranslationDiagnostics.makeContext(pageKey: page.translationCacheKey)
        var work = PreparedPage(
            diagnosticContext: diagnostic,
            key: ReaderTranslationCacheIdentity.translation(page: page.translationCacheKey, settings: settings),
            pageKey: page.translationCacheKey,
            source: WorkSource(page), requestHandoff: requestHandoff,
            recognition: recognitionTask(page, settings: settings, skipTranslated: speculative, promotion: promotion,
                                         lifetime: lifetime, requestHandoff: requestHandoff, preparedImageJPEG: preparedImageJPEG, evidence: evidence,
                                         afterRecognition: afterRecognition, delivery: delivery,
                                         checkTranslationCache: checkTranslationCache, diagnosticContext: diagnostic),
            recognitionDelivery: delivery,
            progress: ReaderTranslationPreparedProgress(),
            promotion: promotion, lifetime: lifetime, settings: settings, preparedImageJPEG: preparedImageJPEG, evidence: evidence
        )
        // A one-request setting preserves OCR-only lookahead, with no queued API prefetch.
        if !speculative || settings.maximumConcurrentRequests > 1 {
            work.translation = translationTask(work, page: page, settings: settings, speculative: speculative)
        }
        return work
    }

    private func translationTask(
        _ work: PreparedPage, page: Page, settings: ReaderTranslationSettings, speculative: Bool
    ) -> Task<SourceRecord?, Error> {
        let translate = translator
        let onPrepared = onPrepared
        let onPreparedRecord = onPreparedRecord
        let onEvidencePrepared = onEvidencePrepared
        let onPersistPreparedRecord = onPersistPreparedRecord
        let storePreparedTranslation = storePreparedTranslation
        let usesInjectedRecognizer = recognizer != nil
        let imageAdmission = imagePreparationGate
        let didFinish: @MainActor @Sendable (String) -> Void = { [weak self] key in
            self?.lookaheadDidFinish(key: key)
        }
        return Task.detached(priority: speculative ? .utility : .userInitiated) { [diskCache, loader, retainImage, translationService] in
            try await ReaderTranslationDiagnostics.measure("preload_translation", context: work.diagnosticContext) {
                defer {
                    work.preparedImageJPEG.discard()
                    work.lifetime.finish()
                    if speculative {
                        let key = work.key
                        Task { await didFinish(key) }
                    }
                }
                let diskWrite = speculative ? await diskCache?.captureTranslationWrite(settings: settings) : nil
                guard let prepared = try await withTaskCancellationHandler(operation: { try await work.recognitionDelivery.value() },
                                                                           onCancel: { work.recognition.cancel() }) else { return nil }
                try Task.checkCancellation()
                let original = prepared.record
                if case .alreadyTranslated = prepared {
                    // Keep the old array-only callback behavior on a cached
                    // hit; only the typed consumer may receive this new path.
                    var cached = original
                    cached.wasReadFromTranslationCache = true
                    if speculative { await onPreparedRecord?(page, cached, settings) }
                    return cached
                }
                let regions = original.regions
                let eligible = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
                let eligibleIDs = Set(eligible.map(\.id))
                let preservingOwners: @Sendable ([ReaderTranslationRegion]) -> [ReaderTranslationRegion] = { translated in
                    ReaderTranslationLanguageFilter.preservingExcludedSource(
                        original: regions, translated: translated, eligibleIDs: eligibleIDs)
                }
                // Publish before image encoding, provider admission, or network work.
                // The progress store also replays OCR when lookahead becomes visible.
                try await work.progress.publish(preservingOwners(eligible))
                let result: [ReaderTranslationRegion]
                if eligible.isEmpty {
                    result = preservingOwners([])
                } else {
                    do {
                        if let translate {
                            result = preservingOwners(try await translate(eligible, settings) {
                                try await work.progress.publish(preservingOwners($0))
                            })
                        } else {
                            let preparedPage: RemoteTranslationPageImage?
                            if settings.shouldAttachPageImage, let prepared = work.preparedImageJPEG.take() {
                                // Same encoder and source image as below, without a second decode/permit.
                                preparedPage = prepared
                            } else if settings.shouldAttachPageImage {
                                preparedPage = try await imageAdmission.withPermit(priority: .promotable(work.promotion)) {
                                    let image = try await loader.load(page, cacheInMemory: await retainImage(page))
                                    try Task.checkCancellation()
                                    if !usesInjectedRecognizer,
                                       (original.sourceRasterClaim == nil ||
                                        ReaderTranslationSourceRasterClaim.observe(fullProcessedSource: image) != original.sourceRasterClaim) {
                                        throw CancellationError() // Do not send A's OCR with B's pixels.
                                    }
                                    return try autoreleasepool { try ReaderTranslationImagePreparation.preparedPage(image, evidence: work.evidence) }
                                }
                            } else {
                                preparedPage = nil
                            }
                            // Keep only the bounded JPEG while waiting for the provider,
                            // rather than retaining the decoded source for every batch.
                            result = try await translationService.translate(
                                regions: regions, settings: settings, preparedPage: preparedPage,
                                onProgress: { try await work.progress.publish($0) },
                                priority: .promotable(work.promotion),
                                // Streamed segments reach only the current observer (the
                                // visible demand page); lookahead has none until adopted.
                                onPartialProgress: { try await work.progress.publish($0) }
                            )
                        }
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        throw ReaderTranslationOCRFallback(regions: await work.progress.snapshot() ?? preservingOwners(regions.map {
                            var value = $0
                            value.translation = nil
                            value.translationReuseIdentity = nil
                            return value
                        }), underlying: error)
                    }
                }
                try Task.checkCancellation()
                let record = SourceRecord(regions: result, sourceRasterClaim: original.sourceRasterClaim)
                if !result.isEmpty { await onEvidencePrepared?(page, settings, work.evidence, record.sourceRasterClaim) }
                if speculative {
                    // Display completed text before persistence finishes. Keep the
                    // write independent of navigation cancellation, but join it here
                    // so this bounded lookahead cannot create a growing write queue.
                    let persistence = Task(priority: .utility) {
                        if let diskCache {
                            guard let diskWrite,
                                  let destination = await diskCache.resolveTranslationWrite(
                                    page: page.translationCacheKey, settings: settings, token: diskWrite) else { return }
                            if let onPersistPreparedRecord {
                                await onPersistPreparedRecord(page, record, destination)
                            } else if let storePreparedTranslation {
                                await storePreparedTranslation(result, destination.key, destination.generation)
                            } else if record.sourceRasterClaim != nil || usesInjectedRecognizer {
                                try? await diskCache.storeRegions(record.regions, for: destination.key, kind: .translation,
                                                                  generation: destination.generation, sourceRasterClaim: record.sourceRasterClaim)
                            }
                        } else {
                            await storePreparedTranslation?(result, work.key, 0)
                        }
                    }
                    await onPrepared?(page, result, settings)
                    await onPreparedRecord?(page, record, settings)
                    await persistence.value
                    try Task.checkCancellation()
                }
                return record
            }
        }
    }

    /// A retained page from before a jump can finish while the new destination
    /// is still waiting on its provider. Refill the bounded lookahead slots now, so
    /// the new neighbor does not wait for another page turn or API completion.
    private func lookaheadDidFinish(key: String) {
        guard preparedPages.contains(where: { $0.key == key }), let currentDemand, !currentDemand.lease.isRetained else { return }
        prepareNext(after: currentDemand.page, settings: currentDemand.work.settings,
                    afterRecognition: currentDemand.work.dependency)
    }

    private func prepareNext(
        after page: Page, settings: ReaderTranslationSettings,
        afterRecognition: RecognitionDependency? = nil
    ) {
        // A second compressed/JPEG/text slot is useful for settled background
        // preparation. Decoding/OCR still uses the single shared image permit.
        let capacity = settings.maximumConcurrentRequests >= 3 && availableMemory() >= 2 * 1_024 * 1_024 * 1_024
            ? min(2, max(1, lookaheadLimit?(page, settings) ?? 1)) : 1
        var excluded: Set<String> = [page.translationCacheKey]
        var desired: [(Page, String)] = []
        for _ in 0..<capacity {
            guard let next = nextPageExcluding?(page, excluded) ?? nextPage?(page),
                  next.translationSourceRect == nil || next.translationSourceRect == ReaderTranslationSplitGeometry.unit,
                  excluded.insert(next.translationCacheKey).inserted else { break }
            desired.append((next, ReaderTranslationCacheIdentity.translation(page: next.translationCacheKey, settings: settings)))
        }
        while preparedPages.count > capacity { preparedPages.removeLast().cancel() }
        guard !desired.isEmpty else { return }
        preparedPages.removeAll { work in
            let matching = desired.first { $0.1 == work.key }
            if let matching, !work.source.canCoalesce(matching.0) {
                work.cancel()
                return true
            }
            let wanted = matching != nil && work.settings.maximumConcurrentRequests == settings.maximumConcurrentRequests
            guard !wanted && !canFinishLookahead(work, settings: settings) else { return false }
            work.cancel()
            return true
        }
        for (next, key) in desired where preparedPages.count < capacity {
            guard !preparedPages.contains(where: { $0.key == key }) else { continue }
            let previous = preparedPages.last?.dependency ?? afterRecognition
            preparedPages.append(makeWork(next, settings: settings, speculative: true, afterRecognition: previous))
        }
    }

    /// One already-started background page may finish even after a distant jump.
    /// Never preserve old foreground priority, changed settings, or work under pressure.
    /// This uses the existing lookahead slot, so navigation cannot grow a work queue.
    private func canFinishLookahead(_ preparedPage: PreparedPage, settings: ReaderTranslationSettings? = nil) -> Bool {
        guard preparedPage.translation != nil,
              !preparedPage.promotion.isForeground, preparedPage.lifetime.isRunning,
              availableMemory() >= TranslationImageWorkBudget.minimumHeadroom else { return false }
        guard let settings else { return true }
        return preparedPage.settings.hasSameTranslation(as: settings)
            && preparedPage.settings.maximumConcurrentRequests == settings.maximumConcurrentRequests
    }

    private func recognitionTask(
        _ page: Page, settings: ReaderTranslationSettings, skipTranslated: Bool = false,
        promotion: TranslationRequestPromotion,
        lifetime: WorkLifetime, requestHandoff: ReaderTranslationImageRequestHandoff,
        preparedImageJPEG: LockedSlot<RemoteTranslationPageImage>,
        evidence: ReaderTranslationPreparedEvidence,
        afterRecognition: RecognitionDependency? = nil,
        delivery: RecognitionDelivery,
        checkTranslationCache: Bool = true, diagnosticContext: ReaderTranslationDiagnostics.Context
    ) -> Task<[ReaderTranslationRegion]?, Error> {
        let key = ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings)
        let admission = imagePreparationGate
        // Only the built-in provider path consumes the page JPEG.
        let encodesJPEG = translator == nil && settings.shouldAttachPageImage
        return Task.detached(priority: .utility) { [diskCache, loader, recognizer, dataPrefetcher, availableMemory, retainImage,
                                                    storeRecognition, fixtureSourceRasterClaim, recognitionWindow] in
            try await ReaderTranslationDiagnostics.measure("ocr_preparation", context: diagnosticContext) {
                func recognize() async throws -> PreparedSource? {
                    try Task.checkCancellation()
                    let diskGeneration = await diskCache?.currentGeneration(settings: settings) ?? 0
                    let fixtureClaim = fixtureSourceRasterClaim?(page)
                    let current: ReaderTranslationSourceRasterClaim?
                    if recognizer != nil { current = fixtureClaim }
                    else if let image = await loader.alreadyProcessedInlineSource(page) {
                        current = .memoized(fullProcessedSource: image)
                    } else { current = nil }
                    @Sendable func completed(matching claim: ReaderTranslationSourceRasterClaim) async -> SourceRecord? {
                        guard checkTranslationCache else { return nil }
                        return try? await diskCache?.translatedRegionRecord(page: page.translationCacheKey,
                                                                           settings: settings, matching: claim)
                    }
                    if let current, let record = await completed(matching: current) {
                        try Task.checkCancellation()
                        lifetime.start()
                        return .alreadyTranslated(record)
                    }
                    let maybeCompleted: Bool
                    if checkTranslationCache, current == nil, recognizer == nil, let diskCache {
                        maybeCompleted = (try? await diskCache.containsTranslationCandidate(page: page.translationCacheKey, settings: settings)) == true
                    } else { maybeCompleted = false }
                    try Task.checkCancellation()
                    // When only the locator is known, authenticate the completed translation
                    // with the actual raster below before reading a second archive for OCR.
                    let candidate: SourceRecord?
                    if !maybeCompleted, current != nil || recognizer == nil {
                        candidate = try? await diskCache?.regionRecord(for: key, kind: .ocr)
                    } else {
                        candidate = nil
                    }
                    // A URL or an unclaimed row is not source authority. No
                    // speculative source request construction or network path.
                    // A processed inline object with memoized proof can bypass
                    // the image permit; injected fixtures provide proof explicitly.
                    if let candidate, let claim = candidate.sourceRasterClaim,
                       !settings.shouldAttachPageImage,
                       !ReaderTranslationImagePreparation.needsImage(candidate.regions, settings: settings) {
                        if current == claim {
                            try Task.checkCancellation()
                            lifetime.start()
                            ReaderTranslationDiagnostics.record("ocr_cache_hit", count: candidate.regions.count)
                            return .recognized(candidate)
                        }
                    }
                    if skipTranslated, !promotion.isForeground,
                       availableMemory() < TranslationImageWorkBudget.minimumHeadroom { return nil }
                    // A cold foreground URL must not hold the sole decode/OCR/render
                    // permit while waiting on the network. Warm only reusable compressed
                    // data here; source interception and all decoding still happen below.
                    if !skipTranslated, recognizer == nil {
                        try? await loader.prefetchData(page, priority: .high, handoff: requestHandoff)
                        try Task.checkCancellation()
                    }
                    lifetime.start()
                    if skipTranslated {
                        // Best effort: source interception/decode fallback remains in load().
                        // Deferred candidates still need source verification.
                        let needsImage = fixtureClaim == nil || candidate?.sourceRasterClaim != fixtureClaim
                            || settings.shouldAttachPageImage || candidate.map {
                                ReaderTranslationImagePreparation.needsImage($0.regions, settings: settings)
                            } != false
                        if needsImage {
                            lifetime.setPrefetching(true)
                            defer { lifetime.setPrefetching(false) }
                            if let dataPrefetcher { try? await dataPrefetcher(page) }
                            else if recognizer == nil {
                                try? await loader.prefetchData(page, priority: promotion.isForeground ? .high : .veryLow, handoff: requestHandoff)
                            }
                        }
                        try Task.checkCancellation()
                        do {
                            _ = try await afterRecognition?.ready.value()
                        } catch {
                            try Task.checkCancellation()
                            // The failed demand will discard its lookahead. Avoid starting
                            // OCR just to cancel/repeat it; nil is retried on actual demand.
                            if !promotion.isForeground, !lifetime.isRetained { return nil }
                        }
                        try Task.checkCancellation()
                    }
                    return try await recognitionWindow.withPermit(priority: .promotable(promotion)) {
                        try await prepareAndStore(candidate: candidate, fixtureClaim: fixtureClaim, maybeCompleted: maybeCompleted,
                                                  diskGeneration: diskGeneration, completed: completed(matching:))
                    }
                }

                @Sendable func prepareAndStore(
                    candidate: SourceRecord?, fixtureClaim: ReaderTranslationSourceRasterClaim?, maybeCompleted: Bool,
                    diskGeneration: UInt64, completed: @escaping @Sendable (ReaderTranslationSourceRasterClaim) async -> SourceRecord?
                ) async throws -> PreparedSource? {
                    /// Encode the provider JPEG while the decoded image is already resident
                    /// under this permit. Failure leaves the translation task's original path.
                    @Sendable func prepareJPEG(_ regions: [ReaderTranslationRegion], image: UIImage) {
                        guard encodesJPEG, !Task.isCancelled,
                              !ReaderTranslationLanguageFilter.apply(regions, settings: settings).isEmpty else { return }
                        preparedImageJPEG.store(try? autoreleasepool { try ReaderTranslationImagePreparation.preparedPage(image, evidence: evidence) })
                    }
                    // SQLite writes happen after the permit is released, so the next page's
                    // decode/OCR never waits for this page's disk I/O.
                    let loadedImageSize = LockedSlot<CGSize>()
                    let output: RecognitionOutput
                    do {
                        let queuedAt = ProcessInfo.processInfo.systemUptime
                        ReaderTranslationDiagnostics.record("image_admission_queued", code: promotion.isForeground ? 0 : 1)
                        output = try await admission.withPermit(priority: .promotable(promotion)) {
                            ReaderTranslationDiagnostics.record("image_admitted", code: promotion.isForeground ? 0 : 1,
                                elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - queuedAt) * 1000)
                            try Task.checkCancellation()
                            // Headroom can fall while downloading or waiting for the OCR permit.
                            if skipTranslated, !promotion.isForeground,
                               availableMemory() < 1_280 * 1_024 * 1_024 { return RecognitionOutput(regions: nil, persist: false) }
                            let checkStarted = ProcessInfo.processInfo.systemUptime
                            var decoded: UIImage?
                            var sourceClaim = fixtureClaim
                            if candidate?.sourceRasterClaim != nil || maybeCompleted, recognizer == nil {
                                let image = try await loader.load(page, cacheInMemory: await retainImage(page), handoff: requestHandoff)
                                decoded = image
                                loadedImageSize.store(image.size)
                                sourceClaim = .observe(fullProcessedSource: image)
                            }
                            if maybeCompleted, let sourceClaim, let completed = await completed(sourceClaim) {
                                try Task.checkCancellation()
                                return RecognitionOutput(regions: completed.regions, persist: false,
                                                         sourceRasterClaim: completed.sourceRasterClaim, alreadyTranslated: true)
                            }
                            try Task.checkCancellation()
                            let ocrRecord: SourceRecord?
                            if maybeCompleted, let sourceClaim {
                                ocrRecord = try? await diskCache?.regionRecord(for: key, kind: .ocr, matching: sourceClaim)
                                try Task.checkCancellation()
                            } else {
                                ocrRecord = candidate
                            }
                            if let sourceClaim, let ocrRecord, ocrRecord.sourceRasterClaim == sourceClaim {
                                let stored = ocrRecord.regions
                                ReaderTranslationDiagnostics.record("ocr_cache_hit", count: stored.count)
                                let needsOrder = ReaderTranslationImagePreparation.needsImage(stored, settings: settings)
                                guard needsOrder || encodesJPEG else {
                                    return RecognitionOutput(regions: stored, persist: false, sourceRasterClaim: sourceClaim)
                                }
                                let image: UIImage
                                if let decoded { image = decoded }
                                else { image = try await loader.load(page, cacheInMemory: await retainImage(page), handoff: requestHandoff) }
                                try Task.checkCancellation()
                                if recognizer == nil, #available(iOS 18.0,*),NativeMainEnsembleRenderer.enabled {
                                    guard let pixels = ReaderTranslationImagePreparation.uprightSourceImage(image).cgImage else {
                                        throw NativeCoreMLDetectorError.imageConversionFailed
                                    }
                                    try evidence.bind(original:pixels)
                                    try Task.checkCancellation()
                                }
                                let prepared = ReaderTranslationImagePreparation.apply(stored, image: image, settings: settings)
                                prepareJPEG(prepared, image: image)
                                return RecognitionOutput(regions: prepared, persist: needsOrder, sourceRasterClaim: sourceClaim)
                            }
                            ReaderTranslationDiagnostics.record("ocr_cache_miss")
                            let regions: [ReaderTranslationRegion]
                            var evidenceImage: UIImage?
                            var jpegSource: UIImage?
                            if let recognizer {
                                regions = try await recognizer(page, settings)
                                if ReaderTranslationImagePreparation.needsImage(regions, settings: settings) {
                                    evidenceImage = try await loader.load(page, cacheInMemory: await retainImage(page), handoff: requestHandoff)
                                    jpegSource = evidenceImage
                                }
                            } else {
                                guard #available(iOS 18.0, *) else { return RecognitionOutput(regions: [], persist: false) }
                                var phaseStart = checkStarted
                                let image: UIImage
                                if let decoded { image = decoded }
                                else { image = try await loader.load(page, cacheInMemory: await retainImage(page), handoff: requestHandoff) }
                                if settings.rightToLeftPanelOrder { evidenceImage = image }
                                jpegSource = image
                                loadedImageSize.store(image.size)
                                // The live Session needs the same linkage even
                                // for explicitly nonpersistent reader owners.
                                if decoded == nil {
                                    sourceClaim = .observe(fullProcessedSource: image)
                                }
                                TranslationPerformanceDiagnostics.clientPhaseCompleted(
                                    phase: "reader_image_load", segmentCount: 0,
                                    elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: phaseStart)
                                )
                                try Task.checkCancellation()
                                // Scope the normalized copy so it is released before JPEG encoding.
                                do {
                                    let pixels = try autoreleasepool { () throws -> CGImage in
                                        guard let pixels = ReaderTranslationImagePreparation.uprightSourceImage(image).cgImage else {
                                            throw NativeCoreMLDetectorError.imageConversionFailed
                                        }
                                        return pixels
                                    }
                                    phaseStart = ProcessInfo.processInfo.systemUptime
                                    try evidence.bind(original: pixels)
                                    regions = try await NativeRFOCRSourceReuse.$leasedIdentity.withValue(evidence.verifiedIdentity(for: pixels)) {
                                        try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration)
                                    }
                                    try Task.checkCancellation()
                                }
                                TranslationPerformanceDiagnostics.clientPhaseCompleted(
                                    phase: skipTranslated ? "reader_ocr_ahead" : "reader_ocr", segmentCount: regions.count,
                                    elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: phaseStart)
                                )
                            }
                            try Task.checkCancellation()
                            let prepared = evidenceImage.map { ReaderTranslationImagePreparation.apply(regions, image: $0, settings: settings) } ?? regions
                            if let jpegSource { prepareJPEG(prepared, image: jpegSource) }
                            return RecognitionOutput(regions: prepared, persist: true, sourceRasterClaim: sourceClaim)
                        }
                    } catch {
                        await delivery.resolve(.failure(error))
                        if let size = loadedImageSize.take() {
                            if let afterRecognition { _ = await afterRecognition.stored.result }
                            try? await diskCache?.storeImageSize(size, page: page.translationCacheKey, generation: diskGeneration)
                        }
                        throw error
                    }
                    // Release the prepared OCR to the provider before disk writes. The
                    // owning recognition task still joins both writes, so navigation and
                    // bounded lookahead cannot accumulate detached persistence jobs.
                    await delivery.resolve(.success(output.prepared))
                    // OCR for the next page may overlap this write. Linked pages still commit in order.
                    if let afterRecognition { _ = await afterRecognition.stored.result }
                    if let size = loadedImageSize.take() {
                        try? await diskCache?.storeImageSize(size, page: page.translationCacheKey, generation: diskGeneration)
                    }
                    if output.persist, let regions = output.regions, !Task.isCancelled {
                        if let storeRecognition { await storeRecognition(regions, key, diskGeneration) }
                        else if output.sourceRasterClaim != nil || recognizer != nil {
                            // Unclaimed injected fixtures may be inspected by the
                            // scheduling tests but cannot hit this consumer.
                            try? await diskCache?.storeRegions(regions, for: key, kind: .ocr, generation: diskGeneration,
                                                              sourceRasterClaim: output.sourceRasterClaim)
                        }
                    }
                    return output.prepared
                }
                do {
                    let result = try await recognize()
                    await delivery.resolve(.success(result))
                    return result?.record.regions
                } catch {
                    await delivery.resolve(.failure(error))
                    throw error
                }
            }
        }
    }

    func cancel(preservingRecognitionFor page: Page? = nil) {
        generation = UUID()
        let preservesDemand = page.map { requested in
            currentDemand?.work.pageKey == requested.translationCacheKey && currentDemand?.work.source.canCoalesce(requested) == true
        } ?? false
        // Replacing only the current observer leaves its neighbors useful,
        // including OCR-only work and preparation not yet at the provider.
        // Keep the same bounded slots, subject to the existing memory floor.
        let preservesNeighbor = preservesDemand && availableMemory() >= TranslationImageWorkBudget.minimumHeadroom
        if let currentDemand, preservesDemand {
            currentDemand.lease.retain()
            // Keep the existing slots: moving demand into a lookahead
            // slot discarded an already-running neighbor on every handoff.
            // The next observer adopts demand directly; OFF still cancels all slots.
        } else {
            currentDemand?.work.cancel()
            currentDemand = nil
        }
        if page != nil {
            for work in preparedPages where canFinishLookahead(work) { work.lifetime.retain() }
        }
        operation?.cancel()
        operation = nil
        // A page turn promotes both OCR and API work. OFF/exit/settings changes
        // pass nil and stop all work. A different destination can leave one
        // started, unpromoted lookahead to finish and persist its result.
        preparedPages.removeAll { work in
            if let page, work.pageKey == page.translationCacheKey, !work.source.canCoalesce(page) {
                work.cancel()
                return true
            }
            guard page == nil || (!preservesNeighbor && page?.translationCacheKey != work.pageKey && !canFinishLookahead(work)) else { return false }
            work.cancel()
            return true
        }
        // Navigation restores the foreground reservation: retain its destination
        // preferentially and at most one old neighbor, never two background APIs.
        if !preservesDemand, preparedPages.count > 1 {
            let kept = preparedPages.first(where: { $0.pageKey == page?.translationCacheKey }) ?? preparedPages[0]
            preparedPages.filter { $0.key != kept.key }.forEach { $0.cancel() }
            preparedPages = [kept]
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
                guard let data = Data(base64Encoded: base64), let image = UIImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                try TranslationImageWorkBudget.shared.checkHeadroom(decodedBytes: TranslationImageWorkBudget.decodedBytes(in: data))
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
            }
            try TranslationImageWorkBudget.shared.checkHeadroom(decodedBytes: bytes)
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
