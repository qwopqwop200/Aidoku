#!/usr/bin/env python3
from pathlib import Path
import json,subprocess,math,random
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).parent;OUT=ROOT/'build/native-plate-growth-host';OUT.mkdir(parents=True,exist_ok=True)
def row(id,source,font,**kw):return dict(id=id,source=source,font=font,rect=[20+int(id)*60,20,40,25],**kw)
def grow(r,**kw):return dict(id=r['id'],source=r['source'],size=r['font'],maximum=r['font'],**kw)
jobs=[]
a=row('0',62.8856104367287,42.75);b=row('1',75.4224104626735,60.25)
jobs.append(dict(name='actual-SFX-grown-to60.25-cohort-to42.75',members=[a,b],growers=[grow(b),grow(a,inPlace=True)]))
for i in range(150):
 rows=[row(str(k),[6,9.9,10,20,40,75][i%6]*(1+k*.025),[9,16,32,42.75][(i+k)%4],sourceVertical=i%3==0,script='korean' if i%5 else 'word',style='B' if k==2 and i%7==0 else 'A',filled=k==1 and i%4==0,rotation=.2 if i%17==0 and k==0 else 0,near=.1 if i%23==0 and k==2 else 0) for k in range(4)]
 if i%11==0:rows[3]['rect']=[900,900,40,25]
 if i%13==0:rows[2]['visible']=False
 gs=[grow(rows[0],inPlace=True,strictFactor=.9 if i%2 else 1),grow(rows[1],extended=i%3==0,base=8 if i%3==0 else 0,interiorBase=12 if i%4==0 else None,gapLimit=14.25)]
 kept=[row('5',rows[0]['source'],min(32,rows[0]['source']*.9))] if i%9==0 else []
 jobs.append(dict(name='cohort-%03d'%i,members=rows,growers=gs,kept=kept))
(OUT/'cohort-fixtures.json').write_text(json.dumps(jobs))
subprocess.run(['swiftc','-O',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPlateGrowth.swift'),str(HERE/'PlateCohortMain.swift'),'-o',str(OUT/'cohort-check')],check=True)
subprocess.run([str(OUT/'cohort-check'),str(OUT/'cohort-fixtures.json'),str(OUT/'cohort-native.json')],check=True)
subprocess.run(['node',str(HERE/'plate-cohort-oracle.cjs'),str(HERE.parent/'reference-source'),str(OUT/'cohort-fixtures.json'),str(OUT/'cohort-web.json')],check=True)
a=json.loads((OUT/'cohort-native.json').read_text());b=json.loads((OUT/'cohort-web.json').read_text());fail=[dict(index=i,native=x,web=y) for i,(x,y) in enumerate(zip(a,b,strict=True)) if x!=y]
r=dict(cases=len(a),passed=not fail,matched=len(a)-len(fail),refits=sum(len(x['trace']) for x in a),differences=fail,scope='Complete unchanged frozen growers cohort block; live font mutations, source alignment/proximity/style cohorts, kept-font medians, readable hold, strict release fallback, extended style caps and final interior gap refits. Typed physical/plate-fit callbacks supplied; no platform raster claim.')
(OUT/'cohort-report.json').write_text(json.dumps(r,indent=2));print(json.dumps({k:v for k,v in r.items() if k!='differences'}));
if fail:print(json.dumps(fail[:2],indent=2));raise SystemExit(1)
