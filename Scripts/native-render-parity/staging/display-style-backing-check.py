#!/usr/bin/env python3
from pathlib import Path
import random,json,subprocess
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;OUT=ROOT/'build/native-display-style-cohort-host';OUT.mkdir(parents=True,exist_ok=True)
rng=random.Random(13902);jobs=[]
for i in range(110):
 W,H=([(4,4),(3,5),(5,5),(64,72),(201,203),(350,300)][i%6]);j=dict(width=W,height=H,frame=[0,0,W,H],origin=[0,0],scale=[1,1],image=[W,H],ink=[0,0,W,H],luminance=[rng.randrange(256) for _ in range(W*H)])
 if i%11==0:j['ink']=[-1,-1,W+2,H+2]
 if i%13==0:j.update(origin=[W*.8,H*.8])
 if i%7==0:j['budget']=10
 if i%17==0:j['budget']=0
 if i%19==0:j['connected']=False
 if i%4==0:j['fallback']=[.1,.9]
 if i%3==0:j['panels']=[dict(rect=[0,0,W/2,H/2],color=[255,255,255]),dict(rect=[W/2,H/2,W/2,H/2],color=[0,0,0])]
 if i%9==0:j['fractional']=True;j['luminance']=[x+.125 for x in j['luminance']]
 if i%5==0:j.update(frame=[10,20,W*2,H*3],ink=[10,20,W*2,H*3],scale=[.5,.25],origin=[1.25,2.5])
 jobs.append(dict(name='backing-%03d'%i,backing=j))
(OUT/'backing-fixtures.json').write_text(json.dumps(jobs))
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeDisplayStyleCohort.swift'),str(HERE/'DisplayStyleBackingMain.swift'),'-o',str(OUT/'backing-check')],check=True)
subprocess.run([str(OUT/'backing-check'),str(OUT/'backing-fixtures.json'),str(OUT/'backing-native.json')],check=True)
subprocess.run(['node',str(HERE/'display-style-backing-oracle.cjs'),str(HERE.parent/'reference-source'),str(OUT/'backing-fixtures.json'),str(OUT/'backing-web.json')],check=True)
a=json.loads((OUT/'backing-native.json').read_text());b=json.loads((OUT/'backing-web.json').read_text());fail=[dict(index=i,native=x,web=y) for i,(x,y) in enumerate(zip(a,b,strict=True)) if x!=y]
report=dict(cases=len(a),passed=not fail,backingRanges=sum(x['range'] is not None for x in a),differences=fail,scope='Unchanged frozen restoredBackingS original integer/fractional luminance buffers, same raster geometry, sample budgets/20k stride/80-percent coverage, 2–98 percentile/fallback and overlapping panel luminance. Exact arrays/remaining budget. Actual final composited raster production ownership separate.')
(OUT/'backing-report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='differences'}))
if fail:print(json.dumps(fail[:3],indent=2));raise SystemExit(1)
