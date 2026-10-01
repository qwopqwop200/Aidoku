#!/usr/bin/env python3
"""Native-size source sampling policy oracle, separate from WebKit image parity.

The frozen JS Canvas mock accepts integer 1:1 crops and uniform-color fractional
or scaled fixtures. This verifies original pixel selection, phase/cache/detail
budgets, ownership and full palette policy; nonuniform Canvas raster parity
belongs to the real WebKit fixture suite.
"""
import argparse
import json
import hashlib
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
SWIFT = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"

NODE = r'''
const fs = require('fs'), vm = require('vm');
const fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const source=fs.readFileSync(process.argv[1],'utf8').match(/static let script = """\r?\n([\s\S]*?)\r?\n    """/)[1].replace(/^    /gm,'');
const geometry=fs.readFileSync(process.argv[2],'utf8').match(/static let script = """\r?\n([\s\S]*?)\r?\n    """/)[1].replace(/^    /gm,'');
class Canvas {
 constructor(){this.canvas=this;}
 getContext(){return this;}
 drawImage(image,x,y,sw,sh,dx,dy,w,h) {
  this.data=new Uint8ClampedArray(w*h*4);
  if(sw!==w||sh!==h||!Number.isInteger(x)||!Number.isInteger(y)){
   if(!image.rgba.every((v,i)=>v===image.rgba[i%4]))throw Error('nonuniform scaled/fractional Canvas: real WebKit oracle needed');
   for(let p=0;p<this.data.length;p++)this.data[p]=image.rgba[p%4];return;
  }
  for(let yy=0;yy<h;yy++)for(let xx=0;xx<w;xx++){
   const from=((y+yy)*image.naturalWidth+x+xx)*4,to=(yy*w+xx)*4;
   for(let c=0;c<4;c++)this.data[to+c]=image.rgba[from+c];
  }
 }
 getImageData(){return {data:this.data};}
}
const context=vm.createContext({console,performance:{now:()=>0},document:{createElement:()=>new Canvas()}});
vm.runInContext(source+'\n'+geometry+'\nglobalThis.makeSampler=aidokuSourceColorSampler;globalThis.makeReader=aidokuSourcePixelReader;',context);
const output=[];
for(const fixture of fixtures){
 const image={complete:true,naturalWidth:fixture.width,naturalHeight:fixture.height,rgba:Uint8ClampedArray.from(fixture.rgba),src:fixture.name};
 const budget={...fixture.budget},stages=new Map(),reader=context.makeReader(image),queries=[];
 for(const query of fixture.queries){
  const phase=query.phase||'ocr';
  if(!stages.has(phase))stages.set(phase,context.makeSampler(image,fixture.enabled!==false,phase,budget,reader));
  const stage=stages.get(phase),result=stage.sample(query.bounds,query.geometry||null);
  queries.push({result,stats:{pixels:stage.stats.pixels,hits:stage.stats.hits,samples:stage.stats.samples},budget:{pixels:budget.pixels,detailPixels:budget.detailPixels,remainingSamples:budget.remainingSamples??null}});
 }
 reader.release();output.push({name:fixture.name,queries});
}
process.stdout.write(JSON.stringify(output));
'''


def fixture(name, fill, background=(255, 255, 255), geometry=None, enabled=True, budget=None):
    width, height = 144, 64
    rgba = list(background + (255,)) * (width * height)
    def rect(x, y, w, h, color):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                offset = (yy * width + xx) * 4
                rgba[offset:offset + 4] = list(color) + [255]
    if fill:
        for x in (16, 56, 96):
            rect(x, 18, 4, 28, fill)
            rect(x + 16, 18, 4, 28, fill)
            rect(x, 30, 20, 4, fill)
    query = {"bounds": [10 / width, 18 / height, 110 / width, 28 / height]}
    if geometry is not None:
        query["geometry"] = geometry
    return {"name": name, "width": width, "height": height, "rgba": rgba, "enabled": enabled,
            "budget": budget or {"pixels": 393216, "detailPixels": 98304, "remainingSamples": 3},
            "queries": [query, query, {**query, "phase": "translation"}, {"bounds": [-0.1, 0, 0.2, 0.2]}]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "build/native-render-parity/sampling-policy.json")
    args = parser.parse_args()
    fixtures = [fixture("dark", (16, 16, 16)), fixture("blue", (25, 70, 180)),
                fixture("green", (25, 150, 70)), fixture("gray", (70, 70, 70)), fixture("blank", None, budget={"pixels": 393216, "detailPixels": 0, "remainingSamples": 3}),
                fixture("disabled", (16, 16, 16), enabled=False),
                fixture("budget-exhausted", (16, 16, 16), budget={"pixels": 0, "detailPixels": 0, "remainingSamples": 4}),
                fixture("owned-dark", (16, 16, 16), geometry={"polygon": [[0.05, 0.2], [0.9, 0.2], [0.9, 0.8], [0.05, 0.8]], "excluded": []}),
                fixture("excluded-dark", (16, 16, 16), geometry={"polygon": [[0.1, 0.2], [0.55, 0.2], [0.55, 0.8], [0.1, 0.8]],
                    "excluded": [[[0.55, 0.2], [0.95, 0.2], [0.95, 0.8], [0.55, 0.8]]]}),
                fixture("muted-backing", (30, 30, 30), background=(220, 210, 180))]
    native_reader = fixture("native-reader-cache", (16, 16, 16))
    native_reader["queries"] = [{"bounds": [x, 18 / 64, 0.7, 28 / 64]} for x in (0.05, 0.10, 0.15, 0.20)]
    fixtures.append(native_reader)
    for name, width, height, detail in [("blank-detail-budget", 384, 64, 98304), ("downsample-area-budget", 512, 128, 0)]:
        query = {"bounds": [0, 0, 1, 1]}
        fixtures.append({"name": name, "width": width, "height": height, "rgba": [255] * (width * height * 4),
            "budget": {"pixels": 393216, "detailPixels": detail, "remainingSamples": 3},
            "queries": [query, query, {**query, "phase": "translation"}]})
    fixtures.append({"name": "transparent", "width": 84, "height": 64, "rgba": [0] * (84 * 64 * 4),
        "budget": {"pixels": 393216, "detailPixels": 0, "remainingSamples": 3}, "queries": [
            {"bounds": [0, 0, 1, 1]}, {"bounds": [0, 0, 1, 1]}, {"bounds": [0, 0, 1, 1], "phase": "translation"}]})
    data = json.dumps(fixtures).encode()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    native_path = args.output.parent / "sampling-policy-native"
    sources = [SWIFT / name for name in ("NativeTranslationPixelKernels.swift", "NativeSourceColorSampler.swift",
        "NativeObservedSourcePalette.swift", "NativeCaptionSourcePalette.swift", "NativeSourceColorSamplingStage.swift")]
    snapshot = args.output.parent / "sampling-policy-source-snapshot"
    snapshot.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for index, source in enumerate(sources):
        data_bytes = source.read_bytes()
        copied = snapshot / source.name
        copied.write_bytes(data_bytes)
        hashes[source.name] = hashlib.sha256(data_bytes).hexdigest()
        sources[index] = copied
    library = ROOT / "build/native-overlay-kernels-host/libAidokuOverlayKernels.a"
    main_source = HERE / "SamplingStageParityMain.swift"
    compile_key = hashlib.sha256((json.dumps(hashes, sort_keys=True) + str(library.stat().st_mtime_ns) + main_source.read_text()).encode()).hexdigest()
    compile_marker = snapshot / "compiled-sha256.txt"
    if not native_path.exists() or not compile_marker.exists() or compile_marker.read_text() != compile_key:
        subprocess.run(["swiftc", "-O", "-I", str(ROOT / "Scripts/overlay-kernels/native"), *map(str, sources),
            str(main_source), str(library), "-o", str(native_path)], check=True)
        compile_marker.write_text(compile_key)
    native = json.loads(subprocess.run([str(native_path)], input=data, stdout=subprocess.PIPE, check=True).stdout)
    reference = json.loads(subprocess.run(["node", "-e", NODE, str(HERE / "reference-source/BrowserSourceTextColor.swift"),
        str(HERE / "reference-source/BrowserSourceGlyphSegmentation.swift")], input=data, stdout=subprocess.PIPE, check=True).stdout)
    cases = [{"name": n["name"], "exact": n == r, "native": n, "reference": r} for n, r in zip(native, reference)]
    report = {"scope": "native-size CGImage crop and uniform-color scaled/detail fixtures + frozen JS policy (not nonuniform scaled Canvas raster parity)",
              "total": len(cases), "exact": sum(c["exact"] for c in cases), "source_sha256": hashes, "cases": cases}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({"exact": report["exact"], "total": report["total"], "report": str(args.output)}))
    if report["exact"] != report["total"]:
        raise SystemExit(1)

if __name__ == "__main__":
    main()
