#!/usr/bin/env python3
from pathlib import Path
import random,json,subprocess,math
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;OUT=ROOT/'build/native-display-style-cohort-host';OUT.mkdir(parents=True,exist_ok=True)
rng=random.Random(13874);jobs=[]
def m(id,**kw):
 x=dict(id=id,sampled=[20,20,20],fill=[20,20,20],font=20,glyph=20,ink=[id*60,10,45,30],ownerRect=[id*60,0,55,60],backing=[1,1]);x['id']=str(id);x.update(kw);return x
def add(name,*members):jobs.append(dict(name=name,members=members))
add('fill-pair',m(0,fill=[90,90,90]),m(1))
add('fill-majority',m(0,fill=[90,90,90]),m(1),m(2))
add('drop-readability',m(0,stroke=[100,100,100],strokeSource='readability-outline'),m(1),m(2))
add('recolor-paper',m(0,fill=[140,140,140],plate=[25,25,25],backing=[.01,.01]),m(1,plate=[255,255,255]),m(2,plate=[255,255,255]))
add('locked-outline',m(0,stroke=[240,240,240],ringKind='outline',ringAction='outline'),m(1),m(2))
for i in range(350):
 sample=rng.choice([[20,20,20],[240,240,240],[220,10,10],[10,120,180],[150,90,50]])
 members=[]
 for k in range(rng.randint(2,7)):
  good=k>0 and rng.random()<.75
  fill=sample if good else rng.choice([[0,0,0],[60,60,60],[100,100,100],[200,200,200],[255,255,255],[140,20,140],[220,10,10]])
  kw=dict(sampled=sample,fill=fill,font=rng.choice([8.5,17.99,18,42.75]),glyph=rng.choice([15,20,36,36.01,50,None]),backing=rng.choice([[0,0],[1,1],[.2,.3],[.8,.95],None]),locked=rng.random()<.07)
  if rng.random()<.6:kw.update(plate=rng.choice([[255,255,255],[30,30,30],[100,100,100],[210,220,235]]),ownerIsNode=rng.random()<.1,ownerAlone=rng.random()<.9)
  if rng.random()<.4:kw.update(stroke=rng.choice([[0,0,0],[255,255,255],[100,100,100],[sample[0],sample[1],sample[2]]]),strokeSource=rng.choice(['preserved','readability-outline','none']))
  if rng.random()<.55:kw.update(sampledStroke=rng.choice([[255,255,255],[0,0,0],[100,100,100]]),strokeConfidence=rng.choice([.54,.55,.9]))
  if rng.random()<.55:kw['sampledBack']=rng.choice([[255,255,255],[100,100,100],[0,0,0]])
  if rng.random()<.5:kw.update(ringKind=rng.choice(['outline','paper','none']),ringAction=rng.choice(['outline','restored-outline','hollow','kept','outline-as-fill','none']),ringCore=rng.choice([sample,[255,255,255],None]),ringPlateTo=rng.random()<.1,ringSurface=rng.choice([[255,255,255,1],[100,100,100,1],[0,0,0,.5],None]))
  members.append(m(k,**kw))
 add('style-%03d'%i,*members)
(OUT/'fixtures.json').write_text(json.dumps(jobs))
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeDisplayStyleCohort.swift'),str(HERE/'DisplayStyleCohortMain.swift'),'-o',str(OUT/'check')],check=True)
subprocess.run([str(OUT/'check'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
subprocess.run(['node',str(HERE/'display-style-cohort-oracle.cjs'),str(HERE.parent/'reference-source'),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
a=json.loads((OUT/'native.json').read_text());b=json.loads((OUT/'web.json').read_text())
def equal(a,b):
 if isinstance(a,(int,float)) and isinstance(b,(int,float)):return math.isclose(a,b,abs_tol=1e-9,rel_tol=0)
 if type(a)!=type(b):return False
 if isinstance(a,dict):return a.keys()==b.keys() and all(equal(a[k],b[k]) for k in a)
 if isinstance(a,list):return len(a)==len(b) and all(equal(x,y) for x,y in zip(a,b))
 return a==b
fail=[dict(index=i,native=x,web=y) for i,(x,y) in enumerate(zip(a,b,strict=True)) if not equal(x,y)]
report=dict(cases=len(a),passed=not fail,decisions=sum(len(x['decisions']) for x in a),differences=fail,numericAbsoluteTolerance=1e-9,scope='Full unchanged frozen final page style cohort13874–14103: CIELab observed medoid, sampled-ink proximity, outline/fill locks, majority stroke removal, plate ownership/shared-ink/polarity guards and committed mutation. Deterministic style/ink/backing collection. Pixel backing raster separate proof; final renderer chronology/PNG excluded.')
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='differences'}))
if fail:print(json.dumps(fail[:3],indent=2));raise SystemExit(1)
