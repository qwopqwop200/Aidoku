#!/usr/bin/env python3
"""Exact all-contrast uniformity search via L1-ball RGB-gradient maxima."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import json
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from boundary_recovery import joint_candidates
from boundary_rf_gate import metrics
from evaluate_gt import read,save,sha
from source_boundary_votes import SourceBoundaryVotes

cv2.setNumThreads(1)
SCALES=[.0125,.025,.0375,.05]
PCAPS=[0,1,2,3,5,7,15,31,63]
QCAPS=[0,1,2,3,5,7,15,31,47]
_CONTEXT=None


def rgb_gradient(rgb):
    kernel=np.ones((3,3),np.uint8)
    return np.max(cv2.dilate(rgb,kernel,borderType=cv2.BORDER_REPLICATE)-
                  cv2.erode(rgb,kernel,borderType=cv2.BORDER_REPLICATE),axis=2)


def diamond_maximum(gradient,minimum_distance):
    # d(edge)>=D iff max(source-gradient over the L1 ball of radius D-1)<T.
    if minimum_distance<1:raise ValueError('Positive integer edge distance required')
    if minimum_distance>65534:return np.full(gradient.shape,255,np.uint8)
    radius=max(0,minimum_distance-1)
    if radius>=sum(gradient.shape)-2:return np.full(gradient.shape,gradient.max(),np.uint8)
    if radius==0:return gradient.copy()
    kernel=cv2.getStructuringElement(cv2.MORPH_CROSS,(3,3))
    return cv2.dilate(gradient,kernel,iterations=radius,borderType=cv2.BORDER_CONSTANT,borderValue=0)


def initialize(base,primary_cache,producer,boundary_cache,reference):
    global _CONTEXT
    gate=read(Path(reference)/'boundary-forest.json')['boundaryEvidenceGate']
    if gate.get('uniformityGate') or gate.get('recoveryGate'):raise ValueError('Dense search requires the immutable styled base')
    _CONTEXT=(SourceBoundaryVotes(base,primary_cache,producer,boundary_cache),Path(reference))
    if (_CONTEXT[0].primary_trees,_CONTEXT[0].boundary_trees)!=(64,48):
        raise ValueError('Dense vote histogram contract requires frozen64/48 classifiers')


def partition(rows):
    votes,reference=_CONTEXT
    hist={s:np.zeros((2,len(SCALES),2,len(PCAPS),len(QCAPS),256),np.int64) for s in ['train','dev','test']}
    counts={s:np.zeros(3,np.int64) for s in hist}
    for ordinal,row in enumerate(rows):
        p,q,_=votes.load(row)
        mask=np.fromfile(reference/'native-masks'/f'{row["id"]}.u8',np.uint8).reshape(p.shape)>0
        rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
        gradient=rgb_gradient(rgb);pv=np.rint(p*64).astype(np.uint8);qv=np.rint(q*48).astype(np.uint8)
        positions=np.flatnonzero((mask&(pv<=max(PCAPS))&(qv<=max(QCAPS))).ravel())
        pc=np.searchsorted(PCAPS,pv.ravel()[positions]);qc=np.searchsorted(QCAPS,qv.ravel()[positions])
        codes=(pc*len(QCAPS)+qc)*256
        consensus=cv2.dilate(((p>=.5)&(q>=.3)).astype(np.uint8),np.ones((3,3),np.uint8))>0
        unprotected=~consensus.ravel()[positions]
        fields={}
        distances=[max(2,min(65535,int(np.ceil(row['fontPixels']*scale)))) for scale in SCALES]
        for distance in set(distances):fields[distance]=diamond_maximum(gradient,distance).ravel()[positions]
        # Gradient, spatial maxima, votes and consensus are all source-only.
        if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
        target=np.asarray(Image.open(row['target']))>0;labels=target.ravel()[positions]
        counts[row['split']]+=[np.count_nonzero(mask&target),np.count_nonzero(mask&~target),np.count_nonzero(~mask&target)]
        for i,distance in enumerate(distances):
            code=codes+fields[distance];shape=(len(PCAPS),len(QCAPS),256);size=np.prod(shape)
            for protected in [False,True]:
                eligible=unprotected if protected else np.ones(len(positions),bool)
                for label in [0,1]:
                    member=eligible&(labels if label==0 else ~labels)
                    hist[row['split']][int(protected),i,label]+=np.bincount(code[member],minlength=size).reshape(shape)
        if (ordinal+1)%200==0:print(f'Dense source gradient partition {ordinal+1}/{len(rows)}',flush=True)
    return hist,counts


def describe(index):
    protected,scale,p,q,c=np.unravel_index(index,(2,len(SCALES),len(PCAPS),len(QCAPS),255))
    return dict(preserveConsensusNeighbors=bool(protected),consensusRadius=1,primarySeedThreshold=.5,boundarySeedThreshold=.3,
        contrastThreshold=int(c)+1,distanceFontScale=SCALES[scale],minimumDistancePixels=2,
        maximumPrimaryProbability=(PCAPS[p]+.5)/64,maximumBoundaryProbability=(QCAPS[q]+.5)/48)


def main():
    parser=argparse.ArgumentParser()
    for name in ['base','primary-cache','producer','boundary-cache','reference','recovery','preserve-reference','out']:
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    args=parser.parse_args();start=time.monotonic();manifest=read(args.base/'evaluation-manifest.json')
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(args.base,args.primary_cache,
            args.producer,args.boundary_cache,args.reference)) as pool:
        parts=list(pool.map(partition,[manifest['items'][i::args.jobs] for i in range(args.jobs)]))
    hist={s:sum(part[0][s] for part in parts) for s in ['train','dev','test']}
    counts={s:sum(part[1][s] for part in parts) for s in hist};reference=read(args.reference/'RESULT.json')
    for s,c in counts.items():
        if tuple(c)!=tuple(reference['bySplit'][s][k] for k in ['TP','FP','FN']):raise ValueError('Reference source masks changed')
    with np.load(args.recovery/'COUNTS.npz') as recovered:
        added=np.stack([recovered[s] for s in counts])
        for s,c in counts.items():
            if not np.array_equal(c,recovered[s+'_base']):raise ValueError('Recovery and dense source baselines differ')
    report=read(args.recovery/'SEARCH.json')
    if report.get('manifestSHA256')!=sha(args.base/'evaluation-manifest.json') or report.get('referenceModelSHA256')!=sha(args.reference/'boundary-forest.json'):
        raise ValueError('Stale recovery source/GT contract')
    recovery=report['recoverySettings']
    if added.shape[1]!=len(recovery):raise ValueError('Recovery grid contract changed')
    recovery=[None]+recovery;added=np.concatenate([np.zeros((3,1,2),np.int64),added],axis=1)
    removed=[]
    for s,h in hist.items():
        cumulative=h.cumsum(3).cumsum(4).cumsum(5)
        removed.append(cumulative[:,:,:,:,:,:255].transpose(0,1,3,4,5,2).reshape(-1,2))
    removed=np.stack(removed);baseline=np.stack(list(counts.values()));total=baseline.sum(0)
    minimum=((int(total[0])+int(total[2]))*999+999)//1000
    # An exact necessary bound eliminates states no recovery can make feasible.
    eligible=removed[:,:,0].sum(0)<=int(total[0])+int(added[:,:,0].sum(0).max())-minimum
    indices=np.flatnonzero(eligible);subset=removed[:,indices,:];preserve=read(args.preserve_reference/'RESULT.json')
    results={}
    for label,test_min,test_iou in [('preserveTestRecall',preserve['bySplit']['test']['TP'],0),
                                   ('recallFloorOnly',0,0),
                                   ('preserveTestRecallAndIoU',preserve['bySplit']['test']['TP'],preserve['bySplit']['test']['microIoU'])]:
        chosen=joint_candidates(baseline,subset,added,minimum,test_min,test_iou)
        if chosen is None:results[label]=None;continue
        u,g,values=chosen
        results[label]=dict(uniformity=describe(int(indices[u])),recovery=recovery[g],**metrics(values.sum(0)),
            bySplit={s:metrics(c) for s,c in zip(counts,values)})
    save(args.out/'SEARCH.json',dict(selected=results,instances=len(manifest['items']),seconds=time.monotonic()-start,
        totalGlobalRemovalStates=removed.shape[1],feasibleRemovalStates=len(indices),GTChanged=False,GTAtInference=False,
        caseSpecificRules=False,nativeValidated=False,freshFinalHoldout=False,testUsedForSelection=True,
        referenceModelSHA256=sha(args.reference/'boundary-forest.json'),recoveryCountsSHA256=sha(args.recovery/'COUNTS.npz'),
        manifestSHA256=sha(args.base/'evaluation-manifest.json'),
        uniformityGrid=dict(fontScales=SCALES,primaryVoteCaps=PCAPS,boundaryVoteCaps=QCAPS,
            contrastRange=[1,255],protectionFlags=[False,True],treeCounts=[64,48],minimumDistancePixels=2)))
    np.savez_compressed(args.out/'COUNTS.npz',**hist,**{s+'_base':c for s,c in counts.items()})
    print(json.dumps(dict(selected=results,seconds=time.monotonic()-start,feasibleStates=len(indices)),indent=2),flush=True)


if __name__=='__main__':main()
