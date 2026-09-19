import CoreGraphics
import Testing
@testable import Aidoku

struct OCRGeometryOverflowRegressionTests {
    @Test func rejectsFiniteCoordinatesOutsideIntegerRange() {
        guard #available(iOS 18.0, *) else { return }
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1e20, y: 0),
                       CGPoint(x: 1e20, y: 30), CGPoint(x: 0, y: 30)]
        #expect(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon) == nil)
    }

    @Test func boundsExtremeAspectRatioBeforeIntegerConversion() throws {
        guard #available(iOS 18.0, *) else { return }
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 1e18, y: 0),
                       CGPoint(x: 1e18, y: 2), CGPoint(x: 0, y: 2)]
        let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon, dynamicWidth: true))
        #expect(plan.resizedWidth == 1_984)
        #expect(plan.bucket.width == 1_984)
    }
}
