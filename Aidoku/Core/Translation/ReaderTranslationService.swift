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
    var sourceOrientation: BrowserOCRSourceOrientation = .unknown
    var sourceSingleVerticalColumn: Bool?
    var translationReuseIdentity: NativeTranslationReuseIdentity?
    var sfxEnclosedBackground: Bool? = nil // Positive evidence protects text; nil means not sampled.

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
            sourcePolygon: polygon.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
        )
    }
}

enum ReaderTranslationGeometry {
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
    private(set) var lastPhaseMilliseconds: [String: Double] = [:]

    func recognize(image: CGImage, tier: IPhoneOCRModelTier) async throws -> [ReaderTranslationRegion] {
        try await recognize(image: image, configuration: ReaderOCRConfiguration(modelTier: tier))
    }

    func recognize(image: CGImage, configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        try await gate.withPermit {
            try await self.recognizeSerial(image: image, configuration: configuration)
        }
    }

    private func recognizeSerial(image: CGImage, configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        if loadedConfiguration?.modelTier != configuration.modelTier ||
            loadedConfiguration?.detectorMaximumSide != configuration.detectorMaximumSide ||
            loadedConfiguration?.recognizerMaximumWidth != configuration.recognizerMaximumWidth {
            await pipeline?.purgeResources()
            pipeline = NativeCoreMLOCRPipeline(
                modelTier: configuration.modelTier, detectorMaximumSide: configuration.detectorMaximumSide,
                recognizerMaximumWidth: configuration.recognizerMaximumWidth
            )
            loadedConfiguration = configuration
        }
        guard let pipeline else { return [] }
        // Pass the complete source once. The detector owns aspect-preserving
        // resize and maps detections back to original-image coordinates.
        ReaderTranslationDiagnostics.record("ocr_begin")
        let result = try await pipeline.recognize(
            image: image, requestID: UUID().uuidString,
            confidenceThreshold: configuration.confidenceThreshold
        )
        try Task.checkCancellation()
        ReaderTranslationDiagnostics.record("ocr_end", count: result.lines.count)
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
                sourceSingleVerticalColumn: line.singleVerticalColumn
            )
        }
        let balloonStart = ProcessInfo.processInfo.systemUptime
        let joined = ReaderTranslationBalloonMerger.apply(regions, image: image, sourceLines: lines.map { .init(polygon: $0.polygon, text: $0.text, orientation: $0.orientation) })
        lastPhaseMilliseconds["balloonMerge"] = (ProcessInfo.processInfo.systemUptime - balloonStart) * 1000
        try Task.checkCancellation()
        return joined
    }

    func purge() async {
        try? await gate.withPermit { await self.purgeSerial() }
    }

    private func purgeSerial() async {
        await pipeline?.purgeResources()
        pipeline = nil
        loadedConfiguration = nil
    }
}

actor ReaderTranslationService {
    static let shared = ReaderTranslationService()
    private let client: RemoteTranslating
    private var service: TranslationService?
    private let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 16)

    init(client: RemoteTranslating = RemoteTranslationClient()) {
        self.client = client
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
                    bounds: settings.filterSFXWithLLM && bounds.allSatisfy { $0.isFinite && (0...1).contains($0) } ? bounds : nil))
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

    func translate(
        regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings, image: UIImage? = nil, onProgress: Progress? = nil,
        priority: TranslationRequestPriority = .foreground
    ) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let regions = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        guard !regions.isEmpty else { try await onProgress?([]); return [] }
        let service = try translationService()
        let concurrency = max(1, min(BoundedTranslationBatchExecutor.allowedMaximumConcurrentRequests, settings.maximumConcurrentRequests))
        await limiter.setMaximumConcurrentRequests(concurrency)
        try Task.checkCancellation()
        let imageJPEG = try settings.includePageImage ? image.map(ReaderTranslationImagePreparation.translationJPEG) : nil
        let plans = Self.plans(regions: regions, settings: settings).map { plan in
            var request = plan.request
            request.imageJPEG = imageJPEG
            return NativeTranslationBatchPlan(request: request, inputIndicesBySegmentID: plan.inputIndicesBySegmentID)
        }
        let progress = try ReaderTranslationProgress(regions: regions, plans: plans, configuration: settings.configuration)
        // Clear translations whose language/model/prompt identity no longer matches before publishing any batch.
        try await onProgress?(await progress.snapshot())
        _ = try await BoundedTranslationBatchExecutor.translate(
            plans.map(\.request), configuration: settings.configuration, service: service,
            // The scheduler reserves foreground capacity until a lookahead is promoted.
            maximumConcurrentRequests: concurrency,
            priority: priority,
            onBatchCompleted: { index, result in
                try Task.checkCancellation()
                let snapshot = await progress.complete(index: index, result: result)
                try await onProgress?(snapshot)
            }
        )
        try Task.checkCancellation()
        return await progress.snapshot()
    }

    func clearCache() async throws {
        try await service?.purgeCache()
    }
}

/// Applies the original progressive identity policy without sharing mutable batches between page requests.
private actor ReaderTranslationProgress {
    private let regions: [ReaderTranslationRegion]
    private let plans: [NativeTranslationBatchPlan]
    private let expected: [Int: NativeTranslationReuseIdentity]
    private var completed: [Int: NativeTranslationReuseValue] = [:]

    init(regions: [ReaderTranslationRegion], plans: [NativeTranslationBatchPlan], configuration: RemoteTranslationConfiguration) throws {
        self.regions = regions
        self.plans = plans
        var expected: [Int: NativeTranslationReuseIdentity] = [:]
        for plan in plans {
            for (id, identity) in try NativeTranslationReuseIdentity.identitiesBySegmentID(configuration: configuration, request: plan.request) {
                if let index = plan.inputIndicesBySegmentID[id] { expected[index] = identity }
            }
        }
        self.expected = expected
    }

    func complete(index: Int, result: RemoteTranslationBatchResult) -> [ReaderTranslationRegion] {
        for segment in result.translations {
            if let inputIndex = plans[index].inputIndicesBySegmentID[segment.id], let identity = expected[inputIndex] {
                completed[inputIndex] = NativeTranslationReuseValue(identity: identity, translatedText: segment.text)
            }
        }
        return snapshot()
    }

    func snapshot() -> [ReaderTranslationRegion] {
        let items = regions.enumerated().map { $0.element.overlayItem(index: $0.offset, imageSize: CGSize(width: 1, height: 1)) }
        let merged = NativeProgressiveTranslationOverlay.merge(items: items, expectedIdentities: expected, completedTranslations: completed)
        return zip(regions, merged).compactMap { region, item in
            var value = region
            value.translation = item.translatedText
            value.translationReuseIdentity = item.translationReuseIdentity
            return value
        }
    }
}
