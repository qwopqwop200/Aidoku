#!/usr/bin/env python3
"""Compare source-chroma fringe policies using actual native classifier votes."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import gzip
import json
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from boundary_color_gate import source_color_distances
from boundary_rf_gate import metrics
from evaluate_gt import read, save, sha
from native_boundary_policy_replay import cache_path
from native_predict import classifier_identity, observation_contract, load_classifier_observation
from boundary_uniformity import source_uniform_candidates

cv2.setNumThreads(1)
_CONTEXT=None


def initialize(base,primary_cache,producer,boundary_cache,chroma_threshold,primary_limit,boundary_limit,uniformity=None):
    global _CONTEXT
    base,primary_cache,producer,boundary_cache=map(Path,(base,primary_cache,producer,boundary_cache))
    pi,pt=classifier_identity(base/'recall-full-rf-native-pixel-forest.json')
    bi,bt=classifier_identity(producer/'boundary-forest.json')
    if (pt,bt)!=(64,48):raise ValueError('This histogram contract requires the frozen64/48-tree pair')
    _CONTEXT=(base,primary_cache,boundary_cache,pi,pt,sha(base/'native-pixel-rf-segmentation'),
              bi,bt,sha(producer/'native-boundary-refiner'),read(producer/'boundary-forest.json'),chroma_threshold,
              primary_limit,boundary_limit,uniformity)


def measure(row):
    base,primary_cache,boundary_cache,pi,pt,pb,bi,bt,bb,model,chroma_threshold,primary_limit,boundary_limit,uniformity=_CONTEXT
    inputs={k:row[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']}
    pc=observation_contract(inputs,base,pi,pb,True)
    bc=observation_contract(inputs,base,bi,bb,True)
    bc.update(primaryClassifierSHA256=pi,primaryExecutableSHA256=pb,schema='source-boundary-classifier-observation-v1')
    po=load_classifier_observation(cache_path(primary_cache,pc),pc,pt)
    bo=load_classifier_observation(cache_path(boundary_cache,bc),bc,bt)
    if po is None or bo is None:raise ValueError('Missing or stale native source votes')
    p,base_mask=po;q,other_base=bo
    if not np.array_equal(base_mask,other_base):raise ValueError('Mixed source extractions')
    c=model['completion'];radius=min(c['maximumRadiusPixels'],max(c['minimumRadiusPixels'],round(row['fontPixels']*c['radiusFontScale'])))
    seed=q>=model['threshold']
    if c['unionNative']:seed|=base_mask>0
    mask=cv2.dilate(seed.astype(np.uint8),cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(2*radius+1,2*radius+1)))>0
    if c.get('fringeThreshold'):mask&=q>=c['fringeThreshold']
    mask|=q>=c['weakThreshold']
    pv=np.rint(p*pt).astype(np.uint8);qv=np.rint(q*bt).astype(np.uint8)
    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
    raw_mask=mask
    if uniformity:mask=mask&~source_uniform_candidates(rgb,p,q,row['fontPixels'],uniformity)
    positions=np.flatnonzero((mask&(pv<primary_limit)&(qv<boundary_limit)).ravel())
    style=(rgb.max(2)-rgb.min(2)>=chroma_threshold).astype(np.uint8)
    distance=source_color_distances(rgb,(p>=.5)|(q>=.3),positions,[1])[0]
    codes=(((style.ravel()[positions].astype(np.int64)*primary_limit+pv.ravel()[positions])*boundary_limit+qv.ravel()[positions])*257+distance)
    # Source-only membership is fixed before evaluation labels are opened.
    if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
    target=np.asarray(Image.open(row['target']))>0;positive=target.ravel()[positions]
    shape=(2,primary_limit,boundary_limit,257);size=np.prod(shape)
    hist=np.stack([np.bincount(codes[positive],minlength=size).reshape(shape),
                   np.bincount(codes[~positive],minlength=size).reshape(shape)])
    counts=[]
    for s in [0,1]:
        member=style==s
        counts.append([np.count_nonzero(mask&target&member),np.count_nonzero(mask&~target&member),
                       np.count_nonzero(~mask&target&member)])
    raw_counts=np.array([np.count_nonzero(raw_mask&target),np.count_nonzero(raw_mask&~target),np.count_nonzero(~raw_mask&target)],np.int64)
    return row['split'],np.array(counts,np.int64),hist,raw_counts


def profiles(histograms,style):
    parameters=[dict(primaryVotes=0,boundaryVotes=1,colorTolerance=-1)]
    data=[np.zeros((3,2),np.int64)]
    primary_limit,boundary_limit=next(iter(histograms.values())).shape[2:4]
    for p in range(1,primary_limit+1):
        for q in range(1,boundary_limit+1):
            tails=[]
            for split in ['train','dev','test']:
                h=histograms[split][:,style,:p,:q,:].sum(axis=(1,2))
                tails.append(h[:,::-1].cumsum(1)[:,::-1])
            # t=-1 removes all unsupported pixels; t=255 retains any seed
            # color match, but still rejects the no-nearby-seed sentinel256.
            values=np.stack(tails,axis=1)
            for t in range(-1,256):
                parameters.append(dict(primaryVotes=p,boundaryVotes=q,colorTolerance=t))
                data.append(values[:,:,t+1].T)
    return parameters,np.stack(data)


def frontier(data,maximum_loss,maximum_test_loss):
    """Dominance pruning preserves every feasible IoU optimum of two bins."""
    all_loss=data[:,:,0].sum(1);false_removed=data[:,:,1].sum(1);test_loss=data[:,2,0]
    valid=np.flatnonzero((all_loss<=maximum_loss)&(test_loss<=maximum_test_loss))
    order=valid[np.lexsort((-false_removed[valid],test_loss[valid],all_loss[valid]))]
    bit=np.full(maximum_test_loss+2,-1,np.int64);kept=[]
    for index in order:
        position=int(test_loss[index])+1;cursor=position;best=-1
        while cursor:
            best=max(best,int(bit[cursor]));cursor-=cursor&-cursor
        if best>=false_removed[index]:continue
        kept.append(index)
        while position<len(bit):
            bit[position]=max(bit[position],false_removed[index]);position+=position&-position
    return np.array(kept,np.int64)


def select_pair(first,second,baseline,maximum_loss,maximum_test_loss):
    left=frontier(first,maximum_loss,maximum_test_loss);right=frontier(second,maximum_loss,maximum_test_loss)
    total_base=baseline.sum(0);best=None;best_value=-1
    for i in left:
        combined=first[i]+second[right]
        losses=combined[:,:,0].sum(1);removed=combined[:,:,1].sum(1)
        feasible=(losses<=maximum_loss)&(combined[:,2,0]<=maximum_test_loss)
        values=np.where(feasible,(total_base[0]-losses)/(total_base.sum()-removed),-1)
        j=int(np.argmax(values))
        if values[j]>best_value:
            best_value=float(values[j]);best=(int(i),int(right[j]),combined[j])
    if best is None:raise ValueError('No admissible style policy')
    return best,dict(firstFrontier=len(left),secondFrontier=len(right),pairs=len(left)*len(right))


def main():
    parser=argparse.ArgumentParser()
    for name in ['base','primary-cache','producer','boundary-cache','raw-reference','reference','out']:
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--chroma-threshold',type=int,default=32)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--primary-limit',type=int,default=8)
    parser.add_argument('--boundary-limit',type=int,default=4)
    parser.add_argument('--pre-uniformity-policy',type=Path)
    args=parser.parse_args();start=time.monotonic();manifest=read(args.base/'evaluation-manifest.json')
    if not 1<=args.chroma_threshold<=255:parser.error('Chroma threshold must be1...255')
    if not 1<=args.primary_limit<=64 or not 1<=args.boundary_limit<=48:parser.error('Vote bounds exceed the frozen classifiers')
    uniformity=None
    if args.pre_uniformity_policy:
        policy=read(args.pre_uniformity_policy)
        if (policy.get('primaryModelSHA256')!=sha(args.base/'recall-full-rf-native-pixel-forest.json') or
                policy.get('manifestSHA256')!=sha(args.base/'evaluation-manifest.json') or
                policy.get('refinerModelSHA256')!=read(args.producer/'boundary-forest.json')['sourceModelSHA256'] or
                policy.get('GTAtInference') is not False):raise ValueError('Unverified pre-uniformity source policy')
        uniformity=policy['selected']['uniformityGate']
    counts={s:np.zeros((2,3),np.int64) for s in ['train','dev','test']}
    raw_counts={s:np.zeros(3,np.int64) for s in counts}
    histograms={s:np.zeros((2,2,args.primary_limit,args.boundary_limit,257),np.int64) for s in counts}
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(args.base,args.primary_cache,
            args.producer,args.boundary_cache,args.chroma_threshold,args.primary_limit,args.boundary_limit,uniformity)) as pool:
        for i,(split,c,h,raw_count) in enumerate(pool.map(measure,manifest['items'],chunksize=8)):
            counts[split]+=c;histograms[split]+=h;raw_counts[split]+=raw_count
            if (i+1)%500==0:print(f'Chroma policy evidence {i+1}/{len(manifest["items"])}',flush=True)
    with np.load(args.raw_reference) as raw:
        for split,c in counts.items():
            if not np.array_equal(raw_counts[split],raw[split+'_base']):raise ValueError('Native vote raw completion does not match reference counts')
    reference=read(args.reference);baseline=np.stack([counts[s].sum(0) for s in ['train','dev','test']])
    params,first=profiles(histograms,0);other,second=profiles(histograms,1)
    raw_tp=int(baseline[:,0].sum());gt=int(baseline[:,0].sum()+baseline[:,2].sum())
    test_loss=int(baseline[2,0]-reference['bySplit']['test']['TP'])
    results={}
    for label,maximum_loss in [('recallFloor',raw_tp-(gt*999+999)//1000),
                               ('preserveReferenceRecall',raw_tp-reference['all']['TP'])]:
        (a,b,delta),statistics=select_pair(first,second,baseline,maximum_loss,test_loss)
        measured=baseline+np.stack([-delta[:,0],-delta[:,1],delta[:,0]],axis=1)
        results[label]=dict(achromatic=params[a],chromatic=other[b],chromaThreshold=args.chroma_threshold,
            radius=1,primarySeedThreshold=.5,boundarySeedThreshold=.3,**metrics(measured.sum(0)),
            bySplit={s:metrics(c) for s,c in zip(['train','dev','test'],measured)},search=statistics)
    save(args.out/'SEARCH.json',dict(selected=results,GTChanged=False,GTAtInference=False,perCaseRules=False,
        freshFinalHoldout=False,testUsedForSelection=True,actualNativeVoteObservations=True,
        nativeValidated=False,preUniformityGate=uniformity,seconds=time.monotonic()-start,instances=len(manifest['items'])))
    args.out.mkdir(parents=True,exist_ok=True)
    np.savez_compressed(args.out/'COUNTS.npz',**histograms,**{s+'_base':c for s,c in counts.items()})
    print(json.dumps(dict(selected=results,seconds=time.monotonic()-start),indent=2),flush=True)


if __name__=='__main__':main()
