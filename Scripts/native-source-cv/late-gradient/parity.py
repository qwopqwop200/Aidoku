#!/usr/bin/env python3
"""Focused fresh synthetic/native late appearance parity; no app build/images."""
import sys,json,pickle,copy,subprocess,time
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[3]
sys.path[:0]=[str(ROOT/'Scripts/appearance_estimation'),str(ROOT/'Scripts/style_gt')]
import source_gradient_core as gradient
import native_gradient_contour as contour
import source_gradient_contour as late
import source_native_primary_quality as quality
from source_native_primary_features import pair_features
import source_outer_shell as shell
from test_source_gradient_contour import SourceGradientContourTests
from test_source_outer_shell import inputs as shell_inputs
OUT=ROOT/'build/native-source-late-gradient/fixtures';OUT.mkdir(parents=True,exist_ok=True)
HEADS=ROOT/'Aidoku/Resources/Translation/SourceModels'
POLICY=json.loads((HEADS/'appearance-metadata.json').read_text())['metadata']['tree']['appearance/policies']
THRESHOLD=POLICY['NATIVE-OUTER-SHELL-POLICY.json']['minimumExcessCoherence']
with (ROOT/'Scripts/appearance_estimation/assets/accepted/pixel-role-model.pkl').open('rb') as f:PIXEL=pickle.load(f)
CASES=[];GOLD=[]

def add(name,rgb,mask,arrays,geometry,prediction,shell_diagnostic=None):
    h,w=mask.shape;polygons=geometry.get('polygons') or [[[0,0],[w,0],[w,h],[0,h]]];geometry={**geometry,'polygons':polygons}
    rgb=np.asarray(rgb,np.uint8);mask=np.asarray(mask,np.uint8)
    arrays={k:np.asarray(v,np.float32) for k,v in arrays.items()}
    own=mask.astype(bool)
    row=dict(name=name,width=w,height=h,font=float(geometry['fontPixels']),prediction=prediction,polygons=polygons,mergedPolygon=__import__('cv2').convexHull(np.concatenate([np.asarray(p,np.float32) for p in polygons])).reshape(-1,2).tolist())
    values={'rgb':rgb,'rf':arrays['rf'],'mask':mask,'primary':arrays['segPrimary'],'boundary':arrays['segBoundary'],'ocr':arrays['ocr']}
    for key,value in values.items():
        relative=name+'.'+key;value.tofile(OUT/relative);row[key]=relative
    if shell_diagnostic is not None:row['shellDiagnostic']=shell_diagnostic
    from fused_source_appearance import extract
    packet=extract(rgb,own,arrays['rf'],arrays['segPrimary'],arrays['segBoundary'],polygons=polygons,font_pixels=geometry['fontPixels'],merged_polygon=__import__('cv2').convexHull(np.concatenate([np.asarray(p,np.float32) for p in polygons])).reshape(-1,2),ocr_maps=arrays['ocr'])
    options=quality.extract_candidates(rgb,own,prediction,polygons)
    features=[list(pair_features(prediction,options,j).values()) for j in range(3)]
    groups=gradient.select_components(gradient.propose(rgb,own,prediction,polygons,geometry['fontPixels']))
    measure=contour.measure(rgb,groups,geometry['fontPixels'])
    result,diagnostic=late.refine(rgb,own,arrays,geometry,prediction,PIXEL,packet)
    final,_=shell.refine(rgb,geometry,result,diagnostic,THRESHOLD)
    scores=quality.validate_artifacts()['model'].predict(np.asarray(features,dtype=np.float64)).tolist()
    gold=dict(name=name,options=options,features88=features,qualityScores=scores,gradientGroups=[len(g) for g in groups],gradientMeasure=measure,refined=final)
    if shell_diagnostic is not None:gold['shell']=shell.refine(rgb,geometry,prediction,shell_diagnostic,0.)[0]
    CASES.append(row);GOLD.append(gold)

tests=SourceGradientContourTests()
for name,kwargs in [('gradient',{}),('solid',{'gradient':False}),('no-ring',{'ring':False}),('mixed-hues',{'mixed':True})]:
    rgb,_,body=tests.source(**kwargs);h,w=body.shape;mask=np.any(rgb!=[235,180,205],axis=2)
    arrays=dict(rf=np.zeros((h,w,27),np.float32),segPrimary=mask.astype(np.float32),segBoundary=mask.astype(np.float32),ocr=np.ones((h,w,8),np.float32));arrays['rf'][:,:,15:17]=1
    p=dict(fillIndex=0,outlineIndex=1,backgroundIndex=2,fill=dict(rgb=[255,220,65],colors=[[255,220,65]],representation='source-fusion-observed-palette'),
      outline=dict(present=True,rgb=[200]*3,probability=.9,widthPx=2.7,widthRangePx=[1.5,3.9]),background=dict(rgb=[235,180,205],colors=[[235,180,205],[255]*3]),shadow=dict(present=False,rgb=None))
    add(name,rgb,mask,arrays,dict(fontPixels=70),copy.deepcopy(p))
    if name=='gradient':
        arr={**arrays,'rf':np.zeros_like(arrays['rf'])};add('unknown-source-owner',rgb,mask,arr,dict(fontPixels=70),copy.deepcopy(p))
        p['outline']['present']=False;add('outline-off',rgb,mask,arrays,dict(fontPixels=70),copy.deepcopy(p))
for kind in ['halo','white-background','partial-white','panel','soft-halo']:
    rgb,g,p,diagnostic=shell_inputs(kind);h,w=rgb.shape[:2];mask=np.any(rgb!=p['background']['rgb'],axis=2)
    arrays=dict(rf=np.zeros((h,w,27),np.float32),segPrimary=mask.astype(np.float32),segBoundary=mask.astype(np.float32),ocr=np.ones((h,w,8),np.float32));arrays['rf'][:,:,15:17]=1
    p['fill'].update(colors=[p['fill']['rgb']],representation='source-fusion-observed-palette')
    add('shell-'+kind,rgb,mask,arrays,g,p,diagnostic)
# White incumbent over repeated bright/native yellow interiors exercises late
# primary and pruning independently of the original ranker colour.
rgb,g,p,diagnostic=shell_inputs('white-background');h,w=rgb.shape[:2];mask=np.any(rgb!=255,axis=2)
arrays=dict(rf=np.zeros((h,w,27),np.float32),segPrimary=mask.astype(np.float32),segBoundary=mask.astype(np.float32),ocr=np.ones((h,w,8),np.float32));arrays['rf'][:,:,15:17]=1
p['fill'].update(rgb=[255]*3,colors=[[255]*3,[145,90,45],[10,11,12]],representation='source-fusion-observed-palette');p['background']['rgb']=[255]*3
add('bright-incumbent',rgb,mask,arrays,g,p,diagnostic)
# A source-derived, role-supported incumbent error exercises the actual frozen
# quality88 gate and replacement of only the primary palette slot.
rgb,g,p,diagnostic=shell_inputs('halo');h,w=rgb.shape[:2];mask=np.any(rgb!=p['background']['rgb'],axis=2)
arrays=dict(rf=np.zeros((h,w,27),np.float32),segPrimary=mask.astype(np.float32),segBoundary=mask.astype(np.float32),ocr=np.ones((h,w,8),np.float32));arrays['rf'][:,:,15:17]=1
p['fill'].update(rgb=[160,160,70],colors=[[160,160,70]],representation='source-fusion-observed-palette')
p['pixelRoleEvidence']={'samples':100,'roles':{role:{'meanProbability':.99,'confidentSamples':100,'observedColours':[{'rgb':color,'observedMass':.99}]} for role,color in [('fill',[245,215,90]),('outline',[145,90,45]),('background',[135,165,195])]}}
for role in ['fill','outline','background']:p[role].update(confidence=.8,probability=.9,candidateScores=[.1,.9])
add('quality-positive',rgb,mask,arrays,g,p,diagnostic)
# Fresh baseline ranker predictions from the supplied original crops/arrays.
# Never read cached appearance.json or row labels/predictions.
source=ROOT.parent/'font-size-estimation-20261110/round126/missing-source-styles/fresh-style-inference'
from fused_source_appearance import extract as fresh_extract
from source_appearance import predict as fresh_predict
with (ROOT/'Scripts/appearance_estimation/assets/accepted/model.pkl').open('rb') as stream:role_model=pickle.load(stream)
for key in ['source-0115-region-3','source-0049-region-4']:
 directory=source/'runtime'/key
 if not (directory/'evidence.npz').exists():continue
 with np.load(directory/'evidence.npz',allow_pickle=False) as evidence:
  arrays={k:evidence[k].astype(np.float32) for k in ['rf','segPrimary','segBoundary','ocr']}
  geometry=json.loads(str(evidence['geometryJSON']))
 h,w=arrays['segPrimary'].shape
 rgb=np.fromfile(source/'crops'/(key+'.rgb'),np.uint8).reshape(h,w,3)
 mask=np.fromfile(directory/'primary.u8',np.uint8).reshape(h,w)>0
 packet=fresh_extract(rgb,mask,arrays['rf'],arrays['segPrimary'],arrays['segBoundary'],polygons=geometry['polygons'],font_pixels=geometry['fontPixels'],ocr_maps=arrays['ocr'])
 prediction=fresh_predict(packet,role_model)
 add('real-'+key,rgb,mask,arrays,geometry,prediction)
(OUT/'INPUT.json').write_text(json.dumps(CASES,separators=(',',':')))
def clean(v):
 if isinstance(v,dict):return {str(k):clean(x) for k,x in v.items()}
 if isinstance(v,(list,tuple)):return [clean(x) for x in v]
 if isinstance(v,np.ndarray):return clean(v.tolist())
 if isinstance(v,np.generic):return clean(v.item())
 if isinstance(v,float) and not np.isfinite(v):return None
 return v
(OUT/'PYTHON.json').write_text(json.dumps(clean(GOLD),separators=(',',':')))
start=time.perf_counter();subprocess.run([str(ROOT/'build/native-source-late-gradient/late-gradient'),str(OUT),str(OUT/'NATIVE.json')],cwd=ROOT,check=True)
print('Native seconds',time.perf_counter()-start)
native=json.loads((OUT/'NATIVE.json').read_text());reports=[]
for expected,actual in zip(GOLD,native):
 name=expected['name'];f=np.asarray(actual['features88'],dtype=float);g=np.asarray(expected['features88'],dtype=float)
 np.testing.assert_array_equal(np.isnan(f),np.isnan(g),err_msg=name+' feature NaNs')
 np.testing.assert_allclose(actual['qualityScores'],expected['qualityScores'],rtol=0,atol=1e-10,err_msg=name+' frozen scores')
 delta=float(np.nanmax(abs(f-g)));np.testing.assert_allclose(f,g,rtol=0,atol=2e-4,equal_nan=True,err_msg=name+' features88')
 assert [x['nativeRGB'] for x in expected['options']]==[x['nativeRGB'] for x in actual['options']],(name,'native options')
 assert actual['gradientGroups']==expected['gradientGroups'],(name,'groups',actual['gradientGroups'],expected['gradientGroups'])
 for role in ['fill','outline','background','shadow']:
  for key in ['rgb','colors','present','widthPx','widthRangePx','observedLayers']:
   e=expected['refined'][role].get(key);a=actual['refined'][role].get(key)
   assert e==a,(name,role,key,e,a)
 assert actual['warm']==actual['refined'],(name,'warm idempotence')
 if 'shell' in expected:
  assert actual['shell']['outline'].get('observedLayers')==expected['shell']['outline'].get('observedLayers'),(name,'finite shell layers')
 reports.append(dict(name=name,maxFeature88Abs=delta,style='exact',warm='exact',gradientGroups='exact'))
report=dict(passed=True,cases=reports);(OUT/'PARITY.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
