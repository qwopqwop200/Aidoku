import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRestorationCanvasPolicyTests {
    @available(iOS 16.0, *)
    @Test func maskCanonicalizationPreservesBinaryPixelsAndRejectsGrayBeforeMutation() throws {
        var mask: [UInt8] = [0, 255, 1, 0, 1]
        try NativeMainEnsemblePipeline.canonicalizeMaskBytes(&mask)
        #expect(mask == [0, 255, 255, 0, 255])
        try NativeMainEnsemblePipeline.canonicalizeMaskBytes(&mask)
        #expect(mask == [0, 255, 255, 0, 255])
        var invalid: [UInt8] = [1, 2, 255]
        do {
            try NativeMainEnsemblePipeline.canonicalizeMaskBytes(&invalid)
            Issue.record("Expected nonbinary mask rejection")
        } catch NativeMainEnsemblePipeline.Failure.invalidMask {}
        #expect(invalid == [1, 2, 255])
    }

    @Test func offCropFiniteCoordinatesAreClampedBeforeIntegerConversion() {
        let pixels = NativeRestorationPixels(width:16,height:16)
        for magnitude: CGFloat in [1e20, 1e308] {
            for rect in [CGRect(x:magnitude,y:0,width:1,height:1),
                         CGRect(x:-magnitude,y:0,width:1,height:1),
                         CGRect(x:0,y:magnitude,width:1,height:1),
                         CGRect(x:0,y:-magnitude,width:1,height:1)] {
                #expect(pixels.indices(rect).isEmpty)
            }
        }
        #expect(pixels.indices(CGRect(x:-1e20,y:-1e20,width:2e20,height:2e20)) == Array(0..<256))
        #expect(pixels.indices(CGRect(x:1.25,y:2.75,width:2.5,height:1.1)) == [33,34,35,49,50,51])
        #expect(pixels.indices(CGRect(x:-0.5,y:-0.5,width:2,height:2)) == [0,1,16,17])
        #expect(pixels.indices(CGRect(x:CGFloat.infinity,y:0,width:1,height:1)).isEmpty)
    }
    @Test func ordinaryCanvasCompletionUsesPaintAndPreservedCountsIndependentlyOfCertificate() {
        // Literal frozen object producer1823: erased>0 && preservedPixels===0 && preservedCore===0.
        #expect(NativeRestorationCanvasPolicy.isComplete(paintedCount: 43549, preservedPixels: 0, preservedCore: 0))
        #expect(NativeRestorationCanvasPolicy.isComplete(paintedCount: 1, preservedPixels: 0, preservedCore: 0))
        #expect(!NativeRestorationCanvasPolicy.isComplete(paintedCount: 0, preservedPixels: 0, preservedCore: 0))
        #expect(!NativeRestorationCanvasPolicy.isComplete(paintedCount: -1, preservedPixels: 0, preservedCore: 0))
        #expect(!NativeRestorationCanvasPolicy.isComplete(paintedCount: 43549, preservedPixels: 1, preservedCore: 0))
        #expect(!NativeRestorationCanvasPolicy.isComplete(paintedCount: 43549, preservedPixels: 0, preservedCore: 1))
    }

    @Test func observedGlyphCanvasRetainsItsRepairWithoutPromotingIndependentSourceCertificate() throws {
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: Data(#"{"id":"observed","text":"글자","sourceBounds":[0.25,0.25,0.5,0.5],"sourceFrame":[0,0,16,16],"x":4,"y":4,"width":8,"height":8,"fontSize":8,"lineHeight":10}"#.utf8))
        var original = NativeRestorationPixels(width: 16, height: 16)
        original.rgba = Array(repeating: [UInt8](arrayLiteral: 100, 110, 120, 255), count: original.count).flatMap { $0 }
        var repaired = NativeRestorationPixels(width: 16, height: 16)
        repaired.rgba.replaceSubrange(100 * 4..<100 * 4 + 4, with: [201,202,203,255])
        repaired.layoutSafe = Array(repeating: 1, count: repaired.count)
        repaired.erasureComplete = false
        repaired.sourceErasureVerified = false
        repaired.glyphsVerified = true
        repaired.sourceRemainingInk = 0
        repaired.method = "observed-palette"
        let prepared = NativeSpatialSourceCrop.Prepared(pixels: original, crop: CGRect(x:0,y:0,width:16,height:16),
            source: CGRect(x:4,y:4,width:8,height:8), box: CGRect(x:4,y:4,width:8,height:8), auxiliary:[],
            excluded:[],marks:[],leadingRule:false,sx:1,sy:1,synthetic:Array(repeating:0,count:256))
        let frame = CGRect(x:0,y:0,width:16,height:16)
        let canvasComplete = NativeRestorationCanvasPolicy.isComplete(paintedCount:repaired.paintedCount,
            preservedPixels:repaired.preservedPixels,preservedCore:repaired.preservedCore)
        let candidate = try #require(NativeRestorationCandidate(prepared:prepared,repaired:repaired,
            luminance:Array(repeating:100,count:256),imageSize:frame.size,frame:frame,item:item,
            canvasErasureComplete:canvasComplete))
        #expect(candidate.erasureComplete && candidate.sourceGlyphsVerified && !candidate.sourceErasureVerified)
        #expect(!repaired.erasureComplete && repaired.sourceErasureVerified == false && repaired.paintedCount == 1)
        let image = try #require(candidate.image())
        var result = NativeTranslationRestoration.Result()
        result.patches = [.init(image:image,rect:frame,itemID:item.id,candidate:candidate)]
        result.appearances[item.id] = .init(foreground:nil,background:nil,restored:true,
            erasureComplete:canvasComplete,sourceGlyphsVerified:true)
        let layout = NativeTranslationLayout(imageSize:frame.size,sourceRect:frame,viewport:frame.size,items:[item])
        let final = NativeDeferredForcedRestoration(image:image,layout:layout)
        let reports = try final.apply(to:&result,hasReadabilityPanel:{_ in true})
        #expect(reports.count == 1 && reports[0].status == .alreadyCertified && reports[0].pixels == 0)
        #expect(final.remainingPixels == 6_000_000 && result.patches.count == 1)
        #expect(result.patches[0].candidate === candidate && candidate.rawRGBA == repaired.rgba)
        #expect(candidate.revision == 0 && !candidate.sourceErasureVerified)
    }
    @Test(arguments: [true, false])
    func finalForceReadsCurrentCanvasGlyphCertificateInsteadOfStaleAppearance(candidateGlyphsVerified: Bool) throws {
        // A larger-paper replacement can retain the old Appearance while its
        // current canvas proof changes. The inverse also forbids OR-ing stale proof.
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: Data(#"{"id":"replacement","text":"글자","sourceBounds":[0.25,0.25,0.5,0.5],"sourceFrame":[0,0,16,16],"x":4,"y":4,"width":8,"height":8,"fontSize":8,"lineHeight":10}"#.utf8))
        var original = NativeRestorationPixels(width:16,height:16)
        original.rgba = Array(repeating:[UInt8](arrayLiteral:100,110,120,255),count:256).flatMap{$0}
        var repaired = NativeRestorationPixels(width:16,height:16)
        repaired.rgba.replaceSubrange(100*4..<100*4+4,with:[201,202,203,255])
        repaired.layoutSafe = Array(repeating:1,count:256)
        repaired.erasureComplete = true; repaired.sourceErasureVerified = false
        repaired.glyphsVerified = candidateGlyphsVerified; repaired.method = "enclosed-paper-ink"
        let frame = CGRect(x:0,y:0,width:16,height:16)
        let prepared = NativeSpatialSourceCrop.Prepared(pixels:original,crop:frame,
            source:CGRect(x:4,y:4,width:8,height:8),box:CGRect(x:4,y:4,width:8,height:8),auxiliary:[],
            excluded:[],marks:[],leadingRule:false,sx:1,sy:1,synthetic:Array(repeating:0,count:256))
        let candidate = try #require(NativeRestorationCandidate(prepared:prepared,repaired:repaired,
            luminance:Array(repeating:100,count:256),imageSize:frame.size,frame:frame,item:item,
            sourceErasureVerified:false))
        let image = try #require(candidate.image())
        var result = NativeTranslationRestoration.Result()
        result.patches = [.init(image:image,rect:frame,itemID:item.id,candidate:candidate)]
        result.appearances[item.id] = .init(foreground:nil,background:nil,restored:true,
            erasureComplete:true,sourceGlyphsVerified:!candidateGlyphsVerified)
        let layout = NativeTranslationLayout(imageSize:frame.size,sourceRect:frame,viewport:frame.size,items:[item])
        let final = NativeDeferredForcedRestoration(image:image,layout:layout)
        let reports = try final.apply(to:&result,hasReadabilityPanel:{_ in true})
        #expect(reports.count == 1 && candidate.erasureComplete && !candidate.provisional && !candidate.sourceErasureVerified)
        if candidateGlyphsVerified {
            #expect(reports[0].status == .alreadyCertified && reports[0].pixels == 0)
            #expect(final.remainingPixels == 6_000_000 && result.patches.count == 1)
            #expect(result.patches.first?.candidate === candidate && candidate.rawRGBA == repaired.rgba && candidate.revision == 0)
        } else {
            #expect(reports[0].status == .accepted || reports[0].status == .rejected)
            #expect(reports[0].pixels == 256 && final.remainingPixels == 6_000_000 - 256)
        }
    }

}

extension NativeRestorationCanvasPolicyTests {
    private enum RemovalReadinessProbeFailure: Error { case backendReached }

    private func removalReadinessImage(_ pixel: [UInt8]) throws -> CGImage {
        let bytes = Data(pixel + pixel + pixel + pixel)
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test(arguments: [false, true])
    func zeroRetainedOwnersPreserveExactOriginalWithoutEnteringBackendOrCachedRestoration(hasProposedMask: Bool) throws {
        typealias R = NativeAOTRemovalReadiness
        let original = try removalReadinessImage([17, 63, 109, 255])
        let cachedRestoration = try removalReadinessImage([240, 230, 220, 255])
        let proposedMask: [UInt8] = hasProposedMask ? [0, 255, 255, 0] : [0, 0, 0, 0]
        let plan = try R.restorationPlan(retainedOwners: 0, hasRemovalPixels: proposedMask.contains { $0 != 0 })
        var backendCalls = 0
        // This closure is the real resolve boundary, not a pipeline mock. A
        // mistakenly authorized backend entry fails even before yielding pixels.
        let result = try R.resolve(plan, original: original) {
            backendCalls += 1
            throw RemovalReadinessProbeFailure.backendReached
        }
        let cachedResult = R.resolve(plan, original: original) {
            backendCalls += 1
            return cachedRestoration
        }
        #expect(backendCalls == 0)
        #expect(result === original && cachedResult === original)
        #expect(result !== cachedRestoration && cachedResult !== cachedRestoration)
        #expect(try NativeMandatoryDisplayStroke.rgba(result) == NativeMandatoryDisplayStroke.rgba(original))
        #expect(plan.preserveOriginal && !plan.appliedHasRemovalPixels)
        #expect(plan.proposedHasRemovalPixels == hasProposedMask)
        #expect(plan.audit["backendMayRun"] as? Bool == false)
        #expect(plan.audit["callerRestorationMayBeReused"] as? Bool == false)
        #expect(plan.audit["restorationDisposition"] as? String == R.RestorationInputAuthority.sourcePassThrough.rawValue)
        #expect(plan.audit["erasureMode"] as? String == "replace-retained-text")
        #expect(plan.audit["upstreamTranslationCompletenessVerified"] as? Bool == false)
        #expect(plan.audit["qualityAccepted"] as? Bool == false)
    }

    @Test(arguments: [1, 4096])
    func retainedOwnersWithRemovalPixelsResolveActualRestorationExactlyOnce(retainedOwners: Int) throws {
        typealias R = NativeAOTRemovalReadiness
        let original = try removalReadinessImage([17, 63, 109, 255])
        let restored = try removalReadinessImage([240, 230, 220, 255])
        let plan = try R.restorationPlan(retainedOwners: retainedOwners, hasRemovalPixels: true)
        var backendCalls = 0
        let result = R.resolve(plan, original: original) {
            backendCalls += 1
            return restored
        }
        #expect(backendCalls == 1 && result === restored && result !== original)
        #expect(try NativeMandatoryDisplayStroke.rgba(result) == NativeMandatoryDisplayStroke.rgba(restored))
        #expect(!plan.preserveOriginal && plan.appliedHasRemovalPixels)
        #expect(plan.audit["retainedTranslationOwners"] as? Int == retainedOwners)
        #expect(plan.audit["backendMayRun"] as? Bool == true)
        #expect(plan.audit["originalSourcePassThrough"] as? Bool == false)
        // Authorization is not an upstream completeness or restoration-quality proof.
        #expect(plan.audit["upstreamTranslationCompletenessVerified"] as? Bool == false)
        #expect(plan.audit["qualityAccepted"] as? Bool == false)
    }

    @Test(arguments: [false, true])
    func explicitEraseOnlyRequiresAnActualMaskBeforeCallingRestoration(hasProposedMask: Bool) throws {
        typealias R = NativeAOTRemovalReadiness
        let original = try removalReadinessImage([17, 63, 109, 255])
        let restored = try removalReadinessImage([240, 230, 220, 255])
        let plan = try R.restorationPlan(retainedOwners: 0, hasRemovalPixels: hasProposedMask, mode: .eraseOnly)
        var backendCalls = 0
        let result = R.resolve(plan, original: original) {
            backendCalls += 1
            return restored
        }
        #expect(backendCalls == (hasProposedMask ? 1 : 0))
        #expect(result === (hasProposedMask ? restored : original))
        #expect(plan.preserveOriginal == !hasProposedMask)
        #expect(plan.appliedHasRemovalPixels == hasProposedMask)
        #expect(plan.audit["erasureMode"] as? String == "explicit-erase-only")
        #expect(plan.audit["retainedTranslationOwners"] as? Int == 0)
        #expect(plan.audit["qualityAccepted"] as? Bool == false)
    }

    @Test(arguments: [-1, 4097, Int.min, Int.max])
    func restorationPlanRejectsInvalidRetainedCountsBeforeAnyResolve(retainedOwners: Int) {
        typealias R = NativeAOTRemovalReadiness
        for mode in [R.ErasureMode.retainedText, .eraseOnly] {
            for hasMask in [false, true] {
                do {
                    _ = try R.restorationPlan(retainedOwners: retainedOwners, hasRemovalPixels: hasMask, mode: mode)
                    Issue.record("Invalid retained owner count was accepted")
                } catch R.Failure.invalidRetainedOwnerCount(let rejected) {
                    #expect(rejected == retainedOwners)
                } catch {
                    Issue.record("Wrong failure for invalid retained owner count: \(error)")
                }
            }
        }
    }

    @Test(arguments: [1, 4096])
    func retainedOwnersWithoutMaskAndEraseOnlyWithOwnersFailWithTheirSpecificContracts(retainedOwners: Int) {
        typealias R = NativeAOTRemovalReadiness
        do {
            _ = try R.restorationPlan(retainedOwners: retainedOwners, hasRemovalPixels: false)
            Issue.record("Retained replacement was authorized without a removal mask")
        } catch R.Failure.translatedOwnersWithoutRemovalMask(let rejected) {
            #expect(rejected == retainedOwners)
        } catch {
            Issue.record("Wrong missing-mask failure: \(error)")
        }
        for hasMask in [false, true] {
            do {
                _ = try R.restorationPlan(retainedOwners: retainedOwners, hasRemovalPixels: hasMask, mode: .eraseOnly)
                Issue.record("Explicit erase-only accepted retained text owners")
            } catch R.Failure.eraseOnlyHasRetainedOwners(let rejected) {
                #expect(rejected == retainedOwners)
            } catch {
                Issue.record("Wrong erase-only owner failure: \(error)")
            }
        }
    }

    @Test func authorizedRestorationPropagatesBackendFailureWithoutSilentlyReturningOriginal() throws {
        typealias R = NativeAOTRemovalReadiness
        let original = try removalReadinessImage([17, 63, 109, 255])
        for mode in [R.ErasureMode.retainedText, .eraseOnly] {
            let plan = try R.restorationPlan(retainedOwners: mode == .retainedText ? 1 : 0,
                hasRemovalPixels: true, mode: mode)
            var backendCalls = 0
            do {
                _ = try R.resolve(plan, original: original) {
                    backendCalls += 1
                    throw RemovalReadinessProbeFailure.backendReached
                }
                Issue.record("An authorized backend failure was swallowed")
            } catch RemovalReadinessProbeFailure.backendReached {
                #expect(backendCalls == 1)
            }
        }
    }
}
