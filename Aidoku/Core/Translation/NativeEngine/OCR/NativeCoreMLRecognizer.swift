// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
@preconcurrency import CoreML
import CryptoKit
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionRegion: Equatable, Sendable {
    let sourceIndex: Int
    let polygon: [CGPoint]
    let useProvidedOrder: Bool

    init(sourceIndex: Int, polygon: [CGPoint], useProvidedOrder: Bool = false) {
        self.sourceIndex = sourceIndex
        self.polygon = polygon
        self.useProvidedOrder = useProvidedOrder
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognizedRegion: Equatable, Sendable {
    let sourceIndex: Int
    let polygon: [CGPoint]
    let text: String
    let confidence: Double
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
    let acceptedRegions: Int
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

    func addingRecovery(_ recovery: Self, acceptedCount: Int) -> Self {
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
            requestedRegions: requestedRegions,
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

    var output: MLMultiArray { outputs[0] }

    init(
        output: MLMultiArray,
        modelWasLoaded: Bool,
        modelLoadMilliseconds: Double
    ) {
        outputs = [output]
        self.modelWasLoaded = modelWasLoaded
        self.modelLoadMilliseconds = modelLoadMilliseconds
    }

    init(
        outputs: [MLMultiArray],
        modelWasLoaded: Bool,
        modelLoadMilliseconds: Double
    ) {
        self.outputs = outputs
        self.modelWasLoaded = modelWasLoaded
        self.modelLoadMilliseconds = modelLoadMilliseconds
    }
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
        private let sharedLoads = NativeCoreMLSharedLoadCoordinator<
            NativeCoreMLRecognitionModelVariant,
            LoadedModel
        >()

        init(
            asset: MLModelAsset,
            maximumResidentModels: Int,
            usesDynamicModel: Bool
        ) {
            precondition((2...3).contains(maximumResidentModels))
            self.asset = asset
            self.maximumResidentModels = maximumResidentModels
            self.usesDynamicModel = usesDynamicModel
        }

        func model(
            for variant: NativeCoreMLRecognitionModelVariant,
            allowsEviction: Bool = true,
            minimumFreeResidentSlots: Int = 0,
            admissionCheck: @escaping @Sendable () throws -> Void = {}
        ) async throws -> ModelAccess? {
            try admissionCheck()
            let headroom = ReaderTranslationSession.processAvailableMemory()
            let residentLimit = headroom < 2 * 1_024 * 1_024 * 1_024 ? min(2, maximumResidentModels) : maximumResidentModels
            let modelKey = storageKey(for: variant)
            if !allowsEviction, headroom < 2 * 1_024 * 1_024 * 1_024 { return nil }
            trimResidents(to: residentLimit, preserving: modelKey)
            if let model = models[modelKey] {
                try admissionCheck()
                if allowsEviction {
                    markDemanded(variant)
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

    init(
        modelURL: URL,
        modelName: String,
        inputFeatureName: String,
        outputFeatureName: String,
        maximumResidentModels: Int
    ) async throws {
        let asset = try MLModelAsset(url: modelURL)
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
            maximumResidentModels: maximumResidentModels,
            usesDynamicModel: usesDynamicModel
        )
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
        guard let modelAccess = try await modelStore.model(for: variant)
        else {
            throw NativeCoreMLRecognizerError.modelInputCreationFailed
        }
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
        try await modelStore.markPrepared(variant, access: modelAccess)
        return NativeCoreMLRecognitionPrediction(
            outputs: try Self.packCompactOutputs(
                indices: indices,
                scores: scores,
                variant: variant
            ),
            modelWasLoaded: modelAccess.wasLoaded,
            modelLoadMilliseconds: modelAccess.loadMilliseconds
        )
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
        variant: NativeCoreMLRecognitionModelVariant
    ) throws -> [MLMultiArray] {
        let expected = [variant.batchSize, variant.bucket.timeSteps]
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
        var outputs: [MLMultiArray] = []
        outputs.reserveCapacity(variant.batchSize)
        for batchIndex in 0..<variant.batchSize {
            let compact = try MLMultiArray(
                shape: [2, variant.bucket.timeSteps].map(
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
        guard (160...2_000).contains(width), width.isMultiple(of: 32) else {
            return nil
        }
        self.width = width
        timeSteps = width / 8
    }

    private init?(width: Int, timeSteps: Int) {
        self.init(width: width)
        guard self.timeSteps == timeSteps else { return nil }
    }

    static func containing(
        desiredWidth: Int,
        dynamicWidth: Bool = false,
        maximumWidth: Int = 2_000
    ) -> Self {
        let alignedMaximum = max(
            160,
            min(2_000, maximumWidth) / 32 * 32
        )
        if dynamicWidth {
            let bounded = min(alignedMaximum, max(160, desiredWidth))
            let aligned = min(
                alignedMaximum,
                ((bounded + 31) / 32) * 32
            )
            return Self(width: aligned)!
        }
        let admitted = all.filter { $0.width <= alignedMaximum }
        let available = admitted.isEmpty ? [all[0]] : admitted
        return available.first { desiredWidth <= $0.width }
            ?? available[available.count - 1]
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
        let metadata = [
            UInt64(tensor.resizedWidth).littleEndian,
            UInt64(tensor.bucket.width).littleEndian,
            tensor.rotatedCounterClockwise ? UInt64(1) : UInt64(0),
        ]
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
private struct NativeCoreMLCachedRecognition: Sendable {
    let text: String
    let confidence: Double
}

/// A small lock-protected LRU. Values contain no source pixels or tensors;
/// only the fixed-width digest and decoded text survive between frames.
@available(iOS 18.0, *)
private final class NativeCoreMLRecognitionCropCache: @unchecked Sendable {
    private struct Entry {
        let value: NativeCoreMLCachedRecognition
        var recency: UInt64
    }

    private let lock = NSLock()
    private let capacity: Int
    private var clock: UInt64 = 0
    private var epoch: UInt64 = 0
    private var entries: [
        NativeCoreMLRecognitionCropFingerprint: Entry
    ] = [:]

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        entries.reserveCapacity(max(0, capacity))
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
                guard var entry = entries[fingerprint] else { return nil }
                clock &+= 1
                entry.recency = clock
                entries[fingerprint] = entry
                return entry.value
            }
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
            clock &+= 1
            entries[fingerprint] = Entry(value: value, recency: clock)
            guard entries.count > capacity,
                  let oldest = entries.min(by: {
                      $0.value.recency < $1.value.recency
                  })?.key
            else {
                return
            }
            entries.removeValue(forKey: oldest)
        }
    }

    func removeAll() {
        lock.withLock {
            epoch &+= 1
            entries.removeAll(keepingCapacity: false)
            clock = 0
        }
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
    static let modelResourceName = "PP-OCRv6-Medium-RecWidths"
    static let dictionaryResourceName =
        "ppocrv6_medium_rec_character_dict"
    static let inputFeatureName = "x"
    static let indexOutputFeatureName = "ctc_indices"
    static let scoreOutputFeatureName = "ctc_scores"
    static let outputFeatureName =
        "\(indexOutputFeatureName)+\(scoreOutputFeatureName)"
    /// Maximum bounded dynamic-width contract reported in diagnostics.
    static let inputShape = [1, 3, 48, 2_000]
    static let outputShape = [2, 250]
    static let expectedDictionaryCharacterCount = 18_709
    static let maximumConcurrentPreparations = 4
    static let maximumPreparedRegionCount = 8
    static let maximumPreparedWindowRegionCount = maximumPreparedRegionCount / 2
    static let maximumPreparedTensorBytes =
        maximumPreparedRegionCount * 3 * 48 * 2_000
            * MemoryLayout<Float>.stride
    static let defaultRecognitionCacheCapacity = 512
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
    private let maximumRecognitionWidth: Int
    private let recognitionCropCache: NativeCoreMLRecognitionCropCache
    private let auditObserver: (@Sendable (NativeCoreMLRecognitionAuditEvent) -> Void)?
    private var storedDiagnostics: NativeCoreMLRecognitionDiagnostics?

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
        maximumRecognitionWidth: Int = 2_000,
        auditObserver: (@Sendable (NativeCoreMLRecognitionAuditEvent) -> Void)? = nil
    ) {
        self.auditObserver = auditObserver
        dynamicWidthEnabled = modelResourceName.hasSuffix("-RecWidths")
        self.maximumRecognitionWidth = maximumRecognitionWidth
        let residentModelLimit = idleLongWidthPreparationEnabled ? 3 : 2
        let alignedMaximumWidth = max(
            160,
            min(2_000, maximumRecognitionWidth) / 32 * 32
        )
        preparationVariants = dynamicWidthEnabled
            ? [NativeCoreMLRecognitionModelVariant(width: 320, batchSize: 1)!]
            : (Self.commonPreparationVariants
                + (idleLongWidthPreparationEnabled
                    ? [Self.longWidthPreparationVariant]
                    : [])).filter {
                        $0.bucket.width <= alignedMaximumWidth
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
        auditObserver: (@Sendable (NativeCoreMLRecognitionAuditEvent) -> Void)? = nil
    ) throws {
        self.auditObserver = auditObserver
        dynamicWidthEnabled = dynamicWidth
        maximumRecognitionWidth = 2_000
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
              ReaderTranslationSession.processAvailableMemory() >= 2 * 1_024 * 1_024 * 1_024 else { return }
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
        let recognitionCacheEpoch = recognitionCropCache.currentEpoch()
        let started = Self.nowMilliseconds()

        return try await withTaskCancellationHandler {
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )
            let resourceAccess = try await resourceStore.load()
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
            let threshold = min(max(confidenceThreshold, 0), 1)
            var plannedRegions: [NativeCoreMLPlannedRegionWork] = []
            plannedRegions.reserveCapacity(regions.count)

            for region in regions {
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                if let auditObserver {
                    auditObserver(.requested(requestID: requestID, region: region))
                }
                let preprocessingStarted = Self.nowMilliseconds()
                let plan = NativeCoreMLRecognitionPreprocessor.plan(
                    polygon: region.polygon,
                    dynamicWidth: dynamicWidthEnabled,
                    maximumWidth: maximumRecognitionWidth,
                    useProvidedOrder: region.useProvidedOrder
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
                    let chunkSize = usesBatchFour ? min(4, remaining) : 1
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

            // Four current tensors plus at most four lookahead tensors retain
            // the existing eight-region byte budget. Prepare the next window
            // while Core ML predicts the current one, keeping model calls and
            // cache admission strictly serial in the established width order.
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

                for preparedChunk in preparedWindow.chunks {
                    let step = try await recognizePreparedChunk(
                        preparedChunk,
                        requestID: requestID,
                        threshold: threshold,
                        predictor: resourceAccess.resources.predictor,
                        dictionary: resourceAccess.resources.dictionary,
                        recognitionCacheEpoch: recognitionCacheEpoch,
                        generation: issuedGeneration,
                        cancellationCheck: cancellationCheck
                    )
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
                inputShape: Self.inputShape,
                outputShape: Self.outputShape,
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
        var regionCount = 0
        while end < chunks.count {
            let nextCount = chunks[end].works.count
            if end > start,
               regionCount + nextCount > maximumPreparedWindowRegionCount {
                break
            }
            regionCount += nextCount
            end += 1
        }
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

    /// Runs prediction for one already-prepared chunk. Prediction itself is
    /// deliberately serial; only CPU crop preparation is globally concurrent.
    private func recognizePreparedChunk(
        _ chunk: NativeCoreMLPreparedRegionChunk,
        requestID: String,
        threshold: Double,
        predictor: any NativeCoreMLRecognitionPredicting,
        dictionary: [String],
        recognitionCacheEpoch: UInt64,
        generation issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLRecognitionStreamingChunkStep {
        let preparedWorks = chunk.works
        let requestedModelBatchSize = chunk.modelBatchSize
        precondition(
            dynamicWidthEnabled
                ? (1...NativeCoreMLRecognitionModelVariant.maximumBatchSize).contains(requestedModelBatchSize)
                : (requestedModelBatchSize == 1 || requestedModelBatchSize == 4)
        )
        var preprocessingMilliseconds = 0.0
        guard !preparedWorks.isEmpty else {
            return NativeCoreMLRecognitionStreamingChunkStep(
                recognizedRegions: [],
                predictedRegions: 0,
                cacheHitRegions: 0,
                skippedInvalidRegions: 0,
                modelFunctionSequence: [],
                modelFunctionLoadSequence: [],
                modelFunctionLoads: 0,
                modelFunctionLoadMilliseconds: 0,
                preprocessingMilliseconds: 0,
                predictionMilliseconds: 0,
                decodingMilliseconds: 0
            )
        }

        try requireCurrent(
            issuedGeneration,
            cancellationCheck: cancellationCheck
        )
        let cachedValues = recognitionCropCache.values(
            for: preparedWorks.map(\.fingerprint)
        )
        var recognizedRegions: [NativeCoreMLRecognizedRegion] = []
        var uncachedWorks: [NativeCoreMLPreparedRegionWork] = []
        uncachedWorks.reserveCapacity(preparedWorks.count)
        var cacheHitRegions = 0
        for (preparedWork, cached) in zip(preparedWorks, cachedValues) {
            guard let cached else {
                uncachedWorks.append(preparedWork)
                continue
            }
            cacheHitRegions += 1
            if let auditObserver {
                auditObserver(.decoded(
                    requestID: requestID, region: preparedWork.work.region,
                    text: cached.text, confidence: cached.confidence,
                    threshold: threshold, cacheHit: true
                ))
            }
            if !cached.text.isEmpty, cached.confidence >= threshold {
                recognizedRegions.append(NativeCoreMLRecognizedRegion(
                    sourceIndex: preparedWork.work.region.sourceIndex,
                    polygon: preparedWork.work.region.polygon,
                    text: cached.text,
                    confidence: cached.confidence
                ))
            }
        }

        guard !uncachedWorks.isEmpty else {
            return NativeCoreMLRecognitionStreamingChunkStep(
                recognizedRegions: recognizedRegions,
                predictedRegions: 0,
                cacheHitRegions: cacheHitRegions,
                skippedInvalidRegions: 0,
                modelFunctionSequence: [],
                modelFunctionLoadSequence: [],
                modelFunctionLoads: 0,
                modelFunctionLoadMilliseconds: 0,
                preprocessingMilliseconds: 0,
                predictionMilliseconds: 0,
                decodingMilliseconds: 0
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
        var predictedRegions = 0
        var modelFunctionSequence: [String] = []
        var modelFunctionLoadSequence: [String] = []
        var modelFunctionLoads = 0
        var modelFunctionLoadMilliseconds = 0.0
        var predictionMilliseconds = 0.0
        var decodingMilliseconds = 0.0

        for group in predictionGroups {
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )
            let packingStarted = Self.nowMilliseconds()
            guard let variant = NativeCoreMLRecognitionModelVariant(
                bucket: group[0].tensor.bucket,
                batchSize: modelBatchSize
            ) else {
                throw NativeCoreMLRecognizerError.modelInputCreationFailed
            }
            let input = try Self.makeInputArray(
                tensors: group.map(\.tensor),
                modelBatchSize: modelBatchSize
            )
            preprocessingMilliseconds += Self.nowMilliseconds()
                - packingStarted

            let predictionStarted = Self.nowMilliseconds()
            let prediction: NativeCoreMLRecognitionPrediction
            do {
                prediction = try await predict(
                    input: input,
                    using: predictor,
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
            guard prediction.outputs.count == modelBatchSize else {
                throw NativeCoreMLRecognizerError.modelOutputShape(
                    expected: [modelBatchSize],
                    actual: [prediction.outputs.count]
                )
            }
            modelFunctionSequence.append(variant.functionName)
            predictedRegions += group.count
            if prediction.modelWasLoaded {
                modelFunctionLoadSequence.append(variant.functionName)
                modelFunctionLoads += 1
            }
            modelFunctionLoadMilliseconds +=
                prediction.modelLoadMilliseconds
            predictionMilliseconds += max(
                0,
                predictionTotalMilliseconds
                    - prediction.modelLoadMilliseconds
            )
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )

            for (preparedWork, output) in zip(group, prediction.outputs) {
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                let decodingStarted = Self.nowMilliseconds()
                let decoded = try NativeCoreMLCTCDecoder.decode(
                    output: output,
                    dictionary: dictionary,
                    expectedShape: Self.outputShape
                )
                decodingMilliseconds += Self.nowMilliseconds()
                    - decodingStarted
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                recognitionCropCache.insert(
                    NativeCoreMLCachedRecognition(
                        text: decoded.text,
                        confidence: decoded.confidence
                    ),
                    for: preparedWork.fingerprint,
                    ifCurrent: recognitionCacheEpoch
                )
                if let auditObserver {
                    auditObserver(.decoded(
                        requestID: requestID, region: preparedWork.work.region,
                        text: decoded.text, confidence: decoded.confidence,
                        threshold: threshold, cacheHit: false
                    ))
                }
                if !decoded.text.isEmpty,
                   decoded.confidence >= threshold {
                    recognizedRegions.append(
                        NativeCoreMLRecognizedRegion(
                            sourceIndex:
                                preparedWork.work.region.sourceIndex,
                            polygon: preparedWork.work.region.polygon,
                            text: decoded.text,
                            confidence: decoded.confidence
                        )
                    )
                }
            }
        }
        return NativeCoreMLRecognitionStreamingChunkStep(
            recognizedRegions: recognizedRegions,
            predictedRegions: predictedRegions,
            cacheHitRegions: cacheHitRegions,
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
        generation issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLRecognitionPrediction {
        try requireCurrent(
            issuedGeneration,
            cancellationCheck: cancellationCheck
        )
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
    let recognizedRegions: [NativeCoreMLRecognizedRegion]
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

@available(iOS 18.0, *)
struct NativeCoreMLPreparedTensor: Equatable, Sendable {
    let values: [Float]
    let resizedWidth: Int
    let bucket: NativeCoreMLRecognitionBucket
    let rotatedCounterClockwise: Bool
}

@available(iOS 18.0, *)
enum NativeCoreMLRecognitionPreprocessor {
    static let targetHeight = 48
    static let maximumTargetWidth = 2_000

    struct Plan: Sendable {
        let resizedWidth: Int
        let bucket: NativeCoreMLRecognitionBucket
        let rotatedCounterClockwise: Bool
        fileprivate let cropWidth: Int
        fileprivate let cropHeight: Int
        fileprivate let orientedWidth: Int
        fileprivate let orientedHeight: Int
        fileprivate let homography: Homography
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
        maximumWidth: Int = 2_000,
        useProvidedOrder: Bool = false
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

        let rotated = Double(cropHeight) / Double(cropWidth) >= 1.5
        let orientedWidth = rotated ? cropHeight : cropWidth
        let orientedHeight = rotated ? cropWidth : cropHeight
        let ratio = Double(orientedWidth) / Double(max(1, orientedHeight))
        let desiredWidth = Int(min(
            Double(maximumTargetWidth),
            max(1, ceil(Double(targetHeight) * ratio))
        ))
        let bucket = NativeCoreMLRecognitionBucket.containing(
            desiredWidth: desiredWidth,
            dynamicWidth: dynamicWidth,
            maximumWidth: maximumWidth
        )
        let resizedWidth = min(bucket.width, desiredWidth)
        return Plan(
            resizedWidth: resizedWidth,
            bucket: bucket,
            rotatedCounterClockwise: rotated,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            orientedWidth: orientedWidth,
            orientedHeight: orientedHeight,
            homography: homography
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
        var valid = true
        // Each column uses the same normalized crop coordinate on all 48
        // rows. Keep the scalar operation order, but calculate it only once.
        let columnCoordinates = (0..<plan.resizedWidth).map { column in
            let orientedX = (Double(column) + 0.5) * orientedWidth / resizedWidth - 0.5
            return min(max(orientedX / (plan.rotatedCounterClockwise ? cropHeight : cropWidth), 0), 1)
        }

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
                for row in 0..<targetHeight {
                    let orientedY =
                        (Double(row) + 0.5) * orientedHeight
                        / Double(targetHeight) - 0.5
                    let rowCoordinate = plan.rotatedCounterClockwise
                        ? min(max((Double(plan.cropWidth - 1) - orientedY) / cropWidth, 0), 1)
                        : min(max(orientedY / cropHeight, 0), 1)
                    for column in 0..<plan.resizedWidth {
                        let u = plan.rotatedCounterClockwise ? rowCoordinate : columnCoordinates[column]
                        let v = plan.rotatedCounterClockwise ? columnCoordinates[column] : rowCoordinate
                        let denominator = homography.g * u
                            + homography.h * v + 1
                        guard denominator.isFinite,
                              abs(denominator) > 0.000_000_1
                        else {
                            valid = false
                            return
                        }
                        let sourceX = min(max(
                            (homography.a * u + homography.b * v
                                + homography.c) / denominator,
                            0
                        ), sourceMaximumX)
                        let sourceY = min(max(
                            (homography.d * u + homography.e * v
                                + homography.f) / denominator,
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
                        let xWeight = sourceX - Double(x0)
                        let yWeight = sourceY - Double(y0)
                        let inverseXWeight = 1 - xWeight
                        let inverseYWeight = 1 - yWeight
                        let topLeft = y0 * frame.bytesPerRow + x0 * 4
                        let topRight = y0 * frame.bytesPerRow + x1 * 4
                        let bottomLeft = y1 * frame.bytesPerRow + x0 * 4
                        let bottomRight = y1 * frame.bytesPerRow + x1 * 4

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
        return NativeCoreMLPreparedTensor(
            values: values,
            resizedWidth: plan.resizedWidth,
            bucket: plan.bucket,
            rotatedCounterClockwise: plan.rotatedCounterClockwise
        )
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
}

@available(iOS 18.0, *)
enum NativeCoreMLCTCDecoder {
    static func decode(
        output: MLMultiArray,
        dictionary: [String],
        expectedShape: [Int]
    ) throws -> NativeCoreMLDecodedText {
        let actualShape = output.shape.map(\.intValue)
        if actualShape.count == 2,
           actualShape[0] == 2,
           (20...400).contains(actualShape[1]),
           actualShape[1].isMultiple(of: 4) {
            return try decodeCompact(
                output: output,
                dictionary: dictionary,
                timeSteps: actualShape[1]
            )
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
        switch output.dataType {
        case .float32:
            let pointer = output.dataPointer.assumingMemoryBound(
                to: Float.self
            )
            return decode(
                pointer: pointer,
                batchOffset: 0 * batchOffset,
                timeSteps: timeSteps,
                classes: classes,
                timeStride: timeStride,
                classStride: classStride,
                dictionary: dictionary
            )
        case .float16:
            let pointer = output.dataPointer.assumingMemoryBound(
                to: Float16.self
            )
            return decode(
                pointer: pointer,
                batchOffset: 0 * batchOffset,
                timeSteps: timeSteps,
                classes: classes,
                timeStride: timeStride,
                classStride: classStride,
                dictionary: dictionary
            )
        case .double:
            let pointer = output.dataPointer.assumingMemoryBound(
                to: Double.self
            )
            return decode(
                pointer: pointer,
                batchOffset: 0 * batchOffset,
                timeSteps: timeSteps,
                classes: classes,
                timeStride: timeStride,
                classStride: classStride,
                dictionary: dictionary
            )
        default:
            throw NativeCoreMLRecognizerError.unsupportedModelOutputType
        }
    }

    private static func decodeCompact(
        output: MLMultiArray,
        dictionary: [String],
        timeSteps: Int
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
        var previousIndex = -1
        var text = ""
        var confidenceSum = 0.0
        var confidenceCount = 0
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
            if index > 0, index != previousIndex {
                text += dictionary[index - 1]
                confidenceSum += Double(score)
                confidenceCount += 1
            }
            previousIndex = index
        }
        return NativeCoreMLDecodedText(
            text: text,
            confidence: confidenceCount == 0
                ? 0
                : confidenceSum / Double(confidenceCount)
        )
    }

    private static func decode<Element: BinaryFloatingPoint>(
        pointer: UnsafePointer<Element>,
        batchOffset: Int,
        timeSteps: Int,
        classes: Int,
        timeStride: Int,
        classStride: Int,
        dictionary: [String]
    ) -> NativeCoreMLDecodedText {
        var previousIndex = -1
        var text = ""
        var confidenceSum = 0.0
        var confidenceCount = 0
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
            if maximumIndex > 0, maximumIndex != previousIndex {
                text += dictionary[maximumIndex - 1]
                confidenceSum += maximumValue
                confidenceCount += 1
            }
            previousIndex = maximumIndex
        }
        return NativeCoreMLDecodedText(
            text: text,
            confidence: confidenceCount == 0
                ? 0
                : confidenceSum / Double(confidenceCount)
        )
    }
}
