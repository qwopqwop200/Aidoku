import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeKeptSourceRestorationTests {
    private func item(kept: Bool, bounds: [Double], frame: [Double]) throws -> NativeTranslationLayoutItem {
        let value: [String: Any] = ["id": kept ? "kept" : "painted", "text": "검증", "keptLettering": kept,
            "sourceBounds": bounds, "sourceFrame": frame, "sourceFontSize": 10,
            "x": 0, "y": 0, "width": kept ? 0 : 20, "height": kept ? 0 : 20, "fontSize": 10, "lineHeight": 12]
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: value))
    }
    @Test func skippedKeptCardUsesReconstructedAreaAndRestoresPartialGlyphOverlap() throws {
        let kept = try item(kept: true, bounds: [0.25, 0.25, 0.5, 0.5], frame: [100, 200, 160, 128])
        #expect(kept.width == 0 && kept.height == 0)
        let owned = NativeKeptSourceRestoration.reconstructed([kept])
        #expect(owned[0].rect == CGRect(x: 140, y: 232, width: 80, height: 64))
        let zones = NativeKeptSourceRestoration.zones(kept: owned, painted: [])
        let selected = NativeKeptSourceRestoration.select(kept: owned, keptZones: zones, effectZones: [],
            glyphLines: [CGRect(x: 142, y: 234, width: 4, height: 4)],
            covers: [CGRect(x: 130, y: 220, width: 120, height: 100)], image: CGRect(x: 100, y: 200, width: 160, height: 128))
        #expect(selected.collisions.isEmpty && selected.overlaps == ["kept"] && selected.restoredIDs == ["kept"])
        #expect(!selected.pieces.isEmpty)
        #expect(selected.pieces.allSatisfy { NativePanelGeometry.overlap($0, CGRect(x: 142, y: 234, width: 4, height: 4)) == 0 })
    }
    @Test func keptHaloSubtractsPaintedSourceAndUsesExplicitCleanupFrame() throws {
        let kept = try item(kept: true, bounds: [0.25, 0.25, 0.5, 0.5], frame: [100, 200, 160, 128])
        let painted = try item(kept: false, bounds: [0.5, 0.25, 0.25, 0.5], frame: [0, 0, 80, 80])
        let frame = CGRect(x: 100, y: 200, width: 160, height: 128)
        let zones = NativeKeptSourceRestoration.zones(items: [kept, painted], cleanupFrame: frame)
        let cut = CGRect(x: 180, y: 232, width: 40, height: 64)
        #expect(!zones.isEmpty && zones.allSatisfy { NativePanelGeometry.overlap($0.rect, cut) == 0 })
        #expect(zones.contains { $0.rect.minX == 138.5 && $0.rect.minY == 230.5 })
        #expect(NativeKeptSourceRestoration.sourceRect(painted) == CGRect(x: 40, y: 20, width: 20, height: 40))
        #expect(NativeKeptSourceRestoration.sourceRect(painted, cleanupFrame: frame) == cut)
    }
}
