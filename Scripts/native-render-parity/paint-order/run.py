#!/usr/bin/env python3
import json,pathlib,random,subprocess,tempfile
here=pathlib.Path(__file__).resolve().parent
repo=here.parents[2]
report=repo/'build/native-render-parity/paint-order';report.mkdir(parents=True,exist_ok=True)
rng=random.Random(11965)
def quad(r):
 x,y,w,h=r;return [[x,y],[x+w,y],[x+w,y+h],[x,y+h]]
rows=[]
for case in range(160):
 layers=[];nodes=[]
 count=3+case%4
 for i in range(count):
  r=[rng.randrange(0,18),rng.randrange(0,18),rng.randrange(4,30),rng.randrange(4,30)]
  plate=i%3==case%3
  if plate:layers.append(dict(id=f'p{i}',z=1,order=float(i),quad=quad(r),coverage=[r],usesQuad=True,opaque=True,shown=True,background=[255,255,255] if case%2 else [17,18,23],kind='source-rotated-panel',owner=f'n{i}'))
  g=[r[0]+1,r[1]+1,max(1,r[2]-2),max(1,r[3]-2)]
  nl=dict(id=f'n{i}',z=2,order=float(i+count),quad=quad(r),coverage=[r],usesQuad=True,opaque=(case+i)%5==0,shown=True,background=[255,255,255],kind='item')
  layers.append(nl)
  nodes.append(dict(id=f'n{i}',layerID=f'n{i}',glyphs=[g],quad=quad(r),isRoot=True,opaque=nl['opaque'],rotatingPanel=plate,ownRotatedPlate=f'p{i}' if plate else None,foreground=[17,18,23] if case%2 else [255,255,255]))
  if (case+i)%2==0:
   pr=[r[0]+2,r[1]+2,r[2],r[3]]
   layers.append(dict(id=f's{i}',z=2,order=float(i+count*2),quad=quad(pr),coverage=[pr],usesQuad=False,opaque=True,shown=(case+i)%11!=0,background=[255,255,255],kind='source-readability-panel'))
 rows.append(dict(layers=layers,nodes=nodes,count=257 if case==159 else count))
with tempfile.TemporaryDirectory() as td:
 td=pathlib.Path(td); fixtures=td/'fixtures.json';fixtures.write_text(json.dumps(rows));main=td/'main.swift';main.write_text((here/'driver.swift').read_text());binary=td/'native'
 subprocess.run(['swiftc',str(repo/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPaintOrder.swift'),str(main),'-o',str(binary)],check=True)
 native=json.loads(subprocess.check_output([str(binary),str(fixtures)]))
 oracle=json.loads(subprocess.check_output(['node',str(here/'oracle.cjs'),str(fixtures),str(repo/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift')]))
 differences=[dict(case=i,native=a,oracle=b) for i,(a,b) in enumerate(zip(native,oracle)) if a!=b]
 data=dict(cases=len(rows),exact=len(rows)-len(differences),positive=sum(x['lifted']>0 for x in oracle),lifted=sum(x['lifted'] for x in oracle),blocked=sum(n['lift']=='blocked' for x in oracle for n in x['nodes']),differences=differences)
 (report/'report.json').write_text(json.dumps(data,indent=2));print(json.dumps({k:v for k,v in data.items() if k!='differences'}));assert not differences
