import Foundation
import Testing
@testable import Aidoku

struct NativePrimarySamplingTests {
    @Test func halfEvenSamplingIsStableAtFourULPsButPreservesFarOffsets() throws {
        for half in stride(from: 3.5, through: 63.5, by: 2) {
            let expected = Int(half.rounded(.toNearestOrEven)) | 1
            for direction in [-1, 1] {
                var value = half
                for _ in 0..<4 {
                    value = direction < 0 ? value.nextDown : value.nextUp
                    #expect(try NativePixelRFFeatures.adaptiveWindow(fontPixels: value * 4) == expected)
                }
            }
            for value in [half - 1e-8, half + 1e-8] {
                #expect(try NativePixelRFFeatures.adaptiveWindow(fontPixels: value * 4) == Int(value.rounded(.toNearestOrEven)) | 1)
            }
        }
    }

    @Test func observedPriorRetainsItsBitsWhileOnlyWindowStabilizes() throws {
        let prior = Double(38).nextDown, original = prior.bitPattern
        #expect(try NativePixelRFFeatures.adaptiveWindow(fontPixels: prior) == 11)
        #expect(prior.bitPattern == original)
        #expect(try NativePixelRFFeatures.adaptiveWindow(fontPixels: 37) == 9)
        #expect(try NativePixelRFFeatures.adaptiveWindow(fontPixels: 38) == 11)
        #expect(NativeSourceInferencePolicy.cacheProjection["sourcePrimaryFeatureSamplingPolicy"] ==
            NativePixelRFFeatures.samplingPolicyVersion)
    }

    @Test func scalarJSONCyclesDoNotMoveTheSamplingWindow() throws {
        var prior = Double(38).nextDown
        for _ in 0..<32 {
            let data = try JSONSerialization.data(withJSONObject: [prior])
            prior = (try JSONSerialization.jsonObject(with: data) as! [NSNumber])[0].doubleValue
            #expect(try NativePixelRFFeatures.adaptiveWindow(fontPixels: prior) == 11)
        }
    }

    @Test func clampsBeforeIntAndRejectsInvalidSamplingInput() throws {
        #expect(try NativePixelRFFeatures.adaptiveWindow(fontPixels: 1) == 3)
        #expect(try NativePixelRFFeatures.adaptiveWindow(fontPixels: Double.greatestFiniteMagnitude) == 65)
        for value in [Double.nan, .infinity, 0, -1] {
            #expect(throws: (any Error).self) { try NativePixelRFFeatures.adaptiveWindow(fontPixels: value) }
        }
    }
}
