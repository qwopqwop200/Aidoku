import Foundation
import Testing
import UIKit
@testable import Aidoku

struct NativeOCRShortReactionRecoveryTests {
    @Test func malformedDimensionsAreRejectedBeforeByteCountArithmetic() {
        for (width, height) in [(Int.max, 2), (Int.max / 4 + 1, 1), (0, 1), (-1, 1), (1, 1)] {
            #expect(NativeOCRShortReactionRecovery.repeatedDotCount(
                [], width: width, height: height, columnWidth: 66
            ) == 0)
        }
    }

    @Test func leadingPunctuationKeepsIndependentlyCountedDots() {
        #expect(NativeOCRShortReactionRecovery.preservingLeadingDots("●・つ！", count: 6) == "……つ！")
        #expect(NativeOCRShortReactionRecovery.preservingLeadingDots("っ！", count: 6) == "っ！")
        #expect(NativeOCRShortReactionRecovery.preservingLeadingDots("・つ！", count: 3) == "・つ！")
    }

    @Test func actualOrangeReactionRetainsItsSixDots() async throws {
        let url = try #require(Bundle(for: ShortReactionFixtureBundle.self)
            .url(forResource: "VerticalShortReaction", withExtension: "png"))
        let image = try #require(UIImage(contentsOfFile: url.path)?.cgImage)
        let frame = try #require(await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image))
        #expect(NativeOCRShortReactionRecovery.repeatedDotCount(frame.bytes, width: frame.width,
            height: frame.height, columnWidth: 66) == 6)
        let polygon = [CGPoint(x: 33, y: 33), CGPoint(x: 99, y: 33), CGPoint(x: 99, y: 299), CGPoint(x: 33, y: 299)]
        let failed = NativeCoreMLRecognitionRegion(sourceIndex: 32, polygon: polygon)
        let anchor = NativeCoreMLRecognizedRegion(sourceIndex: 0,
            polygon: [.zero, CGPoint(x: 10, y: 10)], text: "かな", confidence: 1)
        let recovered = try NativeOCRShortReactionRecovery.recover(frame: frame, failed: [failed], accepted: [anchor])
        let result = try #require(recovered.first)
        #expect(result.sourceIndex == 32)
        #expect(result.polygon == polygon)
        #expect(result.text.hasPrefix("……"))
        #expect(result.text.contains("つ") || result.text.contains("っ"))
        #expect(try NativeOCRShortReactionRecovery.recover(frame: frame, failed: [failed], accepted: [result]).isEmpty)
        #expect(try NativeOCRShortReactionRecovery.recover(frame: frame, failed: [failed], accepted: []).isEmpty)
    }

    @Test func trailingExclamationDotDoesNotInvalidateAnEllipsis() {
        let width = 100, height = 300
        var rgba = [UInt8](repeating: 245, count: width * height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
        func dot(_ cx: Int, _ cy: Int) {
            for y in (cy - 4)...(cy + 4) { for x in (cx - 4)...(cx + 4) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= 17 {
                let i = (y * width + x) * 4; rgba[i] = 220; rgba[i + 1] = 80; rgba[i + 2] = 35
            } }
        }
        for y in [35, 55, 75, 95, 115, 135, 260] { dot(45, y) }
        #expect(NativeOCRShortReactionRecovery.hasRepeatedDots(rgba, width: width, height: height, columnWidth: 66))
        #expect(!NativeOCRShortReactionRecovery.hasRepeatedDots(Array(repeating: 255, count: rgba.count), width: width,
                                                                height: height, columnWidth: 66))
    }
}

private final class ShortReactionFixtureBundle: NSObject {}
