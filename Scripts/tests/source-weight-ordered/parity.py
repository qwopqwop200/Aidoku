"""Ordered glyph source-only Python/native parity, private standalone build."""
from pathlib import Path
import base64,json,sys,tempfile,subprocess,time,os,gzip,pickle
os.environ.setdefault('OMP_NUM_THREADS','1');os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
ROOT=Path(__file__).resolve().parents[3]
sys.path[:0]=[str(ROOT/'Scripts/font_weight_estimation'),str(ROOT/'Scripts/font_size_estimation')]
import numpy as np,cv2
from active_weight_model import load_accepted_model
from reference_ink_weight import reference_pairs
from reference_grid import masks
from ordered_glyph_ink import measure
from registered_stroke_evidence import profile
from soft_stroke_profile import profile as soft
bundle,_=load_accepted_model(ROOT/'Scripts/font_weight_estimation/assets/accepted-complete/model.pkl.gz')
records=[];expected=[]
def add(alpha,known,text,vertical,family,unit,is_soft=True):
 alpha=np.asarray(alpha,np.float32);known=np.asarray(known,bool)
 result=measure(alpha,known,text,vertical,family,unit,profile_fn=soft if is_soft else profile)
 record=dict(width=alpha.shape[1],height=alpha.shape[0],alpha=base64.b64encode(alpha.tobytes()).decode(),known=base64.b64encode(known.astype('uint8').tobytes()).decode(),text=text,vertical=vertical,family=family,unit=unit,soft=is_soft)
 records.append(record);expected.append(result)
for family in reference_pairs(bundle['referenceInkPairs']):
 for vertical,text in [(False,'Oh!'),(False,'スイレン'),(True,'「あっ日」')]:
  base=masks(family,text,vertical)
  if base is None:continue
  for is_soft in [False,True]:
   raster=cv2.resize(base[1],None,fx=.3,fy=.3,interpolation=cv2.INTER_AREA)
   raster=np.pad(raster,((5,5),(5,5)));known=np.ones(raster.shape,bool)
   add(raster,known,text,vertical,family,128*.3,is_soft)
# Actual existing bounded word arrays; no page image is opened or displayed.
probe=ROOT.parent/'font-weight-estimation-20261111/current-evidence-probe'
if probe.exists():
 import ordered_glyph_ink,soft_ink_source
 original=ordered_glyph_ink.measure
 def capture(a,k,t,v,f,u,profile_fn=profile):
  add(a,k,t,v,f,u,profile_fn is soft)
  return original(a,k,t,v,f,u,profile_fn=profile_fn)
 ordered_glyph_ink.measure=capture
 for i in (0,2):
  with gzip.open(probe/f'source-context-{i}.pkl.gz','rb') as h:packet=pickle.load(h)
  soft_ink_source.observe(packet['packets'][0],packet['ems'][0],bundle['referenceInkPairs'],include_ordered=True)
 ordered_glyph_ink.measure=original
family=reference_pairs(bundle['referenceInkPairs'])[0]
for shape,text in [((9,12),'aaaaaaa'),((20,60),'あA')]:add(np.zeros(shape,np.float32),np.ones(shape,bool),text,False,family,20)
start=time.monotonic()
with tempfile.TemporaryDirectory(prefix='aidoku-ordered-') as temporary:
 temp=Path(temporary);vendor=ROOT/'Vendor/NativeSourceCV';source=ROOT/'Vendor/SourceInference'
 files=[Path(__file__).with_name('main.mm'),source/'SourceWeightOrderedGlyph.mm',source/'SourceWeightReferenceGrid.mm',source/'SourceWeightWordFit.mm',source/'SourceWeightRegisteredProfile.mm',vendor/'NativeSourceCV.cpp']
 command=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(source),'-I'+str(vendor/'include'),'-I'+str(vendor/'freetype/include'),*map(str,files),str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),str(vendor/'FreeType.xcframework/macos-arm64/libfreetype.a'),'-lz']
 for framework in ['Foundation','CoreText','CoreGraphics','Accelerate','CoreVideo','AVFoundation','CoreMedia','OpenCL']:command+=['-framework',framework]
 subprocess.run(command+['-o',str(temp/'check')],check=True)
 build=time.monotonic()-start
 (temp/'inputs.json').write_text(json.dumps(records));start=time.monotonic()
 subprocess.run([str(temp/'check'),str(temp/'inputs.json'),str(temp/'outputs.json')],check=True)
 actual=json.loads((temp/'outputs.json').read_text());runtime=time.monotonic()-start
maximum=0.
def check(a,b,path):
 global maximum
 if isinstance(a,dict):
  assert a.keys()==b.keys(),(path,a.keys(),b.keys())
  for key in a:check(a[key],b[key],path+'/'+key)
 elif isinstance(a,list):
  assert len(a)==len(b),(path,len(a),len(b))
  for i,(x,y) in enumerate(zip(a,b)):check(x,y,path+'/'+str(i))
 elif isinstance(a,(float,int)) and not isinstance(a,bool):
  maximum=max(maximum,abs(a-b));np.testing.assert_allclose(a,b,atol=2e-6,rtol=2e-6,err_msg=path)
 else:assert a==b,(path,a,b)
assert len(actual)==len(expected)
for i,(a,b) in enumerate(zip(expected,actual)):check(a,b,str(i))
print(json.dumps(dict(passed=True,cases=len(records),maxAbsoluteError=maximum,buildSeconds=build,nativeSeconds=runtime,wholePagesViewed=False,modelTraining=False),indent=2))
