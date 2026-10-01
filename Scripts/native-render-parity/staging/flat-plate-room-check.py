#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,math
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;OUT=ROOT/'build/native-plate-growth-host';OUT.mkdir(parents=True,exist_ok=True);jobs=[]
for i in range(72):
 w,h=160,140;ratio=[.75,1,1.5,2.5,4,8][i%6];frame=[3,-5,w/ratio,h/ratio];plate=[frame[0]+frame[2]*.3,frame[1]+frame[3]*.3,frame[2]*.3,frame[3]*.3];rgba=[]
 for y in range(h):
  for x in range(w):
   d=0 if i%4==0 else 11 if i%4==1 and x>110 else 25 if i%4==2 and x==50 else (x*3+y)%15 if i%4==3 else 0
   rgba.extend([240-d,240-d,240-d,255])
 glyph=[6,12,40][i%3];queries=[plate,[plate[0]-2,plate[1],1,1],[plate[0]+plate[2]+1,plate[1],1,1],[frame[0],frame[1],1,1],[-100,-100,1,1]]
 f=dict(name='flat-pixels-%03d'%i,width=w,height=h,rgba=rgba,color=[240,240,240],frame=frame,plate=plate,glyph=glyph,covered=[plate] if i%2 else [],queries=queries)
 if i%11==0:f['budget']=64
 if i%17==0:f['shadow']=True
 if i%19==0:f['border']=True
 if i%23==0:f['transformed']=True
 if i%29==0:f['transparent']=True
 jobs.append(f)
(OUT/'flat-fixtures.json').write_text(json.dumps(jobs));subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPlateGrowth.swift'),str(HERE/'FlatPlateRoomMain.swift'),'-o',str(OUT/'flat-check')],check=True)
subprocess.run([str(OUT/'flat-check'),str(OUT/'flat-fixtures.json'),str(OUT/'flat-native.json')],check=True);subprocess.run(['node',str(HERE/'flat-plate-room-oracle.cjs'),str(HERE.parent/'reference-source'),str(OUT/'flat-fixtures.json'),str(OUT/'flat-web.json')],check=True)
a=json.loads((OUT/'flat-native.json').read_text());b=json.loads((OUT/'flat-web.json').read_text());fail=[dict(index=i,native=x,web=y) for i,(x,y) in enumerate(zip(a,b,strict=True)) if x!=y]
r=dict(cases=len(a),passed=not fail,matched=len(a)-len(fail),returned=sum(x['bounds'] is not None for x in a),differences=fail,scope='Full unchanged frozen flatPlateRoom sourcepixel crop/budget/grid/Float32 accumulation/Uint16 count/covered-cell clearing/integral table/physical queries. Exact decisions/geometry/budget with identical source RGBA; no final font or PNG claim.')
(OUT/'flat-report.json').write_text(json.dumps(r,indent=2));print(json.dumps({k:v for k,v in r.items() if k!='differences'}))
if fail:print(json.dumps(fail[:2],indent=2));raise SystemExit(1)
