#!/usr/bin/env python3
"""Parent-run focused synthetic exterior tests. Compiles only in a private temp dir.

No corpus, source RGB, models or shared caches. This runner is deliberately not
registered in a broad test matrix. The implementation worker must not run it.
"""
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble"
INTERIOR = runpy.run_path(str(Path(__file__).with_name("run-balloon-readability-reflow-smoke.py")))
SOURCES = INTERIOR["SOURCES"] + [
    "NativeTextSpacing", "NativeNecessaryCJKBreaks", "NativeWholeWordWrap", "NativeWholeWordWrap+Proposals",
    "NativeWholeWordGlyphPainter", "NativeFinalTextFlow", "NativeContourWordWrap",
]
# Reuse only synthetic fixture construction and exact-RGBA assertions. The
# original interior checks remain unchanged and independently runnable.
HARNESS = INTERIOR["HARNESS"].split("func success()throws")[0] + r'''
import CoreText
import Darwin
// The whole-word painter's unrelated parent bridge needs its Item carrier;
// the actual raw painter is exercised separately by the production smoke.
enum NativeAOTRawTextPainter {
    struct Item {
        let text: String
        let fontSize: CGFloat
        let frame: CGRect
        let chosenFill: CGColor
    }
}
let exteriorDescriptor = Reflow.Descriptor(text:text,ranges:[
    NSRange(location:0,length:2),NSRange(location:2,length:9),NSRange(location:11,length:11)])
func ext(_ before:Admission,complete:Bool=true,descriptor:Reflow.Descriptor=exteriorDescriptor,
         widths:[CGFloat]=[150,150.005,140,130,120],
         make:((String,CGFloat,CGRect)throws->Reflow.Candidate?)?=nil)throws->Reflow.Result {
    try Reflow.refineExterior(before,descriptors:["owner":descriptor],page:page,
        completePeerContext:complete,widths:{_ in widths}) {id,width,bounds in
        if let make {return try make(id,width,bounds)}
        return candidate(before.fills[0],CGRect(x:bounds.minX,y:bounds.minY,width:width,height:bounds.height))
    }
}
func successExterior()throws {
    let before=fixture(inside:false)
    reflowAdmissionCalls=0;reflowFootprintCalls=[:]
    let after=try ext(before)
    require(after.selected.count==1,"one exterior selected")
    require(after.diagnostics["widthRequests"]as?Int == 3,"deduplicated max three content widths")
    require(reflowAdmissionCalls<=3,"max three fixed-origin admissions")
    require(reflowFootprintCalls["peer"]==1,"peer support cached once")
    require(after.fills[1].frame==before.fills[1].frame,"peer frame exact")
    require(try NativeMandatoryDisplayStroke.rgba(after.fills[1].image)==NativeMandatoryDisplayStroke.rgba(before.fills[1].image),"peer RGBA exact")
    require(NSDictionary(dictionary:after.audit[1]).isEqual(to:before.audit[1]),"peer audit exact")
    require(after.audit[0]["exteriorWordCutsAfter"]as?Int == 0,"strict cut reduction")
    require(after.audit[0]["preExteriorReadabilityPlacement"] != nil,"old proof snapshotted")
    require(after.audit[0]["exteriorPalettePreflight"]as?Bool == true,"palette preflight recorded")
    require(after.fills[0].fontOutputPixels==before.fills[0].fontOutputPixels,"retained font")
    // Render the actual admitted primitives and verify the existing native
    // raster gate, rather than treating selection metadata as output proof.
    let context=CGContext(data:nil,width:400,height:400,bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    for fill in after.fills {context.draw(fill.image,in:CGRect(x:fill.frame.minX,y:400-fill.frame.maxY,
        width:fill.frame.width,height:fill.frame.height))}
    try NativeFinalTextPaintAdmission.verifyRaster(context.makeImage()!,expectedPixels:after.audit.reduce(0){$0+($1["paintedPixels"]as!Int)})
    print("PASS exterior strict cuts, max3 widths, actual alpha gate, fixed peer/font/audit")
    for axis in [NativeSourceClusterAlignment.Axis.top,.left] {
        let peer=axis == .top ? CGPoint(x:300,y:170):CGPoint(x:42,y:300)
        let aligned=fixture(peerOrigin:peer,inside:false,axis:axis)
        let widths:[CGFloat]=[150,140,130]
        let result=try ext(aligned,widths:widths,make:{_,width,bounds in
            candidate(aligned.fills[0],CGRect(x:bounds.minX,y:bounds.minY,width:width,height:20),height:20)
        })
        require(result.selected.count==1,"aligned exterior selected")
        let old=try NativeFinalTextPaintAdmission.retainedFootprint(aligned.fills[0]).bounds
        let new=try NativeFinalTextPaintAdmission.retainedFootprint(result.fills[0]).bounds
        require(axis == .top ? old.minY==new.minY:old.minX==new.minX,"exact shared cross-axis anchor")
        require(aligned.fills[1].frame==result.fills[1].frame,"aligned peer fixed")
        let source=aligned.fills[0].textPlacementGuide!.rect(in:page)
        let oldDistance=Reflow.exteriorAnchorDistance(old,source:source,fill:aligned.fills[0])
        let newDistance=Reflow.exteriorAnchorDistance(new,source:source,fill:result.fills[0])
        require(abs(oldDistance - newDistance)<0.001,
                "fixed source anchors do not drift when the block changes size")
    }
}
func exteriorRejections()throws {
    let before=fixture(inside:false)
    unsetenv("AIDOKU_EXTERIOR_READABILITY_REFLOW")
    require(Reflow.exteriorEnabled,"default ON after accepted corpus review")
    setenv("AIDOKU_EXTERIOR_READABILITY_REFLOW","0",1)
    try unchanged(before,try ext(before,make:{_,_,_ in require(false,"explicit OFF");return nil}))
    setenv("AIDOKU_EXTERIOR_READABILITY_REFLOW","1",1)
    try unchanged(before,try ext(before,complete:false,make:{_,_,_ in require(false,"incomplete context skipped");return nil}))
    try unchanged(before,try ext(before,descriptor:descriptor,make:{_,_,_ in require(false,"zero cuts skipped");return nil}))
    let inside=fixture()
    try unchanged(inside,try ext(inside,make:{_,_,_ in require(false,"interior unchanged");return nil}))
    try unchanged(before,try ext(before,widths:[.infinity,-1,0]))
    for change in 0..<7 {
        let rejected=try ext(before) {_,width,bounds in
            var c=candidate(before.fills[0],CGRect(x:bounds.minX,y:bounds.minY,width:width,height:bounds.height))
            switch change {
            case 0:c = candidate(before.fills[0],CGRect(x:42,y:170,width:width,height:20),font:19)
            case 1:return .init(fill:c.fill,ranges:exteriorDescriptor.ranges)
            case 2:return .init(fill:c.fill,ranges:[NSRange(location:0,length:10),NSRange(location:11,length:11)])
            case 3:c.fill.textExpansionPolicy=nil
            case 4:c.fill.balloonTargetRelaxed=true
            case 5:
                let ctx=CGContext(data:nil,width:c.fill.image.width,height:c.fill.image.height,bitsPerComponent:8,bytesPerRow:0,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));ctx.fill(CGRect(x:0,y:0,width:c.fill.image.width,height:c.fill.image.height))
                c.fill.image=ctx.makeImage()!
            default:c.fill.sourceClusterAlignment = .init(groupID:"changed",axis:.top,anchorNormalized:0.4)
            }
            return c
        }
        try unchanged(before,rejected)
    }
    enum CandidateError:Error {case expected}
    let factoryError=try ext(before,make:{_,_,_ in throw CandidateError.expected})
    try unchanged(before,factoryError)
    let failures=factoryError.diagnostics["candidateFailures"]as?[[String:Any]] ?? []
    require(failures.count==3,"one error receipt per bounded width")
    require(failures.allSatisfy { $0["owner"]as?String == "owner" &&
        $0["stage"]as?String == "factory" && $0["error"]as?String == "expected" &&
        $0["contentWidthPixels"]as?Double != nil && $0["errorType"]as?String != nil },
        "errors retain exact stage, type, owner and content width")
    var calls=0
    do {_=try ext(before,make:{_,_,_ in calls+=1;throw CancellationError()});require(false,"cancel propagates")}
    catch is CancellationError {require(calls==1,"cancel stops candidates")}
    // The owner-local fixed-alpha domain must remain hard, even when a factory
    // replaces its closure with an always-true predicate.
    var excluded=before
    var policy=excluded.fills[0].textExpansionPolicy!
    policy.forbiddenBalloonRectNormalized=normalized(page)
    policy.forbiddenBalloonRowsNormalized=(0..<400).map { (150..<170).contains($0) ? [0.1,0.6]:[] }
    policy.balloonExclusionSourceRectNormalized=normalized(CGRect(x:100,y:100,width:80,height:160))
    require(policy.valid,"hard exclusion fixture")
    excluded.fills[0].textExpansionPolicy=policy
    excluded.fills[0].placementDomain={policy.allows($0,page:page)}
    try unchanged(excluded,try ext(excluded,make:{_,width,bounds in
        var c=candidate(excluded.fills[0],CGRect(x:bounds.minX,y:bounds.minY,width:width,height:20))
        c.fill.placementDomain={_ in true};return c
    }))
    // New row effects reach a retained nearby peer even though both base boxes
    // are otherwise legal in the exterior capacity.
    let crowded=fixture(peerOrigin:CGPoint(x:100,y:198),inside:false)
    try unchanged(crowded,try ext(crowded))
    print("PASS default ON, explicit OFF/context/interior/quality/font/palette/state/domain/peer/error/cancel controls")
}
func actualMandatoryPalette()throws {
    let background=CGContext(data:nil,width:400,height:400,bitsPerComponent:8,bytesPerRow:0,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    background.setFillColor(CGColor(gray:0,alpha:1));background.fill(page)
    background.setFillColor(CGColor(gray:1,alpha:1));background.fill(CGRect(x:200,y:0,width:200,height:400))
    let restored=background.makeImage()!
    func pale(_ x:CGFloat)->Fill {
        let ctx=CGContext(data:nil,width:30,height:30,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:2,y:2,width:26,height:26))
        return Fill(image:ctx.makeImage()!,frame:CGRect(x:x,y:100,width:30,height:30),fontOutputPixels:20)
    }
    let black=try Reflow.exteriorPaletteReceipt(pale(50),restored:restored)!
    let white=try Reflow.exteriorPaletteReceipt(pale(300),restored:restored)!
    require(!NSDictionary(dictionary:black).isEqual(to:white),"actual pale-fill/background override detected")
    require(black["finalEndpoint"]as?Int != white["finalEndpoint"]as?Int ||
        black["displayFillRGB"]as?[Int] != white["displayFillRGB"]as?[Int],"fill or endpoint delta observable")
    var owner=pale(155);owner.ownerID="owner"
    owner.textExpansionPolicy = .init(allowedRectNormalized:[0,0,1,1],candidates:[[0,0,1,1]],maskCoverage:[1],backgroundRisk:[0],
        sourceFontPixels:20,kind:"source-near-limited-expansion",maskRectNormalized:nil,maskSpansNormalized:nil)
    owner.textPlacementGuide = .init(rectNormalized:normalized(CGRect(x:130,y:75,width:80,height:80)),horizontal:.center,vertical:.center)
    owner.placementDomain={page.contains($0)}
    let footprint=try NativeFinalTextPaintAdmission.retainedFootprint(owner)
    let admitted=try NativeFinalTextPaintAdmission.place([owner],page:page,fixedOrigins:["owner":footprint.bounds.origin])
    let result=try Reflow.refineExterior(admitted,descriptors:["owner":exteriorDescriptor],page:page,
        completePeerContext:true,restored:restored,widths:{_ in [150]}) {_,_,_ in
        let ctx=CGContext(data:nil,width:150,height:30,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:2,y:2,width:146,height:26))
        var f=admitted.fills[0];f.image=ctx.makeImage()!;f.frame=CGRect(x:95,y:100,width:150,height:30)
        return .init(fill:f,ranges:rows)
    }
    require(result.selected.isEmpty,"background-sensitive palette proposal rejected")
    require((result.diagnostics["rejections"]as?[String:Int])?["final-palette"] == 1,"rejection reaches real palette gate")
    print("PASS real mandatory final palette catches background-dependent changes")
}
func widthAndOwnershipControls()throws {
    let fragmented=Reflow.Descriptor(text:text,ranges:[NSRange(location:0,length:2),
        NSRange(location:2,length:3),NSRange(location:5,length:5),
        NSRange(location:10,length:5),NSRange(location:15,length:7)])
    let reduced=try ext(fixture(inside:false),descriptor:fragmented)
    require(reduced.selected["owner"]?.ranges.count == 2,"safe five-to-two-row repair reaches admission")
    let expanded=[NSRange(location:0,length:1),NSRange(location:1,length:1),
        NSRange(location:2,length:1),NSRange(location:3,length:1),
        NSRange(location:4,length:7),NSRange(location:11,length:11)]
    let retained=fixture(inside:false)
    try unchanged(retained,try ext(retained,make:{_,width,bounds in
        candidate(retained.fills[0],CGRect(x:bounds.minX,y:bounds.minY,width:width,height:20),ranges:expanded)
    }))
    let font=CTFontCreateWithName("AppleSDGothicNeo-Regular"as CFString,20,nil)
    let t="짧은단어 더긴단어입니다",ns=t as NSString
    let r=[NSRange(location:0,length:2),NSRange(location:2,length:5),NSRange(location:7,length:ns.length-7)]
    let widths=NativeFinalTextFlow.terminalExteriorContentWidths(text:t,ranges:r,font:font,current:30,maximum:500)
    require(widths.first==30 && widths.count<=3 && Set(widths).count==widths.count,"content-width palette bounded")
    let black=CGColor(gray:0,alpha:1),width=CGFloat(180),pitch=CGFloat(42)
    if let fixed=try NativeFinalTextFlow.horizontalFixedWidth(text:"alpha beta",font:font,size:20,width:width,
        minimumLineHeight:pitch,outwardExtent:2,color:black) {
        require(fixed.size.width==width && fixed.appliedTracking==0 && fixed.complete,"fixed inner width, tracking and ownership")
    } else {require(false,"fixed-width fixture must fit")}
    let newline="alpha\nbeta",hard=Reflow.Descriptor(text:newline,ranges:[NSRange(location:0,length:2),NSRange(location:2,length:4),NSRange(location:6,length:4)])
    let before=fixture(inside:false)
    try unchanged(before,try ext(before,descriptor:hard,make:{_,width,bounds in
        candidate(before.fills[0],CGRect(x:bounds.minX,y:bounds.minY,width:width,height:20),ranges:[NSRange(location:0,length:10)])
    }))
    print("PASS content units, fixed layout and hard paragraph ownership")
}
setenv("AIDOKU_EXTERIOR_READABILITY_REFLOW","1",1)
try successExterior()
try exteriorRejections()
try actualMandatoryPalette()
try widthAndOwnershipControls()
print("All focused exterior controls passed")
'''


def main():
    with tempfile.TemporaryDirectory(prefix="aidoku-exterior-reflow-") as directory:
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
                                    '        require(fixedOrigins.count == input.count, "all origins fixed")\n' + needle)
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
