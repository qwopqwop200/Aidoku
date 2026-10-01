import Testing
@testable import Aidoku

struct NativeSlantedSourceFrameTests {
    typealias Pixels = NativeRestorationPixels
    typealias RGB = NativeRestorationRGB

    @Test
    func retainConnectedFrameAndKeepIsolatedLetterRepair() throws {
        let ink = RGB([225, 42, 155])
        var page = Pixels(width: 8, height: 8)
        for i in 0..<page.count { page.paint(i, RGB([250, 250, 250])) }
        // The border enters the crop from its left edge; the letter is separate.
        for x in 0...3 { page.paint(4 * 8 + x, ink) }
        page.paint(4 * 8 + 5, ink)
        page.paint(7, RGB([35, 60, 220]))
        let original = page.rgba
        let mask = try #require(NativeSlantedProof.sourceFrameMask(page, foreground: ink))
        var repair = Pixels(width: 8, height: 8)
        for x in 0...3 { repair.paint(4 * 8 + x, RGB([245, 235, 240])) }
        repair.paint(4 * 8 + 5, RGB([245, 235, 240]))
        #expect(NativeSlantedProof.retainSourceFrame(mask, output: &repair.rgba) == 4)
        #expect((0...3).allSatisfy { repair.rgba[(4 * 8 + $0) * 4 + 3] == 0 })
        #expect(repair.rgba[(4 * 8 + 5) * 4 + 3] == 255)
        #expect(mask[7] == 0, "Unrelated source hues are not classified as the lettering frame")
        #expect(page.rgba == original)
    }

    @Test
    func sourceFrameCannotBecomeSafeThroughProofCompletion() throws {
        let ink = RGB([225, 42, 155])
        var page = Pixels(width: 8, height: 8)
        for i in 0..<page.count { page.paint(i, RGB([250, 250, 250])) }
        for x in 0...3 { page.paint(4 * 8 + x, ink) }
        let mask = try #require(NativeSlantedProof.sourceFrameMask(page, foreground: ink))
        var safe = [UInt8](repeating: 1, count: page.count)
        NativeSlantedProof.excludeSourceFrame(mask, w: 8, h: 8, safe: &safe, lw: 8, lh: 8,
            cx: 0, cy: 0, c: 1, s: 0, ox: 0, oy: 0)
        #expect((0...3).allSatisfy { safe[4 * 8 + $0] == 0 && safe[3 * 8 + $0] == 0 })
        #expect(safe[4 * 8 + 5] == 1)
    }

    @Test
    func singlePixelSourceIsBoundedAndNeutralInkDoesNotEnterChromaticGuard() throws {
        let ink = RGB([225, 42, 155])
        var page = Pixels(width: 1, height: 1)
        page.paint(0, ink)
        let mask = try #require(NativeSlantedProof.sourceFrameMask(page, foreground: ink))
        var output = page.rgba, safe: [UInt8] = [1]
        #expect(NativeSlantedProof.retainSourceFrame(mask, output: &output) == 1)
        NativeSlantedProof.excludeSourceFrame(mask, w: 1, h: 1, safe: &safe, lw: 1, lh: 1,
            cx: 0, cy: 0, c: 1, s: 0, ox: 0, oy: 0)
        #expect(output[3] == 0 && safe[0] == 0)
        #expect(NativeSlantedProof.sourceFrameMask(page, foreground: RGB([30, 30, 30])) == nil)
    }
}
