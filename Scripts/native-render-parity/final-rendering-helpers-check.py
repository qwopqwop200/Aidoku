#!/usr/bin/env python3
"""Exact frozen lazy pool bytes/budgets and transformedplate/gloss decisions."""
import json,math,random,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];REF=Path(__file__).parent/'reference-source'
NODE=r'''
const fs=require('fs');
function extract(file,head){const s=fs.readFileSync(process.argv[1]+'/'+file+'.swift','utf8'),start=s.indexOf(head);let b=s.indexOf('{',start),depth=0;for(let i=b;i<s.length;i++){if(s[i]==='{')depth++;if(s[i]==='}'&&!--depth)return s.slice(start,i+1)+';';}}
const poolFns=extract('BrowserOverlayView','const aidokuSurfacePool =')+extract('BrowserOverlayView','const aidokuSurfacePoolReady =');
const plate=extract('BrowserOverlayView','const aidokuPlateMeets=');
const turn=extract('BrowserOverlayTypography','const aidokuTurnGloss =');
const s=fs.readFileSync(process.argv[1]+'/BrowserOverlayView.swift','utf8'),start=s.indexOf('const cellBox=([l,t,r,b])=>'),end=s.indexOf('return surfaceRange;',start)+'return surfaceRange;'.length,range=s.slice(start,end);
const run=new Function('j',poolFns+plate+turn+`
if(j.operation==='plate'){const b=j.bounds,owner={offsetWidth:j.width,offsetHeight:j.height,getBoundingClientRect:()=>({left:b[0],top:b[1],right:b[0]+b[2],bottom:b[1]+b[3],width:b[2],height:b[3]})};globalThis.getComputedStyle=()=>({transform:j.matrix?'matrix('+j.matrix.join(',')+')':''});return aidokuPlateMeets(owner,j.ink);}
if(j.operation==='turn'){globalThis.scrollX=globalThis.scrollY=0;const node={style:{left:String(j.origin[0]),top:String(j.origin[1])}};aidokuTurnGloss(node,{angle:j.angle,center:j.center});return node.style.transform?{angle:j.angle,origin:node.style.transformOrigin.split(' ').map(parseFloat)}:null;}
const surfacePools=new WeakMap();let surfacePoolBudget=j.budget,surfacePoolPixels=0,surfacePoolMilliseconds=0;
const c={safe:j.safe,luminance:j.luminance,w:j.width,h:j.height,x:j.at[0],y:j.at[1],sx:j.at[2],sy:j.at[3],iw:j.at[4],ih:j.at[5],frame:[0,0,...j.frame]};
const pool=aidokuSurfacePool(c);if(!pool)return null;
if(j.operation==='range'){const boxes=j.boxes,histogram=null,exterior=null;let restoredPanelLookupBudget=j.lookup,minimum=Infinity,maximum=-Infinity,surfaceKey=null,surfaceRange=null;const value=(()=>{`+range+`})();return {range:value,lookup:restoredPanelLookupBudget,budget:surfacePoolBudget,pixels:surfacePoolPixels,tiles:Array.from(pool.tiles),low:pool.low&&Array.from(pool.low),high:pool.high&&Array.from(pool.high)};}
const actions=j.steps.map(step=>{const ready=aidokuSurfacePoolReady(pool,...step.box,step.build);return {ready,budget:surfacePoolBudget,pixels:surfacePoolPixels,tiles:Array.from(pool.tiles),low:pool.low&&Array.from(pool.low),high:pool.high&&Array.from(pool.high)}});
return {k:pool.k,cw:pool.cw,ch:pool.ch,tw:pool.tw,th:pool.th,actions,cached:aidokuSurfacePool(c)===pool};`);
process.stdout.write(JSON.stringify(JSON.parse(fs.readFileSync(0,'utf8')).map(run)));
'''
rng=random.Random(13082);jobs=[]
for i in range(80):
    w,h=75+i%7,50+i%9;ratio=[1,2.5,5,10,20,24][i%6];k=math.floor(ratio/1.25)
    safe=[1]*(w*h);lum=[(x*3+y*7)%256 for y in range(h) for x in range(w)]
    if i%3==0:safe[(h//2)*w+w//2]=0
    cw=w//max(1,k);ch=h//max(1,k)
    steps=[dict(box=[0,0,min(cw,4),min(ch,4)],build=False),dict(box=[0,0,min(cw,4),min(ch,4)],build=True),dict(box=[0,0,cw,ch],build=True),dict(box=[0,0,min(cw,4),min(ch,4)],build=False)] if 2<=k<=16 else []
    jobs.append(dict(operation='pool',safe=safe,luminance=lum,width=w,height=h,frame=[w/ratio,h/ratio],at=[-2 if i%4==0 else 0,0,1,1,w,h],budget=[128,4096,1048576][i%3],steps=steps))
for i in range(120):
    angle=(i%20-10)*.08;c,s=math.cos(angle),math.sin(angle);w,h=80,30;bw=abs(c)*w+abs(s)*h;bh=abs(s)*w+abs(c)*h
    jobs.append(dict(operation='plate',bounds=[100-bw/2,80-bh/2,bw,bh],width=w,height=h,matrix=None if i%11==0 else [c,s,-s,c,0,0] if i%13 else [0,0,0,0,0,0],ink=[60+i%12*5,40+i%7*8,70+i%12*5,46+i%7*8]))
for i in range(40):jobs.append(dict(operation='turn',origin=[10+i/4,20-i/2],center=[70,80],angle=0 if i%4==0 else None if i%5==0 else (i-20)*.01))
for i in range(80):
    w=h=100;safe=[1]*(w*h);lum=[230+(x+y)%20 for y in range(h) for x in range(w)]
    if i%5==0:safe[50*w+50]=0
    jobs.append(dict(operation='range',safe=safe,luminance=lum,width=w,height=h,frame=[20,20],at=[-2 if i%4==0 else 0,0,1,1,w,h],budget=[128,4096,1048576][i%3],lookup=[100,1000,10000][i%3],boxes=[[3,3,97,97],[10,10,50,50]] if i%2 else [[4,4,80,80]]))
blob=json.dumps(jobs).encode();web=json.loads(subprocess.check_output(['node','-e',NODE,str(REF)],input=blob));native=json.loads(subprocess.check_output([str(ROOT/'build/native-final-rendering-helper-host/check')],input=blob));fail=[dict(index=i,web=a,native=b) for i,(a,b) in enumerate(zip(web,native)) if a!=b]
report=dict(cases=len(jobs),exact=not fail,failures=fail,scope='80lazy pool byte/budget cases +120transformedplate decisions +40gloss localorigins +80actual owned range/cell scan cases')
(ROOT/'build/native-final-rendering-helper-host/differential.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));raise SystemExit(bool(fail))
