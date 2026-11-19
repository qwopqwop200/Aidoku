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
private final class NativeCoreMLDetectorModelPredictor: Sendable {
    /// Loads the model once; a failed load is retried by the next prediction.
    private actor ModelStore {
        private let asset: MLModelAsset
        private var load: Task<ModelHandle, Error>?

        init(asset: MLModelAsset) {
            self.asset = asset
        }

        func model() async throws -> MLModel {
            if load == nil {
                let asset = self.asset
                load = Task {
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = .cpuAndGPU
                    configuration.modelDisplayName = "PP-OCRv6 Dynamic"
                    configuration.optimizationHints.reshapeFrequency = .frequent
                    configuration.optimizationHints.specializationStrategy = .fastPrediction
                    return ModelHandle(model: try await MLModel.load(asset: asset, configuration: configuration))
                }
            }
            do {
                return try await load!.value.model
            } catch {
                load = nil
                throw error
            }
        }
    }

    private struct ModelHandle: @unchecked Sendable {
        let model: MLModel
    }

    private let modelStore: ModelStore

    init(modelURL: URL) throws {
        let published = try NativeCoreMLModelStore.shared.modelURL(for: modelURL)
        // Both the device and the simulator run the Manga graph on CPU and GPU: its
        // dynamic padding produces nonfinite source cells on the simulator CPU backend.
        modelStore = ModelStore(asset: try MLModelAsset(url: published))
    }

    /// Feature-provider prediction of one planar input canvas.
    func predict(array: MLMultiArray) async throws -> MLMultiArray {
        let model = try await modelStore.model()
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            NativeCoreMLDetector.inputFeatureName: MLFeatureValue(multiArray: array),
        ])
        let prediction = try await model.prediction(from: provider)
        guard let output = prediction.featureValue(for: NativeCoreMLDetector.outputFeatureName)?.multiArrayValue else {
            throw NativeCoreMLDetectorError.modelOutputMissing
        }
        return output
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

/// PP-OCRv6 Manga text detection using one bounded dynamic-spatial Core ML model.
/// A newer request cancels one still in flight on the same instance.
@available(iOS 18.0, *)
final class NativeCoreMLDetector: @unchecked Sendable {
    static let modelResourceName = "PP-OCRv6-Manga-DetShapes"
    static let inputFeatureName = "x"
    static let outputFeatureName = "fetch_name_0"

    private let generation = NativeCoreMLDetectionGeneration()
    private let resourceLock = NSLock()
    private let bundle: Bundle
    private var predictor: NativeCoreMLDetectorModelPredictor?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// DB-decoded boxes (polygon and score) for one page.
    func detectGeometry(
        image: CGImage,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga
    ) async throws -> [NativeCoreMLDetectionBox] {
        try await performGeometryDetection(providedFrame: nil, image: image, configuration: configuration)
    }

    /// Geometry-only detection from caller-owned pixels (V2 shares one frame with recognition).
    func detectGeometry(
        frame: NativeOCRRGBAFrame,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga
    ) async throws -> [NativeCoreMLDetectionBox] {
        try await performGeometryDetection(providedFrame: frame, image: nil, configuration: configuration)
    }

    /// Full-frame detection: multiarray input, feature-provider prediction,
    /// direct output read and one DB decode.
    private func performGeometryDetection(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        configuration: NativeCoreMLDBPostprocessConfiguration
    ) async throws -> [NativeCoreMLDetectionBox] {
        let issuedGeneration = generation.begin()
        let check: @Sendable () throws -> Void = { [self] in
            try Task.checkCancellation()
            guard generation.isCurrent(issuedGeneration) else { throw CancellationError() }
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
            guard let canvas = NativeCoreMLDetectionCanvas.exact(sourceWidth: frame.width, sourceHeight: frame.height) else {
                let resized = NativeCoreMLDetectionPreprocessor.resizeDimensions(
                    sourceWidth: frame.width, sourceHeight: frame.height) ?? (0, 0)
                throw NativeCoreMLDetectorError.unsupportedInputShape(
                    sourceWidth: frame.width, sourceHeight: frame.height,
                    resizedWidth: resized.width, resizedHeight: resized.height)
            }
            let prepared = try await NativeCoreMLDetectionPreprocessor.prepareArray(
                frame: frame, canvas: canvas, cancellationCheck: check)
            try check()
            // A first call loads the model under `resourceLock`; keep that blocking load off the
            // cooperative pool so concurrent pages cannot starve it.
            let predictor = try await Task.detached(priority: .userInitiated) { [self] in
                try loadPredictor(cancellationCheck: check)
            }.value
            try check()
            let output: MLMultiArray
            do {
                output = try await predictor.predict(array: prepared.input)
            } catch let error as CancellationError {
                throw error
            } catch let error as NativeCoreMLDetectorError {
                throw error
            } catch {
                throw NativeCoreMLDetectorError.predictionFailed(String(describing: error))
            }
            try check()
            let map = try NativeCoreMLDetectionOutput.makeMap(
                output: output, width: prepared.resizedWidth,
                height: prepared.resizedHeight, expectedShape: canvas.outputShape)
            try check()
            let boxes = try NativeCoreMLDBPostprocessor.decode(
                map: map, sourceWidth: frame.width, sourceHeight: frame.height,
                configuration: configuration, cancellationCheck: check
            )
            try check()
            return boxes
        } onCancel: { [generation] in
            generation.cancel(ifCurrent: issuedGeneration)
        }
    }

    private func loadPredictor(
        cancellationCheck: () throws -> Void
    ) throws -> NativeCoreMLDetectorModelPredictor {
        resourceLock.lock()
        defer { resourceLock.unlock() }
        try cancellationCheck()
        if let predictor { return predictor }
        guard let modelURL = Self.findModelURL(in: bundle, resourceName: Self.modelResourceName) else {
            throw NativeCoreMLDetectorError.modelResourceMissing
        }
        let loaded: NativeCoreMLDetectorModelPredictor
        do {
            loaded = try NativeCoreMLDetectorModelPredictor(modelURL: modelURL)
        } catch {
            throw NativeCoreMLDetectorError.modelLoadFailed(String(describing: error))
        }
        try cancellationCheck()
        predictor = loaded
        return loaded
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
}

/// The planar detector input canvas, written straight into a Core ML multiarray.
@available(iOS 18.0, *)
struct NativeCoreMLDetectionPreparedArray: @unchecked Sendable {
    let input: MLMultiArray
    let resizedWidth: Int
    let resizedHeight: Int
}

@available(iOS 18.0, *)
enum NativeCoreMLDetectionPreprocessor {
    static let modelMaximumSide = 2_000
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

    /// Separate source content from the stride-aligned model canvas: an axis
    /// must never gain source samples just to reach the model stride.
    static func contentDimensions(
        sourceWidth: Int, sourceHeight: Int,
        maximumSide: Int = IPhoneOCRSettings.defaultDetectorMaximumSide
    ) -> (width: Int, height: Int)? {
        guard let aligned = resizeDimensions(sourceWidth: sourceWidth,
            sourceHeight: sourceHeight, maximumSide: maximumSide) else { return nil }
        return (min(sourceWidth, aligned.width), min(sourceHeight, aligned.height))
    }

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
            input: array, resizedWidth: dimensions.width, resizedHeight: dimensions.height
        )
    }

    /// Rows submitted to one `concurrentPerform` pass. Cancellation is observed
    /// on the calling task between passes (GCD workers have no current Task).
    private static let boundedRowsPerPass = 256
    /// Rows written by one concurrent iteration. Every iteration owns a
    /// disjoint row range in all three planes, so writes never overlap.
    private static let boundedRowsPerBand = 16

    /// Bilinear resize + BGR normalization of the planar canvas
    /// (`3 * canvasWidth * canvasHeight` Floats) into caller-owned contiguous
    /// storage. Rows are only distributed across cores, so the result is
    /// bit-identical to a scalar loop. Only padding is zeroed: content cells
    /// are all written by the row bands.
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

    private static func computeResizeCoordinates(
        sourceLength: Int, targetLength: Int, vertical: Bool, resizesOtherAxis: Bool
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
}

@available(iOS 18.0, *)
enum NativeCoreMLDetectionOutput {
    /// The top-left `width` x `height` window of the model's probability output.
    static func makeMap(
        output: MLMultiArray,
        width: Int,
        height: Int,
        expectedShape: [Int]
    ) throws -> NativeCoreMLDetectionMap {
        let actualShape = output.shape.map(\.intValue)
        guard actualShape == expectedShape,
              output.strides.count == 4,
              width > 0,
              height > 0,
              width <= expectedShape[3],
              height <= expectedShape[2]
        else {
            throw NativeCoreMLDetectorError.modelOutputShape(
                expected: expectedShape,
                actual: actualShape
            )
        }
        let rowStride = output.strides[2].intValue
        let columnStride = output.strides[3].intValue
        switch output.dataType {
        case .float32:
            return makeMap(
                pointer: output.dataPointer.assumingMemoryBound(to: Float.self),
                width: width, height: height, rowStride: rowStride, columnStride: columnStride
            )
        case .float16:
            return makeMap(
                pointer: output.dataPointer.assumingMemoryBound(to: Float16.self),
                width: width, height: height, rowStride: rowStride, columnStride: columnStride
            )
        case .double:
            return makeMap(
                pointer: output.dataPointer.assumingMemoryBound(to: Double.self),
                width: width, height: height, rowStride: rowStride, columnStride: columnStride
            )
        default:
            throw NativeCoreMLDetectorError.unsupportedModelOutputType
        }
    }

    private static func makeMap<Element: BinaryFloatingPoint>(
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
