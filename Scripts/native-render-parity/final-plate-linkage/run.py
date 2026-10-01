#!/usr/bin/env python3
import copy,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/final-plate-linkage';OUT.mkdir(parents=True,exist_ok=True)
base=dict(frame=[0,0,100,100],iw=100,ih=100,opacity=1,preserveBackground=True,background=[240,240,240,255],
 items=[dict(id='a',source=[.43,.1,.14,.65],sourceFont=20,rotation=0,vertical=False,sourceVertical=True)],
 nodes=[dict(id='a',ink=[20,20,60,16],font=12,colors=[[10,10,10],[120,120,120]])],
 panels=[dict(id='a',box=[15,5,70,80],color=[240,240,240])],art=[[18,48,16,29,100,80,240,255],[66,48,16,29,100,80,240,255]])
jobs=[]
for seed in range(180):
 j=copy.deepcopy(base);mode=seed%30;j['seed']=seed
 if mode==1:j['art']=[]
 if mode==2:j['art']=[[15,5,70,80,10,10,10,255]]
 if mode==3:j['art']=j['art']+[[23,55,4,4,10,10,10,255]]
 if mode==4:j['nodes'][0]['inPanel']=True
 if mode==5:j['panels'][0]['sourceErasure']=True
 if mode==6:j['panels'][0]['preservedCaption']=True
 if mode==7:j['panels'][0]['foreignFills']=True
 if mode==8:j['panels'][0]['backing']=True
 if mode==9:j['panels'][0]['transformed']=True
 if mode==10:j['panels'][0]['unknownClip']=True
 if mode==11:j['items'][0]['rotation']=.2
 if mode==12:j['opacity']=.5
 if mode==13:j['preserveBackground']=False
 if mode==14:j['panels'][0]['coverage']=[[15,5,70,50],[30,55,30,30]]
 if mode==15:j['panels'][0]['coverage']=[]
 if mode==16:j['nodes'][0]['transformed']=True
 if mode==17:j['nodes'][0]['fits']=False
 if mode==18:j['panels'][0]['restoration']=[16,45,20,35]
 if mode==19:j['nodes'].append(dict(id='foreign',ink=[18,55,15,15],font=12));j['items'].append(dict(id='foreign',source=[.15,.55,.1,.1],sourceFont=16,rotation=0,vertical=False,sourceVertical=False))
 if mode==20:j['items'][0]['aux']=[[.18,.48,.16,.29]]
 if mode==21:j['nodes'][0]['colors']=[]
 if mode==22:j['art']=[[18,48,16,29,201,220,240,0],[66,48,16,29,190,240,230,255]]
 if mode==23:j['items'][0]['source']=[.2,.45,.6,.2];j['nodes'][0]['ink']=[26,12,45,16];j['art']=[[15,5,70,30,100,80,240,255]]
 if mode==24:j['items'][0]['source']=[.2,.45,.6,.2];j['nodes'][0]['ink']=[26,12,45,16];j['art']=[]
 if mode==25:j['items'][0]['source']=[.2,.45,.6,.2];j['nodes'][0]['ink']=[26,12,45,16];j['nodes'].append(dict(id='foreign',ink=[28,48,45,12],font=12));j['art']=[[15,5,70,30,100,80,240,255]]
 if mode==26:j['panels'][0]['rootChild']=False
 if mode==27:j['panels'][0]['shown']=False
 if mode==28:j['nodes'][0]['shown']=False
 if mode==29:j['items'][0]['sourceVertical']=False;j['items'].append(dict(id='neighbor',source=[.18,.48,.12,.2],sourceFont=8,sourceVertical=True))
 if seed>=30 and mode not in (23,24,25):j['nodes'][0]['font']=8+(seed%6)*2
 if seed>=60 and mode in (0,4,14,21):j['panels'][0]['box']=[14.25,4.75,71.5,81.5]
 if seed>=90 and mode in (0,2,3,4,18,19,20,21):j['iw']=200;j['ih']=200;j['art']=[[r[0]*2,r[1]*2,r[2]*2,r[3]*2]+r[4:] for r in j['art']]
 if seed>=120 and mode==0:j['panels'][0]['coverage']=[[15,5,70,80]]
 jobs.append(j)
# Shared pixel budget is consumed by unsuccessful reads too, in panel order.
for scale in (8,16):
 j=copy.deepcopy(base);j['seed']=len(jobs);j['iw']=j['ih']=100*scale
 j['art']=[[r[0]*scale,r[1]*scale,r[2]*scale,r[3]*scale]+r[4:] for r in j['art']]
 j['nodes'][0]['colors']=[]
 jobs.append(j)
# Isolated source-like marks keep their particular candidate covered; artwork
# without that mark releases both corners. A mark running out an outer side is safe.
for mark in ([23,55,4,4],[16,55,4,4],[23,55,1,1]):
 j=copy.deepcopy(base);j['seed']=len(jobs);j['art'].append(mark+[10,10,10,255]);jobs.append(j)
(OUT/'fixtures.json').write_text(json.dumps(jobs));subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeFinalPlateLinkage.swift'),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
w=json.loads((OUT/'web.json').read_text());n=json.loads((OUT/'native.json').read_text());fail=[dict(seed=j['seed'],web=a,native=b) for j,a,b in zip(jobs,w,n) if a!=b]
r=dict(passed=not fail,cases=len(jobs),exact=len(jobs)-len(fail),positive=sum(bool(v['links']) for v in w),moved=sum(any(l['move'] for l in v['links']) for v in w),failures=fail)
(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps({k:v for k,v in r.items() if k!='failures'}));print(json.dumps(fail[:2],indent=2));raise SystemExit(bool(fail))
