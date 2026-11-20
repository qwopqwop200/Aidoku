import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRRecognitionRegressionTests {
    @Test(arguments: [1.0, 4.0])
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

    @Test(arguments: [33, 641, 1184, 1500])
    func dynamicTensorUsesExactCropWidthWithoutPadding(width: Int) throws {
        let height = 48
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height,
            bytes: [UInt8](repeating: 255, count: width * height * 4)))
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0),
                       CGPoint(x: width, y: height), CGPoint(x: 0, y: height)]
        let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true))
        let expectedWidth = min(width, 1184)
        #expect(plan.resizedWidth == expectedWidth)
        #expect(plan.bucket.width == expectedWidth)
        #expect(plan.bucket.timeSteps == (expectedWidth + 3) / 8)
        let tensor = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, plan: plan))
        #expect(tensor.values.count == 3 * 48 * expectedWidth)
        #expect(tensor.resizedWidth == tensor.bucket.width)
    }

    // Non-finite or huge recognizer quads must fail closed instead of trapping on Int conversion.
    @Test func overflowingGeometryIsRejectedOrBoundedBeforeIntegerConversion() throws {
        #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 1e20, y: 0),
            CGPoint(x: 1e20, y: 30), CGPoint(x: 0, y: 30)]) == nil)
        let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: [CGPoint(x: 0, y: 0),
            CGPoint(x: 1e18, y: 0), CGPoint(x: 1e18, y: 2), CGPoint(x: 0, y: 2)],
            dynamicWidth: true, maximumWidth: IPhoneOCRSettings.defaultRecognizerMaximumWidth))
        #expect(plan.resizedWidth == 1_184)
        #expect(plan.bucket.timeSteps == 148)
        for extreme in [Int.min, -1, Int.max] {
            #expect(NativeCoreMLRecognitionBucket.containing(desiredWidth: Int.max, dynamicWidth: true,
                maximumWidth: extreme).width == (extreme <= 32 ? 32 : 2_400))
            #expect(NativeCoreMLRecognitionBucket.containing(desiredWidth: extreme, dynamicWidth: true,
                maximumWidth: 1_280).width == (extreme <= 32 ? 32 : 1_280))
        }
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
            let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon))
            let actual = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, plan: plan))
            let reference = try #require(NativeOCRRecognitionSamplingReference.prepare(frame: frame, polygon: polygon))
            #expect(actual.resizedWidth == reference.resizedWidth)
            #expect(actual.rotatedCounterClockwise == reference.rotatedCounterClockwise)
            let identicalFloatBits = actual.values.elementsEqual(reference.values) { $0.bitPattern == $1.bitPattern }
            #expect(identicalFloatBits, "The optimized sampler must preserve every reference Float bit")
        }
    }
}
