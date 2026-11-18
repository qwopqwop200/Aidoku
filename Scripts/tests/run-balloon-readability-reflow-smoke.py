#!/usr/bin/env python3
"""Isolated synthetic tests of the real owner-local reflow and alpha admission.

Compile frozen native sources into a temporary directory, with private module
caches. No corpus input, renderer build, source RGB, or production cache is used.
"""
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble"
admission_source_closure = runpy.run_path(
    str(Path(__file__).with_name("native_admission_sources.py"))
)["admission_source_closure"]
SOURCES = admission_source_closure([
    "NativeTextExpansionPolicy", "NativeTextPlacementGuide", "NativeBalloonPlacement",
    "NativeSourceClusterAlignment", "NativeSourceCohortPacking", "NativeInkContourClearance",
    "NativeContourTextClearance", "NativeAdaptiveTextGutter", "NativeReadablePeerGutter", "NativePageEdgePeerPacking", "NativeExplicitDisplayStrokePolicy", "NativeMandatoryDisplayStroke",
    "NativeRenderedStrokeSelection", "NativeSourceStylePaint", "NativeFinalTextPaintAdmission",
    "NativeLineBreakPolicy", "NativeRenderWrapQuality", "NativeBalloonReadabilityReflow",
])

HARNESS = r'''
import CoreGraphics
import Foundation

enum NativeAOTTranslationPageComposer {}
typealias Fill = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
typealias Reflow = NativeBalloonReadabilityReflow
typealias Admission = (fills:[Fill], audit:[[String:Any]])
let page = CGRect(x:0,y:0,width:400,height:400)
var reflowAdmissionCalls = 0
var reflowFootprintCalls: [String:Int] = [:]
let text = "alpha beta gamma delta"
let descriptor = Reflow.Descriptor(text:text,ranges:[NSRange(location:0,length:text.utf16.count)])
let rows = [NSRange(location:0,length:11),NSRange(location:11,length:11)]
func require(_ value:Bool,_ message:String) {
    if !value {fputs("FAIL: \(message)\n",stderr);exit(1)}
}
func normalized(_ r:CGRect)->[Double] {[r.minX/400,r.minY/400,r.width/400,r.height/400].map(Double.init)}
func raster(_ width:Int,_ height:Int)->CGImage {
    let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:width,height:height))
    c.setFillColor(CGColor(gray:0,alpha:1));c.fill(CGRect(x:1,y:1,width:width-2,height:height-2))
    return c.makeImage()!
}
func fixture(peerOrigin:CGPoint=CGPoint(x:300,y:300),inside:Bool=true,axis:NativeSourceClusterAlignment.Axis?=nil,
             body:Bool=false)->Admission {
    let mask=CGRect(x:40,y:60,width:200,height:240),n=normalized(mask)
    let policy=NativeTextExpansionPolicy(allowedRectNormalized:n,candidates:[n],maskCoverage:[1],backgroundRisk:[0],
        sourceFontPixels:20,kind:inside ? "inside-balloon-mask":"source-near-limited-expansion",
        maskRectNormalized:n,maskSpansNormalized:Array(repeating:[0.1,0.6],count:240).flatMap{$0})
    var f=Fill(image:raster(196,20),frame:CGRect(x:42,y:170,width:196,height:20),fontOutputPixels:20)
    f.ownerID="owner";f.hasFinalEffects=true;f.displayStrokeEndpoint=255
    f.textExpansionPolicy=policy
    f.textPlacementGuide = .init(rectNormalized:normalized(CGRect(x:100,y:100,width:80,height:160)),horizontal:.center,vertical:.center)
    f.placementDomain={policy.allows($0,page:page)}
    var p=Fill(image:raster(20,20),frame:CGRect(origin:peerOrigin,size:CGSize(width:20,height:20)),fontOutputPixels:20)
    p.ownerID="peer";p.hasFinalEffects=true;p.displayStrokeEndpoint=255
    if let axis {
        let anchor=(axis == .top ? f.frame.minY:f.frame.minX)/400
        f.sourceClusterAlignment = .init(groupID:"shared",axis:axis,anchorNormalized:Double(anchor))
        p.sourceClusterAlignment=f.sourceClusterAlignment
    }
    if body {
        let packet=NativeBalloonPlacement(crossAlignment:.center,bodyID:"body",rectNormalized:normalized(page),
            preserveSourceOffsets:true,biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0,
            maskSHA256:String(repeating:"0",count:64),order:0)
        f.balloonPlacement=packet;p.balloonPlacement=packet;p.balloonPlacement!.order=1
        p.textPlacementGuide = .init(rectNormalized:normalized(p.frame),horizontal:.center,vertical:.center)
    }
    // Real native admission, all fixture origins fixed. This is also the
    // baseline audit consumed by the helper, not a fabricated placement report.
    return try! NativeFinalTextPaintAdmission.place([f,p],page:page,
        fixedOrigins:["owner":f.frame.origin,"peer":p.frame.origin])
}
func candidate(_ fill:Fill,_ frame:CGRect,height:Int=44,ranges:[NSRange]=rows,font:CGFloat?=nil)->Reflow.Candidate {
    let image=raster(Int(frame.width),height)
    var f=Fill(image:image,frame:CGRect(x:frame.minX.rounded(),y:(frame.midY-CGFloat(height)/2).rounded(),
        width:frame.width,height:CGFloat(height)),fontOutputPixels:font ?? fill.fontOutputPixels)
    f.ownerID=fill.ownerID;f.hasFinalEffects=fill.hasFinalEffects
    f.displayStrokeEndpoint=fill.displayStrokeEndpoint;f.displayStrokeRatio=fill.displayStrokeRatio
    f.textExpansionPolicy=fill.textExpansionPolicy;f.textPlacementGuide=fill.textPlacementGuide
    f.sourceClusterAlignment=fill.sourceClusterAlignment;f.balloonPlacement=fill.balloonPlacement
    f.balloonTargetRelaxed=fill.balloonTargetRelaxed;f.placementDomain=fill.placementDomain
    f.sourceStyle=fill.sourceStyle
    return .init(fill:f,ranges:ranges,metadata:["factoryMarker":"synthetic"])
}
func unchanged(_ before:Admission,_ result:Reflow.Result)throws {
    require(result.selected.isEmpty,"no selection")
    require(NSDictionary(dictionary:before.audit[0]).isEqual(to:result.audit[0]),"rejected audit untouched")
    for i in before.fills.indices {
        require(before.fills[i].frame==result.fills[i].frame,"baseline position unchanged")
        require(try NativeMandatoryDisplayStroke.rgba(before.fills[i].image)==NativeMandatoryDisplayStroke.rgba(result.fills[i].image),"baseline raster unchanged")
    }
}
func run(_ before:Admission,_ make:(String,CGFloat,CGRect)throws->Reflow.Candidate?)throws->Reflow.Result {
    try Reflow.refine(before,descriptors:["owner":descriptor],page:page,make:make)
}
func padded(_ candidate:Reflow.Candidate)->Reflow.Candidate {
    var c=candidate
    let w=c.fill.image.width+6,h=c.fill.image.height+6
    let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(c.fill.image,in:CGRect(x:3,y:3,width:w-6,height:h-6))
    c.fill.image=context.makeImage()!
    c.fill.frame=c.fill.frame.insetBy(dx:-3,dy:-3)
    return c
}
func success()throws {
    var before=fixture();var calls=0;var widths:[CGFloat]=[]
    before.audit[0]["inkContourBeforeRuns"]=[[170,42,238]]
    before.audit[0]["inkContourClearanceRefined"]=true
    before.audit[0]["pageEdgeMarginRefined"]=true
    before.audit[1]["unchangedPeerProof"]="retained"
    reflowAdmissionCalls=0
    reflowFootprintCalls=[:]
    let after=try run(before) {owner,width,frame in
        calls+=1;widths.append(width)
        require(owner=="owner" && frame.midX==140 && frame.height==20,"centered fixed-height callback frame")
        return candidate(before.fills[0],frame)
    }
    require(calls==3 && widths==[166,147,127],"three unique integral widths")
    require(reflowAdmissionCalls>0 && reflowAdmissionCalls<=3,"at most three actual fixed-origin admissions")
    require(reflowFootprintCalls["peer"]==1,"unchanged peer footprint measured once per page")
    require((reflowFootprintCalls["owner"] ?? 0)<=7,"owner footprint bounded by baseline plus three before/after pairs")
    let selected=after.selected["owner"]!
    require(selected.ranges==rows,"extra row selected")
    require(after.fills[0].fontOutputPixels==20 && after.fills[1].fontOutputPixels==20,"fonts retained")
    require(after.fills[1].frame==before.fills[1].frame,"peer fixed")
    require(try NativeMandatoryDisplayStroke.rgba(after.fills[1].image)==NativeMandatoryDisplayStroke.rgba(before.fills[1].image),"peer exact raster")
    require(selected.metadata["balloonReadabilityBoundedAttempts"] as? Int == 3,"attempt metadata")
    require(after.audit[0]["balloonReadabilityMarginBeforePixels"] as? Int == 2,"old exact-alpha margin")
    require(after.audit[0]["balloonReadabilityMarginAfterPixels"] as? Int == 7,"target margin .35em")
    require(after.audit[0]["balloonReadabilityRowsAfter"] as? Int == 2,"audit rows")
    require(after.audit[0]["inkContourBeforeRuns"]==nil && after.audit[0]["inkContourClearanceRefined"]==nil &&
        after.audit[0]["pageEdgeMarginRefined"]==nil,"old immutable-glyph proof removed")
    let oldAudit=after.audit[0]["preReadabilityReflowPlacement"] as! [String:Any]
    require(oldAudit["inkContourClearanceRefined"] as? Bool == true,"old proof snapshotted")
    require(NSDictionary(dictionary:before.audit[1]).isEqual(to:after.audit[1]),"all peer diagnostics preserved")
    require(after.audit[0]["factoryMarker"]==nil,"factory payload is not placement proof")
    require(selected.fill.frame==after.fills[0].frame,"selected retained primitive")
    require(selected.metadata["placementDeltaOutputPixels"] as? [Double] == [0,0],"centered exact-support bridge delta")
    // Verify the actual native raster has its white outline and black interior.
    let bytes=try NativeMandatoryDisplayStroke.rgba(selected.fill.image)
    require(Array(bytes[0..<4])==[255,255,255,255],"visible white outline")
    let offset=(selected.fill.image.width+1)*4
    require(Array(bytes[offset..<offset+4])==[0,0,0,255],"black interior")
    print("PASS narrower extra-row alpha margin, fixed peer, font/style retention, three-attempt bound")
}
func rejectionControls()throws {
    let before=fixture()
    let badRanges:[[NSRange]]=[
        [NSRange(location:0,length:5),NSRange(location:4,length:18)], // overlap
        [NSRange(location:0,length:10),NSRange(location:11,length:11)], // gap
        [NSRange(location:0,length:11),NSRange(location:11,length:10)], // missing suffix
        [NSRange(location:0,length:Int.max),NSRange(location:0,length:1)],
        [NSRange(location:0,length:2),NSRange(location:2,length:20)], // new word cut
        [NSRange(location:0,length:1),NSRange(location:1,length:21)], // single-letter row
        descriptor.ranges, // no extra row
        [NSRange(location:0,length:6),NSRange(location:6,length:5),NSRange(location:11,length:6),NSRange(location:17,length:5)], // +3
    ]
    for ranges in badRanges {
        var calls=0
        let after=try run(before) {_,_,frame in calls+=1;return candidate(before.fills[0],frame,ranges:ranges)}
        require(calls==3,"rejection bounded")
        try unchanged(before,after)
    }
    try unchanged(before,try run(before) {_,_,frame in candidate(before.fills[0],frame,font:19)})
    try unchanged(before,try run(before) {_,_,frame in
        var c=candidate(before.fills[0],frame);c.fill.textExpansionPolicy=nil;return c
    })
    try unchanged(before,try run(before) {_,_,frame in
        var c=candidate(before.fills[0],frame);c.fill.balloonTargetRelaxed.toggle();return c
    })
    enum FactoryFailure:Error {case expected}
    var calls=0
    try unchanged(before,try run(before) {_,_,_ in calls+=1;throw FactoryFailure.expected})
    require(calls==3,"factory errors retain budget and baseline")
    calls=0
    do {
        _=try run(before) {_,_,_ in calls+=1;throw CancellationError()}
        require(false,"cancellation must propagate")
    } catch is CancellationError {require(calls==1,"no callbacks after cancellation")}
    let outside=fixture(inside:false)
    try unchanged(outside,try run(outside) {_,_,_ in require(false,"outside skipped");return nil})
    // More height makes exact alpha cross the assigned mask, even with a
    // deliberately permissive factory domain. Original domain is mandatory.
    try unchanged(before,try run(before) {_,_,frame in
        var c=candidate(before.fills[0],frame,height:260);c.fill.placementDomain={_ in true};return c
    })
    // Validate grapheme ownership and hard paragraphs independently of the
    // factory's painted pixels; quality comparison alone cannot certify these.
    for (s,bad) in [("a\u{301} beta gamma",[NSRange(location:0,length:1),NSRange(location:1,length:12)]),
                    ("alpha\nbeta gamma",[NSRange(location:0,length:8),NSRange(location:8,length:3),NSRange(location:11,length:5)])] {
        let d=Reflow.Descriptor(text:s,ranges:s.contains("\n") ?
            [NSRange(location:0,length:6),NSRange(location:6,length:s.utf16.count-6)]:
            [NSRange(location:0,length:s.utf16.count)])
        let result=try Reflow.refine(before,descriptors:["owner":d],page:page) {_,_,frame in
            candidate(before.fills[0],frame,ranges:bad)
        }
        try unchanged(before,result)
    }
    for (s,bad) in [("alpha beta !",[NSRange(location:0,length:6),NSRange(location:6,length:5),NSRange(location:11,length:1)]),
                    ("alpha (beta gamma)",[NSRange(location:0,length:7),NSRange(location:7,length:11)]),
                    ("I alpha beta",[NSRange(location:0,length:2),NSRange(location:2,length:10)])] {
        let d=Reflow.Descriptor(text:s,ranges:[NSRange(location:0,length:s.utf16.count)])
        let q=NativeRenderWrapQuality.evaluate(s,ranges:bad)
        require(q.orphans>0 || q.illegal>0 || NativeRenderWrapQuality.singleCharacterRows(s,ranges:bad)>0,
            "quality fixture introduces measured defect")
        try unchanged(before,try Reflow.refine(before,descriptors:["owner":d],page:page) {_,_,frame in
            candidate(before.fills[0],frame,ranges:bad)
        })
    }
    print("PASS ownership, wrap quality, font/policy/state rejection, mask, factory error, cancellation, noninside")
}
func geometryControls()throws {
    // Extra height reduces a vertical peer gap without alpha collision: reject.
    let near=fixture(peerOrigin:CGPoint(x:130,y:208))
    try unchanged(near,try run(near) {_,_,frame in candidate(near.fills[0],frame)})
    // A far peer loses some whitespace to the extra row, but remains well
    // beyond the .35em readability target. This must not veto the reflow.
    let far=fixture(peerOrigin:CGPoint(x:130,y:300))
    let farAfter=try run(far) {_,_,frame in candidate(far.fills[0],frame)}
    require(farAfter.selected.count==1,"benign far-peer gap decrease allowed")
    func gap(_ a:Fill,_ b:Fill)throws->CGFloat {
        let A=try NativeFinalTextPaintAdmission.retainedFootprint(a)
        let B=try NativeFinalTextPaintAdmission.retainedFootprint(b)
        let rows=NativeInkContourClearance.envelope(A.runs.map {.init(y:$0.y,left:$0.left,right:$0.right)})
        let peer=NativeInkContourClearance.envelope(B.runs.map {.init(y:$0.y,left:$0.left,right:$0.right)})
        return NativeInkContourClearance.peerMargin(rows:rows,peer:peer,limit:512)
    }
    let oldFarGap=try gap(far.fills[0],far.fills[1])
    let newFarGap=try gap(farAfter.fills[0],farAfter.fills[1])
    require(newFarGap<oldFarGap && newFarGap>=7,"actual distant gap decreases above target")
    let closeCandidate=candidate(near.fills[0],CGRect(x:57,y:170,width:166,height:20))
    require(try gap(closeCandidate.fill,near.fills[1])<7,"near fixture loses required spacing without alpha overlap")
    // Shared top start remains fixed, even though the candidate is taller.
    let top=fixture(peerOrigin:CGPoint(x:300,y:170),axis:.top)
    let topAfter=try run(top) {_,_,frame in padded(candidate(top.fills[0],frame,height:28))}
    require(topAfter.selected.count==1 && topAfter.fills[0].frame.minY==top.fills[0].frame.minY,"shared top lock")
    require(topAfter.fills[1].frame==top.fills[1].frame,"top peer fixed")
    require(topAfter.selected["owner"]!.metadata["placementDeltaOutputPixels"] as? [Double] == [0,4],
        "bridge delta uses exact support, excluding transparent padding")
    // A fixed left edge prevents a useful contour gain; no cohort relaxation.
    let left=fixture(peerOrigin:CGPoint(x:42,y:330),axis:.left)
    try unchanged(left,try run(left) {_,_,frame in candidate(left.fills[0],frame)})
    let active=fixture(peerOrigin:CGPoint(x:300,y:170),body:true)
    require(active.audit[0]["balloonBodyPlaced"] as? Bool == true,"fixture has active target")
    let bodyAfter=try run(active) {_,_,frame in candidate(active.fills[0],frame)}
    for i in active.fills.indices {
        require(bodyAfter.fills[i].balloonPlacement==active.fills[i].balloonPlacement,"body packet unchanged")
        require(bodyAfter.fills[i].balloonTargetRelaxed==active.fills[i].balloonTargetRelaxed,"body target not relaxed")
        require(bodyAfter.audit[i]["balloonBodyPlaced"] as? Bool == active.audit[i]["balloonBodyPlaced"] as? Bool,"active flag unchanged")
    }
    require(bodyAfter.fills[1].frame==active.fills[1].frame,"active peer fixed")
    // The old rows fit, but extra-row alpha would cross an internal mask hole.
    // A mask hull would incorrectly admit this candidate.
    var hole=fixture()
    var policy=hole.fills[0].textExpansionPolicy!
    policy.maskIntervalRowsNormalized=(0..<240).map { (90..<110).contains($0) ? [0.1,0.3,0.4,0.6]:[0.1,0.6] }
    require(policy.valid,"disjoint mask fixture")
    hole.fills[0].textExpansionPolicy=policy
    hole.fills[0].placementDomain={policy.allows($0,page:page)}
    hole=try NativeFinalTextPaintAdmission.place(hole.fills,page:page,
        fixedOrigins:["owner":hole.fills[0].frame.origin,"peer":hole.fills[1].frame.origin])
    try unchanged(hole,try run(hole) {_,_,frame in candidate(hole.fills[0],frame)})
    print("PASS near-peer rejection, benign far-peer decrease, shared top/left, active body packets and target flags")
}
// All positive target flags below come from real native admission. The
// oversized old raster remains legal in its hard mask, outside its soft body.
func existingBodyFitControls()throws {
    func packet(_ id:String,_ rect:CGRect)->NativeBalloonPlacement {
        .init(crossAlignment:.center,bodyID:id,rectNormalized:normalized(rect),
            preserveSourceOffsets:true,biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0,
            maskSHA256:String(repeating:"0",count:64),order:0)
    }
    func admit(_ fills:[Fill])throws->Admission {
        try NativeFinalTextPaintAdmission.place(fills,page:page,
            fixedOrigins:Dictionary(uniqueKeysWithValues:fills.map {($0.ownerID!,$0.frame.origin)}))
    }
    func baseline(_ rect:CGRect,shared:Bool=false)throws->Admission {
        var fills=fixture(peerOrigin:shared ? CGPoint(x:210,y:220):CGPoint(x:300,y:300)).fills
        fills[0].balloonPlacement=packet("assigned",rect)
        fills[1].balloonPlacement=shared ? fills[0].balloonPlacement:
            packet("peer-body",CGRect(x:280,y:280,width:60,height:60))
        if shared { fills[1].balloonPlacement!.order=1 }
        fills[1].textPlacementGuide = .init(rectNormalized:normalized(fills[1].frame),horizontal:.center,vertical:.center)
        return try admit(fills)
    }
    let threeRows=[NSRange(location:0,length:6),NSRange(location:6,length:5),NSRange(location:11,length:11)]
    let bodyRect=CGRect(x:50,y:120,width:180,height:120)
    let before=try baseline(bodyRect)
    let old=try NativeFinalTextPaintAdmission.retainedFootprint(before.fills[0])
    require(!bodyRect.contains(old.bounds),"old raster exceeds assigned singleton body")
    require(before.fills[0].textExpansionPolicy!.allows(old.bounds,page:page),"old raster inside hard mask")
    require(before.audit[0]["balloonBodyPlaced"] as? Bool == false,"oversized old target inactive")
    require(before.audit[1]["balloonBodyPlaced"] as? Bool == true,"separate peer body active")
    let after=try run(before) {_,_,frame in candidate(before.fills[0],frame,height:60,ranges:threeRows)}
    require(after.selected["owner"]?.ranges==threeRows,"singleton extra-row rehabilitation accepted")
    require(NativeRenderWrapQuality.wordCutOffsets(text,ranges:threeRows).isEmpty,"rehabilitation has no word cuts")
    let final=try NativeFinalTextPaintAdmission.retainedFootprint(after.fills[0])
    require(bodyRect.contains(final.bounds),"final exact footprint inside inherited body")
    require(after.audit[0]["balloonBodyPlaced"] as? Bool == true,"same assigned target activated")
    require(after.audit[0]["balloonReadabilityExistingBodyFitRestored"] as? Bool == true &&
        after.selected["owner"]!.metadata["balloonReadabilityExistingBodyFitRestored"] as? Bool == true,
        "restoration marked in audit and candidate metadata")
    let original=after.audit[0]["preReadabilityReflowPlacement"] as! [String:Any]
    require(NSDictionary(dictionary:original).isEqual(to:before.audit[0]),"original inactive audit retained")
    for i in before.fills.indices {
        require(after.fills[i].balloonPlacement==before.fills[i].balloonPlacement,"original body packets retained")
        require(!before.fills[i].balloonTargetRelaxed && !after.fills[i].balloonTargetRelaxed,"no body relaxation")
    }
    require(NSDictionary(dictionary:after.audit[1]).isEqual(to:before.audit[1]),"separate peer target audit unchanged")
    require(after.fills[1].frame==before.fills[1].frame,"peer exact frame retained")
    require(try NativeMandatoryDisplayStroke.rgba(after.fills[1].image) ==
        NativeMandatoryDisplayStroke.rgba(before.fills[1].image),"peer exact raster retained")
    // A factory cannot switch the selected owner to a different body, edit its
    // assigned box, remove membership, or set the relaxation flag.
    for mutation in 0..<4 {
        try unchanged(before,try run(before) {_,_,frame in
            var c=candidate(before.fills[0],frame,height:60,ranges:threeRows)
            switch mutation {
            case 0: c.fill.balloonPlacement=packet("another-body",bodyRect)
            case 1: c.fill.balloonPlacement!.rectNormalized=normalized(page)
            case 2: c.fill.balloonPlacement=nil
            default: c.fill.balloonTargetRelaxed=true
            }
            return c
        })
    }
    // Real multi-member admission would activate both targets. No owner-local
    // exception may activate that peer or rehabilitate a shared body.
    let shared=try baseline(bodyRect,shared:true)
    require(shared.audit.allSatisfy {$0["balloonBodyPlaced"] as? Bool == false},"shared oversized targets inactive")
    var sharedFills=shared.fills
    sharedFills[0]=candidate(shared.fills[0],CGRect(x:57,y:170,width:166,height:20),height:60,ranges:threeRows).fill
    let sharedAttempt=try admit(sharedFills)
    require(sharedAttempt.audit.allSatisfy {$0["balloonBodyPlaced"] as? Bool == true},"native shared attempt changes peer flag")
    try unchanged(shared,try run(shared) {_,_,frame in candidate(shared.fills[0],frame,height:60,ranges:threeRows)})
    // Isolate the every-other-owner flag guard using an injected stale peer
    // audit; the selected owner still qualifies for singleton restoration.
    var peerFlag=before
    peerFlag.audit[1]["balloonBodyPlaced"]=false
    try unchanged(peerFlag,try run(peerFlag) {_,_,frame in candidate(peerFlag.fills[0],frame,height:60,ranges:threeRows)})
    let active=try baseline(CGRect(x:40,y:160,width:200,height:40))
    require(active.audit[0]["balloonBodyPlaced"] as? Bool == true,"short active body baseline")
    var activeFills=active.fills
    activeFills[0]=candidate(active.fills[0],CGRect(x:57,y:170,width:166,height:20),height:60,ranges:threeRows).fill
    let deactivated=try admit(activeFills)
    require(deactivated.audit[0]["balloonBodyPlaced"] as? Bool == false,"extra height would deactivate active target")
    try unchanged(active,try run(active) {_,_,frame in candidate(active.fills[0],frame,height:60,ranges:threeRows)})
    try unchanged(active,try run(active) {_,_,frame in
        var c=candidate(active.fills[0],frame,height:28);c.fill.balloonTargetRelaxed=true;return c
    })
    // Size fitting alone is insufficient: final fixed alpha must lie in the
    // inherited box, even if native admission reports an available target.
    let offset=try baseline(CGRect(x:100,y:120,width:180,height:120))
    try unchanged(offset,try run(offset) {_,_,frame in candidate(offset.fills[0],frame,height:60,ranges:threeRows)})
    print("PASS singleton existing-body fit restoration, unchanged packets, other-body/peer/relaxation/deactivation rejection")
}
func cachedMultiownerControl()throws {
    var fills:[Fill]=[]
    for (owner,x) in [("first",10),("second",250)] {
        let mask=CGRect(x:x,y:100,width:120,height:160),n=normalized(mask)
        let policy=NativeTextExpansionPolicy(allowedRectNormalized:n,candidates:[n],maskCoverage:[1],backgroundRisk:[0],
            sourceFontPixels:10,kind:"inside-balloon-mask",maskRectNormalized:n,
            maskSpansNormalized:Array(repeating:[Double(x)/400,Double(x+120)/400],count:160).flatMap{$0})
        var f=Fill(image:raster(116,10),frame:CGRect(x:x+2,y:175,width:116,height:10),fontOutputPixels:10)
        f.ownerID=owner;f.hasFinalEffects=true;f.displayStrokeEndpoint=255
        f.textExpansionPolicy=policy
        f.textPlacementGuide = .init(rectNormalized:normalized(CGRect(x:x+40,y:140,width:40,height:80)),horizontal:.center,vertical:.center)
        f.placementDomain={policy.allows($0,page:page)}
        fills.append(f)
    }
    let before=try NativeFinalTextPaintAdmission.place(fills,page:page,
        fixedOrigins:Dictionary(uniqueKeysWithValues:fills.map {($0.ownerID!,$0.frame.origin)}))
    reflowFootprintCalls=[:];reflowAdmissionCalls=0
    var callbacks:[String:Int]=[:]
    let result=try Reflow.refine(before,descriptors:["first":descriptor,"second":descriptor],page:page) {owner,_,frame in
        callbacks[owner,default:0]+=1
        return candidate(fills.first {$0.ownerID==owner}!,frame,height:22)
    }
    require(result.selected.count==2,"both owners accepted using updated cached support")
    require(reflowAdmissionCalls==6,"two owners, three fixed admissions each")
    for owner in ["first","second"] {
        require(callbacks[owner]==3,"each owner visited once")
        require(reflowFootprintCalls[owner]==7,"one page measurement plus three candidate before/after pairs; no peer remeasurement")
        require(result.selected[owner]!.fill.frame==result.fills.first {$0.ownerID==owner}!.frame,"selected final support retained")
    }
    print("PASS page-wide support cache, accepted-owner updates, two independent bounded refinements")
}
try success()
try rejectionControls()
try geometryControls()
try existingBodyFitControls()
try cachedMultiownerControl()
print("BALLOON_READABILITY_REFLOW synthetic controls passed")
'''


def main():
    with tempfile.TemporaryDirectory(prefix="aidoku-balloon-reflow-") as directory:
        cache = Path(directory)
        carrier = (ENGINE / "NativeMandatoryDisplayStroke+Composer.swift").read_text()
        carrier = carrier.split("    /// Concrete minimal adapter")[0] + "}\n"
        (cache / "Primitive.swift").write_text(carrier)
        (cache / "main.swift").write_text(HARNESS)
        for name in SOURCES:
            data = (ENGINE / (name + ".swift")).read_text()
            if name == "NativeFinalTextPaintAdmission":
                # Count real admissions and assert every native call is fixed;
                # the native placement/alpha implementation remains intact.
                needle = "        guard input.allSatisfy"
                assert data.count(needle) == 1
                data = data.replace(needle, '        reflowAdmissionCalls += 1\n'
                                    '        require(fixedOrigins.count == input.count, "all origins fixed")\n' + needle)
                needle = "        try proposal(fill)"
                assert data.count(needle) == 1
                data = data.replace(needle, '        reflowFootprintCalls[fill.ownerID ?? "", default: 0] += 1\n'
                                    '        return try proposal(fill)')
            (cache / (name + ".swift")).write_text(data)
        env = {key: value for key, value in os.environ.items() if not key.startswith("AIDOKU_")}
        env["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang-modules")
        binary = cache / "check"
        start = time.monotonic()
        subprocess.run([
            "xcrun", "swiftc", "-O", "-module-cache-path", str(cache / "swift-modules"),
            *[str(cache / (name + ".swift")) for name in SOURCES],
            str(cache / "Primitive.swift"), str(cache / "main.swift"), "-o", str(binary),
        ], check=True, env=env)
        print(f"Isolated helper build: {time.monotonic() - start:.2f}s", flush=True)
        start = time.monotonic()
        subprocess.run([str(binary)], check=True, env=env)
        print(f"Synthetic execution: {time.monotonic() - start:.2f}s", flush=True)


if __name__ == "__main__":
    main()
