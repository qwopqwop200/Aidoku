import UIKit
import CoreGraphics
import Foundation

enum ReaderTranslationGeometry {
    // UIView derives bounds from frame/center arithmetic. Fractional webtoon
    // heights can differ by a few ULPs without any actual viewport change.
    static func sameViewport(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.000_001 && abs(lhs.height - rhs.height) < 0.000_001
    }

    static func displayRect(_ rect: CGRect, imageSize: CGSize, bounds: CGRect, aspectFit: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        var canvas = bounds
        if aspectFit {
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            canvas = CGRect(
                x: bounds.midX - imageSize.width * scale / 2,
                y: bounds.midY - imageSize.height * scale / 2,
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
        }
        return CGRect(
            x: canvas.minX + rect.minX * canvas.width,
            y: canvas.minY + rect.minY * canvas.height,
            width: rect.width * canvas.width,
            height: rect.height * canvas.height
        )
    }
}

actor ReaderTranslationService {
    static let shared = ReaderTranslationService(warmsOCROnReaderOpen: true)
    private let client: RemoteTranslating
    private let warmsOCROnReaderOpen: Bool
    private var service: TranslationService?
    private let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 16)

    private var activeReaders: Set<UUID> = []
    private var metadataGeneration: UInt64 = 0
    private var metadataTasks: [UUID: Task<[ReaderTranslationRegion], Error>] = [:]
    private var metadataWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    // Pause before reader OCR/debounce starts, and retain the pause between pages.
    // Multiple reader owners cannot accidentally resume each other's metadata work.
    // Readers mark themselves active while visible or background translation is on,
    // so this is also the reader-open hook that warms the OCR models.
    func setReaderActive(_ active: Bool, owner: UUID) {
        if active {
            guard activeReaders.insert(owner).inserted else { return }
            metadataGeneration &+= 1
            for task in metadataTasks.values { task.cancel() }
            if warmsOCROnReaderOpen {
                // The page pipeline owns its resident models (loaded once per session).
                if #available(iOS 18.0, *), ReaderTranslationSettings().shouldProcessReaderPages {
                    Task(priority: .utility) { await ReaderTranslationV2Service.shared.prewarm() }
                }
                let configuration = ReaderTranslationSettings().configuration
                Task(priority: .utility) { [client] in await client.prepare(configuration: configuration) }
            }
        } else {
            activeReaders.remove(owner)
            guard activeReaders.isEmpty else { return }
            let waiters = metadataWaiters
            metadataWaiters.removeAll()
            for waiter in waiters.values { waiter.resume() }
        }
    }

    private func waitForMetadataAdmission() async throws {
        while !activeReaders.isEmpty {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { metadataWaiters[id] = continuation }
                }
            } onCancel: {
                Task { await self.cancelMetadataWaiter(id) }
            }
        }
        try Task.checkCancellation()
    }

    private func cancelMetadataWaiter(_ id: UUID) {
        metadataWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func translateMetadata(
        regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
        priority: MetadataTranslationPriority = .mangaTitle
    ) async throws -> [ReaderTranslationRegion] {
        while true {
            try await waitForMetadataAdmission()
            guard activeReaders.isEmpty else { continue }
            let generation = metadataGeneration
            let id = UUID()
            let task = Task { try await self.translateMetadataText(regions: regions, settings: settings, priority: priority) }
            metadataTasks[id] = task
            do {
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                metadataTasks.removeValue(forKey: id)
                try Task.checkCancellation()
                return result
            } catch {
                metadataTasks.removeValue(forKey: id)
                try Task.checkCancellation()
                // Only reader preemption retries. A disappearing/cancelled caller
                // exits immediately, and ordinary provider failures are preserved.
                guard task.isCancelled, generation != metadataGeneration else { throw error }
            }
        }
    }

    /// Metadata has no page image or visual roles. Keep its admission and
    /// cancellation policy above, but never enter the mandatory page route.
    private func translateMetadataText(
        regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
        priority: MetadataTranslationPriority
    ) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let sourceOwners = regions
        let regions = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        let eligibleIDs = Set(regions.map(\.id))
        guard !regions.isEmpty else {
            return ReaderTranslationLanguageFilter.preservingExcludedSource(
                original: sourceOwners, translated: [], eligibleIDs: eligibleIDs)
        }
        let plans = NativeTranslationBatchPlanner.makeBatches(
            candidates: regions.enumerated().map {
                NativeTranslationBatchCandidate(inputIndex: $0.offset,
                    segment: .init(id: $0.element.id, text: $0.element.source))
            },
            sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage)
        let service = try translationService()
        let concurrency = max(1, min(BoundedTranslationBatchExecutor.allowedMaximumConcurrentRequests,
            settings.maximumConcurrentRequests))
        await limiter.setMaximumConcurrentRequests(concurrency)
        let progress = try ReaderTranslationProgress(regions: regions, plans: plans, configuration: settings.configuration)
        let results = try await BoundedTranslationBatchExecutor.translate(
            plans.map(\.request), configuration: settings.configuration, service: service,
            maximumConcurrentRequests: concurrency, priority: .metadata(priority))
        for (index, result) in results.enumerated() {
            _ = await progress.complete(index: index, result: result)
        }
        try Task.checkCancellation()
        return ReaderTranslationLanguageFilter.preservingExcludedSource(
            original: sourceOwners, translated: await progress.snapshot(), eligibleIDs: eligibleIDs)
    }

    init(client: RemoteTranslating = RemoteTranslationClient(), warmsOCROnReaderOpen: Bool = false) {
        self.client = client
        self.warmsOCROnReaderOpen = warmsOCROnReaderOpen
    }

    private func translationService() throws -> TranslationService {
        if let service { return service }
        // Request-level batch reuse stays in memory; the reader's durable cache stores completed pages separately.
        let cache = try TranslationCache(configuration: .init(diskEnabled: false, maxSizeMiB: 10))
        let service = TranslationService(
            client: client, cache: cache,
            providerRequestLimiter: limiter
        )
        self.service = service
        return service
    }

    private static func mandatoryPageSettings(_ settings: ReaderTranslationSettings) -> ReaderTranslationSettings {
        var result = settings
        result.includePageImage = true
        result.filterSFXWithLLM = true
        result.filterBackgroundWithLLM = true
        return result
    }

    func clearCache() async throws {
        try await service?.purgeCache()
    }

    /// V2 S5: one page request through the live provider client, sharing the
    /// reader's provider concurrency limit and mandatory page settings.
    @available(iOS 18.0, *)
    func translateV2(
        _ blocks: [V2Block], pageSize: CGSize, settings: ReaderTranslationSettings, imageJPEG: Data?,
        priority: TranslationRequestPriority = .foreground
    ) async throws -> [V2Block] {
        try Task.checkCancellation()
        let settings = Self.mandatoryPageSettings(settings)
        let configuration = settings.configuration
        _ = try configuration.validatedEndpoint()
        let concurrency = max(1, min(3, settings.maximumConcurrentRequests))
        await limiter.setMaximumConcurrentRequests(concurrency)
        let client = client
        return try await limiter.withPermit(priority: priority) {
            try await V2Translation.translate(
                blocks, pageSize: pageSize, client: client, configuration: configuration,
                sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage,
                imageJPEG: settings.includePageImage ? imageJPEG : nil)
        }
    }
}

/// Applies completed metadata batches under the request's reuse identity.
actor ReaderTranslationProgress {
    private var regions: [ReaderTranslationRegion]
    private let inputIndices: [[String: Int]]
    private let expected: [Int: NativeTranslationReuseIdentity]

    init(regions: [ReaderTranslationRegion], plans: [NativeTranslationBatchPlan], configuration: RemoteTranslationConfiguration) throws {
        self.regions = regions
        self.inputIndices = plans.map(\.inputIndicesBySegmentID)
        var expected: [Int: NativeTranslationReuseIdentity] = [:]
        for plan in plans {
            for (id, identity) in try NativeTranslationReuseIdentity.identitiesBySegmentID(configuration: configuration, request: plan.request) {
                if let index = plan.inputIndicesBySegmentID[id] {
                    expected[index] = identity
                }
            }
        }
        self.expected = expected
        // Keep a reusable translation only while its identity still matches.
        for index in regions.indices {
            guard regions[index].translationRecoveryFailure == nil,
                  let old = regions[index].translationReuseIdentity,
                  let identity = expected[index], regions[index].translation != nil,
                  old == identity || old.canRemainVisibleWhileRefreshing(expected: identity) else {
                self.regions[index].translation = nil
                self.regions[index].translationReuseIdentity = nil
                self.regions[index].keepsClassifiedSFXSource = false
                continue
            }
        }
    }

    func complete(index: Int, result: RemoteTranslationBatchResult) -> [ReaderTranslationRegion] {
        for segment in result.translations {
            if let inputIndex = inputIndices[index][segment.id], let identity = expected[inputIndex] {
                regions[inputIndex].applyTranslation(segment)
                regions[inputIndex].translationReuseIdentity = identity
                regions[inputIndex].translationRecoveryFailure = nil
            }
        }
        return regions
    }

    func snapshot() -> [ReaderTranslationRegion] {
        regions
    }
}
