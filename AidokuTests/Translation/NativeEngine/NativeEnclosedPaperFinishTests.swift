import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeEnclosedPaperFinishTests {
    private let width = 40
    private let height = 32
    private var core: CGRect { CGRect(x: 10, y: 8, width: 15, height: 16) }
    private func fixture() -> (source: [UInt8], rgba: [UInt8], safe: [UInt8]) {
        let source = Array(repeating: [UInt8](arrayLiteral: 250, 250, 250, 255), count: width * height).flatMap { $0 }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 12..<16 { for x in 15..<19 {
            rgba.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 4, with: [240, 241, 242, 255])
        } }
        return (source, rgba, [UInt8](repeating: 1, count: width * height))
    }

    @Test func disconnectedFarDrawingIsClippedWhileOwnedLetteringRetainsItsPatch() throws {
        var f = fixture()
        for y in 2..<5 { for x in 1..<4 {
            f.rgba.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 4, with: [241, 242, 243, 255])
        } }
        let result = try #require(NativeEnclosedPaperFinish.finish(source: f.source, width: width, height: height,
            core: core, auxiliary: [], rgba: f.rgba, safe: f.safe))
        #expect(result.erased == 16)
        #expect(result.rgba[(3 * width + 2) * 4 + 3] == 0)
        #expect(result.safe[3 * width + 2] == 0)
        #expect(result.rgba[(13 * width + 17) * 4 + 3] == 255)
        #expect(result.safe[13 * width + 17] == 1)
    }

    @Test func farDrawingConnectedToOwnedInkRejectsTheWholeProposal() {
        var f = fixture()
        for x in 1..<17 {
            f.rgba.replaceSubrange((12 * width + x) * 4..<(12 * width + x) * 4 + 4, with: [241, 242, 243, 255])
        }
        #expect(NativeEnclosedPaperFinish.finish(source: f.source, width: width, height: height,
            core: core, auxiliary: [], rgba: f.rgba, safe: f.safe) == nil)
    }
}
