#!/usr/bin/env python3
"""Calibrate weak undilated support + stronger expanded seeds on source-group DEV.

Weak uncertain pixels never seed expansion. Runtime requires only forest
probabilities and source-derived font scale, without target masks or IDs.
"""
import argparse
import gzip
import json
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from evaluate_gt import read,save,sha

cv2.setNumThreads(1)


def save_trial_report(path, document):
    """Keep frozen selection receipts small without discarding trial evidence."""
    trials=document.get('trials',[])
    if len(trials)<=1000:
        save(path,document)
        return
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    archive=path.with_suffix('.trials.json.gz');temporary=archive.with_suffix(archive.suffix+'.tmp')
    with gzip.open(temporary,'wt',encoding='utf-8',compresslevel=3) as stream:
        json.dump(trials,stream,separators=(',',':'))
    temporary.replace(archive)
    receipt={k:v for k,v in document.items() if k!='trials'}
    receipt.update(trialCount=len(trials),trialsArchive=archive.name,trialsArchiveSHA256=sha(archive))
    save(path,receipt)


def union_counts(votes, expanded, target, weak, strong, trees, fringe=None):
    """Count every threshold pair in O(pixels + trees²), without trial masks.

    The complement of (votes >= weak OR expanded >= strong) is a
    lower-left rectangle in the joint vote histogram. Keep target pixels
    separate; background true negatives are never used as an accuracy score.
    """
    side = trees + 1
    joint = votes.astype(np.int32) * side + expanded
    totals = np.bincount(joint.ravel(), minlength=side * side).reshape(side, side)
    positive = np.bincount(joint[target], minlength=side * side).reshape(side, side)
    def excluded(hist):
        prefix=np.pad(hist.cumsum(0).cumsum(1),((1,0),(1,0)))
        if fringe is None:
            return prefix[weak,strong]
        return prefix[fringe,side]+prefix[weak,strong]-prefix[fringe,strong]
    fn = excluded(positive)
    tp = int(target.sum()) - fn
    fp = target.size - int(target.sum()) - excluded(totals - positive)
    return tp, fp, fn


def source_bootstrap(rows, trials, out, trees, minimum_recall, objective='macroIoU'):
    """Choose a margin from source-group uncertainty, never held-out labels.

    Repeated crops from one page are not independent evidence. Resample whole
    decoded-source groups, and require the lower one-percentile recall to meet
    the requested foreground floor. A compact frontier avoids huge trial maps.
    """
    frontier={}
    for floor in np.linspace(minimum_recall,1,41):
        eligible=[t for t in trials if t['recall']>=floor]
        if eligible:
            best=max(eligible,key=lambda t:(t[objective],t['recall']))
            frontier[tuple(best[k] for k in ['weakVotes','strongVotes','fringeVotes','radiusFontScale','maximumRadiusPixels'])]=best
    candidates=list(frontier.values())
    if not candidates:
        return None,[]
    groups=sorted({r['sourceGroup'] for r in rows});group_index={s:i for i,s in enumerate(groups)}
    fn=np.zeros((len(candidates),len(groups)),np.int64);positives=np.zeros(len(groups),np.int64)
    weak=np.array([t['weakVotes'] for t in candidates]);strong=np.array([t['strongVotes'] for t in candidates])
    fringe=np.array([t['fringeVotes'] for t in candidates])
    for row in rows:
        gt=np.asarray(Image.open(row['target']))>0
        with np.load(out/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:
            votes=np.floor(data['probability'].astype(np.float32)*trees+.5).astype(np.uint8)
        group=group_index[row['sourceGroup']];positives[group]+=int(gt.sum())
        radii=np.array([min(t['maximumRadiusPixels'],max(1,round(row['fontPixels']*t['radiusFontScale']))) for t in candidates])
        for radius in np.unique(radii):
            indices=np.flatnonzero(radii==radius)
            kind={'square':cv2.MORPH_RECT,'ellipse':cv2.MORPH_ELLIPSE,'cross':cv2.MORPH_CROSS}[candidates[0]['kernel']]
            expanded=cv2.dilate(votes,cv2.getStructuringElement(kind,(2*radius+1,2*radius+1)))
            _,_,missing=union_counts(votes,expanded,gt,weak[indices],strong[indices],trees,fringe[indices])
            fn[indices,group]+=missing
    rng=np.random.default_rng(20261109)
    weights=rng.multinomial(len(groups),np.full(len(groups),1/len(groups)),size=4000)
    denominator=weights@positives
    recalls=1-(weights@fn.T)/np.maximum(1,denominator[:,None])
    lower=np.quantile(recalls,.01,axis=0)
    results=[dict(**t,sourceBootstrapRecallLower01=float(lower[i]),sourceGroups=len(groups),bootstrapReplicates=4000)
             for i,t in enumerate(candidates)]
    eligible=[t for t in results if t['sourceBootstrapRecallLower01']>=minimum_recall]
    return (max(eligible,key=lambda t:(t[objective],t['recall'])) if eligible else None),results


def seed_chroma(row,out):
    """Source-only context: median RGB channel span of confident glyph seeds."""
    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
    with np.load(out/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:
        seed=data['probability']>=.5
    span=rgb.max(2).astype(np.int16)-rgb.min(2)
    return float(np.median(span[seed])) if seed.any() else 0.


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--results',type=Path,help='Small reports only; reuse the immutable input caches from --out')
    ap.add_argument('--minimum-recall',type=float,default=.9990554867162001)
    ap.add_argument('--refine',action='store_true')
    ap.add_argument('--dense',action='store_true')
    ap.add_argument('--kernel',choices=['square','ellipse','cross'],default='square')
    ap.add_argument('--source-bootstrap',action='store_true')
    ap.add_argument('--objective',choices=['macroIoU','microIoU'],default='macroIoU')
    ap.add_argument('--seed-chroma-band',choices=['all','low','high'],default='all')
    args=ap.parse_args();out=args.out
    results=args.results or out
    results.mkdir(parents=True,exist_ok=True)
    rows=[r for r in read(out/'evaluation-manifest.json')['items'] if r['split']=='dev']
    if args.seed_chroma_band!='all':
        rows=[r for r in rows if (seed_chroma(r,out)>=16)==(args.seed_chroma_band=='high')]
        if not rows:raise ValueError('No DEV instances in the requested source-only chroma band')
    trees=read(out/'full-rf-PIXEL-MODEL-TRAINING.json')['trees']
    weak=[4,5,6,7,8] if args.refine else [1,2,3,4,6,8,10,12]
    strong=list(range(10,17)) if args.refine else [12,16,19,24,32,40]
    scales=[.025,.03,.035,.04,.045,.05] if args.refine else [.02,.03,.04,.05,.06]
    caps=[1,2,3] if args.refine else [2,3,4,8]
    if args.dense:
        weak=list(range(1,min(24,trees)+1));strong=list(range(2,trees+1))
        scales=[.015,.025,.035,.045,.06,.08];caps=[1,2,3,5,8]
    fringes=[0,1,2,3,4] if args.dense else [0]
    trials=[dict(weakVotes=w,strongVotes=s,weakThreshold=(w-.5)/trees,strongThreshold=(s-.5)/trees,
                 fringeVotes=f,fringeThreshold=max(0,(f-.5)/trees),kernel=args.kernel,
                 radiusFontScale=scale,minimumRadiusPixels=1,maximumRadiusPixels=cap)
            for w in weak for s in strong if s>w
            for f in fringes if f<=w for scale in scales for cap in caps]
    stem=('HYSTERESIS-DENSE-'+args.kernel.upper()) if args.dense else ('HYSTERESIS-REFINED' if args.refine else 'HYSTERESIS')
    save_trial_report(results/f'{stem}-PROTOCOL.json',dict(trials=trials,minimumRecall=args.minimum_recall,
         rule=f'weak undilated support OR dilation of stronger seeds; maximize DEV {args.objective} subject to recall',
         GTAtInference=False,caseSpecificRules=False,testUsed=False,
         modelSHA256=sha(out/'full-rf-pixel-fusion-model.json')))
    counts=np.zeros((len(trials),3),np.int64);ious=np.zeros(len(trials),np.float64)
    trial_scales=np.array([t['radiusFontScale'] for t in trials])
    trial_caps=np.array([t['maximumRadiusPixels'] for t in trials])
    trial_weak=np.array([t['weakVotes'] for t in trials])
    trial_strong=np.array([t['strongVotes'] for t in trials])
    trial_fringe=np.array([t['fringeVotes'] for t in trials])
    start=time.monotonic()
    for ordinal,row in enumerate(rows):
        gt=np.asarray(Image.open(row['target']))>0
        with np.load(out/'full-rf-dev-probabilities'/f'{row["id"]}.npz')as f:p=f['probability'].astype(np.float32)
        # Exported trees vote for binary leaves. Half-vote cutoffs also
        # remain exact when cached probabilities were stored in FP16.
        votes=np.floor(p*trees+.5).astype(np.uint8)
        radii=np.minimum(trial_caps,np.maximum(1,np.rint(row['fontPixels']*trial_scales).astype(np.int32)))
        for radius in np.unique(radii):
            indices=np.flatnonzero(radii==radius)
            shape={'square':cv2.MORPH_RECT,'ellipse':cv2.MORPH_ELLIPSE,'cross':cv2.MORPH_CROSS}[args.kernel]
            expanded=cv2.dilate(votes,cv2.getStructuringElement(shape,(2*radius+1,2*radius+1)))
            w,s,f=trial_weak[indices],trial_strong[indices],trial_fringe[indices]
            tp,fp,fn=union_counts(votes,expanded,gt,w,s,trees,f)
            counts[indices]+=np.stack([tp,fp,fn],axis=1)
            ious[indices]+=tp/np.maximum(1,tp+fp+fn)
        if (ordinal+1)%100==0:print(f'Hysteresis calibration {ordinal+1}/{len(rows)}',flush=True)
    for i,t in enumerate(trials):
        tp,fp,fn=map(int,counts[i])
        t.update(TP=tp,FP=fp,FN=fn,recall=tp/max(1,tp+fn),precision=tp/max(1,tp+fp),
                 microIoU=tp/max(1,tp+fp+fn),macroIoU=float(ious[i]/len(rows)))
    eligible=[t for t in trials if t['recall']>=args.minimum_recall]
    chosen=max(eligible,key=lambda t:(t[args.objective],t['recall'])) if eligible else None
    bootstrap=[]
    if args.source_bootstrap:
        chosen,bootstrap=source_bootstrap(rows,trials,out,trees,args.minimum_recall,args.objective)
    save_trial_report(results/f'{stem}-SEARCH.json',dict(selected=chosen,trials=trials,instances=len(rows),
         sourceBootstrap=bootstrap,selectionRequiresSourceBootstrap=args.source_bootstrap,
         objective=args.objective,
         seedChromaBand=args.seed_chroma_band,seedChromaThreshold=16,
         minimumRecall=args.minimum_recall,seconds=time.monotonic()-start,testUsedForSelection=False,
         sourceOnlyAtRuntime=True,weakSeedsNeverDilated=True,modelPromoted=False))
    print(__import__('json').dumps(dict(selected=chosen,seconds=time.monotonic()-start),indent=2),flush=True)


if __name__=='__main__':main()
