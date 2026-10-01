#!/usr/bin/env python3
"""Frozen final caption panel policy with a deterministic DOM geometry adapter."""
import json,random,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];REF=Path(__file__).parent/'reference-source/BrowserOverlayTypography.swift'
NODE=r'''
const fs=require('fs'),source=fs.readFileSync(process.argv[1],'utf8');
const begin=source.indexOf('    const aidokuPolishCaptionPanels ='),end=source.indexOf('    // Opaque caption packing',begin);
const scrollX=0,scrollY=0;
const getComputedStyle=n=>({...n.style,visibility:'visible',transform:'none',scale:'none',rotate:'none',translate:'none',opacity:'1',backgroundImage:'none',clipPath:n.style.clipPath||'none',fontSize:n.style.fontSize||'16px',webkitTextStrokeWidth:'0px',webkitTextStrokeColor:'rgb(0,0,0)',color:'rgb(0,0,0)'});
const document={createRange:()=>({selectNodeContents(n){this.node=n},getBoundingClientRect(){return this.node.getBoundingClientRect()}})};
function rect(v){return {left:v[0],top:v[1],right:v[0]+v[2],bottom:v[1]+v[3],width:v[2],height:v[3]};}
function node(v,type,id){
 const n={dataset:{aidokuRegion:id,aidokuImageOcrOverlay:type},style:{left:v[0]+'px',top:v[1]+'px',width:v[2]+'px',height:v[3]+'px',clipPath:'none'},remove(){this.removed=true},getBoundingClientRect(){return rect([parseFloat(this.style.left),parseFloat(this.style.top),parseFloat(this.style.width),parseFloat(this.style.height)])}};return n;
}
const run=new Function('root','items','opacity','kept','document','getComputedStyle','scrollX','scrollY',source.slice(begin,end)+'return aidokuPolishCaptionPanels(root,items,opacity,[],null,kept);');
const jobs=JSON.parse(fs.readFileSync(0,'utf8'));
const result=jobs.map(job=>{
const nodes=[],panels=[],items=[];
const root={querySelectorAll(selector){if(selector.includes('source-readability-backing'))return [];return (selector.includes('source-readability-panel')?panels:nodes).filter(n=>!n.removed)},appendChild(n){n.parentElement=this;}};
for(const e of job.entries){
 const n=node(e.ink,'item',e.id);n.parentElement=root;n.style.fontSize=e.font+'px';nodes.push(n);
 for(const p of e.panels){const q=node(p.rect,'source-readability-panel',e.id);q.parentElement=root;q.style.backgroundColor=`rgba(${p.background.join(',')},1)`;q.dataset.panelCoverage=JSON.stringify(p.coverage);q.dataset.sourceErasure=String(!!p.sourceErasure);if(p.clipped){q.style.clipPath='polygon(0 0)';q.dataset.captionUnionClipped='true';}panels.push(q);}
 const f=e.frame,local=b=>[(b[0]-f[0])/f[2],(b[1]-f[1])/f[3],b[2]/f[2],b[3]/f[3]];
 const column=e.column?{x:e.column[0],y:e.column[1],width:e.column[2],height:e.column[3]}:null;
 items.push({id:e.id,sourceFrame:f,sourceBounds:local(e.sources[0]),auxiliaryInkRects:e.sources.slice(1).map(local),sourceTextOnly:false,rotation:0,vertical:false,wrappingScript:'korean',balancedColumn:!!e.balanced,columnLayout:column});
}
run(root,items,job.opacity??1,job.kept.map(rect),document,getComputedStyle,0,0);
return nodes.map(n=>({id:n.dataset.aidokuRegion,ink:[parseFloat(n.style.left),parseFloat(n.style.top),parseFloat(n.style.width),parseFloat(n.style.height)],panels:panels.filter(p=>!p.removed&&p.dataset.aidokuRegion===n.dataset.aidokuRegion).map(p=>({rect:[parseFloat(p.style.left),parseFloat(p.style.top),parseFloat(p.style.width),parseFloat(p.style.height)],coverage:JSON.parse(p.dataset.panelCoverage)}))}));
});process.stdout.write(JSON.stringify(result));
'''
rng=random.Random(1984);jobs=[]
for i in range(80):
    entries=[]
    count=2+i%4
    for k in range(count):
        x=10+k*(24+i%11);y=20+(k%2 if i%5==0 else 0)
        ink=[x, y, 15+rng.randrange(12),15];source=[x+2,y+2,14,12]
        panels=[dict(rect=[x-3,y-3,ink[2]+9,24],background=[240,240,235],coverage=[[x-3,y-3,ink[2]+9,24]])]
        if i%7==0:
            panels=[dict(rect=[x-3,y-3,18,24],background=[240,240,235],coverage=[[x-3,y-3,18,24]]),dict(rect=[x+13,y-3,ink[2]-7,24],background=[240,240,235],coverage=[[x+13,y-3,ink[2]-7,24]])]
        entries.append(dict(id=str(k),font=16,frame=[0,0,256,128],ink=ink,sources=[source],panels=panels,balanced=i%13==0,column=[x-4,y-1,40,35]))
    jobs.append(dict(entries=entries,kept=[[10,38,8,8]] if i%9==0 else [],opacity=.5 if i==79 else 1))
blob=json.dumps(jobs).encode();web=json.loads(subprocess.check_output(['node','-e',NODE,str(REF)],input=blob));native=json.loads(subprocess.check_output([str(ROOT/'build/native-caption-panel-host/check')],input=blob))
failures=[]
for i,(a,b) in enumerate(zip(web,native)):
    if a!=b:failures.append(dict(index=i,web=a,native=b))
changed=sum(a!=j['entries'][k]['ink'] for j,out in zip(jobs,native) for k,a in enumerate(e['ink'] for e in out)); merged=sum(len(e['panels'])<len(j['entries'][k]['panels']) for j,out in zip(jobs,native) for k,e in enumerate(out));report=dict(cases=len(jobs),failed=len(failures),exact=not failures,translatedInkCases=changed,mergedPanelCases=merged,failures=failures)
(ROOT/'build/native-caption-panel-host/differential.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='failures'}));raise SystemExit(bool(failures))
