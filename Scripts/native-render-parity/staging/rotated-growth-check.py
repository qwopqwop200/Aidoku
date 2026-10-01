#!/usr/bin/env python3
from pathlib import Path
import random,json,subprocess,math
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;OUT=ROOT/'build/native-rotated-growth-host';OUT.mkdir(parents=True,exist_ok=True)
rng=random.Random(7981);jobs=[]
def add(name,**kw):
 x=dict(name=name,font=12,glyph=24,box=[100,100,100,60],text='ONE TWO');x.update(kw);jobs.append(x)
add('body-positive');add('display-positive',glyph=60,box=[100,100,240,180]);add('condensed-word',glyph=32,box=[100,100,75,35],text='ABCDEFGHI')
for i in range(280):
 kw=dict(font=rng.choice([5,7.5,10,12,18,28]),glyph=rng.choice([6,12,24,39.99,40,80]),box=[100,100,rng.choice([35,60,100,180]),rng.choice([20,40,60,120])],text=rng.choice(['ONE TWO','한글 단어 세 글자','ABCDEFGHI','A WORD THEN WORD','ONE\nTWO']),angle=rng.choice([-.4,.2,.6,1.1]),factor=rng.choice([.3,.5,.8]))
 if i%3==0:kw['peers']=[dict(text=kw['text'],script='korean',glyph=20,font=9,source=[250,250,20,20])]
 if i%7==0:kw['others']=[[130,100,40,50]];kw['groups']=[[[130,100,40,20],[130,125,40,20]]]
 if i%11==0:kw['cards']=[[160,120,30,40]]
 if i%13==0:kw['upright']=True
 if i%17==0:kw['noConvex']=True
 if i%19==0:kw.update(strict=True,badStart=True)
 if i%23==0:kw['cap']=kw['font']*1.1
 add('rotated-%03d'%i,**kw)
for key,value in [('rotatingPanel',False),('backgroundKind','inpainted'),('vertical',True),('wrap','other'),('visible',False),('plainText',False),('opaque',False)]:add('gate-'+key,**{key:value})
(OUT/'fixtures.json').write_text(json.dumps(jobs,ensure_ascii=False))
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPlateGrowth.swift'),str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSlantedGeometry.swift'),str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyRotatedGrowth.swift'),str(HERE/'RotatedGrowthMain.swift'),'-o',str(OUT/'check')],check=True)
subprocess.run([str(OUT/'check'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
subprocess.run(['node',str(HERE/'rotated-growth-oracle.cjs'),str(HERE.parent/'reference-source'),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
a=json.loads((OUT/'native.json').read_text());b=json.loads((OUT/'web.json').read_text())
def same(a,b):
 if isinstance(a,(int,float)) and isinstance(b,(int,float)):return math.isclose(a,b,abs_tol=1e-9,rel_tol=0)
 if type(a)!=type(b):return False
 if isinstance(a,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
 if isinstance(a,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
 return a==b
fail=[dict(index=i,native=x,web=y) for i,(x,y) in enumerate(zip(a,b,strict=True)) if not same(x,y)]
report=dict(cases=len(a),passed=not fail,accepted=sum(x['size'] is not None for x in a),differences=fail,numericAbsoluteTolerance=1e-9,scope='Full unchanged frozen growRotatedBody/growRotatedPlate source/peer/row caps, ink/pitch/shift/condensed schedules, shared sourcequad/convex/card/crowding policy. Deterministic physical word Range rows and Canvas font metrics. Actual CoreText/RGBA/renderer chronology excluded.')
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='differences'}))
if fail:print(json.dumps(fail[:3],indent=2));raise SystemExit(1)
