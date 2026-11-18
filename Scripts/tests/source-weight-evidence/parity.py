"""Actual bounded source packet -> native dictionary bridge, no full-page view."""
from pathlib import Path
import base64,json,sys,tempfile,subprocess,time,os,gzip,pickle
os.environ.setdefault('OMP_NUM_THREADS','1');os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
ROOT=Path(__file__).resolve().parents[3];sys.path[:0]=[str(ROOT/'Scripts/font_weight_estimation'),str(ROOT/'Scripts/font_size_estimation')]
import numpy as np
from active_weight_model import load_accepted_model
from font_metric_features import default_font_paths
from soft_ink_source import observe
from reference_ink_weight import measure
from segmented_ink_geometry import measure as eligibility
from color_consistent_ink import reconstruct
from directional_ink_rules import measure_source_page
from glyph_information import count
from fill_body import measure as fill_measure
from weight_bands import measure as bands_measure
b,_=load_accepted_model(ROOT/'Scripts/font_weight_estimation/assets/accepted-complete/model.pkl.gz');fonts=default_font_paths()
spec=dict(fonts=fonts,extendedFonts=fonts+fonts,nativeFonts=fonts)
probe=ROOT.parent/'font-weight-estimation-20261111/current-evidence-probe';records=[];expected=[]
for i in (0,1,2):
 with gzip.open(probe/f'source-context-{i}.pkl.gz','rb') as h:stored=pickle.load(h)
 packet=stored['packets'][0];em=float(stored['ems'][0]);rgb=packet['rgb'];evidence=packet['glyphEvidence'];h,w=rgb.shape[:2]
 def data(a,dtype=None):return base64.b64encode(np.asarray(a,dtype=dtype).tobytes()).decode()
 record=dict(width=w,height=h,rgb=data(rgb),ownership=data(packet['ownership'],np.uint8),valid=data(evidence['valid'],np.uint8),primary=data(evidence['primary'],np.float32),boundary=data(evidence['boundary'],np.float32),rf=data(evidence['rf'],np.float32),nativeMask=data(evidence['native'],np.uint8),bbox=packet['bbox'],prior=packet['prior'],text=packet['text'],style=packet['style'],sourceEm=em,measurementSpec=spec,memberPolygons=[],wordMembers=packet['wordMembers'],referenceInkPairs=b['referenceInkPairs'],includeOrdered=True,GTMaskUsed=False,inferenceUsesGT=False)
 alpha,known,_=reconstruct(rgb,packet['ownership'],packet['style'],evidence,em=em)
 reference=measure(rgb,packet['bbox'],em,packet['ownership'],packet['style'],b['referenceInkPairs'],packet['wordMembers'],alpha,known)
 reference={key:reference[key] for key in ['words','newModelCreated','modelTrainingPerformed']}
 geom=eligibility(rgb,packet['bbox'],em,packet['ownership'],packet['style'],evidence)
 policy=b['referenceInkAdditionalPolicies'][0]
 values={'reference':reference,'soft':observe(packet,em,b['referenceInkPairs'],include_ordered=True),'directional':measure_source_page([packet],[em],b['directionalInkPolicy'])[0],
 'eligibility':dict(stages=[{key:s[key] for key in ['pairedQuantiles','components']} for s in geom['stages']]),
 'information':dict(informativeGlyphs=count(packet['wordMembers'],policy['informationFont'],policy['minimumReferencePerimeterEm'])),
 'normalization':dict(fill71=fill_measure(rgb,packet['bbox'],em,packet['ownership'],packet['style'],version=1).tolist())}
 for kind,value in values.items():records.append(dict(record,kind=kind,policy=policy));expected.append(value)
start=time.monotonic()
with tempfile.TemporaryDirectory(prefix='aidoku-weight-evidence-') as temporary:
 temp=Path(temporary);vendor=ROOT/'Vendor/NativeSourceCV';source=ROOT/'Vendor/SourceInference'
 files=[Path(__file__).with_name('main.mm'),*[source/f for f in ['FontWeightSourceEvidence.mm','SourceWeightWordObservations.mm','SourceWeightOrderedGlyph.mm','SourceWeightReferenceGrid.mm','SourceWeightWordFit.mm','SourceWeightRegisteredProfile.mm','SourceWeightInk.mm','SourceWeightStrokeGeometry.mm','FontTemplateFeatures.mm','FontWeightBands.mm','FontWeightBandSource.mm','Sources/SourceWeightFeatures.cpp','Sources/SourceCoreFeatures.cpp']],vendor/'NativeSourceCV.cpp']
 command=['xcrun','clang++','-std=c++17','-O2','-fobjc-arc','-I'+str(source),'-I'+str(vendor/'include'),'-I'+str(vendor/'freetype/include'),*map(str,files),str(vendor/'opencv2.xcframework/macos-arm64/libopencv2.a'),str(vendor/'FreeType.xcframework/macos-arm64/libfreetype.a'),'-lz']
 for framework in ['Foundation','CoreText','CoreGraphics','Accelerate','CoreVideo','AVFoundation','CoreMedia','OpenCL']:command+=['-framework',framework]
 subprocess.run(command+['-o',str(temp/'check')],check=True);build=time.monotonic()-start
 (temp/'inputs.json').write_text(json.dumps(records));start=time.monotonic();subprocess.run([str(temp/'check'),str(temp/'inputs.json'),str(temp/'outputs.json')],check=True);runtime=time.monotonic()-start
 actual=json.loads((temp/'outputs.json').read_text())
maximum=0.
def check(a,b,path):
 global maximum
 if isinstance(a,dict):
  assert a.keys()==b.keys(),(path,a.keys(),b.keys())
  for key in a:check(a[key],b[key],path+'/'+key)
 elif isinstance(a,(list,tuple)):
  assert len(a)==len(b),(path,len(a),len(b))
  for i,(x,y) in enumerate(zip(a,b)):check(x,y,path+'/'+str(i))
 elif isinstance(a,(float,int,np.number)) and not isinstance(a,(bool,np.bool_)):
  maximum=max(maximum,abs(a-b));np.testing.assert_allclose(a,b,atol=3e-6,rtol=3e-6,err_msg=path)
 else:assert a==b,(path,a,b)
for i,(a,c) in enumerate(zip(expected,actual,strict=True)):check(a,c,str(i)+'/'+records[i]['kind'])
print(json.dumps(dict(passed=True,cases=len(records),maxAbsoluteError=maximum,buildSeconds=build,nativeSeconds=runtime,wholePagesViewed=False,modelTraining=False),indent=2))
