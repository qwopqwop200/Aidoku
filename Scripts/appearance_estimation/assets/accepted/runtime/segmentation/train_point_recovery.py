"""TRAIN-only source-pixel tail correction; no extra mask dilation or GT lookup."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time

import cv2
import joblib
import numpy as np
from PIL import Image
from sklearn.ensemble import HistGradientBoostingClassifier

from audit_kernel_free_completion import component_candidates
from boundary_refiner import source_features
from evaluate_gt import read,save,sha
from source_boundary_votes import SourceBoundaryVotes
from train_edge_boundary import edge_features,EDGE_NAMES

cv2.setNumThreads(1)
CONTEXT=None


def initialize(root):
    global CONTEXT
    root=Path(root);best=read(root/'BEST-RESULT.json')
    CONTEXT=(root,(root/best['modelPackage']).parent,
        SourceBoundaryVotes(root/'boundary-lean',root/'deep-classifier-observations',root/'edge-context60-native',root/'edge-context60-observations'))


def features_and_base(row):
    root,native,votes=CONTEXT
    inputs={k:row[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']}
    features,names,_=source_features(inputs,root/'boundary-lean',root/'deep-classifier-observations',rich=True)
    _,q,_=votes.load(inputs);rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
    features=np.concatenate([features,edge_features(rgb,row['fontPixels']),q.reshape(-1,1)],axis=1)
    mask=np.fromfile(native/'native-masks'/f'{row["id"]}.u8',np.uint8).reshape(q.shape)
    base=component_candidates(mask)['fillHoles']>0
    return features,base,names+EDGE_NAMES+['boundaryProbability']


def training_sample(payload):
    row,ordinal=payload;features,base,names=features_and_base(row)
    if row['split']!='train' or sha(row['target'])!=row['targetSHA256']:raise ValueError('TRAIN/source contract changed')
    gt=np.asarray(Image.open(row['target']))>0
    positive=np.flatnonzero((gt&~base).ravel());negative=np.flatnonzero((~gt&~base).ravel())
    rng=np.random.default_rng(20261109+ordinal)
    uniform=rng.choice(negative,min(512,len(negative)),replace=False)
    weak=negative[(features[negative,0]>0)|(features[negative,-1]>0)]
    hard=rng.choice(weak,min(512,len(weak)),replace=False)
    positions=np.unique(np.concatenate([positive,uniform,hard]));return features[positions],gt.ravel()[positions],names,len(positive)


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--jobs',type=int,default=4);args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    rows=[r for r in read(args.root/'boundary-lean/evaluation-manifest.json')['items'] if r['split']=='train'];start=time.monotonic()
    parts=[];labels=[];positive=0;names=None
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(args.root.resolve(),)) as pool:
        for i,(x,y,names,n) in enumerate(pool.map(training_sample,[(r,i) for i,r in enumerate(rows)],chunksize=4)):
            parts.append(x);labels.append(y);positive+=n
            if (i+1)%400==0:print(f'Point recovery TRAIN {i+1}/{len(rows)}',flush=True)
    x=np.concatenate(parts);y=np.concatenate(labels);del parts,labels
    save(args.out/'TRAINING-PROTOCOL.json',dict(trainInstances=len(rows),samples=len(y),allMissedTrainPixels=positive,
        featureNames=names,featureCount=len(names),trainOnly=True,DEVOrTestUsedForTraining=False,
        sourcePixelsAndRF=True,newCNN=False,GTAtInference=False,pageIdentityFeatures=False,
        extraDilationKernel=False,foregroundWeight=50,maximumLeaves=15,iterations=128,
        sourceManifestSHA256=sha(args.root/'boundary-lean/evaluation-manifest.json')))
    model=HistGradientBoostingClassifier(max_iter=128,max_leaf_nodes=15,min_samples_leaf=64,
        l2_regularization=10,learning_rate=.1,max_bins=64,early_stopping=False,random_state=20261109)
    print(f'Fitting point recovery {x.shape}, positives={int(y.sum())}',flush=True)
    model.fit(x,y,sample_weight=np.where(y,50.,1.));joblib.dump(model,args.out/'model.joblib',compress=3)
    trees=[]
    for stage in model._predictors:
        if len(stage)!=1:raise ValueError('Binary model expected')
        nodes=[]
        for node in stage[0].nodes:
            if node['is_categorical']:raise ValueError('Categorical features are forbidden')
            nodes.append(dict(feature=-1 if node['is_leaf'] else int(node['feature_idx']),threshold=float(node['num_threshold']),
                left=int(node['left']),right=int(node['right']),value=float(node['value'])))
        trees.append(nodes)
    save(args.out/'point-recovery-model.json',dict(schema=1,featureNames=names,featureCount=61,
        intercept=float(model._baseline_prediction.ravel()[0]),trees=trees,sourceOnly=True,extraDilationKernel=False))
    save(args.out/'TRAINING-RESULT.json',dict(seconds=time.monotonic()-start,modelSHA256=sha(args.out/'point-recovery-model.json'),
        TRAINOnly=True,fullCorpusEvaluationPending=True));print('Point recovery trained',flush=True)


if __name__=='__main__':main()
