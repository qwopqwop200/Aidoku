import CoreGraphics
@preconcurrency import CoreML
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRRecognitionRegressionTests {
    @Test func rejectedSteepLatinHasABoundedAlternativeReadingAxis() throws {
        // Original detector quad of the real -57-degree "intensity" fixture.
        let polygon = [CGPoint(x: 255, y: 789), CGPoint(x: 391, y: 575),
                       CGPoint(x: 465, y: 619), CGPoint(x: 329, y: 833)]
        let alternative = try #require(NativeOCRScopeGeometry.alternateHorizontalQuad(polygon))
        #expect(alternative == polygon)
        let primary = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon))
        let recovered = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: alternative, useProvidedOrder: true))
        #expect(primary.rotatedCounterClockwise)
        #expect(!recovered.rotatedCounterClockwise)
        #expect(NativeOCRScopeGeometry.alternateHorizontalQuad([
            CGPoint(x: 516, y: 1259), CGPoint(x: 643, y: 1096),
            CGPoint(x: 750, y: 1183), CGPoint(x: 623, y: 1346)]) != nil)
        #expect(NativeOCRScopeGeometry.alternateHorizontalQuad([
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 20), CGPoint(x: 0, y: 20)]) == nil)
    }

    @Test(arguments: [-35.0, -25, -8, 8, 25, 35], [false, true])
    func slantedTensorKeepsUprightCropAxes(degrees: Double, vertical: Bool) throws {
        let w: CGFloat = vertical ? 32 : 180, h: CGFloat = vertical ? 180 : 32
        let a = degrees * .pi / 180
        let expected = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]
            .map { CGPoint(x: 250 + $0.x * cos(a) - $0.y * sin(a), y: 250 + $0.x * sin(a) + $0.y * cos(a)) }
        for offset in 0..<4 {
            let polygon = (0..<4).map { expected[($0 + offset) % 4] }
            #expect(NativeOCRScopeGeometry.canonicalQuad(polygon) == expected)
            #expect(NativeOCRScopeGeometry.canonicalQuad(Array(polygon.reversed())) == expected)
            let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon))
            #expect(plan.rotatedCounterClockwise == vertical)
        }
    }

    @Test(arguments: 1...7)
    func dynamicBatchesPreservePixelsOrderAndPartialCacheHits(count: Int) async throws {
        let width = 32, height = 180
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width { bytes[(y * width + x) * 4 + 2] = UInt8(y / 20) }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        let regions = (0..<count).map { index in
            NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: [
                CGPoint(x: 0, y: index * 20), CGPoint(x: 8, y: index * 20),
                CGPoint(x: 8, y: index * 20 + 4), CGPoint(x: 0, y: index * 20 + 4)
            ])
        }
        let predictor = OCRPixelPredictor()
        let recognizer = try NativeCoreMLRecognizer(
            predictor: predictor,
            dictionary: (0..<NativeCoreMLRecognizer.expectedDictionaryCharacterCount).map { "line-\($0)" },
            recognitionCacheCapacity: 128,
            dynamicWidth: true
        )
        // Preload just one crop so the next request exercises partial hits
        // inside batches of two, three, and four as well as singleton tails.
        _ = try await recognizer.recognize(frame: frame, regions: [regions[0]])
        let result = try await recognizer.recognize(frame: frame, regions: Array(regions.reversed()))
        #expect(result.regions.map(\.sourceIndex) == Array(0..<count))
        #expect(result.regions.map(\.text) == (0..<count).map { "line-\($0)" })
        #expect(result.diagnostics.cacheHitRegions == 1)
        #expect(result.diagnostics.predictedRegions == count - 1)
        #expect(predictor.maximumActivePredictions == 1)
        let batchSizes = result.diagnostics.modelFunctionSequence.compactMap { $0.last?.wholeNumberValue }
        #expect(batchSizes.reduce(0, +) == count - 1)
        let cached = try await recognizer.recognize(frame: frame, regions: regions)
        #expect(cached.regions == result.regions)
        #expect(cached.diagnostics.predictedRegions == 0)
        await recognizer.purgeResources()
    }

    @Test func precomputedSamplingCoordinatesPreserveEveryFloatBit() throws {
        let width = 128, height = 192
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in bytes.indices {
            bytes[index] = UInt8((index * 37 + index / 17) % 256)
        }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        for index in 0..<24 {
            let x = CGFloat(index % 4 * 7 - 9), y = CGFloat(index % 5 * 11 - 8)
            let w = CGFloat(10 + index * 13 % 100), h = CGFloat(12 + index * 29 % 170)
            let polygon = [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y + 2),
                           CGPoint(x: x + w - 3, y: y + h), CGPoint(x: x + 1, y: y + h - 2)]
            let actual = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, polygon: polygon))
            #if DEBUG
            let reference = try #require(NativeCoreMLRecognitionPreprocessor.prepareReferenceForTesting(frame: frame, polygon: polygon))
            #expect(actual.resizedWidth == reference.resizedWidth)
            #expect(actual.rotatedCounterClockwise == reference.rotatedCounterClockwise)
            #expect(actual.values.map { $0.bitPattern } == reference.values.map { $0.bitPattern })
            #endif
        }
    }

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
