import CoreGraphics
import Testing
@testable import Aidoku

private final class FinalTrialTestCandidate: NativeFinalRestorationCandidate {
    var trialSurface: NativeResidualTopology.Surface
    init() {
        trialSurface = .init(width: 40, height: 32,
            rgba: Array(repeating: [UInt8](arrayLiteral: 200, 211, 222, 255), count: 1280).flatMap { $0 },
            safe: [UInt8](repeating: 1, count: 1280), luminance: [UInt8](repeating: 100, count: 1280),
            surfaceRevision: 7, coreClear: true, innerCoreClear: false, residualLettering: true)
    }
    func hole(x: Int, y: Int) {
        let i = y * 40 + x
        trialSurface.safe[i] = 0
        trialSurface.rgba.replaceSubrange((i * 4)..<(i * 4 + 4), with: [10, 20, 30, 60])
    }
}
@Suite struct NativeFinalRestorationTrialTests {
    private var geometry: NativeFinalRestorationTrial.Geometry {
        .init(imageSize: CGSize(width: 40, height: 32), frame: CGRect(x: 0, y: 0, width: 40, height: 32),
              cropOrigin: .zero, scale: CGSize(width: 1, height: 1), sourceBounds: [0.25, 0.25, 0.5, 0.5], sourceFontSize: 8)
    }
    private var plate: CGRect { CGRect(x: 10, y: 8, width: 20, height: 16) }

    @Test func sharedPixelsRecheckDropsInitialChromaticExemption() throws {
        let candidate = FinalTrialTestCandidate()
        candidate.hole(x: 15, y: 13); candidate.hole(x: 16, y: 14)
        let coverage = try #require(NativeFinalRestorationTrial.marginCoverage(geometry: geometry,
            sourceFrame: geometry.frame, oldPlate: CGRect(x: 8, y: 6, width: 24, height: 20),
            padding: CGSize(width: 3, height: 4), displayedFontSize: 10))
        #expect(coverage.regions == [[8, 6, 24, 20]] && coverage.core == [[10, 8, 20, 16]])
        #expect(NativeFinalRestorationTrial.certifiesEarlyMargin(surface: candidate.trialSurface, coverage: coverage,
            sourceVertical: false, sourceSingleColumn: true, restorationMethod: "chromatic-balloon-glyphs",
            sourceGlyphsVerified: true, sourceErasureVerified: true))
        #expect(!NativeFinalRestorationTrial.certifiesEarlyMargin(surface: candidate.trialSurface, coverage: coverage,
            sourceVertical: false, sourceSingleColumn: true, restorationMethod: "chromatic-balloon-glyphs",
            sourceGlyphsVerified: true, sourceErasureVerified: true, groupRecheck: true))
    }

    @Test func shortCaptionRejectsIslandAndUndoesEarlierSpeck() {
        let candidate = FinalTrialTestCandidate()
        candidate.hole(x: 12, y: 10)
        for x in 20..<25 { candidate.hole(x: x, y: 18) }
        let before = candidate.trialSurface
        let input = NativeFinalRestorationTrial.ShortCaptionInput(geometry: geometry, plate: plate,
            erasureComplete: true, sourceSingleColumn: true, text: "짧은 글", sourceRemainingInk: 0, fontSize: 10)
        let result = NativeFinalRestorationTrial.shortCaption(candidate: candidate, input: input)
        #expect(!result.accepted && result.unsafe == 5 && result.strokeWidth == nil)
        #expect(candidate.trialSurface.rgba == before.rgba && candidate.trialSurface.safe == before.safe)
        #expect(candidate.trialSurface.luminance == before.luminance && candidate.trialSurface.surfaceRevision == 9)
        #expect(candidate.trialSurface.coreClear == true && candidate.trialSurface.residualLettering == true)
    }

    @Test func shortCaptionCommitsSpeckAndRetainsLargeEdgeArtwork() {
        let candidate = FinalTrialTestCandidate()
        candidate.hole(x: 15, y: 13)
        for y in 0..<16 { candidate.hole(x: 10, y: y) }
        let input = NativeFinalRestorationTrial.ShortCaptionInput(geometry: geometry, plate: plate,
            erasureComplete: true, sourceSingleColumn: true, text: "짧은 글", sourceRemainingInk: 0, fontSize: 10)
        let result = NativeFinalRestorationTrial.shortCaption(candidate: candidate, input: input)
        #expect(result.accepted && result.unsafe == 8 && result.enclosedSpecks == 1)
        #expect(result.strokeWidth == 0.44999999999999996)
        #expect(candidate.trialSurface.safe[13 * 40 + 15] == 1)
        #expect(candidate.trialSurface.safe[8 * 40 + 10] == 0)
    }

    @Test func balloonRejectedGlyphRestoresParentAndSurface() {
        let candidate = FinalTrialTestCandidate(); candidate.hole(x: 15, y: 13)
        let before = candidate.trialSurface
        var g = geometry; g.sourceBounds = [0, 0, 1, 1]
        let input = NativeFinalRestorationTrial.BalloonInput(geometry: g, plate: plate,
            erasureComplete: true, parentIsRoot: false, parentIsPlate: true)
        let budget = NativeFinalRestorationTrial.BalloonBudget()
        var trace: [String] = []
        let callbacks = NativeFinalRestorationTrial.BalloonCallbacks(restorationFitEligible: {
            trace.append("eligible")
            return NativeResidualTopology.restoredErasureCovers(safe: candidate.trialSurface.safe, width: 40, height: 32,
                regions: [[10, 8, 20, 16]], glyphSize: 8, core: [[10, 8, 20, 16]])
        }, completeResidualErasure: { trace.append("unexpected-residual"); return nil }, sourceResidualFilled: { 0 },
        fitBalloon: { trace.append("fit"); return false }, liftNodeFromPlate: { trace.append("lift") },
        restoreNodeToPlate: { trace.append("restore") }, attachProposal: { trace.append("unexpected-attach") },
        detachProposal: { trace.append("unexpected-detach") }, commitRestorationFit: { _, _ in trace.append("unexpected-commit") })
        let result = NativeFinalRestorationTrial.balloonSafeFit(candidate: candidate, input: input, budget: budget, callbacks: callbacks)
        #expect(!result.accepted && result.searched && budget.searches == 1 && budget.successfulFits == 0)
        #expect(trace == ["eligible", "eligible", "lift", "fit", "restore"])
        #expect(candidate.trialSurface.rgba == before.rgba && candidate.trialSurface.safe == before.safe)
        #expect(candidate.trialSurface.luminance == before.luminance && candidate.trialSurface.surfaceRevision == 9)
    }

    @Test func detachedBalloonCommitsOnlyMeasuredSafeGlyphsAndCapsSearches() {
        let candidate = FinalTrialTestCandidate()
        var g = geometry; g.sourceBounds = [0, 0, 1, 1]
        let input = NativeFinalRestorationTrial.BalloonInput(geometry: g, plate: plate, erasureComplete: true,
            provisional: true, localProposalDetached: true, canvasConnected: false)
        let budget = NativeFinalRestorationTrial.BalloonBudget()
        var commits = 0, attaches = 0, detaches = 0
        let callbacks = NativeFinalRestorationTrial.BalloonCallbacks(restorationFitEligible: {
                NativeResidualTopology.restoredErasureCovers(safe: candidate.trialSurface.safe, width: 40, height: 32,
                    regions: [[10, 8, 20, 16]], glyphSize: 8, core: [[10, 8, 20, 16]])
            },
            completeResidualErasure: { nil }, sourceResidualFilled: { 0 }, fitBalloon: {
                NativeResidualTopology.mainbodyCellsClear(safe: candidate.trialSurface.safe, width: 40, height: 32, regions: [[12, 12, 8, 8]])
            }, liftNodeFromPlate: {}, restoreNodeToPlate: {}, attachProposal: { attaches += 1 },
            detachProposal: { detaches += 1 }, commitRestorationFit: { _, local in #expect(local); commits += 1 })
        for _ in 0..<3 {
            #expect(NativeFinalRestorationTrial.balloonSafeFit(candidate: candidate, input: input, budget: budget, callbacks: callbacks).accepted)
        }
        let stopped = NativeFinalRestorationTrial.balloonSafeFit(candidate: candidate, input: input, budget: budget, callbacks: callbacks)
        #expect(!stopped.accepted && !stopped.searched)
        #expect(commits == 3 && attaches == 3 && detaches == 0 && budget.searches == 3)
    }
}
