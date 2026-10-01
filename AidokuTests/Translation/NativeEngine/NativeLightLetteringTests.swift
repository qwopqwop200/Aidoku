import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeLightLetteringTests {
    private func fixture(halo: Bool = false) throws -> (NativeLightLettering.Crop, [UInt8]) {
        var budget = 49_152
        let crop = try #require(NativeLightLettering.crop(bounds: [0.2, 0.2, 0.6, 0.6],
            frame: CGRect(x: 0, y: 0, width: 100, height: 80), imageSize: CGSize(width: 100, height: 80),
            sourceFont: 24, plate: CGRect(x: 20, y: 16, width: 60, height: 48), remainingPixels: &budget).crop)
        var rgba = [UInt8](repeating: 255, count: crop.width * crop.height * 4)
        for y in 0..<crop.height { for x in 0..<crop.width {
            let ix = x - 12, iy = y - 12, stripe = ((ix - 3) % 12 + 12) % 12
            let inside = ix >= 3 && ix < 57 && iy >= 5 && iy < 43
            var color: [UInt8] = inside && stripe < 5 ? [245,245,245] : [20,20,20]
            if halo && inside && stripe == 2 && iy >= 8 && iy < 40 { color = [180,20,50] }
            let p = (y * crop.width + x) * 4
            rgba[p] = color[0]; rgba[p + 1] = color[1]; rgba[p + 2] = color[2]
        } }
        return (crop, rgba)
    }

    @Test func lightSourceLettersRecoverDarkSurfaceWithoutChangingGeometry() throws {
        let (crop, rgba) = try fixture()
        let decision = NativeLightLettering.analyze(rgba: rgba, crop: crop, font: 18,
            ink: [30,30,30], plate: [250,250,250], neighborOverlapsPlate: false)
        #expect(decision.rejection == nil)
        #expect(decision.style?.fill == [245,245,245])
        #expect(decision.style?.background == [20,20,20])
        #expect(decision.style?.strokeWidth == 0)
        #expect(decision.record["stroke"] as? Double == 0.25)
        #expect(NativeLightLettering.analyze(rgba: rgba, crop: crop, font: 18,
            ink: [30,30,30], plate: [250,250,250], neighborOverlapsPlate: true).rejection == "surface")
    }

    @Test func darkInkInsidePaleHaloDoesNotBecomeLightLettering() throws {
        let (crop, rgba) = try fixture(halo: true)
        let decision = NativeLightLettering.analyze(rgba: rgba, crop: crop, font: 18,
            ink: [30,30,30], plate: [250,250,250], neighborOverlapsPlate: false)
        #expect(decision.style == nil)
        #expect(decision.rejection == "halo")
        #expect(decision.record["sealed"] as? [Double] == [180,20,50])
    }

    @Test func cropBudgetIsSharedAndRejectsOversizedGeometryWithoutAllocating() {
        var budget = 49_152, accepted = 0
        for _ in 0..<20 {
            let result = NativeLightLettering.crop(bounds: [0.2,0.2,0.6,0.6],
                frame: CGRect(x: 0, y: 0, width: 100, height: 80), imageSize: CGSize(width: 100, height: 80),
                sourceFont: 24, plate: CGRect(x: 20, y: 16, width: 60, height: 48), remainingPixels: &budget)
            if result.crop != nil { accepted += 1 } else { #expect(result.rejection == "budget") }
        }
        #expect(accepted == 8)
        #expect(budget == 768)
        #expect(NativeLightLettering.crop(bounds: [0.2,0.2,0.6,0.6],
            frame: CGRect(x: 0, y: 0, width: 100, height: 80), imageSize: CGSize(width: 1e200, height: 1e200),
            sourceFont: 24, plate: .zero, remainingPixels: &budget).crop == nil)
    }

    @Test func saturatedOutlinePreservesMeasuredNeonAndOptionalGlow() {
        let ring: [String: Any] = ["kind": "outline", "action": "none", "core": [255.0,255,255],
            "outline": [200.0,0,100], "plate": [250.0,250,250], "hug": 0.8, "uniform": 0.8, "width": 0.1]
        let style = NativeLightLettering.saturated(mode: "rotated-panel", font: 18, strokeWidth: 0,
            ring: ring, currentPlate: [250,250,250])
        #expect(style?.fill == [255,255,255])
        #expect(style?.stroke == [200,0,100])
        #expect(style?.strokeWidth == 4.25)
        #expect(style?.glowRadius == 3)
        #expect(NativeLightLettering.saturated(mode: "rotated-panel", font: 18, strokeWidth: 0.5,
            ring: ring, currentPlate: [250,250,250]) == nil)
        let strokeOnly: [String: Any] = ["foreground": [30.0,30,30], "background": [250.0,250,250],
            "stroke": [245.0,245,245], "confidence": ["stroke": 0.9]]
        #expect(NativeLightLettering.hasLightEvidence(sample: strokeOnly, ring: [:]))
        var uncertain = strokeOnly
        uncertain["confidence"] = ["stroke": 0.5]
        #expect(!NativeLightLettering.hasLightEvidence(sample: uncertain, ring: [:]))
    }
}
