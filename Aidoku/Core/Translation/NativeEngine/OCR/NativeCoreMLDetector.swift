// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
@preconcurrency import CoreML
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLDetectionBox: Equatable, Sendable {
    let polygon: [CGPoint]
    let score: Double
    /// Probability-supported ink belongs to erasure only, never recognition geometry.
    let erasurePolygons: [[CGPoint]]
    /// Map- and neighbor-supported fine print may sample a little more context
    /// for recognition. It never enlarges detection or erasure ownership.
    let recognitionPolygon: [CGPoint]?
    let isThinFinePrintRecovery: Bool
    let finePrintRetryPolygons: [[CGPoint]]
    /// Independently measured DB recognition children; erasure polygons never substitute for these.
    let recognitionColumnEvidence: NativeOCRDetectorColumnEvidence?
    /// Exact original DB component cells for downstream source ownership.
    let detectorSeedEvidence: NativeOCRDetectorSeedEvidence?
    /// A separately sampled proposal from this same detector parent.
    let alternateRecognitionPolygon: [CGPoint]?

    init(polygon: [CGPoint], score: Double, erasurePolygons: [[CGPoint]] = [],
         recognitionPolygon: [CGPoint]? = nil, isThinFinePrintRecovery: Bool = false,
         finePrintRetryPolygons: [[CGPoint]] = [],
         recognitionColumnEvidence: NativeOCRDetectorColumnEvidence? = nil,
         detectorSeedEvidence: NativeOCRDetectorSeedEvidence? = nil,
         alternateRecognitionPolygon: [CGPoint]? = nil) {
        self.polygon = polygon
        self.score = score
        self.erasurePolygons = erasurePolygons
        self.recognitionPolygon = recognitionPolygon
        self.isThinFinePrintRecovery = isThinFinePrintRecovery
        self.finePrintRetryPolygons = finePrintRetryPolygons
        self.recognitionColumnEvidence = recognitionColumnEvidence
        self.detectorSeedEvidence = detectorSeedEvidence
        self.alternateRecognitionPolygon = alternateRecognitionPolygon
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionCanvas: Equatable, Hashable, Sendable {
    let width: Int
    let height: Int

    var inputShape: [Int] { [1, 3, height, width] }
    var outputShape: [Int] { [1, 1, height, width] }

    init?(inputShape: [Int]) {
        guard inputShape.count == 4,
              inputShape[0] == 1,
              inputShape[1] == 3,
              (32...2_000).contains(inputShape[2]),
              (32...2_000).contains(inputShape[3]),
              inputShape[2].isMultiple(of: 32),
              inputShape[3].isMultiple(of: 32)
        else {
            return nil
        }
        self.init(width: inputShape[3], height: inputShape[2])
    }

    static func exact(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumSide: Int = IPhoneOCRSettings.defaultDetectorMaximumSide
    ) -> Self? {
        guard let dimensions = NativeCoreMLDetectionPreprocessor
            .resizeDimensions(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                maximumSide: maximumSide
            )
        else {
            return nil
        }
        return Self(width: dimensions.width, height: dimensions.height)
    }

    private init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionDiagnostics: Equatable, Sendable {
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
    let sourceWidth: Int
    let sourceHeight: Int
    let resizedWidth: Int
    let resizedHeight: Int
    let threshold: Double
    let boxThreshold: Double
    let unclipRatio: Double
    let maximumCandidates: Int
    let candidateComponents: Int
    let detectedBoxes: Int
    let modelWasAlreadyLoaded: Bool
    let modelLoadMilliseconds: Double
    let inputTensorCreationMilliseconds: Double
    let tensorGraphMilliseconds: Double
    let preprocessingMilliseconds: Double
    let predictionMilliseconds: Double
    let outputMaterializationMilliseconds: Double
    let dbPostprocessingMilliseconds: Double
    let postprocessingMilliseconds: Double
    let totalMilliseconds: Double
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionResult: Equatable, Sendable {
    let requestID: String
    let width: Int
    let height: Int
    let boxes: [NativeCoreMLDetectionBox]
    let diagnostics: NativeCoreMLDetectionDiagnostics
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionMapRegion: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maximumX: Int { x + width }
    var maximumY: Int { y + height }
    var pixelCount: Int { width * height }

    init(x: Int, y: Int, width: Int, height: Int) {
        precondition(x >= 0 && y >= 0 && width > 0 && height > 0)
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    static func full(width: Int, height: Int) -> Self {
        Self(x: 0, y: 0, width: width, height: height)
    }
}

/// Converts source-coordinate dirty scopes into one conservative probability
/// map window. A single union avoids duplicate components and ordering drift.
/// Wide/fragmented invalidations deliberately fall back to the full map.
@available(iOS 18.0, *)
enum NativeCoreMLDetectionScopePlanner {
    static let minimumSourceExpansion = 64.0
    static let maximumROIAreaFraction = 0.625

    static func region(
        scopes: [CGRect],
        sourceWidth: Int,
        sourceHeight: Int,
        mapWidth: Int,
        mapHeight: Int
    ) -> NativeCoreMLDetectionMapRegion? {
        guard sourceWidth > 0, sourceHeight > 0,
              mapWidth > 0, mapHeight > 0,
              !scopes.isEmpty
        else {
            return nil
        }
        let sourceBounds = CGRect(
            x: 0,
            y: 0,
            width: sourceWidth,
            height: sourceHeight
        )
        let clipped = scopes.compactMap { scope -> CGRect? in
            guard scope.origin.x.isFinite, scope.origin.y.isFinite,
                  scope.size.width.isFinite, scope.size.height.isFinite
            else {
                return nil
            }
            let value = scope.standardized.intersection(sourceBounds)
            return value.isNull || value.isEmpty ? nil : value
        }
        guard var union = clipped.first else { return nil }
        for scope in clipped.dropFirst() {
            union = union.union(scope)
        }
        let expanded = union.insetBy(
            dx: -minimumSourceExpansion,
            dy: -minimumSourceExpansion
        ).intersection(sourceBounds)
        guard !expanded.isNull, !expanded.isEmpty else { return nil }

        let scaleX = Double(mapWidth) / Double(sourceWidth)
        let scaleY = Double(mapHeight) / Double(sourceHeight)
        // One extra map cell covers source/output rounding and the bilinear
        // detector grid boundary in addition to the required 64 source pixels.
        let minimumX = max(
            0,
            Int(floor(Double(expanded.minX) * scaleX)) - 1
        )
        let minimumY = max(
            0,
            Int(floor(Double(expanded.minY) * scaleY)) - 1
        )
        let maximumX = min(
            mapWidth,
            Int(ceil(Double(expanded.maxX) * scaleX)) + 1
        )
        let maximumY = min(
            mapHeight,
            Int(ceil(Double(expanded.maxY) * scaleY)) + 1
        )
        guard maximumX > minimumX, maximumY > minimumY else { return nil }
        let region = NativeCoreMLDetectionMapRegion(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
        let fullPixelCount = mapWidth * mapHeight
        guard region.pixelCount < fullPixelCount,
              Double(region.pixelCount) / Double(fullPixelCount)
                <= maximumROIAreaFraction
        else {
            return nil
        }
        return region
    }
}

@available(iOS 18.0, *)
enum NativeCoreMLDetectorError: Error, Equatable, LocalizedError {
    case modelResourceMissing
    case modelLoadFailed(String)
    case imageConversionFailed
    case modelInputCreationFailed
    case modelOutputMissing
    case modelOutputShape(expected: [Int], actual: [Int])
    case unsupportedInputShape(
        sourceWidth: Int,
        sourceHeight: Int,
        resizedWidth: Int,
        resizedHeight: Int
    )
    case unsupportedModelOutputType
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelResourceMissing:
            NSLocalizedString("OCR_ERROR_MODEL_MISSING")
        case .modelLoadFailed:
            NSLocalizedString("OCR_ERROR_MODEL_LOAD")
        case .imageConversionFailed, .modelInputCreationFailed, .unsupportedInputShape:
            NSLocalizedString("OCR_ERROR_IMAGE")
        case .modelOutputMissing, .modelOutputShape, .unsupportedModelOutputType:
            NSLocalizedString("OCR_ERROR_OUTPUT")
        case .predictionFailed:
            NSLocalizedString("OCR_ERROR_PREDICTION")
        }
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionPrediction: Sendable {
    let output: MLTensor
    let modelWasLoaded: Bool
    let modelLoadMilliseconds: Double
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionArrayPrediction: @unchecked Sendable {
    let output: MLMultiArray
    let modelWasLoaded: Bool
    let modelLoadMilliseconds: Double
}

@available(iOS 18.0, *)
private final class NativeCoreMLDetectorModelPredictor: Sendable {
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

    private actor ModelStore {
        private let asset: MLModelAsset
        private let computeUnits: MLComputeUnits
        private var model: ModelHandle?
        private var preparedCanvases: Set<NativeCoreMLDetectionCanvas> = []
        private var revision: UInt64 = 0
        private let sharedLoads = NativeCoreMLSharedLoadCoordinator<
            String,
            LoadedModel
        >()

        init(asset: MLModelAsset, computeUnits: MLComputeUnits) {
            self.asset = asset
            self.computeUnits = computeUnits
        }

        func model(
            for canvas: NativeCoreMLDetectionCanvas? = nil,
            admissionCheck: @escaping @Sendable () throws -> Void = {}
        ) async throws -> ModelAccess {
            try admissionCheck()
            let issuedRevision = revision
            if let model {
                try admissionCheck()
                return ModelAccess(
                    handle: model,
                    wasLoaded: false,
                    loadMilliseconds: 0,
                    revision: issuedRevision,
                    isPrepared: canvas.map { preparedCanvases.contains($0) } ?? false
                )
            }
            let asset = self.asset
            let computeUnits = self.computeUnits
            let access = try await sharedLoads.load(for: "dynamic") {
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = computeUnits
                    configuration.modelDisplayName = "PP-OCRv6 Dynamic"
                    configuration.optimizationHints.reshapeFrequency =
                        .frequent
                    configuration.optimizationHints.specializationStrategy =
                        .fastPrediction
                    try Task.checkCancellation()
                    let started =
                        ProcessInfo.processInfo.systemUptime * 1_000
                    let handle = ModelHandle(model: try await MLModel.load(
                        asset: asset,
                        configuration: configuration
                    ))
                    return LoadedModel(
                        handle: handle,
                        loadMilliseconds:
                            ProcessInfo.processInfo.systemUptime * 1_000
                                - started
                    )
            }
            guard issuedRevision == revision else {
                throw CancellationError()
            }
            try admissionCheck()
            let loaded = access.value
            let admittedModel = model == nil
            model = loaded.handle
            do {
                try admissionCheck()
            } catch {
                if admittedModel {
                    model = nil
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

        /// Records a completed, materialized prediction only while the exact
        /// resident handle and purge revision that produced it are current.
        /// Cancellation after GPU submission therefore cannot mark a stale or
        /// evicted specialization as warm.
        func markPrepared(
            _ canvas: NativeCoreMLDetectionCanvas,
            access: ModelAccess,
            admissionCheck: @escaping @Sendable () throws -> Void = {}
        ) throws {
            try Task.checkCancellation()
            try admissionCheck()
            guard revision == access.revision,
                  model?.model === access.handle.model
            else {
                throw CancellationError()
            }
            preparedCanvases.insert(canvas)
        }

        func purge() async {
            revision &+= 1
            await sharedLoads.purge()
            model = nil
            preparedCanvases.removeAll(keepingCapacity: false)
        }
    }

    let modelName: String
    let inputFeatureName: String
    let outputFeatureName: String
    private let modelUnits: MLComputeUnits
    var computeUnits: String { modelUnits == .cpuOnly ? "cpuOnly" : "cpuAndGPU" }

    private let modelStore: ModelStore
    let modelPackageSHA256: String
    private var tensorPolicy: MLComputePolicy {
#if targetEnvironment(simulator)
        MLComputePolicy(modelUnits)
#else
        MLComputePolicy(.all)
#endif
    }
    var dbExecutionContract:String {
#if targetEnvironment(simulator)
        computeUnits+"|MLTensor="+computeUnits+"|reshape=frequent|specialization=fastPrediction"
#else
        computeUnits+"|MLTensor=all|reshape=frequent|specialization=fastPrediction"
#endif
    }


    init(
        modelURL: URL,
        modelName: String,
        inputFeatureName: String,
        outputFeatureName: String
    ) throws {
        let published=try NativeCoreMLModelStore.shared.modelURL(for:modelURL)
        modelPackageSHA256=try NativeCoreMLModelStore.shared.packageContentSHA256(at:published)
#if targetEnvironment(simulator)
        // The Manga graph's dynamic padding produces nonfinite source cells on
        // the simulator CPU backend. The same input and weights are finite on GPU.
        modelUnits = modelName == "PP-OCRv6-Manga-DetShapes" ? .cpuAndGPU : .cpuOnly
#else
        modelUnits = .cpuAndGPU
#endif
        modelStore = ModelStore(asset: try MLModelAsset(url:published), computeUnits: modelUnits)
        self.modelName = modelName
        self.inputFeatureName = inputFeatureName
        self.outputFeatureName = outputFeatureName
    }

    func predict(
        input: MLTensor
    ) async throws -> NativeCoreMLDetectionPrediction {
        guard let canvas = NativeCoreMLDetectionCanvas(
            inputShape: input.shape
        ) else {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        let modelAccess = try await modelStore.model(for: canvas)
        let prediction = try await withMLTensorComputePolicy(tensorPolicy) {
            try await modelAccess.handle.model.prediction(
                from: [inputFeatureName: input]
            )
        }
        guard let output = prediction[outputFeatureName] else {
            throw NativeCoreMLDetectorError.modelOutputMissing
        }
        return NativeCoreMLDetectionPrediction(
            output: output,
            modelWasLoaded: modelAccess.wasLoaded,
            modelLoadMilliseconds: modelAccess.loadMilliseconds
        )
    }

    /// Feature-provider prediction for the geometry-only path. Same program,
    /// compute units and Float32 input values as `predict(input:)`; the output
    /// is bit-identical (verified on the dev pages) and avoids the `MLTensor`
    /// round trip, which costs about a third of the prediction time.
    func predict(
        array: MLMultiArray,
        canvas: NativeCoreMLDetectionCanvas
    ) async throws -> NativeCoreMLDetectionArrayPrediction {
        let modelAccess = try await modelStore.model(for: canvas)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputFeatureName: MLFeatureValue(multiArray: array)])
        let prediction = try await modelAccess.handle.model.prediction(from: provider)
        guard let output = prediction.featureValue(for: outputFeatureName)?.multiArrayValue else {
            throw NativeCoreMLDetectorError.modelOutputMissing
        }
        return NativeCoreMLDetectionArrayPrediction(
            output: output,
            modelWasLoaded: modelAccess.wasLoaded,
            modelLoadMilliseconds: modelAccess.loadMilliseconds
        )
    }

    func prepare(
        canvas: NativeCoreMLDetectionCanvas,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        let modelAccess = try await modelStore.model(
            for: canvas,
            admissionCheck: cancellationCheck
        )
        guard !modelAccess.isPrepared else { return }
        try cancellationCheck()
        // Loading a dynamic-shape MLProgram does not compile its GPU kernels.
        // Run one exact-shape zero prediction and materialize the result so the
        // first visible OCR frame does not pay that specialization cost.
        let input = MLTensor(
            zeros: canvas.inputShape,
            scalarType: Float.self
        )
        let prediction = try await withMLTensorComputePolicy(tensorPolicy) {
            try await modelAccess.handle.model.prediction(
                from: [inputFeatureName: input]
            )
        }
        guard let output = prediction[outputFeatureName],
              output.shape == canvas.outputShape
        else {
            throw NativeCoreMLDetectorError.modelOutputMissing
        }
        // Core ML may retain an MLTensor result lazily. Pulling the exact output
        // into a shaped array is the boundary that guarantees prediction and
        // GPU specialization have actually completed before admission.
        let materialized = await output.shapedArray(of: Float.self)
        _ = materialized.scalars.first
        try cancellationCheck()
        try await modelStore.markPrepared(
            canvas,
            access: modelAccess,
            admissionCheck: cancellationCheck
        )
    }

    /// The detector is one dynamic-shape program: its load is independent of
    /// the page canvas. Loading it early moves `MLModel.load` off the first
    /// OCR frame without a speculative (possibly wrong-shape) prediction.
    func warmUpModel(
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        _ = try await modelStore.model(admissionCheck: cancellationCheck)
    }

    func purgeResources() async {
        await modelStore.purge()
    }
}

@available(iOS 18.0, *)
private final class NativeCoreMLDetectionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        value &+= 1
        let result = value
        lock.unlock()
        return result
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
        let result = value == generation
        lock.unlock()
        return result
    }
}

/// PP-OCRv6 text detection using one bounded dynamic-spatial Core ML model.
@available(iOS 18.0, *)
final class NativeCoreMLDetector: @unchecked Sendable {
    static let modelResourceName = "PP-OCRv6-Manga-DetShapes"
    static let inputFeatureName = "x"
    static let outputFeatureName = "fetch_name_0"

    private struct Resources: Sendable {
        let predictor: NativeCoreMLDetectorModelPredictor
        let loadMilliseconds: Double
    }

    private struct ResourceAccess: Sendable {
        let resources: Resources
        let wasAlreadyLoaded: Bool
    }

    private let generation = NativeCoreMLDetectionGeneration()
    private let preparationRevision = NativeCoreMLPreparationRevision()
    private let resourceLock = NSLock()
    private let diagnosticsLock = NSLock()
    private let allowsWeakBridgeSplit: Bool
    private let configuredMaximumSide: Int
    private let resourceLoader: @Sendable () throws -> Resources
    private let canvasSelector:
        @Sendable (_ sourceWidth: Int, _ sourceHeight: Int)
            -> NativeCoreMLDetectionCanvas?
    private var loadedResources: Resources?
    private var storedDiagnostics: NativeCoreMLDetectionDiagnostics?

    var lastDiagnostics: NativeCoreMLDetectionDiagnostics? {
        diagnosticsLock.lock()
        let result = storedDiagnostics
        diagnosticsLock.unlock()
        return result
    }

    init(
        bundle: Bundle = .main,
        modelResourceName: String = NativeCoreMLDetector.modelResourceName,
        maximumSide: Int = IPhoneOCRSettings.defaultDetectorMaximumSide
    ) {
        // The split has been evaluated on the bundled Medium probability maps.
        // Other model tiers retain their established postprocessing behavior.
        configuredMaximumSide=maximumSide
        allowsWeakBridgeSplit = modelResourceName == "PP-OCRv6-Medium-DetShapes"
        canvasSelector = { width, height in
            NativeCoreMLDetectionCanvas.exact(
                sourceWidth: width,
                sourceHeight: height,
                maximumSide: maximumSide
            )
        }
        resourceLoader = {
            let started = Self.nowMilliseconds()
            guard let modelURL = Self.findModelURL(
                in: bundle,
                resourceName: modelResourceName
            ) else {
                throw NativeCoreMLDetectorError.modelResourceMissing
            }
            let predictor: NativeCoreMLDetectorModelPredictor
            do {
                predictor = try NativeCoreMLDetectorModelPredictor(
                    modelURL: modelURL,
                    modelName: modelResourceName,
                    inputFeatureName: Self.inputFeatureName,
                    outputFeatureName: Self.outputFeatureName
                )
            } catch {
                throw NativeCoreMLDetectorError.modelLoadFailed(
                    String(describing: error)
                )
            }
            return Resources(
                predictor: predictor,
                loadMilliseconds: Self.nowMilliseconds() - started
            )
        }
    }

    func cancelCurrent() {
        generation.cancelCurrent()
    }

    func cancelPreparation() {
        preparationRevision.invalidate()
    }

    func prepare(
        sourceWidth: Int,
        sourceHeight: Int
    ) async throws {
        let preparationToken = preparationRevision.token()
        guard let canvas = canvasSelector(sourceWidth, sourceHeight) else {
            let resized = NativeCoreMLDetectionPreprocessor.resizeDimensions(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight
            ) ?? (0, 0)
            throw NativeCoreMLDetectorError.unsupportedInputShape(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                resizedWidth: resized.width,
                resizedHeight: resized.height
            )
        }
        let resourceAccess = try await Task.detached(
            priority: .userInitiated
        ) { [self] in
            try loadResources(cancellationCheck: {
                try self.preparationRevision.requireCurrent(preparationToken)
            })
        }.value
        try preparationRevision.requireCurrent(preparationToken)
        try await resourceAccess.resources.predictor.prepare(
            canvas: canvas,
            cancellationCheck: {
                try self.preparationRevision.requireCurrent(preparationToken)
            }
        )
        try preparationRevision.requireCurrent(preparationToken)
    }

    /// Loads the detector model only (no warm-up prediction). Shares the
    /// preparation lifetime: `cancelPreparation()`/`purgeResources()` reject a
    /// load that has not yet been admitted to the model store.
    func warmUpModel() async throws {
        let preparationToken = preparationRevision.token()
        let resourceAccess = try await Task.detached(
            priority: Task.currentPriority
        ) { [self] in
            try loadResources(cancellationCheck: {
                try self.preparationRevision.requireCurrent(preparationToken)
            })
        }.value
        try preparationRevision.requireCurrent(preparationToken)
        try await resourceAccess.resources.predictor.warmUpModel(
            cancellationCheck: {
                try self.preparationRevision.requireCurrent(preparationToken)
            }
        )
        try preparationRevision.requireCurrent(preparationToken)
    }

    func purgeResources() async {
        cancelPreparation()
        generation.cancelCurrent()
        if let resources = takeLoadedResources() {
            await resources.predictor.purgeResources()
        }
    }

    private func takeLoadedResources() -> Resources? {
        resourceLock.lock()
        let resources = loadedResources
        loadedResources = nil
        resourceLock.unlock()
        return resources
    }

    func detect(
        image: CGImage,
        requestID: String = UUID().uuidString,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionResult {
        try await performDetection(
            providedFrame: nil,
            image: image,
            requestID: requestID,
            configuration: configuration,
            recognitionScopes: nil,
            cancellationCheck: cancellationCheck
        )
    }

    /// Runs detection from caller-owned immutable pixels. The image overload
    /// remains the standalone convenience API, while the full OCR pipeline
    /// uses this seam to share one source conversion with recognition.
    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String = UUID().uuidString,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionResult {
        try await performDetection(
            providedFrame: frame,
            image: nil,
            requestID: requestID,
            configuration: configuration,
            recognitionScopes: nil,
            cancellationCheck: cancellationCheck
        )
    }

    /// Full-frame detector inference with bounded dirty-scope CPU
    /// postprocessing. The scopes affect only output materialization and DB
    /// decoding; the model always receives the same full source frame.
    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String = UUID().uuidString,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga,
        recognitionScopes: [CGRect]?,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionResult {
        try await performDetection(
            providedFrame: frame,
            image: nil,
            requestID: requestID,
            configuration: configuration,
            recognitionScopes: recognitionScopes,
            cancellationCheck: cancellationCheck
        )
    }

    /// Per-call observer; old overloads continue without retaining probability maps.
    func detect(
        frame: NativeOCRRGBAFrame,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
        probabilityObserver: NativeMainEnsembleOCRProbability.Observer?,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult {
        try await performDetection(
            providedFrame: frame, image: nil, requestID: requestID,
            configuration: configuration, recognitionScopes: recognitionScopes,
            probabilityObserver: probabilityObserver, cancellationCheck: cancellationCheck
        )
    }

    /// DB-decoded geometry only (polygon, score and the decoder's own erasure/recognition polygons) for the
    /// V2 pipeline. Skips the legacy column, ownership-seed, ROI-probability and alternate-envelope evidence;
    /// every other entry point keeps that evidence and is unchanged.
    func detectGeometry(
        image: CGImage,
        requestID: String = UUID().uuidString,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionResult {
        try await performGeometryDetection(
            providedFrame: nil, image: image, requestID: requestID, configuration: configuration,
            cancellationCheck: cancellationCheck
        )
    }

    /// Geometry-only detection from caller-owned pixels (V2 shares one frame with recognition).
    func detectGeometry(
        frame: NativeOCRRGBAFrame,
        requestID: String = UUID().uuidString,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionResult {
        try await performGeometryDetection(
            providedFrame: frame, image: nil, requestID: requestID, configuration: configuration,
            cancellationCheck: cancellationCheck
        )
    }

    /// Captures one immutable frame, normalized tensor and detector for a single cache lookup.
    /// Only a cache miss invokes the observer. Actual emission still attests its own resources.
    struct ProbabilityRequest: Sendable {
        let expectation: NativeCoreMLDBProvenance.Expectation
        let observe: @Sendable (
            _ observer: @escaping NativeMainEnsembleOCRProbability.Observer,
            _ cancellationCheck: @escaping @Sendable () throws -> Void
        ) async throws -> Void
    }

    func prepareProbabilityRequest(frame:NativeOCRRGBAFrame,
        configuration:NativeCoreMLDBPostprocessConfiguration) async throws -> ProbabilityRequest {
        try Task.checkCancellation()
        guard let canvas=canvasSelector(frame.width,frame.height) else {throw NativeCoreMLDetectorError.modelInputCreationFailed}
        let prepared=try await NativeCoreMLDetectionPreprocessor.prepare(frame:frame,canvas:canvas)
        let access=try await Task.detached(priority:.utility) { [self] in
            try self.loadResources(cancellationCheck:{try Task.checkCancellation()})
        }.value
        try Task.checkCancellation()
        let predictor=access.resources.predictor
        let producer=NativeCoreMLDBProvenance.producer(resource:predictor.modelName,
            packageSHA256:predictor.modelPackageSHA256,computeUnits:predictor.dbExecutionContract,prepared:prepared)
        let expectation = NativeCoreMLDBProvenance.Expectation(producer:producer,detectorInputIdentity:prepared.inputSHA256,
            consumerConfigurationSHA256:NativeCoreMLDBProvenance.consumerConfigurationSHA256(
                configuration:configuration,maximumSide:configuredMaximumSide,
                mainMangaPolicy:NativeOCRDirectionGeometry.mainMangaPolicy))
        return ProbabilityRequest(expectation: expectation) { [self] observer, check in
            _ = try await performDetection(
                providedFrame: frame, image: nil, requestID: UUID().uuidString,
                configuration: configuration, recognitionScopes: nil,
                probabilityObserver: observer, probabilityOnlyInput: prepared, cancellationCheck: check
            )
        }
    }

    private func performDetection(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
        probabilityObserver: NativeMainEnsembleOCRProbability.Observer? = nil,
        probabilityOnlyInput: NativeCoreMLDetectionPreparedTensor? = nil,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult {
        let issuedGeneration = generation.begin()
        let started = Self.nowMilliseconds()

        return try await withTaskCancellationHandler {
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
                throw NativeCoreMLDetectorError.imageConversionFailed
            }
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )
            guard let canvas = canvasSelector(frame.width, frame.height)
            else {
                let resized = NativeCoreMLDetectionPreprocessor
                    .resizeDimensions(
                        sourceWidth: frame.width,
                        sourceHeight: frame.height
                    ) ?? (0, 0)
                throw NativeCoreMLDetectorError.unsupportedInputShape(
                    sourceWidth: frame.width,
                    sourceHeight: frame.height,
                    resizedWidth: resized.width,
                    resizedHeight: resized.height
                )
            }

            let preprocessingStarted = Self.nowMilliseconds()
            let prepared: NativeCoreMLDetectionPreparedTensor
            if let probabilityOnlyInput {
                guard probabilityOnlyInput.canvas == canvas else { throw NativeCoreMLDetectorError.modelInputCreationFailed }
                prepared = probabilityOnlyInput
            } else {
                prepared = try await Task.detached(priority: .userInitiated) { [self] in
                    try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck)
                    return try await NativeCoreMLDetectionPreprocessor.prepare(
                        frame: frame,
                        canvas: canvas,
                        cancellationCheck: {
                            try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck)
                        }
                    )
                }.value
            }
            let preprocessingElapsed = Self.nowMilliseconds()
                - preprocessingStarted
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )

            let resourceAccess = try await Task.detached(
                priority: .userInitiated
            ) { [self] in
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                let result = try loadResources(cancellationCheck: {
                    try requireCurrent(
                        issuedGeneration,
                        cancellationCheck: cancellationCheck
                    )
                })
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                return result
            }.value

            // Keep async Core ML prediction in the caller's structured task.
            // Detaching it prevents parent Task cancellation from reaching the
            // model (and cancellation-aware test predictors) until prediction
            // has already returned.
            let predictionStarted = Self.nowMilliseconds()
            let prediction: NativeCoreMLDetectionPrediction
            do {
                prediction = try await predict(
                    input: prepared.input,
                    using: resourceAccess.resources.predictor,
                    generation: issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
            } catch let error as CancellationError {
                throw error
            } catch let error as NativeCoreMLDetectorError {
                throw error
            } catch {
                throw NativeCoreMLDetectorError.predictionFailed(
                    String(describing: error)
                )
            }
            let predictionElapsed = Self.nowMilliseconds()
                - predictionStarted
            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )

            let frameBounds = CGRect(
                x: 0,
                y: 0,
                width: frame.width,
                height: frame.height
            )
            let standardizedScopes = recognitionScopes?.compactMap {
                scope -> CGRect? in
                guard scope.origin.x.isFinite, scope.origin.y.isFinite,
                      scope.size.width.isFinite, scope.size.height.isFinite
                else {
                    return nil
                }
                let clipped = scope.standardized.intersection(frameBounds)
                return clipped.isNull || clipped.isEmpty ? nil : clipped
            }

            let postprocessingStarted = Self.nowMilliseconds()
            // Detached model work does not inherit task-local request policy.
            let directionPolicy=NativeOCRDirectionGeometry.mainMangaPolicy
            let postprocessing = try await Task.detached(
                priority: .userInitiated
            ) { [self] in
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                let fullRegion = NativeCoreMLDetectionMapRegion.full(
                    width: prepared.resizedWidth,
                    height: prepared.resizedHeight
                )
                let preferredRegion = standardizedScopes.flatMap {
                    NativeCoreMLDetectionScopePlanner.region(
                        scopes: $0,
                        sourceWidth: frame.width,
                        sourceHeight: frame.height,
                        mapWidth: prepared.resizedWidth,
                        mapHeight: prepared.resizedHeight
                    )
                }
                var materializationMilliseconds = 0.0
                var dbPostprocessingMilliseconds = 0.0

                func materialize(
                    _ region: NativeCoreMLDetectionMapRegion
                ) async throws -> NativeCoreMLDetectionMap {
                    let stageStarted = Self.nowMilliseconds()
                    let map = try await NativeCoreMLDetectionOutput.makeMap(
                        output: prediction.output,
                        region: region,
                        fullWidth: prepared.resizedWidth,
                        fullHeight: prepared.resizedHeight,
                        expectedShape: prepared.canvas.outputShape
                    )
                    materializationMilliseconds += Self.nowMilliseconds()
                        - stageStarted
                    return map
                }

                var sourceProbabilityDigest: String?

                func decode(
                    _ map: NativeCoreMLDetectionMap,
                    region: NativeCoreMLDetectionMapRegion
                ) throws -> NativeCoreMLDBPostprocessResult {
                    // A cache miss needs the source grid alone. Its observer still validates
                    // every cell and the actual producer before the evidence store can admit it.
                    guard probabilityOnlyInput == nil else { return .init(boxes: [], candidateComponents: 0) }
                    let stageStarted = Self.nowMilliseconds()
                    let result = try NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(directionPolicy) {
                        try NativeCoreMLDBPostprocessor.decode(
                            map: map,
                            sourceWidth: frame.width,
                            sourceHeight: frame.height,
                            geometry: NativeCoreMLDetectionMapGeometry(
                                originX: region.x,
                                originY: region.y,
                                fullWidth: prepared.resizedWidth,
                                fullHeight: prepared.resizedHeight
                            ),
                            configuration: configuration,
                            allowsWeakBridgeSplit: allowsWeakBridgeSplit
                                && configuration.withRecoveryBoxThreshold(nil) == .production,
                            allowsThinFinePrintRecovery: allowsWeakBridgeSplit,
                            cancellationCheck: {
                                try requireCurrent(
                                    issuedGeneration,
                                    cancellationCheck: cancellationCheck
                                )
                            }
                        )
                    }
                    // OCR retains its detection evidence; source replacement no longer needs erasure masks.
                    let boxes = result.boxes
                    let mapGeometry = NativeCoreMLDetectionMapGeometry(originX: region.x, originY: region.y,
                        fullWidth: prepared.resizedWidth, fullHeight: prepared.resizedHeight)
                    let columns = try NativeOCRDBChildColumnEvidence.extract(map: map, boxes: boxes,
                        sourceWidth: frame.width, sourceHeight: frame.height, geometry: mapGeometry,
                        cancellationCheck: { try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck) })
                    var seeds = try NativeOCRDBOwnershipCandidates.collect(map: map, boxes: boxes,
                        sourceWidth: frame.width, sourceHeight: frame.height, geometry: mapGeometry,
                        cancellationCheck: { try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck) })
                    // Retain bounded source-resolution evidence, not the detector map.
                    // Existing owner transport carries this through live and saved layouts.
                    var probabilityBudget = NativeOCRSourceROIProbabilityEvidence.maximumPageBytes
                    for index in boxes.indices where seeds[index] != nil {
                        try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck)
                        let points = boxes[index].polygon
                        guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                        // Clamp in floating point before conversion, including finite
                        // but unrepresentable persisted or extreme geometry values.
                        let x0 = Int(max(0, min(CGFloat(frame.width), floor(points.map(\.x).min()!) - 16)))
                        let y0 = Int(max(0, min(CGFloat(frame.height), floor(points.map(\.y).min()!) - 16)))
                        let x1 = Int(max(0, min(CGFloat(frame.width), ceil(points.map(\.x).max()!) + 16)))
                        let y1 = Int(max(0, min(CGFloat(frame.height), ceil(points.map(\.y).max()!) + 16)))
                        guard x1 > x0, y1 > y0, (x1 - x0) <= probabilityBudget / (y1 - y0),
                              (x1 - x0) <= NativeOCRSourceROIProbabilityEvidence.maximumPixels / (y1 - y0) else { continue }
                        if sourceProbabilityDigest == nil {
                            sourceProbabilityDigest = frame.bytes.withUnsafeBufferPointer {
                                NativeOCRSourceROIProbabilityEvidence.sourceIdentity(rgba: $0, width: frame.width,
                                    height: frame.height, bytesPerRow: frame.bytesPerRow)
                            }
                        }
                        guard let digest = sourceProbabilityDigest,
                              let evidence = NativeOCRSourceROIProbabilityEvidence.capture(
                                sourceWidth: frame.width, sourceHeight: frame.height, sourceDigest: digest,
                                roi: .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                                detector: .init(originX: region.x, originY: region.y, width: map.width, height: map.height,
                                                fullWidth: prepared.resizedWidth, fullHeight: prepared.resizedHeight),
                                probabilities: map.values) else { continue }
                        seeds[index]?.sourceProbabilityROI = evidence
                        probabilityBudget -= evidence.upperBounds.count
                    }
                    let alternates: [Int: [CGPoint]]
                    if NativeCoreMLDBPostprocessor.alternateCellEnvelopeEnabled,
                       resourceAccess.resources.predictor.modelName == "PP-OCRv6-Manga-DetShapes",
                       configuration == .manga, configuredMaximumSide == 1_120,
                       !NativeCoreMLDetectionPreprocessor.usesIsotropicContent,
                       recognitionScopes == nil, region == fullRegion {
                        alternates = try NativeCoreMLDBPostprocessor.alternateCellEnvelopes(
                            polygons: boxes.map(\.polygon), sourceWidth: frame.width, sourceHeight: frame.height,
                            mapWidth: map.width, mapHeight: map.height,
                            cancellationCheck: { try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck) }
                        )
                    } else {
                        alternates = [:]
                    }
                    let measuredBoxes = boxes.indices.map { index in
                        let box = boxes[index]
                        return NativeCoreMLDetectionBox(polygon: box.polygon, score: box.score,
                            erasurePolygons: box.erasurePolygons, recognitionPolygon: box.recognitionPolygon,
                            isThinFinePrintRecovery: box.isThinFinePrintRecovery,
                            finePrintRetryPolygons: box.finePrintRetryPolygons,
                            recognitionColumnEvidence: columns[index], detectorSeedEvidence: seeds[index],
                            alternateRecognitionPolygon: alternates[index])
                    }
                    dbPostprocessingMilliseconds += Self.nowMilliseconds()
                        - stageStarted
                    return .init(boxes: measuredBoxes, candidateComponents: result.candidateComponents)
                }

                var usedRegion = preferredRegion ?? fullRegion
                var map = try await materialize(usedRegion)
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                var postprocessed = try decode(map, region: usedRegion)

                if preferredRegion != nil,
                   NativeCoreMLDetectionOutput.requiresFullFallback(
                       map: map,
                       region: usedRegion,
                       fullWidth: prepared.resizedWidth,
                       fullHeight: prepared.resizedHeight,
                       threshold: configuration.threshold
                   )
                    || postprocessed.candidateComponents
                        >= configuration.maximumCandidates
                    || NativeCoreMLDetectionOutput.boxesTouchArtificialEdge(
                        postprocessed.boxes.filter { $0.score >= configuration.boxThreshold },
                        region: usedRegion,
                        fullWidth: prepared.resizedWidth,
                        fullHeight: prepared.resizedHeight,
                        sourceWidth: frame.width,
                        sourceHeight: frame.height
                    )
                {
                    try requireCurrent(
                        issuedGeneration,
                        cancellationCheck: cancellationCheck
                    )
                    usedRegion = fullRegion
                    map = try await materialize(fullRegion)
                    try requireCurrent(
                        issuedGeneration,
                        cancellationCheck: cancellationCheck
                    )
                    postprocessed = try decode(map, region: fullRegion)
                }

                // Reuse only the final ALREADY materialized map. Never force another
                // full-map materialization, prediction, or OCR pass for this handoff.
                if let probabilityObserver {
                    try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck)
                    _ = probabilityObserver(.init(
                        sourceWidth: frame.width, sourceHeight: frame.height,
                        resizedWidth: prepared.resizedWidth, resizedHeight: prepared.resizedHeight,
                        region: CGRect(x: usedRegion.x, y: usedRegion.y,
                            width: usedRegion.width, height: usedRegion.height),
                        width: map.width, height: map.height, values: map.values,
                        producer:NativeCoreMLDBProvenance.producer(
                            resource:resourceAccess.resources.predictor.modelName,
                            packageSHA256:resourceAccess.resources.predictor.modelPackageSHA256,
                            computeUnits:resourceAccess.resources.predictor.dbExecutionContract,prepared:prepared),
                        detectorInputIdentity:prepared.inputSHA256,
                        consumerConfigurationSHA256:NativeCoreMLDBProvenance.consumerConfigurationSHA256(
                            configuration:configuration,maximumSide:configuredMaximumSide,mainMangaPolicy:directionPolicy)
                    ))
                    try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck)
                }

                let filteredResult: NativeCoreMLDBPostprocessResult
                if recognitionScopes != nil {
                    let boxes = postprocessed.boxes.filter { box in
                        guard let bounds = Self.bounds(for: box.polygon)
                        else {
                            return false
                        }
                        return standardizedScopes?.contains { scope in
                            bounds.intersection(scope).isNull == false
                                && bounds.intersection(scope).isEmpty == false
                        } == true
                    }
                    filteredResult = NativeCoreMLDBPostprocessResult(
                        boxes: boxes,
                        candidateComponents:
                            postprocessed.candidateComponents
                    )
                } else {
                    filteredResult = postprocessed
                }
                return NativeCoreMLDetectionPostprocessingWork(
                    result: filteredResult,
                    outputMaterializationMilliseconds:
                        materializationMilliseconds,
                    dbPostprocessingMilliseconds:
                        dbPostprocessingMilliseconds
                )
            }.value
            let postprocessingElapsed = Self.nowMilliseconds()
                - postprocessingStarted

            try requireCurrent(
                issuedGeneration,
                cancellationCheck: cancellationCheck
            )
            let diagnostics = NativeCoreMLDetectionDiagnostics(
                requestID: requestID,
                generation: issuedGeneration,
                backend: "coreml",
                executionProvider: "CoreML",
                computeUnits:
                    resourceAccess.resources.predictor.computeUnits,
                modelName: resourceAccess.resources.predictor.modelName,
                inputFeatureName:
                    resourceAccess.resources.predictor.inputFeatureName,
                outputFeatureName:
                    resourceAccess.resources.predictor.outputFeatureName,
                inputShape: prepared.canvas.inputShape,
                outputShape: prepared.canvas.outputShape,
                sourceWidth: frame.width,
                sourceHeight: frame.height,
                resizedWidth: prepared.resizedWidth,
                resizedHeight: prepared.resizedHeight,
                threshold: configuration.threshold,
                boxThreshold: configuration.boxThreshold,
                unclipRatio: configuration.unclipRatio,
                maximumCandidates: configuration.maximumCandidates,
                candidateComponents:
                    postprocessing.result.candidateComponents,
                detectedBoxes: postprocessing.result.boxes.count,
                modelWasAlreadyLoaded:
                    resourceAccess.wasAlreadyLoaded &&
                        !prediction.modelWasLoaded,
                modelLoadMilliseconds:
                    (resourceAccess.wasAlreadyLoaded
                        ? 0
                        : resourceAccess.resources.loadMilliseconds)
                        + prediction.modelLoadMilliseconds,
                inputTensorCreationMilliseconds:
                    probabilityOnlyInput == nil ? prepared.inputTensorCreationMilliseconds : 0,
                tensorGraphMilliseconds:
                    probabilityOnlyInput == nil ? prepared.tensorGraphMilliseconds : 0,
                preprocessingMilliseconds:
                    preprocessingElapsed,
                predictionMilliseconds: predictionElapsed,
                outputMaterializationMilliseconds:
                    postprocessing.outputMaterializationMilliseconds,
                dbPostprocessingMilliseconds:
                    postprocessing.dbPostprocessingMilliseconds,
                postprocessingMilliseconds:
                    postprocessingElapsed,
                totalMilliseconds: Self.nowMilliseconds() - started
            )
            store(diagnostics)
            return NativeCoreMLDetectionResult(
                requestID: requestID,
                width: frame.width,
                height: frame.height,
                boxes: postprocessing.result.boxes,
                diagnostics: diagnostics
            )
        } onCancel: { [generation] in
            generation.cancel(ifCurrent: issuedGeneration)
        }
    }

    /// The full-frame, unscoped `performDetection` restricted to DB geometry:
    /// multiarray input without digest, feature-provider prediction, direct
    /// output read and one DB decode. Boxes equal the legacy result's
    /// polygon, score, erasure and recognition geometry.
    private func performGeometryDetection(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionResult {
        let issuedGeneration = generation.begin()
        let started = Self.nowMilliseconds()
        let check: @Sendable () throws -> Void = { [self] in
            try requireCurrent(issuedGeneration, cancellationCheck: cancellationCheck)
        }
        return try await withTaskCancellationHandler {
            try check()
            let frame: NativeOCRRGBAFrame
            if let providedFrame {
                frame = providedFrame
            } else if let image, let converted = await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image) {
                frame = converted
            } else {
                throw NativeCoreMLDetectorError.imageConversionFailed
            }
            try check()
            // Geometry-only path; keep this line distinct from the legacy path's
            // canvas guard, which the host launcher patches by exact text anchor.
            guard let geometryCanvas = canvasSelector(frame.width, frame.height) else {
                let resized = NativeCoreMLDetectionPreprocessor.resizeDimensions(
                    sourceWidth: frame.width, sourceHeight: frame.height) ?? (0, 0)
                throw NativeCoreMLDetectorError.unsupportedInputShape(
                    sourceWidth: frame.width, sourceHeight: frame.height,
                    resizedWidth: resized.width, resizedHeight: resized.height)
            }
            let preprocessingStarted = Self.nowMilliseconds()
            let prepared = try await NativeCoreMLDetectionPreprocessor.prepareArray(
                frame: frame, canvas: geometryCanvas, cancellationCheck: check)
            let preprocessingElapsed = Self.nowMilliseconds() - preprocessingStarted
            try check()
            let resourceAccess = try loadResources(cancellationCheck: check)
            let predictor = resourceAccess.resources.predictor
            let predictionStarted = Self.nowMilliseconds()
            let prediction: NativeCoreMLDetectionArrayPrediction
            do {
                prediction = try await predictor.predict(array: prepared.input, canvas: geometryCanvas)
            } catch let error as CancellationError {
                throw error
            } catch let error as NativeCoreMLDetectorError {
                throw error
            } catch {
                throw NativeCoreMLDetectorError.predictionFailed(String(describing: error))
            }
            let predictionElapsed = Self.nowMilliseconds() - predictionStarted
            try check()
            let postprocessingStarted = Self.nowMilliseconds()
            let region = NativeCoreMLDetectionMapRegion.full(width: prepared.resizedWidth, height: prepared.resizedHeight)
            let map = try NativeCoreMLDetectionOutput.makeMap(
                output: prediction.output, region: region, fullWidth: prepared.resizedWidth,
                fullHeight: prepared.resizedHeight, expectedShape: geometryCanvas.outputShape)
            let materializationElapsed = Self.nowMilliseconds() - postprocessingStarted
            try check()
            let decodeStarted = Self.nowMilliseconds()
            let result = try NativeCoreMLDBPostprocessor.decode(
                map: map, sourceWidth: frame.width, sourceHeight: frame.height,
                geometry: NativeCoreMLDetectionMapGeometry(originX: 0, originY: 0,
                    fullWidth: prepared.resizedWidth, fullHeight: prepared.resizedHeight),
                configuration: configuration,
                allowsWeakBridgeSplit: allowsWeakBridgeSplit && configuration.withRecoveryBoxThreshold(nil) == .production,
                allowsThinFinePrintRecovery: allowsWeakBridgeSplit,
                cancellationCheck: check
            )
            let finished = Self.nowMilliseconds()
            try check()
            let diagnostics = NativeCoreMLDetectionDiagnostics(
                requestID: requestID, generation: issuedGeneration, backend: "coreml", executionProvider: "CoreML",
                computeUnits: predictor.computeUnits, modelName: predictor.modelName,
                inputFeatureName: predictor.inputFeatureName, outputFeatureName: predictor.outputFeatureName,
                inputShape: geometryCanvas.inputShape, outputShape: geometryCanvas.outputShape,
                sourceWidth: frame.width, sourceHeight: frame.height,
                resizedWidth: prepared.resizedWidth, resizedHeight: prepared.resizedHeight,
                threshold: configuration.threshold, boxThreshold: configuration.boxThreshold,
                unclipRatio: configuration.unclipRatio, maximumCandidates: configuration.maximumCandidates,
                candidateComponents: result.candidateComponents, detectedBoxes: result.boxes.count,
                modelWasAlreadyLoaded: resourceAccess.wasAlreadyLoaded && !prediction.modelWasLoaded,
                modelLoadMilliseconds: (resourceAccess.wasAlreadyLoaded ? 0 : resourceAccess.resources.loadMilliseconds)
                    + prediction.modelLoadMilliseconds,
                inputTensorCreationMilliseconds: prepared.inputCreationMilliseconds, tensorGraphMilliseconds: 0,
                preprocessingMilliseconds: preprocessingElapsed, predictionMilliseconds: predictionElapsed,
                outputMaterializationMilliseconds: materializationElapsed,
                dbPostprocessingMilliseconds: finished - decodeStarted,
                postprocessingMilliseconds: finished - postprocessingStarted,
                totalMilliseconds: finished - started
            )
            store(diagnostics)
            return NativeCoreMLDetectionResult(requestID: requestID, width: frame.width, height: frame.height,
                                               boxes: result.boxes, diagnostics: diagnostics)
        } onCancel: { [generation] in
            generation.cancel(ifCurrent: issuedGeneration)
        }
    }

    private func loadResources(
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) throws -> ResourceAccess {
        resourceLock.lock()
        defer { resourceLock.unlock() }
        try cancellationCheck()
        if let loadedResources {
            return ResourceAccess(
                resources: loadedResources,
                wasAlreadyLoaded: true
            )
        }
        let resources = try resourceLoader()
        try cancellationCheck()
        loadedResources = resources
        return ResourceAccess(
            resources: resources,
            wasAlreadyLoaded: false
        )
    }

    private func predict(
        input: MLTensor,
        using predictor: NativeCoreMLDetectorModelPredictor,
        generation issuedGeneration: UInt64,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> NativeCoreMLDetectionPrediction {
        try requireCurrent(
            issuedGeneration,
            cancellationCheck: cancellationCheck
        )
        let prediction = try await predictor.predict(input: input)
        try requireCurrent(
            issuedGeneration,
            cancellationCheck: cancellationCheck
        )
        return prediction
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

    private func store(_ diagnostics: NativeCoreMLDetectionDiagnostics) {
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

    private static func normalizedResourceName(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func bounds(for polygon: [CGPoint]) -> CGRect? {
        guard let minimumX = polygon.map(\.x).min(),
              let maximumX = polygon.map(\.x).max(),
              let minimumY = polygon.map(\.y).min(),
              let maximumY = polygon.map(\.y).max(),
              minimumX.isFinite, maximumX.isFinite,
              minimumY.isFinite, maximumY.isFinite,
              maximumX > minimumX, maximumY > minimumY
        else {
            return nil
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private static func nowMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }
}

@available(iOS 18.0, *)
private struct NativeCoreMLDetectionPostprocessingWork: Sendable {
    let result: NativeCoreMLDBPostprocessResult
    let outputMaterializationMilliseconds: Double
    let dbPostprocessingMilliseconds: Double
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionPreparedTensor: Sendable {
    let input: MLTensor
    let inputSHA256: String
    let canvas: NativeCoreMLDetectionCanvas
    let resizedWidth: Int
    let resizedHeight: Int
    let inputTensorCreationMilliseconds: Double
    let tensorGraphMilliseconds: Double

    /// Test/debug materialization of the bounded detector input.
    func values() async -> [Float] {
        await input.shapedArray(of: Float.self).scalars
    }
}

/// Multiarray counterpart of `NativeCoreMLDetectionPreparedTensor` for the geometry-only path.
@available(iOS 18.0, *)
struct NativeCoreMLDetectionPreparedArray: @unchecked Sendable {
    let input: MLMultiArray
    let canvas: NativeCoreMLDetectionCanvas
    let resizedWidth: Int
    let resizedHeight: Int
    let inputCreationMilliseconds: Double
}

@available(iOS 18.0, *)
enum NativeCoreMLDetectionPreprocessor {
    // The packaged model also serves explicit high-resolution replay fixtures.
    // Reader pipelines use the lower IPhoneOCRSettings maximum.
    static let modelMaximumSide = 2_000
    /// Experimental input geometry is process-scoped, never selected from
    /// source identity, OCR text or evaluation labels. The default retains the
    /// packaged detector's established stride-rounded sampling.
    static let usesIsotropicContent = ProcessInfo.processInfo.environment["AIDOKU_DET_ISOTROPIC_CONTENT"] == "1"
    static var provenanceABI: String {
        usesIsotropicContent
            ? "native-db-bounded-bilinear-bgr-planar-float32-v3-isotropic-content"
            : "native-db-bounded-bilinear-bgr-planar-float32-v2-no-upsample-content"
    }
    static var normalizationConfigurationSHA256:String {
        let parts=channelMean.map {String($0.bitPattern)}+channelStandardDeviation.map {String($0.bitPattern)}
        return NativeCoreMLDBProvenance.sha(provenanceABI+"|padding=zero|"+parts.joined(separator:"|"))
    }
    private static let channelMean: [Float] = [0.485, 0.456, 0.406]
    private static let channelStandardDeviation: [Float] = [
        0.229,
        0.224,
        0.225,
    ]

    private static func alignedMaximumSide(_ maximumSide: Int) -> Int {
        max(32, min(modelMaximumSide, maximumSide) / 32 * 32)
    }

    static func resizeDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumSide: Int = IPhoneOCRSettings.defaultDetectorMaximumSide
    ) -> (width: Int, height: Int)? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let alignedMaximumSide = alignedMaximumSide(maximumSide)
        let sourceMaximumSide = max(sourceWidth, sourceHeight)
        let scale = sourceMaximumSide > alignedMaximumSide
            ? Double(alignedMaximumSide) / Double(sourceMaximumSide)
            : 1
        // Always pad upward to the detector stride. Rounding down would throw
        // away source detail solely to satisfy the model shape contract.
        let width = max(
            32,
            Int(ceil(Double(sourceWidth) * scale / 32)) * 32
        )
        let height = max(
            32,
            Int(ceil(Double(sourceHeight) * scale / 32)) * 32
        )
        return (
            min(alignedMaximumSide, width),
            min(alignedMaximumSide, height)
        )
    }

    /// Separate source content from the stride-aligned model canvas. The
    /// existing aligned sizing is retained for unaffected downscaled pages;
    /// an axis must never gain source samples just to reach the model stride.
    static func contentDimensions(
        sourceWidth: Int, sourceHeight: Int,
        maximumSide: Int = IPhoneOCRSettings.defaultDetectorMaximumSide,
        isotropic: Bool = usesIsotropicContent
    ) -> (width: Int, height: Int)? {
        guard let aligned = resizeDimensions(sourceWidth: sourceWidth,
            sourceHeight: sourceHeight, maximumSide: maximumSide) else { return nil }
        if isotropic {
            let scale = min(1, Double(alignedMaximumSide(maximumSide)) / Double(max(sourceWidth, sourceHeight)))
            // Preserve a single geometric scale; rounding changes an axis by
            // at most half a content pixel. Stride accommodation is padding.
            return (
                min(sourceWidth, max(1, Int((Double(sourceWidth) * scale).rounded()))),
                min(sourceHeight, max(1, Int((Double(sourceHeight) * scale).rounded())))
            )
        }
        return (min(sourceWidth, aligned.width), min(sourceHeight, aligned.height))
    }

    static func prepare(
        frame: NativeOCRRGBAFrame,
        canvas: NativeCoreMLDetectionCanvas,
        cancellationCheck: () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionPreparedTensor {
        try cancellationCheck()
        guard let dimensions = contentDimensions(
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            maximumSide: max(canvas.width, canvas.height)
        ) else { throw NativeCoreMLDetectorError.modelInputCreationFailed }
        guard dimensions.width <= canvas.width,
              dimensions.height <= canvas.height
        else {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        // Sample directly into the bounded canvas. Only recognition crops
        // retain full-resolution RGBA; detector intermediates stay page-bounded.
        return try await prepareBounded(
            frame: frame, canvas: canvas, dimensions: dimensions,
            cancellationCheck: cancellationCheck
        )
    }

    static func prepareBounded(
        frame: NativeOCRRGBAFrame, canvas: NativeCoreMLDetectionCanvas,
        dimensions: (width: Int, height: Int), cancellationCheck: () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionPreparedTensor {
        guard dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= frame.width, dimensions.height <= frame.height,
              dimensions.width <= canvas.width, dimensions.height <= canvas.height else {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        let started = nowMilliseconds()
        let sourceXs = await resizeCoordinates(sourceLength: frame.width, targetLength: dimensions.width, resizesOtherAxis: frame.height != dimensions.height)
        try cancellationCheck()
        try Task.checkCancellation()
        let sourceYs = await resizeCoordinates(sourceLength: frame.height, targetLength: dimensions.height, vertical: true, resizesOtherAxis: frame.width != dimensions.width)
        try cancellationCheck()
        try Task.checkCancellation()
        let values = try fillBoundedInput(
            frame: frame, canvasWidth: canvas.width, canvasHeight: canvas.height,
            width: dimensions.width, height: dimensions.height,
            sourceXs: sourceXs, sourceYs: sourceYs, cancellationCheck: cancellationCheck
        )
        let input = MLTensor(shape: canvas.inputShape, scalars: values)
        return NativeCoreMLDetectionPreparedTensor(input: input,
            inputSHA256:NativeMainEnsembleDBCapability.digest(values),canvas: canvas,
            resizedWidth: dimensions.width, resizedHeight: dimensions.height,
            inputTensorCreationMilliseconds: nowMilliseconds() - started, tensorGraphMilliseconds: 0)
    }

    /// Geometry-only (V2) input: the same planar canvas written straight into a
    /// Core ML multiarray. No `MLTensor` and no input digest (V2 never records
    /// probability provenance); the Float values are identical to `prepare`.
    static func prepareArray(
        frame: NativeOCRRGBAFrame,
        canvas: NativeCoreMLDetectionCanvas,
        cancellationCheck: () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionPreparedArray {
        try cancellationCheck()
        guard let dimensions = contentDimensions(
            sourceWidth: frame.width, sourceHeight: frame.height,
            maximumSide: max(canvas.width, canvas.height)
        ), dimensions.width > 0, dimensions.height > 0,
        dimensions.width <= frame.width, dimensions.height <= frame.height,
        dimensions.width <= canvas.width, dimensions.height <= canvas.height
        else { throw NativeCoreMLDetectorError.modelInputCreationFailed }
        let started = nowMilliseconds()
        let sourceXs = await resizeCoordinates(sourceLength: frame.width, targetLength: dimensions.width,
                                               resizesOtherAxis: frame.height != dimensions.height)
        try cancellationCheck()
        try Task.checkCancellation()
        let sourceYs = await resizeCoordinates(sourceLength: frame.height, targetLength: dimensions.height, vertical: true,
                                               resizesOtherAxis: frame.width != dimensions.width)
        try cancellationCheck()
        try Task.checkCancellation()
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: canvas.inputShape.map { NSNumber(value: $0) }, dataType: .float32)
        } catch {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        let contiguous = [3 * canvas.height * canvas.width, canvas.height * canvas.width, canvas.width, 1]
        try array.withUnsafeMutableBytes { bytes, strides in
            guard strides == contiguous, bytes.count >= contiguous[0] * MemoryLayout<Float>.stride,
                  let base = bytes.baseAddress?.assumingMemoryBound(to: Float.self)
            else { throw NativeCoreMLDetectorError.modelInputCreationFailed }
            try fillBoundedInput(
                frame: frame, canvasWidth: canvas.width, canvasHeight: canvas.height,
                width: dimensions.width, height: dimensions.height,
                sourceXs: sourceXs, sourceYs: sourceYs, into: base, cancellationCheck: cancellationCheck
            )
        }
        return NativeCoreMLDetectionPreparedArray(
            input: array, canvas: canvas, resizedWidth: dimensions.width, resizedHeight: dimensions.height,
            inputCreationMilliseconds: nowMilliseconds() - started
        )
    }

    /// Rows submitted to one `concurrentPerform` pass. Cancellation is observed
    /// on the calling task between passes (GCD workers have no current Task).
    private static let boundedRowsPerPass = 256
    /// Rows written by one concurrent iteration. Every iteration owns a
    /// disjoint row range in all three planes, so writes never overlap.
    private static let boundedRowsPerBand = 16

    /// Bilinear resize + BGR normalization into the planar canvas. Every
    /// element uses exactly the same Float expression as the historical scalar
    /// loop; rows are only distributed across cores, so the result is
    /// bit-identical. Only padding is zeroed: content cells are all written by
    /// the row bands, so initializing them first would duplicate those writes.
    static func fillBoundedInput(
        frame: NativeOCRRGBAFrame, canvasWidth: Int, canvasHeight: Int,
        width: Int, height: Int,
        sourceXs: [(Int, Int, Float)], sourceYs: [(Int, Int, Float)],
        cancellationCheck: () throws -> Void = {}
    ) throws -> [Float] {
        let count = canvasWidth * canvasHeight * 3
        return try [Float](unsafeUninitializedCapacity: max(0, count)) { target, initializedCount in
            guard let output = target.baseAddress else { return }
            try fillBoundedInput(
                frame: frame, canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                width: width, height: height, sourceXs: sourceXs, sourceYs: sourceYs,
                into: output, cancellationCheck: cancellationCheck
            )
            initializedCount = count
        }
    }

    /// Writes the planar canvas (`3 * canvasWidth * canvasHeight` Floats) into
    /// caller-owned contiguous storage, e.g. a Core ML multiarray buffer.
    static func fillBoundedInput(
        frame: NativeOCRRGBAFrame, canvasWidth: Int, canvasHeight: Int,
        width: Int, height: Int,
        sourceXs: [(Int, Int, Float)], sourceYs: [(Int, Int, Float)],
        into output: UnsafeMutablePointer<Float>,
        cancellationCheck: () throws -> Void = {}
    ) throws {
        guard width > 0, height > 0, width <= canvasWidth, height <= canvasHeight,
              sourceXs.count >= width, sourceYs.count >= height,
              frame.width > 0, frame.height > 0, frame.bytesPerRow >= frame.width * 4,
              frame.bytes.count >= (frame.height - 1) * frame.bytesPerRow + frame.width * 4
        else {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        for index in 0..<width {
            let (x0, x1, _) = sourceXs[index]
            guard x0 >= 0, x1 >= 0, x0 < frame.width, x1 < frame.width else {
                throw NativeCoreMLDetectorError.modelInputCreationFailed
            }
        }
        for index in 0..<height {
            let (y0, y1, _) = sourceYs[index]
            guard y0 >= 0, y1 >= 0, y0 < frame.height, y1 < frame.height else {
                throw NativeCoreMLDetectorError.modelInputCreationFailed
            }
        }
        let plane = canvasWidth * canvasHeight
        let coversCanvas = width == canvasWidth && height == canvasHeight
        let mean0 = channelMean[0], mean1 = channelMean[1], mean2 = channelMean[2]
        let deviation0 = channelStandardDeviation[0]
        let deviation1 = channelStandardDeviation[1]
        let deviation2 = channelStandardDeviation[2]
        let bytesPerRow = frame.bytesPerRow
        let leftOffsets = sourceXs.prefix(width).map { $0.0 * 4 }
        let rightOffsets = sourceXs.prefix(width).map { $0.1 * 4 }
        let xWeights = sourceXs.prefix(width).map { $0.2 }
        let rows = Array(sourceYs.prefix(height))
        do {
            if !coversCanvas {
                for channel in 0..<3 {
                    let channelBase = output + channel * plane
                    if width < canvasWidth {
                        for row in 0..<height {
                            (channelBase + row * canvasWidth + width)
                                .initialize(repeating: 0, count: canvasWidth - width)
                        }
                    }
                    if height < canvasHeight {
                        (channelBase + height * canvasWidth)
                            .initialize(repeating: 0, count: (canvasHeight - height) * canvasWidth)
                    }
                }
            }
            try frame.bytes.withUnsafeBufferPointer { sourceBuffer in
            try leftOffsets.withUnsafeBufferPointer { leftBuffer in
            try rightOffsets.withUnsafeBufferPointer { rightBuffer in
            try xWeights.withUnsafeBufferPointer { weightBuffer in
            try rows.withUnsafeBufferPointer { rowBuffer in
                guard let source = sourceBuffer.baseAddress,
                      let left = leftBuffer.baseAddress,
                      let right = rightBuffer.baseAddress,
                      let weights = weightBuffer.baseAddress,
                      let sourceRows = rowBuffer.baseAddress
                else { return }
                var passStart = 0
                while passStart < height {
                    try cancellationCheck()
                    try Task.checkCancellation()
                    let passEnd = min(height, passStart + boundedRowsPerPass)
                    let firstRow = passStart
                    let bands = (passEnd - firstRow + boundedRowsPerBand - 1) / boundedRowsPerBand
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        let bandStart = firstRow + band * boundedRowsPerBand
                        let bandEnd = min(passEnd, bandStart + boundedRowsPerBand)
                        for y in bandStart..<bandEnd {
                            let (y0, y1, fy) = sourceRows[y]
                            let top = source + y0 * bytesPerRow
                            let bottom = source + y1 * bytesPerRow
                            let blue = output + y * canvasWidth
                            let green = blue + plane
                            let red = green + plane
                            for x in 0..<width {
                                let x0 = left[x]
                                let x1 = right[x]
                                let fx = weights[x]
                                // Detector uses BGR: channel c reads RGBA byte 2 - c.
                                do {
                                    let a = Float(top[x0 + 2])
                                    let b = Float(top[x1 + 2])
                                    let c = Float(bottom[x0 + 2])
                                    let d = Float(bottom[x1 + 2])
                                    let pixel = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                                    blue[x] = (pixel / 255 - mean0) / deviation0
                                }
                                do {
                                    let a = Float(top[x0 + 1])
                                    let b = Float(top[x1 + 1])
                                    let c = Float(bottom[x0 + 1])
                                    let d = Float(bottom[x1 + 1])
                                    let pixel = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                                    green[x] = (pixel / 255 - mean1) / deviation1
                                }
                                do {
                                    let a = Float(top[x0])
                                    let b = Float(top[x1])
                                    let c = Float(bottom[x0])
                                    let d = Float(bottom[x1])
                                    let pixel = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                                    red[x] = (pixel / 255 - mean2) / deviation2
                                }
                            }
                        }
                    }
                    passStart = passEnd
                }
            }
            }
            }
            }
            }
        }
    }

    private struct ResizeCoordinateKey: Hashable {
        let sourceLength: Int
        let targetLength: Int
        let vertical: Bool
        let resizesOtherAxis: Bool
    }

    /// Consecutive reader pages almost always share source and canvas sizes.
    /// The ramps are a pure function of the key, so a tiny LRU replays the
    /// exact CPU `MLTensor` result instead of building two tensor graphs per
    /// page. Eight entries of at most 2,000 coordinates stay below 400 KB.
    private static let resizeCoordinateCacheCapacity = 8
    private static let resizeCoordinateCache = ResizeCoordinateCache()

    private final class ResizeCoordinateCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: ResizeCoordinateKey, value: [(Int, Int, Float)])] = []

        func value(for key: ResizeCoordinateKey) -> [(Int, Int, Float)]? {
            lock.lock()
            defer { lock.unlock() }
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.value
        }

        func store(_ value: [(Int, Int, Float)], for key: ResizeCoordinateKey, capacity: Int) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll { $0.key == key }
            entries.append((key, value))
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
    }

    /// Native one-dimensional ramps preserve the resize backend's exact
    /// half-pixel rounding without allocating full-resolution Float images.
    /// Match whether one or both axes resize: Core ML selects different
    /// coordinate kernels for these cases. Two constant rows/columns (three
    /// after resizing) preserve this distinction with only linear storage.
    /// A parity ramp carries the fractional weight separately: subtracting
    /// the integer part of a large coordinate loses several Float ULPs.
    static func resizeCoordinates(
        sourceLength: Int, targetLength: Int, vertical: Bool = false, resizesOtherAxis: Bool = false
    ) async -> [(Int, Int, Float)] {
        // Identity ramps obey the same cache contract as resized ramps. In
        // particular, pages below the detector limit retain their source
        // samples and should not rebuild two identical arrays per request.
        let key = ResizeCoordinateKey(sourceLength: sourceLength, targetLength: targetLength,
                                      vertical: vertical, resizesOtherAxis: resizesOtherAxis)
        if let cached = resizeCoordinateCache.value(for: key) { return cached }
        let computed = await computeResizeCoordinates(
            sourceLength: sourceLength, targetLength: targetLength,
            vertical: vertical, resizesOtherAxis: resizesOtherAxis
        )
        resizeCoordinateCache.store(computed, for: key, capacity: resizeCoordinateCacheCapacity)
        return computed
    }

    /// Uncached ramp construction; exposed for cache identity tests.
    static func computeResizeCoordinates(
        sourceLength: Int, targetLength: Int, vertical: Bool = false, resizesOtherAxis: Bool = false
    ) async -> [(Int, Int, Float)] {
        if sourceLength == targetLength {
            return (0..<targetLength).map { ($0, $0, 0) }
        }
        let positions = (0..<sourceLength).map(Float.init)
        let parity = (0..<sourceLength).map { Float($0 % 2) }
        let scalars = vertical
            ? (positions + parity + parity).flatMap { [$0, $0] }
            : positions + positions + parity + parity + parity + parity
        let orthogonalSize = resizesOtherAxis ? 3 : 2
        let coordinates = withMLTensorComputePolicy(.cpuOnly) {
            MLTensor(shape: vertical ? [1, 3, sourceLength, 2] : [1, 3, 2, sourceLength],
                     scalars: scalars)
                .resized(to: vertical ? (targetLength, orthogonalSize) : (orthogonalSize, targetLength),
                         method: .bilinear(alignCorners: false))
        }
        let values = await coordinates.shapedArray(of: Float.self).scalars
        return (0..<targetLength).map { index in
            let offset = vertical ? index * orthogonalSize : index
            let lower = min(sourceLength - 1, max(0, Int(values[offset])))
            let weight = values[targetLength * orthogonalSize + offset]
            return (lower, min(lower + 1, sourceLength - 1), lower.isMultiple(of: 2) ? weight : 1 - weight)
        }
    }

    private static func nowMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }
}

@available(iOS 18.0, *)
enum NativeCoreMLDetectionOutput {
    static func makeMap(
        output: MLTensor,
        width: Int,
        height: Int,
        expectedShape: [Int]
    ) async throws -> NativeCoreMLDetectionMap {
        try await makeMap(
            output: output,
            region: .full(width: width, height: height),
            fullWidth: width,
            fullHeight: height,
            expectedShape: expectedShape
        )
    }

    static func makeMap(
        output: MLTensor,
        region: NativeCoreMLDetectionMapRegion,
        fullWidth: Int,
        fullHeight: Int,
        expectedShape: [Int]
    ) async throws -> NativeCoreMLDetectionMap {
        guard expectedShape.count == 4,
              output.shape == expectedShape,
              fullWidth > 0,
              fullHeight > 0,
              fullWidth <= expectedShape[3],
              fullHeight <= expectedShape[2],
              region.maximumX <= fullWidth,
              region.maximumY <= fullHeight
        else {
            throw NativeCoreMLDetectorError.modelOutputShape(
                expected: expectedShape,
                actual: output.shape
            )
        }
        // When source content covers the stride-aligned canvas, a full-map
        // request covers the whole output. Materialize it directly instead of
        // building a slice graph that copies the same values once more.
        if region.x == 0, region.y == 0,
           region.width == expectedShape[3],
           region.height == expectedShape[2] {
            let shaped = await output.shapedArray(of: Float.self)
            return try shaped.withUnsafeShapedBufferPointer {
                pointer,
                shape,
                strides in
                guard shape == expectedShape,
                      strides.count == 4,
                      let baseAddress = pointer.baseAddress
                else {
                    throw NativeCoreMLDetectorError.modelOutputShape(
                        expected: expectedShape,
                        actual: shape
                    )
                }
                return makeMap(
                    pointer: baseAddress,
                    width: region.width,
                    height: region.height,
                    rowStride: strides[2],
                    columnStride: strides[3]
                )
            }
        }
        // Crop while the result is still an MLTensor. On a portrait capture
        // this avoids transferring the unused right side of the 1,920-square
        // probability map from ML compute storage back to CPU memory. Dirty
        // recognition narrows both dimensions without changing inference.
        let cropped = output[
            0,
            0,
            region.y..<region.maximumY,
            region.x..<region.maximumX
        ]
        guard cropped.shape == [region.height, region.width] else {
            throw NativeCoreMLDetectorError.modelOutputShape(
                expected: [region.height, region.width],
                actual: cropped.shape
            )
        }
        let shaped = await cropped.shapedArray(of: Float.self)
        return try shaped.withUnsafeShapedBufferPointer {
            pointer,
            shape,
            strides in
            guard shape == [region.height, region.width],
                  strides.count == 2,
                  let baseAddress = pointer.baseAddress
            else {
                throw NativeCoreMLDetectorError.modelOutputShape(
                    expected: [region.height, region.width],
                    actual: shape
                )
            }
            return makeMap(
                pointer: baseAddress,
                width: region.width,
                height: region.height,
                rowStride: strides[0],
                columnStride: strides[1]
            )
        }
    }

    static func makeMap(
        output: MLMultiArray,
        width: Int,
        height: Int,
        expectedShape: [Int]
    ) throws -> NativeCoreMLDetectionMap {
        try makeMap(
            output: output,
            region: .full(width: width, height: height),
            fullWidth: width,
            fullHeight: height,
            expectedShape: expectedShape
        )
    }

    static func makeMap(
        output: MLMultiArray,
        region: NativeCoreMLDetectionMapRegion,
        fullWidth: Int,
        fullHeight: Int,
        expectedShape: [Int]
    ) throws -> NativeCoreMLDetectionMap {
        let actualShape = output.shape.map(\.intValue)
        guard actualShape == expectedShape,
              output.strides.count == 4,
              fullWidth > 0,
              fullHeight > 0,
              fullWidth <= expectedShape[3],
              fullHeight <= expectedShape[2],
              region.maximumX <= fullWidth,
              region.maximumY <= fullHeight
        else {
            throw NativeCoreMLDetectorError.modelOutputShape(
                expected: expectedShape,
                actual: actualShape
            )
        }
        let rowStride = output.strides[2].intValue
        let columnStride = output.strides[3].intValue
        let originOffset = region.y * rowStride + region.x * columnStride
        switch output.dataType {
        case .float32:
            return makeMap(
                pointer: output.dataPointer.assumingMemoryBound(
                    to: Float.self
                ).advanced(by: originOffset),
                width: region.width,
                height: region.height,
                rowStride: rowStride,
                columnStride: columnStride
            )
        case .float16:
            return makeMap(
                pointer: output.dataPointer.assumingMemoryBound(
                    to: Float16.self
                ).advanced(by: originOffset),
                width: region.width,
                height: region.height,
                rowStride: rowStride,
                columnStride: columnStride
            )
        case .double:
            return makeMap(
                pointer: output.dataPointer.assumingMemoryBound(
                    to: Double.self
                ).advanced(by: originOffset),
                width: region.width,
                height: region.height,
                rowStride: rowStride,
                columnStride: columnStride
            )
        default:
            throw NativeCoreMLDetectorError.unsupportedModelOutputType
        }
    }

    /// A threshold component touching an artificial crop edge may continue
    /// outside the ROI. Re-materializing the full output is mandatory before
    /// DB can establish its complete hull and unclip distance.
    static func requiresFullFallback(
        map: NativeCoreMLDetectionMap,
        region: NativeCoreMLDetectionMapRegion,
        fullWidth: Int,
        fullHeight: Int,
        threshold: Double
    ) -> Bool {
        @inline(__always)
        func isForeground(_ x: Int, _ y: Int) -> Bool {
            let value = map.values[y * map.width + x]
            return value.isFinite && Double(value) > threshold
        }
        if region.y > 0 {
            for x in 0..<map.width where isForeground(x, 0) { return true }
        }
        if region.maximumY < fullHeight {
            for x in 0..<map.width
            where isForeground(x, map.height - 1) { return true }
        }
        if region.x > 0 {
            for y in 0..<map.height where isForeground(0, y) { return true }
        }
        if region.maximumX < fullWidth {
            for y in 0..<map.height
            where isForeground(map.width - 1, y) { return true }
        }
        return false
    }

    /// Even a complete component may have an unclip rectangle reaching the
    /// internal ROI edge. Treat that as insufficient guard space and retry
    /// full postprocessing from the already-computed model output.
    static func boxesTouchArtificialEdge(
        _ boxes: [NativeCoreMLDetectionBox],
        region: NativeCoreMLDetectionMapRegion,
        fullWidth: Int,
        fullHeight: Int,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> Bool {
        let left = Double(region.x * sourceWidth) / Double(fullWidth)
        let right = Double(region.maximumX * sourceWidth) / Double(fullWidth)
        let top = Double(region.y * sourceHeight) / Double(fullHeight)
        let bottom = Double(region.maximumY * sourceHeight)
            / Double(fullHeight)
        let toleranceX = Double(sourceWidth) / Double(fullWidth) + 1
        let toleranceY = Double(sourceHeight) / Double(fullHeight) + 1
        for box in boxes {
            guard let minimumX = box.polygon.map(\.x).min(),
                  let maximumX = box.polygon.map(\.x).max(),
                  let minimumY = box.polygon.map(\.y).min(),
                  let maximumY = box.polygon.map(\.y).max()
            else {
                continue
            }
            if region.x > 0, Double(minimumX) <= left + toleranceX {
                return true
            }
            if region.maximumX < fullWidth,
               Double(maximumX) >= right - toleranceX {
                return true
            }
            if region.y > 0, Double(minimumY) <= top + toleranceY {
                return true
            }
            if region.maximumY < fullHeight,
               Double(maximumY) >= bottom - toleranceY {
                return true
            }
        }
        return false
    }

    static func makeMap<Element: BinaryFloatingPoint>(
        pointer: UnsafePointer<Element>,
        width: Int,
        height: Int,
        rowStride: Int,
        columnStride: Int
    ) -> NativeCoreMLDetectionMap {
        let count = width * height
        let values = [Float](unsafeUninitializedCapacity: count) {
            buffer,
            initializedCount in
            guard let destination = buffer.baseAddress else { return }
            if Element.self == Float.self, columnStride == 1 {
                // Same Float values, copied a row (or the whole map) at once.
                let source = UnsafeRawPointer(pointer)
                    .assumingMemoryBound(to: Float.self)
                if rowStride == width {
                    destination.initialize(from: source, count: count)
                } else {
                    for row in 0..<height {
                        (destination + row * width).initialize(
                            from: source + row * rowStride,
                            count: width
                        )
                    }
                }
            } else {
                for row in 0..<height {
                    let sourceRow = pointer + row * rowStride
                    let destinationRow = destination + row * width
                    for column in 0..<width {
                        destinationRow[column] = Float(
                            sourceRow[column * columnStride]
                        )
                    }
                }
            }
            initializedCount = count
        }
        return NativeCoreMLDetectionMap(
            width: width,
            height: height,
            values: values
        )
    }
}
