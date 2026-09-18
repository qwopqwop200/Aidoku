import CoreGraphics
import Foundation
import XCTest
@testable import Aidoku
final class NativeCoreMLDetectorSafetyTests: XCTestCase {
    func testPipelinePassesThresholdChangesWithoutRecreatingModels() async throws {
        let frame = try XCTUnwrap(NativeOCRRGBAFrame(width: 16, height: 16, bytes: [UInt8](repeating: 255, count: 16 * 16 * 4)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let pipeline = NativeCoreMLOCRPipeline(detector: ThresholdProbeDetector(),
                                              postprocessConfiguration: .tiny, frameConverter: { _ in frame })
        let custom = ReaderOCRConfiguration(detectorPixelThreshold: 0.45, detectorConfidenceThreshold: 0.8, detectorMinimumBoxSide: 7)
            .detectorPostprocessConfiguration
        let operations: [() async throws -> NativeCoreMLOCRResult] = [
            { try await pipeline.recognize(image: image, requestID: "image", confidenceThreshold: 0.75,
                                           detectorConfiguration: custom) },
            { try await pipeline.recognize(frame: frame, requestID: "frame", confidenceThreshold: 0.75,
                                           detectorConfiguration: custom) },
            { try await pipeline.recognize(image: image, requestID: "image-scopes", confidenceThreshold: 0.75,
                                           detectorConfiguration: custom, recognitionScopes: [.zero]) },
            { try await pipeline.recognize(frame: frame, requestID: "frame-scopes", confidenceThreshold: 0.75,
                                           detectorConfiguration: custom, recognitionScopes: [.zero]) },
            { try await pipeline.recognize(frame: frame, requestID: "default", confidenceThreshold: 0.75) }
        ]
        for (index, operation) in operations.enumerated() {
            do {
                _ = try await operation()
                XCTFail("Expected the detector probe to capture this request")
            } catch let probe as ThresholdProbeResult {
                XCTAssertEqual(probe.configuration, index == 4 ? .tiny : custom)
            }
        }
    }

    func testMinimumDetectionSizeUsesMapPixelsAndCanRecoverSmallText() throws {
        let map = rectangularMap(width: 32, height: 32,
                                 rectangle: CGRect(x: 4, y: 4, width: 12, height: 3), foreground: 0.9)
        var settings = ReaderOCRConfiguration()
        for scale in [1, 10] {
            settings.detectorMinimumBoxSide = 3
            let original = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 32 * scale, sourceHeight: 32 * scale,
                                                                 configuration: settings.detectorPostprocessConfiguration)
            XCTAssertTrue(original.boxes.isEmpty)
            settings.detectorMinimumBoxSide = 2
            let relaxed = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 32 * scale, sourceHeight: 32 * scale,
                                                                configuration: settings.detectorPostprocessConfiguration)
            XCTAssertEqual(relaxed.boxes.count, 1)
        }
    }

    func testMinimumDetectionSizeAlsoControlsExpandedBoxGate() throws {
        let map = rectangularMap(width: 32, height: 32,
                                 rectangle: CGRect(x: 4, y: 4, width: 3, height: 3), foreground: 0.9)
        for minimum in [1.0, 2.0] {
            let settings = ReaderOCRConfiguration(detectorMinimumBoxSide: minimum)
            let result = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 32, sourceHeight: 32,
                                                               configuration: settings.detectorPostprocessConfiguration)
            // Both candidates have a short side of 2. Expansion reaches 3.5;
            // the expanded gate retains its original minimum + 2 relationship.
            XCTAssertEqual(result.boxes.count, minimum == 1 ? 1 : 0)
        }
    }

    func testMinimumDetectionSizeAppliesToWeakSplitParts() throws {
        var pixels = [Float](repeating: 0, count: 64 * 100)
        fill(&pixels, mapWidth: 64, rectangle: CGRect(x: 4, y: 4, width: 10, height: 50), value: 0.95)
        fill(&pixels, mapWidth: 64, rectangle: CGRect(x: 20, y: 35, width: 10, height: 50), value: 0.95)
        fill(&pixels, mapWidth: 64, rectangle: CGRect(x: 13, y: 40, width: 8, height: 1), value: 0.95)
        let map = NativeCoreMLDetectionMap(width: 64, height: 100, values: pixels)
        for minimum in [3.0, 20.0] {
            let settings = ReaderOCRConfiguration(detectorMinimumBoxSide: minimum)
            let result = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 64, sourceHeight: 100,
                                                               configuration: settings.detectorPostprocessConfiguration,
                                                               allowsWeakBridgeSplit: true)
            XCTAssertEqual(result.boxes.count, minimum == 3 ? 2 : 0)
        }
    }

    func testUserPixelAndRegionThresholdsFilterDifferentStages() throws {
        let map = rectangularMap(width: 32, height: 32,
                                 rectangle: CGRect(x: 4, y: 4, width: 12, height: 8), foreground: 0.5)
        func decode(_ settings: ReaderOCRConfiguration) throws -> NativeCoreMLDBPostprocessResult {
            try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 32, sourceHeight: 32,
                                                  configuration: settings.detectorPostprocessConfiguration)
        }
        var settings = ReaderOCRConfiguration()
        let rejectedRegion = try decode(settings)
        XCTAssertEqual(rejectedRegion.candidateComponents, 1)
        XCTAssertTrue(rejectedRegion.boxes.isEmpty)
        settings.detectorConfidenceThreshold = 0.45
        XCTAssertEqual(try decode(settings).boxes.count, 1)
        settings.detectorPixelThreshold = 0.55
        let rejectedPixels = try decode(settings)
        XCTAssertEqual(rejectedPixels.candidateComponents, 0)
        XCTAssertTrue(rejectedPixels.boxes.isEmpty)
        XCTAssertEqual(settings.confidenceThreshold, 0.75)
    }

    func testDBPostprocessFindsScoresAndUnclipsRectangle() throws {
        let map = rectangularMap(
            width: 64,
            height: 64,
            rectangle: CGRect(x: 10, y: 20, width: 20, height: 10),
            foreground: 0.9
        )

        let result = try NativeCoreMLDBPostprocessor.decode(
            map: map,
            sourceWidth: 64,
            sourceHeight: 64
        )

        XCTAssertEqual(result.candidateComponents, 1)
        let box = try XCTUnwrap(result.boxes.first)
        XCTAssertEqual(result.boxes.count, 1)
        XCTAssertEqual(box.score, 0.9, accuracy: 0.000_01)
        XCTAssertEqual(box.polygon.count, 4)
        XCTAssertEqual(box.polygon.map(\.x).min(), 5)
        XCTAssertEqual(box.polygon.map(\.x).max(), 34)
        XCTAssertEqual(box.polygon.map(\.y).min(), 15)
        XCTAssertEqual(box.polygon.map(\.y).max(), 34)
    }

    func testDBPostprocessUsesStrictMaskAndBoxThresholds() throws {
        let exactlyMaskThreshold = rectangularMap(
            width: 32,
            height: 32,
            rectangle: CGRect(x: 4, y: 4, width: 12, height: 8),
            foreground: 0.25
        )
        let belowBoxThreshold = rectangularMap(
            width: 32,
            height: 32,
            rectangle: CGRect(x: 4, y: 4, width: 12, height: 8),
            foreground: 0.5
        )
        let configuration = NativeCoreMLDBPostprocessConfiguration(
            threshold: 0.25,
            boxThreshold: 0.6,
            unclipRatio: 1.5,
            maximumCandidates: 3_000
        )

        let maskResult = try NativeCoreMLDBPostprocessor.decode(
            map: exactlyMaskThreshold,
            sourceWidth: 32,
            sourceHeight: 32,
            configuration: configuration
        )
        let scoreResult = try NativeCoreMLDBPostprocessor.decode(
            map: belowBoxThreshold,
            sourceWidth: 32,
            sourceHeight: 32,
            configuration: configuration
        )

        XCTAssertEqual(maskResult.candidateComponents, 0)
        XCTAssertTrue(maskResult.boxes.isEmpty)
        XCTAssertEqual(scoreResult.candidateComponents, 1)
        XCTAssertTrue(scoreResult.boxes.isEmpty)
    }

    func testDBPostprocessHonorsCandidateBound() throws {
        var values = [Float](repeating: 0, count: 64 * 64)
        for origin in [CGPoint(x: 2, y: 2), CGPoint(x: 20, y: 2), CGPoint(x: 38, y: 2)] {
            fill(
                &values,
                mapWidth: 64,
                rectangle: CGRect(origin: origin, size: CGSize(width: 5, height: 5)),
                value: 0.95
            )
        }
        let map = NativeCoreMLDetectionMap(
            width: 64,
            height: 64,
            values: values
        )
        let configuration = NativeCoreMLDBPostprocessConfiguration(
            threshold: 0.3,
            boxThreshold: 0.6,
            unclipRatio: 1.5,
            maximumCandidates: 2
        )

        let result = try NativeCoreMLDBPostprocessor.decode(
            map: map,
            sourceWidth: 64,
            sourceHeight: 64,
            configuration: configuration
        )

        XCTAssertEqual(result.candidateComponents, 2)
        XCTAssertEqual(result.boxes.count, 2)
    }

    func testDBRunSpansPreserveEightConnectedComponents() throws {
        var values = [Float](repeating: 0, count: 48 * 32)
        // These two blocks touch only at one diagonal pixel and therefore
        // belong to the same 8-connected component.
        fill(
            &values,
            mapWidth: 48,
            rectangle: CGRect(x: 3, y: 3, width: 6, height: 6),
            value: 0.95
        )
        fill(
            &values,
            mapWidth: 48,
            rectangle: CGRect(x: 9, y: 9, width: 6, height: 6),
            value: 0.95
        )
        // A separate component verifies that run expansion does not bridge a
        // true horizontal gap.
        fill(
            &values,
            mapWidth: 48,
            rectangle: CGRect(x: 28, y: 5, width: 8, height: 7),
            value: 0.95
        )
        let map = NativeCoreMLDetectionMap(
            width: 48,
            height: 32,
            values: values
        )

        let result = try NativeCoreMLDBPostprocessor.decode(
            map: map,
            sourceWidth: 48,
            sourceHeight: 32,
            configuration: NativeCoreMLDBPostprocessConfiguration(
                threshold: 0.3,
                boxThreshold: 0.2,
                unclipRatio: 1.5,
                maximumCandidates: 3_000
            )
        )

        XCTAssertEqual(result.candidateComponents, 2)
        XCTAssertEqual(result.boxes.count, 2)
    }

    func testDBPostprocessChecksCancellationDuringWork() {
        let map = rectangularMap(
            width: 128,
            height: 128,
            rectangle: CGRect(x: 4, y: 4, width: 100, height: 100),
            foreground: 0.95
        )
        var checks = 0

        XCTAssertThrowsError(
            try NativeCoreMLDBPostprocessor.decode(
                map: map,
                sourceWidth: 128,
                sourceHeight: 128,
                cancellationCheck: {
                    checks += 1
                    if checks == 2 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }


    func fill(_ values: inout [Float], mapWidth: Int, rectangle: CGRect, value: Float) {
        for y in Int(rectangle.minY)..<Int(rectangle.maxY) {
            for x in Int(rectangle.minX)..<Int(rectangle.maxX) { values[y * mapWidth + x] = value }
        }
    }
    func rectangularMap(width: Int, height: Int, rectangle: CGRect, foreground: Float) -> NativeCoreMLDetectionMap {
        var values = [Float](repeating: 0, count: width * height)
        fill(&values, mapWidth: width, rectangle: rectangle, value: foreground)
        return NativeCoreMLDetectionMap(width: width, height: height, values: values)
    }
}

private struct ThresholdProbeResult: Error {
    let configuration: NativeCoreMLDBPostprocessConfiguration
}

private final class ThresholdProbeDetector: NativeCoreMLDetecting {
    func detect(frame: NativeOCRRGBAFrame, requestID: String, configuration: NativeCoreMLDBPostprocessConfiguration,
                cancellationCheck: @escaping @Sendable () throws -> Void) async throws -> NativeCoreMLDetectionResult {
        try cancellationCheck()
        throw ThresholdProbeResult(configuration: configuration)
    }
    func cancelCurrent() {}
    func purgeResources() async {}
}

extension NativeCoreMLDetectorSafetyTests {
    func bridgeMap(extra: Bool = false) -> NativeCoreMLDetectionMap {
        var v = [Float](repeating: 0, count: 140 * 210)
        fill(&v, mapWidth: 140, rectangle: CGRect(x: 10, y: 10, width: 20, height: 101), value: 0.95)
        fill(&v, mapWidth: 140, rectangle: CGRect(x: 44, y: 70, width: 20, height: 101), value: 0.95)
        fill(&v, mapWidth: 140, rectangle: CGRect(x: 29, y: 80, width: 16, height: 1), value: 0.95)
        if extra { fill(&v, mapWidth: 140, rectangle: CGRect(x: 100, y: 185, width: 11, height: 16), value: 0.95) }
        return NativeCoreMLDetectionMap(width: 140, height: 210, values: v)
    }
    func testWeakSplitDefaultDisabledAndExplicitBudget() throws {
        let map = bridgeMap(extra: true)
        let config = NativeCoreMLDBPostprocessConfiguration(threshold: 0.3, boxThreshold: 0.6, unclipRatio: 1.5, maximumCandidates: 2)
        let disabled = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 140, sourceHeight: 210, configuration: config)
        let enabled = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 140, sourceHeight: 210, configuration: config, allowsWeakBridgeSplit: true)
        XCTAssertEqual(disabled.boxes.count, 1)
        XCTAssertEqual(enabled.boxes.count, 2)
        XCTAssertEqual(enabled.candidateComponents, 2)
    }
    func testWeakSplitDirtyWindowParity() throws {
        let map = bridgeMap()
        let full = try NativeCoreMLDBPostprocessor.decode(map: map, sourceWidth: 140, sourceHeight: 210, allowsWeakBridgeSplit: true)
        var values: [Float] = []
        for y in 5..<180 { values += Array(map.values[(y * 140 + 5)..<(y * 140 + 70)]) }
        let local = try NativeCoreMLDBPostprocessor.decode(map: .init(width: 65, height: 175, values: values), sourceWidth: 140, sourceHeight: 210, geometry: .init(originX: 5, originY: 5, fullWidth: 140, fullHeight: 210), allowsWeakBridgeSplit: true)
        XCTAssertEqual(full, local)
    }
    func testWeakSplitAdditionalScansPropagateCancellation() throws {
        let w = 1100, h = 1600
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<1040 where (x < 400 || x >= 640) && (x + y) % 2 == 0 { values[y * w + x] = 0.95 } }
        for x in 399...641 { values[800 * w + x] = 0.95 }
        var checks = 0
        XCTAssertThrowsError(try NativeCoreMLDBPostprocessor.decode(map: .init(width: w, height: h, values: values), sourceWidth: w, sourceHeight: h, allowsWeakBridgeSplit: true, cancellationCheck: {
            checks += 1
            if checks == 1000 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 1000)
    }
    func inside(_ p: CGPoint, polygon: [CGPoint], tolerance: Double = 1.5) -> Bool {
        var signs: [Double] = []
        for i in 0..<4 {
            let a = polygon[i], b = polygon[(i + 1) % 4]
            let cross = Double((b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x))
            let length = hypot(Double(b.x-a.x), Double(b.y-a.y))
            signs.append(cross / max(1, length))
        }
        return signs.allSatisfy { $0 >= -tolerance } || signs.allSatisfy { $0 <= tolerance }
    }
    func testRotatedWeakSplitsAreConvexNonzeroAndContainLobes() throws {
        let original = bridgeMap(); var exercised = 0
        for degrees in [-10.0, -5, 0, 5, 10] {
            let angle = degrees * .pi / 180, c = cos(angle), s = sin(angle)
            let n = 320
            var values = [Float](repeating: 0, count: n * n)
            var lobePoints: [CGPoint] = []
            for y in 0..<n { for x in 0..<n {
                let dx = Double(x)-160, dy = Double(y)-160
                let ox = Int((dx*c+dy*s+37).rounded()), oy = Int((-dx*s+dy*c+90).rounded())
                if ox >= 0 && ox < original.width && oy >= 0 && oy < original.height {
                    values[y*n+x] = original.values[oy*original.width+ox]
                    if (10...29).contains(ox) && (10...110).contains(oy) || (44...63).contains(ox) && (70...170).contains(oy) { lobePoints.append(CGPoint(x:x,y:y)) }
                }
            } }
            let result = try NativeCoreMLDBPostprocessor.decode(map: .init(width:n,height:n,values:values), sourceWidth:n,sourceHeight:n,allowsWeakBridgeSplit:true)
            if result.boxes.count != 2 { continue }
            exercised += 1
            for box in result.boxes {
                XCTAssertEqual(box.polygon.count,4)
                var area: CGFloat = 0, crosses: [CGFloat] = []
                for i in 0..<4 {
                    let a=box.polygon[i], b=box.polygon[(i+1)%4], c=box.polygon[(i+2)%4]
                    area += a.x*b.y-b.x*a.y
                    crosses.append((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x))
                    XCTAssertTrue(a.x.isFinite && a.y.isFinite && a.x>=0 && a.y>=0 && a.x<=CGFloat(n) && a.y<=CGFloat(n))
                }
                XCTAssertGreaterThan(abs(area),1)
                XCTAssertTrue(crosses.allSatisfy{$0>=0} || crosses.allSatisfy{$0<=0})
            }
            XCTAssertTrue(lobePoints.allSatisfy { point in result.boxes.contains { inside(point,polygon:$0.polygon) } }, "Lobe clipped at angle \(degrees)")
        }
        XCTAssertGreaterThanOrEqual(exercised,3)
    }
}
