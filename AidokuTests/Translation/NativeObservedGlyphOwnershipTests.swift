import CoreGraphics
import Testing
@testable import Aidoku

struct NativeObservedGlyphOwnershipTests {
    private let box = CGRect(x: 2, y: 2, width: 12, height: 12)
    private let polygon = [CGPoint(x: 2, y: 2), CGPoint(x: 9, y: 2), CGPoint(x: 14, y: 14), CGPoint(x: 7, y: 14)]

    @Test
    func drawingOutsideQuadDoesNotBecomeAnUnresolvedBodyGlyph() throws {
        let proof = try #require(NativeObservedGlyphOwnership.make(width: 16, height: 16, box: box,
            polygon: polygon, auxiliary: []))
        var protected = [UInt8](repeating: 0, count: 256), frame = protected
        protected[3 * 16 + 13] = 1 // Drawing in bounding-box corner, beyond the quad and its fringe.
        protected[7 * 16 + 8] = 1; frame[7 * 16 + 8] = 1 // Independently classified drawing remains in the body.
        let originalProtected = protected, originalFrame = frame
        #expect(proof.certifiesBodyGlyphs(protectedInk: protected, frameInk: frame))
        #expect(protected == originalProtected && frame == originalFrame)
    }

    @Test
    func remainingInkInsideQuadOrAntialiasFringeStillRejects() throws {
        let proof = try #require(NativeObservedGlyphOwnership.make(width: 16, height: 16, box: box,
            polygon: polygon, auxiliary: []))
        let frame = [UInt8](repeating: 0, count: 256)
        var protected = frame
        protected[7 * 16 + 8] = 1
        #expect(!proof.certifiesBodyGlyphs(protectedInk: protected, frameInk: frame))
        protected = frame; protected[2 * 16 + 9] = 1
        #expect(!proof.certifiesBodyGlyphs(protectedInk: protected, frameInk: frame), "One source-pixel fringe is still owned")
    }

    @Test
    func bodyContainedAuxiliaryDoesNotBecomeASeparateRubyLine() throws {
        let proof = try #require(NativeObservedGlyphOwnership.make(width: 16, height: 16, box: box,
            polygon: polygon, auxiliary: [CGRect(x: 7, y: 6, width: 2, height: 4)]))
        var protected = [UInt8](repeating: 0, count: 256), frame = protected
        protected[8 * 16 + 8] = 1; frame[8 * 16 + 8] = 1
        #expect(proof.certifiesBodyGlyphs(protectedInk: protected, frameInk: frame))
        frame[8 * 16 + 8] = 0
        #expect(!proof.certifiesBodyGlyphs(protectedInk: protected, frameInk: frame), "Unresolved body ink is never dismissed as metadata duplication")
    }

    @Test
    func separateAuxiliaryRetainsInkAndDrawingGuards() throws {
        let proof = try #require(NativeObservedGlyphOwnership.make(width: 16, height: 16, box: box,
            polygon: polygon, auxiliary: [CGRect(x: 11, y: 2, width: 3, height: 3)]))
        var protected = [UInt8](repeating: 0, count: 256), frame = protected
        protected[3 * 16 + 12] = 1
        #expect(!proof.certifiesBodyGlyphs(protectedInk: protected, frameInk: frame))
        frame[3 * 16 + 12] = 1
        #expect(!proof.certifiesBodyGlyphs(protectedInk: protected, frameInk: frame), "A real external auxiliary cannot ignore a drawing contour")
    }

    @Test
    func malformedOrUnrelatedQuadDoesNotSupplyACertificate() {
        let invalid: [[CGPoint]] = [
            [],
            [CGPoint(x: 2, y: 2), CGPoint(x: 14, y: 14), CGPoint(x: 14, y: 2), CGPoint(x: 2, y: 14)],
            [CGPoint(x: CGFloat.nan, y: 2), CGPoint(x: 9, y: 2), CGPoint(x: 14, y: 14), CGPoint(x: 7, y: 14)],
            [CGPoint(x: -1, y: 2), CGPoint(x: 9, y: 2), CGPoint(x: 14, y: 14), CGPoint(x: 7, y: 14)],
            [CGPoint(x: 3, y: 3), CGPoint(x: 8, y: 3), CGPoint(x: 8, y: 8), CGPoint(x: 3, y: 8)],
            [CGPoint(x: 2, y: 2), CGPoint(x: 4, y: 2), CGPoint(x: 8, y: 2), CGPoint(x: 14, y: 2)]
        ]
        for quad in invalid {
            #expect(NativeObservedGlyphOwnership.make(width: 16, height: 16, box: box, polygon: quad, auxiliary: []) == nil)
        }
        #expect(NativeObservedGlyphOwnership.make(width: 16, height: 16, box: box, polygon: polygon,
            auxiliary: [CGRect(x: 15, y: 1, width: 3, height: 3)]) == nil)
    }

    @Test(arguments: 0..<4)
    func inferredAuxiliaryAddedAfterPolygonConstructionRetainsItsVeto(_ control: Int) throws {
        var page = NativeRestorationPixels(width: 20, height: 20)
        page.rgba = [UInt8](repeating: 255, count: 400 * 4)
        let bounds = CGRect(x: 4, y: 4, width: 12, height: 12)
        let quad = [CGPoint(x: 4, y: 4), CGPoint(x: 11, y: 4), CGPoint(x: 16, y: 16), CGPoint(x: 9, y: 16)]
        let external = CGRect(x: 14, y: 4, width: 2, height: 2)
        let contained = CGRect(x: 9, y: 8, width: 2, height: 4)
        var options = NativeObservedRestoreOptions()
        options.auxiliary = control == 3 ? [contained] : []
        options.glyphOwnership = try #require(NativeObservedGlyphOwnership.make(width: 20, height: 20,
            box: bounds, polygon: quad, auxiliary: options.auxiliary))
        let palette = try #require(NativeRestorationPixels.palette(["foreground": [0, 0, 0], "background": [255, 255, 255],
            "confidence": ["foreground": 1.0, "background": 1.0]]))
        let state = try #require(NativeObservedRestoreState(page, box: bounds, palette: palette, options: options))
        state.protectedInk = [UInt8](repeating: 0, count: 400)
        state.frameInk = state.protectedInk
        // This is the same post-construction state change establishMask makes.
        if control != 3 { state.auxiliary.append(external) }
        if control == 1 { state.protectedInk[5 * 20 + 15] = 1 }
        if control == 2 { state.frameInk[5 * 20 + 15] = 1 }
        if control == 3 {
            state.protectedInk[9 * 20 + 10] = 1
            state.frameInk[9 * 20 + 10] = 1
        }
        let protected = state.protectedInk, frame = state.frameInk, original = page.rgba
        let safe = NativeObservedRestorationHelpers.layoutSafe(protected, drawingSurface: state.drawingSurface, n: page.count)
        let result = state.certified(page)
        #expect(result.polygonGlyphsVerified == (control == 0 || control == 3))
        #expect(result.sourceErasureVerified == false && !result.erasureComplete)
        #expect(result.rgba == original && result.layoutSafe == safe)
        #expect(state.protectedInk == protected && state.frameInk == frame)
    }
}
