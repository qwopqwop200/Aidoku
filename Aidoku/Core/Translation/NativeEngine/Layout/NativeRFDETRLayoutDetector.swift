import CoreML
import Foundation
import CoreGraphics

/// One648 model, one admitted image transaction, bounded content-addressed LRU.
/// Parent owns scheduling with OCR and all grouping/rendering policy. Failure,
/// busy or cancellation must fall back to existing OCR, never discard its text.
@available(iOS 18.0, macOS 15.0, *)
actor NativeRFDETRLayoutDetector {
    typealias ModelURLResolver = @Sendable () async throws -> URL
    private struct Asset: Hashable, Sendable {
        let url: URL
        let treeSHA256: String
        let weights: String
        let revision: String

        init(url: URL, weights: String, revision: String) throws {
            guard url.isFileURL, url.pathExtension == "mlmodelc" else { throw NativeRFDETRLayoutError.modelUnavailable }
            self.url = try NativeRFInstalledModelIdentity.canonicalURL(url)
            treeSHA256 = try NativeRFRawCachePolicy.select(direct: { "" }, cached: { try NativeRFInstalledModelIdentity.digest(url) })
            self.weights = weights
            self.revision = revision
        }
    }
    private final class ModelHandle: @unchecked Sendable {
        let model: MLModel
        let asset: Asset
        init(_ model: MLModel, _ asset: Asset) { self.model = model; self.asset = asset }
        func predict(_ provider: MLFeatureProvider) throws -> MLFeatureProvider { try model.prediction(from: provider) }
    }
    private struct CGImageHandle: @unchecked Sendable { let image: CGImage }

    /// Only raw-cache predictions share models. That cache serializes prediction
    /// and copies every output before another request may use the same model.
    private final class ValidatedModels: @unchecked Sendable {
        static let shared = ValidatedModels()
        private struct Record { weak var handle: ModelHandle? }
        private let lock = NSLock()
        private var records: [Asset: Record] = [:]
        private let queue = DispatchQueue(label: "Aidoku.RFModelLoad", qos: .userInitiated)

        func isValidated(_ asset: Asset) -> Bool { lock.withLock { records[asset] != nil } }
        func live(_ asset: Asset) -> ModelHandle? { lock.withLock { records[asset]?.handle } }

        private func load(_ asset: Asset) throws -> ModelHandle {
            if let ready = live(asset) { return ready }
            let model = try MLModel(contentsOf: asset.url, configuration: NativeRFDETRLayoutDetector.modelConfiguration())
            try NativeRFDETRLayoutTensorContract.validate(model: model, expectedWeightsSHA256: asset.weights,
                expectedSourceRevision: asset.revision)
            guard try NativeRFInstalledModelIdentity.digest(asset.url) == asset.treeSHA256 else {
                throw NativeRFDETRLayoutError.modelUnavailable
            }
            let handle = ModelHandle(model, asset)
            lock.withLock {
                if records.count >= 8 { records = records.filter { $0.value.handle != nil } }
                records[asset] = Record(handle: handle)
            }
            return handle
        }

        func initialIfNeeded(_ asset: Asset) throws -> ModelHandle? {
            try queue.sync { try isValidated(asset) ? nil : load(asset) }
        }

        private final class Admission: @unchecked Sendable {
            private let lock = NSLock()
            private var cancelled = false
            func cancel() { lock.withLock { cancelled = true } }
            func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
        }

        func acquire(_ asset: Asset) async throws -> ModelHandle {
            try Task.checkCancellation()
            if let ready = live(asset) { return ready }
            let admission = Admission()
            let handle: ModelHandle = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        continuation.resume(with: Result {
                            try admission.check()
                            return try self.load(asset)
                        })
                    }
                }
            } onCancel: { admission.cancel() }
            try Task.checkCancellation()
            return handle
        }
    }

    final class InitialModel: @unchecked Sendable {
        fileprivate let model: MLModel
        fileprivate let url: URL
        private let owner: ModelHandle?

        private init(model: MLModel, url: URL, owner: ModelHandle?) {
            self.model = model; self.url = url; self.owner = owner
        }

        static func validatedIfNeeded(contentsOf url: URL) throws -> InitialModel? {
            let asset = try Asset(url: url, weights: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
                revision: NativeRFDETRLayoutResource.highresSourceRevision)
            if NativeRFRawCachePolicy.enabled {
                guard let owner = try ValidatedModels.shared.initialIfNeeded(asset) else { return nil }
                return InitialModel(model: owner.model, url: asset.url, owner: owner)
            }
            let model = try MLModel(contentsOf: asset.url, configuration: NativeRFDETRLayoutDetector.modelConfiguration())
            try NativeRFDETRLayoutTensorContract.validate(model: model, expectedWeightsSHA256: asset.weights,
                expectedSourceRevision: asset.revision)
            return InitialModel(model: model, url: asset.url, owner: nil)
        }
    }
    private weak var initialModel: InitialModel?
    private let resolveModelURL: ModelURLResolver
    private let maximumMaskQueries: Int
    private let retainAllQueryMasks: Bool
    private let expectedWeightsSHA256: String
    private let expectedSourceRevision: String
    private let cacheByteLimit: Int
    private var resourceTask: Task<Asset, Error>?
    private var boundAsset: Asset?
    private var loadTask: Task<ModelHandle, Error>?
    private var resident: ModelHandle?
    private var operation: Task<NativeRFDETRLayoutResult, Error>?
    private var sourcePreparation: Task<(any NativeRFDETRInferenceSource, String, Double), Error>?
    private var generation: UInt64 = 0
    private var busy = false
    private var purging = false
    private var purgeWaiters: [CheckedContinuation<Void, Never>] = []
    private var cache: [String: NativeRFDETRLayoutResult] = [:]
    private var lru: [String] = []

    init(maximumMaskQueries: Int = 160, cacheByteLimit: Int = 8 * 1_048_576,
         retainAllQueryMasks: Bool = false,
         expectedWeightsSHA256: String = NativeRFDETRLayoutResource.sourceWeightsSHA256,
         expectedSourceRevision: String = NativeRFDETRLayoutResource.sourceRevision,
         initialModel: InitialModel? = nil,
         resolveModelURL: @escaping ModelURLResolver = { try NativeRFDETRLayoutResource.bundledModelURL() }) {
        self.initialModel = initialModel
        self.resolveModelURL = resolveModelURL
        self.maximumMaskQueries = min(160, max(0, maximumMaskQueries))
        self.retainAllQueryMasks = retainAllQueryMasks || NativeRFDETRBalloonDomainPolicy.requested
        self.expectedWeightsSHA256 = expectedWeightsSHA256
        self.expectedSourceRevision = expectedSourceRevision
        self.cacheByteLimit = min(16 * 1_048_576, max(0, cacheByteLimit))
    }

    /// Asynchronous background load, coalesced with actual demand. No warm-up
    /// prediction, fallback model, remote download or private benchmark path.
    func prepare() async throws { _ = try await model() }

    func detect(image: CGImage) async throws -> NativeRFDETRLayoutResult {
        let handle = CGImageHandle(image: image)
        let scope = NativeRFOCRSourceReuse.active
        let decode: @Sendable () throws -> any NativeRFDETRInferenceSource = {
            if let scope { return try scope.source(for: handle.image) }
            return try NativeRFDETRSourceImage.decode(handle.image).withPreparedIdentity()
        }
        return try await detectSource(decode)
    }

    func detect(source: NativeRFDETRSourceImage) async throws -> NativeRFDETRLayoutResult {
        try await detectSource { source.withPreparedIdentity() }
    }

    /// Invalidates work and joins it before releasing the sole model handle.
    /// Core ML submissions may finish after cancellation; stale results cannot
    /// enter the cache or reach a newer image generation.
    func purgeResources() async {
        if purging {
            await withCheckedContinuation { purgeWaiters.append($0) }
            return
        }
        purging = true
        defer {
            purging = false
            let waiters = purgeWaiters
            purgeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        initialModel = nil
        generation &+= 1
        let resolving = resourceTask
        resolving?.cancel()
        let pending = operation, loading = loadTask, preparing = sourcePreparation
        pending?.cancel()
        loading?.cancel()
        preparing?.cancel()
        _ = try? await resolving?.value
        _ = try? await preparing?.value
        _ = try? await pending?.value
        _ = try? await loading?.value
        if NativeRFRawCachePolicy.enabled { await NativeRFRawRequestCache.shared.discardCompleted() }
        resident = nil
        resourceTask = nil
        boundAsset = nil
        loadTask = nil
        cache.removeAll()
        lru.removeAll()
    }

    static func modelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
#else
        configuration.computeUnits = .cpuAndGPU
#endif
        configuration.modelDisplayName = "Koharu RF-DETR648 Auxiliary"
        return configuration
    }

    private func resource() async throws -> Asset {
        try Task.checkCancellation()
        guard !purging else { throw NativeRFDETRLayoutError.busy }
        if let boundAsset { return boundAsset }
        let revision = generation
        let task: Task<Asset, Error>
        if let resourceTask { task = resourceTask } else {
            let resolver = resolveModelURL, weights = expectedWeightsSHA256, sourceRevision = expectedSourceRevision
            task = Task.detached(priority: .utility) {
                let url = try await resolver()
                try Task.checkCancellation()
                return try Asset(url: url, weights: weights, revision: sourceRevision)
            }
            resourceTask = task
        }
        do {
            let asset = try await task.value
            guard generation == revision else { throw CancellationError() }
            boundAsset = asset
            resourceTask = nil
            try Task.checkCancellation()
            return asset
        } catch {
            if generation == revision { resourceTask = nil }
            throw error
        }
    }

    private func retain(_ handle: ModelHandle, for revision: UInt64) {
        if generation == revision, boundAsset == handle.asset, !purging { resident = handle }
    }

    private func model() async throws -> ModelHandle {
        try Task.checkCancellation()
        guard !purging else { throw NativeRFDETRLayoutError.busy }
        if let resident { return resident }
        let revision = generation
        let asset = try await resource()
        guard revision == generation else { throw CancellationError() }
        let task: Task<ModelHandle, Error>
        if let loadTask { task = loadTask } else {
            let initial = initialModel
            initialModel = nil
            task = Task.detached(priority: .utility) {
                if NativeRFRawCachePolicy.enabled { return try await ValidatedModels.shared.acquire(asset) }
                let configuration = Self.modelConfiguration()
                let model: MLModel
                if let initial, initial.url == asset.url,
                   initial.model.configuration.computeUnits == configuration.computeUnits,
                   initial.model.configuration.modelDisplayName == configuration.modelDisplayName {
                    model = initial.model
                } else {
                    model = try await MLModel.load(contentsOf: asset.url, configuration: configuration)
                }
                try NativeRFDETRLayoutTensorContract.validate(model: model,
                    expectedWeightsSHA256: asset.weights, expectedSourceRevision: asset.revision)
                try Task.checkCancellation()
                return ModelHandle(model, asset)
            }
            loadTask = task
        }
        do {
            let handle = try await task.value
            guard revision == generation else { throw CancellationError() }
            resident = handle
            loadTask = nil
            try Task.checkCancellation()
            return handle
        } catch {
            if revision == generation { loadTask = nil }
            throw error
        }
    }

    private func detectSource(_ source: @escaping @Sendable () throws -> any NativeRFDETRInferenceSource) async throws -> NativeRFDETRLayoutResult {
        try Task.checkCancellation()
        guard !busy, !purging else { throw NativeRFDETRLayoutError.busy }
        busy = true
        defer { busy = false; operation = nil }
        let revision = generation
        let maximumMasks = maximumMaskQueries
        let allQueryMasks = retainAllQueryMasks
        let direct: ModelHandle?
        if NativeRFRawCachePolicy.enabled { direct = nil } else {
            direct = try await model()
            guard revision == generation else { throw CancellationError() }
        }
        // All image decoding, identity hashing, resizing and synchronous CoreML
        // prediction are off MainActor. No unbounded queue of source tensors.
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let started = ProcessInfo.processInfo.systemUptime
            let image = try source()
            let identity = image.identity
            return (image, identity, (ProcessInfo.processInfo.systemUptime - started) * 1_000)
        }
        sourcePreparation = task
        defer { sourcePreparation = nil }
        let prepared = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        guard revision == generation else { throw CancellationError() }
        try Task.checkCancellation()
        if let result = cache[prepared.1] {
            lru.removeAll { $0 == prepared.1 }
            lru.append(prepared.1)
            return NativeRFDETRLayoutResult(imageIdentity: result.imageIdentity, sourceWidth: result.sourceWidth,
                sourceHeight: result.sourceHeight, primitives: result.primitives,
                maskQueriesOmittedByBudget: result.maskQueriesOmittedByBudget, preprocessingMilliseconds: prepared.2,
                modelMilliseconds: 0, decodeMilliseconds: 0, computeUnits: result.computeUnits, fromCache: true,
                classEvidence: result.classEvidence, semanticGrid: result.semanticGrid, sourceSupportGrid: result.sourceSupportGrid)
        }
        let inference: Task<NativeRFDETRLayoutResult, Error>
        if NativeRFRawCachePolicy.enabled {
            let asset = try await resource()
            guard revision == generation else { throw CancellationError() }
            let active = resident
            let weights = asset.weights, sourceRevision = asset.revision
            inference = Task.detached(priority: .userInitiated) {
                // A previously unseen URL/tree/metadata contract must pass actual
                // executable validation even if another URL supplied equal raw bytes.
                var verified = active
                if verified == nil, !ValidatedModels.shared.isValidated(asset) {
                    verified = try await ValidatedModels.shared.acquire(asset)
                }
                let current = verified
    #if targetEnvironment(simulator)
                let units = "cpuOnly"
    #else
                let units = "cpuAndGPU"
    #endif
                let key = NativeRFRawRequestCache.Key(sourceRGBIdentity: prepared.1,
                    installedModelTreeSHA256: asset.treeSHA256,
                    expectedWeightsSHA256: weights, sourceRevision: sourceRevision,
                    preprocessVersion: "rgb8-srgb-white-aa-triangle-halfpixel-imagenet-f32-v1",
                    tensorContractVersion: "rf648-input-f32-1x3x648x648-output300x4-300x5-300x162x162-v1",
                    computeUnits: units, runtimeVersion: ProcessInfo.processInfo.operatingSystemVersionString)
                NativeRFRawCacheDiagnostics.event(key, "consumerRequests", maximumMasks: maximumMasks, retainAll: allQueryMasks)
                let raw = try await NativeRFRawRequestCache.shared.raw(key: key) {
                    try Task.checkCancellation()
                    let handle: ModelHandle
                    if let current { handle = current } else { handle = try await ValidatedModels.shared.acquire(asset) }
                    await self.retain(handle, for: revision)
                    let start = ProcessInfo.processInfo.systemUptime
                    let input = try NativeRFDETRLayoutTensorContract.preprocess(prepared.0)
                    let preprocessMS = prepared.2 + (ProcessInfo.processInfo.systemUptime - start) * 1_000
                    let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
                    try Task.checkCancellation()
                    let predictionStart = ProcessInfo.processInfo.systemUptime
                    NativeRFRawCacheDiagnostics.event(key, "actualPredictionCalls")
                    let output = try handle.predict(provider)
                    let modelMS = (ProcessInfo.processInfo.systemUptime - predictionStart) * 1_000
                    try Task.checkCancellation()
                    return try NativeRFRawSnapshot(actualOutput: output,
                        preprocessingMilliseconds: preprocessMS, modelMilliseconds: modelMS,
                        weightsSHA256: weights, sourceIdentity: prepared.1)
                }
                try Task.checkCancellation()
                let result = try raw.snapshot.materialize(source: prepared.0,
                    maximumMaskQueries: maximumMasks, retainAllQueryMasks: allQueryMasks,
                    computeUnits: units, reused: raw.reused, sourcePreparationMilliseconds: prepared.2)
                NativeRFRawCacheDiagnostics.event(key, "decoderMaterializations")
                // A completed detector role traditionally keeps its model until
                // purge. Share an existing owner without loading a model on a hit.
                if raw.reused, let live = ValidatedModels.shared.live(asset) {
                    try Task.checkCancellation()
                    await self.retain(live, for: revision)
                }
                return result
            }
        } else {
            guard let handle = direct else { throw NativeRFDETRLayoutError.modelUnavailable }
            inference = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let start = ProcessInfo.processInfo.systemUptime
                let input = try NativeRFDETRLayoutTensorContract.preprocess(prepared.0)
                let preprocessMS = prepared.2 + (ProcessInfo.processInfo.systemUptime - start) * 1_000
                try Task.checkCancellation()
                let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
                let predictionStart = ProcessInfo.processInfo.systemUptime
                let output = try handle.model.prediction(from: provider)
                let modelMS = (ProcessInfo.processInfo.systemUptime - predictionStart) * 1_000
                try Task.checkCancellation()
                let decodeStart = ProcessInfo.processInfo.systemUptime
                let decoded = try NativeRFDETRLayoutTensorContract.decode(output, source: prepared.0,
                    maximumMaskQueries: maximumMasks, retainAllQueryMasks: allQueryMasks)
                var semanticGrid = decoded.semanticGrid
                let metadata = handle.model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
                semanticGrid?.modelWeightsSHA256 = metadata["weights_sha256"]
                try Task.checkCancellation()
    #if targetEnvironment(simulator)
                let units = "cpuOnly"
    #else
                let units = "cpuAndGPU"
    #endif
                return NativeRFDETRLayoutResult(imageIdentity: prepared.1, sourceWidth: prepared.0.width,
                    sourceHeight: prepared.0.height, primitives: decoded.primitives,
                    maskQueriesOmittedByBudget: decoded.omitted, preprocessingMilliseconds: preprocessMS,
                    modelMilliseconds: modelMS, decodeMilliseconds: (ProcessInfo.processInfo.systemUptime - decodeStart) * 1_000,
                    computeUnits: units, fromCache: false, classEvidence: decoded.classEvidence, semanticGrid: semanticGrid,
                    sourceSupportGrid: decoded.sourceSupportGrid)
            }
        }
        operation = inference
        let result = try await withTaskCancellationHandler(operation: { try await inference.value }, onCancel: { inference.cancel() })
        guard revision == generation else { throw CancellationError() }
        try Task.checkCancellation()
        if cacheByteLimit > 0, result.evidenceStorageBytes <= cacheByteLimit {
            cache[result.imageIdentity] = result
            lru.append(result.imageIdentity)
            while lru.count > 4 || cache.values.reduce(0, { $0 + $1.evidenceStorageBytes }) > cacheByteLimit {
                cache.removeValue(forKey: lru.removeFirst())
            }
        }
        return result
    }
}

/// Internal pure preprocessing/decoding seam for focused host contract tests.
enum NativeRFDETRLayoutTensorContract {
    static let mean: [Float] = [0.485, 0.456, 0.406]
    static let std: [Float] = [0.229, 0.224, 0.225]
    static let thresholds: [Float] = [0.25, 0.20, 0.50, 0.50]
    static let inputShape = [1, 3, 648, 648]
    static let outputShapes = ["boxes": [1, 300, 4], "logits": [1, 300, 5], "instance_masks": [1, 300, 162, 162]]

    static func validate(model: MLModel,
                         expectedWeightsSHA256: String = NativeRFDETRLayoutResource.sourceWeightsSHA256,
                         expectedSourceRevision: String = NativeRFDETRLayoutResource.sourceRevision) throws {
        guard let input = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint,
              input.dataType == .float32, input.shape.map(\.intValue) == inputShape else {
            throw NativeRFDETRLayoutError.unsupportedModelContract("image must be fixed float32 NCHW1x3x648x648")
        }
        for (name, shape) in outputShapes {
            guard let output = model.modelDescription.outputDescriptionsByName[name]?.multiArrayConstraint,
                  output.dataType == .float32, output.shape.map(\.intValue) == shape else {
                throw NativeRFDETRLayoutError.unsupportedModelContract(name)
            }
        }
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        guard metadata?["weights_sha256"] == expectedWeightsSHA256,
              metadata?["source_revision"] == expectedSourceRevision,
              metadata?["fixed_resolution"] == "648" else {
            throw NativeRFDETRLayoutError.unsupportedModelContract("pinned RF648 resource metadata")
        }
    }

    private struct Filter { let first: Int; let weights: [Float] }

    /// PyTorch CPU bilinear antialias separable triangle filter: half-pixel
    /// centers, widened support when reducing, truncated/renormalized edges.
    /// CG interpolationQuality/vImage approximate resizing is not substituted.
    private static func filters(source: Int, target: Int) -> [Filter] {
        let scale = Float(source) / Float(target)
        let support = max(scale, 1), inverse = 1 / support
        return (0..<target).map { i in
            let center = scale * (Float(i) + 0.5)
            let first = max(0, Int(center - support + 0.5))
            let end = min(source, Int(center + support + 0.5))
            var weights = (first..<end).map { j in max(0, 1 - abs((Float(j) + 0.5 - center) * inverse)) }
            let sum = weights.reduce(Float(0), +)
            for j in weights.indices { weights[j] /= sum }
            return Filter(first: first, weights: weights)
        }
    }

    // All bands read immutable RGB/filter data. concurrentPerform joins before
    // the pointers expire, and each band writes disjoint rows of all three planes.
    private struct ResizeKernel: @unchecked Sendable {
        let source: UnsafePointer<UInt8>
        let output: UnsafeMutablePointer<Float>
        let sourceWidth: Int
        let horizontal: [Filter]
        let vertical: [Filter]

        func write(rows outputRows: Range<Int>) {
            let side = NativeRFDETRLayoutResource.inputSide
            var rows: [Int: [Float]] = [:]
            var normalized = [Float](repeating: 0, count: sourceWidth * 3)
            for y in outputRows {
                let filter = vertical[y]
                let required = filter.first..<(filter.first + filter.weights.count)
                rows = rows.filter { required.contains($0.key) }
                for row in required where rows[row] == nil {
                    var resized = [Float](repeating: 0, count: side * 3)
                    normalized.withUnsafeMutableBufferPointer { buffer in
                        let values = buffer.baseAddress!
                        let rowBytes = source + row * sourceWidth * 3
                        for i in 0..<buffer.count { values[i] = Float(rowBytes[i]) / 255 }
                        for x in 0..<side {
                            let filter = horizontal[x]
                            let first = values + filter.first * 3
                            var red: Float = 0, green: Float = 0, blue: Float = 0
                            for (j, weight) in filter.weights.enumerated() {
                                red += first[j * 3] * weight
                                green += first[j * 3 + 1] * weight
                                blue += first[j * 3 + 2] * weight
                            }
                            resized[x] = red
                            resized[side + x] = green
                            resized[2 * side + x] = blue
                        }
                    }
                    rows[row] = resized
                }
                for channel in 0..<3 {
                    let channelOffset = channel * side
                    let target = output + channel * side * side + y * side
                    for x in 0..<side { target[x] = 0 }
                    // Preserve the summation order while hoisting the row lookup.
                    for j in filter.weights.indices {
                        let weight = filter.weights[j]
                        rows[filter.first + j]!.withUnsafeBufferPointer { row in
                            let pixels = row.baseAddress! + channelOffset
                            for x in 0..<side { target[x] += pixels[x] * weight }
                        }
                    }
                    for x in 0..<side { target[x] = (target[x] - mean[channel]) / std[channel] }
                }
            }
        }
    }

    static func preprocess(_ source: any NativeRFDETRInferenceSource) throws -> MLMultiArray {
        let side = NativeRFDETRLayoutResource.inputSide
        let result = try MLMultiArray(shape: inputShape.map { NSNumber(value: $0) }, dataType: .float32)
        let output = result.dataPointer.assumingMemoryBound(to: Float.self)
        let horizontal = filters(source: source.width, target: side)
        let vertical = filters(source: source.height, target: side)
        try source.withPackedRGB { rgb in
            let kernel = ResizeKernel(source: rgb.bindMemory(to: UInt8.self).baseAddress!, output: output,
                sourceWidth: source.width, horizontal: horizontal, vertical: vertical)
            // Three bands bound simultaneous scratch storage. Check the owning
            // task between passes because Dispatch workers do not inherit it.
            let rowsPerBand = 54, bandsPerPass = 3
            for first in stride(from: 0, to: side, by: rowsPerBand * bandsPerPass) {
                try Task.checkCancellation()
                let bands = min(bandsPerPass, (side - first + rowsPerBand - 1) / rowsPerBand)
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let start = first + band * rowsPerBand
                    kernel.write(rows: start..<min(start + rowsPerBand, side))
                }
            }
            try Task.checkCancellation()
        }
        return result
    }

    static func decode(_ provider: MLFeatureProvider, source: any NativeRFDETRInferenceSource,
                       maximumMaskQueries: Int, retainAllQueryMasks: Bool = false,
                       snapshotSupportGrid: NativeRFDETRSourceSupportGrid? = nil,
                       borrowSnapshotWeakMasks: Bool = false) throws
        -> (primitives: [NativeRFDETRLayoutPrimitive], omitted: Int, classEvidence: [NativeRFDETRClassEvidence],
            semanticGrid: NativeRFDETRSemanticGrid?, sourceSupportGrid: NativeRFDETRSourceSupportGrid) {
        var arrays: [String: MLMultiArray] = [:]
        for (name, shape) in outputShapes {
            guard let array = provider.featureValue(for: name)?.multiArrayValue,
                  array.dataType == .float32, array.shape.map(\.intValue) == shape,
                  array.strides.allSatisfy({ $0.intValue > 0 }) else {
                throw NativeRFDETRLayoutError.unsupportedModelContract(name)
            }
            arrays[name] = array
        }
        let boxes = arrays["boxes"]!, logits = arrays["logits"]!, masks = arrays["instance_masks"]!
        let boxData = boxes.dataPointer.assumingMemoryBound(to: Float.self)
        let logitData = logits.dataPointer.assumingMemoryBound(to: Float.self)
        let maskData = masks.dataPointer.assumingMemoryBound(to: Float.self)
        let boxStride = boxes.strides.map(\.intValue), logitStride = logits.strides.map(\.intValue), maskStride = masks.strides.map(\.intValue)
        var scores: [(flat: Int, confidence: Float)] = []
        let minimumThreshold = thresholds.min() ?? 0
        for q in 0..<300 {
            for c in 0..<5 {
                let value = logitData[q * logitStride[1] + c * logitStride[2]]
                guard value.isFinite else { throw NativeRFDETRLayoutError.nonfiniteOutput }
                let confidence = value >= 0 ? 1 / (1 + exp(-value)) : exp(value) / (1 + exp(value))
                // A score below every class floor can't affect any admitted rank.
                // Higher scores still compete globally, including unmapped classes.
                if confidence >= minimumThreshold {
                    scores.append((q * 5 + c, confidence))
                }
            }
        }
        scores.sort { $0.confidence == $1.confidence ? $0.flat < $1.flat : $0.confidence > $1.confidence }
        func loadMask(_ query: Int) throws -> NativeRFDETRLayoutMask {
            let plane = maskData + query * maskStride[1]
            let cells = 162 * 162
            let values = try [Float](unsafeUninitializedCapacity: cells) { buffer, initialized in
                let target = buffer.baseAddress!, rowStride = maskStride[2], pixelStride = maskStride[3]
                if rowStride == 162, pixelStride == 1 {
                    try copyFinite(from: plane, to: target, count: cells)
                    initialized = cells
                    return
                }
                for y in 0..<162 {
                    let row = plane + y * rowStride
                    if pixelStride == 1 {
                        try copyFinite(from: row, to: target + initialized, count: 162)
                        initialized += 162
                    } else {
                        for x in 0..<162 {
                            let value = row[x * pixelStride]
                            guard value.isFinite else { throw NativeRFDETRLayoutError.nonfiniteOutput }
                            (target + initialized).initialize(to: value)
                            initialized += 1
                        }
                    }
                }
            }
            return NativeRFDETRLayoutMask(queryID: query, sourceWidth: source.width,
                sourceHeight: source.height, logits: values)
        }
        var primitives: [NativeRFDETRLayoutPrimitive] = []
        var retained: [Int: NativeRFDETRLayoutMask] = [:]
        var omitted = Set<Int>()
        let cap = min(160, max(0, maximumMaskQueries))
        // Preserve balloon/frame availability for explicitly smaller budgets,
        // then admit text/SFX. The default covers every selected query.
        let selected = scores.prefix(160).filter {
            let c = $0.flat % 5
            return c < thresholds.count && $0.confidence >= thresholds[c]
        }
        let priority = selected.filter { $0.flat % 5 >= 2 } + selected.filter { $0.flat % 5 < 2 }
        var maskQueries = Set<Int>()
        for candidate in priority where maskQueries.count < cap { maskQueries.insert(candidate.flat / 5) }
        for candidate in selected {
            try Task.checkCancellation()
            let q = candidate.flat / 5, c = candidate.flat % 5
            guard let semanticClass = NativeRFDETRLayoutClass(rawValue: c), candidate.confidence >= thresholds[c] else { continue }
            let values = (0..<4).map { boxData[q * boxStride[1] + $0 * boxStride[2]] }
            guard values.allSatisfy(\.isFinite), values[2] >= 0, values[3] >= 0 else { throw NativeRFDETRLayoutError.nonfiniteOutput }
            let normalized = CGRect(x: Double(values[0] - values[2] / 2), y: Double(values[1] - values[3] / 2),
                                    width: Double(values[2]), height: Double(values[3]))
            let bounds = CGRect(x: normalized.minX * CGFloat(source.width), y: normalized.minY * CGFloat(source.height),
                                width: normalized.width * CGFloat(source.width), height: normalized.height * CGFloat(source.height))
            var mask: NativeRFDETRLayoutMask?
            do {
                if let existing = retained[q] { mask = existing } else if maskQueries.contains(q) {
                    let selectedMask = try loadMask(q)
                    retained[q] = selectedMask
                    mask = selectedMask
                } else { omitted.insert(q) }
            }
            primitives.append(NativeRFDETRLayoutPrimitive(queryID: q, semanticClass: semanticClass,
                confidence: candidate.confidence, normalizedBounds: normalized, sourceBounds: bounds, mask: mask))
        }
        var hypotheses: [NativeRFDETRClassEvidence] = []
        for q in 0..<300 {
            // Segmentation may consume weak, unaccepted queries as auxiliary
            // evidence without changing any accepted layout primitive. Retain
            // all raw masks only for an explicit accuracy-focused consumer.
            if retainAllQueryMasks, retained[q] == nil {
                try Task.checkCancellation()
                if !borrowSnapshotWeakMasks { retained[q] = try loadMask(q) }
            }
            let values = (0..<4).map { boxData[q * boxStride[1] + $0 * boxStride[2]] }
            guard values.allSatisfy(\.isFinite), values[2] >= 0, values[3] >= 0 else { throw NativeRFDETRLayoutError.nonfiniteOutput }
            let raw = (0..<5).map { logitData[q * logitStride[1] + $0 * logitStride[2]] }
            let probabilities = raw.map { value in value >= 0 ? 1 / (1 + exp(-value)) : exp(value) / (1 + exp(value)) }
            let normalized = CGRect(x: Double(values[0] - values[2] / 2), y: Double(values[1] - values[3] / 2),
                width: Double(values[2]), height: Double(values[3]))
            let bounds = CGRect(x: normalized.minX * CGFloat(source.width), y: normalized.minY * CGFloat(source.height),
                width: normalized.width * CGFloat(source.width), height: normalized.height * CGFloat(source.height))
            hypotheses.append(.init(queryID: q, logits: raw, probabilities: probabilities,
                normalizedBounds: normalized, sourceBounds: bounds, mask: retained[q]))
        }
        // Aggregate the actual ALL300 output once. Thresholded layout masks
        // cannot reconstruct the source165 ABI or the raw geometry RF means.
        let support = try snapshotSupportGrid ?? NativeRFDETRSourceSupportGrid.aggregate(
            boxes: (0..<300).flatMap { q in (0..<4).map { boxData[q * boxStride[1] + $0 * boxStride[2]] } },
            logits: (0..<300).flatMap { q in (0..<5).map { logitData[q * logitStride[1] + $0 * logitStride[2]] } },
            maskData: UnsafePointer(maskData), queryStride: maskStride[1], rowStride: maskStride[2], pixelStride: maskStride[3]
        )
        let cells = 162 * 162
        // Each public semantic plane is copied straight to its final contiguous
        // storage. Native17 orders the three fields for each class together.
        func semanticPlanes(field: Int) -> [Float] {
            support.native17Fields.withUnsafeBufferPointer { native in
                [Float](unsafeUninitializedCapacity: 4 * cells) { output, initialized in
                    for semantic in 0..<4 {
                        let plane = native.baseAddress! + (semantic * 3 + field) * cells
                        (output.baseAddress! + initialized).initialize(from: plane, count: cells)
                        initialized += cells
                    }
                }
            }
        }
        let semanticGrid = NativeRFDETRSemanticGrid(width: source.width, height: source.height, side: 162,
            probabilities: semanticPlanes(field: 0), imageIdentity: source.identity, weightedMeanProbabilities: semanticPlanes(field: 1))
        return (primitives, omitted.count, hypotheses, semanticGrid, support)
    }
    /// Validate exponent bits while copying the original words, including signed zeros.
    static func copyFinite(from: UnsafePointer<Float>, to: UnsafeMutablePointer<Float>, count: Int) throws {
        let source = UnsafeRawPointer(from), destination = UnsafeMutableRawPointer(to)
        let exponent = SIMD4<UInt32>(repeating: 0x7F80_0000)
        var index = 0
        while index + 4 <= count {
            let offset = index * MemoryLayout<Float>.stride
            let words = source.loadUnaligned(fromByteOffset: offset, as: SIMD4<UInt32>.self)
            guard !any((words & exponent) .== exponent) else { throw NativeRFDETRLayoutError.nonfiniteOutput }
            memcpy(destination + offset, source + offset, MemoryLayout<SIMD4<UInt32>>.size)
            index += 4
        }
        for i in index..<count {
            let value = from[i]
            guard value.isFinite else { throw NativeRFDETRLayoutError.nonfiniteOutput }
            to[i] = value
        }
    }
}
