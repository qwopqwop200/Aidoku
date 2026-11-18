import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeAppearanceRectangleABITests {
    @Test func clippedTallSourceZeroAngleUsesAcceptedNegativeAngleCoordinates() throws {
        // Source-only clipped polygon geometry, independent of image content.
        let polygon:[CGPoint]=[
            .init(x:0,y:1092.3256885841079),.init(x:0,y:165.10588890419353),
            .init(x:140.95262043992744,y:119.63154233929458),.init(x:196,y:290.2568065477665),
            .init(x:196,y:1108.8283477424984),.init(x:23.299573679076673,y:1164.5452192267753)]
        let rect=try NativeOpenCVAppearanceImageOperations().minimumAreaRectangle(polygon)
        #expect(abs(rect[0]-98)<1e-5)
        #expect(abs(rect[1]-642.0883178710938)<1e-4)
        #expect(abs(rect[2]-1044.91357421875)<1e-3)
        #expect(abs(rect[3]-196)<1e-5)
        #expect(rect[4] == -90)
        #expect(rect[4]>=(-90) && rect[4]<0)
    }
}
