import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

private final class NativeDottedPaperFrameFixtureBundle: NSObject {}

@Suite(.serialized)
@MainActor
struct NativeDottedPaperFrameTests {
    private let box = CGRect(x: 24, y: 23.890076335877865, width: 41, height: 108.50076335877863)
    // Source-only review of the fixed crop, independent of the candidate mask.
    private let frameIDs: Set<Int> = [0, 5, 6, 9, 11, 14, 17, 20, 21, 23, 24, 26, 30, 34, 36, 37, 35, 32, 29, 27, 25, 13]
    private let glyphIDs: Set<Int> = [7, 8, 15, 18, 22, 28, 31, 33]

    private func source() throws -> NativeRestorationPixels {
        let url = try #require(Bundle(for: NativeDottedPaperFrameFixtureBundle.self)
            .url(forResource: "SmallBalloonRestorationOriginal", withExtension: "bin"))
        let data = try Data(contentsOf: url)
        let cgImage = try #require(UIImage(data: data)?.cgImage)
        let reader = NativeSourcePixelReader(image: cgImage)
        defer { reader.release() }
        var p = NativeRestorationPixels(width: 89, height: 163)
        p.rgba = try reader.read(x: 935, y: 128, sourceWidth: 89, sourceHeight: 163.75, width: 89, height: 163)
        try #require(SHA256.hash(data: Data(p.rgba)).map { String(format: "%02x", $0) }.joined() ==
            "7e16ad54bcd2cc5021c4ca1198c2e03920d9946b039c988c3b591187583c4106")
        return p
    }
    private func parts(_ p: NativeRestorationPixels) -> [NativeRestorationPixels.Component] {
        p.components((0..<p.count).map { p.color($0).minimum < 230 ? 1 : 0 })
    }
    private func whiteCandidate(_ p: NativeRestorationPixels) -> NativeRestorationPixels {
        var result = NativeRestorationPixels(width: p.width, height: p.height)
        for i in 0..<p.count { result.paint(i, .init([255, 255, 255])) }
        result.layoutSafe = [UInt8](repeating: 1, count: p.count)
        result.sourceErasureVerified = true; result.glyphsVerified = true; result.polygonGlyphsVerified = true
        result.erasureComplete = false
        return result
    }
    private func paint(_ p: inout NativeRestorationPixels, _ rect: CGRect, gray: Double = 120) -> [Int] {
        let indices = p.indices(rect)
        for i in indices { p.paint(i, .init([gray, gray, gray])) }
        return indices
    }

    @Test func realContourClipsBothSidesAndKeepsEveryOtherSourceInkPixel() throws {
        let p = try source(), components = parts(p)
        let mask = try #require(NativeDottedPaperFrame.mask(p, box: box))
        let candidate = whiteCandidate(p)
        let protected = NativeDottedPaperFrame.protecting(p, box: box, vertical: true, repaired: candidate)
        var frame = 0, lettering = 0
        for k in components.indices { for i in components[k].points {
            if frameIDs.contains(k) {
                frame += 1
                #expect(mask[i] != 0 && protected.rgba[i * 4 + 3] == 0 && protected.layoutSafe?[i] == 0)
            } else {
                #expect(mask[i] == 0 && protected.rgba[i * 4 + 3] == 255,
                    "Nearby body, real ellipsis and neighboring lettering cannot become frame")
            }
            if glyphIDs.contains(k) { lettering += 1 }
        } }
        #expect(frame == 657 && lettering == 502)
        #expect(protected.sourceErasureVerified == false && !protected.glyphsVerified && !protected.polygonGlyphsVerified)
        #expect(!protected.erasureComplete)
        let unchanged = try source()
        let sourceUnchanged = p.rgba == unchanged.rgba
        #expect(sourceUnchanged)
    }

    @Test func nearbyExternalRubyAndEllipsisAreNotPartOfTheFramePath() throws {
        var p = try source()
        var added: [Int] = []
        for y in [90, 95, 100] { added += paint(&p, CGRect(x: 14, y: y, width: 2, height: 2)) }
        for x in [35, 42, 49] { added += paint(&p, CGRect(x: x, y: 70, width: 2, height: 2)) }
        let mask = try #require(NativeDottedPaperFrame.mask(p, box: box))
        #expect(added.allSatisfy { mask[$0] == 0 })
    }

    @Test func aTextLikeChainBetweenTheSameFrameAnchorsCannotProveAContour() throws {
        let original = try source(), components = parts(original)
        var p = whiteCandidate(original)
        for k in [0, 13] { for i in components[k].points { p.paint(i, original.color(i)) } }
        for y in stride(from: 38, through: 86, by: 3) {
            let x = 48 + Int((Double(y - 38) * 15 / 50).rounded())
            _ = paint(&p, CGRect(x: x, y: y, width: 2, height: 2))
        }
        #expect(NativeDottedPaperFrame.mask(p, box: box) == nil)
    }

    @Test(arguments: ["cycle", "transverse-glyph", "broken-arc"])
    func ambiguousOrIncompleteSourceEvidenceAbstains(_ condition: String) throws {
        var p = try source()
        let components = parts(p)
        switch condition {
        case "cycle":
            _ = paint(&p, CGRect(x: 55, y: 118, width: 1, height: 1))
            _ = paint(&p, CGRect(x: 55, y: 120, width: 1, height: 1))
        case "transverse-glyph":
            _ = paint(&p, CGRect(x: 20, y: 77, width: 11, height: 2))
        case "broken-arc":
            for i in components[23].points { p.paint(i, .init([255, 255, 255])) }
        default: break
        }
        let candidate = whiteCandidate(p)
        #expect(NativeDottedPaperFrame.mask(p, box: box) == nil)
        let unchangedRepair = NativeDottedPaperFrame.protecting(p, box: box, vertical: true, repaired: candidate).rgba == candidate.rgba
        #expect(unchangedRepair)
    }

    @Test func clippingCannotCreateOrInvalidateAnUnrelatedErasureCertificate() throws {
        let p = try source()
        var candidate = p
        candidate.layoutSafe = [UInt8](repeating: 1, count: p.count)
        candidate.sourceErasureVerified = true; candidate.glyphsVerified = true; candidate.polygonGlyphsVerified = true
        let noPaint = NativeDottedPaperFrame.protecting(p, box: box, vertical: true, repaired: candidate)
        #expect(noPaint.sourceErasureVerified == true && noPaint.glyphsVerified && noPaint.polygonGlyphsVerified)
        #expect(!noPaint.erasureComplete)
        candidate.erasureComplete = true
        let unchangedRepair = NativeDottedPaperFrame.protecting(p, box: box, vertical: true, repaired: candidate).rgba == candidate.rgba
        #expect(unchangedRepair)
        #expect(NativeDottedPaperFrame.mask(p, box: CGRect(x: CGFloat.infinity, y: 0, width: 40, height: 100)) == nil)
    }

    private func ownedGlyphRepair(_ p: NativeRestorationPixels) -> NativeRestorationPixels {
        var result = NativeRestorationPixels(width: p.width, height: p.height)
        result.layoutSafe = [UInt8](repeating: 1, count: p.count)
        let components = parts(p)
        for k in glyphIDs { for i in components[k].points { result.paint(i, .init([255, 255, 255])) } }
        return NativeDottedPaperFrame.protecting(p, box: box, vertical: true, repaired: result)
    }

    private func pageGate(_ p: NativeRestorationPixels, _ repaired: NativeRestorationPixels) -> NativeRestorationPixels? {
        NativeSlantedProof.pageErasureInQuad(original: p, result: repaired, sx: 1, sy: 163 / 163.75, ox: 935, oy: 128,
            quad: [962.9310024876094, 152.5910695090333, 33.13799502478138, 107.3178609819334],
            angle: -0.07503234883961765, auxiliary: [],
            palette: .init(foreground: .init([56, 56, 56]), background: .init([254, 254, 254])))?.result
    }

    @Test func frameOnlyAllowsReflowAfterIndependentPageErasureProof() throws {
        let p = try source(), protected = ownedGlyphRepair(p)
        #expect(protected.dottedFrameProtection != nil)
        #expect(!NativeDottedPaperFrame.permitsNarrowReflow(protected))
        let gated = try #require(pageGate(p, protected))
        #expect(NativeDottedPaperFrame.permitsNarrowReflow(gated))
        #expect(!gated.erasureComplete && !gated.glyphsVerified && !gated.polygonGlyphsVerified)
        #expect(gated.sourceErasureVerified != true)
        let pixelsUnchanged = gated.rgba == protected.rgba
        let maskUnchanged = gated.layoutSafe == protected.layoutSafe
        #expect(pixelsUnchanged && maskUnchanged)
        var noErasure = protected
        for i in 0..<noErasure.count { noErasure.rgba[i * 4 + 3] = 0 }
        #expect(pageGate(p, noErasure) == nil, "A frame proof cannot stand in for owned source erasure")
        var noFrame = protected
        noFrame.dottedFrameProtection = nil
        let ordinaryPage = try #require(pageGate(p, noFrame))
        #expect(!NativeDottedPaperFrame.permitsNarrowReflow(ordinaryPage))
    }

    @Test(arguments: ["painted-frame", "safe-frame", "unresolved-auxiliary", "protected-source", "truncated-pixels", "truncated-mask"])
    func alteredFrameOrUnresolvedSourceCannotEnableReflow(_ condition: String) throws {
        let p = try source()
        var gated = try #require(pageGate(p, ownedGlyphRepair(p)))
        let mask = try #require(gated.dottedFrameProtection?.mask)
        let frame = try #require(mask.firstIndex(of: 1))
        switch condition {
        case "painted-frame": gated.rgba[frame * 4 + 3] = 255
        case "safe-frame": gated.layoutSafe?[frame] = 1
        case "unresolved-auxiliary": gated.preservedCore = 1
        case "protected-source": gated.preservedPixels = 1
        case "truncated-pixels": gated.rgba.removeLast()
        case "truncated-mask": gated.layoutSafe?.removeLast()
        default: Issue.record("Unknown negative fixture")
        }
        #expect(!NativeDottedPaperFrame.permitsNarrowReflow(gated))
    }
}
