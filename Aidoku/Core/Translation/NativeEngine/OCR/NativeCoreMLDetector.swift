import CoreGraphics
@preconcurrency import CoreML
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLDetectionBox: Equatable, Sendable {
    let polygon: [CGPoint]
    let score: Double
}

@available(iOS 18.0, *)
enum NativeCoreMLDetectorError: Error, Equatable, LocalizedError {
    case modelResourceMissing
    case modelLoadFailed(String)
    case imageConversionFailed
    case modelInputCreationFailed
    case modelOutputMissing
    case modelOutputShape(expected: [Int], actual: [Int])
    case unsupportedModelOutputType
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelResourceMissing: NSLocalizedString("OCR_ERROR_MODEL_MISSING")
        case .modelLoadFailed: NSLocalizedString("OCR_ERROR_MODEL_LOAD")
        case .imageConversionFailed, .modelInputCreationFailed: NSLocalizedString("OCR_ERROR_IMAGE")
        case .modelOutputMissing, .modelOutputShape, .unsupportedModelOutputType: NSLocalizedString("OCR_ERROR_OUTPUT")
        case .predictionFailed: NSLocalizedString("OCR_ERROR_PREDICTION")
        }
    }
}

/// Loads the model once; a failed load is retried by the next prediction.
@available(iOS 18.0, *)
private actor NativeCoreMLDetectorModelPredictor {
    private struct ModelHandle: @unchecked Sendable {
        let model: MLModel
    }

    private let asset: MLModelAsset
    private var load: Task<ModelHandle, Error>?

    init(modelURL: URL) throws {
        asset = try MLModelAsset(url: try NativeCoreMLModelStore.shared.modelURL(for: modelURL))
    }

    func predict(array: MLMultiArray) async throws -> MLMultiArray {
        if load == nil {
            let asset = self.asset
            load = Task {
                // The stem max-pool pads with 0 (not -inf, which the CPU backend turned into nonfinite
                // cells), so devices run the graph on CPU: about 4x faster than GPU. The Mac host and the
                // simulator stay on CPU and GPU, which keeps replay output byte-identical.
                let configuration = MLModelConfiguration()
                #if os(iOS) && !targetEnvironment(simulator)
                configuration.computeUnits = .cpuOnly
                #else
                configuration.computeUnits = .cpuAndGPU
                #endif
                configuration.modelDisplayName = "PP-OCRv6 Dynamic"
                configuration.optimizationHints.reshapeFrequency = .frequent
                configuration.optimizationHints.specializationStrategy = .fastPrediction
                return ModelHandle(model: try await MLModel.load(asset: asset, configuration: configuration))
            }
        }
        let model: MLModel
        let pending = load!
        do {
            model = try await pending.value.model
        } catch {
            // A late waiter must not discard a retry another caller already started.
            if load == pending { load = nil }
            throw error
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: array)])
        let prediction = try await model.prediction(from: provider)
        guard let output = prediction.featureValue(for: "fetch_name_0")?.multiArrayValue else {
            throw NativeCoreMLDetectorError.modelOutputMissing
        }
        return output
    }
}

/// PP-OCRv6 Manga text detection using one bounded dynamic-spatial Core ML model.
/// A newer request cancels one still in flight on the same instance.
@available(iOS 18.0, *)
final class NativeCoreMLDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let resourceLock = NSLock()
    private let bundle: Bundle
    private var predictor: NativeCoreMLDetectorModelPredictor?

    init(bundle: Bundle = .main) { self.bundle = bundle }

    /// DB-decoded boxes (polygon and score) for one page.
    func detectGeometry(
        image: CGImage,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga
    ) async throws -> [NativeCoreMLDetectionBox] {
        try await detect(providedFrame: nil, image: image, configuration: configuration)
    }

    /// Geometry-only detection from caller-owned pixels (V2 shares one frame with recognition).
    func detectGeometry(
        frame: NativeOCRRGBAFrame,
        configuration: NativeCoreMLDBPostprocessConfiguration = .manga
    ) async throws -> [NativeCoreMLDetectionBox] {
        try await detect(providedFrame: frame, image: nil, configuration: configuration)
    }

    private func detect(
        providedFrame: NativeOCRRGBAFrame?,
        image: CGImage?,
        configuration: NativeCoreMLDBPostprocessConfiguration
    ) async throws -> [NativeCoreMLDetectionBox] {
        let issued = lock.withLock {
            generation &+= 1
            return generation
        }
        let check: @Sendable () throws -> Void = { [self] in
            try Task.checkCancellation()
            guard lock.withLock({ generation == issued }) else { throw CancellationError() }
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
            let prepared = try await NativeCoreMLDetectionPreprocessor.prepareArray(frame: frame, cancellationCheck: check)
            try check()
            // A first call hashes and publishes the model copy under `resourceLock`; keep that blocking
            // work off the cooperative pool so concurrent pages cannot starve it.
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
                height: prepared.resizedHeight, expectedShape: [1, 1] + prepared.input.shape.suffix(2).map(\.intValue))
            try check()
            let boxes = try NativeCoreMLDBPostprocessor.decode(
                map: map, sourceWidth: frame.width, sourceHeight: frame.height,
                configuration: configuration, cancellationCheck: check)
            try check()
            return boxes
        } onCancel: { [self] in
            lock.withLock { if generation == issued { generation &+= 1 } }
        }
    }

    private func loadPredictor(cancellationCheck: () throws -> Void) throws -> NativeCoreMLDetectorModelPredictor {
        resourceLock.lock()
        defer { resourceLock.unlock() }
        try cancellationCheck()
        if let predictor { return predictor }
        guard let modelURL = bundle.url(forResource: "PP-OCRv6-Manga-DetShapes", withExtension: "mlmodelc") else {
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
    private static let channelMean: [Float] = [0.485, 0.456, 0.406]
    private static let channelStandardDeviation: [Float] = [0.229, 0.224, 0.225]

    /// The stride-aligned model canvas, at most `IPhoneOCRSettings.defaultDetectorMaximumSide`.
    static func resizeDimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int)? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let alignedMaximumSide = max(32, min(2_000, IPhoneOCRSettings.defaultDetectorMaximumSide) / 32 * 32)
        let sourceMaximumSide = max(sourceWidth, sourceHeight)
        let scale = sourceMaximumSide > alignedMaximumSide
            ? Double(alignedMaximumSide) / Double(sourceMaximumSide)
            : 1
        // Always pad upward to the detector stride. Rounding down would throw
        // away source detail solely to satisfy the model shape contract.
        let width = max(32, Int(ceil(Double(sourceWidth) * scale / 32)) * 32)
        let height = max(32, Int(ceil(Double(sourceHeight) * scale / 32)) * 32)
        return (min(alignedMaximumSide, width), min(alignedMaximumSide, height))
    }

    static func prepareArray(
        frame: NativeOCRRGBAFrame,
        cancellationCheck: () throws -> Void = {}
    ) async throws -> NativeCoreMLDetectionPreparedArray {
        try cancellationCheck()
        guard let canvas = resizeDimensions(sourceWidth: frame.width, sourceHeight: frame.height) else {
            throw NativeCoreMLDetectorError.modelInputCreationFailed
        }
        // Source content is separate from the stride-aligned canvas: an axis
        // must never gain source samples just to reach the model stride.
        let width = min(frame.width, canvas.width), height = min(frame.height, canvas.height)
        let sourceXs = await resizeCoordinates(sourceLength: frame.width, targetLength: width,
                                               resizesOtherAxis: frame.height != height)
        try cancellationCheck()
        try Task.checkCancellation()
        let sourceYs = await resizeCoordinates(sourceLength: frame.height, targetLength: height, vertical: true,
                                               resizesOtherAxis: frame.width != width)
        try cancellationCheck()
        try Task.checkCancellation()
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: [1, 3, canvas.height, canvas.width].map { NSNumber(value: $0) }, dataType: .float32)
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
                width: width, height: height,
                sourceXs: sourceXs, sourceYs: sourceYs, into: base, cancellationCheck: cancellationCheck
            )
        }
        return NativeCoreMLDetectionPreparedArray(input: array, resizedWidth: width, resizedHeight: height)
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
        else { throw NativeCoreMLDetectorError.modelInputCreationFailed }
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
        let deviation0 = channelStandardDeviation[0], deviation1 = channelStandardDeviation[1]
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
                                @inline(__always) func pixel(_ byte: Int) -> Float {
                                    let a = Float(top[x0 + byte])
                                    let b = Float(top[x1 + byte])
                                    let c = Float(bottom[x0 + byte])
                                    let d = Float(bottom[x1 + byte])
                                    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                                }
                                // Detector uses BGR: channel c reads RGBA byte 2 - c.
                                blue[x] = (pixel(2) / 255 - mean0) / deviation0
                                green[x] = (pixel(1) / 255 - mean1) / deviation1
                                red[x] = (pixel(0) / 255 - mean2) / deviation2
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

    /// Consecutive pages usually share sizes; the ramps are a pure function of
    /// the key, so a tiny LRU replays them instead of building tensor graphs.
    private static let resizeCoordinateCacheCapacity = 8
    private static let resizeCoordinateCache = ResizeCoordinateCache()

    private final class ResizeCoordinateCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: ResizeCoordinateKey, value: [(Int, Int, Float)])] = []

        func value(for key: ResizeCoordinateKey) -> [(Int, Int, Float)]? {
            lock.lock(); defer { lock.unlock() }
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.value
        }

        func store(_ value: [(Int, Int, Float)], for key: ResizeCoordinateKey, capacity: Int) {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.key == key }
            entries.append((key, value))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
    }

    /// One-dimensional ramps resized by `MLTensor` reproduce its exact bilinear
    /// coordinates. Core ML picks different kernels when one or both axes
    /// resize, so the orthogonal axis grows from 2 to 3 to match. A parity ramp
    /// carries the fractional weight separately (subtracting the integer part
    /// of a large coordinate loses Float ULPs).
    private static func resizeCoordinates(
        sourceLength: Int, targetLength: Int, vertical: Bool = false, resizesOtherAxis: Bool = false
    ) async -> [(Int, Int, Float)] {
        let key = ResizeCoordinateKey(sourceLength: sourceLength, targetLength: targetLength,
                                      vertical: vertical, resizesOtherAxis: resizesOtherAxis)
        if let cached = resizeCoordinateCache.value(for: key) { return cached }
        let computed = await computeResizeCoordinates(
            sourceLength: sourceLength, targetLength: targetLength, vertical: vertical, resizesOtherAxis: resizesOtherAxis)
        resizeCoordinateCache.store(computed, for: key, capacity: resizeCoordinateCacheCapacity)
        return computed
    }

    private static func computeResizeCoordinates(
        sourceLength: Int, targetLength: Int, vertical: Bool, resizesOtherAxis: Bool
    ) async -> [(Int, Int, Float)] {
        if sourceLength == targetLength { return (0..<targetLength).map { ($0, $0, 0) } }
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
        output: MLMultiArray, width: Int, height: Int, expectedShape: [Int]
    ) throws -> NativeCoreMLDetectionMap {
        let actualShape = output.shape.map(\.intValue)
        guard actualShape == expectedShape, output.strides.count == 4, width > 0, height > 0,
              width <= expectedShape[3], height <= expectedShape[2] else {
            throw NativeCoreMLDetectorError.modelOutputShape(expected: expectedShape, actual: actualShape)
        }
        let rowStride = output.strides[2].intValue
        let columnStride = output.strides[3].intValue
        func map<Element: BinaryFloatingPoint>(_ type: Element.Type) -> NativeCoreMLDetectionMap {
            // withUnsafeBytes locks a pixel-buffer-backed output; dataPointer does not.
            output.withUnsafeBytes { bytes in
                makeMap(pointer: bytes.baseAddress!.assumingMemoryBound(to: type),
                        width: width, height: height, rowStride: rowStride, columnStride: columnStride)
            }
        }
        switch output.dataType {
        case .float32: return map(Float.self)
        case .float16: return map(Float16.self)
        case .double: return map(Double.self)
        default: throw NativeCoreMLDetectorError.unsupportedModelOutputType
        }
    }

    private static func makeMap<Element: BinaryFloatingPoint>(
        pointer: UnsafePointer<Element>, width: Int, height: Int, rowStride: Int, columnStride: Int
    ) -> NativeCoreMLDetectionMap {
        let count = width * height
        let values = [Float](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            guard let destination = buffer.baseAddress else { return }
            if Element.self == Float.self, columnStride == 1 {
                // Same Float values, copied a row (or the whole map) at once.
                let source = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
                if rowStride == width {
                    destination.initialize(from: source, count: count)
                } else {
                    for row in 0..<height {
                        (destination + row * width).initialize(from: source + row * rowStride, count: width)
                    }
                }
            } else {
                for row in 0..<height {
                    let sourceRow = pointer + row * rowStride
                    let destinationRow = destination + row * width
                    for column in 0..<width {
                        destinationRow[column] = Float(sourceRow[column * columnStride])
                    }
                }
            }
            initializedCount = count
        }
        return NativeCoreMLDetectionMap(width: width, height: height, values: values)
    }
}
