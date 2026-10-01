#!/usr/bin/env python3
from pathlib import Path
import random,json,subprocess,math
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;OUT=ROOT/'build/native-display-widening-host';OUT.mkdir(parents=True,exist_ok=True)
rng=random.Random(8567);jobs=[]
def add(name,**kw):
 x=dict(name=name,font=10,glyph=70,text='GO NOW',plate=[150,100,30,140],frame=[0,0,390,700],source=[150,100,30,140]);x.update(kw);jobs.append(x)
add('positive-display')
for i in range(230):
 kw=dict(font=rng.choice([7,10,20,30]),glyph=rng.choice([23.9,24,39.9,40,60,90]),pageGlyph=rng.choice([10,20,40]),text=rng.choice(['GO NOW','HUGE','한 글 두 글','A MUCH LONGER PHRASE']),factor=rng.choice([.3,.5,.8]),plate=[150,100,rng.choice([20,40,80]),rng.choice([40,80,160])])
 kw['source']=kw['plate']
 if i%4==0:kw['grown']=kw['font']*1.4
 if i%5==0:kw['texture']=True
 if i%7==0:kw['sources']=[[100,100,20,100]]
 if i%11==0:kw['others']=[[190,80,30,150]]
 if i%13==0:kw['cards']=[[110,80,30,150]]
 if i%17==0:kw['budget']=0
 if i%19==0:kw.update(strict=True,badStart=True)
 if i%23==0:kw['visiblePlate']=[155,100,20,100]
 add('widen-%03d'%i,**kw)
for key,value in [('flatRoom',True),('rotated',True),('vertical',True),('sourceVertical',False),('recovery',False),('visible',False),('script','other'),('color',[255,255,255,.9])]:add('gate-'+key,**{key:value})
(OUT/'fixtures.json').write_text(json.dumps(jobs,ensure_ascii=False))
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPlateGrowth.swift'),str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyDisplayWidening.swift'),str(HERE/'DisplayWideningMain.swift'),'-o',str(OUT/'check')],check=True)
subprocess.run([str(OUT/'check'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
subprocess.run(['node',str(HERE/'display-widening-oracle.cjs'),str(HERE.parent/'reference-source'),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
a=json.loads((OUT/'native.json').read_text());b=json.loads((OUT/'web.json').read_text())
def same(a,b):
 if isinstance(a,(int,float)) and isinstance(b,(int,float)):return math.isclose(a,b,abs_tol=1e-9,rel_tol=0)
 if type(a)!=type(b):return False
 if isinstance(a,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
 if isinstance(a,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
 return a==b
fail=[dict(index=i,native=x,web=y) for i,(x,y) in enumerate(zip(a,b,strict=True)) if not same(x,y)]
report=dict(cases=len(a),passed=not fail,accepted=sum(x['size'] is not None for x in a),differences=fail,numericAbsoluteTolerance=1e-9,scope='Full unchanged growPlateWide/widenDisplayCard wrapper, samecanvaswordadvances/nativeRGBA crop probes/physical metrics. Actual font raster, rotated growth and renderer chronology excluded.')
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='differences'}))
if fail:print(json.dumps(fail[:3],indent=2));raise SystemExit(1)
