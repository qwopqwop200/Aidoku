import CoreGraphics
@preconcurrency import CoreML
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRRecognitionRegressionTests {
    @Test func optInAuditIncludesRejectedAndEmptyDecodesWithoutExtraPrediction() async throws {
        let width = 32
        let height = 60
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width { bytes[(y * width + x) * 4 + 2] = UInt8(y / 20) }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        let regions = (0..<3).map { index in
            NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: [
                CGPoint(x: 0, y: index * 20), CGPoint(x: 20, y: index * 20),
                CGPoint(x: 20, y: index * 20 + 4), CGPoint(x: 0, y: index * 20 + 4)
            ])
        }
        var dictionary = (0..<NativeCoreMLRecognizer.expectedDictionaryCharacterCount).map { "line-\($0)" }
        dictionary[1] = "" // An empty decode must remain observable, never accepted.
        let predictor = OCRPixelPredictor()
        let audit = OCRRecognitionAuditRecorder()
        let recognizer = try NativeCoreMLRecognizer(
            predictor: predictor, dictionary: dictionary, recognitionCacheCapacity: 8,
            auditObserver: { audit.append($0) }
        )
        let rejected = try await recognizer.recognize(
            frame: frame, regions: regions, requestID: "audit-rejected", confidenceThreshold: 0.95
        )
        #expect(rejected.regions.isEmpty)
        #expect(audit.requestedCount == 3)
        #expect(audit.decodedTexts.sorted() == ["", "line-0", "line-2"])
        #expect(audit.decodedCount == 3)
        #expect(audit.cacheHitCount == 0)
        #expect(audit.requestIDs == Set(["audit-rejected"]))
        #expect(audit.thresholds == [0.95, 0.95, 0.95])
        let predictionCount = predictor.predictionCount
        audit.removeAll()
        let accepted = try await recognizer.recognize(
            frame: frame, regions: regions, requestID: "audit-cached", confidenceThreshold: 0.75
        )
        #expect(accepted.regions.map(\.text) == ["line-0", "line-2"])
        #expect(predictor.predictionCount == predictionCount)
        #expect(accepted.diagnostics.predictedRegions == 0)
        #expect(audit.requestedCount == 3)
        #expect(audit.decodedCount == 3)
        #expect(audit.cacheHitCount == 3)
        #expect(audit.requestIDs == Set(["audit-cached"]))
        #expect(audit.thresholds == [0.75, 0.75, 0.75])
    }

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

/// Test-only sink: no files, console output, or source image storage.
private final class OCRRecognitionAuditRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NativeCoreMLRecognitionAuditEvent] = []
    func append(_ event: NativeCoreMLRecognitionAuditEvent) { lock.withLock { events.append(event) } }
    func removeAll() { lock.withLock { events.removeAll() } }
    private var snapshot: [NativeCoreMLRecognitionAuditEvent] { lock.withLock { events } }
    var requestedCount: Int { snapshot.filter { if case .requested = $0 { true } else { false } }.count }
    var decodedCount: Int { snapshot.filter { if case .decoded = $0 { true } else { false } }.count }
    var decodedTexts: [String] {
        snapshot.compactMap { if case let .decoded(_, _, text, _, _, _) = $0 { text } else { nil } }
    }
    var cacheHitCount: Int {
        snapshot.filter { if case .decoded(_, _, _, _, _, true) = $0 { true } else { false } }.count
    }
    var thresholds: [Double] {
        snapshot.compactMap { if case let .decoded(_, _, _, _, threshold, _) = $0 { threshold } else { nil } }
    }
    var requestIDs: Set<String> {
        Set(snapshot.map {
            switch $0 {
            case let .requested(requestID, _): requestID
            case let .decoded(requestID, _, _, _, _, _): requestID
            }
        })
    }
}
