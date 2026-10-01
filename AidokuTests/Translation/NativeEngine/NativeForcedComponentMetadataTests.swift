import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeForcedComponentMetadataTests {
    private func palette(_ ink: [String: Any]) -> NativeRestorationPixels.Palette {
        .init(foreground: NativeRestorationRGB([20,20,20]), background: NativeRestorationRGB([255,255,255]),
              stroke: NativeRestorationRGB([255,255,255]), metadata: ["foreground": [20.0,20,20],
              "background": [255.0,255,255], "stroke": [255.0,255,255],
              "confidence": ["background": 0.9,"stroke": 0.9], "sourceInk": ink])
    }
    private func mask(_ palette: NativeRestorationPixels.Palette) -> NativeSourceGlyphSegmentation.Result? {
        let w = 80, h = 110
        var rgba = [UInt8](repeating: 255, count: w*h*4)
        for index in 0..<5 {
            for y in (15+index*16)..<(26+index*16) {
                for x in 22..<31 {
                    for channel in 0..<3 { rgba[(y*w+x)*4+channel] = 150 }
                }
            }
        }
        return NativeSourceGlyphSegmentation.forcedTextMask(rgba: rgba,width: w,height: h,
            box: CGRect(x:17,y:11,width:20,height:85),
            palette: NativeResidualProof.componentSegmentationPalette(palette))
    }

    @Test func nestedBackgroundConfidenceControlsActualSegmentationAdmission() {
        var ink: [String: Any] = ["foreground": [150.0,150,150], "background": [255.0,255,255],
                                 "confidence": ["background": 0.0]]
        #expect(mask(palette(ink)) == nil)
        ink["confidence"] = ["background": 0.9]
        #expect(mask(palette(ink)) != nil)
    }

    @Test func absentNestedBackgroundDoesNotBorrowObservedDisplayPaper() {
        let sample = palette(["foreground": [150.0,150,150], "confidence": ["background": 0.9]])
        let actual = NativeResidualProof.componentSegmentationPalette(sample)
        #expect(actual.sourceInk?.background == nil)
        #expect(mask(sample) == nil)
    }

    @Test func nestedStrokeAndOutlineRemainOriginalHypothesis() {
        let outline = [240.0,230,225], stroke = [190.0,180,170]
        let actual = NativeResidualProof.componentSegmentationPalette(palette([
            "foreground": [150.0,150,150], "background": [250.0,245,230],
            "stroke": stroke, "outline": outline, "confidence": ["background": 0.2]]))
        #expect(actual.sourceInk?.stroke == stroke && actual.sourceInk?.outline == outline)
        #expect(actual.sourceInk?.backgroundConfidence == 0.2)
        let absent = NativeResidualProof.componentSegmentationPalette(palette(["foreground": [20.0,20,20]]))
        #expect(absent.sourceInk?.stroke == nil && absent.sourceInk?.outline == nil)
        #expect(absent.sourceInk?.backgroundConfidence == 0)
    }

    @Test func missingNestedForegroundDoesNotBorrowDisplayInk() {
        let sample = palette(["background": [255.0,255,255], "confidence": ["background": 0.9]])
        #expect(NativeResidualProof.componentSegmentationPalette(sample).sourceInk?.foreground.isEmpty == true)
        #expect(mask(sample) == nil)
    }
}
