#!/usr/bin/env python3
import json,pathlib,subprocess,tempfile,math
here=pathlib.Path(__file__).resolve().parent;repo=here.parents[2];report=repo/'build/native-render-parity/joined-unit-containment';report.mkdir(parents=True,exist_ok=True)
rows=[]
for i in range(32):
 font=9+(i%5)*.5
 rows.append(dict(font=font,span=50+i%3*10,text='AB CD EF GH IJ' if i%3 else 'AB CD EF',initial=[28,18,30,80],centres=[[50,50],[48+i%3,52]],safe=[15+i%4,18,70-i%4*6,64-i%3*8],parent=[10,10,80,85] if i%2 else None,grow=i%4==0,sourceFont=font+2,obstacles=[[0,0,100,100]] if i%8==7 else [[50,20,8,8]] if i%6==5 else []))
for i in range(8):
 rows.append(dict(font=10,span=60,text='AB CD EF',initial=[0,0,30,80],centres=[[50,50],[48,52]],safe=[20,49,60,2+i],parent=None,grow=False,sourceFont=10,obstacles=[]))
with tempfile.TemporaryDirectory() as td:
 td=pathlib.Path(td);(td/'main.swift').write_text((here/'joined-driver.swift').read_text());(td/'fixtures.json').write_text(json.dumps(rows));binary=td/'native'
 subprocess.run(['swiftc',str(here/'NativeJoinedUnitContainment.swift'),str(td/'main.swift'),'-O','-o',str(binary)],check=True)
 native=json.loads(subprocess.check_output([str(binary),str(td/'fixtures.json')]))
 oracle=json.loads(subprocess.check_output(['node',str(here/'joined-oracle.cjs'),str(td/'fixtures.json'),str(repo/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift')]))
 def equal(a,b):
  if isinstance(a,(int,float)) and isinstance(b,(int,float)):return abs(a-b)<=1e-9
  if isinstance(a,dict) and isinstance(b,dict):return a.keys()==b.keys() and all(equal(a[k],b[k]) for k in a)
  if isinstance(a,list) and isinstance(b,list):return len(a)==len(b) and all(equal(x,y) for x,y in zip(a,b))
  return a==b
 differences=[dict(case=i,native=a,oracle=b) for i,(a,b) in enumerate(zip(native,oracle)) if not equal(a,b)]
 data=dict(cases=len(rows),exact=len(rows)-len(differences),accepted=sum(x['candidate'] is not None for x in oracle),partial=sum(x['partial'] for x in oracle),searched=sum(x['searched'] for x in oracle),differences=differences)
 (report/'report.json').write_text(json.dumps(data,indent=2));print(json.dumps({k:v for k,v in data.items() if k!='differences'}));assert not differences
