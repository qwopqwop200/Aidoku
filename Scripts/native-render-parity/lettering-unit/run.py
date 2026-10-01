#!/usr/bin/env python3
import copy,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/lettering-unit';OUT.mkdir(parents=True,exist_ok=True)
a=dict(id='a',box=[0,0,30,30],ink=[5,5,20,20],plate=[240,240,240],fill=[10,10,10],source=[10,10,10],glyph=24,font=18,stroke=None,strokeWidth=0,vertical=False,mode='readability-panel',text='word',children=1,visible=True,hasOwner=True,fills=[],ring=dict(surface=[235,235,235],core=[10,10,10],kind='outline'))
b=copy.deepcopy(a);b.update(id='b',box=[30,0,25,30],ink=[35,5,15,20],plate=[10,10,10],fill=[240,240,240],stroke=[10,10,10],strokeWidth=1)
base=dict(members=[a,b],neighbors=[],itemCount=2,opacity=1,preserveText=True,preserveBackground=True);jobs=[]
for seed in range(140):
 j=copy.deepcopy(base);mode=seed%28;A,B=j['members'];j['seed']=seed
 if mode==1:B['plate']=[225,225,225]
 if mode==2:B['source']=[80,80,80]
 if mode==3:B['glyph']=31
 if mode==4:B['vertical']=True
 if mode==5:B['box'][0]=35
 if mode==6:B['box'][1]=18
 if mode==7:A['ring']['surface']=[120,120,120]
 if mode==8:A['fill']=[90,90,90]
 if mode==9:A['stroke']=[240,240,240];A['strokeWidth']=1.1
 if mode==10:A['stroke']=[20,20,20];A['strokeWidth']=1.1
 if mode==11:j['neighbors']=[dict(id='foreign',ink=[35,5,10,10],fill=[240,240,240])]
 if mode==12:j['neighbors']=[dict(id='foreign',ink=[5,5,10,10],fill=[240,240,240])]
 if mode==13:j['neighbors']=[dict(id='foreign',ink=[35,5,10,10],fill=None)]
 if mode==14:A['font']=17;A['fill']=[100,100,100];A['source']=[100,100,100]
 if mode==15:A['glyphCover']=True
 if mode==16:A['children']=2
 if mode==17:B['hasOwner']=False
 if mode==18:B['visible']=False
 if mode==19:A['source']=None
 if mode==20:A['source']=None;A['ring']['kind']='unproven'
 if mode==21:j['opacity']=.5
 if mode==22:j['itemCount']=257
 if mode==23:j['preserveText']=False
 if mode==24:j['preserveBackground']=False
 if mode==25:
  j['members']=[dict(copy.deepcopy(a),id=str(i),box=[i*30,0,30,30],plate=[240,240,240] if i==0 else [10,10,10]) for i in range(13)];j['itemCount']=13
 if mode==26:
  B['fills']=[dict(rect=[30,0,4,4],color=[10,10,10]),dict(rect=[35,0,4,4],color=[90,80,70])]
 if mode==27:A['box']=[0,0,20,30];B.update(box=[20,0,40,30],plate=[240,240,240],fill=[10,10,10]);A.update(plate=[10,10,10],fill=[240,240,240])
 if seed>=28 and mode not in (25,27):B['font']=12+seed%8
 if seed>=56 and mode==9:A['strokeWidth']=.2
 if seed>=84 and mode==26:A['fills']=[dict(rect=[0,0,4,4],color=[10,10,10])]
 if seed>=112 and mode==0:B['mode']='rotated-panel'
 jobs.append(j)
for count in (3,12):
 j=copy.deepcopy(base);j['seed']=len(jobs);j['itemCount']=count
 j['members']=[dict(copy.deepcopy(a),id=str(i),box=[i*30,0,30,30],ink=[i*30+5,5,20,20],plate=[240,240,240] if i==0 else [10,10,10],fill=[10,10,10] if i==0 else [240,240,240]) for i in range(count)]
 jobs.append(j)
(OUT/'fixtures.json').write_text(json.dumps(jobs));subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeLetteringUnitPalette.swift'),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
w=json.loads((OUT/'web.json').read_text());n=json.loads((OUT/'native.json').read_text());fail=[]
for j,a,b in zip(jobs,w,n):
 if a!=b:fail.append(dict(seed=j['seed'],web=a,native=b))
r=dict(passed=not fail,cases=len(jobs),exact=len(jobs)-len(fail),positive=sum(bool(v['updates']) for v in w),foreignFillCases=sum(bool(m['fills']) for j in jobs for m in j['members']),failures=fail)
(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps({k:v for k,v in r.items() if k!='failures'}));print(json.dumps(fail[:2],indent=2));raise SystemExit(bool(fail))
