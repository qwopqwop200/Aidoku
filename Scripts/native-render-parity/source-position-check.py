#!/usr/bin/env python3
"""Actual frozen final source-position block with independently provided proof inputs.
Lower pixel proof calculations have their own exact64case comparison. This harness
checks admission, observed-stroke choice, collisions and final width at that seam.
"""
import json,subprocess,random
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];REF=Path(__file__).parent/'reference-source'
NODE=r'''
const fs=require('fs'),s=fs.readFileSync(process.argv[1]+'/BrowserOverlayView.swift','utf8');
const a=s.indexOf('(()=>{for(const item of items){',s.indexOf('// A high-contrast glyph outline'));
const b=s.indexOf('})();',a)+5,body=s.slice(a,b);
const color=fs.readFileSync(process.argv[1]+'/BrowserSourceTextColor.swift','utf8'),start=color.indexOf('const aidokuSourceColorLuminance ='),end=color.indexOf('const aidokuLuminanceContrast',start),lum=color.slice(start,end);
const setup=`const source=b=>({left:b[0],top:b[1],right:b[0]+b[2],bottom:b[1]+b[3],width:b[2],height:b[3]});
const node={style:{fontSize:String(j.font)},dataset:{sourceAppliedTextRGB:j.foreground.join(','),sourceSampledStrokeRGB:j.stroke?.join(',')},scrollHeight:j.fits?10:12,clientHeight:10,scrollWidth:10,clientWidth:10};
const item={id:'main',sourceBounds:j.source,sourceFrame:[0,0,1,1],sourceTextOnly:false,sourceVertical:j.vertical,sourceSingleColumn:j.single};
const items=[item,...j.owners.map((q,i)=>({id:'owner'+i,sourceBounds:q.sources[0],auxiliaryInkRects:q.sources.slice(1),sourceFrame:[0,0,1,1]}))];
const c={erasureComplete:j.erasure,iw:1,ih:1,x:0,y:0,sx:1,sy:1,w:1,h:1,safe:[1]},restoredPanelGeometry=new Map([[item,c]]);
items.slice(1).forEach((it,i)=>{const q=j.owners[i];restoredPanelGeometry.set(it,{sourceErasureVerified:q.verified,provisional:q.provisional,partialErasureCertified:q.partial,canvas:{isConnected:q.connected}})});
const nodes=new Map([['main',node],...j.neighbors.map((q,i)=>['neighbor'+i,{rect:source(q)}])]);
const plate={getBoundingClientRect:()=>source(j.plate),remove:()=>{}};const plates=new Map([['main',plate]]);
const document={createRange:()=>({selectNodeContents(n){this.n=n},getBoundingClientRect(){return this.n===node?source(j.ink):this.n.rect}})};
const root={querySelectorAll:()=>[]},cleanupImageGeometry=null,inks=new Map(),rect=r=>r;
let readabilityPanels=1;const aidokuOutlineSourceResolved=()=>j.resolved,aidokuHasAttachedLeadingInk=()=>j.attached,aidokuHasLargePartialResidual=()=>j.residual;`;
const run=new Function('j',lum+setup+body+`;return node.dataset.partialMainbodyProof?{foreground:j.foreground,stroke:node.dataset.sourceAppliedStrokeRGB.split(',').map(Number),width:parseFloat(node.style.webkitTextStrokeWidth),minimumContrast:Number(node.dataset.sourceOutlineContrast)}:null;`);
process.stdout.write(JSON.stringify(JSON.parse(fs.readFileSync(0,'utf8')).map(run)));
'''
rng=random.Random(7137);jobs=[]
for i in range(120):
    j=dict(operation='position',source=[20,15,30,40],ink=[24,27,22,16],plate=[15,10,40,50],font=[6,7,12,20][i%4],foreground=[[12,16,23],[240,245,250],[120,120,120]][i%3],stroke=[255,255,255] if i%5==0 else None,neighbors=[],owners=[],vertical=i%2==0,single=i%3==0,fits=True,erasure=True,resolved=True,attached=False,residual=False)
    mode=i%10
    if mode==0:j['ink'][0]+=25
    if mode==1:j['neighbors']=[[22,25,10,10]]
    if mode==2:j['owners']=[dict(sources=[[15,10,5,5]],verified=True,provisional=False,partial=True,connected=True)]
    if mode==3:j['owners']=[dict(sources=[[15,10,5,5]],verified=True,provisional=False,partial=False,connected=True)]
    if mode==4:j['attached']=True
    if mode==5:j['fits']=False
    if mode==6:j['erasure']=False
    if mode==7:j['resolved']=False
    if mode==8:j['residual']=True
    jobs.append(j)
blob=json.dumps(jobs).encode();web=json.loads(subprocess.check_output(['node','-e',NODE,str(REF)],input=blob));native=json.loads(subprocess.check_output([str(ROOT/'build/native-partial-source-host/check')],input=blob));fail=[]
for i,(a,b) in enumerate(zip(web,native)):
    if a is not None and b is not None and abs(a['minimumContrast']-b['minimumContrast'])<1e-12:b['minimumContrast']=a['minimumContrast']
    if a!=b:fail.append(dict(index=i,web=a,native=b))
report=dict(cases=len(jobs),passed=not fail,positive=sum(a is not None for a in native),failures=fail,contrastStatisticTolerance=1e-12)
(ROOT/'build/native-partial-source-host/source-position-differential.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));raise SystemExit(bool(fail))
