#!/usr/bin/env python3
"""Whole frozen recovered-line block vs actual native policy, including kept halos.
The deterministic raster seam supplies identical source pixels; native Canvas
resampling has its separate frozen-source pixel-reader differential gate.
"""
import copy,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/recovered-line';OUT.mkdir(parents=True,exist_ok=True)
base=dict(frame=[0,0,100,100],iw=100,ih=100,opacity=1,complete=True,background=[255,255,255,255],art=[],items=[dict(id='recovered',recovered=True,bounds=[.4,.4,.2,.2],font=12,hasNode=True,plates=[dict(rect=[0,0,100,100],color=[255,255,255])])])
fixtures=[]
for seed in range(80):
 j=copy.deepcopy(base);j['seed']=seed;mode=seed%20
 if mode in (0,1,2):j['art']=[[0,0,[1,2,3][mode],100,0,0,0,255]]
 elif mode==3:j['art']=[[38,38,24,24,0,0,0,255]]
 elif mode in (4,5,6):j['background']=[[215,255,255,255],[214,255,255,255],[216,255,255,255]][mode-4]
 elif mode==7:j['opacity']=.99
 elif mode==8:j['complete']=False
 elif mode==9:j['items'][0]['hasNode']=False
 elif mode==10:j['items'][0]['plates']=[]
 elif mode==11:j['items'][0]['plates'][0]['visible']=False
 elif mode==12:j['items'][0]['plates'][0]['color']=None
 elif mode==13:j['items'][0]['plates'][0]['color']=None;j['items'][0]['fallback']=[255,255,255];j['background']=[0,0,0,255]
 elif mode==14:j['frame']=[10.25,20.5,83.75,74.5];j['items'][0]['plates'][0]['rect']=[0,0,80.2,90.4];j['art']=[[0,0,30,100,0,0,0,255]]
 elif mode==15:j['iw']=2048;j['ih']=1024;j['frame']=[0,0,2048,1024];j['items'][0]['plates']=[dict(rect=[0,0,2048,1024],color=[255,255,255]) for _ in range(12)];j['background']=[0,0,0,255]
 elif mode==16:j['items'][0]['recovered']=False;j['background']=[0,0,0,255]
 elif mode==17:j['items'][0]['plates']=[dict(rect=[0,0,1,80],color=[255,255,255])];j['background']=[0,0,0,255]
 elif mode==18:j['items'][0]['bounds']=[.4,.4,-.2,.2];j['background']=[0,0,0,255]
 else:j['background']=[0,0,0,0]
 if seed>=20:j['items'].append(dict(id='painted',recovered=False,bounds=[[.55,.3,.2,.4],[.45,.45,.1,.1],[.8,.8,.1,.1]][seed%3],font=None,plates=[]))
 if seed>=40:j['items'][0]['font']=None
 if seed>=60:j['items'].append(dict(id='recovered2',recovered=True,bounds=[.7,.7,.1,.1],font=30,plates=[dict(rect=[60,60,35,35],color=[255,255,255])]))
 fixtures.append(j)
(OUT/'fixtures.json').write_text(json.dumps(fixtures));subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
(OUT/'Model.swift').write_text('import Foundation\nimport CoreGraphics\nstruct NativeTranslationLayoutItem { let id:String; let keptLettering:Bool;let sourceBounds:[CGFloat];let sourceFrame:[CGFloat];let sourceFontSize:CGFloat? }\n')
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
sources=[OVERLAY/(name+'.swift') for name in ('NativeRecoveredLineProtection','NativeKeptSourceRestoration','NativePanelGeometry','NativeTranslationSourceStylePostPolish')]
subprocess.run(['swiftc','-O',str(OUT/'Model.swift'),*map(str,sources),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
web=json.loads((OUT/'web.json').read_text());native=json.loads((OUT/'native.json').read_text());failures=[]
for f,w,n in zip(fixtures,web,native):
 if w!=n:failures.append(dict(seed=f['seed'],web=w,native=n))
report=dict(passed=not failures,cases=len(fixtures),exact=len(fixtures)-len(failures),positiveDrops=sum(bool(v['dropped']) for v in web),budgetExhaustionCases=sum(v['budget']<32768 for v in web),haloSubtractionCases=sum(len(v['zones'])>len(v['kept']) for v in web),failures=failures)
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='failures'}));print(json.dumps(failures[:2],indent=2));raise SystemExit(bool(failures))
