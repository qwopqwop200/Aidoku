#!/usr/bin/env python3
"""Exact RGBA/mask/admission proof for native component restoration vs frozen WASM+JS."""
import importlib.util,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];REF=Path(__file__).parent/'reference-source'
spec=importlib.util.spec_from_file_location('f',ROOT/'Scripts/tests/native-source-glyph-segmentation-parity.py');f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1];
const script=name=>fs.readFileSync(base+'/'+name+'.swift','utf8').split('static let script = """')[1].split('"""')[0];
let segmentation=script('BrowserSourceGlyphSegmentation').replace('n>262144','n>750000').replace('const maxDimension=Math.min(78,Math.max(48,Math.min(b[2],b[3])*.48));','const maxDimension=Number(options.glyphSize)>0?Math.min(180,Math.max(48,Number(options.glyphSize)*1.6)):dark&&!(background&&background.length>=3&&Math.min(...background)>=230)?56:Math.min(78,Math.max(48,Math.min(b[2],b[3])*.48));').replace('area>Math.max(1800,b[2]*b[3]*.08)','area>(Number(options.glyphSize)>0?Math.max(3200,Number(options.glyphSize)**2*1.3):(dark?Math.max(3200,b[2]*b[3]*.14):Math.max(1800,b[2]*b[3]*.08)))');
const scope=vm.createContext({});vm.runInContext(script('BrowserSourceTextColor')+segmentation+script('BrowserSourcePanelRestoration')+script('BrowserForcedInpaintQuality')+script('BrowserForcedComponentInpainting')+`\nglobalThis.run=j=>{
const result=aidokuForceInpaintSourceComponent(Uint8ClampedArray.from(j.rgba),j.width,j.height,j.box,{foreground:j.foreground,background:j.background,stroke:j.stroke,confidence:{foreground:.9,background:.9,stroke:j.stroke?.length?.9:0}},{glyphSize:j.glyphSize,vertical:false});
if(!result)return {missing:true};return {rgba:Array.from(result.rgba),layoutSafe:Array.from(result.layoutSafe),sourceGlyphsVerified:result.sourceGlyphsVerified,sourceErasureVerified:result.sourceErasureVerified};};`,scope);
process.stdout.write(JSON.stringify(scope.run(JSON.parse(fs.readFileSync(0,'utf8')))));
'''
results=[]
for job in f.fixtures()[:5]:
    blob=json.dumps(job).encode()
    web=json.loads(subprocess.check_output(['node','-e',NODE,str(REF)],input=blob))
    native=json.loads(subprocess.check_output([str(ROOT/'build/native-residual-proof-host/component-check')],input=blob))
    fields=[key for key in set(web)|set(native) if web.get(key)!=native.get(key)]
    results.append(dict(name=job['name'],exact=not fields,fields=fields,accepted='rgba'in web,differentBytes=sum(a!=b for a,b in zip(web.get('rgba',[]),native.get('rgba',[])))))
positive=any(r['accepted'] for r in results);report=dict(cases=len(results),positive=positive,passed=positive and all(r['exact'] for r in results),results=results)
(ROOT/'build/native-residual-proof-host/component-differential.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));raise SystemExit(not report['passed'])
