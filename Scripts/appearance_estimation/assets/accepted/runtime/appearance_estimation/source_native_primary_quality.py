"""Late native source-primary selector. No labels, item IDs or study lookup at inference."""
import copy
import hashlib
import json
from pathlib import Path
import pickle
import sys
import numpy as np
import optimize_appearance  # optional host accelerators disabled before sklearn
from native_medoid import infer as native_infer
from native_core import infer as core_infer
from source_native_primary_features import pair_features, choose, CANDIDATES

VERSION='source-native-relative-primary-quality-v2-slot-only'
TAG='nativePrimaryQualityCorrection'
MODEL='native-primary-quality-model.pkl'
POLICY_FILE='NATIVE-PRIMARY-QUALITY-POLICY.json'
MODEL_SHA256='c1269096e10da34c1104d0b88eec2b63780a159ec1e74f0d64b81fb69120429a'
CONFIG=dict(max_leaf_nodes=15,min_samples_leaf=30,l2_regularization=30,max_iter=120,random_state=391,learning_rate=.1,early_stopping=False,loss='squared_error')
GATE=.1
_CACHE=None

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def unique_colours(values):
    result=[]
    for v in values:
        if not isinstance(v,list) or len(v)!=3 or any(type(c) is not int or c<0 or c>255 for c in v):raise ValueError('Invalid native primary RGB')
        if v not in result:result.append(copy.deepcopy(v))
    return result

def palette(new,old,previous):
    # Replace only the estimator's primary slot. Secondary entries are source-owned
    # observations: retain their ordering and multiplicity exactly.
    unique_colours([new,old]+previous)  # byte/RGB validation only; no dedup emission
    if previous and previous[0]!=old:raise ValueError('Native primary palette slot mismatch')
    return [copy.deepcopy(new)]+copy.deepcopy(previous[1:])

def validate_artifacts():
    global _CACHE
    root=Path(__file__).resolve().parent
    policy=json.loads((root/POLICY_FILE).read_text())
    if policy.get('version')!=VERSION or policy.get('modelSHA256')!=MODEL_SHA256 or policy.get('configuration')!=CONFIG or policy.get('gate')!=GATE or policy.get('candidateOrder')!=list(CANDIDATES):raise ValueError('Native primary frozen configuration mismatch')
    paths={root/name:expected for name,expected in policy['helperSHA256'].items()}
    paths[root/MODEL]=MODEL_SHA256
    signature=tuple((str(p),p.stat().st_size,p.stat().st_mtime_ns,p.stat().st_ctime_ns) for p in paths)
    if _CACHE is None or _CACHE[0]!=signature:
        if any(digest(p)!=expected for p,expected in paths.items()):raise ValueError('Native primary artifact/helper hash mismatch')
        for module in ('native_medoid','native_core','source_native_primary_features','source_appearance'):
            if Path(sys.modules[module].__file__).resolve()!=root/(module+'.py'):raise ValueError('Native primary module origin mismatch')
        with (root/MODEL).open('rb') as handle:bundle=pickle.load(handle)
        if bundle['gate']!=GATE or list(bundle['candidateOrder'])!=list(CANDIDATES) or len(bundle['featureNames'])!=88:raise ValueError('Native primary model schema mismatch')
        if any(bundle['model'].get_params()[k]!=v for k,v in CONFIG.items()):raise ValueError('Native primary HGB configuration mismatch')
        if bundle['freezeSHA256']!=policy['trainingFreezeSHA256']:raise ValueError('Native primary TRAIN-only freeze mismatch')
        import sklearn,scipy,cv2
        versions=dict(numpy=np.__version__,sklearn=sklearn.__version__,scipy=scipy.__version__,opencv=cv2.__version__)
        if versions!=policy['runtimeVersions']:raise ValueError('Native primary numeric runtime mismatch')
        _CACHE=(signature,bundle)
    return _CACHE[1]

def validate(tag,rgb=None):
    validate_artifacts()
    if not isinstance(tag,dict) or tag.get('version')!=VERSION or tag.get('modelSHA256')!=MODEL_SHA256 or tag.get('gate')!=GATE:raise ValueError('Invalid native primary provenance')
    unique_colours([tag.get('previousRGB'),tag.get('newRGB')]+tag.get('previousColors',[]))
    if tag.get('newRGB')==tag.get('previousRGB') or type(tag.get('previousColorsPresent')) is not bool:raise ValueError('Invalid native primary change')
    if tag.get('emittedColors')!=palette(tag['newRGB'],tag['previousRGB'],tag['previousColors']):raise ValueError('Invalid native primary palette provenance')
    e=tag.get('sourceEvidence',{})
    score=e.get('predictedImprovement')
    if e.get('candidateIndex') not in (1,2,3) or not isinstance(score,(int,float)) or not np.isfinite(score) or score<GATE:raise ValueError('Invalid native primary learned gate')
    xy=e.get('nativeXY')
    if not isinstance(xy,list) or len(xy)!=2 or any(type(v) is not int or v<0 for v in xy):raise ValueError('Invalid native primary witness')
    if rgb is not None:
        x,y=xy
        if x>=rgb.shape[1] or y>=rgb.shape[0] or rgb[y,x].tolist()!=tag['newRGB'] or hashlib.sha256(rgb.tobytes()).hexdigest()!=e.get('nativeRGBSHA256'):raise ValueError('Native primary RGB/witness mismatch')

def restore_baseline(prediction):
    """Peel this last mutation before interior pruning / certified bright restoration."""
    out=copy.deepcopy(prediction);fill=out['fill'];prior=fill.get(TAG)
    if prior is None:return out
    validate(prior)
    if fill.get('rgb')!=prior['newRGB'] or fill.get('colors')!=prior['emittedColors']:raise ValueError('Tampered warm native primary output')
    fill['rgb']=copy.deepcopy(prior['previousRGB'])
    if prior['previousColorsPresent']:fill['colors']=copy.deepcopy(prior['previousColors'])
    else:fill.pop('colors',None)
    del fill[TAG]
    return out

def extract_candidates(rgb,mask,prediction,polygons):
    colour,evidence=native_infer(rgb,mask,prediction,polygons)
    core=core_infer(rgb,mask,prediction,polygons)
    return [dict(nativeRGB=colour,evidence=evidence),core['core1.0-shift0.0'],core['core1.5-shift0.0']]

def attach(rgb,mask,geometry,prediction):
    """Pure returned-copy attach from native source; no files except frozen model/code."""
    bundle=validate_artifacts();out=restore_baseline(prediction)
    options=extract_candidates(rgb,mask,out,geometry.get('polygons') or [])
    records=[pair_features(out,options,j) for j in range(3)]
    if any(list(v)!=bundle['featureNames'] for v in records):raise ValueError('Native primary source feature schema changed')
    x=np.array([[v[n] for n in bundle['featureNames']] for v in records],float)
    scores=bundle['model'].predict(x).reshape(1,3)
    available=np.array([[v['nativeRGB'] is not None for v in options]])
    selected=int(choose(scores,available,GATE)[0])
    report=dict(version=VERSION,GTAtInference=False,candidateIndex=selected,gate=GATE,predictedImprovements=[float(v) for v in scores[0]],available=available[0].tolist(),applied=False)
    if not selected:return out,report
    colour=options[selected-1]['nativeRGB'];fill=out['fill']
    if colour==fill['rgb']:return out,dict(report,reason='same-primary-rgb')
    previous=copy.deepcopy(fill.get('colors',[]));old=list(fill['rgb']);colours=palette(colour,old,previous)
    tag=dict(version=VERSION,modelSHA256=MODEL_SHA256,gate=GATE,previousRGB=old,previousColorsPresent='colors' in fill,previousColors=previous,newRGB=copy.deepcopy(colour),emittedColors=colours,
             sourceEvidence=dict(candidateIndex=selected,predictedImprovement=float(scores[0,selected-1]),nativeXY=options[selected-1]['evidence']['nativeXY'],nativeRGBSHA256=hashlib.sha256(rgb.tobytes()).hexdigest(),predictedMaskSHA256=hashlib.sha256(mask.tobytes()).hexdigest(),featureVectorSHA256=hashlib.sha256(x.tobytes()).hexdigest()))
    validate(tag,rgb)
    fill.update(rgb=copy.deepcopy(colour),colors=colours)
    fill[TAG]=tag
    return out,dict(report,applied=True)
