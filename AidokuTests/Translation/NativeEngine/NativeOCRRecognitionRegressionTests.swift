import CoreGraphics
@preconcurrency import CoreML
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRRecognitionRegressionTests {
    @Test func dictionaryKeepsLiteralBytesAndReportsMalformedLines() throws {
        let source = "\u{feff}\"e\u{301}\"\r\n\"\\\"\"\r\n \"\\\\\" \r\n\"\"\r\n"
        let tokens = try NativeCoreMLRecognizer.parseDictionary(data: Data(source.utf8), expectedCharacterCount: 4)
        #expect(tokens.map { Array($0.utf8) } == [[0x65, 0xcc, 0x81], [0x22], [0x5c], []])
        for malformed in ["\"a\"\"b\"", "\"a\tb\"", "\"unterminated"] {
            #expect(throws: NativeCoreMLRecognizerError.dictionaryMalformed(line: 5)) {
                try NativeCoreMLRecognizer.parseDictionary(data: Data((source + malformed).utf8))
            }
        }
    }

    @Test func executionSummaryIncludesCancelledInvocationAndKeepsItsGeneration() async throws {
        let frame = try #require(NativeOCRRGBAFrame(width: 32, height: 48,
            bytes: [UInt8](repeating: 255, count: 32 * 48 * 4)))
        let region = NativeCoreMLRecognitionRegion(sourceIndex: 0,
            polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 32, y: 0), CGPoint(x: 32, y: 48), CGPoint(x: 0, y: 48)])
        let predictor = OCRPixelPredictor(delay: .seconds(30))
        let recorder = OCRExecutionRecorder()
        let recognizer = try NativeCoreMLRecognizer(predictor: predictor,
            dictionary: (0..<NativeCoreMLRecognizer.expectedDictionaryCharacterCount).map { "token-\($0)" },
            dynamicWidth: true, executionObserver: { recorder.append($0) })
        let task = Task { try await recognizer.recognize(frame: frame, regions: [region], requestID: "cancelled-pass") }
        // The fixture blocks in a cancellable sleep after entering predict.
        for _ in 0..<100_000 where predictor.predictionCount == 0 { await Task.yield() }
        #expect(predictor.predictionCount == 1)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled recognition unexpectedly succeeded") }
        catch is CancellationError { }
        let snapshots = recorder.snapshot
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.requestID == "cancelled-pass" && snapshot.generation > 0)
        #expect(snapshot.predictionAttempts == 1 && snapshot.attemptedCrops == 1 && snapshot.attemptedBatchSlots == 1)
        #expect(snapshot.discardedCompletedPredictions == 0 && snapshot.discardedCompletedCrops == 0)
    }

    @Test(arguments: [false, true])
    func emissionSpansSurviveCropCacheWithoutAdditionalPredictions(observeSpans: Bool) async throws {
        let frame = try #require(NativeOCRRGBAFrame(width: 32, height: 48,
            bytes: [UInt8](repeating: 255, count: 32 * 48 * 4)))
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 32, y: 0), CGPoint(x: 32, y: 48), CGPoint(x: 0, y: 48)]
        let predictor = OCRPixelPredictor()
        let recognizer = try NativeCoreMLRecognizer(predictor: predictor,
            dictionary: (0..<NativeCoreMLRecognizer.expectedDictionaryCharacterCount).map { "token-\($0)" },
            recognitionCacheCapacity: 8, dynamicWidth: true, observeEmissionSpans: observeSpans)
        let first = try await recognizer.recognize(frame: frame,
            regions: [.init(sourceIndex: 0, polygon: polygon)])
        let predictionCount = predictor.predictionCount
        let second = try await recognizer.recognize(frame: frame,
            regions: [.init(sourceIndex: 7, polygon: polygon)])
        let initial = try #require(first.regions.first)
        let cached = try #require(second.regions.first)
        #expect(initial.text == cached.text && initial.confidence == cached.confidence)
        #expect(initial.tokenObservations == cached.tokenObservations)
        #expect(cached.sourceIndex == 7 && cached.polygon == polygon)
        let token = try #require(cached.tokenObservations.first)
        #expect((token.emissionSpan != nil) == observeSpans)
        if let span = token.emissionSpan {
            #expect(span.steps == 0..<1 && span.precedingBlankSteps == 0 && span.timeStepCount > 0)
        }
        #expect(second.diagnostics.cacheHitRegions == 1 && second.diagnostics.predictedRegions == 0)
        #expect(predictor.predictionCount == predictionCount)
    }

    @Test func alternateSamplingGeometryDoesNotEnlargeRecognizedOwnership() async throws {
        var bytes = [UInt8](repeating: 255, count: 32 * 40 * 4)
        for y in 0..<40 {
            for x in 0..<32 { bytes[(y * 32 + x) * 4 + 2] = UInt8(y / 20) }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: 32, height: 40, bytes: bytes))
        let original = [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 4), CGPoint(x: 0, y: 4)]
        let sampling = original.map { CGPoint(x: $0.x, y: $0.y + 20) }
        let recognizer = try NativeCoreMLRecognizer(
            predictor: OCRPixelPredictor(),
            dictionary: (0..<NativeCoreMLRecognizer.expectedDictionaryCharacterCount).map { "line-\($0)" }
        )
        let result = try await recognizer.recognize(frame: frame, regions: [
            NativeCoreMLRecognitionRegion(sourceIndex: 2, polygon: original, samplingPolygon: sampling, isThinFinePrintRecovery: true)
        ])
        #expect(result.regions.first?.text == "line-1")
        #expect(result.regions.first?.polygon == original)
    }

    @Test(arguments: [0.5, 1.0, 2.0, 4.0])
    func savedNearThresholdCropsKeepReadingAxisAcrossResolutions(scale: Double) throws {
        // Saved low-confidence recognizer quads: run 2EAB1CCF, pages
        // 0280/source20 (.533), 0354/source2 (.547), 0390/source10 (.445).
        // All are below the tall-crop threshold; floored edge lengths had
        // incorrectly rotated all three by 90 degrees at their saved scale.
        let polygons: [[CGPoint]] = [
            [CGPoint(x: 207, y: 286), CGPoint(x: 287, y: 310),
             CGPoint(x: 248, y: 430), CGPoint(x: 167, y: 405)],
            [CGPoint(x: 928, y: 661), CGPoint(x: 955, y: 648),
             CGPoint(x: 975, y: 688), CGPoint(x: 948, y: 702)],
            [CGPoint(x: 1497, y: 1806), CGPoint(x: 1511, y: 1801),
             CGPoint(x: 1517, y: 1822), CGPoint(x: 1504, y: 1826)]
        ]
        for polygon in polygons {
            let scaled = polygon.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: scaled))
            #expect(!plan.rotatedCounterClockwise)
        }
    }

    @Test(arguments: [1.49, 1.5, 1.51], [0.5, 1.0, 2.0, 4.0])
    func readingAxisUsesContinuousAspectRatio(ratio: Double, scale: Double) throws {
        let width = 14.9 * scale
        let height = width * ratio
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0),
                       CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]
        let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon))
        #expect(plan.rotatedCounterClockwise == (ratio >= 1.5))
    }

    @Test(arguments: [33, 48, 99, 157, 319, 320, 641, 1183, 1184, 1185, 1280, 1500])
    func dynamicTensorUsesExactCropWidthWithoutPadding(width: Int) throws {
        let height = 48
        let frame = try #require(NativeOCRRGBAFrame(
            width: width, height: height,
            bytes: [UInt8](repeating: 255, count: width * height * 4)
        ))
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0),
                       CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]
        let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(
            polygon: polygon, dynamicWidth: true
        ))
        let expectedWidth = min(width, 1184)
        #expect(plan.resizedWidth == expectedWidth)
        #expect(plan.bucket.width == expectedWidth)
        #expect(plan.bucket.timeSteps == (expectedWidth + 3) / 8)
        let tensor = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, plan: plan))
        #expect(tensor.values.count == 3 * 48 * expectedWidth)
        #expect(tensor.resizedWidth == tensor.bucket.width)
    }

    @Test(arguments: [64, 319, 320, 321, 640, 641, 960, 1184])
    func fixedModelTensorPreservesContentLimitWithoutDroppingToSmallerBucket(maximumWidth: Int) throws {
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1500, y: 0),
                       CGPoint(x: 1500, y: 48), CGPoint(x: 0, y: 48)]
        let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(
            polygon: polygon, maximumWidth: maximumWidth
        ))
        let expectedBucket = maximumWidth <= 320 ? 320 : maximumWidth <= 640 ? 640 : 1280
        #expect(plan.resizedWidth == maximumWidth)
        #expect(plan.bucket.width == expectedBucket)
        let variant = try #require(NativeCoreMLRecognitionModelVariant(bucket: plan.bucket, batchSize: 1))
        #expect(variant.functionName == "rec\(expectedBucket)b1")
        #expect(variant.inputShape == [1, 3, 48, expectedBucket])
    }

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
        #expect((1...2).contains(predictor.maximumActivePredictions))
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
        for index in 0..<48 {
            let x = CGFloat(index % 4 * 7 - 9), y = CGFloat(index % 5 * 11 - 8)
            let w = CGFloat(10 + index * 13 % 100), h = CGFloat(12 + index * 29 % 170)
            // Odd indices >= 24 are axis-aligned rectangles and even ones are
            // parallelograms: both have g == h == 0 and skip the division.
            let polygon = index < 24
                ? [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y + 2),
                   CGPoint(x: x + w - 3, y: y + h), CGPoint(x: x + 1, y: y + h - 2)]
                : index.isMultiple(of: 2)
                ? [CGPoint(x: x + 0.5, y: y + 0.25), CGPoint(x: x + w + 0.5, y: y + 3.25),
                   CGPoint(x: x + w + 4.5, y: y + h + 3.25), CGPoint(x: x + 4.5, y: y + h + 0.25)]
                : [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                   CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
            let actual = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, polygon: polygon))
            let reference = try #require(NativeOCRRecognitionSamplingReference.prepare(frame: frame, polygon: polygon))
            #expect(actual.resizedWidth == reference.resizedWidth)
            #expect(actual.rotatedCounterClockwise == reference.rotatedCounterClockwise)
            let identicalFloatBits = actual.values.elementsEqual(reference.values) { $0.bitPattern == $1.bitPattern }
            #expect(identicalFloatBits, "The optimized sampler must preserve every reference Float bit")
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
        // Singleton rec1280b1 chunks share a window, so two predict at once.
        #expect(predictor.maximumActivePredictions == 2)
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

extension NativeOCRRecognitionRegressionTests {
    /// Two in-flight predictions must reproduce the serial pass exactly:
    /// results, cache hits (including crops repeated across adjacent chunks),
    /// function order, and the full audit event sequence.
    @Test(arguments: [false, true])
    func concurrentPredictionsMatchSerialOrderCacheAndAudit(dynamicWidth: Bool) async throws {
        let width = 160, height = 600
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width { bytes[(y * width + x) * 4 + 2] = UInt8(y / 20) }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        // Mixed widths, with every third crop repeating its predecessor's
        // pixels so a later chunk depends on an earlier chunk's insertions.
        // Preserve the fixture's 1200/1800 widths: the reader's 1184 cap merges
        // those buckets and moves duplicate crops into the same prediction.
        let regions = (0..<27).map { index -> NativeCoreMLRecognitionRegion in
            let row = index.isMultiple(of: 3) && index > 0 ? index - 1 : index
            let right = [8, 40, 100, 150][row % 4]
            let y = row * 20
            return NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: [
                CGPoint(x: 0, y: y), CGPoint(x: right, y: y),
                CGPoint(x: right, y: y + 4), CGPoint(x: 0, y: y + 4)
            ])
        }.reversed()
        func run(concurrency: Int) async throws -> (
            [[NativeCoreMLRecognizedRegion]], [NativeCoreMLRecognitionDiagnostics], [String], Int
        ) {
            let predictor = OCRPixelPredictor()
            let audit = OCRRecognitionAuditRecorder()
            let recognizer = try NativeCoreMLRecognizer(
                predictor: predictor,
                dictionary: (0..<NativeCoreMLRecognizer.expectedDictionaryCharacterCount).map { "line-\($0)" },
                recognitionCacheCapacity: 12,
                dynamicWidth: dynamicWidth,
                maximumConcurrentPredictions: concurrency,
                maximumRecognitionWidth: 2_000,
                auditObserver: { audit.append($0) }
            )
            var results: [[NativeCoreMLRecognizedRegion]] = []
            var diagnostics: [NativeCoreMLRecognitionDiagnostics] = []
            // A small cache also exercises eviction between passes.
            for pass in [Array(regions), Array(regions.prefix(9)), Array(regions)] {
                let result = try await recognizer.recognize(frame: frame, regions: pass)
                results.append(result.regions)
                diagnostics.append(result.diagnostics)
            }
            return (results, diagnostics, audit.sequence, predictor.maximumActivePredictions)
        }
        let serial = try await run(concurrency: 1)
        let concurrent = try await run(concurrency: 2)
        #expect(serial.3 == 1)
        #expect(concurrent.0 == serial.0)
        #expect(concurrent.1.map(\.predictedRegions) == serial.1.map(\.predictedRegions))
        #expect(concurrent.1.map(\.cacheHitRegions) == serial.1.map(\.cacheHitRegions))
        #expect(concurrent.1.map(\.modelFunctionSequence) == serial.1.map(\.modelFunctionSequence))
        #expect(concurrent.2 == serial.2)
        #expect(serial.1[0].cacheHitRegions > 0)
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
    private let delay: Duration
    init(delay: Duration = .milliseconds(1)) { self.delay = delay }
    var maximumActivePredictions: Int { lock.withLock { maximumActive } }
    var predictionCount: Int { lock.withLock { count } }

    func predict(input: MLMultiArray) async throws -> NativeCoreMLRecognitionPrediction {
        lock.withLock { active += 1; count += 1; maximumActive = max(maximumActive, active) }
        defer { lock.withLock { active -= 1 } }
        try await Task.sleep(for: delay)
        let source = input.dataPointer.assumingMemoryBound(to: Float.self)
        let batchStride = input.strides[0].intValue
        let timeSteps = (input.shape[3].intValue + 3) / 8
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

private final class OCRExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NativeCoreMLRecognitionExecutionSnapshot] = []
    func append(_ value: NativeCoreMLRecognitionExecutionSnapshot) { lock.withLock { values.append(value) } }
    var snapshot: [NativeCoreMLRecognitionExecutionSnapshot] { lock.withLock { values } }
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
    /// Ordered, comparable rendering of every event.
    var sequence: [String] {
        snapshot.map {
            switch $0 {
            case let .requested(_, region): "req:\(region.sourceIndex)"
            case let .decoded(_, region, text, confidence, _, cacheHit):
                "dec:\(region.sourceIndex):\(text):\(confidence):\(cacheHit)"
            }
        }
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
