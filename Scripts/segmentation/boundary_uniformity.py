#!/usr/bin/env python3
"""Calibrate uncertain uniform-interior suppression from source RGB and RF votes."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import itertools
import json
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from boundary_rf_gate import metrics
from evaluate_gt import read,save,sha
from native_boundary_policy_replay import cache_path
from native_predict import classifier_identity,observation_contract,load_classifier_observation

cv2.setNumThreads(1)
CONTRASTS=[8,16,32,48]
SCALES=[.025,.05,.075,.1,.125,.15,.2,.25,.3,.4,.5]
PRIMARY_CAPS=[1,3,7,15,23,31,47,63]
BOUNDARY_CAPS=[0,1,2,3,5,7,11,15,23,31,47]
_CONTEXT=None


def initialize(base,primary_cache,producer,boundary_cache,reference):
    global _CONTEXT
    base,primary_cache,producer,boundary_cache,reference=map(Path,(base,primary_cache,producer,boundary_cache,reference))
    pi,pt=classifier_identity(base/'recall-full-rf-native-pixel-forest.json')
    qi,qt=classifier_identity(producer/'boundary-forest.json')
    if (pt,qt)!=(64,48):raise ValueError('Require frozen64/48 native source classifier pair')
    _CONTEXT=(base,primary_cache,boundary_cache,reference,pi,sha(base/'native-pixel-rf-segmentation'),
              qi,sha(producer/'native-boundary-refiner'))


def edge_distances(rgb,threshold):
    kernel=np.ones((3,3),np.uint8)
    high=cv2.dilate(rgb,kernel,borderType=cv2.BORDER_REPLICATE)
    low=cv2.erode(rgb,kernel,borderType=cv2.BORDER_REPLICATE)
    edge=np.max(high-low,axis=2)>=threshold
    if not edge.any():return np.full(edge.shape,65534,np.int32)
    return np.minimum(cv2.distanceTransform((~edge).astype(np.uint8),cv2.DIST_L1,3),65534).astype(np.int32)


def source_uniform_candidates(rgb,p,q,font,policy):
    distance=edge_distances(rgb,policy['contrastThreshold'])
    minimum=max(policy['minimumDistancePixels'],min(65535,int(np.ceil(font*policy['distanceFontScale']))))
    remove=(p<policy['maximumPrimaryProbability'])&(q<policy['maximumBoundaryProbability'])&(distance>=minimum)
    if policy['preserveConsensusNeighbors']:
        radius=policy['consensusRadius']
        consensus=(p>=policy['primarySeedThreshold'])&(q>=policy['boundarySeedThreshold'])
        remove&=~(cv2.dilate(consensus.astype(np.uint8),np.ones((2*radius+1,2*radius+1),np.uint8))>0)
    return remove


def uniform_removed_counts(pv,qv,distance,target,mask,font,scales=SCALES,primary_caps=PRIMARY_CAPS,boundary_caps=BOUNDARY_CAPS):
    thresholds=np.minimum(65535,np.maximum(2,np.ceil(font*np.asarray(scales)))).astype(np.int64)
    positions=np.flatnonzero(mask.ravel())
    bins=np.searchsorted(thresholds,distance.ravel()[positions],side='right')
    side=len(scales)+1
    codes=(pv.ravel()[positions].astype(np.int64)*49+qv.ravel()[positions])*side+bins
    labels=target.ravel()[positions]
    shape=(65,49,side);size=np.prod(shape)
    h=np.stack([np.bincount(codes[labels],minlength=size).reshape(shape),
                np.bincount(codes[~labels],minlength=size).reshape(shape)])
    h=h.cumsum(1).cumsum(2)[:,:,:,::-1].cumsum(3)[:,:,:,::-1]
    s,p,q=np.meshgrid(np.arange(len(scales)),primary_caps,boundary_caps,indexing='ij')
    return h[:,p.ravel(),q.ravel(),s.ravel()+1].T


def measure(row):
    base,pcache,qcache,reference,pi,pb,qi,qb=_CONTEXT
    inputs={k:row[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']}
    pc=observation_contract(inputs,base,pi,pb,True);qc=observation_contract(inputs,base,qi,qb,True)
    qc.update(primaryClassifierSHA256=pi,primaryExecutableSHA256=pb,schema='source-boundary-classifier-observation-v1')
    po=load_classifier_observation(cache_path(pcache,pc),pc,64)
    qo=load_classifier_observation(cache_path(qcache,qc),qc,48)
    if po is None or qo is None:raise ValueError('Missing or stale native source votes')
    p,native=po;q,other=qo
    if not np.array_equal(native,other):raise ValueError('Source extraction mismatch')
    pv=np.rint(p*64).astype(np.uint8);qv=np.rint(q*48).astype(np.uint8)
    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
    mask=np.fromfile(reference/'native-masks'/f'{row["id"]}.u8',np.uint8).reshape(p.shape)>0
    distances=[edge_distances(rgb,threshold) for threshold in CONTRASTS]
    consensus=cv2.dilate(((p>=.5)&(q>=.3)).astype(np.uint8),np.ones((3,3),np.uint8))>0
    # Every decision operand above comes from source pixels/native predictions.
    if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
    target=np.asarray(Image.open(row['target']))>0
    removed=np.concatenate([uniform_removed_counts(pv,qv,d,target,mask&(~consensus if protect else True),row['fontPixels'])
                            for protect in [False,True] for d in distances])
    baseline=np.array([np.count_nonzero(mask&target),np.count_nonzero(mask&~target),np.count_nonzero(~mask&target)],np.int64)
    return row['split'],baseline,removed


def main():
    parser=argparse.ArgumentParser()
    for name in ['base','primary-cache','producer','boundary-cache','reference','out']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    args=parser.parse_args();start=time.monotonic();manifest=read(args.base/'evaluation-manifest.json')
    settings=[dict(preserveConsensusNeighbors=protect,consensusRadius=1,primarySeedThreshold=.5,boundarySeedThreshold=.3,
        contrastThreshold=c,distanceFontScale=s,minimumDistancePixels=2,
        maximumPrimaryVotes=p,maximumBoundaryVotes=q,maximumPrimaryProbability=(p+.5)/64,
        maximumBoundaryProbability=(q+.5)/48) for protect,c,s,p,q in itertools.product([False,True],CONTRASTS,SCALES,PRIMARY_CAPS,BOUNDARY_CAPS)]
    counts={s:np.zeros(3,np.int64) for s in ['train','dev','test']}
    removed={s:np.zeros((len(settings),2),np.int64) for s in counts}
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(args.base,args.primary_cache,
            args.producer,args.boundary_cache,args.reference)) as pool:
        for i,(split,c,r) in enumerate(pool.map(measure,manifest['items'],chunksize=8)):
            counts[split]+=c;removed[split]+=r
            if (i+1)%400==0:print(f'Uniform source interiors {i+1}/{len(manifest["items"])}',flush=True)
    reference=read(args.reference/'RESULT.json')
    for split,c in counts.items():
        if tuple(c)!=tuple(reference['bySplit'][split][k] for k in ['TP','FP','FN']):raise ValueError('Reference source masks changed')
    trials=[]
    for i,setting in enumerate(settings):
        values={s:c+[-removed[s][i,0],-removed[s][i,1],removed[s][i,0]] for s,c in counts.items()}
        trials.append(dict(**setting,**metrics(sum(values.values())),bySplit={s:metrics(c) for s,c in values.items()}))
    eligible=[t for t in trials if t['recall']>=.999]
    preserved=[t for t in eligible if t['bySplit']['test']['FN']==reference['bySplit']['test']['FN']]
    lossless=[t for t in trials if t['FN']==reference['all']['FN']]
    selected=max(preserved,key=lambda t:t['microIoU']) if preserved else None
    from hysteresis_completion import save_trial_report
    save_trial_report(args.out/'SEARCH.json',dict(selected=selected,
        bestRecallFloor=max(eligible,key=lambda t:t['microIoU']) if eligible else None,
        bestLossless=max(lossless,key=lambda t:t['microIoU']) if lossless else None,trials=trials,
        instances=len(manifest['items']),seconds=time.monotonic()-start,GTChanged=False,GTAtInference=False,
        caseSpecificRules=False,nativeValidated=False,freshFinalHoldout=False,testUsedForSelection=True,
        referenceModelSHA256=sha(args.reference/'boundary-forest.json'),manifestSHA256=sha(args.base/'evaluation-manifest.json')))
    np.savez_compressed(args.out/'COUNTS.npz',**removed,**{s+'_base':c for s,c in counts.items()})
    print(json.dumps(dict(selected=selected,bestFloor=max(eligible,key=lambda t:t['microIoU']) if eligible else None,
        bestLossless=max(lossless,key=lambda t:t['microIoU']) if lossless else None,seconds=time.monotonic()-start),indent=2),flush=True)


if __name__=='__main__':main()
