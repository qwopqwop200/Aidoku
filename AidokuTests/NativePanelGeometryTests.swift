import CoreGraphics
import Testing
@testable import Aidoku

struct NativePanelGeometryTests {
    typealias Geometry = NativePanelGeometry
    private func record(_ id: String, ink: CGRect, source: CGRect, panel: CGRect) -> Geometry.Record {
        .init(id: id, ink: ink, source: source, sources: [source], sourceColorEligible: true,
              sourceTextOnly: false, balancedColumn: false, vertical: false, rotation: 0, font: 16,
              sourceFont: 12, sourceVertical: false, inkPadding: 0, foreground: [0, 0, 0],
              fallbackBackground: [255, 255, 255], panels: [.init(rect: panel, background: [255, 255, 255], coverage: [panel])])
    }

    @Test func anchorCannotJumpAcrossForeignSourceAndBackingRespectsGlyphCollision() {
        let ink = CGRect(x: 8, y: 8, width: 8, height: 8), source = CGRect(x: 40, y: 40, width: 8, height: 8)
        let plate = CGRect(x: 0, y: 0, width: 64, height: 64)
        let shift = Geometry.sourceAnchorShift(ink, source: source, plate: plate, obstacles: [])
        #expect(shift == CGPoint(x: 32, y: 32))
        let blocked = Geometry.sourceAnchorShift(ink, source: source, plate: plate,
            obstacles: [CGRect(x: 24, y: 0, width: 4, height: 64), CGRect(x: 0, y: 24, width: 64, height: 4)])
        #expect(blocked == nil)
        let backing = Geometry.textBackingRect(ink, panel: plate, neighbors: [CGRect(x: 17, y: 8, width: 2, height: 8)])
        #expect(backing == CGRect(x: 7, y: 7, width: 10, height: 10))
        #expect(Geometry.textBackingRect(ink, panel: plate, neighbors: [ink]) == nil)
    }

    @Test func visibleSurfaceUsesPaintOrderAndDoesNotRecoverAnUnreadableOwner() {
        let ink = CGRect(x: 8, y: 8, width: 16, height: 16)
        let layers: [Geometry.Layer] = [.init(rect: ink, color: [80, 80, 80], coverage: [ink]),
            .init(rect: ink, color: [255, 255, 255], coverage: [ink])]
        #expect(Geometry.visiblePanelColors(ink, layers: layers, fallback: [0, 0, 0]) == [[255, 255, 255]])
        #expect(Geometry.needsTextBacking(ink, owner: 0, panels: layers))
        #expect(!Geometry.textBackingKeepsContrast(ink, owner: 0, panels: layers, contrast: {
            NativeTranslationSourceStylePostPolish.sourceColorContrast([0, 0, 0], panel: $0)
        }))
    }

    @Test func finalBalloonClipIncludesForeignSourceAndActualGlyphStroke() {
        let source = CGRect(x: 35, y: 35, width: 24, height: 12), panel = CGRect(x: 8, y: 8, width: 110, height: 60)
        var r = record("a", ink: source, source: source, panel: panel)
        r.balloon = .init(frame: CGRect(x: 0, y: 0, width: 128, height: 128),
            rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), spans: Array(repeating: [0.2, 0.8], count: 16).flatMap { $0 }, contourVerified: true)
        r.glyphs = [source]; r.strokeWidth = 2
        var foreign = record("b", ink: CGRect(x: 70, y: 37, width: 10, height: 8),
            source: CGRect(x: 69, y: 37, width: 12, height: 8), panel: CGRect(x: 69, y: 37, width: 12, height: 8))
        foreign.glyphs = [foreign.ink]
        let result = Geometry.containBalloonPanels([r, foreign])
        #expect(result[0].balloonResult == "rectangular")
        let clip = result[0].panels[0].coverage[0]
        #expect(Geometry.inside(source.insetBy(dx: -1.5, dy: -1.5), clip, tolerance: 0))
        #expect(Geometry.inside(foreign.sources[0], clip, tolerance: 0))
        #expect(result[0].panels[0].rect == panel)
    }

    @Test func balloonReflowRequiresMeasuredGlyphAndOverflowProofBeforeCommit() {
        let source = CGRect(x: 35, y: 35, width: 24, height: 12), panel = CGRect(x: 8, y: 8, width: 110, height: 60)
        var r = record("a", ink: CGRect(x: 20, y: 30, width: 96, height: 15), source: source, panel: panel)
        r.glyphs = [r.ink]
        r.balloon = .init(frame: CGRect(x: 0, y: 0, width: 128, height: 128),
            rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), spans: Array(repeating: [0.2, 0.8], count: 16).flatMap { $0 }, contourVerified: true)
        let rejected = Geometry.containBalloonPanels([r], measure: { _, _, _ in .init(glyphs: [r.ink], scrollFits: false) })
        #expect(rejected[0].balloonResult == "no-safe-rectangle")
        #expect(rejected[0].panels[0].rect == panel)
        #expect(rejected[0].ink == r.ink)
        let accepted = Geometry.containBalloonPanels([r], measure: { _, candidate, font in
            .init(glyphs: [CGRect(x: candidate.minX + 1, y: candidate.minY + 1, width: 48, height: font)], scrollFits: font + 2 <= candidate.height)
        })
        #expect(accepted[0].balloonResult == "reflowed-rectangle")
        #expect(accepted[0].reflowFrame != nil)
        #expect(accepted[0].panels[0].rect == accepted[0].reflowFrame)
        #expect(Geometry.inside(accepted[0].glyphs[0].insetBy(dx: -0.5, dy: -0.5), accepted[0].reflowFrame!, tolerance: 0))
    }
}
