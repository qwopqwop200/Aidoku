import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Direct receipt admission tests; no process-wide feature flags or rendering
/// fixtures. The raw-painter terminal test separately exercises full repaint.
struct NativeRetainedEdgeAnchorAdmissionTests {
    private typealias N = NativeFinalTextPaintAdmission
    private typealias P = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    private struct Fixture {
        let page: CGRect
        var fills: [P]
        var footprints: [N.Footprint]
        var audit: [[String:Any]]
    }

    private func fixture(margin: CGFloat = 0, delta: CGPoint = CGPoint(x:-1,y:-1)) throws -> Fixture {
        let page = CGRect(x:0,y:0,width:256,height:128)
        let whole = [0.0,0,1,1]
        let policy = NativeTextExpansionPolicy(allowedRectNormalized:whole,candidates:[whole],maskCoverage:[1],backgroundRisk:[0],
            sourceFontPixels:20,kind:"source-near-limited-expansion",maskRectNormalized:nil,maskSpansNormalized:nil)
        func box(_ r: CGRect) -> [CGFloat] { [r.minX,r.minY,r.width,r.height] }
        func normalized(_ r: CGRect) -> [Double] {
            [r.minX/page.width,r.minY/page.height,r.width/page.width,r.height/page.height].map(Double.init)
        }
        var fills: [P] = []
        for (index,height) in [24,8].enumerated() {
            var bytes = [UInt8](repeating:0,count:8*height*4)
            for i in stride(from:3,to:bytes.count,by:4) { bytes[i] = 255 }
            var fill = P(image:try NativeMandatoryDisplayStroke.image(bytes,width:8,height:height),
                frame:CGRect(x:40,y:40,width:8,height:height),fontOutputPixels:20)
            fill.ownerID = "edge-\(index)"
            fill.displayStrokeEndpoint = 255; fill.displayStrokeRatio = 0.05
            fill.sourceStyle = .init(sourceFontPixels:20,bands:[.init(rgb:[30,90,170],width:1)],shadow:nil)
            fill.textExpansionPolicy = policy
            fill.placementDomain = { policy.allows($0,page:page) }
            fills.append(fill)
        }
        let initial = try fills.map { try N.retainedFootprint($0) }
        let top = page.height-margin-initial[0].bounds.height
        for i in fills.indices {
            let x: CGFloat = i == 0 ? 60 : page.width-margin-initial[i].bounds.width
            fills[i].frame = fills[i].frame.offsetBy(dx:x-initial[i].bounds.minX,dy:top-initial[i].bounds.minY)
            let support = try N.retainedFootprint(fills[i])
            fills[i].textPlacementGuide = .init(rectNormalized:normalized(support.bounds),horizontal:.center,vertical:.top)
            fills[i].sourceClusterAlignment = .init(groupID:"edge-cohort",axis:.top,
                anchorNormalized:Double(top/page.height),anchorPolicy:"source-near-final-alpha",anchorsToSourceStart:true)
        }
        let before = try fills.map { try N.retainedFootprint($0) }
        let union = before.reduce(CGRect.null) { $0.union($1.bounds) }
        for i in fills.indices { fills[i].frame = fills[i].frame.offsetBy(dx:delta.x,dy:delta.y) }
        let actual = try fills.map { try N.retainedFootprint($0) }
        let norm = hypot(delta.x,delta.y), cohort = fills.compactMap(\.ownerID).sorted()
        let audit: [[String:Any]] = fills.indices.map { i in
            let guide = fills[i].textPlacementGuide!, source = guide.rect(in:page)
            let a = before[i].bounds, b = actual[i].bounds
            let oldPreferred = guide.preferredShift(bounds:a,page:page)
            let newPreferred = guide.preferredShift(bounds:b,page:page)
            let oldCenter = hypot(a.midX-source.midX,a.midY-source.midY)
            let newCenter = hypot(b.midX-source.midX,b.midY-source.midY)
            let oldCost = hypot(oldPreferred.x,oldPreferred.y), newCost = hypot(newPreferred.x,newPreferred.y)
            let receipt: [String:Any] = [
                "version":"retained-page-edge-inset1-v1", "cohortOwners":cohort,
                "shiftPixels":[delta.x,delta.y], "minimalGroupShift":[delta.x,delta.y],
                "insetPixels":1, "exceptionBoundPixels":norm,
                "exceptionAuthority":"minimal-required-page-inset-and-coherent-cohort-only",
                "beforeBounds":box(a), "afterBounds":box(b), "minimalGroupBeforeBounds":box(union),
                "cohortOldAnchor":a.minY, "cohortNewAnchor":b.minY,
                "centerBeforePixels":oldCenter, "centerAfterPixels":newCenter,
                "guideBeforePixels":oldCost, "guideAfterPixels":newCost]
            return ["owner":fills[i].ownerID!, "sourceClusterID":"edge-cohort", "sourceClusterAxis":"top",
                "retainedSourceClusterAnchorApplied":true, "sourceClusterAnchorOutputPixels":b.minY,
                "effectsIncluded":true, "paintedPixels":actual[i].pixels,
                "finalFootprintOutputPixels":box(b), "retainedPageEdgeRecovery":receipt]
        }
        return Fixture(page:page,fills:fills,footprints:actual,audit:audit)
    }

    private func admit(_ f: Fixture) throws -> [String:CGFloat] {
        try N.verifiedRetainedClusterAnchors(f.fills,footprints:f.footprints,audit:f.audit,page:f.page)
    }

    @Test func exteriorEdgeReceiptAdmitsWithoutInteriorFlags() throws {
        let f = try fixture()
        #expect(f.audit.allSatisfy { $0["interiorWordReflow"] == nil && $0["preInteriorWordReflowPlacement"] == nil })
        let anchors = try admit(f)
        #expect(anchors == ["edge-cohort":f.footprints[0].bounds.minY])
        try N.verifyRetainedPlacement(f.fills,footprints:f.footprints,page:f.page,retainedClusterAnchors:anchors)
    }

    @Test func exteriorEdgeRejectsTamperedOrIncompleteProof() throws {
        let original = try fixture()
        func reject(_ f: Fixture) throws {
            do {
                _ = try admit(f)
                Issue.record("Tampered edge anchor proof was accepted")
            } catch N.Failure.invalidGeometry { }
        }
        func changeProof(_ key: String, _ value: Any) -> Fixture {
            var f = original, proof = f.audit[0]["retainedPageEdgeRecovery"] as! [String:Any]
            proof[key] = value; f.audit[0]["retainedPageEdgeRecovery"] = proof
            return f
        }
        // Coherent, fully bound receipts still cannot authorize margin-only
        // motion or a correction larger than one pixel on either axis.
        try reject(try fixture(margin:2))
        try reject(try fixture(delta:CGPoint(x:-2,y:-1)))
        var missing = original
        missing.audit[1].removeValue(forKey:"retainedPageEdgeRecovery")
        try reject(missing)
        var unmarked = original
        unmarked.audit[1].removeValue(forKey:"retainedSourceClusterAnchorApplied")
        try reject(unmarked)
        try reject(changeProof("cohortOwners",["edge-0"]))
        try reject(changeProof("cohortNewAnchor",0))
        try reject(changeProof("cohortOldAnchor",0))
        try reject(changeProof("shiftPixels",[-2,-1]))
        try reject(changeProof("minimalGroupBeforeBounds",[0,0,1,1]))
        try reject(changeProof("beforeBounds",[0,0,1,1]))
        try reject(changeProof("afterBounds",[0,0,1,1]))
        try reject(changeProof("exceptionBoundPixels",1))
        try reject(changeProof("centerAfterPixels",100))
        // Keep the same box/count while corrupting the actual alpha run proof.
        var alpha = original
        let support = alpha.footprints[0]
        var runs = Array(support.runs)
        runs[0] = .init(y:runs[0].y,left:runs[0].left+1,right:runs[0].right+1)
        alpha.footprints[0] = .init(runs:runs,bounds:support.bounds,pixels:support.pixels,readableBounds:support.readableBounds)
        try reject(alpha)
        var notInset = original
        let old = notInset.footprints[0]
        notInset.footprints[0] = old.translated(CGPoint(x:0,y:1))
        try reject(notInset)
        // The edge branch must not weaken the established interior contract.
        var fakeInterior = original
        for i in fakeInterior.audit.indices { fakeInterior.audit[i].removeValue(forKey:"retainedPageEdgeRecovery") }
        try reject(fakeInterior)
    }
}
