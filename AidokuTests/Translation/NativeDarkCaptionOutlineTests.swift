import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeDarkCaptionOutlineTests {
    private func pixels(counters: Bool = false, open: Bool = false, grayHalo: Bool = false) -> [UInt8] {
        let width = 180, height = 96
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { rgba[i * 4 + 3] = 255 }
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt8) {
            for row in y..<(y + h) { for column in x..<(x + w) {
                let i = (row * width + column) * 4
                for c in 0..<3 { rgba[i + c] = color }
            } }
        }
        for column in 0..<4 {
            let x = 16 + column * 38
            if counters {
                rect(x, 24, 18, 18, grayHalo ? 180 : 250)
                rect(x + 3, 27, 12, 12, 5)
            } else {
                rect(x, 24, 12, 26, grayHalo ? 180 : 250)
                rect(x + 2, 26, 8, 22, 100)
                rect(x + 3, 27, 6, 20, 5)
                if open { rect(x + 4, 24, 3, 4, 0) }
            }
        }
        return rgba
    }

    private func observe(_ rgba: [UInt8]) -> [String: Any]? {
        NativeSourceOutlineEvidence.enclosedDarkCaptionOutline(rgba: rgba, width: 180, height: 96,
            box: [8, 8, 172, 88], glyph: 24, background: [0, 0, 0])
    }

    private var sample: [String: Any] {
        ["foreground": NSNull(), "background": [0.0, 0, 0], "captionBackground": [0.0, 0, 0],
         "confidence": ["foreground": 0.0, "stroke": 0, "background": 1],
         "displayEvidence": ["color": [250.0, 250, 250]], "lettering": ["color": [5.0, 5, 5]]]
    }

    @Test func observedDarkFilamentsRetainTheirWhiteHaloOnDarkSurface() throws {
        let original = pixels(), evidence = try #require(observe(original))
        #expect(evidence["foreground"] as? [Double] == [5, 5, 5])
        #expect(evidence["stroke"] as? [Double] == [250, 250, 250])
        #expect(evidence["components"] as? Double == 4)
        #expect(evidence["filaments"] as? Double == 4)
        #expect(original == pixels(), "Source observation never paints or changes ownership")
        let selection = NativeTranslationSourceStylePostPolish.lateSourceOutline(sample: sample, font: 9,
            eligible: true, keepsSourceLettering: false, rotation: 0, displayLettering: false,
            backgroundKind: "inpainted", appliedBackground: nil, surfaceRange: nil,
            ring: nil, enclosed: evidence, certifiedSourcePosition: true, appliedForeground: [5, 5, 5])
        let style = try #require(selection.outline), stroke = style.stroke
        #expect(style.foreground == [5, 5, 5])
        #expect(stroke == [250, 250, 250])
        #expect(style.width == 2)
        #expect(selection.darkPreserved, "Accepted dark source evidence must reach final stroke reconciliation")
        let observed = NativeTranslationSourceStylePostPolish.Stroke(id: "observed", key: "dark-source",
            glyph: 24, font: 9, width: style.width, fill: style.foreground, stroke: stroke,
            preserved: true, darkMeasured: selection.darkPreserved)
        let ordinary = NativeTranslationSourceStylePostPolish.Stroke(id: "ordinary", key: "ordinary",
            glyph: 24, font: 9, width: style.width, fill: style.foreground, stroke: stroke,
            preserved: true, darkMeasured: false)
        let final = NativeTranslationSourceStylePostPolish.strokeWidths([observed, ordinary])
        #expect(final.first { $0.id == "observed" }?.width == 2, "Measured white source halo survives the existing dark-style cap")
        #expect(final.first { $0.id == "ordinary" }?.width == 1.8, "Ordinary preserved outlines keep the original font-relative cap")
    }

    @Test func roundCountersOpenOutlinesAndGrayHalosDoNotProveWhiteGlyphOutlines() {
        #expect(observe(pixels(counters: true)) == nil, "Round counters do not establish dark stroke interiors")
        #expect(observe(pixels(open: true)) == nil, "Dark canvas remains connected through an open halo")
        #expect(observe(pixels(grayHalo: true)) == nil, "A white halo must be present in the source")
        #expect(NativeSourceOutlineEvidence.enclosedDarkCaptionOutline(rgba: [], width: Int.max, height: Int.max,
            box: [0, 0, 1, 1], glyph: 24, background: [0, 0, 0]) == nil, "Invalid dimensions fail before pixel-count multiplication")
        #expect(NativeSourceOutlineEvidence.enclosedDarkCaptionOutline(rgba: [], width: 8, height: 0,
            box: [0, 0, 1, 1], glyph: 24, background: [0, 0, 0]) == nil, "Empty dimensions fail before the budget division")
    }

    @Test func earlyObservationRequiresFinalDarkInkDarkBackgroundAndSourcePositionProof() throws {
        func scan(foreground: [Double], proof: Bool, background: [Double] = [0, 0, 0]) -> NativeSourceOutlineScan.Analysis? {
            var observed = sample
            observed["background"] = background; observed["captionBackground"] = background
            let record = NativeSourceOutlineScan.Record(id: "caption", sourceBounds: [0, 0, 1, 1],
                sourceFrame: CGRect(x: 0, y: 0, width: 180, height: 96), sourceFontSize: 24,
                sourceVertical: true, sourceColorEligible: true, visible: true, backgroundKind: "inpainted",
                appliedForeground: foreground, appliedStrokeWidth: 1, opaquePlate: nil, sample: observed,
                partialMainbodyProof: proof ? "outlined-source-position" : nil)
            return NativeSourceOutlineScan.scan(records: [record], imageSize: CGSize(width: 180, height: 96), displayFrame: nil) { _, w, h in
                #expect(w == 180 && h == 96)
                return pixels()
            }["caption"]
        }
        let admitted = try #require(scan(foreground: [250, 250, 250], proof: true))
        #expect(admitted.enclosed?["polarity"] as? String == "dark-on-dark")
        func finalStyle(_ foreground: [Double], proof: Bool = true, mode: String = "inpainted") -> NativeTranslationSourceStylePostPolish.Outline? {
            NativeTranslationSourceStylePostPolish.lateSourceOutline(sample: sample, font: 9,
                eligible: true, keepsSourceLettering: false, rotation: 0, displayLettering: false,
                backgroundKind: mode, appliedBackground: nil, surfaceRange: nil,
                ring: admitted.ringData, enclosed: admitted.enclosed, certifiedSourcePosition: proof,
                appliedForeground: foreground).outline
        }
        #expect(finalStyle([5, 5, 5])?.width == 2, "Late source-polarity recovery uses the already observed halo")
        #expect(finalStyle([250, 250, 250]) == nil, "Observed white lettering keeps its established polarity")
        #expect(finalStyle([5, 5, 5], proof: false) == nil, "A final source-position proof remains required")
        #expect(finalStyle([5, 5, 5], mode: "readability-panel") == nil, "Observation cannot release a retained panel")
        #expect(scan(foreground: [5, 5, 5], proof: false)?.enclosed == nil, "Color alone cannot certify source position")
        #expect(scan(foreground: [5, 5, 5], proof: true, background: [180, 180, 180])?.enclosed == nil)
    }
}
