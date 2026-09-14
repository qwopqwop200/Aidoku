// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLSharedLoadAccess<Value: Sendable>: Sendable {
    let value: Value
    /// True only for the caller that created the shared load task. A recognizer
    /// joining preparation reports zero model-load time in OCR diagnostics.
    let initiatedLoad: Bool
}

/// An explicit preparation lifetime. Frame cancellation intentionally leaves
/// this revision alone so a newer frame can reuse an in-flight specialization;
/// OCR OFF and resource purge invalidate it before any store is cleared.
@available(iOS 18.0, *)
final class NativeCoreMLPreparationRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func token() -> UInt64 {
        lock.withLock { value }
    }

    func invalidate() {
        lock.withLock { value &+= 1 }
    }

    func requireCurrent(_ token: UInt64) throws {
        try Task.checkCancellation()
        let isCurrent = lock.withLock { value == token }
        guard isCurrent else { throw CancellationError() }
    }
}

/// Coalesces one Core ML function specialization per key. Frame cancellation
/// does not cancel this reusable work; only the explicit resource-purge
/// boundary cancels pending tasks and advances the revision.
@available(iOS 18.0, *)
actor NativeCoreMLSharedLoadCoordinator<
    Key: Hashable & Sendable,
    Value: Sendable
> {
    private struct Pending: Sendable {
        let revision: UInt64
        let token: UInt64
        let task: Task<Value, Error>
    }

    private var revision: UInt64 = 0
    private var nextToken: UInt64 = 0
    private var pending: [Key: Pending] = [:]

    func load(
        for key: Key,
        using loader: @escaping @Sendable () async throws -> Value
    ) async throws -> NativeCoreMLSharedLoadAccess<Value> {
        let issuedRevision = revision
        let entry: Pending
        let initiatedLoad: Bool
        if let existing = pending[key],
           existing.revision == issuedRevision {
            entry = existing
            initiatedLoad = false
        } else {
            nextToken &+= 1
            let task = Task { try await loader() }
            entry = Pending(
                revision: issuedRevision,
                token: nextToken,
                task: task
            )
            pending[key] = entry
            initiatedLoad = true
        }

        let value: Value
        do {
            value = try await entry.task.value
        } catch {
            if pending[key]?.token == entry.token {
                pending[key] = nil
            }
            throw error
        }
        guard revision == issuedRevision else {
            throw CancellationError()
        }
        if pending[key]?.token == entry.token {
            pending[key] = nil
        }
        return NativeCoreMLSharedLoadAccess(
            value: value,
            initiatedLoad: initiatedLoad
        )
    }

    func purge() {
        revision &+= 1
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll(keepingCapacity: false)
    }
}

@available(iOS 18.0, *)
protocol NativeCoreMLDetecting: Sendable {
    func prepare(
        sourceWidth: Int,
        sourceHeight: Int
    ) async throws

    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult

    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult

    func cancelCurrent()
    func cancelPreparation()
    func purgeResources() async
}

@available(iOS 18.0, *)
extension NativeCoreMLDetector: NativeCoreMLDetecting {}

@available(iOS 18.0, *)
extension NativeCoreMLDetecting {
    func prepare(
        sourceWidth: Int,
        sourceHeight: Int
    ) async throws {}
    func cancelPreparation() {}

    /// Non-native test and fallback detectors retain full postprocessing. The
    /// production Core ML detector overrides this requirement to materialize
    /// and decode a safe dirty-scope output window.
    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult {
        _ = recognitionScopes
        return try await detect(
            frame: frame,
            requestID: requestID,
            configuration: configuration,
            cancellationCheck: cancellationCheck
        )
    }
}

@available(iOS 18.0, *)
protocol NativeCoreMLRecognizing: Sendable {
    func prepare() async throws
    func prepareIdlePreservingDemandCapacity() async throws

    func recognize(
        frame: NativeOCRRGBAFrame,
        regions: [NativeCoreMLRecognitionRegion],
        requestID: String,
        confidenceThreshold: Double,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLRecognitionResult

    func cancelCurrent()
    func cancelPreparation()
    func purgeResources() async
}

@available(iOS 18.0, *)
extension NativeCoreMLRecognizer: NativeCoreMLRecognizing {}

@available(iOS 18.0, *)
extension NativeCoreMLRecognizing {
    func prepare() async throws {}
    func prepareIdlePreservingDemandCapacity() async throws {}
    func cancelPreparation() {}
}

@available(iOS 18.0, *)
private final class NativeCoreMLOCRGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        value &+= 1
        let issued = value
        lock.unlock()
        return issued
    }

    func cancelCurrent() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    func cancel(ifCurrent generation: UInt64) {
        lock.lock()
        if value == generation {
            value &+= 1
        }
        lock.unlock()
    }

    func requireCurrent(_ issued: UInt64) throws {
        try Task.checkCancellation()
        lock.lock()
        let isCurrent = value == issued
        lock.unlock()
        guard isCurrent else { throw CancellationError() }
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLOCRLine: Equatable, Sendable {
    let polygon: [CGPoint]
    let text: String
    let score: Double
    let orientation: BrowserOCRSourceOrientation
    /// Aspect-ratio estimates may be revised using neighbouring glyphs. An
    /// explicit writing-direction hint must survive fragment grouping.
    let orientationIsEstimated: Bool
    /// Page-space tile bounds, supplied by tiled readers after offsetting the
    /// polygon. The merger uses interior edges to identify truncated retries.
    let sourceTileBounds: CGRect?

    init(
        polygon: [CGPoint],
        text: String,
        score: Double,
        orientation: BrowserOCRSourceOrientation,
        orientationIsEstimated: Bool = false,
        sourceTileBounds: CGRect? = nil
    ) {
        self.polygon = polygon
        self.text = text
        self.score = score
        self.orientation = orientation
        self.orientationIsEstimated = orientationIsEstimated
        self.sourceTileBounds = sourceTileBounds
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLOCRPipelineDiagnostics: Equatable, Sendable {
    let backend: String
    let frameConversionMilliseconds: Double
    let detectionProvider: String
    let recognitionProvider: String
    let detectionComputeUnits: String
    let recognitionComputeUnits: String
    let detectionModel: String
    let recognitionModel: String
    let detection: NativeCoreMLDetectionDiagnostics
    let recognition: NativeCoreMLRecognitionDiagnostics?
}

@available(iOS 18.0, *)
struct NativeCoreMLOCRResult: Equatable, Sendable {
    let requestID: String
    let width: Int
    let height: Int
    let lines: [NativeCoreMLOCRLine]
    let frameConversionMilliseconds: Double
    let detectionMilliseconds: Double
    let recognitionMilliseconds: Double
    let totalMilliseconds: Double
    let detectedBoxes: Int
    let selectedBoxes: Int
    let diagnostics: NativeCoreMLOCRPipelineDiagnostics
}

@available(iOS 18.0, *)
enum NativeOCRScopeGeometry {
    static func bounds(for polygon: [CGPoint]) -> CGRect? {
        guard let minimumX = polygon.map(\.x).min(),
              let maximumX = polygon.map(\.x).max(),
              let minimumY = polygon.map(\.y).min(),
              let maximumY = polygon.map(\.y).max(),
              minimumX.isFinite,
              maximumX.isFinite,
              minimumY.isFinite,
              maximumY.isFinite,
              maximumX > minimumX,
              maximumY > minimumY
        else {
            return nil
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        ).standardized
    }

    static func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.standardized.intersection(right.standardized)
        guard !intersection.isNull,
              !intersection.isEmpty,
              intersection.width.isFinite,
              intersection.height.isFinite
        else {
            return 0
        }
        let area = intersection.width * intersection.height
        return area.isFinite && area > 0 ? area : 0
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLOCRModelProfile: Equatable, Sendable {
    let tier: IPhoneOCRModelTier
    let detectorResourceName: String
    let recognizerResourceName: String
    let dictionaryResourceName: String
    let expectedDictionaryCharacterCount: Int
    let postprocessConfiguration: NativeCoreMLDBPostprocessConfiguration

    static func profile(for tier: IPhoneOCRModelTier) -> Self {
        switch tier {
        case .medium:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Medium-DetShapes",
                recognizerResourceName: "PP-OCRv6-Medium-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_medium_rec_character_dict",
                expectedDictionaryCharacterCount: 18_709,
                postprocessConfiguration: .production
            )
        case .small:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Small-DetShapes",
                recognizerResourceName: "PP-OCRv6-Small-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_small_rec_character_dict",
                expectedDictionaryCharacterCount: 18_709,
                postprocessConfiguration: .production
            )
        case .tiny:
            Self(
                tier: tier,
                detectorResourceName: "PP-OCRv6-Tiny-DetShapes",
                recognizerResourceName: "PP-OCRv6-Tiny-RecWidths",
                dictionaryResourceName:
                    "ppocrv6_tiny_rec_character_dict",
                expectedDictionaryCharacterCount: 6_905,
                postprocessConfiguration: .tiny
            )
        }
    }
}

/// Runs both PP-OCRv6 model stages through native Core ML. The
/// detector's source-space quads are passed directly to the recognizer, so no
/// PNG/base64/WebKit copy exists on the primary iPhone path.
@available(iOS 18.0, *)
enum NativeCoreMLOCRStage: Equatable, Sendable {
    case detecting
    case recognizing(regionCount: Int)
}

@available(iOS 18.0, *)
enum NativeCoreMLModelPreparationStage: Equatable, Sendable {
    case detectorReady
    case recognizerReady
}

@available(iOS 18.0, *)
final class NativeCoreMLOCRPipeline: @unchecked Sendable {
    typealias FrameConverter = @Sendable (CGImage) async
        -> NativeOCRRGBAFrame?

    private let detector: any NativeCoreMLDetecting
    private let recognizer: any NativeCoreMLRecognizing
    private let frameConverter: FrameConverter
    private let postprocessConfiguration:
        NativeCoreMLDBPostprocessConfiguration
    private let generation = NativeCoreMLOCRGeneration()

    init(
        detector: any NativeCoreMLDetecting = NativeCoreMLDetector(),
        recognizer: any NativeCoreMLRecognizing = NativeCoreMLRecognizer(),
        postprocessConfiguration:
            NativeCoreMLDBPostprocessConfiguration = .production,
        frameConverter: @escaping FrameConverter = { image in
            await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image)
        }
    ) {
        self.detector = detector
        self.recognizer = recognizer
        self.postprocessConfiguration = postprocessConfiguration
        self.frameConverter = frameConverter
    }

    convenience init(
        modelTier: IPhoneOCRModelTier,
        detectorMaximumSide: Int =
            IPhoneOCRSettings.defaultDetectorMaximumSide,
        recognizerMaximumWidth: Int =
            IPhoneOCRSettings.defaultRecognizerMaximumWidth,
        bundle: Bundle = .main
    ) {
        let profile = NativeCoreMLOCRModelProfile.profile(for: modelTier)
        self.init(
            detector: NativeCoreMLDetector(
                bundle: bundle,
                modelResourceName: profile.detectorResourceName,
                maximumSide: detectorMaximumSide
            ),
            recognizer: NativeCoreMLRecognizer(
                bundle: bundle,
                modelResourceName: profile.recognizerResourceName,
                dictionaryResourceName: profile.dictionaryResourceName,
                expectedDictionaryCharacterCount:
                    profile.expectedDictionaryCharacterCount,
                maximumRecognitionWidth: recognizerMaximumWidth
            ),
            postprocessConfiguration: profile.postprocessConfiguration
        )
    }

    /// Moves the bounded Core ML model specialization cost off the first OCR
    /// frame. Preparation has an explicit lifetime separate from OCR frame
    /// generations: `cancelCurrent()` only invalidates obsolete frame work,
    /// while production owners cancel and await speculative preparation before
    /// admitting inference. Completed resident models remain reusable. Each
    /// underlying model store coalesces same-function loads, and
    /// `purgeResources()` is the explicit boundary that clears them.
    ///
    /// Initializes the two bundled OCR model packages sequentially. The
    /// recognizer prepares its bounded common-width working set; later unusual
    /// crop widths can still demand-load their exact function.
    func prepare(
        sourceWidth: Int,
        sourceHeight: Int,
        stageHandler: (@Sendable (NativeCoreMLModelPreparationStage) async -> Void)? = nil
    ) async throws {
        try await detector.prepare(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        await stageHandler?(.detectorReady)
        try await recognizer.prepare()
        await stageHandler?(.recognizerReady)
    }

    /// Best-effort post-result specialization. The production recognizer
    /// refuses to evict actual-demand functions and retains spare capacity for
    /// the next unseen width; low-memory configurations may intentionally do
    /// no work.
    func prepareRecognizerIdlePreservingDemandCapacity() async throws {
        try await recognizer.prepareIdlePreservingDemandCapacity()
    }

    func cancelCurrent() {
        // Invalidate the whole detector -> recognizer transaction first. This
        // makes cancellation sticky even when it lands immediately before the
        // recognizer creates its own stage-local generation.
        generation.cancelCurrent()
        detector.cancelCurrent()
        recognizer.cancelCurrent()
    }

    /// Stops preparation that has not yet crossed a model-store admission
    /// point. Already resident functions remain available to later OCR.
    func cancelPreparation() {
        detector.cancelPreparation()
        recognizer.cancelPreparation()
    }

    func purgeResources() async {
        cancelPreparation()
        cancelCurrent()
        async let detectorPurge: Void = detector.purgeResources()
        async let recognizerPurge: Void = recognizer.purgeResources()
        _ = await (detectorPurge, recognizerPurge)
    }

    func recognize(
        image: CGImage,
        requestID: String,
        confidenceThreshold: Double,
        recognitionScope: CGRect? = nil
    ) async throws -> NativeCoreMLOCRResult {
        try await recognize(
            image: image,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            recognitionScopes: recognitionScope.map { [$0] }
        )
    }

    func recognize(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        confidenceThreshold: Double,
        recognitionScope: CGRect? = nil
    ) async throws -> NativeCoreMLOCRResult {
        try await recognize(
            frame: frame,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            recognitionScopes: recognitionScope.map { [$0] }
        )
    }

    /// Runs the exact full-frame detector once, then admits recognition only
    /// for boxes whose bounds intersect one of the dirty content scopes. This
    /// matches display invalidation so a changed tail of a long line cannot
    /// remove the old line without re-recognizing its replacement.
    /// The single-scope overload above preserves the containing-app API.
    func recognize(
        image: CGImage,
        requestID: String,
        confidenceThreshold: Double,
        recognitionScopes: [CGRect]?
    ) async throws -> NativeCoreMLOCRResult {
        try await performRecognition(
            providedFrame: nil,
            image: image,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            recognitionScopes: recognitionScopes
        )
    }

    /// Entry point for callers that already own canonical RGBA pixels. It is
    /// also the parity seam used by tests; no converter is invoked here.
    func recognize(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        confidenceThreshold: Double,
        recognitionScopes: [CGRect]?,
        stageHandler: (@Sendable (NativeCoreMLOCRStage) -> Void)? = nil
    ) async throws -> NativeCoreMLOCRResult {
        try await performRecognition(
            providedFrame: frame,
            image: nil,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            recognitionScopes: recognitionScopes,
            stageHandler: stageHandler
        )
    }

    private func performRecognition(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        requestID: String,
        confidenceThreshold: Double,
        recognitionScopes: [CGRect]?,
        stageHandler: (@Sendable (NativeCoreMLOCRStage) -> Void)? = nil
    ) async throws -> NativeCoreMLOCRResult {
        let issuedGeneration = generation.begin()
        let started = Self.nowMilliseconds()
        let cancellationCheck: @Sendable () throws -> Void = {
            [generation] in
            try generation.requireCurrent(issuedGeneration)
        }
        return try await withTaskCancellationHandler {
            try cancellationCheck()
            let frame: NativeOCRRGBAFrame
            let frameConversionMilliseconds: Double
            if let providedFrame {
                frame = providedFrame
                frameConversionMilliseconds = 0
            } else if let image {
                let conversionStarted = Self.nowMilliseconds()
                guard let converted = await frameConverter(image) else {
                    throw NativeCoreMLDetectorError.imageConversionFailed
                }
                frame = converted
                frameConversionMilliseconds = max(
                    0,
                    Self.nowMilliseconds() - conversionStarted
                )
            } else {
                throw NativeCoreMLDetectorError.imageConversionFailed
            }
            try cancellationCheck()
            let frameBounds = CGRect(
                x: 0,
                y: 0,
                width: frame.width,
                height: frame.height
            )
            let standardizedScopes = recognitionScopes?.compactMap {
                scope -> CGRect? in
                guard scope.origin.x.isFinite, scope.origin.y.isFinite,
                      scope.size.width.isFinite,
                      scope.size.height.isFinite
                else {
                    return nil
                }
                let clipped = scope.standardized.intersection(frameBounds)
                return clipped.isNull || clipped.isEmpty ? nil : clipped
            }
            stageHandler?(.detecting)
            let detection = try await detector.detect(
                frame: frame,
                requestID: requestID,
                configuration: postprocessConfiguration,
                // The detector model still receives the complete frame. Its
                // CPU output materialization and recognition admission may be
                // limited to dirty scopes for a partial refresh.
                recognitionScopes: standardizedScopes,
                cancellationCheck: cancellationCheck
            )
            try cancellationCheck()
            guard detection.requestID == requestID else {
                throw CancellationError()
            }

            let regions = detection.boxes.enumerated().compactMap {
                index, box -> NativeCoreMLRecognitionRegion? in
                guard box.polygon.count == 4,
                      recognitionScopes == nil || standardizedScopes?.contains(where: { scope in
                          guard let bounds = NativeOCRScopeGeometry.bounds(
                              for: box.polygon
                          ) else {
                              return false
                          }
                          return NativeOCRScopeGeometry.intersectionArea(
                              bounds,
                              scope
                          ) > 0
                      }) == true
                else {
                    return nil
                }
                return NativeCoreMLRecognitionRegion(
                    sourceIndex: index,
                    polygon: box.polygon
                )
            }

            let recognition: NativeCoreMLRecognitionResult?
            if regions.isEmpty {
                recognition = nil
            } else {
                try cancellationCheck()
                stageHandler?(.recognizing(regionCount: regions.count))
                let value = try await recognizer.recognize(
                    frame: frame,
                    regions: regions,
                    requestID: requestID,
                    confidenceThreshold: min(
                        max(confidenceThreshold, 0),
                        1
                    ),
                    cancellationCheck: cancellationCheck
                )
                try cancellationCheck()
                guard value.requestID == requestID else {
                    throw CancellationError()
                }
                recognition = value
            }

            let lines = (recognition?.regions ?? [])
                .sorted { $0.sourceIndex < $1.sourceIndex }
                .map { region in
                    NativeCoreMLOCRLine(
                        polygon: region.polygon,
                        text: region.text,
                        score: region.confidence,
                        orientation: Self.orientation(
                            for: region.polygon
                        ),
                        orientationIsEstimated: true
                    )
                }
            let recognitionMilliseconds =
                recognition?.diagnostics.totalMilliseconds ?? 0
            return NativeCoreMLOCRResult(
                requestID: requestID,
                width: detection.width,
                height: detection.height,
                lines: lines,
                frameConversionMilliseconds: frameConversionMilliseconds,
                detectionMilliseconds:
                    detection.diagnostics.totalMilliseconds,
                recognitionMilliseconds: recognitionMilliseconds,
                totalMilliseconds: Self.nowMilliseconds() - started,
                detectedBoxes: detection.boxes.count,
                selectedBoxes: regions.count,
                diagnostics: NativeCoreMLOCRPipelineDiagnostics(
                    backend: "coreml",
                    frameConversionMilliseconds:
                        frameConversionMilliseconds,
                    detectionProvider:
                        detection.diagnostics.executionProvider,
                    recognitionProvider:
                        recognition?.diagnostics.executionProvider
                            ?? "not-run",
                    detectionComputeUnits:
                        detection.diagnostics.computeUnits,
                    recognitionComputeUnits:
                        recognition?.diagnostics.computeUnits
                            ?? "not-run",
                    detectionModel: detection.diagnostics.modelName,
                    recognitionModel:
                        recognition?.diagnostics.modelName
                            ?? NativeCoreMLRecognizer.modelResourceName,
                    detection: detection.diagnostics,
                    recognition: recognition?.diagnostics
                )
            )
        } onCancel: { [generation] in
            // A late handler from superseded request A must never invalidate
            // request B. The active detector/recognizer have their own
            // token-scoped handlers; explicit owner cancellation still uses
            // `cancelCurrent()` above to invalidate all stages immediately.
            generation.cancel(ifCurrent: issuedGeneration)
        }
    }

    private static func orientation(
        for polygon: [CGPoint]
    ) -> BrowserOCRSourceOrientation {
        guard let bounds = bounds(for: polygon) else {
            return .unknown
        }
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return .unknown }
        return height >= width * 1.25 ? .vertical : .horizontal
    }

    private static func bounds(for polygon: [CGPoint]) -> CGRect? {
        NativeOCRScopeGeometry.bounds(for: polygon)
    }

    private static func nowMilliseconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }
}
