import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeInitialJoinedUnitTests {
    private func item() throws -> NativeTranslationLayoutItem {
        let descriptor: [String: Any] = ["id": "unit", "text": "Joined words", "x": 20, "y": 10, "width": 40, "height": 70,
            "fontSize": 12, "lineHeight": 14.4, "sourceFrame": [0,0,100,100], "sourceBounds": [0.2,0.1,0.4,0.7],
            "unitMemberRects": [[0.2,0.1,0.2,0.2],[0.4,0.4,0.2,0.4]],
            "balloonInterior": ["rect": [0,0,1,1], "center": [0.5,0.5], "spans": [0.3,0.7,0.1,0.9,0.1,0.9,0.2,0.8], "contourVerified": true]]
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
    }

    @Test func actualInitialUnitUsesNativeBandsAndRetainsOriginalPlan() throws {
        let item = try item(), size = CGSize(width: 100, height: 100)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: [item],
            readableRecoveryRemaining: 0, sourceObjectFit: "contain")
        let adjusted = NativeTranslationRenderer.adjustInitialJoinedUnits(layout: layout, restoration: .init())
        #expect(adjusted.items[0].rect == CGRect(x: 23, y: 28, width: 54, height: 69))
        #expect(adjusted.items[0].unitPlannedCard == [20,10,40,70])
        #expect(adjusted.items[0].sourceBounds == item.sourceBounds && adjusted.items[0].fontSize == item.fontSize)
        #expect(adjusted.readableRecoveryRemaining == 0 && adjusted.sourceObjectFit == "contain")
        var residue = NativeTranslationRestoration.Result()
        residue.unitResidueRiskIDs.insert(item.id)
        #expect(NativeTranslationRenderer.adjustInitialJoinedUnits(layout: layout, restoration: residue) == layout)
    }

    @Test func sourceOnlyKeptCaptionBlocksInitialUnitMovement() throws {
        let item = try item(), size = CGSize(width: 100, height: 100)
        let descriptor: [String: Any] = ["id": "kept", "keptLettering": true, "sourceBounds": [0.4,0.3,0.15,0.6], "sourceFrame": [0,0,100,100]]
        let kept = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: [item, kept])
        let adjusted = NativeTranslationRenderer.adjustInitialJoinedUnits(layout: layout, restoration: .init())
        #expect(adjusted.items[0].rect == item.rect && adjusted.items[0].unitPlannedCard == nil)
        #expect(adjusted.items[1] == kept)
    }
}
