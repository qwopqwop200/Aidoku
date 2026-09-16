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
    @Test func mixedHorizontalTextAndOverlappingColumnsAreNotReversed() {
        #expect(ranks([input(0.1, 0.1, vertical: false), input(0.7, 0.1), input(0.3, 0.65)]) == [0, 1, 2])
        #expect(ranks([input(0.1, 0.1), input(0.15, 0.1), input(0.3, 0.65)]) == [0, 1, 2])
    }
    @Test func noncontiguousMembersFollowTheirImageSeparatedPanel() {
        #expect(ranks([input(0.1, 0.1), input(0.3, 0.65), input(0.7, 0.1)]) == [1, 2, 0])
    }
    @Test func diagonalNarrationWithoutCommonBandKeepsOrder() {
        #expect(ranks([input(0.1, 0.24), input(0.7, 0.01), input(0.3, 0.65)]) == [0, 1, 2])
    }
    @Test func separatedBandsWithinOnePanelEachReceiveRTLOrder() {
        let boxes: [ReaderTranslationPanelOrder.Input] = [
            .init(rect: CGRect(x: 0.1, y: 0.02, width: 0.1, height: 0.1), isVertical: true),
            .init(rect: CGRect(x: 0.7, y: 0.02, width: 0.1, height: 0.1), isVertical: true),
            .init(rect: CGRect(x: 0.1, y: 0.28, width: 0.1, height: 0.1), isVertical: true),
            .init(rect: CGRect(x: 0.7, y: 0.28, width: 0.1, height: 0.1), isVertical: true),
            input(0.3, 0.65)
        ]
        #expect(ranks(boxes) == [1, 0, 3, 2, 4])
    }

    @Test func bandOrderingKeepsIsolatedDiagonalTextInItsDetectorSlot() {
        let boxes: [ReaderTranslationPanelOrder.Input] = [
            .init(rect: CGRect(x: 0.1, y: 0.28, width: 0.1, height: 0.1), isVertical: true),
            .init(rect: CGRect(x: 0.1, y: 0.02, width: 0.1, height: 0.1), isVertical: true),
            .init(rect: CGRect(x: 0.7, y: 0.02, width: 0.1, height: 0.1), isVertical: true),
            input(0.3, 0.65)
        ]
        #expect(ranks(boxes) == [0, 2, 1, 3])
    }

    @Test func invalidCoordinatesAndPixelBuffersKeepOrder() {
        #expect(ranks([input(-0.1, 0.1), input(0.7, 0.1), input(0.3, 0.65)]) == [0, 1, 2])
        #expect(ranks([input(0.1, 0.1), input(0.7, 0.1)], pixels: []) == [0, 1])
    }
    @Test func ineligibleImagePairsKeepOriginalRank() throws {
        let provider = try #require(CGDataProvider(data: Data(ruledPanels) as CFData))
        let image = try #require(CGImage(width: 40, height: 40, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let alreadyOrdered = [input(0.7, 0.1), input(0.1, 0.1), input(0.3, 0.65)]
        #expect(ReaderTranslationPanelOrder.rightToLeftRanks(image: image, inputs: alreadyOrdered) == [0, 1, 2])
        let horizontal = [input(0.1, 0.1, vertical: false), input(0.7, 0.1, vertical: false)]
        #expect(ReaderTranslationPanelOrder.rightToLeftRanks(image: image, inputs: horizontal) == [0, 1])
    }

    @Test func explicitVerticalPanelCutOrdersPanelsBeforeTheirInternalText() {
        var pixels = [UInt8](repeating: 0, count: 1600)
        for y in 0..<40 { for x in 18..<22 { pixels[y * 40 + x] = 255 } }
        let boxes = [input(0.1, 0.1), input(0.7, 0.1), input(0.1, 0.65)]
        #expect(ranks(boxes, pixels: pixels) == [1, 0, 2])
    }

    @Test func panelTraversalUsesImageEvidenceForHorizontalLetteringToo() {
        var pixels = [UInt8](repeating: 0, count: 1600)
        for y in 0..<40 { for x in 18..<22 { pixels[y * 40 + x] = 255 } }
        let boxes = [input(0.1, 0.1, vertical: false), input(0.7, 0.1, vertical: false)]
        #expect(ranks(boxes, pixels: pixels) == [1, 0])
        #expect(ranks(boxes, pixels: [UInt8](repeating: 255, count: 1600)) == [0, 1])
    }

    @Test func antialiasedOnePixelGutterNeedsBothPanelFrames() {
        var pixels = [UInt8](repeating: 180, count: 10000)
        for y in 0..<100 {
            pixels[y * 100 + 49] = 0
            pixels[y * 100 + 50] = y == 0 ? 200 : 255
            pixels[y * 100 + 51] = 0
        }
        let boxes = [input(0.1, 0.1), input(0.7, 0.1)]
        #expect(ReaderTranslationPanelOrder.rightToLeftRanks(pixels: pixels, width: 100, height: 100, inputs: boxes) == [1, 0])
    }

    @Test func narrowWhitespaceBesideOnlyOneRuleCannotReorderPanels() {
        var pixels = [UInt8](repeating: 180, count: 10000)
        for y in 0..<100 {
            pixels[y * 100 + 49] = 0
            pixels[y * 100 + 50] = y == 0 ? 200 : 255
        }
        let boxes = [input(0.1, 0.1), input(0.7, 0.1)]
        #expect(ReaderTranslationPanelOrder.rightToLeftRanks(pixels: pixels, width: 100, height: 100, inputs: boxes) == [0, 1])
    }

    @Test func nestedPanelsStayTogetherWhenDetectorInterleavesTheirText() {
        var pixels = [UInt8](repeating: 0, count: 1600)
        // Full vertical gutter; only the left column has a horizontal gutter.
        for y in 0..<40 { for x in 18..<22 { pixels[y * 40 + x] = 255 } }
        for y in 18..<22 { for x in 0..<18 { pixels[y * 40 + x] = 255 } }
        let boxes = [input(0.1, 0.1), input(0.7, 0.1), input(0.1, 0.65), input(0.7, 0.65)]
        // Read the entire tall right panel, then top-left, then bottom-left.
        #expect(ranks(boxes, pixels: pixels) == [2, 0, 3, 1])
    }

    @Test func horizontalGutterRestoresTopPanelBeforeBottomPanel() throws {
        let boxes = [input(0.3, 0.65), input(0.3, 0.1)]
        #expect(ranks(boxes) == [1, 0])
        let provider = try #require(CGDataProvider(data: Data(ruledPanels) as CFData))
        let image = try #require(CGImage(width: 40, height: 40, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        // Exercises the image entry point's preflight, not only the pixel helper.
        #expect(ReaderTranslationPanelOrder.rightToLeftRanks(image: image, inputs: boxes) == [1, 0])
    }

    @Test func textCrossingGutterPreventsUnsupportedPanelSplit() {
        let crossing = ReaderTranslationPanelOrder.Input(rect: CGRect(x: 0.2, y: 0.35, width: 0.15, height: 0.3), isVertical: true)
        #expect(ranks([input(0.1, 0.1), input(0.7, 0.1), crossing]) == [0, 1, 2])
    }

    @Test func staggeredTextInTallPanelStillTriggersImageAnalysis() throws {
        var pixels = [UInt8](repeating: 0, count: 1600)
        for y in 0..<40 { for x in 18..<22 { pixels[y * 40 + x] = 255 } }
        let boxes = [input(0.7, 0.1, vertical: false), input(0.1, 0.3, vertical: false), input(0.7, 0.65, vertical: false)]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 40, height: 40, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(ReaderTranslationPanelOrder.rightToLeftRanks(image: image, inputs: boxes) == [0, 2, 1])
    }

}
