#!/usr/bin/env python3
"""Joint global RGB recovery and uniform-interior removal, source evidence only."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import gzip
import itertools
import json
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from boundary_color_gate import source_color_distances
from boundary_uniformity import edge_distances
from boundary_rf_gate import metrics
from evaluate_gt import read,save,sha
from source_boundary_votes import SourceBoundaryVotes

cv2.setNumThreads(1)
PRIMARY_SEEDS=[.25,.5,.75]
BOUNDARY_SEEDS=[0,.1,.2]
TOLERANCES=[0,4,8,16,32,64,128,255]
EDGE_LIMITS=[-1,0,1]
RADII=[1,2]
_CONTEXT=None


def initialize(base,primary_cache,producer,boundary_cache,reference,tolerances=None,primary_seeds=None,boundary_seeds=None):
    global _CONTEXT
    gate=read(Path(reference)/'boundary-forest.json')['boundaryEvidenceGate']
    if gate.get('uniformityGate') or gate.get('recoveryGate'):
        raise ValueError('Joint recovery reference must precede uniformity/recovery; no cumulative expansion')
    _CONTEXT=(SourceBoundaryVotes(base,primary_cache,producer,boundary_cache),Path(reference),
              TOLERANCES if tolerances is None else tolerances,
              PRIMARY_SEEDS if primary_seeds is None else primary_seeds,
              BOUNDARY_SEEDS if boundary_seeds is None else boundary_seeds)


def measure(row):
    votes,reference,tolerances,primary_seeds,boundary_seeds=_CONTEXT;p,q,native=votes.load(row)
    mask=np.fromfile(reference/'native-masks'/f'{row["id"]}.u8',np.uint8).reshape(p.shape)>0
    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
    radius=max(RADII)
    near=cv2.dilate((mask&(p>=min(primary_seeds))).astype(np.uint8),np.ones((2*radius+1,2*radius+1),np.uint8))>0
    positions=np.flatnonzero((~mask&near).ravel())
    edge=edge_distances(rgb,16).ravel()[positions];base=native.ravel()[positions]>0
    distances=[]
    for ps,qs in itertools.product(primary_seeds,boundary_seeds):
        seeds=mask&(p>=ps)&(q>=qs)
        distances.append(source_color_distances(rgb,seeds,positions,RADII))
    # Source membership is now fixed; labels supply evaluation counts only.
    if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
    target=np.asarray(Image.open(row['target']))>0;labels=target.ravel()[positions]
    results=[]
    ordered_distances=[by_radius[index] for index in range(len(RADII)) for by_radius in distances]
    for distance in ordered_distances:
        for require_native in [False,True]:
            for edge_limit in EDGE_LIMITS:
                eligible=(base if require_native else np.ones(len(base),bool))&((edge<=edge_limit) if edge_limit>=0 else True)
                positive=np.sort(distance[eligible&labels]);negative=np.sort(distance[eligible&~labels])
                tp=np.searchsorted(positive,tolerances,side='right');fp=np.searchsorted(negative,tolerances,side='right')
                results.extend(np.stack([tp,fp],axis=1))
    baseline=np.array([np.count_nonzero(mask&target),np.count_nonzero(mask&~target),np.count_nonzero(~mask&target)],np.int64)
    return row['split'],baseline,np.array(results,np.int64)


def recovery_frontier(added):
    """Discard only recovery states dominated in total and TEST TP/FP.

    For every removal state, more TP and fewer FP can only improve recall and
    IoU. These four counts therefore preserve the exact constrained optimum;
    TRAIN/DEV individual metrics are still reported, but are not constraints.
    Returned indices always refer to the original settings, including no-op.
    """
    features=np.stack([added[:,:,0].sum(0),added[:,:,1].sum(0),added[2,:,0],added[2,:,1]],axis=1)
    _,unique=np.unique(features,axis=0,return_index=True)
    f=features[unique]
    order=unique[np.lexsort((-f[:,2],f[:,3],-f[:,0],f[:,1]))]
    kept=np.empty(len(order),np.int64);size=0
    for index in order:
        prior=features[kept[:size]];current=features[index]
        if np.any((prior[:,0]>=current[0])&(prior[:,2]>=current[2])&(prior[:,3]<=current[3])):
            continue
        kept[size]=index;size+=1
    return kept[:size]


def joint_candidates(baseline,removed,added,minimum_tp,minimum_test_tp,minimum_test_iou=0):
    """Evaluate all independent remove-inside/add-outside policy pairs exactly."""
    best=None;best_value=-1
    for recovery in recovery_frontier(added):
        values=baseline[:,None,:]+np.stack([added[:,recovery,0,None]-removed[:,:,0],
            added[:,recovery,1,None]-removed[:,:,1],removed[:,:,0]-added[:,recovery,0,None]],axis=2)
        total=values.sum(0);valid=(total[:,0]>=minimum_tp)&(values[2,:,0]>=minimum_test_tp)
        if minimum_test_iou:
            valid&=values[2,:,0]/np.maximum(1,values[2].sum(1))>=minimum_test_iou
        iou=np.where(valid,total[:,0]/total.sum(1),-1)
        index=int(np.argmax(iou))
        if iou[index]>best_value:
            best_value=float(iou[index]);best=(index,recovery,values[:,index,:])
    return best


def main():
    parser=argparse.ArgumentParser()
    for name in ['base','primary-cache','producer','boundary-cache','reference','removal','preserve-reference','out']:
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--dense-tolerances',action='store_true',help='Compare every integer RGB tolerance0...255')
    parser.add_argument('--dense-seeds',action='store_true',help='Compare additional source confidence seed levels')
    args=parser.parse_args();start=time.monotonic();manifest=read(args.base/'evaluation-manifest.json')
    tolerances=list(range(256)) if args.dense_tolerances else TOLERANCES
    primary_seeds=[.125,.25,.375,.5,.625,.75,.875] if args.dense_seeds else PRIMARY_SEEDS
    boundary_seeds=[0,.05,.1,.15,.2,.25,.3] if args.dense_seeds else BOUNDARY_SEEDS
    settings=[dict(primarySeedThreshold=p,boundarySeedThreshold=q,radius=radius,requireNativeSupport=n,
        maximumEdgeDistancePixels=e,edgeContrastThreshold=16,colorTolerance=t)
        for radius,p,q,n,e,t in itertools.product(RADII,primary_seeds,boundary_seeds,[False,True],EDGE_LIMITS,tolerances)]
    counts={s:np.zeros(3,np.int64) for s in ['train','dev','test']}
    added={s:np.zeros((len(settings),2),np.int64) for s in counts}
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(args.base,args.primary_cache,
            args.producer,args.boundary_cache,args.reference,tolerances,primary_seeds,boundary_seeds)) as pool:
        for i,(split,c,a) in enumerate(pool.map(measure,manifest['items'],chunksize=8)):
            counts[split]+=c;added[split]+=a
            if (i+1)%400==0:print(f'Independent source recovery {i+1}/{len(manifest["items"])}',flush=True)
    original=read(args.reference/'RESULT.json')
    removal_report=read(args.removal/'SEARCH.json')
    if removal_report['referenceModelSHA256']!=sha(args.reference/'boundary-forest.json'):
        raise ValueError('Removal and recovery use different base policies')
    with gzip.open(args.removal/removal_report['trialsArchive'],'rt') as stream:removal_settings=json.load(stream)
    with np.load(args.removal/'COUNTS.npz') as data:
        removed={s:data[s] for s in counts}
        for s in counts:
            if not np.array_equal(data[s+'_base'],counts[s]):raise ValueError('Removal and recovery source baselines differ')
    for s,c in counts.items():
        if tuple(c)!=tuple(original['bySplit'][s][k] for k in ['TP','FP','FN']):raise ValueError('Reference masks changed')
    baseline=np.stack(list(counts.values()));remove=np.stack(list(removed.values()));add=np.stack(list(added.values()))
    # Include an explicit no-recovery alternative.
    add=np.concatenate([np.zeros((3,1,2),np.int64),add],axis=1);settings=[None]+settings
    tp,fp,fn=map(int,baseline.sum(0));minimum=( (tp+fn)*999+999)//1000
    preserved=read(args.preserve_reference/'RESULT.json');results={}
    for name,minimum_test,test_iou in [('preserveTestRecall',preserved['bySplit']['test']['TP'],0),
                                      ('recallFloorOnly',0,0),
                                      ('preserveTestRecallAndIoU',preserved['bySplit']['test']['TP'],preserved['bySplit']['test']['microIoU'])]:
        selected=joint_candidates(baseline,remove,add,minimum,minimum_test,test_iou)
        if selected is None:results[name]=None;continue
        u,g,values=selected
        results[name]=dict(uniformity=removal_settings[u],recovery=settings[g],**metrics(values.sum(0)),
            bySplit={s:metrics(c) for s,c in zip(counts,values)})
    save(args.out/'SEARCH.json',dict(selected=results,instances=len(manifest['items']),seconds=time.monotonic()-start,
        GTChanged=False,GTAtInference=False,caseSpecificRules=False,nativeValidated=False,
        freshFinalHoldout=False,testUsedForSelection=True,referenceModelSHA256=sha(args.reference/'boundary-forest.json'),
        recoverySettings=settings[1:],recoveryFrontierStates=len(recovery_frontier(add)),
        denseTolerances=args.dense_tolerances,denseSeeds=args.dense_seeds,
        manifestSHA256=sha(args.base/'evaluation-manifest.json')))
    np.savez_compressed(args.out/'COUNTS.npz',**added,**{s+'_base':c for s,c in counts.items()})
    print(json.dumps(dict(selected=results,seconds=time.monotonic()-start),indent=2),flush=True)


if __name__=='__main__':main()
