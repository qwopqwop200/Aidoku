#!/usr/bin/env python3
"""Global RF corroboration for ambiguous weak glyph pixels; no per-case rules."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time

import numpy as np
from PIL import Image

from evaluate_gt import read,save,sha
from prepare_full_rf import native_grids,sigmoid,SIDE


def sample_points(grid,x,y,width,height):
    xs=np.clip((x.astype(np.float32)+.5)*SIDE/width-.5,0,SIDE-1)
    ys=np.clip((y.astype(np.float32)+.5)*SIDE/height-.5,0,SIDE-1)
    left,top=xs.astype(int),ys.astype(int)
    right,bottom=np.minimum(SIDE-1,left+1),np.minimum(SIDE-1,top+1)
    dx,dy=xs-left,ys-top
    upper=grid[top,left]*(1-dx)+grid[top,right]*dx
    lower=grid[bottom,left]*(1-dx)+grid[bottom,right]*dx
    return (upper*(1-dy)+lower*dy).astype(np.float32)


def owner_text_sfx_support(row,base,positions):
    folder=Path(base)/'rf-full/crops';case=read(folder/f'{row["id"]}.json')
    source=native_grids(str((folder/case['nativeGrids']).resolve()))
    queries={int(q):i for i,q in enumerate(source['queryIDs'])}
    x=positions%row['width']+case['cropBounds'][0];y=positions//row['width']+case['cropBounds'][1]
    width,height=case['pageSize'];support=np.zeros(len(positions),np.float32)
    for c in [0,1]:
        q=case['ownerQueries'][c]
        probability=sigmoid(sample_points(source['queryLogits'][queries[q]],x,y,width,height)).astype(np.float16).astype(np.float32)
        affinity=np.float32(np.float16(case['affinityScores'][c]))
        np.maximum(support,probability*affinity,out=support)
    return support


def measure(payload):
    row,base,wide,narrow,thresholds=payload;shape=(row['height'],row['width'])
    old=np.fromfile(Path(wide)/f'recall-full-rf-native-{row["split"]}'/f'{row["id"]}.u8',np.uint8).reshape(shape)>0
    proposed=np.fromfile(Path(narrow)/f'recall-full-rf-native-{row["split"]}'/f'{row["id"]}.u8',np.uint8).reshape(shape)>0
    if (proposed&~old).any():raise ValueError('Policies must differ only in a monotone weak threshold')
    positions=np.flatnonzero((old&~proposed).ravel())
    # Rescue membership is computed before opening target pixels.
    support=owner_text_sfx_support(row,base,positions) if len(positions) else np.empty(0,np.float32)
    target=np.asarray(Image.open(row['target']))>0
    if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
    tp=np.count_nonzero(proposed&target);fp=np.count_nonzero(proposed&~target);fn=np.count_nonzero(~proposed&target)
    labels=target.ravel()[positions]
    positive=np.sort(support[labels]);negative=np.sort(support[~labels])
    added_tp=len(positive)-np.searchsorted(positive,thresholds,side='left')
    added_fp=len(negative)-np.searchsorted(negative,thresholds,side='left')
    return row['split'],np.stack([tp+added_tp,fp+added_fp,fn-added_tp],axis=1),len(positions)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--base',type=Path,required=True)
    parser.add_argument('--wide',type=Path,required=True)
    parser.add_argument('--narrow',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    args=parser.parse_args();manifest=read(args.base/'evaluation-manifest.json')
    thresholds=np.array([0,.01,.025,.05,.1,.15,.2,.25,.3,.35,.4,.45,.5,.55,.6,.65,.7,.75,.8,.9,1.01],np.float32)
    counts={s:np.zeros((len(thresholds),3),np.int64) for s in ['train','dev','test']}
    start=time.monotonic();candidate_pixels=0
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads=[(r,str(args.base),str(args.wide),str(args.narrow),thresholds) for r in manifest['items']]
        for i,(split,metrics,pixels) in enumerate(pool.map(measure,payloads,chunksize=8)):
            counts[split]+=metrics;candidate_pixels+=pixels
            if (i+1)%500==0:print(f'RF weak corroboration {i+1}/{len(payloads)}',flush=True)
    total=sum(counts.values());trials=[]
    for index,folder in [(0,args.wide),(-1,args.narrow)]:
        reference=read(folder/'ROUND-RESULT.json')['all']
        if tuple(total[index])!=tuple(reference[k] for k in ['TP','FP','FN']):
            raise ValueError('Endpoint source masks do not reproduce the recorded native metrics')
    for i,t in enumerate(thresholds):
        tp,fp,fn=map(int,total[i]);trials.append(dict(RFThreshold=float(t),TP=tp,FP=fp,FN=fn,
            recall=tp/(tp+fn),microIoU=tp/(tp+fp+fn),bySplit={s:dict(TP=int(a[i,0]),FP=int(a[i,1]),FN=int(a[i,2]),
                recall=float(a[i,0]/(a[i,0]+a[i,2])),microIoU=float(a[i,0]/a[i].sum())) for s,a in counts.items()}))
    eligible=[t for t in trials if t['recall']>=.999]
    selected=max(eligible,key=lambda t:t['microIoU']) if eligible else None
    save(args.out/'RF-WEAK-RESCUE-SEARCH.json',dict(selected=selected,trials=trials,
        probabilityThreshold=read(args.wide/'recall-full-rf-native-pixel-forest.json')['completion']['weakThreshold'],
        candidatePixels=candidate_pixels,instances=len(manifest['items']),seconds=time.monotonic()-start,
        calibrationScope='previously observed full corpus; no fresh final holdout',GTAtInference=False,
        perCaseRules=False,nativeRescueValidated=False,GTChanged=False,
        support='max(ownerTextMaskProbability * ownerTextAffinity, ownerSFXMaskProbability * ownerSFXAffinity)'))
    print(__import__('json').dumps(dict(selected=selected,seconds=time.monotonic()-start),indent=2),flush=True)


if __name__=='__main__':main()
