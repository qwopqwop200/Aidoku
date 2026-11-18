import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct NativeFixedFontVerificationCacheTests {
    typealias C = NativeAOTTranslationPageComposer
    typealias N = NativeFinalTextPaintAdmission

    private func image(_ side: Int = 8) throws -> CGImage {
        try NativeMandatoryDisplayStroke.image(
            Array(repeating: UInt8(255), count: side * side * 4), width: side, height: side)
    }

    private func fill(_ image: CGImage, owner: String, x: CGFloat = 24, y: CGFloat = 24,
                      sourceContourOnly: Bool = false) -> C.TranslatedFillPrimitive {
        var value = C.TranslatedFillPrimitive(image: image,
            frame: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height)), fontOutputPixels: 10)
        value.ownerID = owner
        if sourceContourOnly {
            value.sourceContourOnly = true
            value.sourceStyle = .init(sourceFontPixels: 10,
                bands: [.init(rgb: [0, 0, 0], width: 1)], shadow: nil)
        }
        return value
    }

    @Test func clippedVerificationReleasesNewPlanesAndPreservesIncumbent() throws {
        let glyph = try image(), incumbent = try image(3), restored = try image(64)
        try NativeFixedFontRecovery.withMetrics {
            let metrics = try #require(NativeFixedFontRecovery.metrics)
            metrics.recoveryActive = true
            let cache = metrics.cache
            let first = try cache.retain(owner: "incumbent", image: incumbent)
            #expect(first)
            let before = cache.audit
            let candidate = fill(glyph, owner: "candidate", x: 0, y: 0)
            var rejectedByActualVerifier = false
            do {
                _ = try C.verifyFixedFontAdmission(restored: restored, admitted: ([candidate], [[:]]))
                Issue.record("Page-edge clipped mandatory halo must fail actual verification")
            } catch N.Failure.clippedEffects {
                rejectedByActualVerifier = true
            }
            #expect(rejectedByActualVerifier)
            #expect(cache.audit == before)
            let incumbentWasNew = try cache.retain(owner: "incumbent", image: incumbent)
            #expect(!incumbentWasNew)
            #expect(cache.audit == before)
        }
    }

    @Test func collisionRollbackPreservesAlreadyChargedSharedFill() throws {
        let glyph = try image(), restored = try image(64)
        try NativeFixedFontRecovery.withMetrics {
            let metrics = try #require(NativeFixedFontRecovery.metrics)
            metrics.recoveryActive = true
            let cache = metrics.cache
            let first = try cache.retain(owner: "accepted", image: glyph)
            #expect(first)
            let before = cache.audit
            let a = fill(glyph, owner: "a", sourceContourOnly: true)
            let b = fill(glyph, owner: "b", sourceContourOnly: true)
            // This resolved paint mode reuses the exact fill identity; two new halo
            // planes are charged before the real peer collision check rejects it.
            let prepared = try NativeMandatoryDisplayStroke.prepare(fill: glyph, restored: restored,
                fontOutputPixels: 10, fillFrame: a.frame, sourceContourOnly: true)
            #expect(prepared.fill === glyph)
            var collision = false
            do {
                _ = try C.verifyFixedFontAdmission(restored: restored, admitted: ([a, b], [[:], [:]]))
                Issue.record("Overlapping actual owners must fail actual verification")
            } catch N.Failure.finalCollision(_, _) {
                collision = true
            }
            #expect(collision)
            #expect(cache.audit == before)
            let sharedFillWasNew = try cache.retain(owner: "accepted", image: glyph)
            #expect(!sharedFillWasNew)
            #expect(cache.audit == before)
        }
    }

    @Test func partialRetainFailureReleasesEarlierNewHaloOnly() throws {
        let glyph = try image(), restored = try image(64)
        let a = fill(glyph, owner: "a", sourceContourOnly: true)
        let b = fill(glyph, owner: "b", sourceContourOnly: true)
        let prepared = try NativeMandatoryDisplayStroke.prepare(fill: glyph, restored: restored,
            fontOutputPixels: 10, fillFrame: a.frame, sourceContourOnly: true)
        let fillCharge = glyph.bytesPerRow * glyph.height * 4 + 4096
        let haloCharge = prepared.halo.bytesPerRow * prepared.halo.height * 4 + 4096
        try NativeFixedFontRecovery.withMetrics {
            let metrics = try #require(NativeFixedFontRecovery.metrics)
            metrics.cache = .init(maxBytes: fillCharge + haloCharge)
            metrics.recoveryActive = true
            let cache = metrics.cache
            let first = try cache.retain(owner: "accepted", image: glyph)
            #expect(first)
            let before = cache.audit
            var resourceFailure = false
            do {
                _ = try C.verifyFixedFontAdmission(restored: restored, admitted: ([a, b], [[:], [:]]))
                Issue.record("Budget holds only the precharged fill and first new halo")
            } catch let failure as NativeFixedFontRecovery.CacheBudgetFailure {
                #expect(failure.owner == "b")
                #expect(failure.resource == "bytes")
                resourceFailure = true
            }
            #expect(resourceFailure)
            #expect(cache.audit == before)
            let sharedFillWasNew = try cache.retain(owner: "accepted", image: glyph)
            #expect(!sharedFillWasNew)
        }
    }

    @Test func successfulVerificationKeepsItsNewPlanesCharged() throws {
        let glyph = try image(), restored = try image(64)
        try NativeFixedFontRecovery.withMetrics {
            let metrics = try #require(NativeFixedFontRecovery.metrics)
            metrics.recoveryActive = true
            let cache = metrics.cache
            let before = cache.audit
            let candidate = fill(glyph, owner: "candidate")
            let admitted = try N.place([candidate], page: CGRect(x: 0, y: 0, width: 64, height: 64))
            let verified = try C.verifyFixedFontAdmission(restored: restored, admitted: admitted)
            let after = cache.audit
            #expect(cache.pixels > before["chargedPixels"]!)
            #expect(cache.bytes > before["conservativeChargedBytes"]!)
            let painted = try C.mandatoryStrokeLayer(verified: verified, expectedItems: 1, textComplete: true)
            #expect(painted.complete)
            #expect(cache.audit == after)
        }
    }
}
