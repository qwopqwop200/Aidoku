#!/usr/bin/env python3
"""Focused shape-clearance checks: synthetic memory-only RGB, real alpha support.
Explicit parent invocation compiles in a temporary isolated directory, never shared builds.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
BASE = runpy.run_path(str(Path(__file__).with_name('run-source-physical-interior-smoke.py')))
SOURCES = BASE['SOURCES']
HARNESS = r'''
import CoreGraphics
import Foundation
import Darwin

typealias C = NativeSourcePhysicalInteriorContext
typealias N = NativeFinalTextPaintAdmission
typealias F = C.Primitive
var checks=0
func check(_ ok:Bool,_ reason:String) {
    if !ok { FileHandle.standardError.write(Data("FAIL \(checks): \(reason)\n".utf8));exit(1) }
    checks += 1
}
func primitive(_ x:Int,_ y:Int,_ w:Int,_ h:Int) throws -> F {
    var rgba=[UInt8](repeating:0,count:w*h*4)
    for p in stride(from:0,to:rgba.count,by:4) { rgba[p+3]=255 }
    var f=F(image:try NativeMandatoryDisplayStroke.image(rgba,width:w,height:h),
        frame:CGRect(x:x,y:y,width:w,height:h),fontOutputPixels:12)
    f.ownerID="synthetic-shape";f.hasFinalEffects=true
    return f
}
func foot(_ f:F) throws -> N.Footprint { try N.retainedFootprint(f) }
func norm(_ r:CGRect,_ w:Int=96,_ h:Int=80)->[Double] {
    [r.minX/CGFloat(w),r.minY/CGFloat(h),r.width/CGFloat(w),r.height/CGFloat(h)].map(Double.init)
}
func inside(_ f:F)->F {
    var f=f
    let r=norm(CGRect(x:4,y:4,width:88,height:72))
    let p=NativeTextExpansionPolicy(allowedRectNormalized:r,candidates:[r],maskCoverage:[1],backgroundRisk:[0],
        sourceFontPixels:12,kind:"inside-balloon-mask",maskRectNormalized:r,
        maskSpansNormalized:[4.0/96,92.0/96,4.0/96,92.0/96],
        maskIntervalRowsNormalized:[[4.0/96,92.0/96],[4.0/96,92.0/96]])
    f.textExpansionPolicy=p
    f.textPlacementGuide = .init(rectNormalized:norm(CGRect(x:35,y:28,width:20,height:20)),horizontal:.center,vertical:.center)
    return f
}
do {
    let page=CGRect(x:0,y:0,width:96,height:80)
    let white=[UInt8](repeating:248,count:96*80*3),empty=[UInt8](repeating:0,count:96*80)
    let flat=C(rgb:white,width:96,height:80,erased:empty,sourceIdentity:"synthetic-flat")!
    let old=try primitive(20,20,2,2),before=try foot(old),changed=try foot(primitive(20,20,3,3))
    let pass=flat.shapeClearance(incumbent:old,before:before,after:changed,page:page)
    check(pass.allowed==true,"different alpha counts can pass fully observed NEW boundary")
    check(pass.audit["newAlphaPixels"] as? Int == 5,"exact after-minus-original alpha count")
    check(pass.audit["originalAlphaPixelsExempt"] as? Int == 4,"old fixed alpha exemption count")
    check(pass.audit["componentEvidenceAvailable"] as? Bool == false && pass.audit["physicalContainmentMeasured"] as? Bool == false,
        "unknown component is explicitly not certified")
    check(pass.audit["observationComplete"] as? Bool == true,"every NEW pixel observed for true")
    let wrong=try foot(primitive(21,20,2,2))
    check(flat.shapeClearance(incumbent:old,before:wrong,after:changed,page:page).allowed==nil,"before must bind actual ORIGINAL primitive")
    let malformed=N.Footprint(runs:changed.runs,bounds:changed.bounds,pixels:changed.pixels+1)
    check(flat.shapeClearance(incumbent:old,before:before,after:malformed,page:page).allowed==nil,"false alpha count unknown")
    let border=try foot(primitive(0,20,2,2))
    check(flat.shapeClearance(incumbent:old,before:before,after:border,page:page).allowed==nil,"source image edge is unobserved, never a pass")
    let unboundPage=CGRect(x:0,y:0,width:95,height:80)
    check(flat.shapeClearance(incumbent:old,before:before,after:changed,page:unboundPage).allowed==nil,"page dimensions bound to source")

    var line=white
    for y in 0..<80 { for c in 0..<3 {line[(y*96+40)*3+c]=0} }
    let rim=C(rgb:line,width:96,height:80,erased:empty,sourceIdentity:"synthetic-retained-rim")!
    let near=try primitive(30,30,2,2),nearBefore=try foot(near),nearAfter=try foot(primitive(30,30,9,2))
    let veto=rim.shapeClearance(incumbent:near,before:nearBefore,after:nearAfter,page:page)
    check(veto.allowed==false && (veto.audit["adverseNewAlphaPixels"] as? Int ?? 0)>0,"NEW alpha within preserved edge distance2 vetoes")
    let touching=try primitive(39,30,2,2),touchingBefore=try foot(touching)
    let noNew=rim.shapeClearance(incumbent:touching,before:touchingBefore,after:touchingBefore,page:page)
    check(noNew.allowed==true && noNew.audit["newAlphaPixels"] as? Int == 0,"existing rim-touch alpha exempt only at its original coordinates")
    // A measured bad pixel remains decisive even with an unobserved image-edge run.
    let mixed=N.Footprint(runs:[.init(y:30,left:0,right:1),.init(y:30,left:38,right:39)],
        bounds:CGRect(x:0,y:30,width:39,height:1),pixels:2)
    check(rim.shapeClearance(incumbent:near,before:nearBefore,after:mixed,page:page).allowed==false,"known boundary violation dominates other unknown pixels")
    var erasedLine=empty
    for y in 0..<80 {erasedLine[y*96+40]=255}
    let excluded=C(rgb:line,width:96,height:80,erased:erasedLine,sourceIdentity:"synthetic-erased-line")!
    check(excluded.shapeClearance(incumbent:near,before:nearBefore,after:nearAfter,page:page).allowed==true,
        "original erased glyph edges are not preserved source boundaries")

    // Real known component with a large non-erased enclosed ink hole. The NEW
    // centre pixel is farther than2 from its rim, but still forbidden by raw mask.
    var room=[UInt8](repeating:0,count:96*80*3),erased=empty
    for y in 0..<80 {for x in 0..<96 {
        let inside=x>=20 && x<76 && y>=16 && y<64
        let glyph=x>=42 && x<46 && y>=34 && y<43
        for c in 0..<3 {room[(y*96+x)*3+c]=glyph ? 0:(inside ? 248:[UInt8(30),60,80][c])}
        if glyph {erased[y*96+x]=255}
    }}
    for y in 25..<37 {for x in 60..<72 {for c in 0..<3 {room[(y*96+x)*3+c]=0}}}
    let known=C(rgb:room,width:96,height:80,erased:erased,sourceIdentity:"synthetic-known-enclosed-hole")!
    let onHole=inside(try primitive(65,30,1,1)),holeBefore=try foot(onHole),holeAfter=try foot(primitive(65,30,2,1))
    let hole=known.shapeClearance(incumbent:onHole,before:holeBefore,after:holeAfter,page:page)
    check(hole.audit["componentEvidenceAvailable"] as? Bool == true,"known component fixture actually available")
    check(hole.allowed==false && hole.audit["status"] as? String == "known-component-new-alpha-veto","NEW enclosed-hole paint rejected by immutable raw component")
    check(known.shapeClearance(incumbent:onHole,before:holeBefore,after:holeBefore,page:page).allowed==true,
        "the original hole pixel can remain without grandfathering a neighbour")
    let shifted=try foot(primitive(66,30,1,1))
    check(known.shapeClearance(incumbent:onHole,before:holeBefore,after:shifted,page:page).allowed==false,
        "old hole exemption is never translated with candidate")
    let knownSafe=inside(try primitive(35,48,2,2)),safeBefore=try foot(knownSafe),safeAfter=try foot(primitive(35,48,3,3))
    let knownPass=known.shapeClearance(incumbent:knownSafe,before:safeBefore,after:safeAfter,page:page)
    check(knownPass.allowed==true && knownPass.audit["physicalContainmentMeasured"] as? Bool == true,
        "known raw containment plus complete boundary observations is explicitly conditional")
    check(knownPass.audit["universalPhysicalCertificate"] as? Bool == false,"never universal physical truth")

    // Shared16M sampling reservation: translation and shape use the SAME counter.
    let bigPage=CGRect(x:0,y:0,width:512,height:512)
    let budget=C(rgb:[UInt8](repeating:248,count:512*512*3),width:512,height:512,
        erased:[UInt8](repeating:0,count:512*512),sourceIdentity:"synthetic-shared-budget")!
    let tiny=try primitive(250,250,1,1),tinyBefore=try foot(tiny),large=try foot(primitive(240,240,128,128))
    var firstAllowed=false,budgetUnknown=false
    for i in 0..<1000 {
        let result=budget.shapeClearance(incumbent:tiny,before:tinyBefore,after:large,page:bigPage)
        if i==0 {firstAllowed=result.allowed==true}
        if result.allowed==nil {
            check(result.audit["status"] as? String == "context-new-alpha-sample-budget","exact shared sample budget reason")
            budgetUnknown=true;break
        }
        check(result.allowed==true,"flat source trials pass before exhausted")
    }
    check(firstAllowed && budgetUnknown,"shared16M budget exhausted into unknown, never pass")
    let perCall=C(rgb:[UInt8](repeating:248,count:1604*1604*3),width:1604,height:1604,
        erased:[UInt8](repeating:0,count:1604*1604),sourceIdentity:"synthetic-per-candidate-budget")!
    let over=N.Footprint(runs:(10..<1510).map {.init(y:$0,left:10,right:1510)},bounds:CGRect(x:10,y:10,width:1500,height:1500),pixels:2_250_000)
    check(perCall.shapeClearance(incumbent:tiny,before:tinyBefore,after:over,page:CGRect(x:0,y:0,width:1604,height:1604)).allowed==nil,
        "new samples over2M unknown before source work")
    print("PASS \(checks) frozen original shape clearance checks; no dataset images or RGB exports")
} catch {FileHandle.standardError.write(Data("FAIL after \(checks): \(error)\n".utf8));exit(1)}
'''


def main():
    with tempfile.TemporaryDirectory(prefix='aidoku-source-shape-') as directory:
        cache = Path(directory)
        composer = (ENGINE/'NativeAOTTranslationPageComposer.swift').read_text()
        text_layer = composer[composer.index('    struct TextLayer {'):composer.index('    struct Result {')]
        failure = re.search(r'    enum Failure: Error \{.*?\n    \}', composer, re.S).group()
        (cache/'ComposerTypes.swift').write_text('import CoreGraphics\nimport Foundation\nfinal class NativeAOTTranslationPageComposer {\n'+text_layer+failure+'\n}\n')
        hashes = {}
        for name in SOURCES:
            data = (ENGINE/(name+'.swift')).read_bytes()
            (cache/(name+'.swift')).write_bytes(data)
            hashes[name+'.swift'] = hashlib.sha256(data).hexdigest()
        (cache/'main.swift').write_text(HARNESS)
        env = {k:v for k,v in os.environ.items() if not k.startswith('AIDOKU_')}
        env['CLANG_MODULE_CACHE_PATH'] = str(cache/'clang-modules')
        binary = cache/'check'
        start = time.monotonic()
        subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(cache/'swift-modules'),
            *[str(cache/(name+'.swift')) for name in SOURCES],str(cache/'ComposerTypes.swift'),
            str(cache/'main.swift'),'-o',str(binary)],check=True,env=env)
        compiled = time.monotonic()
        print(f'Isolated compile seconds: {compiled-start:.3f}',flush=True)
        subprocess.run([str(binary)],check=True,env=env)
        print(json.dumps(dict(compileSeconds=round(compiled-start,3),testSeconds=round(time.monotonic()-compiled,3),
            sourceSHA256=hashes,scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            datasetImages=0,sharedBuilds=0,RGBExports=0)))

if __name__ == '__main__': main()
