import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRestorationCandidateTests {
    private func item() throws -> NativeTranslationLayoutItem {
        let itemJSON = #"{"id":"candidate","text":"검증","sourceBounds":[0.25,0.25,0.5,0.5],"sourceFrame":[0,0,40,32],"sourceFontSize":8,"x":10,"y":8,"width":20,"height":16,"fontSize":10,"lineHeight":12}"#
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: Data(itemJSON.utf8))
    }
    private func fixture(sourceErasureVerified: Bool? = nil, localProposal: Bool = false) throws -> NativeRestorationCandidate {
        let item = try item()
        var original = NativeRestorationPixels(width: 40, height: 32)
        original.rgba = Array(repeating: [UInt8](arrayLiteral: 100, 110, 120, 255), count: original.count).flatMap { $0 }
        var repaired = original
        repaired.rgba = Array(repeating: [UInt8](arrayLiteral: 200, 210, 220, 255), count: repaired.count).flatMap { $0 }
        repaired.layoutSafe = Array(repeating: 1, count: repaired.count)
        repaired.erasureComplete = true
        repaired.localProposal = localProposal
        repaired.sourceErasureVerified = sourceErasureVerified
        repaired.sourceCorePixels = 72
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: original,
            crop: CGRect(x: 0, y: 0, width: 40, height: 32), source: CGRect(x: 10, y: 8, width: 20, height: 16),
            box: CGRect(x: 10, y: 8, width: 20, height: 16), auxiliary: [], excluded: [], marks: [],
            leadingRule: false, sx: 1, sy: 1, synthetic: [])
        return try #require(NativeRestorationCandidate(prepared: prepared, repaired: repaired,
            luminance: Array(repeating: 100, count: repaired.count), imageSize: CGSize(width: 40, height: 32),
            frame: CGRect(x: 0, y: 0, width: 40, height: 32), item: item))
    }

    @Test func committedTrialInvalidatesPatchRasterAndUndoRestoresAllProofBuffers() throws {
        let candidate = try fixture()
        let baseline = candidate.beginTrial()
        let initial = try #require(candidate.image())
        let initialData = try #require(initial.dataProvider?.data)
        let patch = NativeTranslationRestoration.Patch(image: initial, rect: candidate.frame,
            itemID: "candidate", layoutSafe: baseline.safe, surfaceLuminance: baseline.luminance, candidate: candidate)
        var trial = baseline
        let index = 13 * 40 + 15
        trial.rgba.replaceSubrange(index * 4..<index * 4 + 4, with: [33, 44, 55, 255])
        trial.safe[index] = 0
        trial.luminance[index] = 72
        trial.coreClear = false
        trial.surfaceRevision = 7
        #expect(candidate.commit(trial))
        #expect(candidate.revision == 7)
        #expect(patch.layoutSafe?[index] == 0 && patch.surfaceLuminance?[index] == 72)
        let changedData = try #require(patch.image.dataProvider?.data)
        #expect((changedData as Data) != (initialData as Data))
        candidate.undo(baseline)
        #expect(candidate.revision == 8)
        #expect(candidate.rawRGBA == baseline.rgba && patch.layoutSafe == baseline.safe)
        #expect(patch.surfaceLuminance == baseline.luminance && candidate.surface.coreClear == baseline.coreClear)
        #expect((try #require(patch.image.dataProvider?.data) as Data) == (initialData as Data))
    }

    @Test func malformedTransportDoesNotMutateCandidateOrCachedImage() throws {
        let candidate = try fixture(sourceErasureVerified: false, localProposal: true)
        #expect(candidate.erasureComplete && !candidate.sourceErasureVerified && candidate.sourceCorePixels == 72)
        #expect(candidate.localRestorationProposal && candidate.provisional)
        candidate.provisional = false
        #expect(candidate.localRestorationProposal && !candidate.provisional)
        let baseline = candidate.beginTrial()
        let initial = try #require(candidate.image())
        var malformed = baseline
        malformed.width += 1
        malformed.safe.removeLast()
        #expect(!candidate.commit(malformed))
        #expect(candidate.beginTrial() == baseline && candidate.revision == 0)
        #expect(candidate.image() === initial)
        #expect(candidate.commit(baseline) && candidate.revision == 0)
    }

    @Test func finalForceSkipsReleasedPlateWithoutSpendingBudgetOrDeletingOriginalRepair() throws {
        let candidate = try fixture(), item = try item(), image = try #require(candidate.image())
        let layout = NativeTranslationLayout(imageSize: candidate.imageSize, sourceRect: candidate.frame,
            viewport: candidate.imageSize, items: [item])
        let deferred = NativeDeferredForcedRestoration(image: image, layout: layout)
        var result = NativeTranslationRestoration.Result()
        result.patches = [.init(image: image, rect: candidate.frame, itemID: item.id, candidate: candidate)]
        result.appearances[item.id] = .init(foreground: nil, background: nil, restored: true)
        let reports = try deferred.apply(to: &result, hasReadabilityPanel: { _ in false })
        #expect(reports.count == 1 && reports[0].status == .absentPanel)
        #expect(deferred.remainingPixels == 6_000_000 && result.patches.count == 1)
        #expect(result.patches[0].candidate === candidate && candidate.revision == 0)
        #expect(try deferred.apply(to: &result, hasReadabilityPanel: { _ in true }).isEmpty)
    }

    @Test func finalForceRetainsCompletedPlateButRechecksProvisionalSource() throws {
        let candidate = try fixture(), item = try item(), image = try #require(candidate.image())
        let layout = NativeTranslationLayout(imageSize: candidate.imageSize, sourceRect: candidate.frame,
            viewport: candidate.imageSize, items: [item])
        var result = NativeTranslationRestoration.Result()
        result.patches = [.init(image: image, rect: candidate.frame, itemID: item.id, candidate: candidate)]
        result.appearances[item.id] = .init(foreground: nil, background: nil, restored: true, erasureComplete: true)
        let certified = NativeDeferredForcedRestoration(image: image, layout: layout)
        let skipped = try certified.apply(to: &result, hasReadabilityPanel: { _ in true })
        #expect(skipped[0].status == .alreadyCertified && certified.remainingPixels == 6_000_000)
        candidate.provisional = true
        let provisional = NativeDeferredForcedRestoration(image: image, layout: layout)
        let tried = try provisional.apply(to: &result, hasReadabilityPanel: { _ in true })
        #expect(tried[0].status == .accepted || tried[0].status == .rejected)
        #expect(tried[0].pixels == 40 * 32 && provisional.remainingPixels == 6_000_000 - 40 * 32)
    }

    @Test func finalForceUsesExplicitCleanupFrameWithoutChangingPayloadQuad() throws {
        let candidate = try fixture(), item = try item(), image = try #require(candidate.image())
        candidate.provisional = true
        let frame = CGRect(x: 12, y: 30, width: 80, height: 64)
        let geometry = NativeSourceSurfaceGeometry.Geometry(frame: frame, clip: CGRect(x: 0, y: 0, width: 100, height: 100))
        let layout = NativeTranslationLayout(imageSize: candidate.imageSize, sourceRect: candidate.frame,
            viewport: CGSize(width: 100, height: 100), items: [item])
        var result = NativeTranslationRestoration.Result()
        result.patches = [.init(image: image, rect: candidate.frame, itemID: item.id, candidate: candidate)]
        result.appearances[item.id] = .init(foreground: nil, background: nil, restored: true)
        let deferred = NativeDeferredForcedRestoration(image: image, layout: layout, cleanupGeometry: geometry)
        let reports = try deferred.apply(to: &result, hasReadabilityPanel: { _ in true })
        #expect(reports.count == 1 && reports[0].status == .accepted)
        let patch = try #require(result.patches.first)
        #expect(patch.rect == frame && patch.rasterGeometry?.frame == frame && patch.cleanupClip == geometry.clip)
        #expect(item.sourceFrame == [0, 0, 40, 32] && layout.sourceRect == candidate.frame)
    }


    @Test func acceptedFinalForceRetainsIndependentArtworkCoversInTheirOriginalOrder() throws {
        let candidate = try fixture(), item = try item(), image = try #require(candidate.image())
        candidate.provisional = true
        let layout = NativeTranslationLayout(imageSize: candidate.imageSize, sourceRect: candidate.frame,
            viewport: candidate.imageSize, items: [item])
        let firstRect = CGRect(x: 1, y: 2, width: 3, height: 4), secondRect = CGRect(x: 9, y: 8, width: 7, height: 6)
        var result = NativeTranslationRestoration.Result()
        result.patches = [.init(image: image, rect: firstRect, itemID: item.id, independentArtworkCover: true),
            .init(image: image, rect: candidate.frame, itemID: item.id, candidate: candidate),
            .init(image: image, rect: secondRect, itemID: item.id, independentArtworkCover: true)]
        result.appearances[item.id] = .init(foreground: nil, background: nil, restored: true)
        let deferred = NativeDeferredForcedRestoration(image: image, layout: layout)
        let reports = try deferred.apply(to: &result, hasReadabilityPanel: { _ in true })
        #expect(reports[0].status == .accepted)
        #expect(result.patches.count == 3)
        #expect(result.patches[0].independentArtworkCover && result.patches[0].rect == firstRect)
        #expect(result.patches[1].independentArtworkCover && result.patches[1].rect == secondRect)
        #expect(result.patches[0].image === image && result.patches[1].image === image)
        #expect(!result.patches[2].independentArtworkCover && result.patches[2].finalForcedErasure)
    }


    @Test func rejectedFinalForceRetainsIndependentArtworkCoversInTheirOriginalOrder() throws {
        let candidate = try fixture(), image = try #require(candidate.image())
        let value = #"{"id":"candidate","text":"검증","sourceLettering":"display","sourceBounds":[0.25,0.25,0.5,0.5],"sourceFrame":[0,0,40,32],"sourceFontSize":8,"x":10,"y":8,"width":20,"height":16,"fontSize":10,"lineHeight":12}"#
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: Data(value.utf8))
        candidate.provisional = true
        let layout = NativeTranslationLayout(imageSize: candidate.imageSize, sourceRect: candidate.frame,
            viewport: candidate.imageSize, items: [item])
        let firstRect = CGRect(x: 1, y: 2, width: 3, height: 4), secondRect = CGRect(x: 9, y: 8, width: 7, height: 6)
        var result = NativeTranslationRestoration.Result()
        result.patches = [.init(image: image, rect: firstRect, itemID: item.id, independentArtworkCover: true),
            .init(image: image, rect: candidate.frame, itemID: item.id, candidate: candidate),
            .init(image: image, rect: secondRect, itemID: item.id, independentArtworkCover: true)]
        result.appearances[item.id] = .init(foreground: nil, background: nil, restored: true)
        let deferred = NativeDeferredForcedRestoration(image: image, layout: layout)
        let reports = try deferred.apply(to: &result, hasReadabilityPanel: { _ in true })
        #expect(reports[0].status == .rejected && reports[0].pixels == 40 * 32)
        #expect(deferred.remainingPixels == 6_000_000 - 40 * 32)
        #expect(result.patches.count == 2 && result.appearances[item.id]?.restored == false)
        #expect(result.patches[0].independentArtworkCover && result.patches[0].rect == firstRect)
        #expect(result.patches[1].independentArtworkCover && result.patches[1].rect == secondRect)
        #expect(result.patches[0].image === image && result.patches[1].image === image)
    }

}
