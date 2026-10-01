import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeSourceCanvasImageFrameTests {
    // Seven immutable iOS42 DOM/image-Do controls. The eighth is a separate
    // actual macOS negative-half capture, awaiting the iOS43 signed-tie gate.
    @Test(arguments: Array(0..<8))
    func imageEdgesMatchCapturedCanvasDestinations(index: Int) {
        let dom: [CGRect] = [
            CGRect(x: 362.546875, y: 222.34375, width: 67.5, height: 86.34375),
            CGRect(x: 180, y: 159.984375, width: 100, height: 99.984375),
            CGRect(x: 210.25, y: 340.25, width: 100.25, height: 99.25),
            CGRect(x: 179.75, y: 479.75, width: 100.25, height: 99.25),
            CGRect(x: 212, y: 665, width: 20, height: 30),
            CGRect(x: 210, y: 820, width: 0.015625, height: 5),
            CGRect(x: -10.25, y: -10.25, width: 100.25, height: 99.25),
            CGRect(x: -10.5, y: -10.5, width: 100.25, height: 99.25)
        ]
        let expected: [CGRect?] = [
            CGRect(x: 363, y: 222, width: 67, height: 87),
            CGRect(x: 180, y: 160, width: 100, height: 100),
            CGRect(x: 210, y: 340, width: 101, height: 100),
            CGRect(x: 180, y: 480, width: 100, height: 99),
            CGRect(x: 212, y: 665, width: 20, height: 30),
            nil,
            CGRect(x: -10, y: -10, width: 100, height: 99),
            CGRect(x: -10, y: -10, width: 100, height: 99)
        ]
        #expect(NativeSourceCanvasImageFrame.liveFrame(domRect: dom[index]) == expected[index])
    }
}
