#!/usr/bin/env python3
"""Frozen source-position safety masks; exact decision parity including refusals."""
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];REF=Path(__file__).parent/'reference-source'
NODE=r'''
const fs=require('fs');
function extract(file,head){const s=fs.readFileSync(process.argv[1]+'/'+file+'.swift','utf8'),start=s.indexOf(head);let b=s.indexOf('{',start),depth=0;for(let i=b;i<s.length;i++){if(s[i]==='{')depth++;if(s[i]==='}'&&!--depth)return s.slice(start,i+1)+(head.startsWith('const')?';':'');}}
const functions=extract('BrowserSourcePanelRestoration','function aidokuOutlineSourceResolved(')+extract('BrowserOverlayTypography','const aidokuHasAttachedLeadingInk =')+extract('BrowserOverlayView','const aidokuHasLargePartialResidual =');
const run=new Function('j',functions+`return {resolved:aidokuOutlineSourceResolved({w:j.width,h:j.height,safe:j.safe,sourceErasureVerified:j.erasure,sourceGlyphsVerified:j.glyphs,iw:j.ratio,frame:[0,0,1,1],sx:1},j.core),attached:aidokuHasAttachedLeadingInk(j.safe,j.width,j.height,j.core,j.glyph),residual:aidokuHasLargePartialResidual(j.safe,j.width,j.height,j.core,j.glyph,j.vertical)};`);
process.stdout.write(JSON.stringify(JSON.parse(fs.readFileSync(0,'utf8')).map(run)));
'''
jobs=[]
for i in range(64):
    w=h=80;safe=[1]*(w*h)
    def rect(x,y,width,height):
        for yy in range(max(0,y),min(h,y+height)):
            for xx in range(max(0,x),min(w,x+width)):safe[yy*w+xx]=0
    if i%8==0:rect(40,15,6,7);rect(40,29,6,8)
    if i%8==1:rect(31,15,6,6);rect(42,15,6,6)
    if i%8==2:rect(42,0,2,80);rect(44,20,5,6);rect(44,36,5,6)
    if i%8==3:rect(40,0,15,80);rect(35,20,5,6);rect(35,36,5,6)
    if i%8==4:rect(0,0,80,2)
    if i%8==5:rect(5,5,3,4)
    if i%8==6:rect(35,20,5,30)
    if i%8==7:rect(25,0,2,80);rect(40,20,6,8);rect(40,36,6,8)
    jobs.append(dict(width=w,height=h,safe=safe,core=[[20,12,15,50]],glyph=12,ratio=1+i%3,erasure=i%5==0,glyphs=i%7!=0,vertical=i%2==0))
blob=json.dumps(jobs).encode();web=json.loads(subprocess.check_output(['node','-e',NODE,str(REF)],input=blob));native=json.loads(subprocess.check_output([str(ROOT/'build/native-partial-source-host/check')],input=blob));failures=[dict(index=i,web=a,native=b) for i,(a,b) in enumerate(zip(web,native)) if a!=b]
report=dict(cases=len(jobs),passed=not failures,positiveCounts={key:sum(v[key] for v in native) for key in ['resolved','attached','residual']},failures=failures)
(ROOT/'build/native-partial-source-host/differential.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));raise SystemExit(bool(failures))
