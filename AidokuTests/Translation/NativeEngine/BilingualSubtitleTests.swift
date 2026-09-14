import Foundation
import CoreGraphics
import Testing
@testable import Aidoku
struct BilingualSubtitleTests {
    @Test func independentlyQuotedLanguagesRemainSeparateAcrossScaleAndOrder() {
        // Actual ATRI detector quads; substituted text keeps the test portable
        // and avoids requiring external comic files inside the simulator.
        let fixtures: [([String], [[[CGFloat]]])] = [
            (["「明日の作業についてもう一度説明してくれますか」",
              "\"Could you explain the plan once more before we begin the practice session?\""],
             [[[254, 547], [685, 548], [685, 571], [254, 570]],
              [[243, 575], [974, 575], [974, 599], [243, 599]]]),
            (["「はい！」", "\"Okay!\""],
             [[[253, 546], [329, 550], [327, 574], [251, 570]],
              [[241, 571], [326, 573], [325, 602], [240, 599]]])
        ]
        for (texts, polygons) in fixtures {
            for scale: CGFloat in [0.5, 1, 2] {
                let lines = zip(texts, polygons).map { text, polygon in
                    NativeCoreMLOCRLine(
                        polygon: polygon.map { CGPoint(x: $0[0] * scale, y: $0[1] * scale) },
                        text: text, score: 0.99, orientation: .horizontal, orientationIsEstimated: true
                    )
                }
                for ordered in [lines, Array(lines.reversed())] {
                    let out = NativeOCRTextLineMerger.merge(
                        ordered, imageWidth: Int(1280 * scale), imageHeight: Int(720 * scale)
                    )
                    #expect(Set(out.map(\.text)) == Set(texts))
                }
            }
        }
    }
    @Test func quotedLatinNamesAndWrappedJapaneseRemainOneUtterance() {
        // ATRI row positions with boundary variants: a quotation around an inline name is not a second utterance.
        for texts in [["「ハイ!", "\"Yayyy!\"」"], ["「ハイ!」", "「わかった!」"], ["「MCの", "話です」"]] {
            let lines = texts.enumerated().map { i, text in
                NativeCoreMLOCRLine(polygon: [CGPoint(x: 243,y: 547+i*28),CGPoint(x: 450,y:547+i*28),CGPoint(x:450,y:571+i*28),CGPoint(x:243,y:571+i*28)], text:text, score:0.99, orientation:.horizontal)
            }
            let out = NativeOCRTextLineMerger.merge(lines,imageWidth:1280,imageHeight:720)
            #expect(out.count == 1)
            #expect(texts.allSatisfy { out[0].text.contains($0) })
        }
    }
}
