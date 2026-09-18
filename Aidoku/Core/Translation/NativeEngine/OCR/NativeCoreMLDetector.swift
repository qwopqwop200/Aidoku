// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
@preconcurrency import CoreML
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLDetectionBox: Equatable, Sendable {
    let polygon: [CGPoint]
    let score: Double
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionCanvas: Equatable, Hashable, Sendable {
    // Browser controls can change the visible viewport height. Keep exact
    // fixed-shape functions for the observed iPhone portrait aspect family;
    // choosing a nearby padded shape is not
    // equivalent for PP-OCRv6 because its detector contains spatial global
    // reductions.
    static let portrait480 = Self(
        functionName: "detPortrait480x1920",
        width: 480,
        height: 1_920
    )
    static let portrait640 = Self(
        functionName: "detPortrait640x1920",
        width: 640,
        height: 1_920
    )
    static let portrait704 = Self(
        functionName: "detPortrait704x1920",
        width: 704,
        height: 1_920
    )
    static let portrait1088 = Self(
        functionName: "detPortrait1088x1920",
        width: 1_088,
        height: 1_920
    )
    static let portrait1120 = Self(
        functionName: "detPortrait1120x1920",
        width: 1_120,
        height: 1_920
    )
    static let portrait1280 = Self(
        functionName: "detPortrait1280x1920",
        width: 1_280,
        height: 1_920
    )
    static let portrait1440 = Self(
        functionName: "detPortrait1440x1920",
        width: 1_440,
        height: 1_920
    )
    static let portrait1536 = Self(
        functionName: "detPortrait1536x1920",
        width: 1_536,
        height: 1_920
    )
    static let portrait = portrait1120
    static let landscape480 = Self(
        functionName: "detLandscape1920x480",
        width: 1_920,
        height: 480
    )
    static let landscape640 = Self(
        functionName: "detLandscape1920x640",
        width: 1_920,
        height: 640
    )
    static let landscape704 = Self(
        functionName: "detLandscape1920x704",
        width: 1_920,
        height: 704
    )
    static let landscape896 = Self(
        functionName: "detLandscape1920x896",
        width: 1_920,
        height: 896
    )
    static let landscape960 = Self(
        functionName: "detLandscape1920x960",
        width: 1_920,
        height: 960
    )
    static let landscape1088 = Self(
        functionName: "detLandscape1920x1088",
        width: 1_920,
        height: 1_088
    )
    static let landscape1120 = Self(
        functionName: "detLandscape1920x1120",
        width: 1_920,
        height: 1_120
    )
    static let landscape1280 = Self(
        functionName: "detLandscape1920x1280",
        width: 1_920,
        height: 1_280
    )
    static let landscape1440 = Self(
        functionName: "detLandscape1920x1440",
        width: 1_920,
        height: 1_440
    )
    static let landscape1536 = Self(
        functionName: "detLandscape1920x1536",
        width: 1_920,
        height: 1_536
    )
    static let landscape = landscape1120
    static let square = Self(
        functionName: "detSquare1920",
        width: 1_920,
        height: 1_920
    )
    static let all = [
        portrait480,
        portrait640,
        portrait704,
        portrait1088,
        portrait1120,
        portrait1280,
        portrait1440,
        portrait1536,
        landscape480,
        landscape640,
        landscape704,
        landscape896,
        landscape960,
        landscape1088,
        landscape1120,
        landscape1280,
        landscape1440,
        landscape1536,
        square,
    ]

    let functionName: String
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
        self.init(
            functionName: "dynamic",
            width: inputShape[3],
            height: inputShape[2]
        )
    }

    static func exact(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumSide: Int = NativeCoreMLDetectionPreprocessor.canvasSide
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
        return Self(
            functionName: "dynamic",
            width: dimensions.width,
            height: dimensions.height
        )
    }

    private init(functionName: String, width: Int, height: Int) {
        self.functionName = functionName
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
protocol NativeCoreMLDetectionPredicting: AnyObject, Sendable {
    var modelName: String { get }
    var inputFeatureName: String { get }
    var outputFeatureName: String { get }
    var computeUnits: String { get }

    func predict(
        input: MLTensor
    ) async throws -> NativeCoreMLDetectionPrediction

    func prepare(canvas: NativeCoreMLDetectionCanvas) async throws
    func prepare(
        canvas: NativeCoreMLDetectionCanvas,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws
    func purgeResources() async
}

@available(iOS 18.0, *)
extension NativeCoreMLDetectionPredicting {
    var computeUnits: String { "all" }
    func prepare(canvas: NativeCoreMLDetectionCanvas) async throws {}
    func prepare(
        canvas: NativeCoreMLDetectionCanvas,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        try cancellationCheck()
        try await prepare(canvas: canvas)
        try cancellationCheck()
    }
    func purgeResources() async {}
}

@available(iOS 18.0, *)
struct NativeCoreMLDetectionPrediction: Sendable {
    let output: MLTensor
    let modelWasLoaded: Bool
    let modelLoadMilliseconds: Double
}

@available(iOS 18.0, *)
private final class NativeCoreMLDetectorModelPredictor:
    NativeCoreMLDetectionPredicting
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

    private actor ModelStore {
        private let asset: MLModelAsset
        private var model: ModelHandle?
        private var preparedCanvases: Set<NativeCoreMLDetectionCanvas> = []
        private var revision: UInt64 = 0
        private let sharedLoads = NativeCoreMLSharedLoadCoordinator<
            String,
            LoadedModel
        >()

        init(asset: MLModelAsset) {
            self.asset = asset
        }

        func model(
            for canvas: NativeCoreMLDetectionCanvas,
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
                    isPrepared: preparedCanvases.contains(canvas)
                )
            }
            let asset = self.asset
            let access = try await sharedLoads.load(for: "dynamic") {
                    let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
                    configuration.computeUnits = .cpuOnly
#else
                    configuration.computeUnits = .all
#endif
                    configuration.modelDisplayName = "PP-OCRv6 Medium Dynamic"
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
    var computeUnits: String {
#if targetEnvironment(simulator)
        "cpuOnly"
#else
        "all"
#endif
    }

    private let modelStore: ModelStore

    init(
        modelURL: URL,
        modelName: String,
        inputFeatureName: String,
        outputFeatureName: String
    ) throws {
        modelStore = ModelStore(asset: try MLModelAsset(url: modelURL))
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
        let prediction: [String: MLTensor]
#if targetEnvironment(simulator)
        prediction = try await withMLTensorComputePolicy(.cpuOnly) {
            try await modelAccess.handle.model.prediction(
                from: [inputFeatureName: input]
            )
        }
#else
        prediction = try await withMLTensorComputePolicy(.init(.all)) {
            try await modelAccess.handle.model.prediction(
                from: [inputFeatureName: input]
            )
        }
#endif
        guard let output = prediction[outputFeatureName] else {
            throw NativeCoreMLDetectorError.modelOutputMissing
        }
        return NativeCoreMLDetectionPrediction(
            output: output,
            modelWasLoaded: modelAccess.wasLoaded,
            modelLoadMilliseconds: modelAccess.loadMilliseconds
        )
    }

    func prepare(canvas: NativeCoreMLDetectionCanvas) async throws {
        try await prepare(canvas: canvas, cancellationCheck: {})
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
        // Loading a multifunction MLProgram does not compile its GPU kernels.
        // Run one exact-shape zero prediction and materialize the result so the
        // first visible OCR frame does not pay that specialization cost.
        let input = MLTensor(
            zeros: canvas.inputShape,
            scalarType: Float.self
        )
        let prediction: [String: MLTensor]
#if targetEnvironment(simulator)
        prediction = try await withMLTensorComputePolicy(.cpuOnly) {
            try await modelAccess.handle.model.prediction(
                from: [inputFeatureName: input]
            )
        }
#else
        prediction = try await withMLTensorComputePolicy(.init(.all)) {
            try await modelAccess.handle.model.prediction(
                from: [inputFeatureName: input]
            )
        }
#endif
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
    static let modelResourceName = "PP-OCRv6-Medium-DetShapes"
    static let inputFeatureName = "x"
    static let outputFeatureName = "fetch_name_0"
    static let inputShape = [1, 3, 1_920, 1_920]
    static let outputShape = [1, 1, 1_920, 1_920]

    private struct Resources: Sendable {
        let predictor: any NativeCoreMLDetectionPredicting
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
        maximumSide: Int = NativeCoreMLDetectionPreprocessor.canvasSide
    ) {
        // The split has been evaluated on the bundled Medium probability maps.
        // Other model tiers retain their established postprocessing behavior.
        allowsWeakBridgeSplit = modelResourceName == Self.modelResourceName
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

    init(predictor: any NativeCoreMLDetectionPredicting) {
        allowsWeakBridgeSplit = false
        let resources = Resources(
            predictor: predictor,
            loadMilliseconds: 0
        )
        resourceLoader = { resources }
        // Test predictors use the historical square tensor contract so unit
        // tests can exercise cancellation and postprocessing on tiny images
        // without loading a 1,920-pixel production source.
        canvasSelector = { _, _ in .square }
        loadedResources = resources
    }

    static func supportsSourceDimensions(
        width: Int,
        height: Int,
        maximumSide: Int = NativeCoreMLDetectionPreprocessor.canvasSide
    ) -> Bool {
        NativeCoreMLDetectionCanvas.exact(
            sourceWidth: width,
            sourceHeight: height,
            maximumSide: maximumSide
        ) != nil
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
        configuration: NativeCoreMLDBPostprocessConfiguration = .production,
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
        configuration: NativeCoreMLDBPostprocessConfiguration = .production,
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
        configuration: NativeCoreMLDBPostprocessConfiguration = .production,
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

    private func performDetection(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        requestID: String,
        configuration: NativeCoreMLDBPostprocessConfiguration,
        recognitionScopes: [CGRect]?,
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
            let prepared = try await Task.detached(
                priority: .userInitiated
            ) { [self] in
                try requireCurrent(
                    issuedGeneration,
                    cancellationCheck: cancellationCheck
                )
                return try NativeCoreMLDetectionPreprocessor.prepare(
                    frame: frame,
                    canvas: canvas,
                    cancellationCheck: {
                        try requireCurrent(
                            issuedGeneration,
                            cancellationCheck: cancellationCheck
                        )
                    }
                )
            }.value
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
                let result = try loadResources()
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

                func decode(
                    _ map: NativeCoreMLDetectionMap,
                    region: NativeCoreMLDetectionMapRegion
                ) throws -> NativeCoreMLDBPostprocessResult {
                    let stageStarted = Self.nowMilliseconds()
                    let result = try NativeCoreMLDBPostprocessor.decode(
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
                        allowsWeakBridgeSplit: allowsWeakBridgeSplit && configuration == .production,
                        cancellationCheck: {
                            try requireCurrent(
                                issuedGeneration,
                                cancellationCheck: cancellationCheck
                            )
                        }
                    )
                    dbPostprocessingMilliseconds += Self.nowMilliseconds()
                        - stageStarted
                    return result
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
                        postprocessed.boxes,
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
                    prepared.inputTensorCreationMilliseconds,
                tensorGraphMilliseconds:
                    prepared.tensorGraphMilliseconds,
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
        using predictor: any NativeCoreMLDetectionPredicting,
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
    let canvas: NativeCoreMLDetectionCanvas
    let resizedWidth: Int
    let resizedHeight: Int
    let inputTensorCreationMilliseconds: Double
    let tensorGraphMilliseconds: Double

    /// Test/debug materialization. Production passes the lazy tensor graph
    /// directly into Core ML so resize/normalization can stay on ML compute
    /// devices without a multi-megabyte CPU-side Float intermediate tensor.
    func values() async -> [Float] {
        await input.shapedArray(of: Float.self).scalars
    }
}

@available(iOS 18.0, *)
enum NativeCoreMLDetectionPreprocessor {
    static let canvasSide = 2_000
    private static let channelMean: [Float] = [0.485, 0.456, 0.406]
    private static let channelStandardDeviation: [Float] = [
        0.229,
        0.224,
        0.225,
    ]

    static func resizeDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumSide: Int = canvasSide
    ) -> (width: Int, height: Int)? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let alignedMaximumSide = max(
            32,
            min(canvasSide, maximumSide) / 32 * 32
        )
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

    static func prepare(
        frame: NativeOCRRGBAFrame,
        canvas: NativeCoreMLDetectionCanvas = .square,
        useBoundedMemory: Bool = true,
        cancellationCheck: () throws -> Void = {}
    ) throws -> NativeCoreMLDetectionPreparedTensor {
        try cancellationCheck()
        let dimensions = resizeDimensions(
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            maximumSide: max(canvas.width, canvas.height)
        ) ?? (canvas.width, canvas.height)
        guard dimensions.width <= canvas.width,
              dimensions.height <= canvas.height
        else {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        // Every source size previously built its own GPU resize/normalization
        // graph below the 4 MP cutoff. Its full-resolution intermediates and
        // runtime caches survive individual pages and even model eviction.
        // Sample directly into the bounded canvas for ALL page sizes; retain
        // full-resolution RGBA only for the unchanged recognition crops.
        if useBoundedMemory {
            return try prepareBounded(frame: frame, canvas: canvas, dimensions: dimensions,
                                      cancellationCheck: cancellationCheck)
        }
        let inputTensorStarted = nowMilliseconds()
        let contiguousRGBA = makeContiguousRGBA(frame: frame)
        let rgba = MLTensor(
            shape: [1, frame.height, frame.width, 4],
            scalars: contiguousRGBA,
            scalarType: UInt8.self
        )
        let inputTensorElapsed = nowMilliseconds() - inputTensorStarted
        try cancellationCheck()
        let tensorGraphStarted = nowMilliseconds()
#if targetEnvironment(simulator)
        let tensorComputePolicy = MLComputePolicy.cpuOnly
#else
        let tensorComputePolicy = MLComputePolicy(.all)
#endif
        let input = withMLTensorComputePolicy(tensorComputePolicy) {
            let channelIndices = MLTensor([
                Int32(2),
                Int32(1),
                Int32(0),
            ])
            let bgr = rgba
                .transposed(permutation: [0, 3, 1, 2])
                .gathering(atIndices: channelIndices, alongAxis: 1)
                .cast(to: Float.self)
                .resized(
                    to: (dimensions.height, dimensions.width),
                    method: .bilinear(alignCorners: false)
                )
            let mean = MLTensor(
                shape: [1, 3, 1, 1],
                scalars: channelMean
            )
            let standardDeviation = MLTensor(
                shape: [1, 3, 1, 1],
                scalars: channelStandardDeviation
            )
            var padded = (bgr / Float(255) - mean) / standardDeviation
            if dimensions.width < canvas.width {
                let rightPadding = MLTensor(
                    zeros: [
                        1,
                        3,
                        dimensions.height,
                        canvas.width - dimensions.width,
                    ],
                    scalarType: Float.self
                )
                padded = MLTensor(
                    concatenating: [padded, rightPadding],
                    alongAxis: 3
                )
            }
            if dimensions.height < canvas.height {
                let bottomPadding = MLTensor(
                    zeros: [
                        1,
                        3,
                        canvas.height - dimensions.height,
                        canvas.width,
                    ],
                    scalarType: Float.self
                )
                padded = MLTensor(
                    concatenating: [padded, bottomPadding],
                    alongAxis: 2
                )
            }
            return padded
        }
        let tensorGraphElapsed = nowMilliseconds() - tensorGraphStarted
        guard input.shape == canvas.inputShape else {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        try cancellationCheck()
        return NativeCoreMLDetectionPreparedTensor(
            input: input,
            canvas: canvas,
            resizedWidth: dimensions.width,
            resizedHeight: dimensions.height,
            inputTensorCreationMilliseconds: inputTensorElapsed,
            tensorGraphMilliseconds: tensorGraphElapsed
        )
    }

    static func prepareBounded(
        frame: NativeOCRRGBAFrame, canvas: NativeCoreMLDetectionCanvas,
        dimensions: (width: Int, height: Int), cancellationCheck: () throws -> Void = {}
    ) throws -> NativeCoreMLDetectionPreparedTensor {
        guard dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= canvas.width, dimensions.height <= canvas.height else {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        let started = nowMilliseconds()
        let plane = canvas.width * canvas.height
        var values = [Float](repeating: 0, count: plane * 3)
        let scaleX = Float(frame.width) / Float(dimensions.width)
        let scaleY = Float(frame.height) / Float(dimensions.height)
        try frame.bytes.withUnsafeBufferPointer { source in
            try values.withUnsafeMutableBufferPointer { target in
                for y in 0..<dimensions.height {
                    try cancellationCheck()
                    try Task.checkCancellation()
                    let sourceY = min(Float(frame.height - 1), max(0, (Float(y) + 0.5) * scaleY - 0.5))
                    let y0 = Int(sourceY), y1 = min(y0 + 1, frame.height - 1)
                    let fy = sourceY - Float(y0)
                    for x in 0..<dimensions.width {
                        let sourceX = min(Float(frame.width - 1), max(0, (Float(x) + 0.5) * scaleX - 0.5))
                        let x0 = Int(sourceX), x1 = min(x0 + 1, frame.width - 1)
                        let fx = sourceX - Float(x0)
                        for channel in 0..<3 {
                            let offset = 2 - channel // detector uses BGR
                            let a = Float(source[y0 * frame.bytesPerRow + x0 * 4 + offset])
                            let b = Float(source[y0 * frame.bytesPerRow + x1 * 4 + offset])
                            let c = Float(source[y1 * frame.bytesPerRow + x0 * 4 + offset])
                            let d = Float(source[y1 * frame.bytesPerRow + x1 * 4 + offset])
                            let pixel = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                            target[channel * plane + y * canvas.width + x] =
                                (pixel / 255 - channelMean[channel]) / channelStandardDeviation[channel]
                        }
                    }
                }
            }
        }
        let input = MLTensor(shape: canvas.inputShape, scalars: values)
        return NativeCoreMLDetectionPreparedTensor(input: input, canvas: canvas,
            resizedWidth: dimensions.width, resizedHeight: dimensions.height,
            inputTensorCreationMilliseconds: nowMilliseconds() - started, tensorGraphMilliseconds: 0)
    }

    private static func makeContiguousRGBA(
        frame: NativeOCRRGBAFrame
    ) -> [UInt8] {
        let tightBytesPerRow = frame.width * 4
        let visibleByteCount = tightBytesPerRow * frame.height
        if frame.bytesPerRow == tightBytesPerRow,
           frame.bytes.count == visibleByteCount
        {
            return frame.bytes
        }
        var result = [UInt8](repeating: 0, count: visibleByteCount)
        result.withUnsafeMutableBytes { destination in
            frame.bytes.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress
                else {
                    return
                }
                for row in 0..<frame.height {
                    destinationBase
                        .advanced(by: row * tightBytesPerRow)
                        .copyMemory(
                            from: sourceBase.advanced(
                                by: row * frame.bytesPerRow
                            ),
                            byteCount: tightBytesPerRow
                        )
                }
            }
        }
        return result
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
        guard output.shape == expectedShape,
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

    private static func makeMap<Element: BinaryFloatingPoint>(
        pointer: UnsafePointer<Element>,
        width: Int,
        height: Int,
        rowStride: Int,
        columnStride: Int
    ) -> NativeCoreMLDetectionMap {
        var values = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                values[row * width + column] = Float(
                    pointer[row * rowStride + column * columnStride]
                )
            }
        }
        return NativeCoreMLDetectionMap(
            width: width,
            height: height,
            values: values
        )
    }
}
