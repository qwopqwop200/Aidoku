#!/usr/bin/env python3
"""Parent-run synthetic interior lexical tests using the existing native carrier.

No corpus, RGB inputs, shared caches or model calls. The core worker deliberately
only syntax-checks this Python file; running it compiles isolated Swift sources.
"""
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

BASE = runpy.run_path(str(Path(__file__).with_name("run-balloon-readability-reflow-smoke.py")))
ENGINE = BASE["ENGINE"]
SOURCES = BASE["SOURCES"]
HARNESS = BASE["HARNESS"].split("func success()throws")[0] + r'''
import Darwin
let cutDescriptor = Reflow.Descriptor(text:text,ranges:[NSRange(location:0,length:2),NSRange(location:2,length:20)])
let threeWholeRows = [NSRange(location:0,length:6),NSRange(location:6,length:5),NSRange(location:11,length:11)]
func words(_ before:Admission,complete:Bool=true,d:Reflow.Descriptor=cutDescriptor,
           width:CGFloat?=201.25,
           make:((String,CGFloat,CGRect)throws->Reflow.Candidate?)?=nil)throws->Reflow.Result {
    try Reflow.refineInteriorWords(before,descriptors:["owner":d],page:page,completePeerContext:complete,
        outerWidths:{_ in width}) {owner,width,bounds in
        if let make {return try make(owner,width,bounds)}
        return candidate(before.fills[0],bounds,height:20)
    }
}
func controls()throws {
    let before=fixture()
    unsetenv("AIDOKU_INTERIOR_WORD_REFLOW")
    require(Reflow.interiorWordsEnabled,"reviewed default ON")
    setenv("AIDOKU_INTERIOR_WORD_REFLOW","0",1)
    reflowAdmissionCalls=0;reflowFootprintCalls=[:]
    try unchanged(before,try words(before) {_,_,_ in require(false,"OFF factory");return nil})
    require(reflowAdmissionCalls==0 && reflowFootprintCalls.isEmpty,"OFF performs no native work")
    require(!Reflow.interiorWordsEnabled,"explicit rollback OFF")
    setenv("AIDOKU_INTERIOR_WORD_REFLOW","1",1)
    // A complete standalone word is not a fragment merely because it has one
    // grapheme. Restoring whole words may intentionally expose that short word.
    for (value,old,joined) in [
        ("A BCDEF",[NSRange(location:0,length:4),NSRange(location:4,length:3)],
         [NSRange(location:0,length:2),NSRange(location:2,length:5)]),
        ("ABCDE F",[NSRange(location:0,length:3),NSRange(location:3,length:4)],
         [NSRange(location:0,length:6),NSRange(location:6,length:1)])] {
        let result=try words(before,d:.init(text:value,ranges:old)) {_,_,b in
            candidate(before.fills[0],b,height:20,ranges:joined)
        }
        require(result.selected.count==1,"complete one-letter token survives lexical repair")
    }
    reflowAdmissionCalls=0;reflowFootprintCalls=[:]
    var widths=0,shapes=0
    let after=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{id in
            widths+=1;require(id=="owner","eligible width owner");return 201.25
        }) {id,width,bounds in
            shapes+=1;require(width==201.25,"exact OUTER width, no rounding/content conversion")
            return candidate(before.fills[0],bounds,height:20)
        }
    require(widths==1 && shapes==1 && reflowAdmissionCalls==1,"one provider/factory/admission")
    require(after.selected.count==1,"equal row count and equal contour accepted")
    require(after.audit[0]["interiorWordMarginBeforePixels"]as?Int == 2 &&
        after.audit[0]["interiorWordMarginAfterPixels"]as?Int == 2,"equal subtarget margin allowed")
    require(after.audit[0]["interiorWordCutsAfter"]as?Int == 0,"strict cut reduction")
    require(after.audit[0]["preInteriorWordReflowPlacement"] != nil,"baseline proof retained")
    require(after.fills[1].image === before.fills[1].image && after.fills[1].frame==before.fills[1].frame,"original peer object/frame")
    require(NSDictionary(dictionary:after.audit[1]).isEqual(to:before.audit[1]),"peer audit exact")
    require(reflowFootprintCalls["peer"]==1,"peer support cached once")
    let extra=try words(before) {_,_,b in candidate(before.fills[0],b,height:44,ranges:threeWholeRows)}
    require(extra.selected.count==1,"one extra whole-word row")
    var wideGuide=before
    wideGuide.fills[0].textPlacementGuide = .init(rectNormalized:normalized(CGRect(x:40,y:170,width:200,height:20)),
        horizontal:.center,vertical:.center)
    require(try words(wideGuide).selected.count==1,"lexical pass independent of old tall-source contour gate")
    for ranges in [cutDescriptor.ranges,descriptor.ranges,
                   [NSRange(location:0,length:2),NSRange(location:3,length:19)],
                   [NSRange(location:0,length:Int.max)],
                   [NSRange(location:0,length:1),NSRange(location:1,length:21)],
                   [NSRange(location:0,length:6),NSRange(location:6,length:5),NSRange(location:11,length:6),NSRange(location:17,length:5)]] {
        try unchanged(before,try words(before) {_,_,b in candidate(before.fills[0],b,ranges:ranges)})
    }
    try unchanged(before,try words(before,complete:false) {_,_,_ in require(false,"incomplete peers");return nil})
    try unchanged(before,try words(before,d:descriptor) {_,_,_ in require(false,"no cuts");return nil})
    let exterior=fixture(inside:false)
    try unchanged(exterior,try words(exterior) {_,_,_ in require(false,"exterior");return nil})
    for width in [nil,0,-1,CGFloat.nan,CGFloat.infinity] as [CGFloat?] {
        try unchanged(before,try words(before,width:width) {_,_,_ in require(false,"invalid width");return nil})
    }
    for mutation in 0..<6 {
        try unchanged(before,try words(before) {_,_,b in
            var c=candidate(before.fills[0],b,height:20)
            switch mutation {
            case 0:c=candidate(before.fills[0],b,height:20,font:19)
            case 1:c.fill.balloonTargetRelaxed=true
            case 2:c.fill.textExpansionPolicy=nil
            case 3:c.fill.textPlacementGuide=nil
            case 4:c.fill.hasFinalEffects=false
            default:c.fill.image=raster(198,20);c.fill.frame.size.width=198 // margin 2 -> 1
            }
            return c
        })
    }
    // Font/effect packets do not prove palette identity: actual opaque colors
    // must still agree after final admission.
    try unchanged(before,try words(before) {_,_,b in
        var c=candidate(before.fills[0],b,height:20)
        let ctx=CGContext(data:nil,width:196,height:20,bitsPerComponent:8,bytesPerRow:784,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:196,height:20))
        c.fill.image=ctx.makeImage()!;return c
    })
    let near=fixture(peerOrigin:CGPoint(x:130,y:208))
    try unchanged(near,try words(near) {_,_,b in candidate(near.fills[0],b,height:44,ranges:threeWholeRows)})
    let body=fixture(body:true)
    let bodyAfter=try words(body)
    require(bodyAfter.selected.count==1,"active body lexical repair")
    for i in body.fills.indices {
        require(body.fills[i].balloonPlacement==bodyAfter.fills[i].balloonPlacement,"body packet exact")
        require(body.audit[i]["balloonBodyPlaced"]as?Bool == bodyAfter.audit[i]["balloonBodyPlaced"]as?Bool,"body state exact")
    }
    // Never trust a weakened factory domain; the assigned mask has a hole
    // outside old paint, crossed only by the added rows.
    var hole=before
    var policy=hole.fills[0].textExpansionPolicy!
    policy.maskIntervalRowsNormalized=(0..<240).map { (100..<110).contains($0) ? [0.1,0.3,0.4,0.6]:[0.1,0.6] }
    hole.fills[0].textExpansionPolicy=policy;hole.fills[0].placementDomain={policy.allows($0,page:page)}
    try unchanged(hole,try words(hole) {_,_,b in
        var c=candidate(hole.fills[0],b,height:60,ranges:threeWholeRows)
        c.fill.placementDomain={_ in true};return c
    })
    for (s,old,bad) in [
        ("a\u{301} beta gamma",[NSRange(location:0,length:4),NSRange(location:4,length:9)],
         [NSRange(location:0,length:1),NSRange(location:1,length:12)]),
        ("alpha\nbeta gamma",[NSRange(location:0,length:6),NSRange(location:6,length:2),NSRange(location:8,length:8)],
         [NSRange(location:0,length:8),NSRange(location:8,length:8)])] {
        try unchanged(before,try words(before,d:.init(text:s,ranges:old)) {_,_,b in
            candidate(before.fills[0],b,height:20,ranges:bad)
        })
    }
    enum Failure:Error {case expected}
    var calls=0
    try unchanged(before,try words(before) {_,_,_ in calls+=1;throw Failure.expected})
    require(calls==1,"ordinary factory error no retry")
    try unchanged(before,try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in throw Failure.expected}) {_,_,_ in
            require(false,"width error no shape");return nil
        })
    for stage in 0..<2 {
        do {
            _=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
                completePeerContext:true,outerWidths:{_ in if stage==0 {throw CancellationError()};return 201.25}) {_,_,_ in
                    throw CancellationError()
                }
            require(false,"cancellation propagated")
        } catch is CancellationError {}
    }
    // Two independent eligible owners consume precisely two natural plans.
    var fills:[Fill]=[]
    for (owner,x) in [("first",10),("second",250)] {
        let mask=CGRect(x:x,y:100,width:120,height:160),n=normalized(mask)
        let p=NativeTextExpansionPolicy(allowedRectNormalized:n,candidates:[n],maskCoverage:[1],backgroundRisk:[0],
            sourceFontPixels:10,kind:"inside-balloon-mask",maskRectNormalized:n,
            maskSpansNormalized:Array(repeating:[Double(x)/400,Double(x+120)/400],count:160).flatMap{$0})
        var f=Fill(image:raster(116,10),frame:CGRect(x:x+2,y:175,width:116,height:10),fontOutputPixels:10)
        f.ownerID=owner;f.hasFinalEffects=true;f.displayStrokeEndpoint=255
        f.textExpansionPolicy=p;f.placementDomain={p.allows($0,page:page)}
        f.textPlacementGuide = .init(rectNormalized:normalized(f.frame),horizontal:.center,vertical:.center)
        fills.append(f)
    }
    let pair=try NativeFinalTextPaintAdmission.place(fills,page:page,
        fixedOrigins:Dictionary(uniqueKeysWithValues:fills.map {($0.ownerID!,$0.frame.origin)}))
    reflowAdmissionCalls=0;reflowFootprintCalls=[:]
    var ownersCalled:[String:Int]=[:]
    let pairAfter=try Reflow.refineInteriorWords(pair,descriptors:["first":cutDescriptor,"second":cutDescriptor],
        page:page,completePeerContext:true,outerWidths:{_ in 120}) {id,_,b in
            ownersCalled[id,default:0]+=1
            return candidate(fills.first {$0.ownerID==id}!,b,height:10)
        }
    require(pairAfter.selected.count==2 && reflowAdmissionCalls==2,"one admission per eligible owner")
    require(ownersCalled==["first":1,"second":1],"no recursion or owner revisit")
    require(reflowFootprintCalls==["first":3,"second":3],"baseline plus candidate before/after, no peer remeasurement")
    print("INTERIOR_WORD_REFLOW synthetic controls passed")
}
func measuredWidthControls()throws {
    let before=fixture()
    unsetenv("AIDOKU_INTERIOR_MEASURED_WIDTHS")
    require(Reflow.interiorMeasuredWidthsEnabled,"reviewed widths default ON")
    setenv("AIDOKU_INTERIOR_MEASURED_WIDTHS","0",1)
    require(!Reflow.interiorMeasuredWidthsEnabled,"explicit measured-width rollback OFF")
    let palette:[CGFloat]=[140,150,150.005,160,170]
    var calls:[CGFloat]=[],providers=0
    func probe(_ allowReduction:Bool=false,_ d:Reflow.Descriptor=cutDescriptor)throws->Reflow.Result {
        try Reflow.refineInteriorWords(before,descriptors:["owner":d],page:page,completePeerContext:true,
            outerWidths:{_ in 140},extraOuterWidths:{_ in providers+=1;return palette},allowRowReduction:allowReduction) {_,w,b in
                calls.append(w)
                return candidate(before.fills[0],CGRect(x:b.minX,y:b.minY,width:w,height:20),height:20,
                    ranges:w==140 ? d.ranges:rows)
            }
    }
    try unchanged(before,try probe())
    require(calls==[140] && providers==0,"OFF ignores extra provider and keeps one natural width")
    calls=[];providers=0;reflowAdmissionCalls=0
    setenv("AIDOKU_INTERIOR_MEASURED_WIDTHS","1",1)
    let result=try probe()
    require(calls==[140,150,160] && providers==1,"three unique bounded widths, provider once")
    require(reflowAdmissionCalls==2,"one admission per improving width")
    require(result.selected["owner"]?.metadata["interiorWordOuterWidthPixels"]as?Double==150,
        "equal quality prefers smaller actual paint and width")
    require(result.fills[1].image === before.fills[1].image && result.fills[1].frame==before.fills[1].frame,"peers immutable")
    let fragmented=Reflow.Descriptor(text:text,ranges:[NSRange(location:0,length:2),NSRange(location:2,length:3),
        NSRange(location:5,length:5),NSRange(location:10,length:5),NSRange(location:15,length:7)])
    calls=[]
    try unchanged(before,try probe(false,fragmented))
    require(try probe(true,fragmented).selected["owner"]?.ranges.count==2,"guarded row reduction reaches admission")
    unsetenv("AIDOKU_INTERIOR_MEASURED_WIDTHS")
    print("MEASURED_WIDTH bounded provider, dedup, quality ranking, row budget and immutable peers passed")
}
func incumbentPreservationControls()throws {
    let before=fixture(body:true)
    let value=candidate(before.fills[0],before.fills[0].frame,height:20)
    setenv("AIDOKU_INTERIOR_MEASURED_WIDTHS","0",1)
    let old=try words(before) {_,_,_ in value}
    require(old.selected.count==1,"retained-width incumbent exists")
    setenv("AIDOKU_INTERIOR_MEASURED_WIDTHS","1",1)
    var factories=0,extraProviders=0
    let result=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 201.25},extraOuterWidths:{_ in
            extraProviders+=1;return [250,300]
        },allowRowReduction:true) {_,_,_ in factories+=1;return value}
    require(factories==1 && extraProviders==0,"fully repaired incumbent never reshaped or revisited")
    require(result.selected.count==old.selected.count,"retained selections preserved")
    for i in old.fills.indices {
        require(old.fills[i].frame==result.fills[i].frame,"incumbent positions exact")
        require(try NativeMandatoryDisplayStroke.rgba(old.fills[i].image)==NativeMandatoryDisplayStroke.rgba(result.fills[i].image),"incumbent raster exact")
        require(NSDictionary(dictionary:old.audit[i]).isEqual(to:result.audit[i]),"incumbent owner audit exact")
    }
    unsetenv("AIDOKU_INTERIOR_MEASURED_WIDTHS")
    print("INCUMBENT retained-width repairs remain exact before bounded extra-width proposals")
}
func bodyResidualControls()throws {
    setenv("AIDOKU_INTERIOR_MEASURED_WIDTHS","1",1)
    let n=normalized(page)
    let policy=NativeTextExpansionPolicy(allowedRectNormalized:n,candidates:[n],maskCoverage:[1],backgroundRisk:[0],
        sourceFontPixels:20,kind:"inside-balloon-mask",maskRectNormalized:n,
        maskSpansNormalized:Array(repeating:[0.0,1.0],count:400).flatMap{$0})
    var first=Fill(image:raster(100,60),frame:CGRect(x:60,y:170,width:100,height:60),fontOutputPixels:20)
    first.ownerID="owner";first.hasFinalEffects=true;first.displayStrokeEndpoint=255
    first.textExpansionPolicy=policy;first.placementDomain={policy.allows($0,page:page)}
    first.textPlacementGuide = .init(rectNormalized:normalized(first.frame),horizontal:.center,vertical:.center)
    first.balloonPlacement = .init(crossAlignment:.center,bodyID:"body-rounding",rectNormalized:n,
        preserveSourceOffsets:true,biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0,
        maskSHA256:String(repeating:"0",count:64),order:0)
    var peer=first;peer.ownerID="peer";peer.image=raster(20,20);peer.frame=CGRect(x:250,y:190,width:20,height:20)
    peer.textPlacementGuide = .init(rectNormalized:normalized(peer.frame),horizontal:.center,vertical:.center)
    peer.balloonPlacement!.order=1
    let before=try NativeFinalTextPaintAdmission.place([first,peer],page:page,
        fixedOrigins:["owner":first.frame.origin,"peer":peer.frame.origin])
    let after=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 100},extraOuterWidths:{_ in [101]}) {_,w,b in
        guard w==101 else{return nil}
        return candidate(first,CGRect(x:b.minX,y:b.minY,width:w,height:20),height:20)
    }
    require(after.selected.count==1,"odd-size body candidate survives final invariants")
    require(after.fills[1].image === before.fills[1].image && after.fills[1].frame==before.fills[1].frame,"body peer immutable")
    let support=try after.fills.map {try NativeFinalTextPaintAdmission.retainedFootprint($0)}
    try NativeFinalTextPaintAdmission.verifyRetainedPlacement(after.fills,footprints:support,page:page)
    var broken=support
    broken[0]=broken[0].translated(CGPoint(x:1,y:0))
    do {
        try NativeFinalTextPaintAdmission.verifyRetainedPlacement(after.fills,footprints:broken,page:page)
        require(false,"one-pixel body residual mismatch still fails final validation")
    }catch{}
    unsetenv("AIDOKU_INTERIOR_MEASURED_WIDTHS")
    print("BODY_RESIDUAL odd-size owner aligns with fixed peer; final one-pixel mismatch rejected")
}
func retainedCohortAnchorControls()throws {
    setenv("AIDOKU_INTERIOR_MEASURED_WIDTHS","1",1)
    let n=normalized(page)
    let policy=NativeTextExpansionPolicy(allowedRectNormalized:n,candidates:[n],maskCoverage:[1],backgroundRisk:[0],
        sourceFontPixels:20,kind:"inside-balloon-mask",maskRectNormalized:n,
        maskSpansNormalized:Array(repeating:[0.0,1.0],count:400).flatMap{$0})
    let cluster=NativeSourceClusterAlignment(groupID:"retained",axis:.top,anchorNormalized:0.425,
        anchorPolicy:"source-near-final-alpha")
    var first=Fill(image:raster(100,60),frame:CGRect(x:60,y:170,width:100,height:60),fontOutputPixels:20)
    first.ownerID="owner";first.hasFinalEffects=true;first.displayStrokeEndpoint=255
    first.textExpansionPolicy=policy;first.placementDomain={policy.allows($0,page:page)}
    first.sourceClusterAlignment=cluster
    first.textPlacementGuide = .init(rectNormalized:normalized(CGRect(x:70,y:160,width:80,height:80)),horizontal:.center,vertical:.center)
    var peer=first;peer.ownerID="peer";peer.image=raster(20,20);peer.frame=CGRect(x:250,y:170,width:20,height:20)
    peer.textPlacementGuide = .init(rectNormalized:normalized(CGRect(x:245,y:160,width:30,height:40)),horizontal:.center,vertical:.center)
    let fixed=["owner":first.frame.origin,"peer":peer.frame.origin]
    let before=try NativeFinalTextPaintAdmission.place([first,peer],page:page,fixedOrigins:fixed)
    let d=Reflow.Descriptor(text:text,ranges:[NSRange(location:0,length:2),NSRange(location:2,length:3),
        NSRange(location:5,length:5),NSRange(location:10,length:5),NSRange(location:15,length:7)])
    let shape=candidate(first,CGRect(x:60,y:170,width:100,height:20),height:20)
    do {
        _=try NativeFinalTextPaintAdmission.place([shape.fill,peer],page:page,fixedOrigins:fixed)
        require(false,"changed height shifts recomputed median target and rejects retained positions")
    } catch {}
    let after=try Reflow.refineInteriorWords(before,descriptors:["owner":d],page:page,completePeerContext:true,
        outerWidths:{_ in 100},extraOuterWidths:{_ in []},allowRowReduction:true) {_,_,_ in shape}
    require(after.selected.count==1,"certified current cohort anchor admits safe row reduction")
    require(after.fills[0].frame.minY==170 && after.fills[1].frame==peer.frame,"both shared starts retained")
    require(after.audit[0]["retainedSourceClusterAnchorApplied"]as?Bool == true,"retention is explicit in receipt")
    require(NSDictionary(dictionary:after.audit[1]).isEqual(to:before.audit[1]),"peer audit remains original")
    for (origins,anchors) in [
        (["owner":first.frame.origin],["retained":CGFloat(170)]),
        (fixed,["unknown":CGFloat(170)]),
        (fixed,["retained":CGFloat(180)]),
        (["owner":CGPoint(x:60,y:390),"peer":CGPoint(x:250,y:390)],["retained":CGFloat(390)])] {
        do {
            _=try NativeFinalTextPaintAdmission.place([shape.fill,peer],page:page,fixedOrigins:origins,retainedClusterAnchors:anchors)
            require(false,"incomplete, unknown, mismatched or capacity-invalid anchors must fail")
        } catch {}
    }
    unsetenv("AIDOKU_INTERIOR_MEASURED_WIDTHS")
    print("RETAINED_COHORT real target recomputation, complete certified anchor, immutable peer and invalid override controls passed")
}
func diagnosticControls()throws {
    let before=fixture()
    func outcomes(_ result:Reflow.Result)->[[String:Any]] {
        let records=result.diagnostics["candidateOutcomes"] as? [[String:Any]] ?? []
        require(JSONSerialization.isValidJSONObject(result.diagnostics),"diagnostics are JSON-safe")
        return records
    }
    func rejected(_ reason:String,_ make:@escaping (String,CGFloat,CGRect)throws->Reflow.Candidate?)throws {
        let result=try words(before,make:make)
        try unchanged(before,result)
        let records=outcomes(result)
        require(records.count==1,"one record per retained-width attempt")
        let record=records[0]
        require(record["reason"] as? String == reason,"specific rejection: \(reason)")
        require(record["owner"] as? String == "owner" && record["outerWidthPixels"] as? Double == 201.25,
            "candidate owner/width bound")
        require(record["status"] as? String == "rejected" && record["rowsBefore"] as? Int == 2 &&
            record["cutsBefore"] as? Int == 1 && record["stage"] is String,"old rows/cuts/stage present")
    }
    try rejected("factory-unavailable") {_,_,_ in nil}
    try rejected("inherited-carrier") {_,_,b in candidate(before.fills[0],b,height:20,font:19)}
    try rejected("ownership") {_,_,b in candidate(before.fills[0],b,height:20,
        ranges:[NSRange(location:0,length:2),NSRange(location:3,length:19)])}
    try rejected("row-budget-increase") {_,_,b in candidate(before.fills[0],b,height:20,
        ranges:[NSRange(location:0,length:6),NSRange(location:6,length:5),
                NSRange(location:11,length:6),NSRange(location:17,length:5)])}
    try rejected("quality-word-cuts-not-improved") {_,_,b in candidate(before.fills[0],b,height:20,ranges:cutDescriptor.ranges)}
    try rejected("frame-integrality") {_,_,b in
        var c=candidate(before.fills[0],b,height:20);c.fill.frame.origin.x+=0.5;return c
    }
    try rejected("image-width-binding") {_,_,b in
        var c=candidate(before.fills[0],b,height:20);c.fill.frame.size.width+=1;return c
    }
    try rejected("image-height-binding") {_,_,b in
        var c=candidate(before.fills[0],b,height:20);c.fill.frame.size.height+=1;return c
    }
    let fragmented=Reflow.Descriptor(text:text,ranges:[NSRange(location:0,length:2),NSRange(location:2,length:3),
        NSRange(location:5,length:5),NSRange(location:10,length:5),NSRange(location:15,length:7)])
    let reduction=try words(before,d:fragmented) {_,_,b in candidate(before.fills[0],b,height:20)}
    try unchanged(before,reduction)
    require(outcomes(reduction).first?["reason"] as? String == "row-budget-reduction","lower row budget diagnosed")
    let marginResult=try words(before) {_,_,b in
        var c=candidate(before.fills[0],b,height:20);c.fill.image=raster(198,20);c.fill.frame.size.width=198;return c
    }
    try unchanged(before,marginResult)
    let marginRecord=outcomes(marginResult)[0]
    require(marginRecord["reason"] as? String == "contour-margin" &&
        (marginRecord["marginAfterPixels"] as! Int)<(marginRecord["marginBeforePixels"] as! Int),"margin gate has numerical witness")
    enum ProbeError:Error {case expected}
    let failure=try words(before) {_,_,_ in throw ProbeError.expected}
    require(outcomes(failure)[0]["stage"] as? String == "factory" &&
        outcomes(failure)[0]["reason"] as? String == "candidate-error","thrown error retains failing stage")
    let success=try words(before)
    require(outcomes(success)[0]["status"] as? String == "selected","committed candidate marked selected")

    setenv("AIDOKU_INTERIOR_MEASURED_WIDTHS","1",1)
    var factories=0
    let measured=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 140},extraOuterWidths:{_ in [150,160]}) {_,w,b in
            factories+=1
            return candidate(before.fills[0],CGRect(x:b.minX,y:b.minY,width:w,height:20),height:20,
                ranges:w==140 ? cutDescriptor.ranges:rows)
        }
    let records=outcomes(measured)
    require(factories==3 && records.count==4,"cached retained-width failure plus three measured attempts logged without extra paint")
    require(records.filter {$0["pass"] as? String == "retained-width"}.count==1,"incumbent failure survives aggregation")
    require(records.filter {$0["status"] as? String == "selected"}.count==1 &&
        records.first {$0["status"] as? String == "selected"}?["outerWidthPixels"] as? Double == 150,"final winner only")
    require(records.contains {$0["status"] as? String == "admissible-not-selected" &&
        $0["outerWidthPixels"] as? Double == 160},"admissible nonwinner distinguished from rejection")
    require((measured.diagnostics["rejections"] as? [String:Int])?["quality-word-cuts-not-improved"]==2,
        "both passes' rejection counts survive")
    require(measured.diagnostics["candidateOutcomesTruncatedCount"] as? Int == 0,"no false truncation")
    let incumbent=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 201.25},extraOuterWidths:{_ in
            require(false,"fully repaired incumbent is not revisited");return []
        }) {_,_,b in candidate(before.fills[0],b,height:20)}
    require(outcomes(incumbent).count==1 && outcomes(incumbent)[0]["status"] as? String == "selected",
        "empty second pass does not erase incumbent outcome")

    // Deliberately reject before native admission; overlapping synthetic owners
    // are safe here because no geometry is proposed or admitted. Two-pass cache
    // revisits create1024 outcomes but only768 actual factories, unchanged.
    var manyFills:[Fill]=[],manyAudits:[[String:Any]]=[],manyDescriptors:[String:Reflow.Descriptor]=[:]
    for i in 0..<256 {
        let owner="bounded-\(i)";var fill=before.fills[0];fill.ownerID=owner
        var audit=before.audit[0];audit["owner"]=owner
        manyFills.append(fill);manyAudits.append(audit);manyDescriptors[owner]=cutDescriptor
    }
    factories=0
    let bounded=try Reflow.refineInteriorWords((manyFills,manyAudits),descriptors:manyDescriptors,page:page,
        completePeerContext:true,outerWidths:{_ in 140},extraOuterWidths:{_ in [150,160]}) {_,_,_ in factories+=1;return nil}
    let boundedRecords=outcomes(bounded)
    require(factories==768 && bounded.diagnostics["actualFactoryCalls"] as? Int == 768,"diagnostic cap never changes factory budget")
    require(boundedRecords.count==768 && bounded.diagnostics["candidateOutcomeCount"] as? Int == 1024 &&
        bounded.diagnostics["candidateOutcomesTruncatedCount"] as? Int == 256,"one page-wide768 cap and exact omitted count")
    require(boundedRecords.filter {$0["pass"] as? String == "retained-width"}.count==256,"all incumbent failures retained first")
    require((bounded.diagnostics["candidateOutcomeStatusCounts"] as? [String:Int])?["rejected"]==1024,
        "status counts include omitted outcomes")
    let invalid=try Reflow.refineInteriorWords((manyFills,manyAudits),descriptors:manyDescriptors,page:page,
        completePeerContext:true,outerWidths:{_ in CGFloat.nan},extraOuterWidths:{_ in
            require(false,"invalid initial width never calls extra provider");return []
        }) {_,_,_ in require(false,"invalid initial width never paints");return nil}
    require(JSONSerialization.isValidJSONObject(invalid.diagnostics),"invalid widths cannot poison JSON")
    require(invalid.diagnostics["ownerFailureCount"] as? Int == 512 &&
        (invalid.diagnostics["ownerFailures"] as? [[String:Any]])?.count==256 &&
        invalid.diagnostics["ownerFailuresTruncatedCount"] as? Int == 256,"owner preflight failures aggregated and bounded")
    unsetenv("AIDOKU_INTERIOR_MEASURED_WIDTHS")
    print("DIAGNOSTICS specific gates, numerical evidence, winner status, two-pass failures and768 cap passed")
}
func exactShape(_ a:NativeFinalTextPaintAdmission.Footprint,_ b:NativeFinalTextPaintAdmission.Footprint)->Bool {
    a.bounds==b.bounds && a.pixels==b.pixels && a.runs.count==b.runs.count &&
        zip(a.runs,b.runs).allSatisfy{$0.y==$1.y && $0.left==$1.left && $0.right==$1.right}
}
func shapeGateLegacyExact()throws {
    let before=fixture(),old=try words(before)
    var gates=0,factories=0
    let original=try NativeFinalTextPaintAdmission.retainedFootprint(before.fills[0])
    let result=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 201.25},shapeGate:{owner,baseline,_ in
            require(owner=="owner" && exactShape(baseline,original),"original bound on legacy gate")
            gates+=1;return (true,["observationComplete":true])
        }) {_,_,bounds in factories+=1;return candidate(before.fills[0],bounds,height:20)}
    require(gates==1 && factories==1,"legacy accepted first origin never expands")
    for i in old.fills.indices {
        require(result.fills[i].frame==old.fills[i].frame,"legacy geometry exact")
        require(try NativeMandatoryDisplayStroke.rgba(result.fills[i].image)==NativeMandatoryDisplayStroke.rgba(old.fills[i].image),"legacy raster exact")
    }
    require(result.selected["owner"]?.metadata["interiorWordExpandedSearch"]as?Bool == false,"legacy winner dominates expansion")
}
func shapeGateVetoAndUnknown()throws {
    let before=fixture(),original=try NativeFinalTextPaintAdmission.retainedFootprint(before.fills[0])
    for verdict:Bool? in [false,nil] {
        var gates=0
        let result=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
            completePeerContext:true,outerWidths:{_ in 201.25},extraOuterWidths:{_ in [202]},allowRowReduction:true,
            shapeGate:{_,baseline,_ in
                gates+=1;require(exactShape(baseline,original),"immutable original through two passes/fallback")
                return (verdict,["observationComplete":verdict != nil])
            }) {_,_,bounds in candidate(before.fills[0],bounds,height:20)}
        try unchanged(before,result)
        require(gates>0,"veto and unknown actually reached gate")
        let budgets=result.diagnostics["originAttemptsByOwnerWidth"]as?[String:Int] ?? [:]
        require(!budgets.isEmpty && budgets.values.allSatisfy{$0<=8},"origin budget includes repeated passes")
    }
}
func shapeGatePolicyProjectionRescue()throws {
    let before=fixture(),original=try NativeFinalTextPaintAdmission.retainedFootprint(before.fills[0])
    var sawLegacy=false,sawProjected=false
    let result=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 201.25},shapeGate:{_,baseline,proposed in
            require(exactShape(baseline,original),"no candidate alpha grandfathering")
            let moved=proposed.bounds.origin != original.bounds.origin
            if moved{sawProjected=true}else{sawLegacy=true}
            return (moved,["observationComplete":true])
        }) {_,_,bounds in candidate(before.fills[0],bounds,height:20)}
    require(sawLegacy && sawProjected && result.selected.count==1,"actual projected origin rescues rejected center")
    require(result.fills[0].frame != before.fills[0].frame,"real retained raster translated")
    require(result.fills[1].image === before.fills[1].image && result.fills[1].frame==before.fills[1].frame,"all peers pinned")
    require(NSDictionary(dictionary:result.audit[1]).isEqual(to:before.audit[1]),"peer audit unchanged")
    let support=try NativeFinalTextPaintAdmission.retainedFootprint(result.fills[0])
    require(support.runs.allSatisfy{before.fills[0].textExpansionPolicy!.allows(CGRect(x:$0.left,y:$0.y,width:$0.right-$0.left,height:1),page:page)},"actual alpha remains assigned mask")
    try NativeFinalTextPaintAdmission.verifyRetainedPlacement(result.fills,
        footprints:result.fills.map{try NativeFinalTextPaintAdmission.retainedFootprint($0)},page:page)
    let budgets=result.diagnostics["originAttemptsByOwnerWidth"]as?[String:Int] ?? [:]
    require(!budgets.isEmpty && budgets.values.allSatisfy{$0<=8},"all-phase hard origin budget")
    require(result.selected["owner"]?.metadata["interiorWordExpandedSearch"]as?Bool == true,"expanded selection truthful")
}
try shapeGateLegacyExact()
try shapeGateVetoAndUnknown()
try shapeGatePolicyProjectionRescue()

func contourFallbackPreservesWinnersAndOriginalSource()throws {
    let before=fixture(),original=try NativeFinalTextPaintAdmission.retainedFootprint(before.fills[0])
    let approved:Reflow.ShapeGate={_,old,_ in
        require(exactShape(old,original),"contour family keeps ORIGINAL alpha authority")
        return (true,["observationComplete":true])
    }
    let first=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 201.25},shapeGate:approved,
        makeContour:{_,_,_ in require(false,"an accepted fixed-width winner must never be reshaped");return nil},
        make:{_,_,bounds in candidate(before.fills[0],bounds,height:20)})
    require(first.selected.count==1,"fixed-width winner retained")
    var contours=0
    let second=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 201.25},shapeGate:approved,
        makeContour:{_,_,bounds in contours+=1;return candidate(before.fills[0],bounds,height:20)},
        make:{_,_,_ in nil})
    require(contours==1 && second.selected.count==1,"contour family reached only after complete ordinary search")
    require(second.diagnostics["contourFallbackOwners"]as?[String]==["owner"],"selected contour receipt")
    require(second.fills[1].image === before.fills[1].image && second.fills[1].frame==before.fills[1].frame,"contour fallback pins peers")
    let disabled=try Reflow.refineInteriorWords(before,descriptors:["owner":cutDescriptor],page:page,
        completePeerContext:true,outerWidths:{_ in 201.25},
        makeContour:{_,_,_ in require(false,"no source gate means no contour search");return nil},make:{_,_,_ in nil})
    try unchanged(before,disabled)
}
try contourFallbackPreservesWinnersAndOriginalSource()

try controls()
try measuredWidthControls()
try retainedCohortAnchorControls()
try bodyResidualControls()
try incumbentPreservationControls()
try diagnosticControls()
'''


def main():
    with tempfile.TemporaryDirectory(prefix="aidoku-interior-words-") as directory:
        cache = Path(directory)
        carrier = (ENGINE / "NativeMandatoryDisplayStroke+Composer.swift").read_text()
        (cache / "Primitive.swift").write_text(carrier.split("    /// Concrete minimal adapter")[0] + "}\n")
        (cache / "main.swift").write_text(HARNESS)
        for name in SOURCES:
            data = (ENGINE / (name + ".swift")).read_text()
            if name == "NativeFinalTextPaintAdmission":
                needle = "        guard input.allSatisfy"
                assert data.count(needle) == 1
                data = data.replace(needle, '        reflowAdmissionCalls += 1\n'
                                    '        require(fixedOrigins.count == input.count || !retainedClusterAnchors.isEmpty, "all origins fixed")\n' + needle)
                needle = "        try proposal(fill)"
                assert data.count(needle) == 1
                data = data.replace(needle, '        reflowFootprintCalls[fill.ownerID ?? "", default: 0] += 1\n'
                                    '        return try proposal(fill)')
            (cache / (name + ".swift")).write_text(data)
        env = {k: v for k, v in os.environ.items() if not k.startswith("AIDOKU_")}
        env["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang-modules")
        binary = cache / "check"
        subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(cache / "swift-modules"),
                        *[str(cache / (name + ".swift")) for name in SOURCES],
                        str(cache / "Primitive.swift"), str(cache / "main.swift"), "-o", str(binary)], check=True, env=env)
        subprocess.run([str(binary)], check=True, env=env)


if __name__ == "__main__":
    main()
