#!/usr/bin/env python3
"""Run the complete unchanged frozen growPlate block with shared physical probes."""
from pathlib import Path
import json,subprocess,random,math
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;OUT=ROOT/'build/native-plate-growth-host';OUT.mkdir(parents=True,exist_ok=True)
rng=random.Random(8294);jobs=[]
def add(name,**kwargs):
 f=dict(name=name,text='hello world',font=12,glyph=24,plate=[20,20,160,100],ink=[65,62,70,16],frame=[0,0,390,700],factor=.5)
 f.update(kwargs);jobs.append(f)
add('actual-source-color-SFX-cohort-cap',text='달칵!',font=31.5,glyph=75.4224104626735,cap=42.75,plate=[33,381.53125,199.1875,103.15625],ink=[101.265625,413.615625,62.640625,39],ratio=37.88916015625/31.75)
add('actual-source-color-SFX-first-growth',text='달칵!',font=31.5,glyph=75.4224104626735,plate=[33,381.53125,199.1875,103.15625],ink=[101.265625,413.615625,62.640625,39],ratio=37.88916015625/31.75)
for i in range(240):
 font=[5,7.5,8.49,8.5,9,12,24,31.5,32,40][i%10];glyph=[6,8,9.99,10,20,39.99,40,53.44,75.4224104626735,160][(i//10)%10]
 kw=dict(font=font,glyph=glyph,text=['가나다 라마바','짧은 말','ONE VERYLONGWORD TEXT','한글','word word word word'][i%5],factor=[.25,.5,.9][i%3],plate=[20,20,[40,80,160,250][i%4],[24,55,100,170][i%4]],ink=[45,30,15,font*1.2])
 if i%4==0:kw['room']=[0,0,330,300]
 if i%11==0:kw['others']=[[50,50,20,20]]
 if i%13==0:kw['foreignPlates']=[[100,20,20,40]]
 if i%17==0:kw['cards']=[[25,25,10,10]]
 if i%7==0:kw['cap']=font*1.12
 if i%9==0:kw['condensed']=True
 if i%19==0:kw.update(strict=True,badStart=True)
 if i%23==0:kw['coverage']=[[20,20,25,80],[40,20,60,100]]
 if i%29==0:kw['roomLayouts']=48
 if i%31==0:kw['blocked']=[[80,70,5,40]]
 add('plate-%03d'%i,**kw)
for key,val in [('vertical',True),('rotated',True),('visible',False),('plateVisible',False),('recovery',False),('script','other'),('committedAllowed',False),('lone',4)]:add('admission-'+key,condensed=True,**{key:val})
(OUT/'fixtures.json').write_text(json.dumps(jobs,ensure_ascii=False))
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPlateGrowth.swift'),str(HERE/'PlateGrowthMain.swift'),'-o',str(OUT/'check')],check=True)
subprocess.run([str(OUT/'check'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
subprocess.run(['node',str(HERE/'plate-growth-oracle.cjs'),str(HERE.parent/'reference-source'),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
a=json.loads((OUT/'native.json').read_text());b=json.loads((OUT/'web.json').read_text())
def same(a,b):
 if isinstance(a,(int,float)) and isinstance(b,(int,float)):return math.isclose(a,b,abs_tol=1e-9,rel_tol=0)
 if type(a)!=type(b):return False
 if isinstance(a,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
 if isinstance(a,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
 return a==b
fail=[dict(index=i,native=x,web=y) for i,(x,y) in enumerate(zip(a,b,strict=True)) if not same(x,y)]
r=dict(cases=len(a),passed=not fail,exactDecisions=sum(x['size']==y['size'] for x,y in zip(a,b)),accepted=sum(x['size'] is not None for x in a),roomAccepted=sum(bool(x.get('flatRoom')) for x in a),differences=fail,numericAbsoluteTolerance=1e-9,scope='Full unchanged frozen growPlate axis policy: source/display/lift/condensed schedules, actual plate/coverage/room selection, physical ink/line rectangles, collision/flow, room layout budgets and plate mutations. Supplied deterministic word advances and physical probes; real font raster, rotated grower, display widening and full renderer chronology excluded.')
(OUT/'report.json').write_text(json.dumps(r,indent=2,ensure_ascii=False));print(json.dumps({k:v for k,v in r.items() if k!='differences'},ensure_ascii=False))
if fail:print(json.dumps(fail[:3],indent=2,ensure_ascii=False));raise SystemExit(1)
