import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeSourceFillPreservationTests {
    private let white = [254.0, 254, 250]

    private func packet(pixels: Bool) -> [String: Any] {
        var value: [String: Any] = [
            "sourceOnly": true, "fill": ["rgb": white],
            "outline": ["present": false, "probability": 0.12, "widthPx": 0,
                        "measurementEvidence": ["reliable": true, "usableRays": 100]],
            "shadow": ["present": false, "probability": 0.0],
            "background": ["representation": "observed-context-palette", "insufficientObservedContext": false,
                           "colors": [[121, 80, 120]], "observedContextWeights": [1.0]]]
        if pixels {
            value["pixelRoleEvidence"] = ["GTAtInference": false, "samples": 1000,
                "roles": ["fill": ["confidentSamples": 200,
                                   "observedColours": [["rgb": white, "observedMass": 0.99]]],
                          "outline": ["confidentSamples": 0, "meanProbability": 0.005]]]
        }
        return value
    }

    @Test func ancillaryRaysCannotHideIndependentPlainFillEvidence() {
        var withoutRays = packet(pixels: true)
        var outline = withoutRays["outline"] as! [String: Any]
        outline.removeValue(forKey: "measurementEvidence")
        withoutRays["outline"] = outline
        for source in [withoutRays, packet(pixels: true)] {
            #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
                sourceAppearance: source, enabled: true) == 0.035)
        }
        #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
            sourceAppearance: packet(pixels: false), enabled: true) == 0.20)
        #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
            sourceAppearance: packet(pixels: true), enabled: false) == 0.20)
    }

    @Test func actualPreparedFillRetainsSupportedWhiteOnColouredBackground() throws {
        let foreground = try NativeMandatoryDisplayStroke.image(
            Array(repeating: [UInt8(254), 254, 250, 255], count: 8 * 8).flatMap { $0 }, width: 8, height: 8)
        let background = try NativeMandatoryDisplayStroke.image(
            Array(repeating: [UInt8(121), 80, 120, 255], count: 32 * 32).flatMap { $0 }, width: 32, height: 32)
        let prepared = try NativeMandatoryDisplayStroke.prepare(fill: foreground, restored: background,
            fontOutputPixels: 24, outwardEm: 0.035, fillFrame: CGRect(x: 12, y: 12, width: 8, height: 8),
            sourceAppearance: packet(pixels: true))
        #expect(prepared.endpointDecision["whiteFillOverride"] as? Bool == false)
        #expect(prepared.endpointDecision["sourceAbsentOutlineFillPreserved"] as? Bool == true)
        #expect(prepared.endpointDecision["displayFillRGB"] as? [Int] == [254, 254, 250])
        let bytes = try NativeMandatoryDisplayStroke.rgba(prepared.fill)
        let opaque = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 3] == 255 }
        #expect(opaque.count == 64)
        #expect(opaque.allSatisfy { bytes[$0] == 254 && bytes[$0 + 1] == 254 && bytes[$0 + 2] == 250 })
    }

    @Test func relaxedAbsenceBoundaryRequiresIndependentWhitePixelRoles() {
        var source = packet(pixels: true)
        var pixels = source["pixelRoleEvidence"] as! [String: Any]
        pixels["featureContextPolicy"] = "source-independent-paint-feature-context-v1"
        source["pixelRoleEvidence"] = pixels
        var outline = source["outline"] as! [String: Any]
        outline["probability"] = 0.25
        source["outline"] = outline
        #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
            sourceAppearance: source, enabled: true) == 0.035)
        outline["probability"] = 0.2501
        source["outline"] = outline
        #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
            sourceAppearance: source, enabled: true) == 0.20)
        outline["probability"] = 0.20
        source["outline"] = outline
        pixels.removeValue(forKey: "featureContextPolicy")
        source["pixelRoleEvidence"] = pixels
        #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
            sourceAppearance: source, enabled: true) == 0.20)
    }

    @Test func strongWhiteEvidenceStillRequiresNinetyFourPercentContrastingContext() {
        var source = packet(pixels: true)
        var pixels = source["pixelRoleEvidence"] as! [String: Any]
        pixels["featureContextPolicy"] = "source-independent-paint-feature-context-v1"
        source["pixelRoleEvidence"] = pixels
        var background = source["background"] as! [String: Any]
        background["colors"] = [[121, 80, 120], [254, 254, 250]]
        background["observedContextWeights"] = [0.94, 0.06]
        source["background"] = background
        #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
            sourceAppearance: source, enabled: true) == 0.035)
        background["observedContextWeights"] = [0.939, 0.061]
        source["background"] = background
        #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
            sourceAppearance: source, enabled: true) == 0.20)
        background["observedContextWeights"] = [0.94, 0.06]
        source["background"] = background
        pixels.removeValue(forKey: "featureContextPolicy")
        source["pixelRoleEvidence"] = pixels
        #expect(NativeExplicitDisplayStrokePolicy.sourceAwareGuardRatio(chosenFillRGB: white,
            sourceAppearance: source, enabled: true) == 0.20)
    }
}
