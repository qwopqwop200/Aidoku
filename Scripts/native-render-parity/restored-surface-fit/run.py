#!/usr/bin/env python3
import json,math,pathlib,random,subprocess,time
root=pathlib.Path(__file__).resolve().parents[3];build=root/'build/native-render-parity/restored-surface-fit';build.mkdir(parents=True,exist_ok=True)
source=(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPostPolish.swift').read_text();(build/'NativeTypographyPostPolish.swift').write_text(source.split('    /// Frozen inspectSurface range')[0]+'}\n')
start=time.monotonic();subprocess.run(['swiftc','-O',str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationTypography.swift'),str(build/'NativeTypographyPostPolish.swift'),str(root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyRestoredSurfaceFit.swift'),str(root/'Scripts/native-render-parity/restored-surface-fit/main.swift'),'-o',str(build/'fit')],check=True)
compiled=time.monotonic()-start
rng=random.Random(9768);cases=[]
for i in range(60):
 w=h=120;safe=[1]*(w*h);interior=None
 for k in range(i%4):
  x=rng.randrange(20,100);y=rng.randrange(20,100)
  for yy in range(y,min(y+10,h)):
   for xx in range(x,min(x+3,w)):safe[yy*w+xx]=0
 painted=None if i%3 else [255 if 38<=x<45 and 40<=y<80 else 0 for y in range(h) for x in range(w)]
 if i%4==0:interior=[1 if (x-60)**2+(y-60)**2<56**2 else 0 for y in range(h) for x in range(w)]
 cases.append(dict(id=str(i),width=w,height=h,crop=[10,20,120,120],page=[0,0,200,220],safe=safe,painted=painted,interior=interior,core=[[40,50,40,50]],obstacles=[] if i%2 else [[95,20,10,120]],glyph=14,font=[8.5,10,12.5,16][i%4],ratio=1.2,lines=3,text=['안녕, 세상! 함께 출발하자.','지금 가는 것은 무리인 것 같다.','왜 이러는 거야','정말로 믿을 수 있겠어?'][i%4],baseWidth=68,budget=65536))
start=time.monotonic();p=subprocess.run([str(build/'fit')],input=''.join(json.dumps(c,ensure_ascii=False)+'\n' for c in cases),text=True,capture_output=True,check=True)
native=[json.loads(l) for l in p.stdout.splitlines()];assert len(native)==len(cases)
inputs=[dict(c,widths=n['widths']) for c,n in zip(cases,native)]
o=subprocess.run(['node',str(root/'Scripts/native-render-parity/restored-surface-fit/oracle.cjs')],input=''.join(json.dumps(c,ensure_ascii=False)+'\n' for c in inputs),text=True,capture_output=True,check=True)
oracle=[json.loads(l) for l in o.stdout.splitlines()];assert len(oracle)==len(cases)
def same(a,b):
 if isinstance(a,(int,float)) and isinstance(b,(int,float)):return math.isclose(a,b,rel_tol=0,abs_tol=1e-8)
 if isinstance(a,dict) and isinstance(b,dict):return a.keys()==b.keys() and all(same(a[k],b[k]) for k in a)
 if isinstance(a,list) and isinstance(b,list):return len(a)==len(b) and all(same(x,y) for x,y in zip(a,b))
 return a==b
fail=[dict(id=c['id'],native={k:v for k,v in n.items() if k!='widths'},oracle=o) for c,n,o in zip(cases,native,oracle) if not same({k:v for k,v in n.items() if k!='widths'},o)]
r=dict(cases=len(cases),passed=len(cases)-len(fail),failed=len(fail),compileSeconds=compiled,executionSeconds=time.monotonic()-start,scope='Full frozen late safe-area connected-grid and prediction policy using the same native font metrics; final DOM candidate proof remains separate.',failures=fail)
(build/'report.json').write_text(json.dumps(r,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in r.items() if k!='failures'}));print(json.dumps(fail[:2],ensure_ascii=False))
if fail:raise SystemExit(1)
