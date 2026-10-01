#!/usr/bin/env python3
"""Bounded source-image geometry/coverage policy proof, independent of rasterization."""
import hashlib,json,pathlib,random,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'build/native-render-parity/surface-geometry'
SRC=ROOT/'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'
NODE=r'''
const fs=require('fs'),vm=require('vm'),source=fs.readFileSync(process.argv[1],'utf8').replaceAll('\\\\','\\');
const start=source.indexOf('    function aidokuCleanupContentGeometry'),end=source.indexOf('    const cleanupImageGeometry',start);
const body=source.slice(start,end);
const begin=source.indexOf('    const aidokuRebaseCoverageClip'),finish=source.indexOf('    // Specks',begin);
const context=vm.createContext({CSS:{supports:()=>true}});vm.runInContext(body+'\n'+source.slice(begin,finish),context);
const fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const result=fixtures.map(f=>{
context.f=f;return vm.runInContext(`(()=>{
 const r={x:f.rect[0],y:f.rect[1],width:f.rect[2],height:f.rect[3]};
 const geometry=aidokuCleanupContentGeometry(r,...f.natural,f.style);
 const clip=aidokuCleanupClip(geometry,...f.probe), empty=clip==='inset(50%)';
 const insets=clip==='none'?[0,0,0,0]:empty?[50,50,50,50]:clip.slice(6,-1).split(' ').map(parseFloat);
 const plate={style:{clipPath:f.hasClip?'path(old)':'none'}};
 aidokuRebaseCoverageClip(plate,f.coverage,...f.origin);
 let coverage=null;if(f.hasClip){const tokens=plate.style.clipPath.match(/-?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)/g).map(Number);coverage=[];for(let i=0;i<tokens.length;i+=5)coverage.push(tokens.slice(i,i+4));}
 return {geometry,insets,empty,coverage};
})()`,context);
});process.stdout.write(JSON.stringify(result));
'''
def main():
 OUT.mkdir(parents=True,exist_ok=True)
 rng=random.Random(7913);fixtures=[]
 def add(**kw):
  f=dict(rect=[10,20,390,700],natural=[640,880],style={'transform':'none','objectFit':'contain','objectPosition':'50% 50%'},probe=[0,0,440,740],coverage=[[10,20,40,50],[80,90,30,25]],origin=[11,21],hasClip=True)
  f.update(kw);fixtures.append(f)
 for fit in ['fill','contain','cover','none','scale-down','']:
  for pos in ['left top','center center','right bottom','0% 100%','25.5% 77%','-10px 14.5px','-1% 50%','101% 1%','left','top left','calc(50%) 50%','+1px 0px','1e2px 0px','0px 0px']:
   add(style={'transform':'none','objectFit':fit,'objectPosition':pos})
 for key in ['borderLeftWidth','borderTopWidth','borderRightWidth','borderBottomWidth','paddingLeft','paddingTop','paddingRight','paddingBottom']:
  for v in ['0','0px','-0.0px',' 0.0e3foo','1px','auto','']:add(style={'transform':'none','objectFit':'cover',key:v})
 for probe in [[10,20,390,700],[12,24,100,120],[-10,0,410,720],[400,20,1,1],[10,720,1,1],[0,0,0,0],[-20,-30,10,10]]:add(probe=probe)
 for rect in [[0,0,0,5],[0,0,-3,10],[0,0,10,0]]:add(rect=rect)
 add(hasClip=False);add(style={'transform':'matrix(1,0,0,1,0,0)','objectFit':'fill'})
 for _ in range(240):
  rect=[rng.uniform(-100,100),rng.uniform(-100,100),rng.uniform(1,1000),rng.uniform(1,1000)]
  add(rect=rect,natural=[rng.randint(1,3000),rng.randint(1,3000)],style={'transform':'none','objectFit':rng.choice(['fill','contain','cover']),'objectPosition':f'{rng.randrange(101)}% {rng.randrange(101)}%'},probe=[rng.uniform(-150,150),rng.uniform(-150,150),rng.uniform(1,1300),rng.uniform(1,1300)],origin=[rng.uniform(-100,100),rng.uniform(-100,100)])
 data=json.dumps(fixtures).encode();(OUT/'fixtures.json').write_bytes(data)
 executable=OUT/'native'
 subprocess.run(['swiftc','-O','-swift-version','6',str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceSurfaceGeometry.swift'),str(ROOT/'Scripts/native-render-parity/SurfaceGeometryParityMain.swift'),'-o',str(executable)],check=True)
 native=json.loads(subprocess.check_output([str(executable)],input=data));web=json.loads(subprocess.check_output(['node','-e',NODE,str(SRC)],input=data))
 def compare(a,b,path):
  if isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool):
   if abs(a-b)>1e-9:raise AssertionError((path,a,b))
  elif type(a)!=type(b):raise AssertionError((path,a,b))
  elif isinstance(a,dict):
   if a.keys()!=b.keys():raise AssertionError((path,a,b))
   for k in a:compare(a[k],b[k],path+'.'+k)
  elif isinstance(a,list):
   if len(a)!=len(b):raise AssertionError((path,a,b))
   for i,(x,y) in enumerate(zip(a,b)):compare(x,y,f'{path}[{i}]')
  elif a!=b:raise AssertionError((path,a,b))
 failures=[]
 for i,(a,b) in enumerate(zip(native,web)):
  try:compare(a,b,str(i))
  except AssertionError as e:failures.append(str(e))
 report={'passed':not failures,'cases':len(fixtures),'matched':len(fixtures)-len(failures),'failures':failures,'referenceSHA256':hashlib.sha256(SRC.read_bytes()).hexdigest(),'numericAbsoluteTolerance':1e-9,'scope':'Geometry policy only; no raster or final-image equality claim.'}
 (OUT/'native.json').write_text(json.dumps(native,indent=2));(OUT/'web.json').write_text(json.dumps(web,indent=2));(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));raise SystemExit(bool(failures))
if __name__=='__main__':main()
