import CoreGraphics
@preconcurrency import CoreML
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRRecognitionRegressionTests {
    @Test func mixedWidthWindowsPreservePixelsOrderPaddingAndCacheIdentity() async throws {
        let width = 128
        let height = 500
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width { bytes[(y * width + x) * 4 + 2] = UInt8(y / 20) }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        let regions = (0..<25).reversed().map { index in
            let right = [8, 40, 100][index % 3]
            let y = index * 20
            return NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: [
                CGPoint(x: 0, y: y), CGPoint(x: right, y: y),
                CGPoint(x: right, y: y + 4), CGPoint(x: 0, y: y + 4)
            ])
        }
        let predictor = OCRPixelPredictor()
        let recognizer = try NativeCoreMLRecognizer(
            predictor: predictor,
            dictionary: (0..<NativeCoreMLRecognizer.expectedDictionaryCharacterCount).map { "line-\($0)" },
            recognitionCacheCapacity: 128
        )
        let first = try await recognizer.recognize(frame: frame, regions: regions)
        #expect(first.regions.map(\.sourceIndex) == Array(0..<25))
        #expect(first.regions.map(\.text) == (0..<25).map { "line-\($0)" })
        #expect(first.diagnostics.predictedRegions == 25)
        #expect(first.diagnostics.modelFunctionSequence == Array(repeating: "rec1280b1", count: 8)
                + Array(repeating: "rec640b4", count: 2) + Array(repeating: "rec320b4", count: 3))
        #expect(predictor.maximumActivePredictions == 1)
        let calls = predictor.predictionCount
        let remapped = regions.map { NativeCoreMLRecognitionRegion(sourceIndex: $0.sourceIndex + 100, polygon: $0.polygon) }
        let second = try await recognizer.recognize(frame: frame, regions: remapped)
        #expect(second.regions.map(\.sourceIndex) == Array(100..<125))
        #expect(second.regions.map(\.text) == first.regions.map(\.text))
        #expect(second.diagnostics.cacheHitRegions == 25)
        #expect(second.diagnostics.predictedRegions == 0)
        #expect(predictor.predictionCount == calls)
        let filtered = try await recognizer.recognize(frame: frame, regions: regions, confidenceThreshold: 0.95)
        #expect(filtered.regions.isEmpty)
        #expect(filtered.diagnostics.cacheHitRegions == 25)
        #expect(predictor.predictionCount == calls)
    }
}

private final class OCRPixelPredictor: NativeCoreMLRecognitionPredicting, @unchecked Sendable {
    let modelName = "pixel-order-probe"
    let inputFeatureName = "x"
    let outputFeatureName = "ctc_indices+ctc_scores"
    private let lock = NSLock()
    private var active = 0
    private var maximumActive = 0
    private var count = 0
    var maximumActivePredictions: Int { lock.withLock { maximumActive } }
    var predictionCount: Int { lock.withLock { count } }

    func predict(input: MLMultiArray) async throws -> NativeCoreMLRecognitionPrediction {
        lock.withLock { active += 1; count += 1; maximumActive = max(maximumActive, active) }
        defer { lock.withLock { active -= 1 } }
        try await Task.sleep(for: .milliseconds(1))
        let source = input.dataPointer.assumingMemoryBound(to: Float.self)
        let batchStride = input.strides[0].intValue
        let timeSteps = input.shape[3].intValue / 8
        let outputs = try (0..<input.shape[0].intValue).map { batch -> MLMultiArray in
            let output = try MLMultiArray(shape: [2, NSNumber(value: timeSteps)], dataType: .float32)
            let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
            pointer.initialize(repeating: 0, count: output.count)
            let pixel = Int(((source[batch * batchStride] + 1) * 127.5).rounded())
            pointer[0] = Float(pixel + 1)
            pointer[output.strides[0].intValue] = 0.9
            return output
        }
        return NativeCoreMLRecognitionPrediction(outputs: outputs, modelWasLoaded: false, modelLoadMilliseconds: 0)
    }

    func purgeResources() async {}
}
