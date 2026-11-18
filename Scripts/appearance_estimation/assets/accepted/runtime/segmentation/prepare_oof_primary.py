#!/usr/bin/env python3
"""Train-source cross fitting for contextual segmentation calibration.

Each TRAIN crop is predicted by a teacher that excluded its entire decoded
source group. DEV and test do not enter teacher fitting or these predictions.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
from pathlib import Path
import tempfile
import time

import cv2
import numpy as np

from evaluate_gt import read,save,sha
from pixel_rfdetr_fusion import sample_training_case,fit_forest,feature_planes,merge_forests

cv2.setNumThreads(1)


def source_fold(group):
    return int(hashlib.sha256(group.encode()).hexdigest()[:8],16)%3


def fit_fold(payload):
    scratch,out,fold,shard,trees,depth,minimum_samples=payload;scratch=Path(scratch);out=Path(out)
    x=np.load(scratch/'features.npy',mmap_mode='r');y=np.load(scratch/'labels.npy',mmap_mode='r')
    folds=np.load(scratch/'folds.npy',mmap_mode='r');keep=folds!=fold
    model=fit_forest(x[keep],y[keep],trees,depth,minimum_samples,20261109+fold*100+shard)
    path=out/f'fold-{fold}-shard-{shard}.json';model.save(str(path))
    print(f'OOF teacher {fold} shard {shard}: {int(keep.sum())} pixels, {trees} trees complete',flush=True)
    return str(path)


_MODELS={}


def predict_case(payload):
    row,base,out,fold=payload;out=Path(out)
    if fold not in _MODELS:_MODELS[fold]=cv2.ml.RTrees_load(str(out/f'fold-{fold}.json'))
    features,_=feature_planes(row,Path(base)/'baseline',True)
    result=np.empty(len(features),np.float32)
    for start in range(0,len(features),65536):
        votes=_MODELS[fold].getVotes(features[start:start+65536],0)
        positive=np.flatnonzero(votes[0]==1).item()
        result[start:start+len(votes)-1]=votes[1:,positive]/votes[1:].sum(1)
    np.savez_compressed(out/'probabilities'/f'{row["id"]}.npz',
        probability=result.reshape(row['height'],row['width']).astype(np.float16),fold=np.int32(fold))
    return row['id']


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--base',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--trees',type=int,default=12)
    parser.add_argument('--depth',type=int,default=12)
    parser.add_argument('--minimum-samples',type=int,default=128)
    parser.add_argument('--samples',type=int,default=128)
    parser.add_argument('--boundary-samples',type=int,default=128)
    parser.add_argument('--fold-shards',type=int,default=1)
    args=parser.parse_args();base=args.base.resolve();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    manifest=read(base/'evaluation-manifest.json');rows=[r for r in manifest['items'] if r['split']=='train']
    groups=sorted({r['sourceGroup'] for r in rows})
    assignment={g:source_fold(g) for g in groups}
    partitions=[]
    for f in range(3):
        excluded=[g for g in groups if assignment[g]==f];training=[g for g in groups if assignment[g]!=f]
        if not excluded or not training or set(excluded)&set(training):raise ValueError('Invalid source fold')
        partitions.append(dict(fold=f,trainingGroups=training,excludedGroups=excluded))
    save(out/'OOF-PROTOCOL.json',dict(manifestSHA256=sha(base/'evaluation-manifest.json'),folds=partitions,
        targetPartition='train',trees=args.trees,maximumDepth=args.depth,minimumSamplesToSplit=args.minimum_samples,
        uniformSamplesPerClass=args.samples,boundarySamplesPerClass=args.boundary_samples,foldShards=args.fold_shards,
        sourceGroupLeakage=False,DEVAndTestUsed=False,caseIdentityFeatures=False))
    start=time.monotonic();state=dict(status='extracting-training-pixels',GTChanged=False)
    save(out/'OOF-STATE.json',state)
    samples=[];labels=[];sample_folds=[]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads=[(r,str(base),True,args.samples,args.boundary_samples,i) for i,r in enumerate(rows)]
        for i,(x,y,names) in enumerate(pool.map(sample_training_case,payloads,chunksize=4)):
            samples.append(x);labels.append(y);sample_folds.append(np.full(len(y),assignment[rows[i]['sourceGroup']],np.uint8))
            if (i+1)%250==0:print(f'OOF training extraction {i+1}/{len(rows)}',flush=True)
    x,y,folds=np.concatenate(samples),np.concatenate(labels),np.concatenate(sample_folds)
    state['status']='fitting-excluded-source-teachers';save(out/'OOF-STATE.json',state)
    with tempfile.TemporaryDirectory(prefix='oof-fit-',dir=out) as scratch:
        root=Path(scratch);np.save(root/'features.npy',x);np.save(root/'labels.npy',y);np.save(root/'folds.npy',folds)
        jobs=min(args.fold_shards,args.trees)
        payloads=[(str(root),str(out),f,s,len(range(s,args.trees,jobs)),args.depth,args.minimum_samples)
                  for f in range(3) for s in range(jobs)]
        with ProcessPoolExecutor(max_workers=min(3*jobs,args.jobs)) as pool:
            list(pool.map(fit_fold,payloads))
        for f in range(3):
            merge_forests([out/f'fold-{f}-shard-{s}.json' for s in range(jobs)],out/f'fold-{f}.json')
    state['status']='predicting-excluded-training-sources';save(out/'OOF-STATE.json',state)
    (out/'probabilities').mkdir(exist_ok=True)
    keys=['id','width','height','rgb','rf','polygons','fontPixels']
    inputs=[({k:r[k] for k in keys},str(base),str(out),assignment[r['sourceGroup']]) for r in rows]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for i,_ in enumerate(pool.map(predict_case,inputs,chunksize=4)):
            if (i+1)%250==0:print(f'Excluded-source probabilities {i+1}/{len(rows)}',flush=True)
    result=dict(status='complete',instances=len(rows),sourceGroups=len(groups),sampledPixels=len(y),featureNames=names,
        manifestSHA256=sha(base/'evaluation-manifest.json'),sourceGroupLeakage=False,DEVAndTestUsed=False,
        foldByItem={r['id']:assignment[r['sourceGroup']] for r in rows},
        models=[dict(fold=f,SHA256=sha(out/f'fold-{f}.json')) for f in range(3)],
        seconds=time.monotonic()-start,GTChanged=False)
    save(out/'OOF-COMPLETE.json',result);save(out/'OOF-STATE.json',result)
    print(f'Completed {len(rows)} cross-fitted TRAIN observations in {result["seconds"]:.1f}s',flush=True)


if __name__=='__main__':main()
