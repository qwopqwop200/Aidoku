import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeSourceROIFeaturesTests {
    @Test func retainedBankRejectsMutationAndUnrelatedPixels() throws {
        var rgba: [UInt8] = [32, 64, 96, 255, 160, 192, 224, 255]
        let box = CGRect(x: 0, y: 0, width: 2, height: 1)
        let features = try #require(NativeSourceROIFeatures(rgba: rgba, width: 2, height: 1, box: [0, 0, 2, 1]))
        let retained = rgba
        #expect(features.matches(rgba: retained, width: 2, height: 1, box: box))
        rgba[0] = 99
        #expect(!features.matches(rgba: rgba, width: 2, height: 1, box: box))
        #expect(features.matches(rgba: retained, width: 2, height: 1, box: box))
        let unrelated: [UInt8] = [33, 64, 96, 255, 160, 192, 224, 255]
        #expect(!features.matches(rgba: unrelated, width: 2, height: 1, box: box))
        #expect(!features.matches(rgba: retained, width: 1, height: 2, box: box))
        #expect(!features.matches(rgba: retained, width: 2, height: 1,
            box: CGRect(x: -0.0, y: 0, width: 2, height: 1)))
    }

    @Test func histogramOrderHalfOpenBoundsAndAlphaRemainExact() throws {
        let rgba: [UInt8] = [32, 64, 96, 127, 32, 64, 96, 128,
                            160, 192, 224, 255, 32, 64, 96, 255]
        let features = try #require(NativeSourceROIFeatures(rgba: rgba, width: 2, height: 2, box: [0, 0, 1, 2]))
        #expect(features.four.map(\.key) == [582, 2766])
        #expect(features.four.map(\.count) == [1, 1])
        #expect(features.four.map(\.sum) == [[32, 64, 96], [160, 192, 224]])
        #expect(features.three.map(\.key) == [83, 375])
        #expect(features.three.map(\.count) == [2, 1])
        #expect(features.three.map(\.inside) == [0, 1])
        #expect(features.insideCount == 1 && features.outsideCount == 2)
    }

    @Test func oversizedMalformedOrNonfiniteInputsAreRefused() {
        #expect(NativeSourceROIFeatures(rgba: [], width: Int.max, height: 1, box: [0, 0, 1, 1]) == nil)
        #expect(NativeSourceROIFeatures(rgba: [], width: 1, height: 0, box: [0, 0, 1, 1]) == nil)
        #expect(NativeSourceROIFeatures(rgba: [0, 0, 0], width: 1, height: 1, box: [0, 0, 1, 1]) == nil)
        #expect(NativeSourceROIFeatures(rgba: [0, 0, 0, 255], width: 1, height: 1, box: [.nan, 0, 1, 1]) == nil)
    }
}
