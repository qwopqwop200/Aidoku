#!/usr/bin/env python3
"""Frozen giant-title orchestration + actual gloss search, with identical fixed text metrics/RGBA."""
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];REF=Path(__file__).parent/'reference-source'
NODE=r'''
const fs=require('fs'),view=fs.readFileSync(process.argv[1]+'/BrowserOverlayView.swift','utf8'),type=fs.readFileSync(process.argv[1]+'/BrowserOverlayTypography.swift','utf8'),colour=fs.readFileSync(process.argv[1]+'/BrowserSourceTextColor.swift','utf8');
const begin=view.indexOf('    // Oversized failed source restoration'),end=view.indexOf('    // Commit each opaque caption',begin);
const gloss=type.slice(type.indexOf('    const aidokuGlossPlacer ='),type.indexOf('    // Turns a placed gloss node'));
const colours=colour.slice(colour.indexOf('    const aidokuSourceColorLuminance ='),colour.indexOf('    // Keep an already readable color'));
const scrollX=0,scrollY=0,performance={now:()=>0};
function rect(v){return{left:v[0],top:v[1],right:v[0]+v[2],bottom:v[1]+v[3],width:v[2],height:v[3]};}
function measure(node){const size=parseFloat(node.style.fontSize),width=parseFloat(node.style.width),lh=parseFloat(node.style.lineHeight),natural=node.textContent.length*size*.53,lines=Math.max(1,Math.ceil(natural/width)),tw=Math.min(width,natural);return rect([parseFloat(node.style.left)+(width-tw)/2,parseFloat(node.style.top)+size*.08,tw,lines*lh*.82]);}
const document={createElement:()=>{const c={};c.getContext=()=>({drawImage(){},getImageData:()=>({data:new Uint8ClampedArray(Array.from({length:c.width*c.height},()=>[240,240,235,255]).flat())})});return c;},createRange:()=>({selectNodeContents(n){this.n=n},getBoundingClientRect(){return measure(this.n)}})};
const run=new Function('root','items','cleanupImageGeometry','restoredPanelGeometry','keptItems','sourceImage','document','scrollX','scrollY','performance',colours+gloss+view.slice(begin,end).replaceAll(String.fromCharCode(92,92),String.fromCharCode(92)));
const jobs=JSON.parse(fs.readFileSync(0,'utf8'));
const result=jobs.map(job=>{
 const nodes=[],panels=[],items=[],restored=new Map();
 const root={querySelectorAll(selector){if(selector.includes('source-panel-restoration'))return[];return(selector.includes('source-readability')||selector.includes('source-rotated-panel')?panels:nodes).filter(n=>!n.removed)}};
 for(const r of job.records){const n={textContent:r.text,dataset:{aidokuRegion:r.id,sourceBackgroundColor:'readability-panel',sourceSampledTextRGB:'30,30,30',sourceSampledBackgroundRGB:'240,240,235'},style:{left:r.origin[0]+'px',top:r.origin[1]+'px',width:r.width+'px',height:'40px',fontSize:r.font+'px',lineHeight:(r.font*1.2)+'px'},getBoundingClientRect(){return measure(this)}};nodes.push(n);
 const item={id:r.id,sourceBounds:r.source,sourceFrame:job.frame,sourceFontSize:r.sourceFont,rotation:r.rotation||0};items.push(item);if(r.restored)restored.set(item,{});
 for(const box of r.panels){const p={dataset:{aidokuRegion:r.id,aidokuImageOcrOverlay:'source-readability-panel'},style:{left:box[0]+'px',top:box[1]+'px',width:box[2]+'px',height:box[3]+'px'},querySelectorAll(){return[]},getBoundingClientRect(){return rect([parseFloat(this.style.left),parseFloat(this.style.top),parseFloat(this.style.width),parseFloat(this.style.height)])},remove(){this.removed=true}};panels.push(p);}}
 run(root,items,{frame:job.frame},restored,[],{complete:true,naturalWidth:640,naturalHeight:1024},document,0,0,performance);
 return nodes.map(n=>({id:n.dataset.aidokuRegion,ink:(()=>{const r=measure(n);return[r.left,r.top,r.width,r.height]})(),font:parseFloat(n.style.fontSize),panels:panels.filter(p=>!p.removed&&p.dataset.aidokuRegion===n.dataset.aidokuRegion).map(p=>{const q=p.getBoundingClientRect();return[q.left,q.top,q.width,q.height]}),preserved:!!n.dataset.sourceErasurePreserved,gloss:!!n.dataset.sourcePreservedGloss}));
});process.stdout.write(JSON.stringify(result));
'''
jobs=[]
for i in range(40):
    frame=[0,0,320,512]
    records=[dict(id='a',text=['거대한 제목','샘플 무단 금지','쾅쾅','위대한 모험의 시작'][i%4],source=[.15,.25,.7,.5],origin=[115,235],font=8+i%3,width=80,sourceFont=100,panels=[[40,120,250,270]],restored=i%13==0)]
    if i%3==0:records.append(dict(id='b',text='작은 제목',source=[.2,.18,.6,.05],origin=[115,95],font=10,width=80,sourceFont=50,panels=[[55,80,210,38]]))
    if i%5==0:records.append(dict(id='c',text='이웃 대사',source=[.75,.48,.1,.1],origin=[115,235],font=10,width=65,sourceFont=12,panels=[[245,240,40,40]]))
    jobs.append(dict(frame=frame,records=records))
blob=json.dumps(jobs).encode();web=json.loads(subprocess.check_output(['node','-e',NODE,str(REF)],input=blob));native=json.loads(subprocess.check_output([str(ROOT/'build/native-oversized-title-host/check')],input=blob))
def same(a,b):
    if isinstance(a,dict):return set(a)==set(b) and all(same(a[k],b[k]) for k in a)
    if isinstance(a,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
    if isinstance(a,(int,float)) and not isinstance(a,bool):return isinstance(b,(int,float)) and abs(a-b)<1e-9
    return a==b
failures=[dict(index=i,web=a,native=b) for i,(a,b) in enumerate(zip(web,native)) if not same(a,b)]
report=dict(cases=len(jobs),failed=len(failures),passed=not failures,glossNotes=sum(e['gloss'] for out in native for e in out),clippedCaptions=sum(e['preserved'] for out in native for e in out),coordinateTolerance=1e-9,failures=failures)
(ROOT/'build/native-oversized-title-host/differential.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='failures'}));raise SystemExit(bool(failures))
