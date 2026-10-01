import CoreGraphics
import Testing
@testable import Aidoku

@Suite struct NativeResidualTopologyTests {
    @Test func residualGlyphVetoDistinguishesSpecksAndContours() {
        let w = 40, h = 32, regions = [[10.0, 8, 16, 12]]
        var safe = [UInt8](repeating: 1, count: w * h)
        safe[12 * w + 16] = 0
        #expect(!NativeResidualTopology.hasResidualLettering(safe: safe, width: w, height: h, regions: regions, glyphSize: 8))
        safe[13 * w + 17] = 0
        #expect(NativeResidualTopology.hasResidualLettering(safe: safe, width: w, height: h, regions: regions, glyphSize: 8))
        safe = [UInt8](repeating: 1, count: w * h)
        for x in 0..<w { safe[2 * w + x] = 0 }
        #expect(!NativeResidualTopology.hasResidualLettering(safe: safe, width: w, height: h, regions: regions, glyphSize: 8))
    }

    @Test func repeatedAttachedGlyphsVetoRelease() {
        let w = 96, h = 80
        var safe = [UInt8](repeating: 1, count: w * h)
        for y in 0..<h { safe[y * w + 89] = 0 }
        let core = [[35.0, 5, 25, 65]]
        #expect(!NativeResidualTopology.hasAttachedLeadingInk(safe: safe, width: w, height: h, core: core, glyph: 20))
        for y in Array(20..<25) + Array(35..<40) { for x in 65..<90 { safe[y * w + x] = 0 } }
        #expect(NativeResidualTopology.hasAttachedLeadingInk(safe: safe, width: w, height: h, core: core, glyph: 20))
    }

    @Test func erasureAndMainbodyKeepDistinctSafeByteContracts() {
        let safe = [UInt8](repeating: 2, count: 40 * 32), regions = [[10.0, 8, 16, 12]]
        #expect(NativeResidualTopology.restoredErasureCovers(safe: safe, width: 40, height: 32, regions: regions, glyphSize: 8, core: regions))
        #expect(!NativeResidualTopology.mainbodyCellsClear(safe: safe, width: 40, height: 32, regions: regions))
        #expect(!NativeResidualTopology.restoredErasureCovers(safe: safe, width: 40, height: 32, regions: regions, glyphSize: 8, core: [[-1, 8, 16, 12]]))
        #expect(!NativeResidualTopology.mainbodyCellsClear(safe: [UInt8](repeating: 1, count: 1280), width: 40, height: 32, regions: Array(repeating: [0, 0, 40, 32], count: 3)))
    }

    @Test func speckRepairInvalidatesProofsAndUndoRestoresBytes() throws {
        let w = 18, h = 16, i = 6 * w + 7
        var surface = NativeResidualTopology.Surface(width: w, height: h,
            rgba: Array(repeating: [UInt8(200), 211, 222, 255], count: w * h).flatMap { $0 },
            safe: [UInt8](repeating: 1, count: w * h), luminance: [UInt8](repeating: 100, count: w * h),
            surfaceRevision: 7, coreClear: true, innerCoreClear: false, residualLettering: true)
        surface.safe[i] = 0
        surface.rgba.replaceSubrange((i * 4)..<(i * 4 + 4), with: [10, 30, 50, 70])
        let original = surface
        let undo = try #require(NativeResidualTopology.fillEnclosedSpecks(surface: &surface))
        #expect(Array(surface.rgba[(i * 4)..<(i * 4 + 4)]) == [200, 211, 222, 255])
        #expect(surface.safe[i] == 1 && surface.luminance[i] == 164)
        #expect(surface.enclosedSpecks == 1 && surface.surfaceRevision == 8)
        #expect(surface.coreClear == nil && surface.innerCoreClear == nil && surface.residualLettering == nil)
        undo.restore(&surface)
        #expect(surface.rgba == original.rgba && surface.safe == original.safe && surface.luminance == original.luminance)
        #expect(surface.surfaceRevision == 9 && surface.enclosedSpecks == nil)
        #expect(surface.coreClear == true && surface.innerCoreClear == false && surface.residualLettering == true)
    }

    @Test func foreignRepaintRespectsOwnershipAndDetachedScope() {
        let rgba: [UInt8] = Array(repeating: [10, 20, 30, 255], count: 40 * 32).flatMap { $0 }
        let count = NativeResidualTopology.hiddenForeignRepaint(width: 40, height: 32, imageSize: CGSize(width: 40, height: 32),
            frame: CGRect(x: 0, y: 0, width: 40, height: 32), cropOrigin: .zero, scale: CGSize(width: 1, height: 1),
            sourceFontSize: 8, sourceBounds: [0.3, 0.3, 0.2, 0.2], auxiliaryInkRects: [],
            plate: CGRect(x: 10, y: 8, width: 25, height: 22), detachedProposal: true, rgba: rgba)
        #expect(count == 1112)
        #expect(NativeResidualTopology.hiddenForeignRepaint(width: 40, height: 32, imageSize: CGSize(width: 40, height: 32),
            frame: CGRect(x: 0, y: 0, width: 40, height: 32), cropOrigin: .zero, scale: CGSize(width: 1, height: 1),
            sourceFontSize: 8, sourceBounds: [0, 0, 1, 1], auxiliaryInkRects: [],
            plate: CGRect(x: 10, y: 8, width: 25, height: 22), detachedProposal: true, rgba: rgba) == 0)
    }
}
