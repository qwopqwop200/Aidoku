import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeShadowedSourceOutlineTests {
    private func pixels(counters: Bool = false, open: Bool = false, grayFill: Bool = false) -> [UInt8] {
        let width = 180, height = 96
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: [UInt8]) {
            for row in y..<(y + h) { for column in x..<(x + w) {
                let i = (row * width + column) * 4
                for c in 0..<3 { rgba[i + c] = color[c] }
            } }
        }
        for column in 0..<4 {
            let x = 16 + column * 38
            if counters {
                rect(x, 24, 18, 18, [223, 90, 6])
                rect(x + 2, 26, 14, 14, [165, 165, 165])
                rect(x + 3, 27, 12, 12, [250, 250, 250])
            } else {
                rect(x, 24, 12, 26, [223, 90, 6])
                rect(x + 2, 26, 8, 22, [165, 165, 165])
                rect(x + 3, 27, 6, 20, grayFill ? [165, 165, 165] : [250, 250, 250])
                if open { rect(x + 4, 24, 3, 4, [255, 255, 255]) }
            }
        }
        return rgba
    }

    private func observe(_ rgba: [UInt8]) -> [String: Any]? {
        NativeSourceOutlineEvidence.enclosedCaptionOutline(rgba: rgba, width: 180, height: 96,
            box: [8, 8, 172, 88], glyph: 24, ink: [223, 90, 6])
    }

    @Test func closedWhiteFilamentsSurviveAnInnerNeutralShadow() throws {
        let original = pixels(), evidence = try #require(observe(original))
        #expect(evidence["foreground"] as? [Double] == [250, 250, 250])
        #expect(evidence["stroke"] as? [Double] == [223, 90, 6])
        #expect(evidence["components"] as? Double == 4)
        #expect(evidence["filaments"] as? Double == 4)
        #expect(original == pixels())
        let sample: [String: Any] = ["foreground": [223.0, 90, 6], "confidence": ["foreground": 0.9]]
        func style(_ mode: String) -> NativeTranslationSourceStylePostPolish.Outline? {
            NativeTranslationSourceStylePostPolish.lateSourceOutline(sample: sample, font: 8.25,
                eligible: true, keepsSourceLettering: false, rotation: 0, displayLettering: false,
                backgroundKind: mode, appliedBackground: nil, surfaceRange: nil,
                ring: nil, enclosed: evidence, certifiedSourcePosition: false).outline
        }
        #expect(style("readability-panel") == nil, "Color observation cannot release or bypass a retained plate")
        #expect(style("inpainted")?.foreground == [250, 250, 250])
    }

    @Test func counterholesAndUnenclosedOrUnobservedFillRemainRejected() {
        #expect(observe(pixels(counters: true)) == nil, "Round letter counters are not white glyph filaments")
        #expect(observe(pixels(open: true)) == nil, "A gap to the exterior is not an enclosing ring")
        #expect(observe(pixels(grayFill: true)) == nil, "A bright fill must be observed, never invented")
    }
}
