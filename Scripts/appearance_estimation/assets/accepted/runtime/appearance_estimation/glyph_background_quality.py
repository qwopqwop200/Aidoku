"""Frozen relative background comparator, using source features and no identities."""
import hashlib
from pathlib import Path
import numpy as np
from source_local_background_fusion import FEATURE_NAMES as BASE_NAMES
from glyph_background import FEATURE_NAMES as GLYPH_NAMES,VERSION as SOURCE_VERSION

VERSION='source-glyph-background-relative-quality-v1'
GATE=.95
SOURCE_NAMES=tuple(BASE_NAMES)+tuple('glyph.'+n for n in GLYPH_NAMES)
FEATURE_NAMES=tuple(p+n for p in ('xA.','xB.','BminusA.','absBminusA.') for n in SOURCE_NAMES)
CONFIG=dict(max_leaf_nodes=31,min_samples_leaf=60,l2_regularization=30,max_iter=120,
            learning_rate=.1,early_stopping=False,random_state=463)

def helper_hashes():
    root=Path(__file__).parent
    return {n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in ('glyph_background.py','glyph_background_quality.py')}

def validate(model):
    expected=dict(version=VERSION,sourceVersion=SOURCE_VERSION,sourceFeatureCount=126,
        featureCount=504,gate=GATE,configuration=CONFIG,helperSHA256=helper_hashes())
    if not isinstance(model,dict) or any(model.get(k)!=v for k,v in expected.items()):raise ValueError('Glyph background frozen policy mismatch')
    if tuple(model.get('sourceFeatureNames',()))!=SOURCE_NAMES or tuple(model.get('featureNames',()))!=FEATURE_NAMES:raise ValueError('Glyph background source feature schema mismatch')
    clf=model.get('classifier')
    if getattr(clf,'n_features_in_',None)!=504 or not np.array_equal(getattr(clf,'classes_',None),[0,1]):raise ValueError('Expected binary504-feature glyph quality classifier')
    if any(clf.get_params().get(k)!=v for k,v in CONFIG.items()):raise ValueError('Glyph background classifier configuration changed')

def pair(a,b):
    a=np.asarray(a,np.float32);b=np.asarray(b,np.float32);delta=b-a
    return np.column_stack([a,b,delta,np.abs(delta)]).astype(np.float32)

def choose(colours,source,baseline,observed,model):
    validate(model);x=np.asarray(source,np.float32);rgb=np.asarray(colours)
    if x.ndim!=2 or x.shape[1]!=126 or len(x)==0 or not np.isfinite(x).all():raise ValueError('Expected finite Nx126 source matrix')
    if rgb.shape!=(len(x),3) or not np.isfinite(rgb).all() or np.any(rgb<0) or np.any(rgb>255):raise ValueError('Invalid existing background palette')
    if isinstance(baseline,(bool,np.bool_)) or not isinstance(baseline,(int,np.integer)) or not 0<=baseline<len(x):raise ValueError('Invalid V3 baseline index')
    report=dict(version=VERSION,sourceVersion=SOURCE_VERSION,sourceOnly=True,GTAtInference=False,
        baselineIndex=int(baseline),minimumRelativeProbability=GATE,anchorsObserved=bool(observed))
    if not observed:return int(baseline),dict(report,chosenIndex=int(baseline),thresholdPassed=False,reason='No joint source glyph anchors')
    a=np.repeat(x[baseline:baseline+1],len(x),axis=0);clf=model['classifier']
    forward=np.asarray(clf.predict_proba(pair(a,x)));reverse=np.asarray(clf.predict_proba(pair(x,a)))
    if forward.shape!=(len(x),2) or reverse.shape!=forward.shape or not np.isfinite(forward).all() or not np.isfinite(reverse).all() or np.any(forward<0) or np.any(forward>1) or np.any(reverse<0) or np.any(reverse>1):raise ValueError('Invalid glyph relative probabilities')
    q=(forward[:,1]+1-reverse[:,1])/2;q[baseline]=.5;proposal=int(q.argmax());accepted=bool(q[proposal]>=GATE)
    chosen=proposal if accepted else int(baseline)
    return chosen,dict(report,proposalIndex=proposal,chosenIndex=chosen,thresholdPassed=accepted,
        relativeQualityProbabilities=q.tolist(),proposalRelativeProbability=float(q[proposal]),
        baselineSemantics='Frozen V3 choice; glyph-near comparator is a separate final choice')
