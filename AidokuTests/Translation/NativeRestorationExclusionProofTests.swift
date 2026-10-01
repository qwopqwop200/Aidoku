import CoreGraphics
import Testing
@testable import Aidoku

struct NativeRestorationExclusionProofTests {
    private let box = CGRect(x: 20, y: 15, width: 30, height: 50)
    private let excluded = CGRect(x: 45, y: 20, width: 15, height: 30)

    private func fixture(paper: UInt8 = 253) throws -> (NativeRestorationPixels, NativeRestorationPixels, NativeRestorationPixels.Palette) {
        var source = NativeRestorationPixels(width: 80, height: 80)
        for index in 0..<source.count { source.paint(index, .init([Double(paper), Double(paper), Double(paper)])) }
        var repaired = NativeRestorationPixels(width: 80, height: 80)
        for index in source.indices(CGRect(x: 28, y: 25, width: 7, height: 9)) {
            source.paint(index, .init([20, 20, 20]))
            repaired.paint(index, .init([Double(paper), Double(paper), Double(paper)]))
        }
        repaired.layoutSafe = [UInt8](repeating: 1, count: source.count)
        repaired.erasureComplete = true
        repaired.glyphsVerified = true
        repaired.sourceErasureVerified = true
        let palette = try #require(NativeRestorationPixels.palette([
            "foreground": [20, 20, 20], "background": [Int(paper), Int(paper), Int(paper)],
            "confidence": ["foreground": 1.0, "background": 1.0]
        ]))
        return (source, repaired, palette)
    }

    @Test(arguments: [UInt8(248), UInt8(253), UInt8(255)])
    func emptyPaperOverlapRetainsProofWithoutPaintingForeignBounds(_ paper: UInt8) throws {
        let (source, repaired, palette) = try fixture(paper: paper)
        let original = source.rgba
        let result = try #require(NativeRestorationPixels.protectExclusions(repaired, original: source,
            box: box, auxiliary: [], excluded: [excluded], palette: palette))
        #expect(result.erasureComplete && result.glyphsVerified && result.sourceErasureVerified == true)
        #expect(result.paintedCount == repaired.paintedCount)
        #expect(source.indices(excluded).allSatisfy { result.rgba[$0 * 4 + 3] == 0 && result.layoutSafe?[$0] == 0 })
        #expect(source.rgba == original)
    }

    @Test(arguments: ["preclipped-ink", "faint-ink", "rim-ink", "transparent", "colored", "no-palette"])
    func unprovenOverlapInvalidatesBoxProofWithoutInventingLostSourceInk(_ condition: String) throws {
        var (source, repaired, palette) = try fixture()
        let overlapPixel = 30 * source.width + 47
        switch condition {
        case "preclipped-ink": source.paint(overlapPixel, .init([20, 20, 20]))
        case "faint-ink": source.paint(overlapPixel, .init([232, 232, 232]))
        case "rim-ink": source.paint(30 * source.width + 44, .init([20, 20, 20]))
        case "transparent": source.rgba[overlapPixel * 4 + 3] = 254
        case "colored": source.paint(overlapPixel, .init([250, 242, 250]))
        default: break
        }
        // This is the important negative: no current patch alpha overlaps the
        // foreign rectangle, but original ink cannot become an empty-paper proof.
        #expect(source.indices(excluded).allSatisfy { repaired.rgba[$0 * 4 + 3] == 0 })
        let original = source.rgba
        let result = try #require(NativeRestorationPixels.protectExclusions(repaired, original: source,
            box: box, auxiliary: [], excluded: [excluded], palette: condition == "no-palette" ? nil : palette))
        #expect(!result.erasureComplete && !result.glyphsVerified)
        // This operation did not remove any painted source pixel. The independent
        // producing algorithm's source-erasure certificate is not a bbox proof.
        #expect(result.sourceErasureVerified == true)
        #expect(source.indices(excluded).allSatisfy { result.rgba[$0 * 4 + 3] == 0 })
        #expect(source.rgba == original)
    }

    @Test func clippingObservedOriginalInkRevokesBothCertificates() throws {
        var (source, repaired, palette) = try fixture()
        let clipped = 30 * source.width + 47
        source.paint(clipped, .init([20, 20, 20]))
        repaired.paint(clipped, .init([253, 253, 253]))
        let result = try #require(NativeRestorationPixels.protectExclusions(repaired, original: source,
            box: box, auxiliary: [], excluded: [excluded], palette: palette))
        #expect(!result.erasureComplete && !result.glyphsVerified && result.sourceErasureVerified == false)
        #expect(result.rgba[clipped * 4 + 3] == 0 && result.layoutSafe?[clipped] == 0)
        #expect(result.paintedCount == repaired.paintedCount - 1)
    }

    @Test func clippingProvenPaperPaddingRetainsIndependentSourceProof() throws {
        var (source, repaired, palette) = try fixture()
        let clipped = 30 * source.width + 47
        repaired.paint(clipped, .init([253, 253, 253]))
        let result = try #require(NativeRestorationPixels.protectExclusions(repaired, original: source,
            box: box, auxiliary: [], excluded: [excluded], palette: palette))
        #expect(result.erasureComplete && result.glyphsVerified && result.sourceErasureVerified == true)
        #expect(result.rgba[clipped * 4 + 3] == 0 && result.layoutSafe?[clipped] == 0)
        #expect(result.paintedCount == repaired.paintedCount - 1)
    }

    @Test func clippingObservedOutlineRevokesIndependentSourceProof() throws {
        var (source, repaired, _) = try fixture()
        let clipped = 30 * source.width + 47
        source.paint(clipped, .init([20, 20, 20]))
        repaired.paint(clipped, .init([120, 140, 160]))
        repaired.observedFill = .init([255, 255, 255])
        repaired.observedStroke = .init([20, 20, 20])
        repaired.observedBacking = .init([120, 140, 160])
        let result = try #require(NativeRestorationPixels.protectExclusions(repaired, original: source,
            box: box, auxiliary: [], excluded: [excluded], palette: nil))
        #expect(!result.erasureComplete && !result.glyphsVerified && result.sourceErasureVerified == false)
        #expect(result.rgba[clipped * 4 + 3] == 0 && result.layoutSafe?[clipped] == 0)
    }

    @Test func paperOverlapCannotUpgradeAnIncompleteRepair() throws {
        var (source, repaired, palette) = try fixture()
        repaired.erasureComplete = false
        repaired.glyphsVerified = false
        repaired.sourceErasureVerified = false
        let result = try #require(NativeRestorationPixels.protectExclusions(repaired, original: source,
            box: box, auxiliary: [], excluded: [excluded], palette: palette))
        #expect(!result.erasureComplete && !result.glyphsVerified && result.sourceErasureVerified == false)
    }
}
