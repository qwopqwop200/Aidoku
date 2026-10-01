import CoreGraphics
@preconcurrency import CoreML
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeOCRPreparationBudgetTests {
    @Test func compatibilityBudgetEqualsEightIndependentPreparedFloatBuffers() throws {
        #expect(IPhoneOCRSettings.defaultRecognizerMaximumWidth == 1_184)
        #expect(NativeCoreMLRecognizer.inputShape == [1, 3, 48, 1_184])
        #expect(NativeCoreMLRecognizer.outputShape == [2, 148])
        #expect(NativeCoreMLRecognizer.maximumPreparedRegionCount == 8)
        #expect(NativeCoreMLRecognizer.maximumPreparedWindowRegionCount == 4)
        // Distinct source bands prevent equal-value CoW reuse from making this
        // allocation check cheaper than the eight-tensor worst case.
        var bytes = [UInt8](repeating: 255, count: 1_280 * 48 * 8 * 4)
        for row in 0..<(48 * 8) {
            for column in 0..<1_280 { bytes[(row * 1_280 + column) * 4] = UInt8(row / 48) }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: 1_280, height: 48 * 8, bytes: bytes))
        let tensors = try (0..<8).map { index in
            let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(
                polygon: polygon(width: 1_280, y: index * 48), dynamicWidth: true,
                maximumWidth: 1_280
            ))
            return try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, plan: plan))
        }
        let addresses = tensors.map { $0.values.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) } }
        #expect(Set(addresses).count == 8)
        let actualBytes = tensors.reduce(0) { total, tensor in total + tensor.values.withUnsafeBytes { $0.count } }
        #expect(actualBytes == 5_898_240)
        #expect(actualBytes == NativeCoreMLRecognizer.maximumPreparedTensorBytes)
        #expect(actualBytes / 2 == NativeCoreMLRecognizer.maximumPreparedWindowTensorBytes)
    }

    @Test(arguments: [1_280, 1_281, 1_706, 1_707, 2_000])
    func chunkAdmissionMatchesActualPreparedTensorBytes(width: Int) throws {
        let expectedCount = switch width {
        case 1_280: 4
        case 1_281, 1_706: 3
        default: 2
        }
        let frame = try makeFrame(width: width, height: 48)
        let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(
            polygon: polygon(width: width), dynamicWidth: true, maximumWidth: width
        ))
        let tensor = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, plan: plan))
        let actualBytes = tensor.values.withUnsafeBytes { $0.count }
        #expect(NativeOCRPreparationWindowBudget.bytesPerRegion(bucket: plan.bucket) == actualBytes)
        #expect(NativeOCRPreparationWindowBudget.maximumChunkRegionCount(bucket: plan.bucket) == expectedCount)
        var budget = NativeOCRPreparationWindowBudget()
        let admitted = budget.admit(regions: expectedCount, bucket: plan.bucket)
        #expect(admitted)
        #expect(budget.tensorBytes == actualBytes * expectedCount)
        #expect(budget.tensorBytes * 2 <= NativeCoreMLRecognizer.maximumPreparedTensorBytes)
        let rejected = budget.admit(regions: 1, bucket: plan.bucket)
        #expect(!rejected)
        #expect(budget.regionCount == expectedCount)
        #expect(budget.tensorBytes == actualBytes * expectedCount)
    }

    @Test func mixedWidthsRespectBytesAsWellAsRegionCount() throws {
        let wide = try #require(NativeCoreMLRecognitionBucket(width: 2_000))
        let reader = try #require(NativeCoreMLRecognitionBucket(width: 1_280))
        var budget = NativeOCRPreparationWindowBudget()
        let first = budget.admit(regions: 2, bucket: wide)
        #expect(first)
        #expect(budget.regionCount == 2)
        #expect(budget.tensorBytes == 2_304_000)
        let overBudget = budget.admit(regions: 1, bucket: reader)
        #expect(!overBudget)
        #expect(budget.regionCount == 2)
        #expect(budget.tensorBytes == 2_304_000)
        let small = try #require(NativeCoreMLRecognitionBucket(width: 320))
        let remainder = budget.admit(regions: 2, bucket: small)
        #expect(remainder)
        #expect(budget.regionCount == 4)
        #expect(budget.tensorBytes == 2_672_640)
    }

    @Test(arguments: [Int.min, -1, 0, 5, Int.max])
    func invalidRegionCountsDoNotOverflowOrChangeAdmission(regions: Int) throws {
        let bucket = try #require(NativeCoreMLRecognitionBucket(width: 1_280))
        var budget = NativeOCRPreparationWindowBudget()
        let admitted = budget.admit(regions: regions, bucket: bucket)
        #expect(!admitted)
        #expect(budget.regionCount == 0)
        #expect(budget.tensorBytes == 0)
    }

    @Test(arguments: [1_280, 2_000])
    func actualRecognizerBatchesEveryRegionWithinItsWindowBudget(width: Int) async throws {
        let frame = try makeFrame(width: width, height: 48 * 9)
        let regions = (0..<9).map { index in
            NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: polygon(width: width, y: index * 48))
        }
        let predictor = OCRPreparationBudgetPredictor()
        let recognizer = try NativeCoreMLRecognizer(
            predictor: predictor,
            dictionary: [String](repeating: "word", count: NativeCoreMLRecognizer.expectedDictionaryCharacterCount),
            recognitionCacheCapacity: 0, dynamicWidth: true, maximumRecognitionWidth: 2_000
        )
        let result = try await recognizer.recognize(frame: frame, regions: regions)
        let batches = width == 1_280 ? [4, 4, 1] : [2, 2, 2, 2, 1]
        #expect(result.diagnostics.modelFunctionSequence == batches.map { "rec\(width)b\($0)" })
        #expect(predictor.inputShapes == batches.map { [$0, 3, 48, width] })
        #expect(result.diagnostics.predictedRegions == 9)
        #expect(result.diagnostics.skippedInvalidRegions == 0)
        #expect(result.regions.map(\.sourceIndex) == Array(0..<9))
        #expect(result.regions.map(\.text) == [String](repeating: "word", count: 9))
        await recognizer.purgeResources()
    }

    @Test(arguments: [1_184, 1_185, 1_280, 2_000])
    func defaultRecognizerCapsLongLinesAndKeepsFourRegionBatches(sourceWidth: Int) async throws {
        let frame = try makeFrame(width: sourceWidth, height: 48 * 9)
        let regions = (0..<9).map { index in
            NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: polygon(width: sourceWidth, y: index * 48))
        }
        let predictor = OCRPreparationBudgetPredictor()
        let recognizer = try NativeCoreMLRecognizer(
            predictor: predictor,
            dictionary: [String](repeating: "word", count: NativeCoreMLRecognizer.expectedDictionaryCharacterCount),
            dynamicWidth: true
        )
        let result = try await recognizer.recognize(frame: frame, regions: regions)
        #expect(result.diagnostics.modelFunctionSequence == ["rec1184b4", "rec1184b4", "rec1184b1"])
        #expect(predictor.inputShapes == [[4, 3, 48, 1_184], [4, 3, 48, 1_184], [1, 3, 48, 1_184]])
        #expect(result.diagnostics.predictedRegions == 9)
        #expect(result.diagnostics.skippedInvalidRegions == 0)
        #expect(result.regions.map(\.sourceIndex) == Array(0..<9))
        #expect(result.regions.map(\.text) == [String](repeating: "word", count: 9))
        await recognizer.purgeResources()
    }

    private func makeFrame(width: Int, height: Int) throws -> NativeOCRRGBAFrame {
        try #require(NativeOCRRGBAFrame(
            width: width, height: height,
            bytes: [UInt8](repeating: 255, count: width * height * 4)
        ))
    }

    private func polygon(width: Int, y: Int = 0) -> [CGPoint] {
        [CGPoint(x: 0, y: y), CGPoint(x: width, y: y),
         CGPoint(x: width, y: y + 48), CGPoint(x: 0, y: y + 48)]
    }
}

private final class OCRPreparationBudgetPredictor: NativeCoreMLRecognitionPredicting, @unchecked Sendable {
    let modelName = "preparation-budget-probe"
    let inputFeatureName = "x"
    let outputFeatureName = "ctc_indices+ctc_scores"
    private let lock = NSLock()
    private var recordedShapes: [[Int]] = []
    var inputShapes: [[Int]] { lock.withLock { recordedShapes } }

    func predict(input: MLMultiArray) async throws -> NativeCoreMLRecognitionPrediction {
        let shape = input.shape.map(\.intValue)
        lock.withLock { recordedShapes.append(shape) }
        let timeSteps = (shape[3] + 3) / 8
        let outputs = try (0..<shape[0]).map { _ -> MLMultiArray in
            let output = try MLMultiArray(shape: [2, NSNumber(value: timeSteps)], dataType: .float32)
            let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
            pointer.initialize(repeating: 0, count: output.count)
            pointer[0] = 1
            pointer[output.strides[0].intValue] = 0.99
            return output
        }
        return NativeCoreMLRecognitionPrediction(outputs: outputs, modelWasLoaded: false, modelLoadMilliseconds: 0)
    }

    func purgeResources() async {}
}
