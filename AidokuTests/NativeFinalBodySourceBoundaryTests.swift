import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Aidoku

/// Integration tests for refineFinalPlacement -> final soft-body targets ->
/// actual retained effect-alpha -> authenticated original-source boundary veto.
/// Synthetic native RGBA only; no CoreText, fixture files, environment mutation,
/// production raster reuse, or mocked admission/boundary closures.
struct NativeFinalBodySourceBoundaryTests {
    private typealias N = NativeFinalTextPaintAdmission
    private typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    private typealias T = (fills: [P], audit: [[String: Any]])
    private let page = CGRect(x: 0, y: 0, width: 240, height: 160)

    private func normalized(_ rect: CGRect) -> [Double] {
        [rect.minX / page.width, rect.minY / page.height,
         rect.width / page.width, rect.height / page.height].map(Double.init)
    }

    private func incumbent() throws -> T {
        // A final, already styled opaque 10x8 primitive. No early bbox proxy:
        // retainedFootprint must read its real RGBA and count all 80 pixels.
        var rgba = [UInt8](repeating: 0, count: 10 * 8 * 4)
        for i in 0..<80 { rgba[i * 4 + 3] = 255 }
        let image = try NativeMandatoryDisplayStroke.image(rgba, width: 10, height: 8)
        let allowed = normalized(CGRect(x: 4, y: 4, width: 232, height: 152))
        let policy = NativeTextExpansionPolicy(allowedRectNormalized: allowed,
            candidates: [allowed], maskCoverage: [1], backgroundRisk: [0], sourceFontPixels: 10,
            kind: "inside-balloon-mask", maskRectNormalized: allowed,
            maskSpansNormalized: [4.0 / 240, 236.0 / 240, 4.0 / 240, 236.0 / 240])
        #expect(policy.valid)
        var fills: [P] = []
        for i in 0..<3 {
            let frame = i == 2 ? CGRect(x: 180, y: 120, width: 10, height: 8)
                : CGRect(x: 50 + i * 40, y: 50, width: 10, height: 8)
            var fill = P(image: image, frame: frame, fontOutputPixels: 10)
            fill.ownerID = ["left", "right", "unrelated-peer"][i]
            fill.hasFinalEffects = true
            fill.textExpansionPolicy = policy
            fill.placementDomain = { [page] in policy.allows($0, page: page) }
            fill.textPlacementGuide = .init(
                rectNormalized: normalized(i < 2 ? frame.offsetBy(dx: 10, dy: 0) : frame),
                horizontal: .left, vertical: .top)
            if i < 2 {
                fill.balloonPlacement = .init(crossAlignment: .start, bodyID: "synthetic-soft-body",
                    rectNormalized: normalized(CGRect(x: 30, y: 30, width: 140, height: 50)),
                    preserveSourceOffsets: true, biasNormalized: [0, 0], flow: .row,
                    paddingEm: 0, gapEm: 0.6, maskSHA256: String(repeating: "a", count: 64), order: i)
                // The guarded pass must actually reactivate inherited soft-body
                // targets, as in the regression, rather than test a no-op.
                fill.balloonTargetRelaxed = true
            }
            fills.append(fill)
        }
        let fixed = try Dictionary(uniqueKeysWithValues: fills.map {
            ($0.ownerID!, try N.retainedFootprint($0).bounds.origin)
        })
        return try N.place(fills, page: page, fixedOrigins: fixed)
    }

    private func source(preservedEdge: Bool) throws -> NativeSourcePhysicalInteriorContext {
        let width = Int(page.width), height = Int(page.height)
        var rgb = [UInt8](repeating: 255, count: width * height * 3)
        let erased = [UInt8](repeating: 0, count: width * height)
        if preservedEdge {
            // Original black rim at x69: incumbent left support is x50..<60,
            // while the new target is x60..<70. The coarse domain permits both.
            for y in 40..<70 {
                for c in 0..<3 { rgb[(y * width + 69) * 3 + c] = 0 }
            }
        }
        var identityBytes = Data(rgb)
        identityBytes.append(Data(erased))
        let identity = SHA256.hash(data: identityBytes).map { String(format: "%02x", $0) }.joined()
        return try #require(NativeSourcePhysicalInteriorContext(rgb: rgb, width: width, height: height,
            erased: erased, sourceIdentity: identity, sourceOpaque: true))
    }

    private func refined(_ before: T, source: NativeSourcePhysicalInteriorContext) -> T {
        // Mirror the cohort-boundary-only host scope. Do not grant the legacy
        // physical-interior consumers a `current` context to make this pass.
        NativeSourceObstructionRecovery.$sourceContext.withValue(nil) {
            NativeSourcePhysicalInteriorContext.$current.withValue(nil) {
                NativeSourcePhysicalInteriorContext.$cohortBoundaryContext.withValue(source) {
                    N.$retainedSourceRiskGate.withValue(nil) {
                        N.refineFinalPlacement(before, page: page)
                    }
                }
            }
        }
    }

    private func verify(_ after: T, preserving before: T) throws {
        #expect(after.fills.count == 3 && after.audit.count == 3)
        let supports = try after.fills.map { try N.retainedFootprint($0) }
        try N.verifyRetainedPlacement(after.fills, footprints: supports, page: page)
        for i in before.fills.indices {
            #expect(supports[i].pixels == 80)
            #expect(page.contains(supports[i].bounds))
            #expect(after.fills[i].placementDomain?(supports[i].bounds) == true)
            #expect(after.audit[i]["pageContained"] as? Bool == true)
            #expect(after.audit[i]["domainContained"] as? Bool == true)
            #expect(after.audit[i]["peerAlphaCollisions"] as? Int == 0)
            #expect(after.audit[i]["peerReadableBlockConflicts"] as? Int == 0)
            #expect(after.fills[i].textPlacementGuide == before.fills[i].textPlacementGuide)
            #expect(after.fills[i].textExpansionPolicy == before.fills[i].textExpansionPolicy)
            #expect(after.fills[i].fontOutputPixels == before.fills[i].fontOutputPixels)
            #expect(try NativeMandatoryDisplayStroke.rgba(after.fills[i].image)
                == NativeMandatoryDisplayStroke.rgba(before.fills[i].image))
            for j in supports.indices where j > i { #expect(!N.intersects(supports[i], supports[j])) }
        }
        #expect(after.fills[2].frame == before.fills[2].frame)
        #expect(after.fills[2].balloonPlacement == before.fills[2].balloonPlacement)
        #expect(after.fills[2].balloonTargetRelaxed == before.fills[2].balloonTargetRelaxed)
    }

    @Test func movedSoftBodyOverPreservedOriginalEdgeIsVetoedAndIncumbentRetained() throws {
        let before = try incumbent(), context = try source(preservedEdge: true)
        // Prove the candidate is otherwise a successful actual native admission:
        // this test must fail without the new guard, not pass on another veto.
        let candidate = try N.place(before.fills, page: page,
            fixedOrigins: ["unrelated-peer": before.fills[2].frame.origin],
            readableBodyIDs: ["synthetic-soft-body"])
        for i in 0..<2 {
            #expect(candidate.fills[i].frame == before.fills[i].frame.offsetBy(dx: 10, dy: 0))
        }
        let oldAlpha = try N.retainedFootprint(before.fills[0])
        let newAlpha = try N.retainedFootprint(candidate.fills[0])
        let independentEdgeProof = context.boundaryClearance(before: oldAlpha, after: newAlpha,
            maximumAllowedDecreasePixels: 0, minimumChannelContrast: 32)
        #expect(independentEdgeProof.allowed == false)
        #expect((independentEdgeProof.audit["adverseAlphaPixels"] as? Int ?? 0) > 0)

        let after = refined(before, source: context)
        #expect(after.fills.map(\.frame) == before.fills.map(\.frame))
        for i in 0..<2 {
            #expect(after.fills[i].balloonTargetRelaxed)
            #expect(after.audit[i]["balloonBodyPlaced"] as? Bool == false)
            #expect(after.audit[i]["finalBodySourceBoundaryIncumbentRetained"] as? Bool == true)
        }
        let check = try #require(after.audit[0]["finalBodySourceBoundaryCheck"] as? [String: Any])
        #expect(check["sourceIdentity"] as? String == context.sourceIdentity)
        // A measured original component may reject first; otherwise the exact
        // new-alpha preserved-edge predicate must reject. Unknown is not enough.
        let status = try #require(check["status"] as? String)
        #expect(status == "known-component-new-alpha-veto"
            || status == "new-alpha-preserved-source-boundary-veto")
        try verify(after, preserving: before)
    }

    @Test func blankAuthenticatedSourceAllowsSafeSoftBodyTargetAndPinsPeer() throws {
        let before = try incumbent(), context = try source(preservedEdge: false)
        let after = refined(before, source: context)
        for i in 0..<2 {
            #expect(after.fills[i].frame == before.fills[i].frame.offsetBy(dx: 10, dy: 0))
            #expect(!after.fills[i].balloonTargetRelaxed)
            #expect(after.audit[i]["balloonBodyPlaced"] as? Bool == true)
            #expect(after.audit[i]["finalBodyTargetsRefined"] as? Bool == true)
            let check = try #require(after.audit[i]["finalBodySourceBoundaryCheck"] as? [String: Any])
            #expect(check["sourceIdentity"] as? String == context.sourceIdentity)
            #expect(check["observationComplete"] as? Bool == true)
            #expect(check["adverseNewAlphaPixels"] as? Int == 0)
        }
        try verify(after, preserving: before)
    }
}
