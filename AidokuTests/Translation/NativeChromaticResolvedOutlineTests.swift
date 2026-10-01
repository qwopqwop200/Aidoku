import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeChromaticResolvedOutlineTests {
    private let ring = [103.0, 214, 190]
    private let originalInk = [129.0, 220, 206]

    private func pixels() -> NativeRestorationPixels {
        var result = NativeRestorationPixels(width: 180, height: 96)
        result.rgba = [UInt8](repeating: 255, count: result.rgba.count)
        for column in 0..<4 {
            let left = 16 + column * 38
            for y in 24..<52 { for x in left..<(left + 14) {
                if x >= left + 3 && x < left + 11 && y >= 27 && y < 49 { continue }
                result.paint(y * result.width + x, NativeRestorationRGB(ring))
            } }
        }
        return result
    }

    private func sample(sourceStroke: Any? = NSNull(), foregroundConfidence: Double = 0.8,
                        strokeConfidence: Double = 0.7) -> [String: Any] {
        var sourceInk: [String: Any] = [
            "foreground": originalInk, "background": [255.0, 255, 255],
            "confidence": ["foreground": 0.99, "background": 0.9, "stroke": 0.0]
        ]
        sourceInk["stroke"] = sourceStroke
        return [
            "foreground": [255.0, 255, 255], "background": [255.0, 255, 255], "stroke": ring,
            "confidence": ["foreground": foregroundConfidence, "background": 0.9, "stroke": strokeConfidence],
            "sourceInk": sourceInk
        ]
    }

    private func repair(_ page: NativeRestorationPixels, sample: [String: Any]) throws -> NativeRestorationPixels {
        let palette = try #require(NativeRestorationPixels.palette(sample))
        let result = NativeRestorationPixels.sampledChromatic(page, box: CGRect(x: 8, y: 8, width: 164, height: 80),
            auxiliary: [], excluded: [], palette: palette, vertical: false)
        return try #require(result)
    }

    @Test func jsonNullAndMissingSourceStrokeKeepTheIndependentlyResolvedWhiteFill() throws {
        let page = pixels(), original = page.rgba
        let encoded = try JSONSerialization.data(withJSONObject: sample())
        let decodedValue = try JSONSerialization.jsonObject(with: encoded)
        let decoded = try #require(decodedValue as? [String: Any])
        #expect((decoded["sourceInk"] as? [String: Any])?["stroke"] is NSNull)
        let explicitNull = try repair(page, sample: decoded)
        let missing = try repair(page, sample: sample(sourceStroke: nil))
        #expect(explicitNull.observedFill?.channels == [255, 255, 255])
        #expect(explicitNull.discoveredOutline?.channels == ring)
        let equivalentRepair = explicitNull.rgba == missing.rgba && explicitNull.layoutSafe == missing.layoutSafe
        #expect(equivalentRepair)
        #expect(explicitNull.sourceErasureVerified == true)
        let sourceUnchanged = page.rgba == original
        #expect(sourceUnchanged)
        for y in 0..<page.height { for x in 0..<page.width where x < 2 || y < 2 || x >= page.width - 2 || y >= page.height - 2 {
            #expect(explicitNull.rgba[(y * page.width + x) * 4 + 3] == 0)
        } }
    }

    @Test func anObservedSourceStrokeRetainsTheOriginalInkPolarity() throws {
        let result = try repair(pixels(), sample: sample(sourceStroke: [255.0, 255, 255]))
        #expect(result.observedFill?.channels == originalInk)
        #expect(result.discoveredOutline == nil)
    }

    @Test func insufficientIndependentConfidenceDoesNotPromoteWhiteFill() throws {
        for candidate in [sample(foregroundConfidence: 0.69), sample(strokeConfidence: 0.69)] {
            let result = try repair(pixels(), sample: candidate)
            #expect(result.observedFill?.channels == originalInk)
            #expect(result.discoveredOutline == nil)
        }
    }
}
