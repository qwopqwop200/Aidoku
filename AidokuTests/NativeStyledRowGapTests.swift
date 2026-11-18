import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeStyledRowGapTests {
    typealias G = NativeStyledRowGap
    typealias N = NativeFinalTextPaintAdmission
    typealias Composer = NativeAOTTranslationPageComposer
    private func runs(_ values:[(Int,Int,Int)])->[N.Run] {
        values.map{N.Run(y:$0.0,left:$0.1,right:$0.2)}
    }
    private func image(_ width:Int=2,_ height:Int=2)throws->CGImage {
        let context=try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:0,alpha:1))
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        return try #require(context.makeImage())
    }
    private func tuple(_ carrier:CGImage)->G.Tuple {
        let fill=Composer.TranslatedFillPrimitive(image:carrier,
            frame:CGRect(x:0,y:0,width:carrier.width,height:carrier.height),fontOutputPixels:20,ownerID:"owner")
        return ([fill],[["owner":"owner"]])
    }
    @Test func completedMetricUsesCurrentVerifiedSupportAfterMovingStyledPeer() throws {
        guard G.enabled else { return }
        let restored = try image(144, 80), glyph = try image(10, 8)
        let page = CGRect(x: 0, y: 0, width: 144, height: 80)
        var left = Composer.TranslatedFillPrimitive(image: glyph,
            frame: CGRect(x: 25, y: 25, width: 10, height: 8), fontOutputPixels: 10,
            displayStrokeEndpoint: 255, ownerID: "left")
        left.sourceStyle = .init(sourceFontPixels: 10, bands: [.init(rgb: [12, 29, 44], width: 1)],
            shadow: .init(rgb: [0, 0, 0], offset: [2.5, 1.5]))
        var right = left
        right.ownerID = "right"
        var prior: Composer.FixedFontVerifiedAdmission?
        var gaps: [Int] = []
        for x in [65, 78] {
            right.frame.origin.x = CGFloat(x)
            let tuple = try N.place([left, right], page: page)
            let verified = try Composer.verifyFixedFontAdmission(restored: restored, admitted: tuple, reusing: prior)
            let layer = try Composer.mandatoryStrokeLayer(verified: verified, expectedItems: 2, textComplete: true)
            var published = try #require(layer.audit["completedStyledRowPairMetric"] as? [String: Any])
            let freshLayers = try tuple.fills.map { fill in
                try NativeMandatoryDisplayStroke.prepare(fill: fill.image, restored: restored,
                    fontOutputPixels: fill.fontOutputPixels, fillFrame: fill.frame, forcedEndpoint: fill.displayStrokeEndpoint)
            }
            var fresh = try G.measure(fills: tuple.fills, layers: freshLayers, audit: tuple.audit)
            fresh.removeValue(forKey: "seconds")
            published.removeValue(forKey: "seconds")
            #expect(NSDictionary(dictionary: published).isEqual(to: fresh))
            let pairs = try #require(published["pairs"] as? [[String: Any]])
            let horizontal = try #require(pairs.first { $0["axis"] as? String == "horizontal" })
            gaps.append(try #require(horizontal["minimumGapPixels"] as? Int))
            prior = verified
        }
        #expect(gaps[1] - gaps[0] == 13)
    }

    @Test func rejectedPlacementNeverPublishesVerifiedSupport() throws {
        let restored = try image(40, 40), glyph = try image(8, 8)
        let rect = CGRect(x: 12, y: 12, width: 8, height: 8)
        var fill = Composer.TranslatedFillPrimitive(image: glyph, frame: rect, fontOutputPixels: 10)
        fill.placementDomain = { _ in false }
        let prepared = try NativeMandatoryDisplayStroke.prepare(fill: glyph, restored: restored,
            fontOutputPixels: 10, fillFrame: rect)
        var published = false
        do {
            _ = try N.verify([fill], layers: [prepared], page: CGRect(x: 0, y: 0, width: 40, height: 40)) { _ in
                published = true
            }
            Issue.record("Expected the final domain guard to reject the glyph")
        } catch N.Failure.clippedEffects {}
        #expect(!published)
    }
    @Test func enabledByDefaultWithExplicitDisable() {
        for value in ["","0","true","yes","01"," 1","1 "] {
            #expect(!G.enabled(in:["AIDOKU_STYLED_ROW_GAP":value]))
        }
        #expect(G.enabled(in:[:]))
        #expect(G.enabled(in:["AIDOKU_STYLED_ROW_GAP":"1"]))
    }
    @Test func sameBBoxGapCanHideRaggedRowCrowding() throws {
        let a=G.envelopes(runs([(0,0,10),(1,0,90)]))
        let actual=G.envelopes(runs([(0,97,110),(1,177,190)]))
        let crowded=G.envelopes(runs([(0,97,110),(1,97,110)]))
        let bboxActual=actual.map(\.left).min()!-a.map(\.right).max()!
        let bboxCrowded=crowded.map(\.left).min()!-a.map(\.right).max()!
        #expect(bboxActual==7 && bboxCrowded==7)
        #expect(try #require(G.horizontal(a,actual)).gap==87)
        #expect(try #require(G.horizontal(a,crowded)).gap==7)
    }
    @Test func mergesDisjointRunsIntoConservativeEnvelope() throws {
        let x=G.envelopes(runs([(4,0,3),(4,8,10)]))
        #expect(x.count==1)
        #expect(try #require(x.first).left==0)
        #expect(try #require(x.first).right==10)
    }
    @Test func missingCommonRowsDoesNotInventGap() {
        #expect(G.horizontal(G.envelopes(runs([(0,0,10)])),G.envelopes(runs([(5,97,110)])))==nil)
    }
    @Test func touchingAndOverlappingEnvelopesRemainVisible() throws {
        let left=G.envelopes(runs([(0,0,10)]))
        #expect(try #require(G.horizontal(left,G.envelopes(runs([(0,10,20)])))).gap==0)
        #expect(try #require(G.horizontal(left,G.envelopes(runs([(0,8,20)])))).gap == -2)
    }
    @Test func integerTranslationChangesGapExactly() throws {
        let a=G.envelopes(runs([(0,0,10),(1,0,90)]))
        let b=G.envelopes(runs([(0,97,110),(1,177,190)]))
        let shifted=b.map{G.Envelope(y:$0.y,left:$0.left+9,right:$0.right+9)}
        #expect(try #require(G.horizontal(a,shifted)).gap==96)
    }
    @Test func rejectsStaleOrIncompleteCompletedMetric() {
        let admission:[[String:Any]]=[["owner":"owner","finalFootprintOutputPixels":[1,2,3,4],"paintedPixels":7]]
        func metric(_ bounds:[Int]=[1,2,3,4],pixels:Int=7,owner:String="owner",complete:Bool=true)->[String:Any] {
            ["complete":complete,"owners":[["owner":owner,"bounds":bounds,"pixels":pixels]]]
        }
        #expect(G.metricIsCurrent(metric(),admission:admission))
        #expect(!G.metricIsCurrent(metric([2,2,3,4]),admission:admission))
        #expect(!G.metricIsCurrent(metric(pixels:8),admission:admission))
        #expect(!G.metricIsCurrent(metric(owner:"peer"),admission:admission))
        #expect(!G.metricIsCurrent(metric(complete:false),admission:admission))
        #expect(!G.metricIsCurrent(metric(),admission:admission+admission))
        #expect(!G.metricIsCurrent(nil,admission:admission))
    }
    @Test func captureDoesNotRetainCompositeImage() throws {
        let capture=G.CompletedTupleCapture()
        let t=tuple(try image())
        weak var weakComposite:CGImage?
        try autoreleasepool {
            let page=try image(3,3)
            weakComposite=page
            #expect(capture.observe(page,t.fills,t.audit))
            #expect(capture.stats().entries==1)
        }
        #expect(weakComposite==nil)
        #expect(capture.stats().entries==0)
    }
    @Test func sharedCarrierIsChargedOnceAcrossLiveCompletions() throws {
        let capture=G.CompletedTupleCapture()
        let carrier=try image(),a=try image(3,3),b=try image(4,4)
        let t=tuple(carrier)
        #expect(capture.observe(a,t.fills,t.audit))
        #expect(capture.observe(b,t.fills,t.audit))
        #expect(capture.stats().entries==2)
        #expect(capture.stats().uniqueCarrierImages==1)
        #expect(capture.stats().carrierPixels==carrier.width*carrier.height)
        #expect(capture.stats().carrierRowBytes==carrier.bytesPerRow*carrier.height)
        #expect(capture.stats().conservativeChargedBytes==carrier.bytesPerRow*carrier.height*4+2*4096)
    }
    @Test func captureEnforcesEntryPixelAndByteCaps() throws {
        let carrier=try image(),a=try image(3,3),b=try image(4,4);let t=tuple(carrier)
        let entries=G.CompletedTupleCapture(entryLimit:1)
        #expect(entries.observe(a,t.fills,t.audit))
        #expect(!entries.observe(b,t.fills,t.audit))
        #expect(!G.CompletedTupleCapture(pixelLimit:1).observe(a,t.fills,t.audit))
        #expect(!G.CompletedTupleCapture(byteLimit:1).observe(a,t.fills,t.audit))
    }
    @Test func rejectsCompositeAliasedAsCarrier() throws {
        let composite=try image();let t=tuple(composite);let capture=G.CompletedTupleCapture()
        #expect(!capture.observe(composite,t.fills,t.audit))
        #expect(capture.stats().entries==0)
    }
    @Test func captureBindsSelectedImageAndCompleteAdmissionTuple() throws {
        let carrier=try image(),composite=try image(3,3),other=try image(3,3);let t=tuple(carrier)
        let capture=G.CompletedTupleCapture();#expect(capture.observe(composite,t.fills,t.audit))
        func layer(_ image:CGImage,_ audit:[[String:Any]])->Composer.TextLayer {
            Composer.TextLayer(image:image,expectedItems:1,paintedItems:1,complete:true,audit:["finalPaintAdmission":audit])
        }
        #expect(capture.selectedTuple(for:layer(composite,t.audit)) != nil)
        #expect(capture.selectedTuple(for:layer(other,t.audit))==nil)
        #expect(capture.selectedTuple(for:layer(composite,[["owner":"different"]]))==nil)
    }
    @Test func forwardsOuterObserverEvenWhenLocalCaptureRejects() throws {
        let carrier=try image(),composite=try image(3,3);let t=tuple(carrier)
        var calls=0
        let outer=Composer.CompletedPaintObserver { image,fills,audit in
            calls+=1
            #expect(image === composite)
            #expect(fills.count==1 && audit.count==1)
        }
        let capture=G.CompletedTupleCapture(entryLimit:0)
        let chained=G.forwardingObserver(to:outer,capture:capture)
        chained.observe(composite,t.fills,t.audit)
        #expect(calls==1)
        #expect(capture.stats().entries==0)
    }
}
