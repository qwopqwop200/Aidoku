import UIKit
import CoreGraphics
import Foundation

struct ReaderTranslationRegion: Equatable, Sendable {
    let id: String
    let rect: CGRect // Normalized image coordinates, top-left origin.
    let source: String
    var translation: String?
    var polygon: [CGPoint] = [] // Normalized; retain the detector/merger geometry.
    var confidence: Double = 1
    var sourceImageAspectRatio: Double? = nil
    var translationOrder: Int? = nil
    var translationOrderVersion: String? = nil
    var sourceOrientation: BrowserOCRSourceOrientation = .unknown
    var sourceSingleVerticalColumn: Bool?
    var translationReuseIdentity: NativeTranslationReuseIdentity?
    var auxiliaryInkRects: [CGRect] = [] // Normalized suppressed-ruby ink; not layout bounds.
    var auxiliaryInkPolygons: [[CGPoint]] = []

    /// If translation adds no information, preserve the original lettering.
    /// This avoids opaque boxes over numbers, punctuation, unchanged names,
    /// and artwork that OCR mistook for a letter. Changed output still paints.
    var preservesOriginalText: Bool {
        guard let translation else { return false }
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return !original.isEmpty && original == translation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func overlayItems(_ regions: [Self], imageSize: CGSize) -> [BrowserOverlayItem] {
        regions.enumerated().compactMap { index, region in
            region.preservesOriginalText ? nil : region.overlayItem(index: index, imageSize: imageSize)
        }
    }

    func overlayItem(index: Int, imageSize: CGSize) -> BrowserOverlayItem {
        BrowserOverlayItem(
            stableRegionID: UInt64(index),
            rect: CGRect(x: rect.minX * imageSize.width, y: rect.minY * imageSize.height,
                         width: rect.width * imageSize.width, height: rect.height * imageSize.height),
            sourceText: source, translatedText: translation, confidence: confidence,
            sourceOrientation: sourceOrientation, sourceSingleVerticalColumn: sourceSingleVerticalColumn,
            translationReuseIdentity: translationReuseIdentity,
            sourcePolygon: polygon.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) },
            auxiliaryInkRects: auxiliaryInkRects.map { CGRect(x: $0.minX * imageSize.width, y: $0.minY * imageSize.height,
                width: $0.width * imageSize.width, height: $0.height * imageSize.height) },
            auxiliaryInkPolygons: auxiliaryInkPolygons.map { $0.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) } }
        )
    }
}

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

@available(iOS 18.0, *)
actor ReaderOCRService {
    static let shared = ReaderOCRService()
    private let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private var pipeline: NativeCoreMLOCRPipeline?
    private var loadedConfiguration: ReaderOCRConfiguration?
    private var pipelineEpoch: UInt64 = 0
    private var warmUpTask: Task<Void, Never>?
    private var warmUpID: UUID?
    private(set) var lastPhaseMilliseconds: [String: Double] = [:]

    func recognize(image: CGImage, tier: IPhoneOCRModelTier) async throws -> [ReaderTranslationRegion] {
        try await recognize(image: image, configuration: ReaderOCRConfiguration(modelTier: tier))
    }

    func recognize(image: CGImage, configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        let queuedAt = ProcessInfo.processInfo.systemUptime
        return try await gate.withPermit {
            TranslationPerformanceFileLog.record(.ocrQueue, fields: [
                .elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: queuedAt)
            ])
            return try await self.recognizeSerial(image: image, configuration: configuration)
        }
    }

    private static func sameModels(_ lhs: ReaderOCRConfiguration?, _ rhs: ReaderOCRConfiguration) -> Bool {
        lhs?.modelTier == rhs.modelTier && lhs?.detectorMaximumSide == rhs.detectorMaximumSide &&
            lhs?.recognizerMaximumWidth == rhs.recognizerMaximumWidth
    }

    /// Callers hold `gate`: replacement awaits the old pipeline's purge.
    private func currentPipeline(for configuration: ReaderOCRConfiguration) async -> NativeCoreMLOCRPipeline {
        if let pipeline, Self.sameModels(loadedConfiguration, configuration) { return pipeline }
        await pipeline?.purgeResources()
        let created = NativeCoreMLOCRPipeline(
            modelTier: configuration.modelTier, detectorMaximumSide: configuration.detectorMaximumSide,
            recognizerMaximumWidth: configuration.recognizerMaximumWidth
        )
        pipeline = created
        loadedConfiguration = configuration
        pipelineEpoch &+= 1
        return created
    }

    /// Loads the OCR models for `configuration` in the background so the first
    /// page does not pay detector + recognizer model load. Idempotent (one
    /// in-flight warm-up; resident models return immediately), low priority,
    /// and it never holds `gate` while loading: real OCR coalesces with, and
    /// escalates, the shared model loads. Skipped under memory pressure; it
    /// loads only the models the first OCR frame would load anyway.
    func warmUp(configuration: ReaderOCRConfiguration) {
        guard warmUpTask == nil,
              ReaderTranslationSession.processAvailableMemory() >= TranslationImageWorkBudget.minimumHeadroom
        else { return }
        let id = UUID()
        warmUpID = id
        warmUpTask = Task(priority: .utility) {
            await self.performWarmUp(configuration: configuration)
            self.finishWarmUp(id)
        }
    }

    private func finishWarmUp(_ id: UUID) {
        guard warmUpID == id else { return }
        warmUpTask = nil
        warmUpID = nil
    }

    func cancelWarmUp() {
        warmUpTask?.cancel()
        warmUpTask = nil
        warmUpID = nil
    }

    private func performWarmUp(configuration: ReaderOCRConfiguration) async {
        let target: NativeCoreMLOCRPipeline
        if let pipeline, Self.sameModels(loadedConfiguration, configuration) {
            target = pipeline
        } else {
            guard let created = try? await gate.withPermit({
                await self.currentPipeline(for: configuration)
            }) else { return }
            target = created
        }
        let epoch = pipelineEpoch
        guard !Task.isCancelled else { return }
        do {
            try await target.warmUp()
            ReaderTranslationDiagnostics.record("ocr_warmup_end")
        } catch {
            ReaderTranslationDiagnostics.record("ocr_warmup_cancelled")
        }
        // A purge or configuration change during warm-up orphaned `target`;
        // release anything it admitted instead of waiting for deallocation.
        if epoch != pipelineEpoch || pipeline !== target {
            await target.purgeResources()
        }
    }

    private func recognizeSerial(image: CGImage, configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let pipeline = await currentPipeline(for: configuration)
        // Pass the complete source once. The detector owns aspect-preserving
        // resize and maps detections back to original-image coordinates.
        ReaderTranslationDiagnostics.record("ocr_begin")
        let result = try await pipeline.recognize(
            image: image, requestID: UUID().uuidString,
            confidenceThreshold: configuration.confidenceThreshold,
            detectorConfiguration: configuration.detectorPostprocessConfiguration
        )
        try Task.checkCancellation()
        ReaderTranslationDiagnostics.record("ocr_end", count: result.lines.count)
        TranslationPerformanceFileLog.record(.ocrFrame, fields: [.elapsedMilliseconds: result.frameConversionMilliseconds])
        TranslationPerformanceFileLog.record(.ocrDetection, fields: [.elapsedMilliseconds: result.detectionMilliseconds])
        TranslationPerformanceFileLog.record(.ocrRecognition, fields: [.elapsedMilliseconds: result.recognitionMilliseconds])
        let postprocessStartedAt = ProcessInfo.processInfo.systemUptime
        let lines = result.lines
        var phases: [String: Double] = ["native": result.totalMilliseconds, "ocrPasses": 1]
        let wordStart = ProcessInfo.processInfo.systemUptime
        let wordCandidates = NativeOCRTextLineMerger.latinWordCandidates(lines)
        let recognizedWords: Set<String>
        if wordCandidates.isEmpty {
            recognizedWords = []
        } else {
            recognizedWords = await ReaderOCRWordBoundaryResolver.recognizedWords(in: wordCandidates)
        }
        try Task.checkCancellation()
        phases["wordBoundary"] = (ProcessInfo.processInfo.systemUptime - wordStart) * 1000
        let mergeStart = ProcessInfo.processInfo.systemUptime
        let separator = lines.count >= 2 ? NativeOCRRegionSeparator(image: image) : nil
        try Task.checkCancellation()
        // Cache even inconclusive colour samples: each candidate rectangle is sampled once.
        var inkSamples: [NSValue: [Double]] = [:]
        func ink(_ rect: CGRect) -> [Double] {
            let key = NSValue(cgRect: rect)
            if let cached = inkSamples[key] { return cached }
            let sample = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: rect)
            let value = sample.map { [$0.0, $0.1, $0.2] } ?? []
            inkSamples[key] = value
            return value
        }
        let merged = NativeOCRTextLineMerger.merge(
            lines, imageWidth: image.width, imageHeight: image.height, recognizedLatinWords: recognizedWords,
            separationCheck: { a, b, orientation in
                if orientation == .vertical {
                    let first = ink(a), second = ink(b)
                    if first.count == 3, second.count == 3 {
                        if zip(first, second).contains(where: { abs($0 - $1) >= 70 }) { return true }
                        // Outlined captions on artwork have observable gutters,
                        // even when recognition drops every quotation mark.
                        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                        if gap >= min(a.width, b.width) * 0.3 { return true }
                    }
                }
                return separator?.separates(a, b, orientation: orientation) ?? false
            }
        )
        try Task.checkCancellation()
        phases["mergeAndSeparator"] = (ProcessInfo.processInfo.systemUptime - mergeStart) * 1000
        lastPhaseMilliseconds = phases
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let regions: [ReaderTranslationRegion] = merged.enumerated().compactMap { index, line in
            let rect = line.boundingRect.intersection(imageBounds)
            let source = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rect.isNull, !rect.isEmpty, !source.isEmpty else { return nil }
            return ReaderTranslationRegion(
                id: "region-\(index)",
                rect: CGRect(
                    x: rect.minX / imageBounds.width, y: rect.minY / imageBounds.height,
                    width: rect.width / imageBounds.width, height: rect.height / imageBounds.height
                ),
                source: source,
                polygon: line.poly.map { CGPoint(x: $0.x / imageBounds.width, y: $0.y / imageBounds.height) },
                confidence: line.score, sourceImageAspectRatio: Double(image.width) / Double(image.height), sourceOrientation: line.sourceOrientation,
                sourceSingleVerticalColumn: line.singleVerticalColumn,
                auxiliaryInkRects: line.auxiliaryInkRects.map { $0.intersection(imageBounds) }.filter { !$0.isNull && !$0.isEmpty }.map {
                    CGRect(x: $0.minX / imageBounds.width, y: $0.minY / imageBounds.height,
                           width: $0.width / imageBounds.width, height: $0.height / imageBounds.height)
                },
                auxiliaryInkPolygons: line.auxiliaryInkPolygons.map { $0.map { CGPoint(x: $0.x / imageBounds.width, y: $0.y / imageBounds.height) } }
            )
        }
        let balloonStart = ProcessInfo.processInfo.systemUptime
        let joined = ReaderTranslationBalloonMerger.apply(regions, image: image, sourceLines: lines.map { .init(polygon: $0.polygon, text: $0.text, orientation: $0.orientation) })
        lastPhaseMilliseconds["balloonMerge"] = (ProcessInfo.processInfo.systemUptime - balloonStart) * 1000
        TranslationPerformanceFileLog.record(.ocrPostprocess, fields: [
            .segments: Double(joined.count),
            .elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: postprocessStartedAt)
        ])
        try Task.checkCancellation()
        return joined
    }

    func purge() async {
        cancelWarmUp()
        try? await gate.withPermit { await self.purgeSerial() }
    }

    private func purgeSerial() async {
        await pipeline?.purgeResources()
        pipeline = nil
        loadedConfiguration = nil
        pipelineEpoch &+= 1
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
    // Readers mark themselves active only while automatic translation is on,
    // so this is also the reader-open hook that warms the OCR models.
    func setReaderActive(_ active: Bool, owner: UUID) {
        if active {
            guard activeReaders.insert(owner).inserted else { return }
            metadataGeneration &+= 1
            for task in metadataTasks.values { task.cancel() }
            if warmsOCROnReaderOpen {
                Self.requestOCRWarmUp()
                let configuration = ReaderTranslationSettings().configuration
                Task(priority: .utility) { [client] in await client.prepare(configuration: configuration) }
            }
        } else {
            activeReaders.remove(owner)
            guard activeReaders.isEmpty else { return }
            if warmsOCROnReaderOpen, #available(iOS 18.0, *) {
                Task(priority: .utility) { await ReaderOCRService.shared.cancelWarmUp() }
            }
            let waiters = metadataWaiters
            metadataWaiters.removeAll()
            for waiter in waiters.values { waiter.resume() }
        }
    }

    /// Off the main thread and low priority; the OCR service ignores the
    /// request when models are resident, a warm-up is running, or memory is low.
    private static func requestOCRWarmUp() {
        guard #available(iOS 18.0, *) else { return }
        let settings = ReaderTranslationSettings()
        guard settings.automaticallyTranslate else { return }
        let configuration = settings.ocrConfiguration
        Task(priority: .utility) { await ReaderOCRService.shared.warmUp(configuration: configuration) }
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
            let task = Task { try await self.translate(regions: regions, settings: settings, priority: .metadata(priority)) }
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

    static func plans(regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> [NativeTranslationBatchPlan] {
        var candidates = regions.enumerated().map {
            let rect = $0.element.rect
            let bounds = [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
            return NativeTranslationBatchCandidate(inputIndex: $0.offset,
                segment: .init(id: $0.element.id, text: $0.element.source,
                    bounds: (settings.filterSFXWithLLM || settings.filterBackgroundWithLLM) && bounds.allSatisfy { $0.isFinite && (0...1).contains($0) } ? bounds : nil))
        }
        let ranks = regions.compactMap(\.translationOrder)
        if settings.rightToLeftPanelOrder, ranks.count == regions.count, Set(ranks).count == ranks.count {
            candidates.sort { ranks[$0.inputIndex] < ranks[$1.inputIndex] }
        }
        let plans = NativeTranslationBatchPlanner.makeBatches(candidates: candidates,
            sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage, context: [], glossary: [],
            includesNeighborContext: true)
        return plans.map { plan in
            var request = plan.request
            request.filtersSFX = settings.filterSFXWithLLM ? true : nil
            request.filtersBackground = settings.filterBackgroundWithLLM ? true : nil
            return NativeTranslationBatchPlan(request: request, inputIndicesBySegmentID: plan.inputIndicesBySegmentID)
        }
    }

    static func requests(regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) throws -> [RemoteTranslationRequest] {
        let regions = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        let requests = plans(regions: regions, settings: settings).map(\.request)
        for request in requests { try request.validate() }
        return requests
    }

    typealias Progress = @Sendable ([ReaderTranslationRegion]) async throws -> Void

    /// `onPartialProgress` (optional) receives snapshots that include
    /// provisional streamed segments of unfinished batches. It never runs
    /// after this call returns, and completed batches always win over it.
    func translate(
        regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings, image: UIImage? = nil,
        preparedImageJPEG: Data? = nil, onProgress: Progress? = nil,
        priority: TranslationRequestPriority = .foreground,
        onPartialProgress: Progress? = nil
    ) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let regions = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        guard !regions.isEmpty else { try await onProgress?([]); return [] }
        let service = try translationService()
        let attachesImage = settings.shouldAttachPageImage
        // A remembered text-only fallback sends no image and must not retain
        // the image-upload concurrency cap merely because the preference is on.
        let concurrency = max(1, min(attachesImage ? 2 : BoundedTranslationBatchExecutor.allowedMaximumConcurrentRequests,
                                     settings.maximumConcurrentRequests))
        await limiter.setMaximumConcurrentRequests(concurrency)
        try Task.checkCancellation()
        let imageJPEG = try attachesImage
            ? (preparedImageJPEG ?? image.map(ReaderTranslationImagePreparation.translationJPEG)) : nil
        guard !attachesImage || imageJPEG != nil else {
            throw RemoteTranslationError.invalidRequest("Page image attachment is enabled, but no page image was provided.")
        }
        let imageDataURL = imageJPEG.map { "data:image/jpeg;base64," + $0.base64EncodedString() }
        let plans = Self.plans(regions: regions, settings: settings).map { plan in
            var request = plan.request
            request.imageJPEG = imageJPEG
            request.preparedImageDataURL = imageDataURL
            return NativeTranslationBatchPlan(request: request, inputIndicesBySegmentID: plan.inputIndicesBySegmentID)
        }
        let progress = try ReaderTranslationProgress(regions: regions, plans: plans, configuration: settings.configuration)
        // Clear translations whose language/model/prompt identity no longer matches before publishing any batch.
        try await onProgress?(await progress.snapshot())
        // Streamed segments arrive synchronously on the network queue. One
        // ordered consumer applies them, so a partial never overtakes a later
        // partial and never replaces a completed batch.
        var partialConsumer: Task<Void, Never>?
        var partialHandler: BoundedTranslationBatchExecutor.BatchPartialHandler?
        var partialContinuation: AsyncStream<(Int, [RemoteTranslatedSegment])>.Continuation?
        if let onPartialProgress {
            let (stream, continuation) = AsyncStream<(Int, [RemoteTranslatedSegment])>.makeStream()
            partialContinuation = continuation
            partialHandler = { index, segments in continuation.yield((index, segments)) }
            partialConsumer = Task {
                for await (index, segments) in stream {
                    guard !Task.isCancelled else { break }
                    guard let snapshot = await progress.partial(index: index, segments: segments) else { continue }
                    guard !Task.isCancelled else { break }
                    try? await onPartialProgress(snapshot)
                }
            }
        }
        defer {
            partialContinuation?.finish()
            partialConsumer?.cancel()
        }
        _ = try await BoundedTranslationBatchExecutor.translate(
            plans.map(\.request), configuration: settings.configuration, service: service,
            // The scheduler reserves foreground capacity until a lookahead is promoted.
            maximumConcurrentRequests: concurrency,
            priority: priority,
            onBatchCompleted: { index, result in
                try Task.checkCancellation()
                let snapshot = await progress.complete(index: index, result: result)
                try await onProgress?(snapshot)
            },
            onBatchPartial: partialHandler
        )
        partialContinuation?.finish()
        partialConsumer?.cancel()
        await partialConsumer?.value
        try Task.checkCancellation()
        return await progress.snapshot()
    }

    func clearCache() async throws {
        try await service?.purgeCache()
    }
}

/// Applies the original progressive identity policy without sharing mutable batches between page requests.
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
                if let index = plan.inputIndicesBySegmentID[id] { expected[index] = identity }
            }
        }
        self.expected = expected
        // Validate existing display-only reuse once. Subsequent batches only
        // replace their own regions, retaining OCR geometry without rebuilding
        // two full overlay arrays on every progressive publication.
        for index in regions.indices {
            guard let old = regions[index].translationReuseIdentity,
                  let identity = expected[index], regions[index].translation != nil,
                  old == identity || old.canRemainVisibleWhileRefreshing(expected: identity) else {
                self.regions[index].translation = nil
                self.regions[index].translationReuseIdentity = nil
                continue
            }
        }
    }

    private var completedBatches = Set<Int>()

    /// Applies provisional streamed segments of an unfinished batch. Returns
    /// nil when nothing changed or the batch has already completed.
    func partial(index: Int, segments: [RemoteTranslatedSegment]) -> [ReaderTranslationRegion]? {
        guard inputIndices.indices.contains(index), !completedBatches.contains(index) else { return nil }
        var changed = false
        for segment in segments {
            if let inputIndex = inputIndices[index][segment.id], let identity = expected[inputIndex],
               regions[inputIndex].translation != segment.text || regions[inputIndex].translationReuseIdentity != identity {
                regions[inputIndex].translation = segment.text
                regions[inputIndex].translationReuseIdentity = identity
                changed = true
            }
        }
        return changed ? regions : nil
    }

    func complete(index: Int, result: RemoteTranslationBatchResult) -> [ReaderTranslationRegion] {
        completedBatches.insert(index)
        for segment in result.translations {
            if let inputIndex = inputIndices[index][segment.id], let identity = expected[inputIndex] {
                regions[inputIndex].translation = segment.text
                regions[inputIndex].translationReuseIdentity = identity
            }
        }
        return regions
    }

    func snapshot() -> [ReaderTranslationRegion] {
        regions
    }
}
