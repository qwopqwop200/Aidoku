import CoreML
import Foundation
import XCTest
@testable import Aidoku

/// Bit-identity guards for the parallel detector preprocessing, output-map
/// copies and DB threshold mask. Each test keeps the historical scalar
/// implementation as the reference and compares IEEE bit patterns.
@available(iOS 18.0, *)
final class NativeOCRDetectionIdentityTests: XCTestCase {
    func testRGBAConversionPreservesTransparentColorSpaceAndPaddedImages() throws {
        // Poisoning the reference destination additionally proves that the
        // full .copy draw overwrites every byte, including alpha-zero pixels.
        for size in [(1, 1), (7, 13), (32, 48), (189, 257)] {
            for space in [CGColorSpaceCreateDeviceRGB(), CGColorSpace(name: CGColorSpace.sRGB)!,
                          CGColorSpace(name: CGColorSpace.displayP3)!] {
                for alpha in [CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .noneSkipLast] {
                    let stride = (size.0 * 4 + 63) / 64 * 64
                    let context = try XCTUnwrap(CGContext(data: nil, width: size.0, height: size.1,
                        bitsPerComponent: 8, bytesPerRow: stride, space: space, bitmapInfo: alpha.rawValue))
                    context.clear(CGRect(x: 0, y: 0, width: size.0, height: size.1))
                    for row in 0..<size.1 {
                        context.setFillColor(red: CGFloat(row % 3) / 2, green: 0.4, blue: 0.8,
                            alpha: CGFloat(row % 4) / 3)
                        context.fill(CGRect(x: 0, y: row, width: size.0, height: 1))
                    }
                    let image = try XCTUnwrap(context.makeImage())
                    try assertExactRGBAConversion(image)
                }
            }
        }
    }

    func testRGBAConversionPreservesGrayscaleAndCancellation() async throws {
        let width = 7, height = 13, stride = 16
        let data = Data((0..<(stride * height)).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: stride, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        try assertExactRGBAConversion(image)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return NativeOCRCGImageAdapter.makeRGBAFrame(from: image)
        }
        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }

    func testRGBAConversionPreservesBinaryAndGrayscaleMaskBackgrounds() throws {
        for bits in [1, 8] {
            for shade: UInt8 in [0, 85, 255] {
                let width = 8, height = 8, stride = bits == 1 ? 1 : 8
                let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: shade, count: stride * height) as CFData))
                let image = try XCTUnwrap(CGImage(maskWidth: width, height: height, bitsPerComponent: bits,
                    bitsPerPixel: bits, bytesPerRow: stride, provider: provider, decode: nil, shouldInterpolate: false))
                XCTAssertTrue(image.isMask)
                // Unlike ordinary images, masks intentionally leave uncovered
                // destination pixels unchanged; compare only with zero-fill.
                try assertExactRGBAConversion(image, poisons: [0])
            }
        }
    }

    private func assertExactRGBAConversion(_ image: CGImage, poisons: [UInt8] = [0, 0xA5]) throws {
        let actual = try XCTUnwrap(NativeOCRCGImageAdapter.makeRGBAFrame(from: image))
        for poison in poisons {
            var expected = [UInt8](repeating: poison, count: image.width * image.height * 4)
            try expected.withUnsafeMutableBytes { bytes in
                let target = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                target.interpolationQuality = .none
                target.setBlendMode(.copy)
                target.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            XCTAssertEqual(actual.bytes, expected)
        }
    }

    // MARK: - Historical reference implementations

    private static let referenceMean: [Float] = [0.485, 0.456, 0.406]
    private static let referenceDeviation: [Float] = [0.229, 0.224, 0.225]

    /// Verbatim copy of the pre-optimization `prepareBounded` element loop.
    private static func referencePrepareBounded(
        frame: NativeOCRRGBAFrame, canvasWidth: Int, canvasHeight: Int,
        dimensions: (width: Int, height: Int),
        sourceXs: [(Int, Int, Float)], sourceYs: [(Int, Int, Float)]
    ) -> [Float] {
        let channelMean = referenceMean
        let channelStandardDeviation = referenceDeviation
        let plane = canvasWidth * canvasHeight
        var values = [Float](repeating: 0, count: plane * 3)
        frame.bytes.withUnsafeBufferPointer { source in
            values.withUnsafeMutableBufferPointer { target in
                for y in 0..<dimensions.height {
                    let (y0, y1, fy) = sourceYs[y]
                    for x in 0..<dimensions.width {
                        let (x0, x1, fx) = sourceXs[x]
                        for channel in 0..<3 {
                            let offset = 2 - channel // detector uses BGR
                            let a = Float(source[y0 * frame.bytesPerRow + x0 * 4 + offset])
                            let b = Float(source[y0 * frame.bytesPerRow + x1 * 4 + offset])
                            let c = Float(source[y1 * frame.bytesPerRow + x0 * 4 + offset])
                            let d = Float(source[y1 * frame.bytesPerRow + x1 * 4 + offset])
                            let pixel = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                            target[channel * plane + y * canvasWidth + x] =
                                (pixel / 255 - channelMean[channel]) / channelStandardDeviation[channel]
                        }
                    }
                }
            }
        }
        return values
    }

    /// Verbatim copy of the pre-optimization generic output-map copy.
    private static func referenceMakeMap<Element: BinaryFloatingPoint>(
        pointer: UnsafePointer<Element>, width: Int, height: Int, rowStride: Int, columnStride: Int
    ) -> [Float] {
        var values = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                values[row * width + column] = Float(pointer[row * rowStride + column * columnStride])
            }
        }
        return values
    }

    // MARK: - Helpers

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func randomFrame(width: Int, height: Int, rowPadding: Int, seed: UInt64) throws -> NativeOCRRGBAFrame {
        var generator = SeededGenerator(state: seed)
        let bytesPerRow = width * 4 + rowPadding
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            let words = raw.count / 8
            let pointer = raw.baseAddress!
            for index in 0..<words {
                pointer.storeBytes(of: generator.next(), toByteOffset: index * 8, as: UInt64.self)
            }
            for index in (words * 8)..<raw.count {
                raw[index] = UInt8(truncatingIfNeeded: generator.next())
            }
        }
        return try XCTUnwrap(NativeOCRRGBAFrame(width: width, height: height, bytesPerRow: bytesPerRow, bytes: bytes))
    }

    private static func assertBitIdentical(_ lhs: [Float], _ rhs: [Float], _ label: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, label, file: file, line: line)
        guard lhs.count == rhs.count else { return }
        let mismatch = lhs.withUnsafeBufferPointer { a in
            rhs.withUnsafeBufferPointer { b in
                (0..<a.count).first { a[$0].bitPattern != b[$0].bitPattern }
            }
        }
        if let mismatch {
            XCTFail("\(label): first mismatch at \(mismatch): \(lhs[mismatch]) vs \(rhs[mismatch])", file: file, line: line)
        }
    }

    // MARK: - prepareBounded

    func testParallelBoundedPreprocessingIsBitIdenticalToScalarReference() async throws {
        // (source width, height, row padding, maximum side, extra canvas padding)
        let cases: [(Int, Int, Int, Int, Int, Int)] = [
            (37, 53, 0, 2_000, 0, 0),        // upscale to the 32 stride, odd size
            (257, 389, 16, 192, 0, 0),       // downscale, padded rows
            (1_281, 64, 0, 1_600, 0, 0),     // wide, one axis unchanged vertically
            (640, 960, 12, 1_600, 0, 0),     // identity resize (no MLTensor ramps)
            (999, 1_501, 4, 1_600, 0, 0),    // odd portrait downscale
            (511, 733, 0, 512, 64, 32),      // padded canvas: zero padding path
            (3_840, 2_160, 0, 1_600, 0, 0),  // 4K landscape
            (2_160, 3_840, 8, 1_600, 0, 0),  // 4K portrait, padded rows
        ]
        for (index, entry) in cases.enumerated() {
            let (width, height, padding, maximumSide, extraWidth, extraHeight) = entry
            let frame = try Self.randomFrame(width: width, height: height, rowPadding: padding,
                                             seed: UInt64(index + 1) &* 7_919)
            let dimensions = try XCTUnwrap(NativeCoreMLDetectionPreprocessor.resizeDimensions(
                sourceWidth: width, sourceHeight: height, maximumSide: maximumSide))
            let canvas = try XCTUnwrap(NativeCoreMLDetectionCanvas(inputShape: [
                1, 3, dimensions.height + extraHeight, dimensions.width + extraWidth,
            ]))
            let sourceXs = await NativeCoreMLDetectionPreprocessor.computeResizeCoordinates(
                sourceLength: width, targetLength: dimensions.width,
                resizesOtherAxis: height != dimensions.height)
            let sourceYs = await NativeCoreMLDetectionPreprocessor.computeResizeCoordinates(
                sourceLength: height, targetLength: dimensions.height, vertical: true,
                resizesOtherAxis: width != dimensions.width)
            let expected = Self.referencePrepareBounded(
                frame: frame, canvasWidth: canvas.width, canvasHeight: canvas.height,
                dimensions: dimensions, sourceXs: sourceXs, sourceYs: sourceYs)
            let direct = try NativeCoreMLDetectionPreprocessor.fillBoundedInput(
                frame: frame, canvasWidth: canvas.width, canvasHeight: canvas.height,
                width: dimensions.width, height: dimensions.height,
                sourceXs: sourceXs, sourceYs: sourceYs)
            Self.assertBitIdentical(expected, direct, "fill \(width)x\(height)")
            // End to end twice: the second call replays cached ramps.
            for pass in 0..<2 {
                let prepared = try await NativeCoreMLDetectionPreprocessor.prepareBounded(
                    frame: frame, canvas: canvas, dimensions: dimensions)
                XCTAssertEqual(prepared.input.shape, canvas.inputShape)
                let actual = await prepared.values()
                Self.assertBitIdentical(expected, actual, "prepareBounded \(width)x\(height) pass \(pass)")
            }
        }
    }

    func testCachedResizeCoordinatesMatchFreshComputation() async {
        for (source, target, vertical, other) in [(1_000, 608, false, true), (1_000, 608, true, false),
                                                 (37, 64, true, true), (3_840, 1_600, false, true)] {
            let fresh = await NativeCoreMLDetectionPreprocessor.computeResizeCoordinates(
                sourceLength: source, targetLength: target, vertical: vertical, resizesOtherAxis: other)
            for _ in 0..<2 {
                let cached = await NativeCoreMLDetectionPreprocessor.resizeCoordinates(
                    sourceLength: source, targetLength: target, vertical: vertical, resizesOtherAxis: other)
                XCTAssertEqual(cached.count, fresh.count)
                for (lhs, rhs) in zip(cached, fresh) {
                    XCTAssertEqual(lhs.0, rhs.0)
                    XCTAssertEqual(lhs.1, rhs.1)
                    XCTAssertEqual(lhs.2.bitPattern, rhs.2.bitPattern)
                }
            }
        }
    }

    func testBoundedPreprocessingObservesCancellationBetweenPasses() async throws {
        let frame = try Self.randomFrame(width: 700, height: 1_100, rowPadding: 0, seed: 3)
        let dimensions = try XCTUnwrap(NativeCoreMLDetectionPreprocessor.resizeDimensions(
            sourceWidth: 700, sourceHeight: 1_100, maximumSide: 1_600))
        let canvas = try XCTUnwrap(NativeCoreMLDetectionCanvas(inputShape: [1, 3, dimensions.height, dimensions.width]))
        struct Stop: Error {}
        var calls = 0
        do {
            _ = try await NativeCoreMLDetectionPreprocessor.prepareBounded(
                frame: frame, canvas: canvas, dimensions: dimensions,
                cancellationCheck: { calls += 1; if calls > 3 { throw Stop() } })
            XCTFail("Expected cancellation")
        } catch is Stop {}
    }

    // MARK: - Output maps

    private static func randomMultiArray(height: Int, width: Int, type: MLMultiArrayDataType, seed: UInt64) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: height), NSNumber(value: width)], dataType: type)
        var generator = SeededGenerator(state: seed)
        for index in 0..<array.count {
            let value = Float(Double(generator.next() % 1_000_000) / 999_983.0)
            switch type {
            case .float16: array.dataPointer.assumingMemoryBound(to: Float16.self)[index] = Float16(value)
            case .double: array.dataPointer.assumingMemoryBound(to: Double.self)[index] = Double(value) + 1e-12
            default: array.dataPointer.assumingMemoryBound(to: Float.self)[index] = value
            }
        }
        return array
    }

    private static func referenceMap(_ array: MLMultiArray, region: NativeCoreMLDetectionMapRegion) -> [Float] {
        let rowStride = array.strides[2].intValue, columnStride = array.strides[3].intValue
        let origin = region.y * rowStride + region.x * columnStride
        switch array.dataType {
        case .float16:
            return referenceMakeMap(pointer: UnsafePointer(array.dataPointer.assumingMemoryBound(to: Float16.self)).advanced(by: origin),
                                    width: region.width, height: region.height, rowStride: rowStride, columnStride: columnStride)
        case .double:
            return referenceMakeMap(pointer: UnsafePointer(array.dataPointer.assumingMemoryBound(to: Double.self)).advanced(by: origin),
                                    width: region.width, height: region.height, rowStride: rowStride, columnStride: columnStride)
        default:
            return referenceMakeMap(pointer: UnsafePointer(array.dataPointer.assumingMemoryBound(to: Float.self)).advanced(by: origin),
                                    width: region.width, height: region.height, rowStride: rowStride, columnStride: columnStride)
        }
    }

    func testMultiArrayOutputMapCopiesAreBitIdentical() throws {
        let height = 96, width = 160
        let regions = [
            NativeCoreMLDetectionMapRegion.full(width: width, height: height),
            NativeCoreMLDetectionMapRegion(x: 0, y: 0, width: 128, height: 96),
            NativeCoreMLDetectionMapRegion(x: 17, y: 5, width: 61, height: 33),
            NativeCoreMLDetectionMapRegion(x: 0, y: 40, width: 160, height: 56),
        ]
        for (typeIndex, type) in [MLMultiArrayDataType.float32, .float16, .double].enumerated() {
            let array = try Self.randomMultiArray(height: height, width: width, type: type, seed: UInt64(typeIndex + 11))
            for region in regions {
                let map = try NativeCoreMLDetectionOutput.makeMap(
                    output: array, region: region, fullWidth: width, fullHeight: height,
                    expectedShape: [1, 1, height, width])
                XCTAssertEqual(map.width, region.width)
                XCTAssertEqual(map.height, region.height)
                Self.assertBitIdentical(Self.referenceMap(array, region: region), map.values, "\(type) \(region)")
            }
        }
    }

    func testStridedOutputMapCopyIsBitIdentical() {
        // Non-unit column stride and padded rows exercise the scalar fallback
        // and the per-row memcpy path respectively.
        var storage = [Float](repeating: 0, count: 64 * 50)
        var generator = SeededGenerator(state: 99)
        for index in storage.indices { storage[index] = Float(bitPattern: UInt32(truncatingIfNeeded: generator.next()) & 0x3F7F_FFFF) }
        storage.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for (rowStride, columnStride, width, height) in [(64, 1, 50, 40), (64, 1, 64, 50), (64, 2, 30, 20), (128, 1, 64, 25)] {
                let expected = Self.referenceMakeMap(pointer: base, width: width, height: height,
                                                     rowStride: rowStride, columnStride: columnStride)
                let actual = NativeCoreMLDetectionOutput.makeMap(pointer: base, width: width, height: height,
                                                                 rowStride: rowStride, columnStride: columnStride)
                Self.assertBitIdentical(expected, actual.values, "stride \(rowStride)/\(columnStride)")
            }
        }
    }

    func testTensorOutputMapFullRegionFastPathMatchesSlice() async throws {
        let height = 64, width = 96
        var generator = SeededGenerator(state: 5)
        let scalars = (0..<(height * width)).map { _ in Float(Double(generator.next() % 1_000_000) / 999_983.0) }
        // `shapedArray(of: Float.self)` requires Float32 tensors on both the
        // historical and the fast path; the detector output is Float32.
        let tensors = [MLTensor(shape: [1, 1, height, width], scalars: scalars)]
        for tensor in tensors {
            let full = NativeCoreMLDetectionMapRegion.full(width: width, height: height)
            let map = try await NativeCoreMLDetectionOutput.makeMap(
                output: tensor, region: full, fullWidth: width, fullHeight: height,
                expectedShape: [1, 1, height, width])
            // Historical path: slice the tensor, then copy the shaped array.
            let sliced = await tensor[0, 0, 0..<height, 0..<width].shapedArray(of: Float.self)
            let expected = sliced.withUnsafeShapedBufferPointer { pointer, _, strides in
                Self.referenceMakeMap(pointer: pointer.baseAddress!, width: width, height: height,
                                      rowStride: strides[0], columnStride: strides[1])
            }
            Self.assertBitIdentical(expected, map.values, "tensor full \(tensor.scalarType)")
            let partial = NativeCoreMLDetectionMapRegion(x: 3, y: 7, width: 41, height: 29)
            let partialMap = try await NativeCoreMLDetectionOutput.makeMap(
                output: tensor, region: partial, fullWidth: width, fullHeight: height,
                expectedShape: [1, 1, height, width])
            var partialExpected: [Float] = []
            for row in 0..<partial.height {
                for column in 0..<partial.width {
                    partialExpected.append(expected[(row + partial.y) * width + column + partial.x])
                }
            }
            Self.assertBitIdentical(partialExpected, partialMap.values, "tensor partial \(tensor.scalarType)")
        }
    }

    // MARK: - DB threshold mask

    func testFloatThresholdMaskMatchesDoublePredicate() {
        var generator = SeededGenerator(state: 17)
        var values: [Float] = [0, -0.0, .infinity, -.infinity, .nan, -.nan, .greatestFiniteMagnitude,
                               -.greatestFiniteMagnitude, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
                               .leastNormalMagnitude, 1, -1, 0.5]
        let thresholds: [Double] = [0.3, 0.2, 0.6, 0, -0.0, 1e-50, -1e-50, 1e-40, .nan, .infinity, -.infinity,
                                    1e300, -1e300, Double(Float(0.3)), Double(Float(0.3)).nextUp,
                                    Double(Float(0.3)).nextDown, Double(Float.greatestFiniteMagnitude),
                                    Double(Float.leastNonzeroMagnitude) / 2, 0.1]
        for threshold in thresholds where threshold.isFinite {
            let cutoff = Float(threshold)
            values.append(contentsOf: [cutoff, cutoff.nextUp, cutoff.nextDown])
        }
        for _ in 0..<200_000 {
            values.append(Float(bitPattern: UInt32(truncatingIfNeeded: generator.next())))
            values.append(Float(Double(generator.next() % 2_000_001) / 1_000_000.0 - 0.5))
        }
        for threshold in thresholds {
            let actual = NativeCoreMLDBPostprocessor.foregroundState(values: values, threshold: threshold)
            for (index, value) in values.enumerated() {
                let expected: UInt8 = value.isFinite && Double(value) > threshold ? 1 : 0
                if actual[index] != expected {
                    XCTFail("threshold \(threshold) value \(value) (\(value.bitPattern)): \(actual[index]) != \(expected)")
                    break
                }
            }
        }
    }

    // MARK: - Warm-up

    func testPipelineWarmUpLoadsDetectorAndRecognizerConcurrently() async throws {
        let probe = WarmUpProbe()
        let pipeline = NativeCoreMLOCRPipeline(detector: WarmUpDetector(probe: probe),
                                               recognizer: WarmUpRecognizer(probe: probe))
        try await pipeline.warmUp()
        let events = await probe.events
        XCTAssertEqual(Set(events), ["detector-start", "recognizer-start", "detector-end", "recognizer-end"])
        // Both loads start before either finishes: they overlap.
        XCTAssertEqual(Set(events.prefix(2)), ["detector-start", "recognizer-start"])
    }
}

@available(iOS 18.0, *)
private actor WarmUpProbe {
    private(set) var events: [String] = []
    private var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func start(_ name: String) async {
        events.append(name + "-start")
        started += 1
        if started == 2 {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func end(_ name: String) { events.append(name + "-end") }
}

@available(iOS 18.0, *)
private final class WarmUpDetector: NativeCoreMLDetecting {
    let probe: WarmUpProbe
    init(probe: WarmUpProbe) { self.probe = probe }
    func warmUpModel() async throws {
        await probe.start("detector")
        await probe.end("detector")
    }
    func detect(frame: NativeOCRRGBAFrame, requestID: String, configuration: NativeCoreMLDBPostprocessConfiguration,
                cancellationCheck: @escaping @Sendable () throws -> Void) async throws -> NativeCoreMLDetectionResult {
        throw CancellationError()
    }
    func cancelCurrent() {}
    func purgeResources() async {}
}

@available(iOS 18.0, *)
private final class WarmUpRecognizer: NativeCoreMLRecognizing {
    let probe: WarmUpProbe
    init(probe: WarmUpProbe) { self.probe = probe }
    func prepare() async throws {
        await probe.start("recognizer")
        await probe.end("recognizer")
    }
    func recognize(frame: NativeOCRRGBAFrame, regions: [NativeCoreMLRecognitionRegion], requestID: String,
                   confidenceThreshold: Double,
                   cancellationCheck: @escaping @Sendable () throws -> Void) async throws -> NativeCoreMLRecognitionResult {
        throw CancellationError()
    }
    func cancelCurrent() {}
    func purgeResources() async {}
}
