import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Full six captured body/art cases, four explicit proof controls, transaction
/// and auxiliary controls, plus seven segmented/neighbor-preservation cases.
@Suite(.serialized)
struct NativeSourceOwnershipMatrixTests {
    private typealias F = NativeSourceRestorationMatrixFixtures

    @Test(arguments: 0..<6)
    func bodyArtworkEvidenceAndExactPixels(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("source-body-art-evidence", index, count: 6), page = try f.pixels(), original = page.rgba
            let palette = f.values["palette"] as? F.Payload
            let result = try #require(F.restore(page, fixture: f, palette: palette), "\(f.id)")
            let body = try #require(f.values["body"] as? Bool), full = try #require(f.values["full"] as? Bool)
            #expect(result.glyphsVerified == body, "\(f.id): body proof remains distinct from complete rectangle erasure")
            #expect(result.sourceErasureVerified == full, "\(f.id): artwork cannot become erasure proof")
            #expect(F.hash(Data(result.rgba)) == f.values["rgbaSHA"] as? String, "\(f.id): exact paint")
            let safe = try #require(result.layoutSafe)
            #expect(F.hash(Data(safe)) == f.values["safeSHA"] as? String, "\(f.id): exact ownership mask")
            #expect(page.rgba == original)
            // Native attempts own their context locally. A fresh call must have
            // the same bytes and proof, independent of the preceding retries.
            let replay = try #require(F.restore(page, fixture: f, palette: palette))
            #expect(replay.rgba == result.rgba && replay.layoutSafe == safe)
            #expect(replay.glyphsVerified == result.glyphsVerified && replay.sourceErasureVerified == result.sourceErasureVerified)
            #expect(page.rgba == original)
        }
    }

    @Test(arguments: 0..<4)
    func explicitUnresolvedAndAuxiliaryProofControls(_ control: Int) throws {
        var page = NativeRestorationPixels(width: 20, height: 20)
        page.rgba = [UInt8](repeating: 255, count: 400 * 4)
        let palette = try #require(NativeRestorationPixels.palette(["foreground": [0, 0, 0], "background": [255, 255, 255],
            "confidence": ["foreground": 1.0, "background": 1.0]]))
        let state = try #require(NativeObservedRestoreState(page, box: CGRect(x: 4, y: 4, width: 12, height: 12),
            palette: palette, options: .init()))
        state.protectedInk = [UInt8](repeating: 0, count: 400)
        state.frameInk = [UInt8](repeating: 0, count: 400)
        state.auxiliary = []
        state.unresolved = control == 1 ? 1 : 0
        state.frameInterior = control == 0 ? 10 : 0
        if control >= 2 { state.auxiliary = [CGRect(x: 4, y: 4, width: 3, height: 3)] }
        if control == 2 { state.protectedInk[105] = 1 }
        if control == 3 { state.frameInk[105] = 1 }
        // This accessor is also consumed by establishMask/certified; no test-side
        // reimplementation of the ownership decision is used.
        let proof = state.ownershipCertificate
        #expect(proof.glyphs == (control == 0))
        #expect(!proof.erasure)
    }

    private func candidate(_ id: String, full: Bool) -> NativeEarlyMarginTrial.Entry {
        let geometry = NativeEarlyMarginPixels.Geometry(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            imageSize: CGSize(width: 40, height: 40), origin: .zero, scale: CGSize(width: 1, height: 1))
        let canvas = NativeEarlyMarginPixels.Canvas(id: id, width: 4, height: 4,
            rgba: [UInt8](repeating: 0, count: 64), safe: [UInt8](repeating: 0, count: 16),
            luminance: [UInt8](repeating: 255, count: 16), geometry: geometry, erasureComplete: true, erasureVerified: full)
        let coverage = NativeFinalRestorationTrial.MarginCoverage(viewportRects: [], regions: [[0, 0, 1, 1]],
            core: [[0, 0, 1, 1]], glyphSize: 4)
        let entry = NativeEarlyMarginTrial.Entry(state: .init(canvas: canvas), coverage: coverage, sourceCorePixels: 100)
        entry.sourceGlyphsVerified = true
        return entry
    }

    private func callbacks(fit: @escaping (NativeEarlyMarginTrial.Entry, NativeEarlyMarginTrial.FitMode) -> Bool)
        -> NativeEarlyMarginTrial.Callbacks {
        .init(publish: { _ in }, refresh: { _ in }, fit: fit, largerPaper: { _, _ in nil },
            replaceCandidate: { _, _, _ in }, sourcePosition: { _ in false }, eligible: { _ in false },
            completeResidual: { _ in nil }, residualKey: { _ in "unchanged" }, commitResidual: { _ in })
    }

    @Test func establishedPlacementPrecedesFreshProofAndFailureRollsBack() {
        let fresh = candidate("new", full: false), prior = candidate("prior", full: true)
        var order: [String] = []
        NativeEarlyMarginTrial.run([fresh, prior], budget: .init(artworkRemaining: 262_144, paperRemaining: 0),
            callbacks: callbacks { entry, _ in order.append(entry.id); return entry.id == "prior" })
        #expect(order == ["prior", "new", "new"])
        #expect(!prior.hasPanel && fresh.hasPanel)
        #expect(!fresh.state.partialCertified && fresh.state.policy == nil)
        #expect(prior.state.metadata["sourceErasureReleased"] == "[]", "Nonrectangular proof cannot release a whole OCR box")
    }

    @Test func unresolvedExplicitAuxiliaryVetoesResidualSpeckRetry() {
        let auxiliary = candidate("auxiliary", full: false)
        auxiliary.sourceGlyphsVerified = false
        auxiliary.sourceRemainingInk = 1
        auxiliary.sourceCorePixels = 100
        auxiliary.coverage.core.append([2, 2, 1, 1])
        var attempted = false
        NativeEarlyMarginTrial.run([auxiliary], budget: .init(artworkRemaining: 262_144, paperRemaining: 0),
            callbacks: callbacks { _, _ in attempted = true; return true })
        #expect(!attempted, "Numeric speck tolerance cannot authorize explicitly owned unresolved auxiliary text")
    }

    @Test(arguments: 0..<6)
    func segmentedRecoveryRetainsUnownedSource(_ index: Int) throws {
        try autoreleasepool {
            let f = try F.load("source-segmented-restoration", index, count: 6), page = try f.pixels(), original = page.rgba
            let palette = try #require(f.values["palette"] as? F.Payload)
            let expected = try #require(f.values["expected"] as? Bool)
            let result = F.restore(page, fixture: f, palette: palette)
            #expect((result != nil) == expected, "\(f.id): reviewed segmented admission")
            #expect(page.rgba == original)
            let replay = F.restore(page, fixture: f, palette: palette)
            #expect((replay != nil) == (result != nil))
            #expect(replay?.rgba == result?.rgba && replay?.layoutSafe == result?.layoutSafe, "\(f.id): retry context is per call")
            #expect(replay?.sourceErasureVerified == result?.sourceErasureVerified)
            guard let output = result else { return }
            let verified = try #require(f.values["verified"] as? Bool)
            #expect(output.sourceErasureVerified == verified, "\(f.id): partial erasure cannot become complete ownership")
            let surface = try #require(output.surfaceQuality), safe = try #require(output.layoutSafe)
            #expect(surface["safe"] as? Bool == true)
            #expect(F.number(surface["rmse"], .infinity) <= 3)
            #expect(F.number(surface["outliers"], .infinity) == 0)
            let protected = f.values["protected"] == nil ? nil : try f.raw("protected")
            let background = F.numbers(palette["background"]), box = F.rect(f.values["b"])
            var remaining = 0, protectedCount = 0, protectedDark = 0, unsafePaint = 0, changedNeighbor = 0
            for i in 0..<page.count {
                let x = i % page.width, y = i / page.width, alpha = Double(output.rgba[i * 4 + 3]) / 255
                if safe[i] == 0 && alpha != 0 { unsafePaint += 1 }
                if !verified && background.count == 3 && Double(x) >= Double(box.minX) && Double(x) < Double(box.maxX) &&
                    Double(y) >= Double(box.minY) && Double(y) < Double(box.maxY) && alpha == 0 {
                    let delta = (0..<3).map { abs(Double(original[i * 4 + $0]) - background[$0]) }.max()!
                    if delta > 40 { remaining += 1 }
                }
                if let protected, protected[i] != 0 {
                    protectedCount += 1
                    if original[(i * 4)..<(i * 4 + 3)].max()! < 110 { protectedDark += 1 }
                    let delta = (0..<3).map { c in
                        abs(alpha * Double(output.rgba[i * 4 + c]) + (1 - alpha) * Double(original[i * 4 + c]) - Double(original[i * 4 + c]))
                    }.max()!
                    if delta > 3 { changedNeighbor += 1 }
                }
            }
            #expect(unsafePaint == 0, "\(f.id): unowned cells cannot receive paint")
            #expect(changedNeighbor == 0, "\(f.id): neighboring OCR-owned lettering changed")
            if !verified { #expect(remaining > 0, "\(f.id): partial recovery retains original non-background pixels") }
            if protected != nil { #expect(protectedCount > 500 && protectedDark > 100, "\(f.id): independent neighbor glyph oracle") }
            #expect(page.rgba == original)
        }
    }

    @Test func segmentedRecoveryCannotLeakIntoSlantedNeighborMask() throws {
        try autoreleasepool {
            let f = try F.load("slanted-dense-recovery-guard", 3, count: 4), page = try f.pixels(), original = page.rgba
            #expect(f.values["name"] as? String == "diverse-4367-g4")
            #expect(F.slanted(page, fixture: f, palette: f.values["palette"] as? F.Payload) == nil,
                "Unsafe neighboring-lettering negative remains rejected")
            #expect(page.rgba == original)
        }
    }
}
