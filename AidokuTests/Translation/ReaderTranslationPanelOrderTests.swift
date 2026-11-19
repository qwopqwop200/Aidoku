import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationPanelOrderTests {
    private func input(_ x: CGFloat, _ y: CGFloat, vertical: Bool = true) -> ReaderTranslationPanelOrder.Input {
        .init(rect: CGRect(x: x, y: y, width: 0.12, height: 0.20), isVertical: vertical)
    }
    private var ruledPanels: [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 40 * 40)
        for y in 18..<22 { for x in 0..<40 { pixels[y * 40 + x] = 255 } }
        return pixels
    }
    private func ranks(_ inputs: [ReaderTranslationPanelOrder.Input], pixels: [UInt8]? = nil) -> [Int] {
        ReaderTranslationPanelOrder.rightToLeftRanks(pixels: pixels ?? ruledPanels, width: 40, height: 40, inputs: inputs)
    }

    @Test func imageSeparatedVerticalBandSuppliesRTLRankWithoutMovingOtherPanel() {
        #expect(ranks([input(0.1, 0.1), input(0.4, 0.12), input(0.7, 0.11), input(0.3, 0.65)]) == [2, 1, 0, 3])
    }
    @Test func whitespaceAloneAndUnseparatedArtworkKeepDetectorOrder() {
        let boxes = [input(0.1, 0.1), input(0.7, 0.1), input(0.3, 0.65)]
        #expect(ranks(boxes, pixels: [UInt8](repeating: 255, count: 1600)) == [0, 1, 2])
        #expect(ranks(boxes, pixels: [UInt8](repeating: 0, count: 1600)) == [0, 1, 2])
    }
    @Test func invalidCoordinatesAndPixelBuffersKeepOrder() {
        #expect(ranks([input(-0.1, 0.1), input(0.7, 0.1), input(0.3, 0.65)]) == [0, 1, 2])
        #expect(ranks([input(0.1, 0.1), input(0.7, 0.1)], pixels: []) == [0, 1])
    }
}
