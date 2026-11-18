#!/usr/bin/env python3
"""DEV-only search: uncertain seeds grow locally, strong cores reach farther."""
import argparse
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from evaluate_gt import read,save,sha

cv2.setNumThreads(1)


def triple_counts(votes,near,far,target,weak,local,strong,trees):
    side=trees+1
    index=(votes.astype(np.int32)*side+near)*side+far
    shape=(side,)*3
    total=np.bincount(index.ravel(),minlength=side**3).reshape(shape)
    positive=np.bincount(index[target],minlength=side**3).reshape(shape)
    def excluded(hist):
        return hist.cumsum(0).cumsum(1).cumsum(2)[weak-1,local-1,strong-1]
    fn=excluded(positive)
    return int(target.sum())-fn,target.size-int(target.sum())-excluded(total-positive),fn


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--results',type=Path,required=True)
    parser.add_argument('--minimum-recall',type=float,default=.999)
    args=parser.parse_args()
    rows=[r for r in read(args.out/'evaluation-manifest.json')['items'] if r['split']=='dev']
    trees=read(args.out/'full-rf-PIXEL-MODEL-TRAINING.json')['trees']
    trials=[dict(weakVotes=w,localVotes=n,strongVotes=f,farFontScale=s,farCap=c)
            for w in [1,2,3,4,6,8,10,12] for n in [6,8,10,12,16,20,24,28,32] if n>w
            for f in range(12,trees+1,4) if f>n for s in [.035,.05,.075,.1] for c in [2,3,4,6]]
    w,n,f=[np.array([t[k] for t in trials]) for k in ['weakVotes','localVotes','strongVotes']]
    scales=np.array([t['farFontScale'] for t in trials]);caps=np.array([t['farCap'] for t in trials])
    counts=np.zeros((len(trials),3),np.int64);ious=np.zeros(len(trials))
    start=time.monotonic()
    for ordinal,row in enumerate(rows):
        gt=np.asarray(Image.open(row['target']))>0
        with np.load(args.out/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:
            votes=np.floor(data['probability'].astype(np.float32)*trees+.5).astype(np.uint8)
        near=cv2.dilate(votes,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(3,3)))
        radii=np.minimum(caps,np.maximum(2,np.rint(row['fontPixels']*scales).astype(int)))
        for radius in np.unique(radii):
            indices=np.flatnonzero(radii==radius)
            far=cv2.dilate(votes,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(2*radius+1,2*radius+1)))
            tp,fp,fn=triple_counts(votes,near,far,gt,w[indices],n[indices],f[indices],trees)
            counts[indices]+=np.stack([tp,fp,fn],axis=1);ious[indices]+=tp/np.maximum(1,tp+fp+fn)
        if (ordinal+1)%100==0:print(f'Multiscale {ordinal+1}/{len(rows)}',flush=True)
    for i,t in enumerate(trials):
        tp,fp,fn=map(int,counts[i]);t.update(TP=tp,FP=fp,FN=fn,recall=tp/max(1,tp+fn),microIoU=tp/max(1,tp+fp+fn),macroIoU=float(ious[i]/len(rows)))
    frontier=[]
    for floor in [.999,.9993,.9995,.9997,.9998,.9999,.99995]:
        eligible=[t for t in trials if t['recall']>=floor]
        frontier.append(dict(minimumRecall=floor,selected=max(eligible,key=lambda t:t['macroIoU']) if eligible else None))
    eligible=[t for t in trials if t['recall']>=args.minimum_recall]
    selected=max(eligible,key=lambda t:t['macroIoU']) if eligible else None
    save(args.results/'MULTISCALE-SEARCH.json',dict(selected=selected,frontier=frontier,trialCount=len(trials),
        instances=len(rows),seconds=time.monotonic()-start,modelSHA256=sha(args.out/'full-rf-pixel-fusion-model.json'),
        manifestSHA256=sha(args.out/'evaluation-manifest.json'),runtimeReadsGT=False,testUsed=False,
        nearRadius=1,kernel='ellipse',minimumFarRadius=2))
    args.results.mkdir(parents=True,exist_ok=True)
    np.savez_compressed(args.results/'MULTISCALE-TRIALS.npz',counts=counts,macroIoU=ious/len(rows),
        weakVotes=w,localVotes=n,strongVotes=f,farFontScale=scales,farCap=caps)
    print(__import__('json').dumps(dict(selected=selected,frontier=frontier),indent=2),flush=True)


if __name__=='__main__':main()
