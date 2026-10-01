import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRestorationUnitInteriorTests {
    private func fixture(rotation: Double) throws -> (NativeTranslationLayoutItem, NativeSpatialSourceCrop.Prepared, NativeRestorationPixels) {
        let value: [String: Any] = ["id": "joined", "text": "검증", "sourceBounds": [0, 0, 1, 1],
            "sourceFrame": [0, 0, 40, 40], "sourceFontSize": 8, "fontSize": 8, "lineHeight": 10, "x": 0, "y": 0, "width": 40, "height": 40,
            "rotation": rotation, "unitMemberRects": [[0.05, 0.05, 0.1, 0.1], [0.8, 0.8, 0.1, 0.1]],
            "balloonInterior": ["contourVerified": true, "rect": [0.25, 0.25, 0.5, 0.5], "center": [0.5, 0.5],
                "spans": Array(repeating: [0.25, 0.75], count: 8).flatMap { $0 }]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: value))
        var pixels = NativeRestorationPixels(width: 40, height: 40)
        pixels.rgba = Array(repeating: [UInt8](arrayLiteral: 250, 250, 250, 255), count: pixels.count).flatMap { $0 }
        var repaired = pixels
        repaired.rgba = Array(repeating: [UInt8](arrayLiteral: 210, 220, 230, 255), count: pixels.count).flatMap { $0 }
        repaired.layoutSafe = Array(repeating: 1, count: pixels.count)
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: pixels, crop: CGRect(x: 0, y: 0, width: 40, height: 40),
            source: CGRect(x: 0, y: 0, width: 40, height: 40), box: CGRect(x: 0, y: 0, width: 40, height: 40),
            auxiliary: [], excluded: [], marks: [], leadingRule: false, sx: 1, sy: 1, synthetic: [])
        return (item, prepared, repaired)
    }

    @Test func ordinaryRotatedSpatialProposalClipsByUnitOwnershipRatherThanAngle() throws {
        for rotation in [0.001, 1.0] {
            let (item, prepared, initial) = try fixture(rotation: rotation)
            var repaired = initial
            let cleanupFrame = CGRect(x: 3, y: 9, width: 80, height: 80)
            #expect(NativeTranslationRestoration.clipUnitInterior(item: item, prepared: prepared,
                imageSize: CGSize(width: 40, height: 40), repaired: &repaired, frame: cleanupFrame))
            #expect(repaired.rgba[(20 * 40 + 1) * 4 + 3] == 0 && repaired.layoutSafe?[20 * 40 + 1] == 0)
            #expect(repaired.rgba[(20 * 40 + 20) * 4 + 3] == 255 && repaired.layoutSafe?[20 * 40 + 20] == 1)
            #expect(repaired.rgba[(3 * 40 + 3) * 4 + 3] == 255 && repaired.layoutSafe?[3 * 40 + 3] == 0)
            #expect(item.sourceFrame == [0, 0, 40, 40])
        }
    }

    @Test func detachedSpatialProposalKeepsItsQuadVerifiedPixelsAndSafety() throws {
        let (item, prepared, initial) = try fixture(rotation: 0.001)
        var repaired = initial
        #expect(NativeTranslationRestoration.clipUnitInterior(item: item, prepared: prepared,
            imageSize: CGSize(width: 40, height: 40), repaired: &repaired, detached: true))
        #expect(repaired.rgba == initial.rgba && repaired.layoutSafe == initial.layoutSafe)
    }

    @Test func acceptedRectifiedProposalKeepsItsSlantedProofAtTinyAngles() throws {
        let (item, prepared, initial) = try fixture(rotation: 0.001)
        var repaired = initial
        let proof = NativeSlantedRestoration.ProofRaster(width: 40, height: 40, box: [0, 0, 40, 40],
            safe: try #require(initial.layoutSafe), luminance: Array(repeating: 180, count: initial.count), auxiliary: [])
        #expect(NativeTranslationRestoration.clipUnitInterior(item: item, prepared: prepared,
            imageSize: CGSize(width: 40, height: 40), repaired: &repaired, slantedProof: proof))
        #expect(repaired.rgba == initial.rgba && repaired.layoutSafe == proof.safe)
    }
}
