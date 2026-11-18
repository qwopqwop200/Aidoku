import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeOCRRubyFooterTests {
    private func line(_ text: String, _ coordinates: [(CGFloat, CGFloat)], score: Double = 0.99,
                      scale: CGFloat = 1) -> NativeCoreMLOCRLine {
        .init(polygon: coordinates.map { CGPoint(x: $0.0 * scale, y: $0.1 * scale) },
              text: text, score: score, orientation: .vertical, orientationIsEstimated: true)
    }

    // Exact cached raw 0064 quads/text/scores, not grouped or translated input.
    private func fixture(scale: CGFloat = 1, alternate: Bool = false) -> [NativeCoreMLOCRLine] {
        [line(alternate ? "ここを見て!" : "これを読め!", [(762,147),(783,147),(783,275),(762,275)],
              score: 0.99146450559298194, scale: scale),
         line(alternate ? "窓の方に向かって" : "カメラに向かって", [(784,144),(810,144),(812,317),(786,317)],
              score: 0.99912818521261215, scale: scale),
         line(alternate ? "さあ!" : "よし!", [(812,146),(832,146),(832,211),(812,211)],
              score: 0.99212177594502771, scale: scale),
         line(alternate ? "花園" : "園咲", [(809,232),(828,232),(828,273),(809,273)],
              score: 0.98862877488136292, scale: scale),
         line(alternate ? "はなぞの" : "そのさき", [(828,226),(853,231),(843,279),(818,274)],
              score: 0.79221376776695251, scale: scale)]
    }

    private func merge(_ rows: [NativeCoreMLOCRLine], scale: CGFloat = 1,
                       separator: ((CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool)? = nil,
                       ink: ((CGRect, CGRect) -> Bool)? = nil,
                       polarity: ((CGRect, CGRect) -> Bool)? = nil) -> [PaddleOCRLine] {
        NativeOCRTextLineMerger.merge(rows, imageWidth: Int(1250 * scale), imageHeight: Int(799 * scale),
            separationCheck: separator, inkContrast: ink, polarityContrast: polarity)
    }

    @Test(arguments: [0.5, 1.0, 2.0])
    func cachedFooterRestoresColumnOrderAndKeepsRubyInk(scale: CGFloat) {
        let rows = fixture(scale: scale)
        for input in [rows, Array(rows.reversed()), [rows[4], rows[1], rows[3], rows[0], rows[2]]] {
            let result = merge(input, scale: scale)
            #expect(result.count == 1)
            #expect(result.first?.text.replacingOccurrences(of: "\n", with: "") == "よし!園咲カメラに向かってこれを読め!")
            #expect(result.first?.auxiliaryInkPolygons.contains(rows[4].polygon) == true)
            #expect(result.first?.singleVerticalColumn == false)
        }
        let alternative = merge(fixture(scale: scale, alternate: true), scale: scale)
        #expect(alternative.count == 1)
        #expect(alternative.first?.text.replacingOccurrences(of: "\n", with: "") == "さあ!花園窓の方に向かってここを見て!")
    }

    @Test func boundariesAndInkVetoRubyAndFooterOwnership() {
        let rows = fixture()
        for result in [merge(rows, separator: { _, _, _ in true }),
                       merge(rows, ink: { _, _ in true }),
                       merge(rows, polarity: { _, _ in true })] {
            #expect(result.contains { $0.text.contains(rows[4].text) })
            #expect(!result.contains { $0.text.contains(rows[2].text) && $0.text.contains(rows[3].text) })
        }
    }

    @Test func ambiguousMissingAndIndependentColumnsDoNotBorrowRubyOwnership() {
        let rows = fixture()
        let duplicate = line("山川", [(809,232),(828,232),(828,273),(809,273)])
        let secondHead = line("待て!", [(812,146),(832,146),(832,211),(812,211)])
        let fullSize = line("そのさき", [(828,226),(853,231),(843,310),(818,305)])
        let remote = line("園咲", [(909,232),(928,232),(928,273),(909,273)])
        let quoted = line("「よし!」", [(812,146),(832,146),(832,211),(812,211)])
        let speaker = line("甲：よし!", [(812,146),(832,146),(832,211),(812,211)])
        let weak = line("そのさき", [(828,226),(853,231),(843,279),(818,274)], score: 0.74)
        let inputs = [rows + [duplicate], rows + [secondHead],
                      [rows[0], rows[2], rows[3], rows[4]],
                      [rows[0], rows[1], rows[3], rows[4]],
                      Array(rows.prefix(4)) + [fullSize],
                      Array(rows.prefix(4)) + [weak],
                      [rows[0], rows[1], rows[2], remote, rows[4]],
                      [rows[0], rows[1], quoted, rows[3], rows[4]],
                      [rows[0], rows[1], speaker, rows[3], rows[4]]]
        for input in inputs {
            let result = merge(input)
            #expect(result.contains { $0.text.contains("そのさき") })
            #expect(!result.contains { $0.auxiliaryInkPolygons.contains(rows[4].polygon) })
        }
    }
}
