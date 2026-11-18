"""Existing bounded source contexts -> real native heads/measurements/orchestration.

The boundary shell retains supplied source ems (font estimation is not rerun).
No weight labels or previous decisions enter the native executable.
"""
from pathlib import Path
import sys,json,gzip,pickle,base64,subprocess,tempfile,time,os
os.environ.setdefault('OMP_NUM_THREADS','1');os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
ROOT=Path(__file__).resolve().parents[3];sys.path[:0]=[str(ROOT/'Scripts/font_weight_estimation'),str(ROOT/'Scripts/font_size_estimation')]
import numpy as np
from active_weight_model import load_accepted_model
from active_model import resolve_default_model
from estimator import load_model
from physical_templates import font_pairs
b,_=load_accepted_model(ROOT/'Scripts/font_weight_estimation/assets/accepted-complete/model.pkl.gz')
font=load_model(resolve_default_model());spec={key:font['optimizedGraph']['measurementSpec'][key] for key in ['fonts','extendedFonts','nativeFonts']}
physical=[[dict(path=a,faceIndex=ai),dict(path=c,faceIndex=ci)] for a,ai,c,ci in font_pairs()]
probe=ROOT.parent/'font-weight-estimation-20261111/current-evidence-probe';batches=[]
sources=[('0030',probe/'source-context-0.pkl.gz'),('0511',probe/'source-context-1.pkl.gz'),('0637',probe/'source-context-2.pkl.gz'),('0744',probe/'mixed/source-context-0.pkl.gz')]
for page,source_file in sources:
 with gzip.open(source_file,'rb') as f:v=pickle.load(f)
 rows=[]
 for p,em in zip(v['packets'],v['ems']):
  h,w=p['rgb'].shape[:2];g=p['glyphEvidence']
  def data(value,dtype=None):return base64.b64encode(np.asarray(value,dtype=dtype).tobytes()).decode()
  rows.append(dict(width=w,height=h,rgb=data(p['rgb']),ownership=data(p['ownership'],np.uint8),valid=data(g['valid'],np.uint8),primary=data(g['primary'],np.float32),boundary=data(g['boundary'],np.float32),rf=data(g['rf'],np.float32),nativeMask=data(g['native'],np.uint8),bbox=p['bbox'],prior=p['prior'],text=p['text'],style=p['style'],sourceEm=float(em),measurementSpec=spec,memberPolygons=[],wordMembers=p['wordMembers'],referenceInkPairs=b['referenceInkPairs'],referencePairs=b['referencePairs'],physicalFontPairs=physical,sourceAngle=0.,GTMaskUsed=False,inferenceUsesGT=False))
 batches.append(dict(page=page,packets=rows))
ensemble=ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
names=['NativeAppearanceForest.swift','NativeFrozenSourceModel.swift','NativeSourceFontGraphMath.swift','NativeSourceWeightGraph.swift','NativeSourceWeightImagePolicy.swift','NativeSourceWeightFontResources.swift','NativeSourceFontResolver.swift','NativeAcceptedSourceWeightInference.swift']
start=time.monotonic()
with tempfile.TemporaryDirectory(prefix='aidoku-weight-source-pipeline-') as temporary:
 out=Path(temporary);(out/'request.json').write_text(json.dumps(batches))
 (out/'CV.swift').write_text((ensemble/'NativeOpenCVImageOperations.swift').read_text().split('struct NativeOpenCVAppearanceImageOperations:')[0])
 cache=ROOT/'build/native-source-cv-host'
 command=['xcrun','swiftc','-O','-parse-as-library','-module-cache-path',str(out/'modules'),'-I',str(ROOT/'Vendor/NativeSourceCV/include'),*map(str,[ensemble/name for name in names]),str(Path(__file__).with_name('Replay.swift')),str(out/'CV.swift'),'-L',str(cache),'-lAidokuSourceCV','-lAidokuOpenCV','-lAidokuFreeType','-lc++','-lz']
 for framework in ['Foundation','CoreText','CoreGraphics','Accelerate','CoreVideo','AVFoundation','CoreMedia','OpenCL']:command+=['-framework',framework]
 subprocess.run(command+['-o',str(out/'replay')],check=True);build=time.monotonic()-start;start=time.monotonic()
 subprocess.run([str(out/'replay'),str(ROOT/'Aidoku/Resources/Translation/SourceModels'),str(ROOT/'Aidoku/Resources/Translation/SourceReferenceFonts.bundle'),str(out/'request.json'),str(out/'reply.json')],check=True)
 replies=json.loads((out/'reply.json').read_text());elapsed=time.monotonic()-start
expected=json.loads((ROOT.parent/'font-weight-estimation-20261111/operational-glyph-confirmation12/PREDICTIONS.json').read_text())['items'];expected={(r['page'],r['id']):r for r in expected}
errors=[];total=0;maximum=0.
for batch,reply in zip(batches,replies,strict=True):
 assert len(batch['packets'])==len(reply['rows'])
 with gzip.open(dict(sources)[batch['page']],'rb') as f:packets=pickle.load(f)['packets']
 for p,value in zip(packets,reply['rows'],strict=True):
  target=expected[(batch['page'],p['sourceRegionID'])];total+=1
  for key in ['sourceWeight','renderBold']:
   if value[key]!=target[key]:errors.append(dict(page=batch['page'],region=p['sourceRegionID'],key=key,actual=value[key],expected=target[key]))
  for key in ['boldScore','polarityRescueScore','stemRescueScore']:
   maximum=max(maximum,abs(value[key]-target[key]));np.testing.assert_allclose(value[key],target[key],atol=1e-9,rtol=1e-9)
print(json.dumps(dict(passed=not errors,errors=errors,pages=len(batches),owners=total,maxScoreError=maximum,compileSeconds=build,executionSeconds=elapsed,freshFontEstimation=False,actualNativeHeads=True,actualNativeMeasurements=True,GTAtInference=False,wholePagesViewed=False),indent=2))
assert not errors
