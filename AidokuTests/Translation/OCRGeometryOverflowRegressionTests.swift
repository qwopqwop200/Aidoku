import CoreGraphics
import Testing
@testable import Aidoku

struct OCRGeometryOverflowRegressionTests {
    @Test func rejectsFiniteCoordinatesOutsideIntegerRange() {
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1e20, y: 0),
                       CGPoint(x: 1e20, y: 30), CGPoint(x: 0, y: 30)]
        #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon) == nil)
    }

    @Test func boundsExtremeAspectRatioBeforeIntegerConversion() throws {
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1e18, y: 0),
                       CGPoint(x: 1e18, y: 2), CGPoint(x: 0, y: 2)]
        let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(
            polygon: polygon, dynamicWidth: true, maximumWidth: 2_000
        ))
        // Explicit offline fixtures preserve the model's 2,000-pixel ceiling;
        // the former 1,984 limit came from rounding down to a 32-pixel grid.
        #expect(plan.resizedWidth == 2_000)
        #expect(plan.bucket.width == 2_000)
        #expect(plan.bucket.timeSteps == 250)

        // The same finite geometry must also respect the reader's smaller ceiling.
        let readerPlan = try #require(NativeCoreMLRecognitionPreprocessor.plan(
            polygon: polygon,
            dynamicWidth: true,
            maximumWidth: IPhoneOCRSettings.defaultRecognizerMaximumWidth
        ))
        #expect(readerPlan.resizedWidth == 1_184)
        #expect(readerPlan.bucket.width == 1_184)
        #expect(readerPlan.bucket.timeSteps == 148)
    }

    @Test(arguments: [Int.min, -1, 0, 31, 32, 2_001, Int.max])
    func dynamicBucketClampsExtremeMaximumBeforeForceUnwrapping(maximumWidth: Int) {
        let bucket = NativeCoreMLRecognitionBucket.containing(
            desiredWidth: Int.max, dynamicWidth: true, maximumWidth: maximumWidth
        )
        #expect(bucket.width == (maximumWidth <= 32 ? 32 : 2_000))
    }

    @Test(arguments: [Int.min, -1, 0, 31, Int.max])
    func dynamicBucketBoundsDesiredWidthBeforeArithmetic(desiredWidth: Int) {
        let bucket = NativeCoreMLRecognitionBucket.containing(
            desiredWidth: desiredWidth, dynamicWidth: true, maximumWidth: 1_280
        )
        #expect(bucket.width == (desiredWidth <= 32 ? 32 : 1_280))
    }
}
