#!/usr/bin/env python3
from pathlib import Path
import json,random,subprocess,math,hashlib
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;OUT=ROOT/'build/native-early-balloon-grid-host';OUT.mkdir(parents=True,exist_ok=True)
rng=random.Random(4749);jobs=[]
def add(name,**kw):
 j=dict(name=name,w=16,h=16,at=[112,112,1,1,256,256],frame=[0,0,256,256],glyph=8,surfaceSafe=True,coeff=[[220,0,0],[220,0,0],[220,0,0]],clearSearch=True,late=False,obstacles=[],exterior='paper');j.update(kw)
 w,h=j['w'],j['h'];x,y,sx,sy,iw,ih=j['at'];j.setdefault('safe',[1]*(w*h));j.setdefault('sources',[[(x+w/sx*.25)/iw,(y+h/sy*.25)/ih,w/sx*.5/iw,h/sy*.5/ih]]);jobs.append(j)
add('full-positive-expanded');add('alpha254-positive',exterior='alpha254');add('alpha253-crop-only',exterior='alpha253');add('tolerance18-positive',exterior='tolerance');add('tolerance19-crop-only',exterior='wrong');add('nil-reader-crop-only',exterior='absent');add('no-plane-reach',coeff=None);add('late-no-reach',late=True);add('normal-no-reach',clearSearch=False);add('unsafe-quality-no-reach',surfaceSafe=False);add('source-font-zero',glyph=0)
add('expansion-limit-fallback',w=128,h=128,at=[112,112,2,2,256,256],frame=[0,0,64,64])
add('painted-component-left',safe=[0 if x==8 else 1 for y in range(16) for x in range(16)],painted=[255 if x<8 else 0 for y in range(16) for x in range(16)],coeff=None)
add('painted-empty-fallback',safe=[0 if x==8 else 1 for y in range(16) for x in range(16)],painted=[0]*256,coeff=None)
add('interior-positive',interior=[108,108,28,28]);add('interior-no-source',interior=[10,10,8,8]);add('all-unsafe',safe=[0]*256,coeff=None)
for i in range(96):
 w,h=rng.choice([(8,8),(16,12),(24,20),(32,24)]);sx,sy=rng.choice([(1,1),(.5,.75),(2,1),(1,2)]);x,y=rng.choice([(112,112),(0,0),(230,240),(64,88)]);frame=rng.choice([[0,0,256,256],[7,11,512,384],[-5,8,128,256]])
 safe=[1 if rng.random()>.12 else 0 for _ in range(w*h)]
 coeff=rng.choice([[[220,0,0]]*3,[[120,60,20],[100,-10,30],[80,20,-20]],[[300,-100,0],[260,0,-100],[-20,120,100]],None])
 kw=dict(w=w,h=h,at=[x,y,sx,sy,256,256],frame=frame,safe=safe,coeff=coeff,exterior=rng.choice(['paper','wrong','tolerance','striped','alpha253','alpha254','absent']),glyph=rng.choice([0,5,8,12]),clearSearch=i%13!=0,late=i%17==0)
 if i%5==0:kw['painted']=[255 if n%w<w//2 else 0 for n in range(w*h)]
 if i%7==0:kw['obstacles']=[[frame[0]+x/256*frame[2]+4,frame[1]+y/256*frame[3]+2,3,9]]
 if i%11==0:kw['interior']=[frame[0]+x/256*frame[2]-2,frame[1]+y/256*frame[3]-2,24,24]
 add('random-%03d'%i,**kw)
(OUT/'fixtures.json').write_text(json.dumps(jobs))
helper=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeEarlyBalloonGrid.swift'
if not helper.exists():helper=HERE/'NativeEarlyBalloonGrid.swift'
subprocess.run(['swiftc','-O','-swift-version','6',str(helper),str(HERE/'EarlyBalloonGridMain.swift'),'-o',str(OUT/'check')],check=True)
subprocess.run([str(OUT/'check'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
subprocess.run(['node',str(HERE/'early-balloon-grid-oracle.cjs'),str(HERE.parent/'reference-source'),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
a=json.loads((OUT/'native.json').read_text());b=json.loads((OUT/'web.json').read_text())
def same(a,b):
 if isinstance(a,(float,int)) and not isinstance(a,bool) and isinstance(b,(float,int)) and not isinstance(b,bool):return math.isclose(a,b,abs_tol=1e-9,rel_tol=0)
 if type(a)!=type(b):return False
 if isinstance(a,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
 if isinstance(a,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
 return a==b
failed=[dict(index=i,native=x,web=y) for i,(x,y) in enumerate(zip(a,b,strict=True)) if not same(x,y)]
report=dict(cases=len(a),passed=not failed,accepted=sum(x['accepted'] for x in a),differences=failed,numericAbsoluteTolerance=1e-9,
 scope='Unchanged frozen4749–4837 expanded early clear grid. All blocked/reached bytes and Int32 SAT entries compared via SHA256; exact clear queries and exterior read dimensions; geometry numeric1e-9. Positive exterior/tolerance/alpha, component selection/fallback, sourceSpan and limits. Supplied identical RGBA/safe/painted/interior/other-layer inputs; actual shaper and finalPNG excluded.',
 sourceSHA256={str(helper.relative_to(ROOT)):hashlib.sha256(helper.read_bytes()).hexdigest()})
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='differences'}))
if failed:print(json.dumps(failed[:3],indent=2));raise SystemExit(1)
