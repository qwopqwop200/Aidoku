import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRestorationCanvasPolicyTests {
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
