#!/usr/bin/env python3
"""Differential mixed probes against unchanged frozen inspectSurface cell/edge loop."""
from pathlib import Path
import hashlib,json,random,subprocess
root=Path(__file__).resolve().parents[2];reference=root/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift';out=root/'build/native-render-parity/exterior-surface-pool';out.mkdir(parents=True,exist_ok=True)
node=r'''
const fs=require('fs'),s=fs.readFileSync(process.argv[1],'utf8');
function fn(head){let a=s.indexOf(head),b=s.indexOf('{',a),d=0;for(let i=b;i<s.length;i++){if(s[i]==='{')d++;if(s[i]==='}'&&!--d)return s.slice(a,i+1)+';';}}
const poolFns=fn('const aidokuSurfacePool =')+fn('const aidokuSurfacePoolReady =');
const a=s.indexOf('const cellBox=([l,t,r,b])=>'),b=s.indexOf('return surfaceRange;',a)+'return surfaceRange;'.length,loop=s.slice(a,b);
const run=new Function('j',poolFns+`
const surfacePools=new WeakMap();let surfacePoolBudget=j.poolBudget,surfacePoolPixels=0,surfacePoolMilliseconds=0;
const c={safe:j.safe,luminance:j.luminance,w:j.width,h:j.height,x:40,y:40,sx:1,sy:1,iw:j.width+80,ih:j.height+80,frame:[0,0,j.width/j.ratio,j.height/j.ratio],surfaceQuality:{coefficients:[[255,0,0],[255,0,0],[255,0,0]]}};
const pool=aidokuSurfacePool(c),boxes=j.boxes,histogram=null,item={},abortUnsupportedGrowth=false;
const exterior={x:0,y:0,w:j.width+80,h:j.height+80,rgba:{subarray(i,end){const x=(i/4)%exterior.w;return j.reject&&x<40?[0,0,0]:j.exterior},get(){return 255}}};
exterior.rgba=new Proxy(exterior.rgba,{get(o,k){return k==='subarray'?o.subarray:Number.isInteger(Number(k))?255:o[k]}});
const aidokuSurfacePlaneRGB=()=>[255,255,255],aidokuSourceColorLuminance=rgb=>{const a=rgb.map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4});return .2126*a[0]+.7152*a[1]+.0722*a[2]};
let restoredPanelLookupBudget=j.lookup,minimum=Infinity,maximum=-Infinity,surfaceKey=null,surfaceRange=null;
const range=(()=>{`+loop+`})();return {range,lookup:restoredPanelLookupBudget,poolBudget:surfacePoolBudget,pixels:surfacePoolPixels,tiles:Array.from(pool.tiles)};`);
process.stdout.write(JSON.stringify(JSON.parse(fs.readFileSync(0,'utf8')).map(run)));
'''
r=random.Random(4030);cases=[]
for i in range(80):
 w=48+i%4*8;h=96;safe=[1]*(w*h);lum=[240+(x+y)%11 for y in range(h) for x in range(w)]
 if i%7==0:safe[22*w+20]=0
 cases.append(dict(width=w,height=h,ratio=3 if i%2 else 5,safe=safe,luminance=lum,poolBudget=[1048576,128,4096][i%3],lookup=[400,1000,65536][i%3],boxes=[[-4,20,w+4,40],[2,40,w-2,60]] if i%2 else [[-4,20,w+4,60]],exterior=[245+i%11]*3,reject=i%9==0))
source=root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSurfacePool.swift';main=root/'Scripts/native-render-parity/ExteriorSurfacePoolMain.swift'
subprocess.run(['xcrun','swiftc','-O',str(source),str(main),'-o',str(out/'differential')],check=True)
blob=json.dumps(cases).encode();expected=json.loads(subprocess.check_output(['node','-e',node,str(reference)],input=blob));actual=json.loads(subprocess.check_output([str(out/'differential')],input=blob));fail=[dict(index=i,expected=a,actual=b) for i,(a,b) in enumerate(zip(expected,actual)) if a!=b]
report=dict(cases=len(cases),accepted=sum(v['range'] is not None for v in expected),exact=not fail,failures=fail,scope='Unchanged frozen mixed interior/exterior pooled lookup loop, exact range/page-pool/lookup costs and unsafe rejection',frozenSHA256=hashlib.sha256(reference.read_bytes()).hexdigest(),sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest())
(out/'differential.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k != "failures"},indent=2));print("mismatch count:",len(fail));raise SystemExit(bool(fail))
