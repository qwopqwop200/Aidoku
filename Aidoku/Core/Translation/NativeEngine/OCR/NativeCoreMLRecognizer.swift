// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
@preconcurrency import CoreML
import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#endif

@available(iOS 18.0, *)
enum NativeCoreMLRecognitionPhotometricMode: String, Sendable {
    case original
    case luminanceContrast
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionRegion: Equatable, Sendable {
    let sourceIndex: Int
    let polygon: [CGPoint]
    let samplingPolygon: [CGPoint]?
    let isThinFinePrintRecovery: Bool
    let finePrintRetryPolygons: [[CGPoint]]
    let useProvidedOrder: Bool
    let minimumSequenceWidth: Int
    let recognitionColumnEvidence: NativeOCRDetectorColumnEvidence?
    let photometricMode: NativeCoreMLRecognitionPhotometricMode

    init(
        sourceIndex: Int, polygon: [CGPoint], samplingPolygon: [CGPoint]? = nil,
        isThinFinePrintRecovery: Bool = false, finePrintRetryPolygons: [[CGPoint]] = [],
        useProvidedOrder: Bool = false, minimumSequenceWidth: Int = 0,
        recognitionColumnEvidence: NativeOCRDetectorColumnEvidence? = nil,
        photometricMode: NativeCoreMLRecognitionPhotometricMode = .original
    ) {
        self.sourceIndex = sourceIndex
        self.polygon = polygon
        self.samplingPolygon = samplingPolygon
        self.isThinFinePrintRecovery = isThinFinePrintRecovery
        self.finePrintRetryPolygons = finePrintRetryPolygons
        self.useProvidedOrder = useProvidedOrder
        self.minimumSequenceWidth = minimumSequenceWidth
        self.recognitionColumnEvidence = recognitionColumnEvidence
        self.photometricMode = photometricMode
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognizedRegion: Equatable, Sendable {
    let sourceIndex: Int
    let polygon: [CGPoint]
    let text: String
    let confidence: Double
    var tokenObservations: [NativeCoreMLCTCTokenObservation] = []
}

@available(iOS 18.0, *)
struct NativeCoreMLCTCTokenObservation: Equatable, Sendable {
    let text: String
    let confidence: Double
    var emissionSpan: NativeCoreMLCTCEmissionSpan? = nil
}

/// Sequence coordinates from the existing greedy path, not source glyph bounds.
/// A repeated label extends its half-open span; a blank separates equal labels.
@available(iOS 18.0, *)
struct NativeCoreMLCTCEmissionSpan: Equatable, Sendable {
    let steps: Range<Int>
    let timeStepCount: Int
    let precedingBlankSteps: Int
}

@available(iOS 18.0, *)
struct NativeCoreMLGreedyRecognition: Equatable, Sendable {
    let text: String
    let confidence: Double
    /// Nil means unavailable; an empty array is an observed blank CTC path.
    var tokenObservations: [NativeCoreMLCTCTokenObservation]? = nil
}

/// Explicit full-bank observation of an existing pass, before acceptance.
/// There is no row limit or retained bank here. A bounded external sink must
/// throw on overflow/failure, never silently truncate or claim completeness.
/// The sink serializes callbacks across all tasks sharing this page scope.
@available(iOS 18.0, *)
final class NativeCoreMLRecognitionObservations: @unchecked Sendable {
    @TaskLocal static var current: NativeCoreMLRecognitionObservations?

    struct Request: Equatable, Sendable {
        let requestID: String
        let generation: UInt64
        let callerConfidenceThreshold: Double
        let appliedConfidenceThreshold: Double
    }

    enum AdmissionReason: String, Equatable, Sendable {
        case accepted, empty, belowThreshold, nonFiniteConfidence
    }

    struct Decoded: Equatable, Sendable {
        let request: Request
        let region: NativeCoreMLRecognitionRegion
        let finalText: String
        let finalConfidence: Double
        let tokenObservations: [NativeCoreMLCTCTokenObservation]
        /// Nil means not retained by the earlier pass that populated this
        /// cache entry. It never means an empty greedy decode.
        let greedyObservation: NativeCoreMLGreedyRecognition?
        let cacheHit: Bool
        let admitted: Bool
        let reason: AdmissionReason
    }

    enum Event: Equatable, Sendable {
        /// Actual invocation, including a real zero-crop call. A missing event
        /// is unobserved, never an inferred empty pass.
        case began(request: Request, requestedRegions: Int)
        case requested(request: Request, region: NativeCoreMLRecognitionRegion)
        case decoded(Decoded)
        /// Successful pass only. Errors/cancellation/sink failures do not emit
        /// this certificate; an enclosing page must also complete before seal.
        case finished(request: Request, decodedRegions: Int)
    }

    private let lock = NSLock()
    private let observer: @Sendable (Event) throws -> Void

    init(observer: @escaping @Sendable (Event) throws -> Void) {
        self.observer = observer
    }

    func record(_ event: Event) throws {
        try lock.withLock { try observer(event) }
    }
}

@available(iOS 18.0, *)
private struct NativeCoreMLRecognitionObservationPass: Sendable {
    let sink: NativeCoreMLRecognitionObservations
    let request: NativeCoreMLRecognitionObservations.Request

    func began(requestedRegions: Int) throws {
        try sink.record(.began(request: request, requestedRegions: requestedRegions))
    }

    func finished(decodedRegions: Int) throws {
        try sink.record(.finished(request: request, decodedRegions: decodedRegions))
    }
}

/// Explicit in-memory diagnostic events for an existing recognition pass.
/// Nothing is logged or persisted automatically. A test harness may opt in to
/// inspect rejection causes without rerunning the detector or recognizer.
@available(iOS 18.0, *)
enum NativeCoreMLRecognitionAuditEvent: Sendable {
    /// Every detector polygon admitted to this recognizer, before crop planning.
    case requested(requestID: String, region: NativeCoreMLRecognitionRegion)
    /// Includes empty/low-confidence decodes and cache hits before acceptance.
    case decoded(
        requestID: String,
        region: NativeCoreMLRecognitionRegion,
        text: String,
        confidence: Double,
        threshold: Double,
        cacheHit: Bool
    )
}

/// Execution accounting is separate from committed recognition diagnostics.
/// In particular, a failed/cancelled attempt is not a successful prediction.
@available(iOS 18.0, *)
struct NativeCoreMLRecognitionExecutionSnapshot: Equatable, Sendable {
    let requestID: String
    let generation: UInt64
    var predictionAttempts = 0
    var attemptedCrops = 0
    var attemptedBatchSlots = 0
    var discardedLookaheadChunks = 0
    var discardedPlannedCrops = 0
    var discardedCompletedPredictions = 0
    var discardedCompletedCrops = 0
}

/// Created only for an explicitly observed recognition generation. Concurrent
/// prediction tasks update scalars; the final callback runs once, outside lock.
@available(iOS 18.0, *)
final class NativeCoreMLRecognitionExecutionCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NativeCoreMLRecognitionExecutionSnapshot
    private var finished = false
    private let observer: @Sendable (NativeCoreMLRecognitionExecutionSnapshot) -> Void

    init(requestID: String, generation: UInt64,
         observer: @escaping @Sendable (NativeCoreMLRecognitionExecutionSnapshot) -> Void) {
        value = .init(requestID: requestID, generation: generation)
        self.observer = observer
    }

    func attempted(crops: Int, batchSlots: Int) {
        lock.withLock {
            guard !finished else { return }
            value.predictionAttempts += 1
            value.attemptedCrops += crops
            value.attemptedBatchSlots += batchSlots
        }
    }

    func discardedLookahead(plannedCrops: Int, completedPredictions: Int, completedCrops: Int) {
        lock.withLock {
            guard !finished else { return }
            value.discardedLookaheadChunks += 1
            value.discardedPlannedCrops += plannedCrops
            value.discardedCompletedPredictions += completedPredictions
            value.discardedCompletedCrops += completedCrops
        }
    }

    func finish() {
        let snapshot: NativeCoreMLRecognitionExecutionSnapshot? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return value
        }
        if let snapshot { observer(snapshot) }
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionDiagnostics: Equatable, Sendable {
    let requestID: String
    let generation: UInt64
    let backend: String
    let executionProvider: String
    let computeUnits: String
    let modelName: String
    let inputFeatureName: String
    let outputFeatureName: String
    let inputShape: [Int]
    let outputShape: [Int]
    let requestedRegions: Int
    let predictedRegions: Int
    /// Regions whose complete rectified float tensor exactly matched a prior
    /// prediction from this recognizer/model instance.
    let cacheHitRegions: Int
    private(set) var acceptedRegions: Int
    let skippedInvalidRegions: Int
    let modelWasAlreadyLoaded: Bool
    let modelLoadMilliseconds: Double
    let modelFunctionSequence: [String]
    let modelFunctionLoadSequence: [String]
    let modelFunctionLoads: Int
    let modelFunctionLoadMilliseconds: Double
    let preprocessingMilliseconds: Double
    let predictionMilliseconds: Double
    let decodingMilliseconds: Double
    let totalMilliseconds: Double

    func withAcceptedRegions(_ count: Int) -> Self {
        var result = self
        result.acceptedRegions = count
        return result
    }

    func addingRecovery(_ recovery: Self, acceptedCount: Int,
                        includingRecoveryRequests: Bool = false) -> Self {
        Self(
            requestID: requestID,
            generation: generation,
            backend: backend,
            executionProvider: executionProvider,
            computeUnits: computeUnits,
            modelName: modelName,
            inputFeatureName: inputFeatureName,
            outputFeatureName: outputFeatureName,
            inputShape: inputShape,
            outputShape: outputShape,
            requestedRegions: requestedRegions + (includingRecoveryRequests ? recovery.requestedRegions : 0),
            predictedRegions: predictedRegions + recovery.predictedRegions,
            cacheHitRegions: cacheHitRegions + recovery.cacheHitRegions,
            acceptedRegions: acceptedCount,
            skippedInvalidRegions: skippedInvalidRegions + recovery.skippedInvalidRegions,
            modelWasAlreadyLoaded: modelWasAlreadyLoaded,
            modelLoadMilliseconds: modelLoadMilliseconds + recovery.modelLoadMilliseconds,
            modelFunctionSequence: modelFunctionSequence + recovery.modelFunctionSequence,
            modelFunctionLoadSequence: modelFunctionLoadSequence + recovery.modelFunctionLoadSequence,
            modelFunctionLoads: modelFunctionLoads + recovery.modelFunctionLoads,
            modelFunctionLoadMilliseconds: modelFunctionLoadMilliseconds + recovery.modelFunctionLoadMilliseconds,
            preprocessingMilliseconds: preprocessingMilliseconds + recovery.preprocessingMilliseconds,
            predictionMilliseconds: predictionMilliseconds + recovery.predictionMilliseconds,
            decodingMilliseconds: decodingMilliseconds + recovery.decodingMilliseconds,
            totalMilliseconds: totalMilliseconds + recovery.totalMilliseconds)
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionResult: Equatable, Sendable {
    let requestID: String
    let regions: [NativeCoreMLRecognizedRegion]
    let diagnostics: NativeCoreMLRecognitionDiagnostics
}

@available(iOS 18.0, *)
enum NativeCoreMLRecognizerError: Error, Equatable, LocalizedError {
    case modelResourceMissing
    case modelLoadFailed(String)
    case dictionaryResourceMissing
    case dictionaryMalformed(line: Int)
    case dictionaryCharacterCount(expected: Int, actual: Int)
    case imageConversionFailed
    case modelInputCreationFailed
    case modelOutputMissing
    case modelOutputShape(expected: [Int], actual: [Int])
    case unsupportedModelOutputType
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelResourceMissing:
            NSLocalizedString("OCR_ERROR_MODEL_MISSING")
        case .modelLoadFailed:
            NSLocalizedString("OCR_ERROR_MODEL_LOAD")
        case .dictionaryResourceMissing, .dictionaryMalformed, .dictionaryCharacterCount:
            NSLocalizedString("OCR_ERROR_DICTIONARY")
        case .imageConversionFailed, .modelInputCreationFailed:
            NSLocalizedString("OCR_ERROR_IMAGE")
        case .modelOutputMissing, .modelOutputShape, .unsupportedModelOutputType:
            NSLocalizedString("OCR_ERROR_OUTPUT")
        case .predictionFailed:
            NSLocalizedString("OCR_ERROR_PREDICTION")
        }
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionPrediction: @unchecked Sendable {
    let outputs: [MLMultiArray]
    let modelWasLoaded: Bool
    let modelLoadMilliseconds: Double
}

@available(iOS 18.0, *)
protocol NativeCoreMLRecognitionPredicting: AnyObject, Sendable {
    var modelName: String { get }
    var inputFeatureName: String { get }
    var outputFeatureName: String { get }

    func predict(
        input: MLMultiArray
    ) async throws -> NativeCoreMLRecognitionPrediction

    func preferredBucketOrder(availableWidths: [Int]) async -> [Int]
    func prepare(
        variants: [NativeCoreMLRecognitionModelVariant]
    ) async throws
    func prepare(
        variants: [NativeCoreMLRecognitionModelVariant],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws
    func prepareNonEvicting(
        variants: [NativeCoreMLRecognitionModelVariant],
        minimumFreeResidentSlots: Int,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws
    func purgeResources() async
}

@available(iOS 18.0, *)
extension NativeCoreMLRecognitionPredicting {
    func preferredBucketOrder(availableWidths: [Int]) async -> [Int] {
        Array(Set(availableWidths)).sorted(by: >)
    }

    func prepare(
        variants: [NativeCoreMLRecognitionModelVariant]
    ) async throws {}

    func prepare(
        variants: [NativeCoreMLRecognitionModelVariant],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        try cancellationCheck()
        try await prepare(variants: variants)
        try cancellationCheck()
    }

    func prepareNonEvicting(
        variants: [NativeCoreMLRecognitionModelVariant],
        minimumFreeResidentSlots: Int,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        _ = variants
        _ = minimumFreeResidentSlots
        try cancellationCheck()
    }

    func purgeResources() async {}
}

@available(iOS 18.0, *)
private final class NativeCoreMLModelPredictor:
    NativeCoreMLRecognitionPredicting
{
    private struct ModelHandle: @unchecked Sendable {
        let model: MLModel
    }

    private struct ModelAccess: @unchecked Sendable {
        let handle: ModelHandle
        let wasLoaded: Bool
        let loadMilliseconds: Double
        let revision: UInt64
        let isPrepared: Bool
    }

    private struct LoadedModel: @unchecked Sendable {
        let handle: ModelHandle
        let loadMilliseconds: Double
    }

    /// A multifunction package shares weights on disk, but each loaded
    /// `MLModel` function has a substantial private runtime footprint.
    /// Batch-one and batch-four variants are separate `MLModel` handles even
    /// though their disk weights are shared, so the owner supplies a strict
    /// two- or three-function resident limit based on device memory.
    private actor ModelStore {
        private let asset: MLModelAsset
        private let assetURL: URL
        private let maximumResidentModels: Int
        private let usesDynamicModel: Bool
        private var models: [NativeCoreMLRecognitionModelVariant: ModelHandle]
            = [:]
        private var preparedVariants: Set<NativeCoreMLRecognitionModelVariant>
            = []
        /// Idle-only handles stay resident but are always eviction candidates
        /// before a function selected by an actual crop prediction.
        private var speculativeVariants: Set<
            NativeCoreMLRecognitionModelVariant
        > = []
        /// Oldest first, newest last.
        private var recency: [NativeCoreMLRecognitionModelVariant] = []
        private var revision: UInt64 = 0
        // A Core ML handle can serialize independent dynamic shapes internally.
        // Acquire a second copy only while a real prediction is already active.
        private var activePredictions = 0
        private var replicaInUse = false
        private var replica: ModelStore?
        private var replicaFailed = false
        private var replicaUse: UInt64 = 0
        private var idleExpiry: Task<Void, Never>?
        private var replicaIdleDeadline: ContinuousClock.Instant?
        private var foreground = true
        private var pressureCooldownUntil: ContinuousClock.Instant?
        private enum ReplicaPressure: Error { case insufficientHeadroom, retired }

        private let sharedLoads = NativeCoreMLSharedLoadCoordinator<
            NativeCoreMLRecognitionModelVariant,
            LoadedModel
        >()

        init(
            asset: MLModelAsset,
            assetURL: URL,
            maximumResidentModels: Int,
            usesDynamicModel: Bool
        ) {
            precondition((2...3).contains(maximumResidentModels))
            self.asset = asset
            self.assetURL = assetURL
            self.maximumResidentModels = maximumResidentModels
            self.usesDynamicModel = usesDynamicModel
        }

        deinit { idleExpiry?.cancel() }

        private static var hasReplicaHeadroom: Bool {
            let available = ProcessMemory.available()
            // The simulator's sentinel means that no headroom reading was available.
            return available != .max && available >= 3 * 1_024 * 1_024 * 1_024
        }

        private func dropIdleReplica() {
            idleExpiry?.cancel()
            idleExpiry = nil
            replicaIdleDeadline = nil
            replica = nil
        }

        func trimReplicaForPressure() {
            // The process budget may still be high when UIKit has signalled
            // real system pressure. Let accepted work finish on its live handle.
            // Detached idle/pending handles cannot become resident again.
            pressureCooldownUntil = ContinuousClock.now.advanced(by: .seconds(3))
            replicaUse &+= 1
            dropIdleReplica()
        }

        func setForeground(_ active: Bool) {
            foreground = active
            guard !active else { return }
            // Release optional residency. The reader owns cancellation of active work.
            replicaUse &+= 1
            dropIdleReplica()
        }

        // Between pages keep an eligible second handle for a short reading
        // interval. Pressure is checked at least every two seconds of idle time.
        private func keepIdleReplica(after use: UInt64, until deadline: ContinuousClock.Instant) -> Bool {
            guard replicaUse == use, !replicaInUse, replica != nil else { return false }
            guard Self.hasReplicaHeadroom else {
                trimReplicaForPressure()
                return false
            }
            guard foreground, ContinuousClock.now < deadline else {
                dropIdleReplica()
                return false
            }
            return true
        }

        func withPredictionModel<T: Sendable>(
            for variant: NativeCoreMLRecognitionModelVariant,
            perform: @Sendable (ModelAccess) async throws -> T
        ) async throws -> T {
            try Task.checkCancellation()
            if !usesDynamicModel {
                guard let access = try await model(for: variant) else {
                    throw NativeCoreMLRecognizerError.modelInputCreationFailed
                }
                let result = try await perform(access)
                try markPrepared(variant, access: access)
                return result
            }

            let issuedRevision = revision
            if replica != nil, !Self.hasReplicaHeadroom {
                trimReplicaForPressure()
            } else if let deadline = replicaIdleDeadline, !replicaInUse, ContinuousClock.now >= deadline {
                dropIdleReplica()
            }
            let pressureAllowsReplica = pressureCooldownUntil.map { ContinuousClock.now >= $0 } ?? true
            let useReplica = foreground && pressureAllowsReplica && activePredictions > 0 && !replicaInUse
                && !replicaFailed && Self.hasReplicaHeadroom
            activePredictions += 1
            if useReplica {
                replicaInUse = true
                replicaIdleDeadline = nil
                replicaUse &+= 1
                idleExpiry?.cancel()
                idleExpiry = nil
                if replica == nil {
                    // Core ML reuses an MLModel instance when the same MLModelAsset
                    // is loaded twice. An independent asset opens the same compiled weights.
                    do {
                        let independentAsset = try MLModelAsset(url: assetURL)
                        replica = ModelStore(asset: independentAsset, assetURL: assetURL,
                                             maximumResidentModels: maximumResidentModels, usesDynamicModel: true)
                    } catch {
                        replicaFailed = true
                    }
                }
            }
            defer {
                activePredictions -= 1
                if useReplica { replicaInUse = false }
                if !replicaInUse, replica != nil {
                    if !Self.hasReplicaHeadroom {
                        trimReplicaForPressure()
                    } else if Task.isCancelled || !foreground {
                        dropIdleReplica()
                    } else if useReplica {
                        let use = replicaUse
                        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                        replicaIdleDeadline = deadline
                        idleExpiry = Task { [weak self] in
                            repeat {
                                let next = min(deadline, ContinuousClock.now.advanced(by: .seconds(2)))
                                do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
                            } while await self?.keepIdleReplica(after: use, until: deadline) == true
                        }
                    }
                }
            }

            var store = self
            var access: ModelAccess?
            if useReplica, let secondary = replica {
                do {
                    access = try await secondary.model(for: variant, admissionCheck: {
                        try Task.checkCancellation()
                        guard Self.hasReplicaHeadroom else { throw ReplicaPressure.insufficientHeadroom }
                    })
                    // Low headroom can be reported during an asynchronous compilation.
                    guard replica === secondary, foreground else { throw ReplicaPressure.retired }
                    guard Self.hasReplicaHeadroom else { throw ReplicaPressure.insufficientHeadroom }
                    store = secondary
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Replica load failures leave the existing primary available.
                    // Suppress repeated failing loads until the model store is purged.
                    guard revision == issuedRevision else { throw CancellationError() }
                    try Task.checkCancellation()
                    if let reason = error as? ReplicaPressure {
                        if reason == .insufficientHeadroom { trimReplicaForPressure() }
                        else { dropIdleReplica() }
                    } else {
                        replicaFailed = true
                        dropIdleReplica()
                    }
                    access = nil
                }
            }
            guard revision == issuedRevision else { throw CancellationError() }
            try Task.checkCancellation()
            if access == nil { access = try await model(for: variant) }
            guard let access else { throw NativeCoreMLRecognizerError.modelInputCreationFailed }
            guard revision == issuedRevision else { throw CancellationError() }
            try Task.checkCancellation()
            let result: T
            do {
                result = try await perform(access)
            } catch {
                // An accepted inference is counted once. Retire a failed replica
                // for future demand without issuing a second prediction here.
                if store !== self, revision == issuedRevision,
                   !(error is CancellationError), !Task.isCancelled {
                    replicaFailed = true
                    dropIdleReplica()
                }
                throw error
            }
            guard revision == issuedRevision else { throw CancellationError() }
            try await store.markPrepared(variant, access: access)
            return result
        }

        func model(
            for variant: NativeCoreMLRecognitionModelVariant,
            allowsEviction: Bool = true,
            minimumFreeResidentSlots: Int = 0,
            admissionCheck: @escaping @Sendable () throws -> Void = {}
        ) async throws -> ModelAccess? {
            try admissionCheck()
            let headroom = ProcessMemory.available()
            let residentLimit = headroom < 2 * 1_024 * 1_024 * 1_024 ? min(2, maximumResidentModels) : maximumResidentModels
            let modelKey = storageKey(for: variant)
            if !allowsEviction, headroom < 2 * 1_024 * 1_024 * 1_024 { return nil }
            trimResidents(to: residentLimit, preserving: modelKey)
            if let model = models[modelKey] {
                try admissionCheck()
                if allowsEviction {
                    markDemanded(modelKey)
                }
                return ModelAccess(
                    handle: model,
                    wasLoaded: false,
                    loadMilliseconds: 0,
                    revision: revision,
                    isPrepared: preparedVariants.contains(modelKey)
                )
            }
            let reservedSlots = min(
                residentLimit,
                max(0, minimumFreeResidentSlots)
            )
            let nonEvictingLimit = residentLimit - reservedSlots
            if !allowsEviction, models.count >= nonEvictingLimit {
                return nil
            }

            // Release an old handle before loading its replacement, rather than
            // briefly holding the full resident set plus a new model runtime.
            if allowsEviction { trimResidents(to: max(0, residentLimit - 1), preserving: modelKey) }
            let issuedRevision = revision
            let asset = self.asset
            let usesDynamicModel = self.usesDynamicModel
            let access = try await sharedLoads.load(for: modelKey) {
                    let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
                    // Core ML in the iOS 26 Simulator rejects a non-default
                    // multifunction program with CPU + GPU.
                    configuration.computeUnits = .cpuOnly
#else
                    configuration.computeUnits = .all
#endif
                    if !usesDynamicModel {
                        configuration.functionName = variant.functionName
                    }
                    configuration.modelDisplayName =
                        usesDynamicModel
                            ? "PP-OCRv6 Dynamic Width"
                            : "PP-OCRv6 \(variant.functionName)"
                    configuration.optimizationHints.reshapeFrequency =
                        usesDynamicModel ? .frequent : .infrequent
                    configuration.optimizationHints.specializationStrategy =
                        .fastPrediction
                    try Task.checkCancellation()
                    let loadStarted =
                        ProcessInfo.processInfo.systemUptime * 1_000
                    let handle = ModelHandle(model: try await MLModel.load(
                        asset: asset,
                        configuration: configuration
                    ))
                    return LoadedModel(
                        handle: handle,
                        loadMilliseconds:
                            ProcessInfo.processInfo.systemUptime * 1_000
                                - loadStarted
                    )
            }
            guard issuedRevision == revision else {
                throw CancellationError()
            }
            try admissionCheck()
            let loaded = access.value
            var admittedModel = false
            if models[modelKey] == nil {
                if !allowsEviction, models.count >= nonEvictingLimit {
                    return nil
                }
                // Evict only when a completed handle is admitted. The strong
                // resident set therefore remains at its configured cap while
                // a shared preparation task is in flight.
                if allowsEviction,
                   models.count >= residentLimit,
                   let oldestVariant = recency.first {
                    models[oldestVariant] = nil
                    preparedVariants.remove(oldestVariant)
                    recency.removeFirst()
                }
                models[modelKey] = loaded.handle
                admittedModel = true
            }
            if admittedModel {
                if allowsEviction {
                    markDemanded(modelKey)
                } else {
                    markSpeculative(modelKey)
                }
            } else if allowsEviction {
                // A concurrent idle load may have admitted the shared handle.
                // Actual prediction demand promotes it to protected MRU.
                markDemanded(modelKey)
            }
            do {
                try admissionCheck()
            } catch {
                if admittedModel {
                    models[modelKey] = nil
                    speculativeVariants.remove(modelKey)
                    recency.removeAll { $0 == modelKey }
                }
                throw error
            }
            try Task.checkCancellation()
            return ModelAccess(
                handle: loaded.handle,
                wasLoaded: access.initiatedLoad,
                loadMilliseconds:
                    access.initiatedLoad ? loaded.loadMilliseconds : 0,
                revision: issuedRevision,
                isPrepared: false
            )
        }

        private func trimResidents(to limit: Int, preserving key: NativeCoreMLRecognitionModelVariant) {
            while models.count > limit {
                guard let victim = recency.first(where: { $0 != key && speculativeVariants.contains($0) })
                    ?? recency.first(where: { $0 != key }) else { return }
                models[victim] = nil
                preparedVariants.remove(victim)
                speculativeVariants.remove(victim)
                recency.removeAll { $0 == victim }
            }
        }

        func markPrepared(
            _ variant: NativeCoreMLRecognitionModelVariant,
            access: ModelAccess,
            admissionCheck: @escaping @Sendable () throws -> Void = {}
        ) throws {
            try Task.checkCancellation()
            try admissionCheck()
            let modelKey = storageKey(for: variant)
            guard revision == access.revision,
                  models[modelKey]?.model === access.handle.model
            else {
                throw CancellationError()
            }
            preparedVariants.insert(modelKey)
        }

        func preferredOrder(availableWidths: [Int]) -> [Int] {
            let unique = Array(Set(availableWidths)).sorted(by: >)
            if usesDynamicModel { return unique }
            var cached: [Int] = []
            for variant in recency
            where unique.contains(variant.bucket.width)
                && !cached.contains(variant.bucket.width) {
                cached.append(variant.bucket.width)
            }
            let residentWidths = Set(
                models.keys.map { $0.bucket.width }
            )
            let missing = unique.filter { !residentWidths.contains($0) }
            return cached + missing
        }

        func purge() async {
            revision &+= 1
            replicaUse &+= 1
            let retainedReplica = replica
            dropIdleReplica()
            replicaFailed = false
            await retainedReplica?.purge()
            await sharedLoads.purge()
            models.removeAll(keepingCapacity: false)
            preparedVariants.removeAll(keepingCapacity: false)
            speculativeVariants.removeAll(keepingCapacity: false)
            recency.removeAll(keepingCapacity: false)
        }

        private func markDemanded(
            _ variant: NativeCoreMLRecognitionModelVariant
        ) {
            speculativeVariants.remove(variant)
            recency.removeAll { $0 == variant }
            recency.append(variant)
        }

        private func markSpeculative(
            _ variant: NativeCoreMLRecognitionModelVariant
        ) {
            speculativeVariants.insert(variant)
            recency.removeAll { $0 == variant }
            recency.insert(variant, at: 0)
        }

        private func storageKey(
            for variant: NativeCoreMLRecognitionModelVariant
        ) -> NativeCoreMLRecognitionModelVariant {
            usesDynamicModel
                ? NativeCoreMLRecognitionModelVariant(
                    width: 320,
                    batchSize: 1
                )!
                : variant
        }
    }

    let modelName: String
    let inputFeatureName: String
    let outputFeatureName: String

    private let modelStore: ModelStore

#if os(iOS)
    private final class ReplicaActivityObservation: @unchecked Sendable {
        private let tokens: [NSObjectProtocol]

        @MainActor init(store: ModelStore) async {
            // Sample the current state in the callback task as well: a rapid
            // foreground transition may precede delivery of a queued notification.
            let activity = [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
                      UIApplication.willResignActiveNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak store] _ in
                    Task { @MainActor in
                        await store?.setForeground(UIApplication.shared.applicationState == .active)
                    }
                }
            }
            let warning = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
            ) { [weak store] _ in Task { await store?.trimReplicaForPressure() } }
            tokens = activity + [warning]
            await store.setForeground(UIApplication.shared.applicationState == .active)
        }

        deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
    }
    private let replicaActivity: ReplicaActivityObservation?
#endif

    init(
        modelURL: URL,
        modelName: String,
        inputFeatureName: String,
        outputFeatureName: String,
        maximumResidentModels: Int
    ) async throws {
        let assetURL = try NativeCoreMLModelStore.shared.modelURL(for: modelURL)
        let asset = try MLModelAsset(url: assetURL)
        let availableFunctions = Set(try await asset.functionNames)
        let expectedFunctions = Set(
            NativeCoreMLRecognitionModelVariant.production.map(\.functionName)
        )
        // A single-function MLProgram reports an empty function list on some
        // Core ML runtimes. Multifunction packages report their named entry
        // points, so both empty and `main` identify the bounded dynamic model.
        let usesDynamicModel = availableFunctions.isEmpty
            || availableFunctions == ["main"]
        guard usesDynamicModel || availableFunctions == expectedFunctions else {
            throw NativeCoreMLRecognizerError.modelLoadFailed(
                "Unexpected recognizer functions: "
                    + availableFunctions.sorted().joined(separator: ",")
            )
        }
        modelStore = ModelStore(
            asset: asset,
            assetURL: assetURL,
            maximumResidentModels: maximumResidentModels,
            usesDynamicModel: usesDynamicModel
        )
#if os(iOS)
        if usesDynamicModel { replicaActivity = await ReplicaActivityObservation(store: modelStore) }
        else { replicaActivity = nil }
#endif
        self.modelName = modelName
        self.inputFeatureName = inputFeatureName
        self.outputFeatureName = outputFeatureName
    }

    func predict(
        input: MLMultiArray
    ) async throws -> NativeCoreMLRecognitionPrediction {
        guard input.shape.count == 4,
              let batchSize = input.shape.first?.intValue,
              let width = input.shape.last?.intValue,
              let variant = NativeCoreMLRecognitionModelVariant(
                  width: width,
                  batchSize: batchSize
              )
        else {
            throw NativeCoreMLRecognizerError.modelInputCreationFailed
        }
        return try await modelStore.withPredictionModel(for: variant) { [self] modelAccess in
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                inputFeatureName: MLFeatureValue(multiArray: input),
            ])
            // The async Core ML API is intentionally used instead of wrapping the
            // synchronous prediction call in a detached task. Core ML can observe
            // Swift task cancellation and abort an obsolete GPU submission on a
            // best-effort basis when a newer browser frame supersedes it.
            let prediction = try await modelAccess.handle.model.prediction(
                from: provider
            )
            guard let indices = prediction.featureValue(
                for: NativeCoreMLRecognizer.indexOutputFeatureName
            )?.multiArrayValue,
                  let scores = prediction.featureValue(
                      for: NativeCoreMLRecognizer.scoreOutputFeatureName
                  )?.multiArrayValue
            else {
                throw NativeCoreMLRecognizerError.modelOutputMissing
            }
            return NativeCoreMLRecognitionPrediction(
                outputs: try Self.packCompactOutputs(
                    indices: indices,
                    scores: scores,
                    variant: variant,
                    topIndices: prediction.featureValue(for: "ctc_topk_indices")?.multiArrayValue,
                    topScores: prediction.featureValue(for: "ctc_topk_scores")?.multiArrayValue
                ),
                modelWasLoaded: modelAccess.wasLoaded,
                modelLoadMilliseconds: modelAccess.loadMilliseconds
            )
        }
    }

    func preferredBucketOrder(availableWidths: [Int]) async -> [Int] {
        await modelStore.preferredOrder(availableWidths: availableWidths)
    }

    func prepare(
        variants: [NativeCoreMLRecognitionModelVariant]
    ) async throws {
        try await prepare(variants: variants, cancellationCheck: {})
    }

    func prepare(
        variants: [NativeCoreMLRecognitionModelVariant],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        try await prepare(
            variants: variants,
            allowsEviction: true,
            minimumFreeResidentSlots: 0,
            cancellationCheck: cancellationCheck
        )
    }

    func prepareNonEvicting(
        variants: [NativeCoreMLRecognitionModelVariant],
        minimumFreeResidentSlots: Int,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        try await prepare(
            variants: variants,
            allowsEviction: false,
            minimumFreeResidentSlots: minimumFreeResidentSlots,
            cancellationCheck: cancellationCheck
        )
    }

    private func prepare(
        variants: [NativeCoreMLRecognitionModelVariant],
        allowsEviction: Bool,
        minimumFreeResidentSlots: Int,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        var seen: Set<NativeCoreMLRecognitionModelVariant> = []
        for variant in variants where seen.insert(variant).inserted {
            try cancellationCheck()
            guard let modelAccess = try await modelStore.model(
                for: variant,
                allowsEviction: allowsEviction,
                minimumFreeResidentSlots: minimumFreeResidentSlots,
                admissionCheck: cancellationCheck
            ) else {
                continue
            }
            guard !modelAccess.isPrepared else { continue }
            // Keep the two common functions strictly serial. Each input is
            // released before the next variant begins, bounding preparation to
            // one MLMultiArray plus the bounded resident model handles.
            let input: MLMultiArray
            do {
                input = try MLMultiArray(
                    shape: variant.inputShape.map(NSNumber.init(value:)),
                    dataType: .float32
                )
            } catch {
                throw NativeCoreMLRecognizerError.modelInputCreationFailed
            }
            memset(
                input.dataPointer,
                0,
                input.count * MemoryLayout<Float>.stride
            )
            try cancellationCheck()
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                inputFeatureName: MLFeatureValue(multiArray: input),
            ])
            let prediction = try await modelAccess.handle.model.prediction(
                from: provider
            )
            guard let indices = prediction.featureValue(
                for: NativeCoreMLRecognizer.indexOutputFeatureName
            )?.multiArrayValue,
                  let scores = prediction.featureValue(
                for: NativeCoreMLRecognizer.scoreOutputFeatureName
            )?.multiArrayValue,
                  indices.shape.map(\.intValue) == variant.compactOutputShape,
                  scores.shape.map(\.intValue) == variant.compactOutputShape
            else {
                throw NativeCoreMLRecognizerError.modelOutputMissing
            }
            // MLMultiArray outputs are materialized storage. Touching one value
            // makes that completion boundary explicit and prevents an optimizer
            // from treating the best-effort result as unused.
            if indices.count > 0 {
                _ = indices[0]
                _ = scores[0]
            }
            try cancellationCheck()
            try await modelStore.markPrepared(
                variant,
                access: modelAccess,
                admissionCheck: cancellationCheck
            )
        }
    }

    func purgeResources() async {
        await modelStore.purge()
    }

    private static func packCompactOutputs(
        indices: MLMultiArray,
        scores: MLMultiArray,
        variant: NativeCoreMLRecognitionModelVariant,
        topIndices: MLMultiArray? = nil,
        topScores: MLMultiArray? = nil
    ) throws -> [MLMultiArray] {
        let expected = [variant.batchSize, variant.bucket.timeSteps]
        guard (topIndices == nil) == (topScores == nil) else {
            throw NativeCoreMLRecognizerError.modelOutputMissing
        }
        let alternatives = topIndices == nil ? 0 : 4
        if let topIndices, let topScores {
            let shape = [variant.batchSize, variant.bucket.timeSteps, alternatives]
            guard topIndices.shape.map(\.intValue) == shape, topScores.shape.map(\.intValue) == shape,
                  topIndices.dataType == .int32, topScores.dataType == .float32 else {
                throw NativeCoreMLRecognizerError.modelOutputMissing
            }
        }
        guard indices.shape.map(\.intValue) == expected,
              scores.shape.map(\.intValue) == expected,
              indices.dataType == .int32,
              scores.dataType == .float32,
              indices.strides.count == 2,
              scores.strides.count == 2
        else {
            throw NativeCoreMLRecognizerError.modelOutputShape(
                expected: expected,
                actual: indices.shape.map(\.intValue)
            )
        }
        let indexPointer = indices.dataPointer.assumingMemoryBound(
            to: Int32.self
        )
        let scorePointer = scores.dataPointer.assumingMemoryBound(
            to: Float.self
        )
        let indexBatchStride = indices.strides[0].intValue
        let scoreBatchStride = scores.strides[0].intValue
        let indexTimeStride = indices.strides[1].intValue
        let scoreTimeStride = scores.strides[1].intValue
        let topIndexStrides = topIndices?.strides.map(\.intValue)
        let topScoreStrides = topScores?.strides.map(\.intValue)
        var outputs: [MLMultiArray] = []
        outputs.reserveCapacity(variant.batchSize)
        for batchIndex in 0..<variant.batchSize {
            let compact = try MLMultiArray(
                shape: [2 + alternatives * 2, variant.bucket.timeSteps].map(
                    NSNumber.init(value:)
                ),
                dataType: .float32
            )
            let destination = compact.dataPointer.assumingMemoryBound(
                to: Float.self
            )
            let rowStride = compact.strides[0].intValue
            let timeStride = compact.strides[1].intValue
            let indexBatchOffset = batchIndex * indexBatchStride
            let scoreBatchOffset = batchIndex * scoreBatchStride
            for step in 0..<variant.bucket.timeSteps {
                destination[step * timeStride] = Float(
                    indexPointer[
                        indexBatchOffset + step * indexTimeStride
                    ]
                )
                destination[rowStride + step * timeStride] =
                    scorePointer[
                        scoreBatchOffset + step * scoreTimeStride
                    ]
            }
            if let topIndices, let topScores, let topIndexStrides, let topScoreStrides {
                let topIndexPointer = topIndices.dataPointer.assumingMemoryBound(to: Int32.self)
                let topScorePointer = topScores.dataPointer.assumingMemoryBound(to: Float.self)
                let indexTimeStride = topIndexStrides[1], scoreTimeStride = topScoreStrides[1]
                let indexBatchOffset = batchIndex * topIndexStrides[0]
                let scoreBatchOffset = batchIndex * topScoreStrides[0]
                for rank in 0..<alternatives {
                    let indexRankOffset = indexBatchOffset + rank * topIndexStrides[2]
                    let scoreRankOffset = scoreBatchOffset + rank * topScoreStrides[2]
                    let indexDestination = destination + (2 + rank * 2) * rowStride
                    let scoreDestination = indexDestination + rowStride
                    for step in 0..<variant.bucket.timeSteps {
                        indexDestination[step * timeStride] = Float(topIndexPointer[indexRankOffset + step * indexTimeStride])
                        scoreDestination[step * timeStride] = topScorePointer[scoreRankOffset + step * scoreTimeStride]
                    }
                }
            }
            outputs.append(compact)
        }
        return outputs
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionBucket: Equatable, Hashable, Sendable {
    static let all = [
        NativeCoreMLRecognitionBucket(width: 320, timeSteps: 40)!,
        NativeCoreMLRecognitionBucket(width: 640, timeSteps: 80)!,
        NativeCoreMLRecognitionBucket(width: 1_280, timeSteps: 160)!,
    ]

    let width: Int
    let timeSteps: Int

    init?(width: Int) {
        guard (32...2_400).contains(width) else {
            return nil
        }
        self.width = width
        // Two width strides followed by pooling: floor(ceil(width / 4) / 2).
        timeSteps = (width + 3) / 8
    }

    private init?(width: Int, timeSteps: Int) {
        self.init(width: width)
        guard self.timeSteps == timeSteps else { return nil }
    }

    static func containing(
        desiredWidth: Int,
        dynamicWidth: Bool = false,
        maximumWidth: Int = IPhoneOCRSettings.defaultRecognizerMaximumWidth
    ) -> Self {
        let boundedMaximum = min(2_400, max(32, maximumWidth))
        let boundedWidth = min(boundedMaximum, max(32, desiredWidth))
        if dynamicWidth {
            // Exact crop width: no bucket rounding and no minimum-width padding.
            return Self(width: boundedWidth)!
        }
        // Fixed functions still need their compiled tensor width. The crop
        // planner caps content separately, so a 1184-pixel line uses rec1280
        // without shrinking all the way to the preceding 640-pixel bucket.
        return all.first { boundedWidth <= $0.width } ?? all[all.count - 1]
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionModelVariant: Equatable, Hashable, Sendable {
    static let maximumBatchSize = 4
    static let production = [
        NativeCoreMLRecognitionModelVariant(width: 320, batchSize: 1)!,
        NativeCoreMLRecognitionModelVariant(width: 320, batchSize: 4)!,
        NativeCoreMLRecognitionModelVariant(width: 640, batchSize: 1)!,
        NativeCoreMLRecognitionModelVariant(width: 640, batchSize: 4)!,
        NativeCoreMLRecognitionModelVariant(width: 1_280, batchSize: 1)!,
    ]

    let bucket: NativeCoreMLRecognitionBucket
    let batchSize: Int

    var functionName: String { "rec\(bucket.width)b\(batchSize)" }
    var inputShape: [Int] { [batchSize, 3, 48, bucket.width] }
    var compactOutputShape: [Int] { [batchSize, bucket.timeSteps] }

    init?(width: Int, batchSize: Int) {
        guard let bucket = NativeCoreMLRecognitionBucket(width: width),
              (1...Self.maximumBatchSize).contains(batchSize)
        else {
            return nil
        }
        self.bucket = bucket
        self.batchSize = batchSize
    }

    init?(bucket: NativeCoreMLRecognitionBucket, batchSize: Int) {
        self.init(width: bucket.width, batchSize: batchSize)
    }
}

@available(iOS 18.0, *)
private final class NativeCoreMLRecognitionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        value &+= 1
        let generation = value
        lock.unlock()
        return generation
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

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        let current = value == generation
        lock.unlock()
        return current
    }
}

/// Full SHA-256 identity of the exact float tensor submitted to the
/// recognizer. Geometry, perspective sampling, rotation, normalization and
/// zero padding have already been applied, so equality here is stronger than
/// a dirty-tile or source-bounds comparison.
@available(iOS 18.0, *)
private struct NativeCoreMLRecognitionCropFingerprint: Hashable, Sendable {
    let word0: UInt64
    let word1: UInt64
    let word2: UInt64
    let word3: UInt64

    init(tensor: NativeCoreMLPreparedTensor) {
        var hasher = SHA256()
        var metadata = [
            UInt64(tensor.resizedWidth).littleEndian,
            UInt64(tensor.bucket.width).littleEndian,
            tensor.rotatedCounterClockwise ? UInt64(1) : UInt64(0),
        ]
        // Keep every original-mode fingerprint byte-identical. Explicit input
        // transforms get a separate identity even when their contrast gate
        // abstains and leaves the sampled tensor unchanged.
        if tensor.photometricMode != .original {
            metadata.append(UInt64(1).littleEndian)
        }
        metadata.withUnsafeBytes { bytes in
            hasher.update(bufferPointer: bytes)
        }
        tensor.values.withUnsafeBytes { bytes in
            hasher.update(bufferPointer: bytes)
        }
        let digest = hasher.finalize()
        let words = digest.withUnsafeBytes { bytes in
            (
                Self.word(in: bytes, at: 0),
                Self.word(in: bytes, at: 8),
                Self.word(in: bytes, at: 16),
                Self.word(in: bytes, at: 24)
            )
        }
        word0 = words.0
        word1 = words.1
        word2 = words.2
        word3 = words.3
    }

    private static func word(
        in bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + MemoryLayout<UInt64>.size) {
            value = (value << 8) | UInt64(bytes[index])
        }
        return value
    }
}

@available(iOS 18.0, *)
private struct NativeCoreMLCachedRecognition: Equatable, Sendable {
    let text: String
    let confidence: Double
    var tokenObservations: [NativeCoreMLCTCTokenObservation] = []
    var greedyObservation: NativeCoreMLGreedyRecognition? = nil
}

/// A small lock-protected LRU. Values contain no source pixels or tensors;
/// only the fixed-width digest and decoded text survive between frames.
@available(iOS 18.0, *)
private final class NativeCoreMLRecognitionCropCache: @unchecked Sendable {
    private struct Entry {
        let fingerprint: NativeCoreMLRecognitionCropFingerprint
        var value: NativeCoreMLCachedRecognition
        var older: Int?
        var newer: Int?
    }

    private let lock = NSLock()
    private let capacity: Int
    private var epoch: UInt64 = 0
    // Stable slots form the LRU list. At capacity a cold insert recycles the
    // oldest slot, so eviction never scans the other decoded crops under lock.
    private var slots: [NativeCoreMLRecognitionCropFingerprint: Int] = [:]
    private var entries: [Entry] = []
    private var oldest: Int?
    private var newest: Int?

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        slots.reserveCapacity(self.capacity)
    }

    func currentEpoch() -> UInt64 {
        lock.withLock { epoch }
    }

    func values(
        for fingerprints: [NativeCoreMLRecognitionCropFingerprint]
    ) -> [NativeCoreMLCachedRecognition?] {
        guard capacity > 0 else {
            return [NativeCoreMLCachedRecognition?](
                repeating: nil,
                count: fingerprints.count
            )
        }
        return lock.withLock {
            fingerprints.map { fingerprint in
                guard let slot = slots[fingerprint] else { return nil }
                touch(slot)
                return entries[slot].value
            }
        }
    }

    /// Reads entries without updating recency. Used only to predict a
    /// lookahead chunk; the recency-updating `values(for:)` still runs at the
    /// serial point and decides whether that prediction is used.
    func peekValues(
        for fingerprints: [NativeCoreMLRecognitionCropFingerprint]
    ) -> [NativeCoreMLCachedRecognition?] {
        guard capacity > 0 else {
            return [NativeCoreMLCachedRecognition?](
                repeating: nil,
                count: fingerprints.count
            )
        }
        return lock.withLock {
            fingerprints.map { key in slots[key].map { entries[$0].value } }
        }
    }

    func insert(
        _ value: NativeCoreMLCachedRecognition,
        for fingerprint: NativeCoreMLRecognitionCropFingerprint,
        ifCurrent expectedEpoch: UInt64
    ) {
        guard capacity > 0 else { return }
        lock.withLock {
            guard epoch == expectedEpoch else { return }
            if let slot = slots[fingerprint] {
                entries[slot].value = value
                touch(slot)
                return
            }
            let slot: Int
            if entries.count == capacity, let oldest {
                slot = oldest
                slots.removeValue(forKey: entries[slot].fingerprint)
                unlink(slot)
                entries[slot] = Entry(fingerprint: fingerprint, value: value)
            } else {
                slot = entries.count
                entries.append(Entry(fingerprint: fingerprint, value: value))
            }
            slots[fingerprint] = slot
            appendNewest(slot)
        }
    }

    func removeAll() {
        lock.withLock {
            epoch &+= 1
            slots.removeAll()
            entries.removeAll()
            oldest = nil
            newest = nil
        }
    }

    private func touch(_ slot: Int) {
        guard newest != slot else { return }
        unlink(slot)
        appendNewest(slot)
    }

    private func unlink(_ slot: Int) {
        let older = entries[slot].older
        let newer = entries[slot].newer
        if let older { entries[older].newer = newer } else { oldest = newer }
        if let newer { entries[newer].older = older } else { newest = older }
    }

    private func appendNewest(_ slot: Int) {
        entries[slot].older = newest
        entries[slot].newer = nil
        if let newest { entries[newest].newer = slot } else { oldest = slot }
        newest = slot
    }
}

/// Native PP-OCRv6 text recognition backed by Core ML's CPU/GPU
/// compute units. Detection remains a separate pipeline stage, so callers pass
/// detector polygons in source-image pixel coordinates.
///
/// Core ML does not expose a safe way to abort an in-flight prediction. A new
/// request nevertheless invalidates the old generation synchronously. The old
/// request checks that generation before and after every prediction, stops
/// before the next region, and can never publish a stale result.
@available(iOS 18.0, *)
final class NativeCoreMLRecognizer: @unchecked Sendable {
    static let modelResourceName = "PP-OCRv6-Manga-RecWidths"
    static let dictionaryResourceName =
        "ppocrv6_manga_rec_character_dict"
    static let inputFeatureName = "x"
    static let indexOutputFeatureName = "ctc_indices"
    static let scoreOutputFeatureName = "ctc_scores"
    static let outputFeatureName =
        "\(indexOutputFeatureName)+\(scoreOutputFeatureName)"
    /// Production dynamic-width ceiling reported in diagnostics. Explicit
    /// offline fixture configurations may use the model's wider contract.
    static let inputShape = [1, 3, 48, IPhoneOCRSettings.maximumRecognizerWidth]
    static let outputShape = [2, (IPhoneOCRSettings.maximumRecognizerWidth + 3) / 8]
    static let expectedDictionaryCharacterCount = 19_054
    static let maximumConcurrentPreparations = 4
    static let maximumPreparedRegionCount = 8
    static let maximumPreparedWindowRegionCount = maximumPreparedRegionCount / 2
    // Retain enough space for fixed-model 1280 tensors as well as the smaller
    // production dynamic tensors, preserving four-crop window admission.
    static let maximumPreparedTensorBytes =
        maximumPreparedRegionCount * 3 * 48 * 1_280
            * MemoryLayout<Float>.stride
    static let maximumPreparedWindowTensorBytes = maximumPreparedTensorBytes / 2
    static let defaultRecognitionCacheCapacity = 512
    /// Below this process headroom a window predicts one chunk at a time, so
    /// a second in-flight Core ML activation set is never added.
    static let minimumConcurrentPredictionMemory: UInt64 =
        2 * 1_024 * 1_024 * 1_024
    /// The ordinary multi-line phone-page functions. This exactly fills, but
    /// never exceeds, the lower-memory two-function resident working set.
    /// Sparse batch-one inputs remain demand-loaded on every device.
    static let commonPreparationVariants = [
        NativeCoreMLRecognitionModelVariant(width: 320, batchSize: 4)!,
        NativeCoreMLRecognitionModelVariant(width: 640, batchSize: 4)!,
    ]
    static let longWidthPreparationVariant =
        NativeCoreMLRecognitionModelVariant(width: 1_280, batchSize: 1)!
    /// A third Core ML function is admitted only on devices with enough
    /// physical memory to keep the common 320/640 batch functions resident.
    /// Lower-memory devices retain the established two-function cap and load
    /// width 1280 only on demand.
    static var supportsIdleLongWidthPreparation: Bool {
#if targetEnvironment(simulator)
        false
#else
        ProcessInfo.processInfo.physicalMemory >= 7 * 1_024 * 1_024 * 1_024
#endif
    }

    private struct Resources: Sendable {
        let predictor: any NativeCoreMLRecognitionPredicting
        let dictionary: [String]
        let loadMilliseconds: Double
    }

    private struct ResourceAccess: Sendable {
        let resources: Resources
        let wasAlreadyLoaded: Bool
    }

    private actor ResourceStore {
        private let loader: @Sendable () async throws -> Resources
        private var loadedResources: Resources?
        private var revision: UInt64 = 0
        private var pendingLoad: (
            revision: UInt64,
            task: Task<Resources, Error>
        )?

        init(
            loader: @escaping @Sendable () async throws -> Resources,
            preloaded: Resources? = nil
        ) {
            self.loader = loader
            loadedResources = preloaded
        }

        func load(
            admissionCheck: @escaping @Sendable () throws -> Void = {}
        ) async throws -> ResourceAccess {
            try admissionCheck()
            if let loadedResources {
                try admissionCheck()
                return ResourceAccess(
                    resources: loadedResources,
                    wasAlreadyLoaded: true
                )
            }
            let issuedRevision = revision
            let task: Task<Resources, Error>
            if let pendingLoad,
               pendingLoad.revision == issuedRevision {
                task = pendingLoad.task
            } else {
                let loader = self.loader
                task = Task.detached(priority: .userInitiated) {
                    try await loader()
                }
                pendingLoad = (issuedRevision, task)
            }
            let resources: Resources
            do {
                resources = try await task.value
            } catch {
                if pendingLoad?.revision == issuedRevision {
                    pendingLoad = nil
                }
                throw error
            }
            guard revision == issuedRevision else {
                throw CancellationError()
            }
            try admissionCheck()
            loadedResources = resources
            if pendingLoad?.revision == issuedRevision {
                pendingLoad = nil
            }
            try Task.checkCancellation()
            return ResourceAccess(
                resources: resources,
                wasAlreadyLoaded: false
            )
        }

        func purge() -> Resources? {
            revision &+= 1
            pendingLoad?.task.cancel()
            pendingLoad = nil
            let resources = loadedResources
            loadedResources = nil
            return resources
        }
    }

    private let generation = NativeCoreMLRecognitionGeneration()
    private let preparationRevision = NativeCoreMLPreparationRevision()
    private let diagnosticsLock = NSLock()
    private let resourceStore: ResourceStore
    private let preparationVariants: [NativeCoreMLRecognitionModelVariant]
    private let idlePreparationEnabled: Bool
    private let dynamicWidthEnabled: Bool
    private let mangaPublisherWidthEnabled: Bool
    /// One or two chunk predictions in flight within a prepared window.
    private let maximumConcurrentPredictions: Int
    private let maximumRecognitionWidth: Int
    var recoverySequenceWidthLimit: Int { dynamicWidthEnabled ? maximumRecognitionWidth : 0 }
    private let recognitionCropCache: NativeCoreMLRecognitionCropCache
    private let auditObserver: (@Sendable (NativeCoreMLRecognitionAuditEvent) -> Void)?
    private let languageModelLoader: @Sendable () throws -> NativeMangaNGram?
    private let observeEmissionSpans: Bool
    private let executionObserver: (@Sendable (NativeCoreMLRecognitionExecutionSnapshot) -> Void)?
    private var storedDiagnostics: NativeCoreMLRecognitionDiagnostics?

    /// Resolve the page recorder at callback time, including on reused recognizers.
    /// Keep the explicit observer independent; neither observer controls acceptance.
    private func emitAudit(_ event: @autoclosure () -> NativeCoreMLRecognitionAuditEvent) {
        guard auditObserver != nil || NativeCausalRawDecodeDiagnostics.current != nil else { return }
        let value = event()
        auditObserver?(value)
        NativeCausalRawDecodeDiagnostics.observe(value)
    }

    var lastDiagnostics: NativeCoreMLRecognitionDiagnostics? {
        diagnosticsLock.lock()
        let diagnostics = storedDiagnostics
        diagnosticsLock.unlock()
        return diagnostics
    }

    init(
        bundle: Bundle = .main,
        modelResourceName: String = NativeCoreMLRecognizer.modelResourceName,
        dictionaryResourceName: String =
            NativeCoreMLRecognizer.dictionaryResourceName,
        expectedDictionaryCharacterCount: Int =
            NativeCoreMLRecognizer.expectedDictionaryCharacterCount,
        idleLongWidthPreparationEnabled: Bool =
            NativeCoreMLRecognizer.supportsIdleLongWidthPreparation,
        recognitionCacheCapacity: Int =
            NativeCoreMLRecognizer.defaultRecognitionCacheCapacity,
        maximumRecognitionWidth: Int? = nil,
        observeEmissionSpans: Bool = false,
        executionObserver: (@Sendable (NativeCoreMLRecognitionExecutionSnapshot) -> Void)? = nil,
        auditObserver: (@Sendable (NativeCoreMLRecognitionAuditEvent) -> Void)? = nil
    ) {
        let maximumRecognitionWidth = maximumRecognitionWidth ?? (modelResourceName == "PP-OCRv6-Manga-RecWidths"
            ? IPhoneOCRSettings.mangaMaximumRecognizerWidth : IPhoneOCRSettings.defaultRecognizerMaximumWidth)
        self.auditObserver = auditObserver
        self.observeEmissionSpans = observeEmissionSpans
        self.executionObserver = executionObserver
        if modelResourceName == "PP-OCRv6-Manga-RecWidths" {
            languageModelLoader = { try NativeMangaNGram.bundled(in: bundle) }
        } else {
            languageModelLoader = { nil }
        }
        dynamicWidthEnabled = modelResourceName.hasSuffix("-RecWidths")
        mangaPublisherWidthEnabled = modelResourceName == "PP-OCRv6-Manga-RecWidths"
        maximumConcurrentPredictions = 2
        self.maximumRecognitionWidth = maximumRecognitionWidth
        let residentModelLimit = idleLongWidthPreparationEnabled ? 3 : 2
        let maximumStaticBucketWidth = NativeCoreMLRecognitionBucket.containing(
            desiredWidth: maximumRecognitionWidth,
            maximumWidth: maximumRecognitionWidth
        ).width
        preparationVariants = dynamicWidthEnabled
            ? [NativeCoreMLRecognitionModelVariant(
                width: min(320, max(32, maximumRecognitionWidth)), batchSize: 1
            )!]
            : (Self.commonPreparationVariants
                + (idleLongWidthPreparationEnabled
                    ? [Self.longWidthPreparationVariant]
                    : [])).filter {
                        $0.bucket.width <= maximumStaticBucketWidth
                    }
        idlePreparationEnabled = idleLongWidthPreparationEnabled
        recognitionCropCache = NativeCoreMLRecognitionCropCache(
            capacity: recognitionCacheCapacity
        )
        resourceStore = ResourceStore {
            let started = Self.nowMilliseconds()
            guard let modelURL = Self.findModelURL(
                in: bundle,
                resourceName: modelResourceName
            ) else {
                throw NativeCoreMLRecognizerError.modelResourceMissing
            }
            guard let dictionaryURL = Self.findDictionaryURL(
                in: bundle,
                resourceName: dictionaryResourceName
            )
            else {
                throw NativeCoreMLRecognizerError
                    .dictionaryResourceMissing
            }
            let dictionary = try Self.loadDictionary(
                from: dictionaryURL,
                expectedCharacterCount: expectedDictionaryCharacterCount
            )
            let predictor: NativeCoreMLModelPredictor
            do {
                predictor = try await NativeCoreMLModelPredictor(
                    modelURL: modelURL,
                    modelName: modelResourceName,
                    inputFeatureName: Self.inputFeatureName,
                    outputFeatureName: Self.outputFeatureName,
                    maximumResidentModels: residentModelLimit
                )
            } catch {
                throw NativeCoreMLRecognizerError.modelLoadFailed(
                    String(describing: error)
                )
            }
            return Resources(
                predictor: predictor,
                dictionary: dictionary,
                loadMilliseconds: Self.nowMilliseconds() - started
            )
        }
    }

    init(
        predictor: any NativeCoreMLRecognitionPredicting,
        dictionary: [String],
        idleLongWidthPreparationEnabled: Bool = false,
        recognitionCacheCapacity: Int = 0,
        dynamicWidth: Bool = false,
        maximumConcurrentPredictions: Int = 2,
        maximumRecognitionWidth: Int = IPhoneOCRSettings.defaultRecognizerMaximumWidth,
        observeEmissionSpans: Bool = false,
        executionObserver: (@Sendable (NativeCoreMLRecognitionExecutionSnapshot) -> Void)? = nil,
        auditObserver: (@Sendable (NativeCoreMLRecognitionAuditEvent) -> Void)? = nil
    ) throws {
        self.auditObserver = auditObserver
        self.observeEmissionSpans = observeEmissionSpans
        self.executionObserver = executionObserver
        languageModelLoader = { nil }
        dynamicWidthEnabled = dynamicWidth
        mangaPublisherWidthEnabled = false
        self.maximumConcurrentPredictions = min(2, max(1, maximumConcurrentPredictions))
        self.maximumRecognitionWidth = maximumRecognitionWidth
        guard dictionary.count == Self.expectedDictionaryCharacterCount
        else {
            throw NativeCoreMLRecognizerError.dictionaryCharacterCount(
                expected: Self.expectedDictionaryCharacterCount,
                actual: dictionary.count
            )
        }
        let resources = Resources(
            predictor: predictor,
            dictionary: dictionary,
            loadMilliseconds: 0
        )
        preparationVariants = Self.commonPreparationVariants
            + (idleLongWidthPreparationEnabled
                ? [Self.longWidthPreparationVariant]
                : [])
        idlePreparationEnabled = idleLongWidthPreparationEnabled
        recognitionCropCache = NativeCoreMLRecognitionCropCache(
            capacity: recognitionCacheCapacity
        )
        resourceStore = ResourceStore(
            loader: { resources },
            preloaded: resources
        )
    }

    func cancelCurrent() {
        generation.cancelCurrent()
    }

    func cancelPreparation() {
        preparationRevision.invalidate()
    }

    func prepare() async throws {
        let preparationToken = preparationRevision.token()
        let resourceAccess = try await resourceStore.load(admissionCheck: {
            try self.preparationRevision.requireCurrent(preparationToken)
        })
        try preparationRevision.requireCurrent(preparationToken)
        try await resourceAccess.resources.predictor.prepare(
            variants: preparationVariants,
            cancellationCheck: {
                try self.preparationRevision.requireCurrent(preparationToken)
            }
        )
        try preparationRevision.requireCurrent(preparationToken)
    }

    func prepareIdlePreservingDemandCapacity() async throws {
        // Two-slot devices cannot warm any speculative recognizer function
        // while both preserving the actual function and reserving capacity for
        // the next unseen width. Do no work there rather than evicting the
        // just-used sparse-page b1 function.
        guard idlePreparationEnabled,
              ProcessMemory.available() >= 2 * 1_024 * 1_024 * 1_024 else { return }
        let preparationToken = preparationRevision.token()
        let resourceAccess = try await resourceStore.load(admissionCheck: {
            try self.preparationRevision.requireCurrent(preparationToken)
        })
        try preparationRevision.requireCurrent(preparationToken)
        try await resourceAccess.resources.predictor.prepareNonEvicting(
            variants: preparationVariants,
            minimumFreeResidentSlots: 1,
            cancellationCheck: {
                try self.preparationRevision.requireCurrent(preparationToken)
            }
        )
        try preparationRevision.requireCurrent(preparationToken)
    }

    func purgeResources() async {
        cancelPreparation()
        generation.cancelCurrent()
        recognitionCropCache.removeAll()
        if let resources = await resourceStore.purge() {
            await resources.predictor.purgeResources()
        }
    }

    func recognize(
        image: CGImage,
        regions: [NativeCoreMLRecognitionRegion],
        requestID: String = UUID().uuidString,
        confidenceThreshold: Double = 0,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> NativeCoreMLRecognitionResult {
        try await performRecognition(
            providedFrame: nil,
            image: image,
            regions: regions,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            cancellationCheck: cancellationCheck
        )
    }

    /// Runs recognition from the same immutable source pixels used by the
    /// detector. Perspective warp sampling reads this frame directly.
    func recognize(
        frame: NativeOCRRGBAFrame,
        regions: [NativeCoreMLRecognitionRegion],
        requestID: String = UUID().uuidString,
        confidenceThreshold: Double = 0,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> NativeCoreMLRecognitionResult {
        try await performRecognition(
            providedFrame: frame,
            image: nil,
            regions: regions,
            requestID: requestID,
            confidenceThreshold: confidenceThreshold,
            cancellationCheck: cancellationCheck
        )
    }

    private func performRecognition(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        regions: [NativeCoreMLRecognitionRegion],
        requestID: String,
        confidenceThreshold: Double,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLRecognitionResult {
        let issuedGeneration = generation.begin()
        let observationSink = NativeCoreMLRecognitionObservations.current
        let threshold = min(max(confidenceThreshold, 0), 1)
        let observationPass = observationSink.map {
            NativeCoreMLRecognitionObservationPass(sink: $0, request: .init(requestID: requestID,
                generation: issuedGeneration, callerConfidenceThreshold: confidenceThreshold,
                appliedConfidenceThreshold: threshold))
        }
        let observer = executionObserver
        let rawRecorder = NativeCausalRawDecodeDiagnostics.current
        let execution: NativeCoreMLRecognitionExecutionCounters? = observer != nil || rawRecorder != nil
            ? .init(requestID: requestID, generation: issuedGeneration, observer: { snapshot in
                observer?(snapshot)
                rawRecorder?.recordExecution(snapshot)
            }) : nil
        // Structured prediction tasks have drained before this runs, including
        // on cancellation/error. A reused recognizer cannot redirect this page.
        defer { execution?.finish() }
        let recognitionCacheEpoch = recognitionCropCache.currentEpoch()
        let started = Self.nowMilliseconds()

        return try await withTaskCancellationHandler {
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )
            try observationPass?.began(requestedRegions: regions.count)
            let resourceAccess = try await resourceStore.load(admissionCheck: {
                try self.requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
            })
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )

            let frame: NativeOCRRGBAFrame
            if let providedFrame {
                frame = providedFrame
            } else if let image,
                      let converted = await NativeOCRCGImageAdapter
                          .makeRGBAFrameOffMain(from: image) {
                frame = converted
            } else {
                throw NativeCoreMLRecognizerError.imageConversionFailed
            }
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )

            var recognized: [NativeCoreMLRecognizedRegion] = []
            var multilineCandidates: [NativeCoreMLRecognizedRegion] = []
            var leadingDashCandidates: [NativeCoreMLRecognitionRegion] = []
            var emptyFinePrintCandidates: [NativeCoreMLRecognitionRegion] = []
            recognized.reserveCapacity(regions.count)
            var predictedRegions = 0
            var cacheHitRegions = 0
            var skippedInvalidRegions = 0
            var preprocessingMilliseconds = 0.0
            var predictionMilliseconds = 0.0
            var decodingMilliseconds = 0.0
            var modelFunctionSequence: [String] = []
            var modelFunctionLoadSequence: [String] = []
            var modelFunctionLoads = 0
            var modelFunctionLoadMilliseconds = 0.0
            var plannedRegions: [NativeCoreMLPlannedRegionWork] = []
            plannedRegions.reserveCapacity(regions.count)

            for region in regions {
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                emitAudit(.requested(requestID: requestID, region: region))
                if let observationPass {
                    try observationPass.sink.record(.requested(request: observationPass.request, region: region))
                }
                let preprocessingStarted = Self.nowMilliseconds()
                let plan = NativeCoreMLRecognitionPreprocessor.plan(
                    polygon: region.samplingPolygon ?? region.polygon,
                    dynamicWidth: dynamicWidthEnabled,
                    maximumWidth: maximumRecognitionWidth,
                    mangaPublisherWidth: mangaPublisherWidthEnabled,
                    useProvidedOrder: region.useProvidedOrder,
                    minimumSequenceWidth: region.minimumSequenceWidth,
                    photometricMode: region.photometricMode
                )
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                preprocessingMilliseconds += Self.nowMilliseconds()
                    - preprocessingStarted
                guard let plan else {
                    skippedInvalidRegions += 1
                    continue
                }
                plannedRegions.append(NativeCoreMLPlannedRegionWork(
                    region: region,
                    plan: plan
                ))
            }

            // A multifunction package shares weights on disk, not the full
            // loaded Core ML runtime state. Process each width as one group
            // and begin with resident widths. The bounded function store then
            // needs at most one load on a repeated three-width low-memory frame
            // and no loads on the common 320/640 case.
            let bucketOrder = await resourceAccess.resources.predictor
                .preferredBucketOrder(availableWidths: plannedRegions.map {
                    $0.plan.bucket.width
                })
            var bucketRank: [Int: Int] = [:]
            for width in bucketOrder where bucketRank[width] == nil {
                bucketRank[width] = bucketRank.count
            }
            plannedRegions.sort {
                if $0.plan.bucket.width != $1.plan.bucket.width {
                    return bucketRank[$0.plan.bucket.width, default: .max]
                        < bucketRank[$1.plan.bucket.width, default: .max]
                }
                return $0.region.sourceIndex < $1.region.sourceIndex
            }

            // Dynamic models accept every batch size from one through four,
            // so each chunk uses only its real crops. Static functions keep
            // padded tails to avoid loading a second model function.
            var plannedChunks: [NativeCoreMLPlannedRegionChunk] = []
            plannedChunks.reserveCapacity(plannedRegions.count)
            var groupStart = 0
            while groupStart < plannedRegions.count {
                let width = plannedRegions[groupStart].plan.bucket.width
                var groupEnd = groupStart + 1
                while groupEnd < plannedRegions.count,
                      plannedRegions[groupEnd].plan.bucket.width == width {
                    groupEnd += 1
                }
                let usesBatchFour = dynamicWidthEnabled
                    || (groupEnd - groupStart >= 4 && width <= 640)
                var chunkStart = groupStart
                while chunkStart < groupEnd {
                    let remaining = groupEnd - chunkStart
                    let maximumChunkSize = NativeOCRPreparationWindowBudget.maximumChunkRegionCount(
                        bucket: plannedRegions[chunkStart].plan.bucket
                    )
                    let chunkSize = usesBatchFour ? min(maximumChunkSize, remaining) : 1
                    let chunk = Array(
                        plannedRegions[chunkStart..<(chunkStart + chunkSize)]
                    )
                    plannedChunks.append(NativeCoreMLPlannedRegionChunk(
                        works: chunk,
                        modelBatchSize: dynamicWidthEnabled ? chunk.count : (usesBatchFour ? 4 : 1),
                    ))
                    chunkStart += chunkSize
                }
                groupStart = groupEnd
            }

            // Current and lookahead windows each retain at most four tensors
            // and half the byte budget. Wider offline crops use smaller chunks.
            // Prepare the next window
            // while Core ML predicts the current one. Up to two chunks of a
            // window predict concurrently; cache admission, audit events, and
            // diagnostics stay strictly serial in the established width order.
            var windows: [[NativeCoreMLPlannedRegionChunk]] = []
            var windowStart = 0
            while windowStart < plannedChunks.count {
                let windowEnd = Self.preparationWindowEnd(
                    chunks: plannedChunks,
                    startingAt: windowStart
                )
                windows.append(Array(plannedChunks[windowStart..<windowEnd]))
                windowStart = windowEnd
            }
            try await NativeOCRPreparationPipeline.run(windows, prepare: { chunks in
                try await self.preparePlannedWindow(
                    chunks,
                    frame: frame,
                    generation: issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
            }, consume: { preparedWindow in
                preprocessingMilliseconds +=
                    preparedWindow.preprocessingMilliseconds
                skippedInvalidRegions +=
                    preparedWindow.skippedInvalidRegions

                try await recognizePreparedWindowChunks(
                    preparedWindow.chunks,
                    requestID: requestID,
                    threshold: threshold,
                    predictor: resourceAccess.resources.predictor,
                    dictionary: resourceAccess.resources.dictionary,
                    recognitionCacheEpoch: recognitionCacheEpoch,
                    execution: execution,
                    observationPass: observationPass,
                    generation: issuedGeneration,
                    cancellationCheck: cancellationCheck
                ) { step in
                    preprocessingMilliseconds +=
                        step.preprocessingMilliseconds
                    predictionMilliseconds += step.predictionMilliseconds
                    decodingMilliseconds += step.decodingMilliseconds
                    skippedInvalidRegions += step.skippedInvalidRegions
                    modelFunctionSequence.append(
                        contentsOf: step.modelFunctionSequence
                    )
                    modelFunctionLoadSequence.append(
                        contentsOf: step.modelFunctionLoadSequence
                    )
                    modelFunctionLoads += step.modelFunctionLoads
                    modelFunctionLoadMilliseconds +=
                        step.modelFunctionLoadMilliseconds
                    predictedRegions += step.predictedRegions
                    cacheHitRegions += step.cacheHitRegions
                    recognized.append(contentsOf: step.recognizedRegions)
                    multilineCandidates.append(contentsOf: step.multilineCandidates)
                    leadingDashCandidates.append(contentsOf: step.leadingDashCandidates)
                    emptyFinePrintCandidates.append(contentsOf: step.emptyFinePrintCandidates)
                }
            })

            recognized.sort { $0.sourceIndex < $1.sourceIndex }

            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )
            let diagnostics = NativeCoreMLRecognitionDiagnostics(
                requestID: requestID,
                generation: issuedGeneration,
                backend: "coreml",
                executionProvider: "CoreML",
                computeUnits: Self.computeUnitsDescription,
                modelName: resourceAccess.resources.predictor.modelName,
                inputFeatureName:
                    resourceAccess.resources.predictor.inputFeatureName,
                outputFeatureName:
                    resourceAccess.resources.predictor.outputFeatureName,
                inputShape: [1, 3, 48, maximumRecognitionWidth],
                outputShape: [2, (maximumRecognitionWidth + 3) / 8],
                requestedRegions: regions.count,
                predictedRegions: predictedRegions,
                cacheHitRegions: cacheHitRegions,
                acceptedRegions: recognized.count,
                skippedInvalidRegions: skippedInvalidRegions,
                modelWasAlreadyLoaded:
                    resourceAccess.wasAlreadyLoaded &&
                        modelFunctionLoads == 0,
                modelLoadMilliseconds:
                    (resourceAccess.wasAlreadyLoaded
                        ? 0
                        : resourceAccess.resources.loadMilliseconds)
                        + modelFunctionLoadMilliseconds,
                modelFunctionSequence: modelFunctionSequence,
                modelFunctionLoadSequence: modelFunctionLoadSequence,
                modelFunctionLoads: modelFunctionLoads,
                modelFunctionLoadMilliseconds:
                    modelFunctionLoadMilliseconds,
                preprocessingMilliseconds: preprocessingMilliseconds,
                predictionMilliseconds: predictionMilliseconds,
                decodingMilliseconds: decodingMilliseconds,
                totalMilliseconds: Self.nowMilliseconds() - started
            )
            try observationPass?.finished(decodedRegions: predictedRegions + cacheHitRegions)
            store(diagnostics)
            return NativeCoreMLRecognitionResult(
                requestID: requestID,
                regions: recognized,
                diagnostics: diagnostics
            )
        } onCancel: { [generation] in
            generation.cancel(ifCurrent: issuedGeneration)
        }
    }

    private static func preparationWindowEnd(
        chunks: [NativeCoreMLPlannedRegionChunk],
        startingAt start: Int
    ) -> Int {
        var end = start
        var budget = NativeOCRPreparationWindowBudget()
        while end < chunks.count {
            let next = chunks[end].works
            guard let first = next.first,
                  budget.admit(regions: next.count, bucket: first.plan.bucket) else {
                break
            }
            end += 1
        }
        precondition(end > start, "Every OCR chunk must fit one preparation window")
        return end
    }

    /// Prepares one memory-bounded window across model chunks. Only four CPU
    /// sampling kernels run simultaneously; completion order is stored back in
    /// chunk/work slots so serial prediction order and source ordering remain
    /// unchanged.
    private func preparePlannedWindow(
        _ chunks: [NativeCoreMLPlannedRegionChunk],
        frame: NativeOCRRGBAFrame,
        generation issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLPreparedRegionWindow {
        let regionCount = chunks.reduce(0) { $0 + $1.works.count }
        precondition(!chunks.isEmpty)
        precondition(regionCount <= Self.maximumPreparedWindowRegionCount)
        var budget = NativeOCRPreparationWindowBudget()
        precondition(chunks.allSatisfy { chunk in
            guard let first = chunk.works.first else { return false }
            return budget.admit(regions: chunk.works.count, bucket: first.plan.bucket)
        })
        try requireCurrent(
            issuedGeneration,
            cancellationCheck: cancellationCheck
        )
        let preparationStarted = Self.nowMilliseconds()
        let requests = chunks.enumerated().flatMap { chunkIndex, chunk in
            chunk.works.enumerated().map { workIndex, work in
                NativeCoreMLRegionPreparationRequest(
                    chunkIndex: chunkIndex,
                    workIndex: workIndex,
                    work: work
                )
            }
        }
        var prepared = chunks.map { chunk in
            [NativeCoreMLRegionPreparationResult?](
                repeating: nil,
                count: chunk.works.count
            )
        }
        try await withThrowingTaskGroup(
            of: NativeCoreMLRegionPreparationResult.self,
            returning: Void.self
        ) { group in
            let initialCount = min(
                Self.maximumConcurrentPreparations,
                requests.count
            )
            for request in requests.prefix(initialCount) {
                group.addTask(priority: .userInitiated) {
                    try self.requireCurrent(
                        issuedGeneration,
                        cancellationCheck: cancellationCheck
                    )
                    let tensor = NativeCoreMLRecognitionPreprocessor
                        .prepare(frame: frame, plan: request.work.plan)
                    let fingerprint = tensor.map(
                        NativeCoreMLRecognitionCropFingerprint.init(tensor:)
                    )
                    try self.requireCurrent(
                        issuedGeneration,
                        cancellationCheck: cancellationCheck
                    )
                    return NativeCoreMLRegionPreparationResult(
                        chunkIndex: request.chunkIndex,
                        workIndex: request.workIndex,
                        tensor: tensor,
                        fingerprint: fingerprint
                    )
                }
            }
            var nextRequestIndex = initialCount
            while let result = try await group.next() {
                prepared[result.chunkIndex][result.workIndex] = result
                if nextRequestIndex < requests.count {
                    let request = requests[nextRequestIndex]
                    nextRequestIndex += 1
                    group.addTask(priority: .userInitiated) {
                        try self.requireCurrent(
                            issuedGeneration,
                            cancellationCheck: cancellationCheck
                        )
                        let tensor = NativeCoreMLRecognitionPreprocessor
                            .prepare(frame: frame, plan: request.work.plan)
                        let fingerprint = tensor.map(
                            NativeCoreMLRecognitionCropFingerprint.init(tensor:)
                        )
                        try self.requireCurrent(
                            issuedGeneration,
                            cancellationCheck: cancellationCheck
                        )
                        return NativeCoreMLRegionPreparationResult(
                            chunkIndex: request.chunkIndex,
                            workIndex: request.workIndex,
                            tensor: tensor,
                            fingerprint: fingerprint
                        )
                    }
                }
            }
        }
        try requireCurrent(
            issuedGeneration,
            cancellationCheck: cancellationCheck
        )
        var skippedInvalidRegions = 0
        let preparedChunks = zip(chunks, prepared).map { chunk, results in
            var preparedWorks: [NativeCoreMLPreparedRegionWork] = []
            preparedWorks.reserveCapacity(chunk.works.count)
            for (work, result) in zip(chunk.works, results) {
                guard let tensor = result?.tensor,
                      let fingerprint = result?.fingerprint
                else {
                    skippedInvalidRegions += 1
                    continue
                }
                preparedWorks.append(NativeCoreMLPreparedRegionWork(
                    work: work,
                    tensor: tensor,
                    fingerprint: fingerprint
                ))
            }
            return NativeCoreMLPreparedRegionChunk(
                works: preparedWorks,
                modelBatchSize: chunk.modelBatchSize
            )
        }
        return NativeCoreMLPreparedRegionWindow(
            chunks: preparedChunks,
            skippedInvalidRegions: skippedInvalidRegions,
            preprocessingMilliseconds:
                Self.nowMilliseconds() - preparationStarted
        )
    }

    /// Runs every chunk of one prepared window. At most two Core ML
    /// predictions are in flight, each with its own unchanged input tensor,
    /// shape, and batch size. All externally observable side effects (cache
    /// lookups and insertions, audit events, diagnostics, and result order)
    /// still happen strictly in chunk order.
    ///
    /// A lookahead chunk is predicted against a non-mutating cache peek. When
    /// the preceding chunk has been committed, the real (recency-updating)
    /// lookup runs at exactly the serial point; the speculative prediction is
    /// used only when that lookup matches the peek, otherwise it is discarded
    /// and the chunk is predicted again from the real lookup. The cache state
    /// sequence, batch sizes, and model inputs therefore equal the serial
    /// order's.
    private func recognizePreparedWindowChunks(
        _ chunks: [NativeCoreMLPreparedRegionChunk],
        requestID: String,
        threshold: Double,
        predictor: any NativeCoreMLRecognitionPredicting,
        dictionary: [String],
        recognitionCacheEpoch: UInt64,
        execution: NativeCoreMLRecognitionExecutionCounters?,
        observationPass: NativeCoreMLRecognitionObservationPass?,
        generation issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void,
        accumulate: (NativeCoreMLRecognitionStreamingChunkStep) -> Void
    ) async throws {
        guard !chunks.isEmpty else { return }
        let allowsOverlap = chunks.count > 1
            && maximumConcurrentPredictions > 1
            && ProcessMemory.available()
                >= Self.minimumConcurrentPredictionMemory
        try await withThrowingTaskGroup(
            of: (Int, Int, NativeCoreMLChunkPredictionOutcome).self
        ) { group in
            var lookups = [NativeCoreMLChunkCacheLookup?](
                repeating: nil,
                count: chunks.count
            )
            var speculative = [Bool](repeating: false, count: chunks.count)
            var attempts = [Int](repeating: 0, count: chunks.count)
            var launched = [Bool](repeating: false, count: chunks.count)
            var completed: [Int: NativeCoreMLChunkPredictionOutcome] = [:]

            func launch(_ index: Int, _ lookup: NativeCoreMLChunkCacheLookup) {
                attempts[index] += 1
                launched[index] = true
                let attempt = attempts[index]
                group.addTask {
                    (index, attempt, await self.predictChunkGroups(
                        lookup,
                        predictor: predictor,
                        execution: execution,
                        generation: issuedGeneration,
                        cancellationCheck: cancellationCheck
                    ))
                }
            }

            /// Launches `index` speculatively while its predecessor is in
            /// flight. Static multifunction packages overlap only identical
            /// functions so no second function load or eviction can start.
            func launchLookahead(_ index: Int) {
                guard allowsOverlap, index < chunks.count,
                      !launched[index],
                      let previous = lookups[index - 1]
                else { return }
                if !dynamicWidthEnabled,
                   chunks[index].modelBatchSize
                       != chunks[index - 1].modelBatchSize
                    || chunks[index].works.first?.tensor.bucket
                       != chunks[index - 1].works.first?.tensor.bucket {
                    return
                }
                let pending = Set(previous.uncachedWorks.map(\.fingerprint))
                // A crop repeated across the two chunks would become a cache
                // hit after the predecessor commits; predict it serially.
                guard !chunks[index].works.contains(where: {
                    pending.contains($0.fingerprint)
                }) else { return }
                let peek = makeCacheLookup(
                    chunks[index],
                    cachedValues: recognitionCropCache.peekValues(
                        for: chunks[index].works.map(\.fingerprint)
                    )
                )
                lookups[index] = peek
                speculative[index] = true
                if !peek.predictionGroups.isEmpty {
                    launch(index, peek)
                }
            }

            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )
            let first = makeCacheLookup(
                chunks[0],
                cachedValues: recognitionCropCache.values(
                    for: chunks[0].works.map(\.fingerprint)
                )
            )
            lookups[0] = first
            if !first.predictionGroups.isEmpty { launch(0, first) }
            launchLookahead(1)

            for index in chunks.indices {
                guard let lookup = lookups[index] else {
                    preconditionFailure("Missing recognition cache lookup")
                }
                var outcome = NativeCoreMLChunkPredictionOutcome.empty
                if !lookup.predictionGroups.isEmpty {
                    while completed[index] == nil {
                        guard let (completedIndex, attempt, value) =
                            try await group.next()
                        else {
                            preconditionFailure("Missing chunk prediction")
                        }
                        if attempt == attempts[completedIndex] {
                            completed[completedIndex] = value
                        }
                    }
                    outcome = completed.removeValue(forKey: index)!
                }
                let step = try commitChunk(
                    lookup,
                    outcome: outcome,
                    requestID: requestID,
                    threshold: threshold,
                    dictionary: dictionary,
                    recognitionCacheEpoch: recognitionCacheEpoch,
                    observationPass: observationPass,
                    generation: issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                accumulate(step)

                let next = index + 1
                guard next < chunks.count else { break }
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                // The serial lookup point for the next chunk.
                let real = makeCacheLookup(
                    chunks[next],
                    cachedValues: recognitionCropCache.values(
                        for: chunks[next].works.map(\.fingerprint)
                    )
                )
                if speculative[next],
                   let peek = lookups[next],
                   peek.cachedValues == real.cachedValues {
                    lookups[next] = real
                } else {
                    if speculative[next], launched[next] {
                        // Drain the stale prediction first so no more than
                        // two predictions are ever in flight.
                        while completed[next] == nil {
                            guard let (completedIndex, attempt, value) =
                                try await group.next()
                            else { break }
                            if attempt == attempts[completedIndex] {
                                completed[completedIndex] = value
                            }
                        }
                        if let execution, let discarded = completed[next], let peek = lookups[next] {
                            execution.discardedLookahead(plannedCrops: peek.uncachedWorks.count,
                                completedPredictions: discarded.groups.count,
                                completedCrops: discarded.groups.reduce(0) { $0 + $1.works.count })
                        }
                        completed[next] = nil
                    }
                    lookups[next] = real
                    speculative[next] = false
                    if !real.predictionGroups.isEmpty { launch(next, real) }
                }
                launchLookahead(next + 1)
            }
        }
    }

    private func makeCacheLookup(
        _ chunk: NativeCoreMLPreparedRegionChunk,
        cachedValues: [NativeCoreMLCachedRecognition?]
    ) -> NativeCoreMLChunkCacheLookup {
        let preparedWorks = chunk.works
        let requestedModelBatchSize = chunk.modelBatchSize
        precondition(
            dynamicWidthEnabled
                ? (1...NativeCoreMLRecognitionModelVariant.maximumBatchSize).contains(requestedModelBatchSize)
                : (requestedModelBatchSize == 1 || requestedModelBatchSize == 4)
        )
        var uncachedWorks: [NativeCoreMLPreparedRegionWork] = []
        uncachedWorks.reserveCapacity(preparedWorks.count)
        var cacheHitRegions = 0
        for (preparedWork, cached) in zip(preparedWorks, cachedValues) {
            if cached == nil {
                uncachedWorks.append(preparedWork)
            } else {
                cacheHitRegions += 1
            }
        }
        guard !uncachedWorks.isEmpty else {
            return NativeCoreMLChunkCacheLookup(
                works: preparedWorks,
                cachedValues: cachedValues,
                uncachedWorks: [],
                cacheHitRegions: cacheHitRegions,
                modelBatchSize: 0,
                predictionGroups: []
            )
        }
        // Dynamic models batch only cache misses. Static functions retain
        // their existing padding and partial-cache-hit loading policy.
        let modelBatchSize: Int
        if dynamicWidthEnabled {
            modelBatchSize = uncachedWorks.count
        } else if cacheHitRegions == 0 {
            modelBatchSize = requestedModelBatchSize
        } else {
            modelBatchSize = uncachedWorks.count >= 4
                && uncachedWorks[0].tensor.bucket.width <= 640 ? 4 : 1
        }
        let predictionGroups: [[NativeCoreMLPreparedRegionWork]]
        if modelBatchSize > 1,
           NativeCoreMLRecognitionModelVariant(
               bucket: uncachedWorks[0].tensor.bucket,
               batchSize: modelBatchSize
           ) != nil {
            predictionGroups = [uncachedWorks]
        } else {
            predictionGroups = uncachedWorks.map { [$0] }
        }
        return NativeCoreMLChunkCacheLookup(
            works: preparedWorks,
            cachedValues: cachedValues,
            uncachedWorks: uncachedWorks,
            cacheHitRegions: cacheHitRegions,
            modelBatchSize: modelBatchSize,
            predictionGroups: predictionGroups
        )
    }

    /// Packs and predicts the chunk's cache misses without any cache, audit,
    /// or diagnostics side effect. Groups stop at the first error, exactly
    /// where the serial loop stopped; completed groups are still committed.
    private func predictChunkGroups(
        _ lookup: NativeCoreMLChunkCacheLookup,
        predictor: any NativeCoreMLRecognitionPredicting,
        execution: NativeCoreMLRecognitionExecutionCounters?,
        generation issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async -> NativeCoreMLChunkPredictionOutcome {
        var groups: [NativeCoreMLGroupPrediction] = []
        groups.reserveCapacity(lookup.predictionGroups.count)
        do {
            for group in lookup.predictionGroups {
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                let packingStarted = Self.nowMilliseconds()
                guard let variant = NativeCoreMLRecognitionModelVariant(
                    bucket: group[0].tensor.bucket,
                    batchSize: lookup.modelBatchSize
                ) else {
                    throw NativeCoreMLRecognizerError.modelInputCreationFailed
                }
                let input = try Self.makeInputArray(
                    tensors: group.map(\.tensor),
                    modelBatchSize: lookup.modelBatchSize
                )
                let packingMilliseconds = Self.nowMilliseconds()
                    - packingStarted

                let predictionStarted = Self.nowMilliseconds()
                let prediction: NativeCoreMLRecognitionPrediction
                do {
                    prediction = try await predict(
                        input: input,
                        using: predictor,
                        actualCrops: group.count,
                        execution: execution,
                        generation: issuedGeneration,
                        cancellationCheck: cancellationCheck
                    )
                } catch let error as NativeCoreMLRecognizerError {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw NativeCoreMLRecognizerError.predictionFailed(
                        String(describing: error)
                    )
                }
                let predictionTotalMilliseconds = Self.nowMilliseconds()
                    - predictionStarted
                guard prediction.outputs.count == lookup.modelBatchSize else {
                    throw NativeCoreMLRecognizerError.modelOutputShape(
                        expected: [lookup.modelBatchSize],
                        actual: [prediction.outputs.count]
                    )
                }
                groups.append(NativeCoreMLGroupPrediction(
                    works: group,
                    variant: variant,
                    prediction: prediction,
                    packingMilliseconds: packingMilliseconds,
                    predictionTotalMilliseconds: predictionTotalMilliseconds
                ))
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
            }
        } catch {
            return NativeCoreMLChunkPredictionOutcome(
                groups: groups,
                error: error
            )
        }
        return NativeCoreMLChunkPredictionOutcome(groups: groups, error: nil)
    }

    /// Applies one chunk's cache hits and predictions in the established
    /// serial order: hit audits, then per-group decode, cache insertion, and
    /// audit. A prediction error is rethrown after the groups that completed
    /// before it, matching the former interleaved loop.
    private func commitChunk(
        _ lookup: NativeCoreMLChunkCacheLookup,
        outcome: NativeCoreMLChunkPredictionOutcome,
        requestID: String,
        threshold: Double,
        dictionary: [String],
        recognitionCacheEpoch: UInt64,
        observationPass: NativeCoreMLRecognitionObservationPass?,
        generation issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) throws -> NativeCoreMLRecognitionStreamingChunkStep {
        var recognizedRegions: [NativeCoreMLRecognizedRegion] = []
        var multilineCandidates: [NativeCoreMLRecognizedRegion] = []
        var leadingDashCandidates: [NativeCoreMLRecognitionRegion] = []
        var emptyFinePrintCandidates: [NativeCoreMLRecognitionRegion] = []
        func admit(_ read: NativeCoreMLCachedRecognition, for preparedWork: NativeCoreMLPreparedRegionWork, cacheHit: Bool) throws {
            if let observationPass {
                let admitted = !read.text.isEmpty && read.confidence >= threshold
                let reason: NativeCoreMLRecognitionObservations.AdmissionReason = admitted ? .accepted
                    : read.text.isEmpty ? .empty : !read.confidence.isFinite ? .nonFiniteConfidence : .belowThreshold
                try observationPass.sink.record(.decoded(.init(request: observationPass.request,
                    region: preparedWork.work.region, finalText: read.text, finalConfidence: read.confidence,
                    tokenObservations: read.tokenObservations, greedyObservation: read.greedyObservation,
                    cacheHit: cacheHit, admitted: admitted, reason: reason)))
            }
            emitAudit(.decoded(
                requestID: requestID, region: preparedWork.work.region,
                text: read.text, confidence: read.confidence,
                threshold: threshold, cacheHit: cacheHit
            ))
            if !read.text.isEmpty, read.confidence >= threshold {
                recognizedRegions.append(NativeCoreMLRecognizedRegion(
                    sourceIndex: preparedWork.work.region.sourceIndex,
                    polygon: preparedWork.work.region.polygon,
                    text: read.text,
                    confidence: read.confidence, tokenObservations: read.tokenObservations
                ))
            }
            if preparedWork.work.region.recognitionColumnEvidence != nil {
                let candidate = NativeCoreMLRecognizedRegion(
                    sourceIndex: preparedWork.work.region.sourceIndex,
                    polygon: preparedWork.work.region.polygon,
                    text: read.text, confidence: read.confidence
                )
                if NativeOCRMultilineColumnRecovery.eligible(candidate) { multilineCandidates.append(candidate) }
            }
            if read.text.isEmpty || read.confidence < 0.35 {
                leadingDashCandidates.append(preparedWork.work.region)
            }
            if read.text.isEmpty, preparedWork.work.region.isThinFinePrintRecovery {
                emptyFinePrintCandidates.append(preparedWork.work.region)
            }
        }
        for (preparedWork, cached) in zip(lookup.works, lookup.cachedValues) {
            if let cached { try admit(cached, for: preparedWork, cacheHit: true) }
        }

        var preprocessingMilliseconds = 0.0
        var predictedRegions = 0
        var modelFunctionSequence: [String] = []
        var modelFunctionLoadSequence: [String] = []
        var modelFunctionLoads = 0
        var modelFunctionLoadMilliseconds = 0.0
        var predictionMilliseconds = 0.0
        var decodingMilliseconds = 0.0

        for groupPrediction in outcome.groups {
            let prediction = groupPrediction.prediction
            preprocessingMilliseconds += groupPrediction.packingMilliseconds
            modelFunctionSequence.append(groupPrediction.variant.functionName)
            predictedRegions += groupPrediction.works.count
            if prediction.modelWasLoaded {
                modelFunctionLoadSequence.append(
                    groupPrediction.variant.functionName
                )
                modelFunctionLoads += 1
            }
            modelFunctionLoadMilliseconds +=
                prediction.modelLoadMilliseconds
            predictionMilliseconds += max(
                0,
                groupPrediction.predictionTotalMilliseconds
                    - prediction.modelLoadMilliseconds
            )

            for (preparedWork, output) in zip(
                groupPrediction.works,
                prediction.outputs
            ) {
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                let decodingStarted = Self.nowMilliseconds()
                let decoded = try NativeCoreMLCTCDecoder.decode(
                    output: output,
                    dictionary: dictionary,
                    expectedShape: Self.outputShape,
                    languageModel: languageModelLoader(),
                    observeEmissionSpans: observeEmissionSpans,
                    observeGreedy: observationPass != nil
                )
                decodingMilliseconds += Self.nowMilliseconds()
                    - decodingStarted
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                let read = NativeCoreMLCachedRecognition(text: decoded.text,
                    confidence: decoded.confidence, tokenObservations: decoded.tokenObservations,
                    greedyObservation: decoded.greedyObservation)
                recognitionCropCache.insert(
                    read,
                    for: preparedWork.fingerprint,
                    ifCurrent: recognitionCacheEpoch
                )
                try admit(read, for: preparedWork, cacheHit: false)
            }
        }
        if let error = outcome.error {
            throw error
        }
        return NativeCoreMLRecognitionStreamingChunkStep(
            multilineCandidates: multilineCandidates,
            recognizedRegions: recognizedRegions,
            leadingDashCandidates: leadingDashCandidates,
            emptyFinePrintCandidates: emptyFinePrintCandidates,
            predictedRegions: predictedRegions,
            cacheHitRegions: lookup.cacheHitRegions,
            skippedInvalidRegions: 0,
            modelFunctionSequence: modelFunctionSequence,
            modelFunctionLoadSequence: modelFunctionLoadSequence,
            modelFunctionLoads: modelFunctionLoads,
            modelFunctionLoadMilliseconds:
                modelFunctionLoadMilliseconds,
            preprocessingMilliseconds: preprocessingMilliseconds,
            predictionMilliseconds: predictionMilliseconds,
            decodingMilliseconds: decodingMilliseconds
        )
    }

    private func requireCurrent(
        _ issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) throws {
        try Task.checkCancellation()
        try cancellationCheck()
        guard generation.isCurrent(issuedGeneration) else {
            throw CancellationError()
        }
    }

    private func predict(
        input: MLMultiArray,
        using predictor: any NativeCoreMLRecognitionPredicting,
        actualCrops: Int,
        execution: NativeCoreMLRecognitionExecutionCounters?,
        generation issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLRecognitionPrediction {
        try requireCurrent(
            issuedGeneration,
            cancellationCheck: cancellationCheck
        )
        execution?.attempted(crops: actualCrops, batchSlots: input.shape[0].intValue)
        let output = try await predictor.predict(input: input)
        try requireCurrent(
            issuedGeneration,
            cancellationCheck: cancellationCheck
        )
        return output
    }

    private func store(_ diagnostics: NativeCoreMLRecognitionDiagnostics) {
        diagnosticsLock.lock()
        storedDiagnostics = diagnostics
        diagnosticsLock.unlock()
    }

    private static func findModelURL(
        in bundle: Bundle,
        resourceName: String
    ) -> URL? {
        if let exact = bundle.url(
            forResource: resourceName,
            withExtension: "mlmodelc"
        ) {
            return exact
        }
        let expected = normalizedResourceName(resourceName)
        return bundle.urls(
            forResourcesWithExtension: "mlmodelc",
            subdirectory: nil
        )?.first {
            normalizedResourceName($0.deletingPathExtension()
                .lastPathComponent) == expected
        }
    }

    private static func findDictionaryURL(
        in bundle: Bundle,
        resourceName: String
    ) -> URL? {
        if let exact = bundle.url(
            forResource: resourceName,
            withExtension: "txt"
        ) {
            return exact
        }
        let expected = normalizedResourceName(resourceName)
        return bundle.urls(
            forResourcesWithExtension: "txt",
            subdirectory: nil
        )?.first {
            normalizedResourceName($0.deletingPathExtension()
                .lastPathComponent) == expected
        }
    }

    private static func normalizedResourceName(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func loadDictionary(
        from url: URL,
        expectedCharacterCount: Int? = nil
    ) throws -> [String] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw NativeCoreMLRecognizerError.dictionaryResourceMissing
        }
        return try parseDictionary(
            data: data,
            expectedCharacterCount: expectedCharacterCount
        )
    }

    /// The generated resource stores one JSON string literal per line. This
    /// preserves quotes, backslashes, spaces, and control characters without
    /// making line-oriented parsing ambiguous.
    static func parseDictionary(
        data: Data,
        expectedCharacterCount: Int? = nil
    ) throws -> [String] {
        guard var text = String(data: data, encoding: .utf8) else {
            throw NativeCoreMLRecognizerError.dictionaryMalformed(line: 1)
        }
        if text.hasPrefix("\u{feff}") {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var characters: [String] = []
        characters.reserveCapacity(rawLines.count)
        let decoder = JSONDecoder()
        for (offset, rawLine) in rawLines.enumerated() {
            if offset == rawLines.count - 1, rawLine.isEmpty {
                continue
            }
            var line = String(rawLine)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            // An unescaped JSON string contains its token's exact UTF-8 bytes.
            // Let JSONDecoder handle escapes, surrounding whitespace and malformed lines.
            let bytes = line.utf8
            if bytes.count >= 2, bytes.first == UInt8(ascii: "\""), bytes.last == UInt8(ascii: "\"") {
                let token = bytes.dropFirst().dropLast()
                if token.allSatisfy({ $0 >= 0x20 && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }) {
                    characters.append(String(decoding: token, as: UTF8.self))
                    continue
                }
            }
            guard let lineData = line.data(using: .utf8) else {
                throw NativeCoreMLRecognizerError.dictionaryMalformed(
                    line: offset + 1
                )
            }
            do {
                characters.append(
                    try decoder.decode(String.self, from: lineData)
                )
            } catch {
                throw NativeCoreMLRecognizerError.dictionaryMalformed(
                    line: offset + 1
                )
            }
        }
        if let expectedCharacterCount,
           characters.count != expectedCharacterCount {
            throw NativeCoreMLRecognizerError.dictionaryCharacterCount(
                expected: expectedCharacterCount,
                actual: characters.count
            )
        }
        return characters
    }

    private static func makeInputArray(
        tensors: [NativeCoreMLPreparedTensor],
        modelBatchSize: Int? = nil
    ) throws -> MLMultiArray {
        guard let first = tensors.first,
              tensors.count <= NativeCoreMLRecognitionModelVariant
                  .maximumBatchSize,
              tensors.allSatisfy({ $0.bucket == first.bucket }),
              let variant = NativeCoreMLRecognitionModelVariant(
                  bucket: first.bucket,
                  batchSize: modelBatchSize ?? tensors.count
              )
        else {
            throw NativeCoreMLRecognizerError.modelInputCreationFailed
        }
        guard tensors.count <= variant.batchSize,
              variant.batchSize == 4 || tensors.count == variant.batchSize
        else {
            throw NativeCoreMLRecognizerError.modelInputCreationFailed
        }
        let width = first.bucket.width
        let expectedTensorCount = 3 * 48 * width
        guard tensors.allSatisfy({
            $0.values.count == expectedTensorCount
        }) else {
            throw NativeCoreMLRecognizerError.modelInputCreationFailed
        }
        let array: MLMultiArray
        do {
            array = try MLMultiArray(
                shape: variant.inputShape.map(NSNumber.init(value:)),
                dataType: .float32
            )
        } catch {
            throw NativeCoreMLRecognizerError.modelInputCreationFailed
        }
        guard array.strides.count == 4 else {
            throw NativeCoreMLRecognizerError.modelInputCreationFailed
        }
        let batchStride = array.strides[0].intValue
        let channelStride = array.strides[1].intValue
        let rowStride = array.strides[2].intValue
        let columnStride = array.strides[3].intValue
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        let height = 48
        let sourceChannelStride = height * width
        // A batch-four remainder reuses its last valid normalized tensor for
        // unused model slots. No extra prepared tensor is allocated, and the
        // caller decodes only `tensors.count` outputs.
        let contiguous = columnStride == 1
            && rowStride == width
            && channelStride == sourceChannelStride
            && batchStride == expectedTensorCount
        for batchIndex in 0..<variant.batchSize {
            let tensor = tensors[min(batchIndex, tensors.count - 1)]
            if contiguous {
                tensor.values.withUnsafeBufferPointer { source in
                    guard let sourceAddress = source.baseAddress else { return }
                    memcpy(
                        pointer.advanced(by: batchIndex * batchStride),
                        sourceAddress,
                        expectedTensorCount * MemoryLayout<Float>.stride
                    )
                }
                continue
            }
            for channel in 0..<3 {
                for row in 0..<height {
                    let sourceOffset = channel * sourceChannelStride
                        + row * width
                    let destinationOffset = batchIndex * batchStride
                        + channel * channelStride
                        + row * rowStride
                    for column in 0..<width {
                        pointer[destinationOffset + column * columnStride] =
                            tensor.values[sourceOffset + column]
                    }
                }
            }
        }
        return array
    }

    private static func nowMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }

    private static var computeUnitsDescription: String {
#if targetEnvironment(simulator)
        "cpuOnly"
#else
        "all"
#endif
    }
}

@available(iOS 18.0, *)
private struct NativeCoreMLRecognitionStreamingChunkStep: Sendable {
    let multilineCandidates: [NativeCoreMLRecognizedRegion]
    let recognizedRegions: [NativeCoreMLRecognizedRegion]
    let leadingDashCandidates: [NativeCoreMLRecognitionRegion]
    let emptyFinePrintCandidates: [NativeCoreMLRecognitionRegion]
    let predictedRegions: Int
    let cacheHitRegions: Int
    let skippedInvalidRegions: Int
    let modelFunctionSequence: [String]
    let modelFunctionLoadSequence: [String]
    let modelFunctionLoads: Int
    let modelFunctionLoadMilliseconds: Double
    let preprocessingMilliseconds: Double
    let predictionMilliseconds: Double
    let decodingMilliseconds: Double
}

@available(iOS 18.0, *)
private struct NativeCoreMLPlannedRegionWork: Sendable {
    let region: NativeCoreMLRecognitionRegion
    let plan: NativeCoreMLRecognitionPreprocessor.Plan
}

@available(iOS 18.0, *)
private struct NativeCoreMLPlannedRegionChunk: Sendable {
    let works: [NativeCoreMLPlannedRegionWork]
    let modelBatchSize: Int
}

@available(iOS 18.0, *)
private struct NativeCoreMLPreparedRegionWork: Sendable {
    let work: NativeCoreMLPlannedRegionWork
    let tensor: NativeCoreMLPreparedTensor
    let fingerprint: NativeCoreMLRecognitionCropFingerprint
}

@available(iOS 18.0, *)
private struct NativeCoreMLPreparedRegionChunk: Sendable {
    let works: [NativeCoreMLPreparedRegionWork]
    let modelBatchSize: Int
}

@available(iOS 18.0, *)
private struct NativeCoreMLChunkCacheLookup: Sendable {
    let works: [NativeCoreMLPreparedRegionWork]
    let cachedValues: [NativeCoreMLCachedRecognition?]
    let uncachedWorks: [NativeCoreMLPreparedRegionWork]
    let cacheHitRegions: Int
    let modelBatchSize: Int
    let predictionGroups: [[NativeCoreMLPreparedRegionWork]]
}

@available(iOS 18.0, *)
private struct NativeCoreMLGroupPrediction: Sendable {
    let works: [NativeCoreMLPreparedRegionWork]
    let variant: NativeCoreMLRecognitionModelVariant
    let prediction: NativeCoreMLRecognitionPrediction
    let packingMilliseconds: Double
    let predictionTotalMilliseconds: Double
}

@available(iOS 18.0, *)
private struct NativeCoreMLChunkPredictionOutcome: Sendable {
    static let empty = NativeCoreMLChunkPredictionOutcome(
        groups: [],
        error: nil
    )

    let groups: [NativeCoreMLGroupPrediction]
    let error: (any Error)?
}

@available(iOS 18.0, *)
private struct NativeCoreMLPreparedRegionWindow: Sendable {
    let chunks: [NativeCoreMLPreparedRegionChunk]
    let skippedInvalidRegions: Int
    let preprocessingMilliseconds: Double
}

@available(iOS 18.0, *)
private struct NativeCoreMLRegionPreparationRequest: Sendable {
    let chunkIndex: Int
    let workIndex: Int
    let work: NativeCoreMLPlannedRegionWork
}

@available(iOS 18.0, *)
private struct NativeCoreMLRegionPreparationResult: Sendable {
    let chunkIndex: Int
    let workIndex: Int
    let tensor: NativeCoreMLPreparedTensor?
    let fingerprint: NativeCoreMLRecognitionCropFingerprint?
}

/// Accounts for the actual Float backing in one of the two retained preparation
/// windows. Region-count and byte admission both remain bounded for wider offline
/// configurations; default reader crops at or below 1280 retain existing grouping.
@available(iOS 18.0, *)
struct NativeOCRPreparationWindowBudget: Sendable {
    private(set) var regionCount = 0
    private(set) var tensorBytes = 0

    init() {}

    static func bytesPerRegion(bucket: NativeCoreMLRecognitionBucket) -> Int {
        3 * NativeCoreMLRecognitionPreprocessor.targetHeight * bucket.width * MemoryLayout<Float>.stride
    }

    static func maximumChunkRegionCount(bucket: NativeCoreMLRecognitionBucket) -> Int {
        min(NativeCoreMLRecognizer.maximumPreparedWindowRegionCount,
            NativeCoreMLRecognizer.maximumPreparedWindowTensorBytes / bytesPerRegion(bucket: bucket))
    }

    mutating func admit(regions: Int, bucket: NativeCoreMLRecognitionBucket) -> Bool {
        // Validate the count before multiplying: callers cannot overflow the byte
        // calculation with invalid counts, and rejected admissions change no state.
        guard regions > 0,
              regions <= Self.maximumChunkRegionCount(bucket: bucket),
              regions <= NativeCoreMLRecognizer.maximumPreparedWindowRegionCount - regionCount else { return false }
        let bytes = regions * Self.bytesPerRegion(bucket: bucket)
        guard bytes <= NativeCoreMLRecognizer.maximumPreparedWindowTensorBytes - tensorBytes else { return false }
        regionCount += regions
        tensorBytes += bytes
        return true
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLPreparedTensor: Equatable, Sendable {
    let values: [Float]
    let resizedWidth: Int
    let bucket: NativeCoreMLRecognitionBucket
    let rotatedCounterClockwise: Bool
    var photometricMode: NativeCoreMLRecognitionPhotometricMode = .original
}

@available(iOS 18.0, *)
enum NativeCoreMLRecognitionPreprocessor {
    static let targetHeight = 48
    static let maximumTargetWidth = 2_000
    static let mangaWidthPolicyVersion = "manga-publisher-rounded48-640-over2000-2400-v1"

    struct Plan: Sendable {
        let resizedWidth: Int
        let bucket: NativeCoreMLRecognitionBucket
        let rotatedCounterClockwise: Bool
        fileprivate let cropWidth: Int
        fileprivate let cropHeight: Int
        fileprivate let orientedWidth: Int
        fileprivate let orientedHeight: Int
        fileprivate let homography: Homography
        let photometricMode: NativeCoreMLRecognitionPhotometricMode
    }

    fileprivate struct Quad: Sendable {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomRight: CGPoint
        let bottomLeft: CGPoint
    }

    fileprivate struct Homography: Sendable {
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        let e: Double
        let f: Double
        let g: Double
        let h: Double

        func sourcePoint(u: Double, v: Double) -> CGPoint? {
            let denominator = g * u + h * v + 1
            guard denominator.isFinite, abs(denominator) > 0.000_000_1
            else {
                return nil
            }
            return CGPoint(
                x: (a * u + b * v + c) / denominator,
                y: (d * u + e * v + f) / denominator
            )
        }
    }

    static func prepare(
        frame: NativeOCRRGBAFrame,
        polygon: [CGPoint]
    ) -> NativeCoreMLPreparedTensor? {
        guard let plan = plan(polygon: polygon) else { return nil }
        return prepare(frame: frame, plan: plan)
    }

    static func plan(
        polygon: [CGPoint],
        dynamicWidth: Bool = false,
        maximumWidth: Int = IPhoneOCRSettings.defaultRecognizerMaximumWidth,
        mangaPublisherWidth: Bool = false,
        useProvidedOrder: Bool = false,
        minimumSequenceWidth: Int = 0,
        photometricMode: NativeCoreMLRecognitionPhotometricMode = .original
    ) -> Plan? {
        guard let quad = makeQuad(polygon, useProvidedOrder: useProvidedOrder),
              let homography = makeHomography(quad)
        else { return nil }
        let widthTop = distance(quad.topLeft, quad.topRight)
        let widthBottom = distance(quad.bottomLeft, quad.bottomRight)
        let heightLeft = distance(quad.topLeft, quad.bottomLeft)
        let heightRight = distance(quad.topRight, quad.bottomRight)
        let width = max(widthTop, widthBottom)
        let height = max(heightLeft, heightRight)
        // Finite input points can still produce overflowing distances or
        // dimensions outside Int's range. Reject before converting geometry.
        guard width.isFinite, height.isFinite,
              width < Double(Int.max), height < Double(Int.max) else { return nil }
        let cropWidth = max(1, Int(floor(width)))
        let cropHeight = max(1, Int(floor(height)))
        guard cropWidth > 1, cropHeight > 1 else { return nil }

        // Decide the reading axis before raster rounding. Flooring short edges
        // can turn a 1.49 aspect ratio into 1.5 and rotate the same lettering
        // differently at different detector resolutions.
        let rotated = height / width >= 1.5
        let orientedWidth = rotated ? cropHeight : cropWidth
        let orientedHeight = rotated ? cropWidth : cropHeight
        let ratio = Double(orientedWidth) / Double(max(1, orientedHeight))
        let legacyWidth = Int(min(
            Double(maximumTargetWidth),
            max(1, ceil(Double(targetHeight) * ratio))
        ))
        // Publisher's rule uses the natural width BEFORE clipping: ordinary
        // lines cap at 640, only natural widths above 2000 can use up to 2400.
        // Keep explicit contextual sequence samples on their existing contract.
        let desiredWidth: Int
        if mangaPublisherWidth && minimumSequenceWidth == 0 {
            let naturalWidth = (Double(targetHeight) * ratio).rounded(.toNearestOrEven)
            desiredWidth = Int(max(1, min(naturalWidth > 2_000 ? 2_400 : 640, naturalWidth)))
        } else {
            desiredWidth = legacyWidth
        }
        // Every admitted contextual request must materialize its declared
        // sequence width. Static models or a smaller cap cannot supply two
        // distinct widths, so they must not masquerade as corroborating reads.
        let padsShortSequence = minimumSequenceWidth != 0
        if padsShortSequence {
            let supportedContextWidth = minimumSequenceWidth == 160 || minimumSequenceWidth == 192
                ? desiredWidth < 160
                : [256, 320, 384, 448, 512, 576, 640, 704, 768, 832].contains(minimumSequenceWidth)
                    && desiredWidth < minimumSequenceWidth
            guard dynamicWidth, supportedContextWidth,
                  maximumWidth >= minimumSequenceWidth else { return nil }
        }
        // Sampling keeps the original resizedWidth; ordinary crops stay exact.
        let bucket = NativeCoreMLRecognitionBucket.containing(
            desiredWidth: padsShortSequence ? max(desiredWidth, minimumSequenceWidth) : desiredWidth,
            dynamicWidth: dynamicWidth,
            maximumWidth: maximumWidth
        )
        guard !padsShortSequence || bucket.width == minimumSequenceWidth else { return nil }
        let resizedWidth = min(bucket.width, desiredWidth, max(32, maximumWidth))
        return Plan(
            resizedWidth: resizedWidth,
            bucket: bucket,
            rotatedCounterClockwise: rotated,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            orientedWidth: orientedWidth,
            orientedHeight: orientedHeight,
            homography: homography,
            photometricMode: photometricMode
        )
    }

    static func prepare(
        frame: NativeOCRRGBAFrame,
        plan: Plan
    ) -> NativeCoreMLPreparedTensor? {
        let targetWidth = plan.bucket.width
        let planeSize = targetHeight * targetWidth
        var values = [Float](repeating: 0, count: planeSize * 3)
        let cropWidth = Double(plan.cropWidth)
        let cropHeight = Double(plan.cropHeight)
        let orientedWidth = Double(plan.orientedWidth)
        let orientedHeight = Double(plan.orientedHeight)
        let resizedWidth = Double(plan.resizedWidth)
        let sourceMaximumX = Double(frame.width - 1)
        let sourceMaximumY = Double(frame.height - 1)
        let homography = plan.homography
        // With g == h == 0 the projective denominator is exactly 1.0 for every
        // finite u/v in [0, 1] (signed zeros included), and IEEE division by
        // 1.0 is the identity. Skipping it is therefore bit-identical.
        let isAffine = homography.g == 0 && homography.h == 0
        var valid = true
        // Each column uses the same normalized crop coordinate on all 48
        // rows. Keep the scalar operation order, but calculate it only once.
        let columnCoordinates = (0..<plan.resizedWidth).map { column in
            let orientedX = (Double(column) + 0.5) * orientedWidth / resizedWidth - 0.5
            return min(max(orientedX / (plan.rotatedCounterClockwise ? cropHeight : cropWidth), 0), 1)
        }

        let axis = isAffine && homography.b == 0 && homography.d == 0
            ? sampleAxisAligned(frame: frame, plan: plan, columns: columnCoordinates) : nil

        // This remains the exact scalar Paddle/OpenCV sampling contract, but
        // all CGPoint construction and nested per-channel closures are removed.
        // The immutable source and disjoint output slots also make this kernel
        // safe for the recognizer's bounded region-level task group.
        values.withUnsafeMutableBufferPointer { destination in
            frame.bytes.withUnsafeBufferPointer { sourceBytes in
                guard let output = destination.baseAddress,
                      let source = sourceBytes.baseAddress
                else {
                    valid = false
                    return
                }
                if plan.rotatedCounterClockwise, let axis,
                   let first = axis.y.first, let last = axis.y.last,
                   abs(last.near - first.near) / frame.bytesPerRow < axis.y.count {
                    sampleUpscaledVertical(source: source, output: output, xAxis: axis.x,
                                           yAxis: axis.y, targetWidth: targetWidth, planeSize: planeSize)
                    return
                }
                for row in 0..<targetHeight {
                    let orientedY =
                        (Double(row) + 0.5) * orientedHeight
                        / Double(targetHeight) - 0.5
                    let rowCoordinate = plan.rotatedCounterClockwise
                        ? min(max((Double(plan.cropWidth - 1) - orientedY) / cropWidth, 0), 1)
                        : min(max(orientedY / cropHeight, 0), 1)
                    for column in 0..<plan.resizedWidth {
                        let xWeight, yWeight: Double
                        let topLeft, topRight, bottomLeft, bottomRight: Int
                        if let axis {
                            let x = axis.x[plan.rotatedCounterClockwise ? row : column]
                            let y = axis.y[plan.rotatedCounterClockwise ? column : row]
                            xWeight = x.weight
                            yWeight = y.weight
                            topLeft = y.near + x.near
                            topRight = y.near + x.far
                            bottomLeft = y.far + x.near
                            bottomRight = y.far + x.far
                        } else {
                            let u = plan.rotatedCounterClockwise ? rowCoordinate : columnCoordinates[column]
                            let v = plan.rotatedCounterClockwise ? columnCoordinates[column] : rowCoordinate
                            var projectedX = homography.a * u
                                + homography.b * v + homography.c
                            var projectedY = homography.d * u
                                + homography.e * v + homography.f
                            if !isAffine {
                                let denominator = homography.g * u
                                    + homography.h * v + 1
                                guard denominator.isFinite,
                                      abs(denominator) > 0.000_000_1
                                else {
                                    valid = false
                                    return
                                }
                                projectedX /= denominator
                                projectedY /= denominator
                            }
                            let sourceX = min(max(
                                projectedX,
                                0
                            ), sourceMaximumX)
                            let sourceY = min(max(
                                projectedY,
                                0
                            ), sourceMaximumY)
                            guard sourceX.isFinite, sourceY.isFinite else {
                                valid = false
                                return
                            }
                            let x0 = Int(floor(sourceX))
                            let y0 = Int(floor(sourceY))
                            let x1 = min(x0 + 1, frame.width - 1)
                            let y1 = min(y0 + 1, frame.height - 1)
                            xWeight = sourceX - Double(x0)
                            yWeight = sourceY - Double(y0)
                            topLeft = y0 * frame.bytesPerRow + x0 * 4
                            topRight = y0 * frame.bytesPerRow + x1 * 4
                            bottomLeft = y1 * frame.bytesPerRow + x0 * 4
                            bottomRight = y1 * frame.bytesPerRow + x1 * 4

                        }
                        let inverseXWeight = 1 - xWeight
                        let inverseYWeight = 1 - yWeight

                        @inline(__always)
                        func interpolate(_ channel: Int) -> Float {
                            let top = Double(source[topLeft + channel])
                                    * inverseXWeight
                                + Double(source[topRight + channel])
                                    * xWeight
                            let bottom = Double(source[bottomLeft + channel])
                                    * inverseXWeight
                                + Double(source[bottomRight + channel])
                                    * xWeight
                            let value = top * inverseYWeight
                                + bottom * yWeight
                            return Float(value / 127.5 - 1)
                        }

                        let outputIndex = row * targetWidth + column
                        // Paddle's RecResizeImg converts RGBA to BGR, then
                        // applies (channel / 255 - 0.5) / 0.5. Padding stays 0.
                        output[outputIndex] = interpolate(2)
                        output[planeSize + outputIndex] = interpolate(1)
                        output[planeSize * 2 + outputIndex] = interpolate(0)
                    }
                }
            }
        }
        guard valid else { return nil }
        if plan.photometricMode == .luminanceContrast {
            applyLuminanceContrast(values: &values, resizedWidth: plan.resizedWidth, targetWidth: targetWidth)
        }
        return NativeCoreMLPreparedTensor(
            values: values,
            resizedWidth: plan.resizedWidth,
            bucket: plan.bucket,
            rotatedCounterClockwise: plan.rotatedCounterClockwise,
            photometricMode: plan.photometricMode
        )
    }

    /// On a rotated axis-aligned crop, an output row holds its source X fixed.
    /// Adjacent columns can therefore reuse the exact horizontal interpolation
    /// when bilinear sampling revisits either of the same two source rows.
    private static func sampleUpscaledVertical(
        source: UnsafePointer<UInt8>, output: UnsafeMutablePointer<Float>,
        xAxis: [AxisSample], yAxis: [AxisSample], targetWidth: Int, planeSize: Int
    ) {
        typealias RGB = (red: Double, green: Double, blue: Double)
        for (row, x) in xAxis.enumerated() {
            let inverseX = 1 - x.weight
            let leftColumn = source + x.near
            let rightColumn = source + x.far
            @inline(__always)
            func horizontal(_ rowOffset: Int) -> RGB {
                let left = leftColumn + rowOffset
                let right = rightColumn + rowOffset
                return (
                    Double(left[0]) * inverseX + Double(right[0]) * x.weight,
                    Double(left[1]) * inverseX + Double(right[1]) * x.weight,
                    Double(left[2]) * inverseX + Double(right[2]) * x.weight
                )
            }
            var nearOffset = -1, farOffset = -1
            var top: RGB = (0, 0, 0), bottom: RGB = (0, 0, 0)
            let line = output + row * targetWidth
            for (column, y) in yAxis.enumerated() {
                if y.near != nearOffset {
                    let previousTop = top
                    top = y.near == farOffset ? bottom : horizontal(y.near)
                    bottom = y.far == nearOffset ? previousTop : horizontal(y.far)
                    nearOffset = y.near
                    farOffset = y.far
                }
                let inverseY = 1 - y.weight
                line[column] = Float((top.blue * inverseY + bottom.blue * y.weight) / 127.5 - 1)
                line[planeSize + column] = Float((top.green * inverseY + bottom.green * y.weight) / 127.5 - 1)
                line[planeSize * 2 + column] = Float((top.red * inverseY + bottom.red * y.weight) / 127.5 - 1)
            }
        }
    }

    private struct AxisSample {
        let near: Int
        let far: Int
        let weight: Double
    }

    /// Exact separable axis-aligned warp. Generic affine/projective paths
    /// still exercise their existing per-cell projection and validity rules.
    private static func sampleAxisAligned(frame: NativeOCRRGBAFrame, plan: Plan, columns: [Double]) -> (x: [AxisSample], y: [AxisSample])? {
        let homography = plan.homography
        let rotated = plan.rotatedCounterClockwise
        let cropWidth = Double(plan.cropWidth)
        let cropHeight = Double(plan.cropHeight)
        let orientedHeight = Double(plan.orientedHeight)
        let rows = (0..<targetHeight).map { row in
            let y = (Double(row) + 0.5) * orientedHeight / Double(targetHeight) - 0.5
            return rotated ? min(max((Double(plan.cropWidth - 1) - y) / cropWidth, 0), 1) : min(max(y / cropHeight, 0), 1)
        }
        func samples(_ coordinates: [Double], horizontal: Bool) -> [AxisSample]? {
            let maximum = horizontal ? frame.width - 1 : frame.height - 1
            let stride = horizontal ? 4 : frame.bytesPerRow
            var result: [AxisSample] = []
            result.reserveCapacity(coordinates.count)
            for coordinate in coordinates {
                // Keep multiply/add order used by the generic branch. The
                // omitted coordinate has zero coefficient; its only possible
                // IEEE difference is the sign of zero, which clamps to the
                // same source pixel and normalizes identically.
                let projected = horizontal
                    ? homography.a * coordinate + homography.b * 0 + homography.c
                    : homography.d * 0 + homography.e * coordinate + homography.f
                let source = min(max(projected, 0), Double(maximum))
                guard source.isFinite else { return nil }
                let near = Int(floor(source))
                let far = min(near + 1, maximum)
                let weight = source - Double(near)
                result.append(.init(near: near * stride, far: far * stride, weight: weight))
            }
            return result
        }
        guard let xs = samples(rotated ? rows : columns, horizontal: true),
              let ys = samples(rotated ? columns : rows, horizontal: false) else { return nil }
        return (xs, ys)
    }

    /// Optional numeric model-input transform only. Statistics exclude padding
    /// and use the actual sampled crop, never DB masks or inferred characters.
    /// P2/P98 limit outliers; a 32...192 level span and <=2x gain avoid amplifying
    /// flat input or changing already high-contrast observations. Gamma is 1.
    /// Output is grayscale; source pixels, geometry and normalized padding stay
    /// untouched. Monotonic luminance preserves polarity, not chromatic detail.
    private static func applyLuminanceContrast(values: inout [Float], resizedWidth: Int, targetWidth: Int) {
        let plane = targetHeight * targetWidth
        var histogram = [Int](repeating: 0, count: 256)
        func luminance(_ index: Int) -> Double {
            (0.0722 * Double(values[index]) + 0.7152 * Double(values[plane + index])
                + 0.2126 * Double(values[plane * 2 + index]) + 1) * 127.5
        }
        for row in 0..<targetHeight {
            for column in 0..<resizedWidth {
                let value = luminance(row * targetWidth + column)
                histogram[min(255, max(0, Int(value.rounded())))] += 1
            }
        }
        let count = targetHeight * resizedWidth
        func percentile(_ percent: Int) -> Int {
            let rank = (count - 1) * percent / 100
            var cumulative = 0
            for value in 0..<256 {
                cumulative += histogram[value]
                if cumulative > rank { return value }
            }
            return 255
        }
        let low = percentile(2), high = percentile(98), span = high - low
        guard (32...192).contains(span) else { return }
        let gain = min(2, 255 / Double(span)), midpoint = Double(low + high) / 2
        for row in 0..<targetHeight {
            for column in 0..<resizedWidth {
                let index = row * targetWidth + column
                let transformed = min(255, max(0, (luminance(index) - midpoint) * gain + 127.5))
                let normalized = Float(transformed / 127.5 - 1)
                values[index] = normalized
                values[plane + index] = normalized
                values[plane * 2 + index] = normalized
            }
        }
    }

#if DEBUG
    /// Preserves the former CGPoint/closure implementation as a test-only
    /// oracle for the optimized contiguous sampling kernel.
    static func prepareReferenceForTesting(
        frame: NativeOCRRGBAFrame,
        polygon: [CGPoint]
    ) -> NativeCoreMLPreparedTensor? {
        guard let plan = plan(polygon: polygon) else { return nil }
        let targetWidth = plan.bucket.width
        let planeSize = targetHeight * targetWidth
        var values = [Float](repeating: 0, count: planeSize * 3)
        for row in 0..<targetHeight {
            for column in 0..<plan.resizedWidth {
                let orientedX =
                    (Double(column) + 0.5) * Double(plan.orientedWidth)
                    / Double(plan.resizedWidth) - 0.5
                let orientedY =
                    (Double(row) + 0.5) * Double(plan.orientedHeight)
                    / Double(targetHeight) - 0.5
                let warpedX: Double
                let warpedY: Double
                if plan.rotatedCounterClockwise {
                    warpedX = Double(plan.cropWidth - 1) - orientedY
                    warpedY = orientedX
                } else {
                    warpedX = orientedX
                    warpedY = orientedY
                }
                let u = min(max(warpedX / Double(plan.cropWidth), 0), 1)
                let v = min(max(warpedY / Double(plan.cropHeight), 0), 1)
                guard let source = plan.homography.sourcePoint(u: u, v: v)
                else {
                    return nil
                }
                let rgba = sampleBilinear(frame: frame, at: source)
                let destination = row * targetWidth + column
                values[destination] = normalize(rgba.blue)
                values[planeSize + destination] = normalize(rgba.green)
                values[planeSize * 2 + destination] = normalize(rgba.red)
            }
        }
        return NativeCoreMLPreparedTensor(
            values: values,
            resizedWidth: plan.resizedWidth,
            bucket: plan.bucket,
            rotatedCounterClockwise: plan.rotatedCounterClockwise
        )
    }
#endif

    private static func makeQuad(_ polygon: [CGPoint], useProvidedOrder: Bool = false) -> Quad? {
        let finite = polygon.filter {
            $0.x.isFinite && $0.y.isFinite
        }
        guard finite.count == polygon.count, finite.count >= 2 else {
            return nil
        }
        if finite.count == 4 {
            guard let p = useProvidedOrder ? finite : NativeOCRScopeGeometry.canonicalQuad(finite) else { return nil }
            let quad = Quad(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])
            guard abs(signedArea(quad)) > 0.5 else { return nil }
            return quad
        }

        guard let minimumX = finite.map(\.x).min(),
              let maximumX = finite.map(\.x).max(),
              let minimumY = finite.map(\.y).min(),
              let maximumY = finite.map(\.y).max(),
              maximumX - minimumX > 1,
              maximumY - minimumY > 1
        else {
            return nil
        }
        return Quad(
            topLeft: CGPoint(x: minimumX, y: minimumY),
            topRight: CGPoint(x: maximumX, y: minimumY),
            bottomRight: CGPoint(x: maximumX, y: maximumY),
            bottomLeft: CGPoint(x: minimumX, y: maximumY)
        )
    }

    private static func makeHomography(_ quad: Quad) -> Homography? {
        let x0 = Double(quad.topLeft.x)
        let y0 = Double(quad.topLeft.y)
        let x1 = Double(quad.topRight.x)
        let y1 = Double(quad.topRight.y)
        let x2 = Double(quad.bottomRight.x)
        let y2 = Double(quad.bottomRight.y)
        let x3 = Double(quad.bottomLeft.x)
        let y3 = Double(quad.bottomLeft.y)
        let dx1 = x1 - x2
        let dx2 = x3 - x2
        let dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2
        let dy2 = y3 - y2
        let dy3 = y0 - y1 + y2 - y3
        let g: Double
        let h: Double
        if abs(dx3) < 0.000_000_1, abs(dy3) < 0.000_000_1 {
            g = 0
            h = 0
        } else {
            let denominator = dx1 * dy2 - dx2 * dy1
            guard abs(denominator) > 0.000_000_1 else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / denominator
            h = (dx1 * dy3 - dx3 * dy1) / denominator
        }
        let homography = Homography(
            a: x1 - x0 + g * x1,
            b: x3 - x0 + h * x3,
            c: x0,
            d: y1 - y0 + g * y1,
            e: y3 - y0 + h * y3,
            f: y0,
            g: g,
            h: h
        )
        let values = [
            homography.a, homography.b, homography.c,
            homography.d, homography.e, homography.f,
            homography.g, homography.h,
        ]
        return values.allSatisfy(\.isFinite) ? homography : nil
    }

    private static func signedArea(_ quad: Quad) -> Double {
        let points = [
            quad.topLeft, quad.topRight,
            quad.bottomRight, quad.bottomLeft,
        ]
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += Double(points[index].x * next.y - next.x * points[index].y)
        }
        return area * 0.5
    }

    private static func distance(_ left: CGPoint, _ right: CGPoint) -> Double {
        hypot(Double(right.x - left.x), Double(right.y - left.y))
    }

    private struct SampledRGBA {
        let red: Double
        let green: Double
        let blue: Double
    }

    private static func sampleBilinear(
        frame: NativeOCRRGBAFrame,
        at point: CGPoint
    ) -> SampledRGBA {
        let x = min(max(Double(point.x), 0), Double(frame.width - 1))
        let y = min(max(Double(point.y), 0), Double(frame.height - 1))
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(x0 + 1, frame.width - 1)
        let y1 = min(y0 + 1, frame.height - 1)
        let xWeight = x - Double(x0)
        let yWeight = y - Double(y0)

        func channel(_ x: Int, _ y: Int, _ offset: Int) -> Double {
            Double(frame.bytes[y * frame.bytesPerRow + x * 4 + offset])
        }
        func interpolate(_ offset: Int) -> Double {
            let top = channel(x0, y0, offset) * (1 - xWeight)
                + channel(x1, y0, offset) * xWeight
            let bottom = channel(x0, y1, offset) * (1 - xWeight)
                + channel(x1, y1, offset) * xWeight
            return top * (1 - yWeight) + bottom * yWeight
        }
        return SampledRGBA(
            red: interpolate(0),
            green: interpolate(1),
            blue: interpolate(2)
        )
    }

    private static func normalize(_ channel: Double) -> Float {
        Float(channel / 127.5 - 1)
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLDecodedText: Equatable, Sendable {
    let text: String
    let confidence: Double
    var tokenObservations: [NativeCoreMLCTCTokenObservation] = []
    var languageModelCorrections: Int = 0
    var greedyObservation: NativeCoreMLGreedyRecognition? = nil
}

@available(iOS 18.0, *)
enum NativeCoreMLCTCDecoder {
    static func decode(
        output: MLMultiArray,
        dictionary: [String],
        expectedShape: [Int],
        languageModel: NativeMangaNGram? = nil,
        observeEmissionSpans: Bool = false,
        observeGreedy: Bool = false
    ) throws -> NativeCoreMLDecodedText {
        let actualShape = output.shape.map(\.intValue)
        if actualShape.count == 2,
           (actualShape[0] == 2 || actualShape[0] == 10),
           (4...400).contains(actualShape[1]) {
            var decoded = try decodeCompact(
                output: output,
                dictionary: dictionary,
                timeSteps: actualShape[1],
                observeEmissionSpans: observeEmissionSpans
            )
            if observeGreedy {
                decoded.greedyObservation = .init(text: decoded.text, confidence: decoded.confidence,
                    tokenObservations: decoded.tokenObservations)
            }
            guard actualShape[0] == 10, let languageModel else { return decoded }
            return try correctCompact(output: output, decoded: decoded, dictionary: dictionary,
                timeSteps: actualShape[1], model: languageModel)
        }
        guard actualShape == expectedShape,
              output.strides.count == 3
        else {
            throw NativeCoreMLRecognizerError.modelOutputShape(
                expected: expectedShape,
                actual: actualShape
            )
        }
        let timeSteps = actualShape[1]
        let classes = actualShape[2]
        guard dictionary.count + 1 == classes else {
            throw NativeCoreMLRecognizerError.dictionaryCharacterCount(
                expected: classes - 1,
                actual: dictionary.count
            )
        }
        let batchOffset = output.strides[0].intValue
        let timeStride = output.strides[1].intValue
        let classStride = output.strides[2].intValue
        var decoded: NativeCoreMLDecodedText
        switch output.dataType {
        case .float32:
            let pointer = output.dataPointer.assumingMemoryBound(
                to: Float.self
            )
            decoded = decode(
                pointer: pointer,
                batchOffset: 0 * batchOffset,
                timeSteps: timeSteps,
                classes: classes,
                timeStride: timeStride,
                classStride: classStride,
                dictionary: dictionary,
                observeEmissionSpans: observeEmissionSpans
            )
        case .float16:
            let pointer = output.dataPointer.assumingMemoryBound(
                to: Float16.self
            )
            decoded = decode(
                pointer: pointer,
                batchOffset: 0 * batchOffset,
                timeSteps: timeSteps,
                classes: classes,
                timeStride: timeStride,
                classStride: classStride,
                dictionary: dictionary,
                observeEmissionSpans: observeEmissionSpans
            )
        case .double:
            let pointer = output.dataPointer.assumingMemoryBound(
                to: Double.self
            )
            decoded = decode(
                pointer: pointer,
                batchOffset: 0 * batchOffset,
                timeSteps: timeSteps,
                classes: classes,
                timeStride: timeStride,
                classStride: classStride,
                dictionary: dictionary,
                observeEmissionSpans: observeEmissionSpans
            )
        default:
            throw NativeCoreMLRecognizerError.unsupportedModelOutputType
        }
        if observeGreedy {
            decoded.greedyObservation = .init(text: decoded.text, confidence: decoded.confidence,
                tokenObservations: decoded.tokenObservations)
        }
        return decoded
    }

    private static func correctCompact(output: MLMultiArray, decoded: NativeCoreMLDecodedText,
                                       dictionary: [String], timeSteps: Int, model: NativeMangaNGram) throws -> NativeCoreMLDecodedText {
        let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
        let rowStride = output.strides[0].intValue, timeStride = output.strides[1].intValue
        var previous = -1
        var candidates: [[NativeMangaNGram.Choice]] = []
        for step in 0..<timeSteps {
            let index = Int(pointer[step * timeStride])
            let score = Double(pointer[rowStride + step * timeStride])
            if index > 0 {
                let base = NativeMangaNGram.Choice(text: dictionary[index - 1], probability: score)
                if index != previous { candidates.append([base]) }
                if score >= (candidates.last?.first?.probability ?? 0) {
                    var choices = [base], seen: Set<Int> = [index]
                    for rank in 0..<4 {
                        let raw = pointer[(2 + rank * 2) * rowStride + step * timeStride]
                        let probability = pointer[(3 + rank * 2) * rowStride + step * timeStride]
                        guard raw.isFinite, raw.rounded(.towardZero) == raw, raw >= 0, raw <= Float(dictionary.count),
                              probability.isFinite, probability >= 0, probability <= 1.001 else {
                            throw NativeCoreMLRecognizerError.unsupportedModelOutputType
                        }
                        let alternative = Int(raw)
                        if alternative > 0, seen.insert(alternative).inserted {
                            choices.append(.init(text: dictionary[alternative - 1], probability: Double(probability)))
                        }
                    }
                    candidates[candidates.count - 1] = choices
                }
            }
            previous = index
        }
        guard candidates.count == decoded.tokenObservations.count else {
            throw NativeCoreMLRecognizerError.unsupportedModelOutputType
        }
        let result = model.correct(candidates)
        guard result.changedTokens > 0 else { return decoded }
        // Acceptance confidence remains the original visual confidence. LM
        // scores neither inflate nor replace the detector/recognizer signal.
        return NativeCoreMLDecodedText(text: result.choices.map(\.text).joined(), confidence: decoded.confidence,
            tokenObservations: zip(result.choices, decoded.tokenObservations).map { choice, original in
                .init(text: choice.text, confidence: choice.text == original.text ? original.confidence : choice.probability,
                      emissionSpan: original.emissionSpan)
            }, languageModelCorrections: result.changedTokens, greedyObservation: decoded.greedyObservation)
    }

    private static func decodeCompact(
        output: MLMultiArray,
        dictionary: [String],
        timeSteps: Int,
        observeEmissionSpans: Bool
    ) throws -> NativeCoreMLDecodedText {
        guard output.dataType == .float32,
              output.strides.count == 2,
              !dictionary.isEmpty
        else {
            throw NativeCoreMLRecognizerError.unsupportedModelOutputType
        }
        let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
        let rowStride = output.strides[0].intValue
        let timeStride = output.strides[1].intValue
        var collapse = Collapse(timeSteps: timeSteps, observeEmissionSpans: observeEmissionSpans)
        for step in 0..<timeSteps {
            let rawIndex = pointer[step * timeStride]
            let score = pointer[rowStride + step * timeStride]
            guard rawIndex.isFinite,
                  score.isFinite,
                  rawIndex.rounded(.towardZero) == rawIndex,
                  rawIndex >= 0,
                  rawIndex <= Float(dictionary.count),
                  score >= 0,
                  score <= 1.001
            else {
                throw NativeCoreMLRecognizerError.unsupportedModelOutputType
            }
            let index = Int(rawIndex)
            collapse.append(index: index, confidence: Double(score), step: step, dictionary: dictionary)
        }
        return collapse.result
    }

    private static func decode<Element: BinaryFloatingPoint>(
        pointer: UnsafePointer<Element>,
        batchOffset: Int,
        timeSteps: Int,
        classes: Int,
        timeStride: Int,
        classStride: Int,
        dictionary: [String],
        observeEmissionSpans: Bool
    ) -> NativeCoreMLDecodedText {
        var collapse = Collapse(timeSteps: timeSteps, observeEmissionSpans: observeEmissionSpans)
        for step in 0..<timeSteps {
            let stepOffset = batchOffset + step * timeStride
            var maximumIndex = 0
            var maximumValue = -Double.infinity
            for characterClass in 0..<classes {
                let value = Double(
                    pointer[stepOffset + characterClass * classStride]
                )
                if value > maximumValue {
                    maximumValue = value
                    maximumIndex = characterClass
                }
            }
            collapse.append(index: maximumIndex, confidence: maximumValue, step: step, dictionary: dictionary)
        }
        return collapse.result
    }

    /// Both output ABIs use the same first-emission confidence contract.
    /// Later repeated scores never replace the original acceptance signal.
    private struct Collapse {
        let timeSteps: Int
        let observeEmissionSpans: Bool
        var previousIndex = -1
        var precedingBlankSteps = 0
        var text = ""
        var confidenceSum = 0.0
        var tokens: [NativeCoreMLCTCTokenObservation] = []

        mutating func append(index: Int, confidence: Double, step: Int, dictionary: [String]) {
            if index > 0, index != previousIndex {
                let token = dictionary[index - 1]
                text += token
                confidenceSum += confidence
                tokens.append(.init(text: token, confidence: confidence,
                    emissionSpan: observeEmissionSpans ? .init(steps: step..<(step + 1),
                        timeStepCount: timeSteps, precedingBlankSteps: precedingBlankSteps) : nil))
            } else if index > 0, observeEmissionSpans, let span = tokens.last?.emissionSpan {
                tokens[tokens.count - 1].emissionSpan = .init(steps: span.steps.lowerBound..<(step + 1),
                    timeStepCount: timeSteps, precedingBlankSteps: span.precedingBlankSteps)
            }
            precedingBlankSteps = index == 0 ? precedingBlankSteps + 1 : 0
            previousIndex = index
        }

        var result: NativeCoreMLDecodedText {
            .init(text: text, confidence: tokens.isEmpty ? 0 : confidenceSum / Double(tokens.count), tokenObservations: tokens)
        }
    }
}

/// Read-only replay identity; uses the production crop-cache fingerprint without inference.
@available(iOS 18.0, *)
extension NativeCoreMLRecognitionPreprocessor {
    static func tensorIdentityForReplay(_ tensor: NativeCoreMLPreparedTensor) -> String {
        let fingerprint = NativeCoreMLRecognitionCropFingerprint(tensor: tensor)
        return String(format: "%016llx%016llx%016llx%016llx",
                      fingerprint.word0, fingerprint.word1,
                      fingerprint.word2, fingerprint.word3)
    }
}
