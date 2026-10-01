import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct NativePrimaryOutlinedLetteringTests {
    private func ring(core: [Double] = [10, 10, 10], outline: [Double] = [240, 240, 240],
                      kind: String = "outline", width: Double = 0.08, boxRing: Double? = 0.2,
                      surface: NativeSourceOutlineEvidence.Surface? = nil,
                      structure: NativeSourceOutlineEvidence.Structure = .init(band: 0.85, deep: 0.1, fillN: 80, ringN: 90)) -> NativeSourceOutlineEvidence.Ring {
        .init(core: core, outline: outline, uniform: 0.9, hug: 0.95, width: width, structure: structure,
              boxRing: boxRing, reached: 0.95, exterior: 0.1, kind: kind, surface: surface)
    }

    @Test func vanishedNeutralInkCanRecoverItsSourceRoleButCarriedOutlineCannot() {
        let evidence = ring(structure: .init(band: 0.2, deep: 0.5, fillN: 15, ringN: 10))
        let lost = NativePrimaryOutlinedLettering.State(sample: ["foreground": [240.0, 240, 240]],
            font: 14, foreground: [160, 160, 160], plate: [160, 160, 160])
        let recovery = NativePrimaryOutlinedLettering.decide(ring: evidence, state: lost)
        #expect(recovery.record["rolesForReadability"] as? Bool == true)
        #expect(recovery.record["rolesFromStructure"] as? Bool == true)
        #expect(recovery.rejection == nil)
        let carried = NativePrimaryOutlinedLettering.State(sample: ["foreground": [240.0, 240, 240],
            "widthEvidence": ["samplePixels": 3.0, "relativeToGlyph": 0.2]], font: 14,
            foreground: [230, 230, 230], stroke: [5, 5, 5], strokeWidth: 2, plate: [245, 245, 245])
        let retained = NativePrimaryOutlinedLettering.decide(ring: evidence, state: carried)
        #expect(retained.rejection == "sampled-ink-is-ring")
        #expect(retained.fill == nil)
        #expect(retained.background == nil)
    }

    @Test func haloPlateCannotEraseReadabilityOfAnotherCaption() {
        let evidence = ring(kind: "paper", width: 0.25, boxRing: 0.7)
        var state = NativePrimaryOutlinedLettering.State(sample: ["foreground": [10.0, 10, 10]],
            font: 14, foreground: [10, 10, 10], plate: [10, 10, 10])
        let owned = NativePrimaryOutlinedLettering.decide(ring: evidence, state: state)
        #expect(owned.record["action"] as? String == "halo-plate")
        #expect(owned.background == [240, 240, 240])
        state.overlappingInks = [[240, 240, 240]]
        let shared = NativePrimaryOutlinedLettering.decide(ring: evidence, state: state)
        #expect(shared.background == nil)
        state.overlappingInks = []; state.plateIsAlone = false
        #expect(NativePrimaryOutlinedLettering.decide(ring: evidence, state: state).background == nil)
    }

    @Test func slantedPurpleFillTakesSmallestVerifiedCorrectionAcrossRestoredGradient() {
        let surface = NativeSourceOutlineEvidence.Surface(rgb: [125, 125, 125], flat: false,
            close: 0.8, luminances: [0.1, 0.3, 0.5])
        let evidence = ring(core: [80, 25, 125], outline: [0, 0, 0], boxRing: nil, surface: surface)
        let state = NativePrimaryOutlinedLettering.State(sample: ["foreground": [80.0, 25, 125]],
            font: 24, foreground: [200, 200, 200], plate: [200, 200, 200], restored: true,
            slanted: true, slantedSurfaceLuminance: [0.01, 0.8])
        let correction = NativePrimaryOutlinedLettering.decide(ring: evidence, state: state)
        // Frozen original primary branch: 32 surface samples and 12 bisection steps.
        #expect(correction.fill == [175, 151, 196])
        #expect(correction.stroke == [0, 0, 0])
        #expect(correction.record["slantedPair"] as? Double == 3)
        #expect(correction.record["action"] as? String == "restored-outline")
        #expect(correction.background == nil)
    }

    @Test func sampledSlantedEdgeMovesWithoutReplacingItsWhiteSourceFill() {
        let surface = NativeSourceOutlineEvidence.Surface(rgb: [15, 130, 160], flat: true,
            close: 0.8, luminances: [0.005, 0.01])
        let evidence = ring(core: [255, 255, 255], outline: [60, 60, 60], boxRing: nil, surface: surface)
        let state = NativePrimaryOutlinedLettering.State(sample: ["foreground": [255.0, 255, 255],
            "stroke": [60.0, 60, 60], "confidence": ["stroke": 0.8]], font: 12,
            foreground: [80, 25, 125], plate: [0, 0, 0], restored: true, slanted: true,
            slantedSurfaceLuminance: [0.3, 0.6])
        let correction = NativePrimaryOutlinedLettering.decide(ring: evidence, state: state)
        #expect(correction.fill == [255, 255, 255])
        #expect(correction.stroke == [46, 46, 46])
        #expect(correction.record["outlineRaised"] as? [Double] == [46, 46, 46])
        #expect(correction.record["slantedPair"] as? Double == 4.53)
    }
}
