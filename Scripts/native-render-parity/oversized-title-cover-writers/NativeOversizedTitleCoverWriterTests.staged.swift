import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeOversizedTitleCoverWriterTests {
    private func fixture() throws -> NativeTranslationOversizedTitleGloss.Record {
        let owner = CGRect(x: 50, y: 60, width: 200, height: 160)
        let coverage = CGRect(x: 80, y: 90, width: 60, height: 40)
        let panelClip = try #require(NativeCSSCoveragePath.percentageInset(coverage: coverage, owner: owner))
        let backingClip = try #require(NativeCSSCoveragePath.declaration(coverage: [coverage], origin: owner.origin, commands: .relative))
        let panel = NativeTranslationSourceStylePostPolish.Panel(rect: owner,
            background: [240, 235, 230], radius: 5, coverage: [coverage], clipped: true,
            coverageClip: panelClip, captionUnionClipped: false, sourceBridgeClipped: true)
        let backing = NativePanelGeometry.Backing(frame: owner, coverage: [coverage], color: [220, 225, 230],
            captionUnionClipped: false, sourceBridgeClipped: true, clipped: true, coverageClip: backingClip)
        // A single syllable declines the later title-note placement. This isolates
        // the earlier, genuine oversized-source cover resize and CSS clip:none.
        return .init(id: "large-source", text: "가", normalizedSourceBounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            sourceFontSize: 80, rotation: 0, hasRestorationProposal: false, origin: CGPoint(x: 100, y: 110),
            ink: CGRect(x: 100, y: 110, width: 20, height: 10), fontSize: 8,
            panels: [panel], sampledForeground: [0, 0, 0], sampledStroke: nil, sampledBackground: [240, 235, 230], backings: [backing])
    }

    private func refine(_ record: NativeTranslationOversizedTitleGloss.Record) -> NativeTranslationOversizedTitleGloss.Result {
        NativeTranslationOversizedTitleGloss.refining(records: [record], frame: CGRect(x: 0, y: 0, width: 400, height: 400),
            image: nil, keptSources: [], erased: [], measure: { _, _, _, _, _, _ in
                Issue.record("The cover-writer fixture must stop before title-note measurement")
                return .zero
            })
    }

    @Test func sourcePanelAndBackingShareAcceptedResizeAndClearOnlyLiveClip() throws {
        let input = try fixture()
        let result = refine(input)
        let output = try #require(result.records.first)
        let panel = try #require(output.panels.first)
        let backing = try #require(output.backings.first)
        let resized = CGRect(x: 96, y: 106, width: 28, height: 18)
        #expect(panel.rect == resized)
        #expect(backing.frame == resized)
        #expect(panel.coverage == [resized])
        #expect(backing.coverage == [resized])
        #expect(!panel.clipped && panel.coverageClip == nil)
        #expect(!backing.clipped && backing.coverageClip == nil)
        #expect(panel.captionUnionClipped && backing.captionUnionClipped)
        #expect(panel.sourceBridgeClipped && backing.sourceBridgeClipped)
        #expect(panel.background == input.panels[0].background && panel.radius == 5)
        #expect(backing.color == input.backings[0].color)
        #expect(output.preservedErasure && output.backgroundKind == "source-preserved-caption")
        #expect(result.gloss.notes.isEmpty && result.gloss.hiddenIDs.isEmpty)
        // Value input and authored declarations remain intact after transactional refinement.
        #expect(input.panels[0].rect == CGRect(x: 50, y: 60, width: 200, height: 160))
        #expect(input.backings[0].frame == input.panels[0].rect)
        #expect(input.panels[0].clipped && input.backings[0].clipped)
        #expect(!input.panels[0].captionUnionClipped && !input.backings[0].captionUnionClipped)
        let originalInset = try #require(input.panels[0].coverageClip?.inset)
        #expect(originalInset.values == [18.75, 55, 56.25, 15])
        #expect(input.backings[0].coverageClip?.subpaths == [[CGPoint(x: 30, y: 30), CGPoint(x: 90, y: 30), CGPoint(x: 90, y: 70), CGPoint(x: 30, y: 70)]])
    }

    @Test func backingOnlyLiteralCoverIsStillEligibleWithoutSourcePanel() throws {
        var input = try fixture()
        input.panels = []
        let result = refine(input)
        let output = try #require(result.records.first)
        let backing = try #require(output.backings.first)
        #expect(output.panels.isEmpty)
        #expect(backing.frame == CGRect(x: 96, y: 106, width: 28, height: 18))
        #expect(backing.coverage == [backing.frame])
        #expect(!backing.clipped && backing.coverageClip == nil)
        #expect(backing.captionUnionClipped && backing.sourceBridgeClipped)
        #expect(output.preservedErasure)
        #expect(input.backings[0].clipped && input.backings[0].coverageClip != nil)
        #expect(result.gloss.notes.isEmpty)
    }

    @Test func rotatedForeignCoverBlocksGlossWithoutJoiningInitialTrimCovers() throws {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 512)
        func measure(_ id: String, _ text: String, _ size: Double, _ width: Double,
                     _ lineHeight: Double, _ origin: CGPoint) -> CGRect {
            // Same supplied measurement contract as the frozen 40-case policy
            // differential; the genuine production placer performs its search.
            let natural = Double(text.utf16.count) * size * 0.53
            return CGRect(x: origin.x + (width - min(width, natural)) / 2,
                y: origin.y + size * 0.08, width: min(width, natural),
                height: max(1, ceil(natural / width)) * lineHeight * 0.82)
        }
        let origin = CGPoint(x: 115, y: 235)
        let owner = CGRect(x: 40, y: 120, width: 250, height: 270)
        let title = NativeTranslationOversizedTitleGloss.Record(id: "title", text: "거대한 제목",
            normalizedSourceBounds: CGRect(x: 0.15, y: 0.25, width: 0.7, height: 0.5),
            sourceFontSize: 100, rotation: 0, hasRestorationProposal: false, origin: origin,
            ink: measure("title", "거대한 제목", 9, 80, 10.8, origin), fontSize: 9,
            panels: [.init(rect: owner, background: [240, 240, 235], coverage: [owner])],
            sampledForeground: [30, 30, 30], sampledStroke: nil, sampledBackground: [240, 240, 235])
        var foreign = NativeTranslationOversizedTitleGloss.Record(id: "foreign", text: "가",
            normalizedSourceBounds: CGRect(x: 2, y: 2, width: 0, height: 0),
            sourceFontSize: nil, rotation: 0, hasRestorationProposal: false,
            origin: CGPoint(x: 1000, y: 1000), ink: CGRect(x: 1000, y: 1000, width: 10, height: 10), fontSize: 8,
            panels: [], sampledForeground: nil, sampledStroke: nil, sampledBackground: nil)
        func run(_ obstacle: NativeTranslationOversizedTitleGloss.Record) -> NativeTranslationOversizedTitleGloss.Result {
            NativeTranslationOversizedTitleGloss.refining(records: [title, obstacle], frame: frame, image: nil,
                keptSources: [], erased: [], measure: measure, placerFactory: { f, source, fill, ground, _ in
                    NativeTranslationGlossPlacement(frame: f, band: source, fill: fill, ground: ground) { _, _, w, h in
                        Array(repeating: [UInt8(240), 240, 235, 255], count: w * h).flatMap { $0 }
                    }
                })
        }
        let unblocked = run(foreign)
        #expect(unblocked.gloss.notes.count == 1)
        #expect(unblocked.gloss.notes.first?.id == "title")
        #expect(unblocked.records[0].preservedGloss)
        foreign.rotatedCoverFrames = [frame]
        let blocked = run(foreign)
        #expect(blocked.gloss.notes.isEmpty)
        #expect(!blocked.records[0].preservedGloss)
        #expect(blocked.records[0].preservedErasure)
        // Rotated BCR only blocks later placement; the initial trim is still
        // applied to genuine source panels/backings, not to this foreign BCR.
        let trimmed = try #require(blocked.records[0].panels.first)
        let expected = title.ink.insetBy(dx: -4, dy: -4)
        #expect(abs(trimmed.rect.minX - expected.minX) < 1e-12)
        #expect(abs(trimmed.rect.minY - expected.minY) < 1e-12)
        #expect(abs(trimmed.rect.width - expected.width) < 1e-12)
        #expect(abs(trimmed.rect.height - expected.height) < 1e-12)
        #expect(trimmed.captionUnionClipped && !trimmed.clipped && trimmed.coverageClip == nil)
        #expect(blocked.records[1].rotatedCoverFrames == [frame])
        #expect(blocked.records[1].panels.isEmpty && blocked.records[1].backings.isEmpty)
        #expect(title.panels[0].rect == owner && foreign.rotatedCoverFrames == [frame])
    }
}
