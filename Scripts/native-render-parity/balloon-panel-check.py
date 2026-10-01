#!/usr/bin/env python3
"""Frozen DOM contour/backing flow with independent deterministic glyph probes."""
import json
import subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent
OUT = ROOT/'build/native-render-parity/balloon-panel'
OUT.mkdir(parents=True, exist_ok=True)
NODE = r'''
const fs=require('fs'),s=fs.readFileSync(process.argv[1],'utf8');
const a=s.indexOf('    const aidokuSolidPanelCoverage ='),z=a+s.slice(a).indexOf('\n    };')+7;
const start=s.indexOf('    const aidokuContainBalloonPanels ='),end=s.indexOf('    const aidokuContainBalloonText =',start);
const rect=r=>({left:r[0],top:r[1],width:r[2],height:r[3],right:r[0]+r[2],bottom:r[1]+r[3]});
const array=r=>[r.left,r.top,r.width,r.height];
const style=n=>({...n.style,transform:'none',visibility:'visible',display:'block',fontSize:n.style.fontSize,lineHeight:n.style.lineHeight,webkitTextStrokeWidth:n.stroke+'px'});
const document={createTextNode:text=>text,createRange:()=>({selectNodeContents(n){this.n=n},getClientRects(){return this.n.glyphs()},getBoundingClientRect(){const p=this.n.glyphs();return rect([Math.min(...p.map(r=>r.left)),Math.min(...p.map(r=>r.top)),Math.max(...p.map(r=>r.right))-Math.min(...p.map(r=>r.left)),Math.max(...p.map(r=>r.bottom))-Math.min(...p.map(r=>r.top))]);}})};
const run=new Function('root','items','document','getComputedStyle',s.slice(a,z)+s.slice(start,end)+'return aidokuContainBalloonPanels(root,items);');
const jobs=JSON.parse(fs.readFileSync(0,'utf8'));
const outputs=jobs.map(job=>{
const nodes=[],panels=[],items=[],root={querySelectorAll(q){return q.includes('source-readability-panel')?panels:nodes}};
function node(r,id){const n={dataset:{aidokuRegion:id},style:{left:r[0]+'px',top:r[1]+'px',width:r[2]+'px',height:r[3]+'px'},getBoundingClientRect(){return rect([parseFloat(this.style.left),parseFloat(this.style.top),parseFloat(this.style.width),parseFloat(this.style.height)])}};
Object.defineProperty(n.style,'cssText',{get(){return JSON.stringify(this)},set(v){Object.assign(this,JSON.parse(v))},enumerable:false});return n;}
for(const e of job.entries){
 const n=node(e.ink,e.id),p=node(e.panel,e.id);n.parentElement=root;n.stroke=e.stroke;n.style.fontSize=e.font+'px';n.style.lineHeight=e.font+'px';n.childNodes=['original'];n.innerText='X'.repeat(e.characters);n.replaceChildren=(...c)=>{n.childNodes=c;n.changed=c[0]!=='original'};
 n.glyphs=()=>{if(!n.changed)return [rect(e.ink)];const f=parseFloat(n.style.fontSize),r=n.getBoundingClientRect(),wrap=Math.max(1,Math.floor((r.width-2)/(f*.5))),out=[];for(let pos=0,line=0;pos<e.characters;pos+=wrap,line++)out.push(rect([r.left+1,r.top+1+line*f,Math.min(wrap,e.characters-pos)*f*.5,f]));return out};
 Object.defineProperties(n,{clientWidth:{get(){return this.getBoundingClientRect().width}},clientHeight:{get(){return this.getBoundingClientRect().height}},scrollWidth:{get(){return this.clientWidth}},scrollHeight:{get(){return n.changed?n.glyphs().length*parseFloat(n.style.fontSize)+2:this.clientHeight}}});
 p.style.backgroundColor='rgb(255,255,255)';p.dataset.panelCoverage=JSON.stringify([e.panel]);nodes.push(n);panels.push(p);
 const f=e.frame,b=e.source;items.push({id:e.id,text:n.innerText,sourceFrame:f,sourceBounds:[(b[0]-f[0])/f[2],(b[1]-f[1])/f[3],b[2]/f[2],b[3]/f[3]],balloonInterior:e.spans?{rect:e.balloonRect,spans:e.spans,contourVerified:true}:null});
}
run(root,items,document,style);
return panels.map((p,i)=>{const o={id:p.dataset.aidokuRegion,panel:array(p.getBoundingClientRect()),coverage:JSON.parse(p.dataset.panelCoverage)};const result=p.dataset.finalBalloonPanelFit||p.dataset.finalBalloonPanelRejected;if(result)o.result=result;if(result==='reflowed-rectangle')o.font=parseFloat(nodes[i].style.fontSize);return o;});
});process.stdout.write(JSON.stringify(outputs));
'''
jobs=[]
for i in range(64):
    entry=dict(id='a',frame=[0,0,128,128],balloonRect=[.1,.1,.8,.8],spans=[.2,.8]*16,
               source=[35,35,24,12],ink=[20,30,96,15] if i%3 else [36,36,24,12],panel=[8,8,110,60],font=16,stroke=i%4,characters=3+i%30)
    if i%11==0: entry['source']=[10,35,24,12]
    if i%13==0: entry['spans']=[.4,.6]*16
    entries=[entry]
    if i%7==0: entries.append(dict(id='b',frame=[0,0,128,128],source=[80,34,10,16],ink=[80,34,10,16],panel=[78,32,14,20],font=16,stroke=0,characters=1))
    jobs.append(dict(entries=entries))
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeCSSCoveragePath.swift'),str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSourceStylePostPolish.swift'),str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativePanelGeometry.swift'),str(HERE/'BalloonPanelMain.swift'),'-o',str(OUT/'check')],check=True)
blob=json.dumps(jobs).encode()
web=json.loads(subprocess.check_output(['node','-e',NODE,str(HERE/'reference-source/BrowserOverlayTypography.swift')],input=blob))
native=json.loads(subprocess.check_output([str(OUT/'check')],input=blob))
failed=[dict(index=i,fixture=jobs[i],web=a,native=b) for i,(a,b) in enumerate(zip(web,native)) if a!=b]
results={key:sum(r.get('result')==key for case in native for r in case) for key in ['rectangular','reflowed-rectangle','source-or-ink-outside','no-safe-rectangle']}
report=dict(cases=len(jobs),exact=not failed,failed=len(failed),results=results,failures=failed)
(OUT/'differential.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='failures'}));raise SystemExit(bool(failed))
