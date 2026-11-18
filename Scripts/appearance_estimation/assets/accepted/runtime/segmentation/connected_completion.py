#!/usr/bin/env python3
"""Source-only weak-component attachment; never dilate recovered components."""
import argparse
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from evaluate_gt import read,save,sha

cv2.setNumThreads(1)


def component_strength(votes,weak,trees):
    _,labels=cv2.connectedComponents((votes>=weak).astype(np.uint8),connectivity=8)
    maximum=np.zeros(int(labels.max())+1,np.uint8)
    np.maximum.at(maximum,labels.ravel(),votes.ravel())
    maximum[0]=0
    return maximum[labels]


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--results',type=Path,required=True)
    parser.add_argument('--minimum-recall',type=float,default=.999)
    args=parser.parse_args()
    rows=[r for r in read(args.out/'evaluation-manifest.json')['items'] if r['split']=='dev']
    trees=read(args.out/'full-rf-PIXEL-MODEL-TRAINING.json')['trees']
    trials=[dict(weakVotes=w,strongVotes=s,weakThreshold=(w-.5)/trees,strongThreshold=(s-.5)/trees,
        radiusFontScale=f,minimumRadiusPixels=1,maximumRadiusPixels=c,kernel='ellipse',connectedWeak=True)
        for w in [1,2,3,4,6,8,10,12] for s in range(w+1,trees+1)
        for f in [.02,.04,.06,.08] for c in [1,2,3,5]]
    weak=np.array([t['weakVotes'] for t in trials]);strong=np.array([t['strongVotes'] for t in trials])
    scales=np.array([t['radiusFontScale'] for t in trials]);caps=np.array([t['maximumRadiusPixels'] for t in trials])
    counts=np.zeros((len(trials),3),np.int64);ious=np.zeros(len(trials))
    start=time.monotonic()
    for ordinal,row in enumerate(rows):
        gt=np.asarray(Image.open(row['target']))>0
        with np.load(args.out/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:
            votes=np.floor(data['probability'].astype(np.float32)*trees+.5).astype(np.uint8)
        radii=np.minimum(caps,np.maximum(1,np.rint(row['fontPixels']*scales).astype(int)))
        expanded={r:cv2.dilate(votes,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(2*r+1,2*r+1))) for r in np.unique(radii)}
        positives=int(gt.sum())
        for w in np.unique(weak):
            attached=component_strength(votes,w,trees)
            for radius in expanded:
                indices=np.flatnonzero((weak==w)&(radii==radius))
                score=np.maximum(attached,expanded[radius])
                total=np.bincount(score.ravel(),minlength=trees+1).cumsum()
                positive=np.bincount(score[gt],minlength=trees+1).cumsum()
                fn=positive[strong[indices]-1];tp=positives-fn
                fp=gt.size-positives-total[strong[indices]-1]+fn
                counts[indices]+=np.stack([tp,fp,fn],axis=1);ious[indices]+=tp/np.maximum(1,tp+fp+fn)
        if (ordinal+1)%100==0:print(f'Connected calibration {ordinal+1}/{len(rows)}',flush=True)
    for i,t in enumerate(trials):
        tp,fp,fn=map(int,counts[i]);t.update(TP=tp,FP=fp,FN=fn,recall=tp/max(1,tp+fn),microIoU=tp/max(1,tp+fp+fn),macroIoU=float(ious[i]/len(rows)))
    eligible=[t for t in trials if t['recall']>=args.minimum_recall]
    selected=max(eligible,key=lambda t:t['macroIoU']) if eligible else None
    frontier=[]
    for floor in [.999,.9993,.9995,.9997,.9998,.9999]:
        eligible=[t for t in trials if t['recall']>=floor]
        frontier.append(dict(minimumRecall=floor,selected=max(eligible,key=lambda t:t['macroIoU']) if eligible else None))
    save(args.results/'CONNECTED-SEARCH.json',dict(selected=selected,frontier=frontier,trialCount=len(trials),
        instances=len(rows),seconds=time.monotonic()-start,runtimeReadsGT=False,testUsed=False,
        modelSHA256=sha(args.out/'full-rf-pixel-fusion-model.json'),manifestSHA256=sha(args.out/'evaluation-manifest.json')))
    np.savez_compressed(args.results/'CONNECTED-TRIALS.npz',counts=counts,macroIoU=ious/len(rows),
        weakVotes=weak,strongVotes=strong,radiusFontScale=scales,maximumRadiusPixels=caps)
    print(__import__('json').dumps(dict(selected=selected,frontier=frontier),indent=2),flush=True)


if __name__=='__main__':main()
