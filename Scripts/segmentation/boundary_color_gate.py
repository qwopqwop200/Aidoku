#!/usr/bin/env python3
"""Source-color corroboration for uncertain completion fringes, no GT features."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image

from boundary_rf_gate import metrics
from evaluate_gt import read, save, sha
from native_predict import load_classifier_observation
from hysteresis_completion import save_trial_report


RADII=[1,2,3]
TOLERANCES=[-1,*range(256)]
PRIMARY_LIMIT=8
BOUNDARY_LIMIT=4


def source_color_distances(rgb, seeds, positions, radii=RADII):
    """Nearest seed RGB L-infinity distance in bounded square neighborhoods."""
    height,width=seeds.shape;y,x=positions//width,positions%width
    colors=rgb.reshape(-1,3)[positions].astype(np.int16)
    nearest=np.full(len(positions),256,np.int16);result=[]
    for radius in range(1,max(radii)+1):
        offsets=[(dy,dx) for dy in range(-radius,radius+1) for dx in range(-radius,radius+1)
                 if radius==1 or max(abs(dx),abs(dy))==radius]
        for dy,dx in offsets:
            sy,sx=y+dy,x+dx;valid=(sy>=0)&(sy<height)&(sx>=0)&(sx<width)
            index=np.flatnonzero(valid)
            index=index[seeds[sy[index],sx[index]]]
            if not len(index):continue
            distance=np.max(np.abs(colors[index]-rgb[sy[index],sx[index]].astype(np.int16)),axis=1)
            nearest[index]=np.minimum(nearest[index],distance)
        if radius in radii:result.append(nearest.copy())
    return result


def measure(payload):
    row,primary,refiner,cache=payload;primary,refiner,cache=map(Path,(primary,refiner,cache))
    contract=read(primary/f'recall-full-rf-native-{row["split"]}/receipts/{row["id"]}.json')['contract']['observation']
    key=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    observation=load_classifier_observation(cache/f'{key}.npz',contract,64)
    if observation is None:raise ValueError('Unverified source observation')
    p,_=observation
    with np.load(refiner/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:q=data['probability'].astype(np.float32)
    mask=np.fromfile(refiner/'python-research-all'/f'{row["id"]}.u8',np.uint8).reshape(p.shape)>0
    pv=np.rint(p*64).astype(np.uint8);qv=np.rint(q*48).astype(np.uint8)
    positions=np.flatnonzero((mask&(pv<PRIMARY_LIMIT)&(qv<BOUNDARY_LIMIT)).ravel())
    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
    distances=source_color_distances(rgb,(p>=.5)|(q>=.3),positions)
    # All candidate positions, votes and RGB distances above are source-only.
    if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
    target=np.asarray(Image.open(row['target']))>0;labels=target.ravel()[positions]
    histograms=[]
    for distance in distances:
        size=PRIMARY_LIMIT*BOUNDARY_LIMIT*257;shape=(PRIMARY_LIMIT,BOUNDARY_LIMIT,257)
        code=(pv.ravel()[positions].astype(np.int64)*BOUNDARY_LIMIT+qv.ravel()[positions])*257+distance
        histograms.append(np.stack([np.bincount(code[labels],minlength=size).reshape(shape),
                                   np.bincount(code[~labels],minlength=size).reshape(shape)]))
    counts=np.array([np.count_nonzero(mask&target),np.count_nonzero(mask&~target),np.count_nonzero(~mask&target)],np.int64)
    return row['split'],counts,np.stack(histograms)


def main():
    parser=argparse.ArgumentParser()
    for name in ['primary','refiner','cache','reference','out']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    args=parser.parse_args();manifest=read(args.primary/'evaluation-manifest.json');start=time.monotonic()
    if len(read(args.primary/'recall-full-rf-native-pixel-forest.json')['trees'])!=64 or read(args.refiner/'full-rf-PIXEL-MODEL-TRAINING.json')['trees']!=48:
        raise ValueError('This calibration contract requires the frozen64/48-tree pair')
    counts={s:np.zeros(3,np.int64) for s in ['train','dev','test']}
    histograms={s:np.zeros((len(RADII),2,PRIMARY_LIMIT,BOUNDARY_LIMIT,257),np.int64) for s in counts}
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads=[(r,str(args.primary),str(args.refiner),str(args.cache)) for r in manifest['items']]
        for i,(split,c,h) in enumerate(pool.map(measure,payloads,chunksize=8)):
            counts[split]+=c;histograms[split]+=h
            if (i+1)%400==0:print(f'Color evidence gate {i+1}/{len(payloads)}',flush=True)
    reference=read(args.reference)
    for split,h in histograms.items():
        tp,fp=h[0,:,:1,:1,:].sum(axis=(1,2,3));baseline=counts[split]+[-tp,-fp,tp]
        if tuple(baseline)!=tuple(reference['bySplit'][split][k] for k in ['TP','FP','FN']):
            raise ValueError('Zero-color endpoint differs from actual native reference')
    trials=[]
    for i,radius in enumerate(RADII):
        for p in range(1,PRIMARY_LIMIT+1):
            for q in range(1,BOUNDARY_LIMIT+1):
                for tolerance in TOLERANCES:
                    measured={}
                    for split,h in histograms.items():
                        tp,fp=h[i,:,:p,:q,tolerance+1:].sum(axis=(1,2,3))
                        measured[split]=counts[split]+[-tp,-fp,tp]
                    trials.append(dict(primaryVotes=p,boundaryVotes=q,radius=radius,colorTolerance=tolerance,
                        primarySeedThreshold=.5,boundarySeedThreshold=.3,**metrics(sum(measured.values())),
                        bySplit={s:metrics(c) for s,c in measured.items()}))
    eligible=[t for t in trials if t['recall']>=.999]
    best=max(eligible,key=lambda t:t['microIoU']) if eligible else None
    dev=[t for t in trials if t['bySplit']['dev']['recall']>=.999]
    best_dev=max(dev,key=lambda t:t['bySplit']['dev']['microIoU']) if dev else None
    preserved=[t for t in trials if t['recall']>=reference['all']['recall'] and
               t['bySplit']['test']['recall']>=reference['bySplit']['test']['recall']]
    best_preserved=max(preserved,key=lambda t:t['microIoU']) if preserved else None
    save_trial_report(args.out/'SEARCH.json',dict(bestObservedCorpus=best,selectedDev=best_dev,
        selectedPreserveFullAndTestRecall=best_preserved,trials=trials,
        sourceOnlyAtInference=True,perCaseRules=False,GTChanged=False,nativeValidated=False,
        primaryModelSHA256=sha(args.primary/'recall-full-rf-native-pixel-forest.json'),
        refinerModelSHA256=sha(args.refiner/'full-rf-pixel-fusion-model.json'),
        manifestSHA256=sha(args.primary/'evaluation-manifest.json'),
        freshFinalHoldout=False,seconds=time.monotonic()-start,instances=len(manifest['items'])))
    np.savez_compressed(args.out/'COUNTS.npz',**histograms,**{s+'_base':c for s,c in counts.items()})
    print(json.dumps(dict(best=best,selectedDev=best_dev,selectedPreserved=best_preserved,seconds=time.monotonic()-start),indent=2),flush=True)


if __name__=='__main__':main()
