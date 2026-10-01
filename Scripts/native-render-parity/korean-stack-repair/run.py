#!/usr/bin/env python3
import copy,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/korean-stack-repair';OUT.mkdir(parents=True,exist_ok=True)
O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
source=(O/'NativeTypographyPostPolish.swift').read_text();(OUT/'NativeTypographyPostPolish.swift').write_text(source.split('    /// Frozen inspectSurface range')[0]+'}\n')
jobs=[]
for parts,unit in [(['카','나','반','칙'],False),(['쏘아','리'],False),(['카나','반칙','이다'],False),(['있습','니다'],True),(['두근','두근'],True),(['긴 ','한','글이다'],False)]:
 for mode in range(10):
  font=16.;at=0;rows=[];pitch=font*1.2;n=len(parts)
  for i,part in enumerate(parts):
   nonspace=[k for k,c in enumerate(part) if not c.isspace()];chars=part.strip();w=len(chars)*font*(1-.012)+font*.012
   rows.append(dict(first=at+nonspace[0],last=at+nonspace[-1],chars=chars,rect=[-w/2,-n*pitch/2+i*pitch+(pitch-font)/2,w/2,-n*pitch/2+i*pitch+(pitch+font)/2]));at+=len(part)
  j=dict(seed=len(jobs),text=''.join(parts),rows=rows,font=font,ratio=1.2,spacing=-.012,angle=0.,condense=1.,center=[100.,150.],nodeSize=[40.,n*pitch+4],frame=[0.,0.,200.,300.],sourceWidth=400.,unit=unit,calibration=1.,plates=[dict(own=True,rect=[20.,40.,160.,220.],color=[240.,240.,240.])],obstacleRects=[],background=[240,240,240,255],art=[],source=[.45,.4,.1,.2])
  if mode==1:j['plates']=[];j['source']=None
  if mode==2:j['art']=[[0,0,200,300,0,0,0,255]]
  if mode==3:j['obstacleRects']=[[60,130,80,40]]
  if mode==4:j['clip']=[94,100,12,100]
  if mode==5:j['plates'][0]['rect']=[88.,80.,24.,150.]
  if mode==6:j['sourceWidth']=100.
  if mode==7:j['calibration']=1.05
  if mode==8:j['angle']=.15
  if mode==9:j['condense']=.9;[r['rect'].__setitem__(k,r['rect'][k]*.9) for r in j['rows'] for k in (0,2)]
  jobs.append(j)
(OUT/'fixtures.json').write_text(json.dumps(jobs));subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json'),str(OUT/'web.json')],check=True)
subprocess.run(['swiftc','-O',str(O/'NativeTranslationTypography.swift'),str(OUT/'NativeTypographyPostPolish.swift'),str(O/'NativeSlantedGeometry.swift'),str(O/'NativeKoreanStackRepair.swift'),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
w=json.loads((OUT/'web.json').read_text());n=json.loads((OUT/'native.json').read_text());fail=[dict(seed=j['seed'],web=a,native=b) for j,a,b in zip(jobs,w,n) if a!=b]
r=dict(passed=not fail,cases=len(jobs),exact=len(jobs)-len(fail),positive=sum(v['repair'] is not None for v in w),declined=sum(v['declined'] is not None for v in w),failures=fail)
(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps({k:v for k,v in r.items() if k!='failures'}));print(json.dumps(fail[:1],indent=2)[:6000]);raise SystemExit(bool(fail))
