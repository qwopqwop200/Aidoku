import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRendererSourcePositionTests {
    private func fixture(residual: Bool = false) throws -> (NativeTranslationLayoutItem, NativeRestorationCandidate) {
        let json = #"{"id":"main","text":"검증","sourceTextOnly":false,"sourceBounds":[0.25,0.25,0.5,0.5],"sourceFrame":[100,200,160,128],"sourceFontSize":8,"x":160,"y":256,"width":40,"height":16,"fontSize":12,"lineHeight":14}"#
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: Data(json.utf8))
        var original = NativeRestorationPixels(width: 40, height: 32)
        original.rgba = [UInt8](repeating: 255, count: original.count * 4)
        var repaired = original
        repaired.layoutSafe = [UInt8](repeating: 1, count: repaired.count)
        repaired.erasureComplete = true; repaired.glyphsVerified = true
        if residual {
            for x0 in [16, 21] { for y in 14..<18 { for x in x0..<(x0 + 3) {
                repaired.layoutSafe?[y * 40 + x] = 0
            } } }
        }
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: original,
            crop: CGRect(x: 10, y: 8, width: 80, height: 64), source: CGRect(x: 40, y: 32, width: 80, height: 64),
            box: CGRect(x: 15, y: 12, width: 40, height: 32), auxiliary: [], excluded: [], marks: [],
            leadingRule: false, sx: 0.5, sy: 0.5, synthetic: [])
        let candidate = try #require(NativeRestorationCandidate(prepared: prepared, repaired: repaired,
            luminance: [UInt8](repeating: 255, count: repaired.count), imageSize: CGSize(width: 160, height: 128),
            frame: CGRect(x: 100, y: 200, width: 160, height: 128), item: item))
        return (item, candidate)
    }

    @Test func outlineReleaseUsesSourceFrameAndRetainedPixelMasks() throws {
        let (item, candidate) = try fixture()
        let ink = CGRect(x: 160, y: 256, width: 40, height: 16)
        let plate = CGRect(x: 138, y: 230, width: 84, height: 68)
        let choice = NativeRendererSourcePosition.decide(item: item, ink: ink, font: 12, foreground: [17,18,23],
            sampledStroke: [210,220,230], oldPlate: plate, candidate: candidate, otherCandidates: [:],
            otherSources: [], neighbors: [], contentFits: true)
        #expect(choice?.stroke == [210,220,230])
        #expect(abs((choice?.width ?? 0) - 1.2) < 1e-12)
        let (_, unresolved) = try fixture(residual: true)
        #expect(NativeRendererSourcePosition.decide(item: item, ink: ink, font: 12, foreground: [17,18,23],
            sampledStroke: nil, oldPlate: plate, candidate: unresolved, otherCandidates: [:],
            otherSources: [], neighbors: [], contentFits: true) == nil)
    }

    @Test func foreignAuxiliaryInkRequiresItsOwnConnectedCompleteRestoration() throws {
        let (item, candidate) = try fixture()
        let (_, other) = try fixture()
        let sources: [(id: String, rect: CGRect)] = [
            ("other", CGRect(x: 400, y: 400, width: 20, height: 20)),
            ("other", CGRect(x: 140, y: 232, width: 8, height: 8))
        ]
        func choice(_ attached: [String: NativeRestorationCandidate]) -> NativeTranslationSourceStylePostPolish.Outline? {
            NativeRendererSourcePosition.decide(item: item, ink: CGRect(x: 160, y: 256, width: 40, height: 16),
                font: 12, foreground: [17,18,23], sampledStroke: nil,
                oldPlate: CGRect(x: 138, y: 230, width: 84, height: 68), candidate: candidate,
                otherCandidates: attached, otherSources: sources, neighbors: [], contentFits: true)
        }
        #expect(choice([:]) == nil)
        #expect(choice(["other": other]) != nil)
        other.partialErasureCertified = true
        #expect(choice(["other": other]) == nil)
    }
}
