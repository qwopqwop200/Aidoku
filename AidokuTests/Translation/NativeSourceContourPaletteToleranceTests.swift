import CoreGraphics
import Foundation
import Darwin
import Testing
@testable import Aidoku

@Suite(.serialized)
struct NativeSourceContourPaletteToleranceTests {
    // Synthetic producer/consumer binding fixture only, never corpus evidence.
    private func owner(_ id: String, source: [Double] = [221, 90, 5],
                       rendered: [Double] = [221, 90, 5]) throws -> [String: Any] {
        let binding = Dictionary(uniqueKeysWithValues: NativeOperationalAppearance.bindingKeys.map {
            ($0, String(repeating: "a", count: 64))
        })
        let prediction: [String: Any] = [
            "sourceOnly": true,
            "fill": ["rgb": [255.0, 254.0, 250.0]],
            "outline": ["present": true, "rgb": source, "widthPx": 5.0],
            "shadow": ["present": false], "background": ["rgb": [255.0, 255.0, 255.0]]]
        let packet: [String: Any] = ["schema": "aidoku-live-source-appearance-v1",
            "sourceOnly": true, "freshInference": true, "GTAtInference": false,
            "cachedPredictionsRead": false, "binding": binding, "prediction": prediction]
        return try NativeOperationalAppearance.apply(packet: JSONSerialization.data(withJSONObject: packet),
            expectedBinding: binding, to: ["id": id, "sourceFontSize": 40.0,
                "sourceStyleGroupID": "synthetic-cohort", "renderSourceOutlineRGB": rendered])
    }

    private func enabled(_ body: () throws -> Void) rethrows {
        let key = "AIDOKU_SOURCE_CONTOUR_ONLY"
        let previous = getenv(key).map { String(cString: $0) }
        setenv(key, "1", 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        try body()
    }

    @Test func oneLSBPeerDoesNotVetoAuthenticatedCohortOrMutatePredictions() throws {
        try enabled {
            let input = try [owner("a"), owner("b"), owner("c", source: [221, 90, 6])]
            let before = try JSONSerialization.data(withJSONObject: input, options: .sortedKeys)
            let result = NativeOperationalAppearance.annotateContourPolicies(input)
            #expect(result.allSatisfy { NativeOperationalAppearance.sourceContourOnly($0) })
            #expect(result.allSatisfy { $0["sourceContourCohortVeto"] == nil })
            #expect(try JSONSerialization.data(withJSONObject: result, options: .sortedKeys) == before)
        }
    }

    @Test func eachChannelAcceptsThreeAndRejectsFour() throws {
        try enabled {
            for channel in 0..<3 {
                for sign in [-1.0, 1.0] {
                    for delta in [0.0, 1.0, 2.0, 3.0, 4.0] {
                        var color = [221.0, 90.0, 50.0]
                        color[channel] += sign * delta
                        let raw = try owner("a", source: [221, 90, 50], rendered: color)
                        #expect(NativeOperationalAppearance.sourceContourOnly(raw) == (delta <= 3))
                    }
                }
            }
        }
    }

    @Test func significantColorDifferenceStillVetoesCompleteCohort() throws {
        try enabled {
            let result = NativeOperationalAppearance.annotateContourPolicies(try [
                owner("a"), owner("b", rendered: [225, 90, 5])])
            #expect(result.allSatisfy { $0["sourceContourCohortVeto"] as? Bool == true })
            #expect(result.allSatisfy { !NativeOperationalAppearance.sourceContourOnly($0) })
        }
    }

    @Test func authorityAndStructuralGuardsRemainRequired() throws {
        try enabled {
            let valid = try owner("a", source: [221, 90, 6])
            var unbound = valid
            unbound.removeValue(forKey: "sourceAppearanceBinding")
            unbound.removeValue(forKey: "sourceContourPaintBinding")
            #expect(!NativeOperationalAppearance.sourceContourOnly(unbound))
            var wrongBinding = valid; wrongBinding["sourceContourPaintBinding"] = ["rgbSHA256": "bad"]
            #expect(!NativeOperationalAppearance.sourceContourOnly(wrongBinding))
            var widthMismatch = valid; widthMismatch["renderSourceOutlineWidthPx"] = 5.1
            #expect(!NativeOperationalAppearance.sourceContourOnly(widthMismatch))
            var badRGB = valid; badRGB["renderSourceOutlineRGB"] = [221.0, 90.0, Double.nan]
            #expect(!NativeOperationalAppearance.sourceContourOnly(badRGB))
            #expect(!NativeOperationalAppearance.sourceContourOnly(try owner("neutral", source: [1, 0, 0], rendered: [1, 0, 0])))
            for multipleBands in [false, true] {
                var raw = valid
                var prediction = try #require(raw["sourceAppearance"] as? [String: Any])
                if multipleBands {
                    var outline = try #require(prediction["outline"] as? [String: Any])
                    outline["observedLayers"] = [["rgb": [255, 255, 255], "widthPx": 2], ["rgb": [221, 90, 6], "widthPx": 5]]
                    prediction["outline"] = outline
                } else { prediction["shadow"] = ["present": true] }
                raw["sourceAppearance"] = prediction
                #expect(!NativeOperationalAppearance.sourceContourOnly(raw))
            }
        }
    }

    @Test func eligibleContourRetainsWhiteGlyphRGBAWithoutInnerBWGuard() throws {
        try enabled {
            let input = try [owner("a"), owner("b", source: [221, 90, 6])]
            let rows = NativeOperationalAppearance.annotateContourPolicies(input)
            let bytes: [UInt8] = (0..<64).flatMap { _ -> [UInt8] in [255, 254, 250, 255] }
            let glyph = try NativeMandatoryDisplayStroke.image(bytes, width: 8, height: 8)
            let surface = try NativeMandatoryDisplayStroke.image([UInt8](repeating: 255, count: 32*32*4), width: 32, height: 32)
            for raw in rows {
                #expect(NativeOperationalAppearance.sourceContourOnly(raw))
                let prepared = try NativeMandatoryDisplayStroke.prepare(fill: glyph, restored: surface,
                    fontOutputPixels: 40, fillFrame: CGRect(x: 8, y: 8, width: 8, height: 8),
                    sourceContourOnly: NativeOperationalAppearance.sourceContourOnly(raw))
                #expect(try NativeMandatoryDisplayStroke.rgba(prepared.fill) == bytes)
                #expect(prepared.outwardPixels == 0)
                #expect(prepared.endpointDecision["whiteFillOverride"] as? Bool == false)
                #expect(prepared.endpointDecision["guardPainted"] as? Bool == false)
                let style = try #require(try NativeSourceStylePaint.style(raw))
                let prediction = try #require(raw["sourceAppearance"] as? [String: Any])
                let outline = try #require(prediction["outline"] as? [String: Any])
                #expect(style.bands.count == 1 && style.bands[0].width == 5)
                #expect(style.bands[0].rgb == (outline["rgb"] as? [Double]))
            }
        }
    }
}
