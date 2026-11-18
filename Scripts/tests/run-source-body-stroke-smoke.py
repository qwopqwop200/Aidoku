#!/usr/bin/env python3
"""Private source-only production leaf: counter-role and independent body/halo forecast regressions."""
import argparse
import hashlib
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
BASE=runpy.run_path(str(Path(__file__).with_name('run-source-role-evidence-smoke.py')))
BODY=r'''
func bodyCase(_ f:Fixture,_ accept:Bool,_ label:String,budget initial:Int=pixels*4,reverse:Bool=false,derive:Bool=false) {
    var input=forecastInput(f)
    input["stroke"]=NSNull()
    if reverse { input["foreground"]=f.stroke; input["sourceInk"]=["foreground":f.stroke,"stroke":f.fill] }
    if derive { input["sourceInk"]=["foreground":f.fill,"stroke":NSNull()] }
    let frozen=try! JSONSerialization.data(withJSONObject:input,options:[.sortedKeys])
    var budget=initial
    let output=Sampler.supportedBodyStrokeForecast(rgba:f.rgba,width:width,height:height,ownership:f.ownership,
        result:input,observationBudget:&budget)
    var errors:[String]=[]
    if (output != nil) != accept { errors.append(accept ? "legitimate body/halo rejected" : "false stroke forecast accepted") }
    if let output {
        if error(Sampler.rgb(output["color"]),f.stroke)>12 { errors.append("source stroke endpoint changed") }
        if output["certified"] as? Bool != false { errors.append("forecast masquerades as role certificate") }
        if output["sourceWidthCalibrated"] as? Bool != false { errors.append("invented source width") }
        if output["backgroundCertified"] as? Bool != false { errors.append("unknown exterior promoted to BG proof") }
        if output["foreground"] != nil { errors.append("stroke evidence mutates FG role") }
        if Int(Sampler.number(output["observerPixels"])) != initial-budget { errors.append("unreported observation debit") }
    }
    if budget<0 || initial<pixels && budget != initial { errors.append("unbounded or underfunded work") }
    if frozen != (try! JSONSerialization.data(withJSONObject:input,options:[.sortedKeys])) { errors.append("backing/source input mutated") }
    report("body-stroke-"+label,errors,output ?? ["spentPixels":initial-budget])
}
func thinFixture()->Fixture {
    var f=fixture("thin-white-orange",fill:white,stroke:orange,background:mint)
    var mask=[Bool](repeating:false,count:pixels)
    for o in [18,44,70,96] { for y in 26..<56 { for x in o..<(o+16) {
        mask[y*width+x]=x==o || x==o+15 || y==40
    } } }
    for y in 0..<height { for x in 0..<width {
        let i=y*width+x
        let halo=(-1...1).contains { dy in (-1...1).contains { dx in
            let xx=x+dx,yy=y+dy;return xx>=0 && xx<width && yy>=0 && yy<height && mask[yy*width+xx]
        } }
        let color=mask[i] ? white : halo ? orange : mint
        for c in 0..<3 { f.rgba[i*4+c]=UInt8(color[c]) }
    } }
    return f
}
let bodyBlue=fixture("blue-white",fill:[51,66,101],stroke:white,background:grey)
let bodyOrange=fixture("white-orange",fill:white,stroke:orange,background:mint)
bodyCase(bodyBlue,true,"blue-white")
bodyCase(bodyOrange,true,"white-orange-H")
bodyCase(thinFixture(),true,"one-pixel-white-orange-H")
bodyCase(bodyBlue,false,"paired-reverse",reverse:true)
bodyCase(bodyOrange,false,"paired-reverse-white-orange",reverse:true)
bodyCase(bodyOrange,true,"observed-edge-frontier",derive:true)
let bodyBlack=fixture("black-white",fill:[0,0,0],stroke:white,background:grey)
bodyCase(bodyBlack,true,"black-white-legitimate")
bodyCase(fixture("black-paper",fill:[0,0,0],stroke:white,background:white),false,"black-white-paper")
bodyCase(fixture("photo",fill:white,stroke:photoEdge,background:photoBG,shape:"blob"),false,"pale-photo")
bodyCase(fixture("island",fill:white,stroke:orange,background:mint,shape:"island"),false,"compact-counter-islands")
var bodyUnowned=bodyBlue;bodyUnowned.ownership=[UInt8](repeating:0,count:pixels)
bodyCase(bodyUnowned,false,"unowned")
bodyCase(fixture("AA-only",fill:white,stroke:orange,background:mint,mixedStroke:true),false,"AA-only-stroke")
bodyCase(bodyBlue,false,"budget-zero",budget:0)
bodyCase(bodyBlue,false,"budget-short",budget:pixels-1)
let bodyCancelGate=AsyncStream<Void>.makeStream()
let bodyCancelled=Task.detached {
    for await _ in bodyCancelGate.stream { break }
    var input=forecastInput(bodyBlue);input["stroke"]=NSNull()
    var budget=pixels
    let output=Sampler.supportedBodyStrokeForecast(rgba:bodyBlue.rgba,width:width,height:height,
        ownership:bodyBlue.ownership,result:input,observationBudget:&budget)
    return Task.isCancelled && output==nil && budget==pixels
}
bodyCancelled.cancel();bodyCancelGate.continuation.finish()
let bodyCancelGroup=DispatchGroup();bodyCancelGroup.enter()
Task.detached {
    let ok=await bodyCancelled.value
    report("body-stroke-cancelled",ok ? [] : ["cancelled body observer accepted or spent"],[:])
    bodyCancelGroup.leave()
}
bodyCancelGroup.wait()
// Validate actual estimator -> full stage roles, not only a supplied hypothesis.
for f in [bodyOrange,thinFixture()] {
    let provider=CGDataProvider(data:Data(f.rgba) as CFData)!
    let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let stage=NativeSourceColorSamplingStage(image:image,enabled:true,phase:"translation",budget:.init(remainingSamples:1))
    let output=stage.sampleOriginalStyle(bounds:[0,0,1,1],geometry:["polygon":[[0.0,0],[1,0],[1,1],[0,1]]])
    var errors:[String]=[]
    if error(Sampler.rgb(output?["foreground"]),f.fill)>12 { errors.append("legitimate White fill not preserved by full stage") }
    if error(Sampler.rgb(output?["stroke"]),f.stroke)>12 { errors.append("legitimate Orange stroke not preserved by full stage") }
    report("body-full-stage-"+f.name,errors,output ?? [:])
}
'''

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--real-case',action='append',nargs=3,default=[])
    p.add_argument('--output',type=Path)
    a=p.parse_args()
    with tempfile.TemporaryDirectory(prefix='aidoku-body-stroke-leaf-') as d:
        t=Path(d);cache=t/'module-cache';cache.mkdir()
        env=os.environ.copy();env.update(CLANG_MODULE_CACHE_PATH=str(cache),SWIFT_MODULECACHE_PATH=str(cache))
        if a.output:a.output.mkdir(parents=True,exist_ok=True);env['AIDOKU_ROLE_DIAGNOSTICS_DIR']=str(a.output.resolve())
        parts=[]
        for name in ['NativeSourceColorSampler.swift','NativeTranslationPixelKernels.swift','NativeSourceROIFeatures.swift',
                     'NativeCaptionSourcePalette.swift','NativeObservedSourcePalette.swift','NativeSourceLetteringScale.swift',
                     'NativeSourceColorSamplingStage.swift']:
            b=(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'/name).read_bytes();parts.append(b)
            print('SOURCE',name,hashlib.sha256(b).hexdigest(),flush=True)
        real=BASE['REAL_HARNESS']
        # Match native source normalization/admission. Kept owners still exclude.
        real=real.replace('budget: .init(remainingSamples: items.count)',
            'budget: .init(remainingSamples: items.filter { $0["keptLettering"] as? Bool != true && !($0["text"] as? String ?? "").isEmpty }.count)')
        real=real.replace('        let id = items[index]["id"] as! String',
            '        guard items[index]["keptLettering"] as? Bool != true, !((items[index]["text"] as? String) ?? "").isEmpty else { continue }\n        let id = items[index]["id"] as! String')
        real=real.replace('let geometry: Payload = ["polygon": polygon(bounds[index]),',
            'let geometry: Payload = ["sourceVertical": items[index]["sourceVertical"] ?? false, "letteringScaleTransportVersion": 1, "polygon": polygon(bounds[index]),')
        real=real.replace('    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!',r'''
    let originalImage=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
    let reduction=min(1,8192/Double(max(originalImage.width,originalImage.height)),sqrt(4_000_000/Double(originalImage.width)/Double(originalImage.height)))
    let nw=max(1,Int(floor(Double(originalImage.width)*reduction))),nh=max(1,Int(floor(Double(originalImage.height)*reduction)))
    let image:CGImage
    if reduction==1 {image=originalImage} else {
        let ctx=CGContext(data:nil,width:nw,height:nh,bitsPerComponent:8,bytesPerRow:nw*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.draw(originalImage,in:CGRect(x:0,y:0,width:nw,height:nh));image=ctx.makeImage()!
    }
''')
        real=real.replace('        let details: Payload = ["image": input, "layout": layoutPath, "id": id,',r'''
        var problems:[String]=[]
        // Explicit known original core/halo roles are test oracles, not production RGB rules.
        let name=url.deletingLastPathComponent().lastPathComponent
        let expectedFG:[Double]=name=="0010" ? [253,254,251] : [205,19,150]
        let expectedEdge:[Double]=name=="0010" ? [225,90,4] : [253,252,252]
        if error(Sampler.rgb(result?["foreground"]),expectedFG)>12 {problems.append("actual ordered foreground lost or inverse role survived")}
        if error(Sampler.rgb(result?["stroke"]),expectedEdge)>12 {problems.append("actual observed halo still NULL or changed")}
        report("required-body-actual-"+name+"-"+id,problems,result ?? [:])
        let details: Payload = ["image": input, "layout": layoutPath, "id": id,
''')
        (t/'main.swift').write_bytes(b'\n'.join(parts)+BASE['HARNESS'].encode()+BODY.encode()+BASE['ORACLE_HARNESS'].encode()+real.encode()+b'\nprint("BODY_SUMMARY PASS=\\(passed) FAIL=\\(failed)")\nif failed != 0 { exit(1) }\n')
        lib=t/'kernels.a'
        subprocess.run(['rustc','--crate-type','staticlib','--crate-name','aidoku_overlay_kernels','-C','opt-level=3','-C','panic=abort',str(ROOT/'Scripts/overlay-kernels/kernels.rs'),'-o',str(lib)],env=env,check=True)
        subprocess.run(['xcrun','swiftc','-O','-D','AIDOKU_SOURCE_ROLE_LOCAL_CANDIDATE','-module-cache-path',str(cache),str(t/'main.swift'),'-I',str(ROOT/'Scripts/overlay-kernels/native'),str(lib),'-o',str(t/'smoke')],env=env,check=True)
        subprocess.run([str(t/'smoke'),*[s for case in a.real_case for s in case]],env=env,check=True)

if __name__=='__main__':main()
