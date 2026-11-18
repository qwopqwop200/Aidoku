#!/usr/bin/env python3
"""Study source-evidence gating of expansion fringes; no instance exceptions."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image

from evaluate_gt import read,save,sha
from native_predict import load_classifier_observation


def measure(payload):
    row,primary,refiner,cache,settings,trees=payload;primary=Path(primary);refiner=Path(refiner);cache=Path(cache)
    receipt=read(primary/f'recall-full-rf-native-{row["split"]}/receipts/{row["id"]}.json')
    contract=receipt['contract']['observation']
    key=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    observation=load_classifier_observation(cache/f'{key}.npz',contract,trees)
    if observation is None:raise ValueError('Unverified primary observation')
    p,native=observation
    with np.load(refiner/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:q=data['probability'].astype(np.float32)
    mask_path=refiner/'python-research-all'/f'{row["id"]}.u8'
    if not mask_path.exists():mask_path=refiner/f'python-research-{row["split"]}'/f'{row["id"]}.u8'
    mask=np.fromfile(mask_path,np.uint8).reshape(p.shape)>0
    gates=[(p>=s['primaryFloor'])|(q>=s['refinerFloor'])|((native>0) if s['nativeSupport'] else False) for s in settings]
    # All inputs to gate membership above are source observations/predictions.
    if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
    target=np.asarray(Image.open(row['target']))>0
    result=[]
    for gate in gates:
        m=mask&gate;tp=np.count_nonzero(m&target);fp=np.count_nonzero(m&~target);fn=np.count_nonzero(~m&target)
        result.append([tp,fp,fn])
    return row['split'],np.array(result,np.int64)


def main():
    parser=argparse.ArgumentParser()
    for name in ['primary','refiner','cache','out']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--split',choices=['all','dev','test'],default='all')
    args=parser.parse_args();manifest=read(args.primary/'evaluation-manifest.json')
    rows=[r for r in manifest['items'] if args.split=='all' or r['split']==args.split]
    primary_trees=len(read(args.primary/'recall-full-rf-native-pixel-forest.json')['trees'])
    refiner_trees=read(args.refiner/'full-rf-PIXEL-MODEL-TRAINING.json')['trees']
    settings=[dict(primaryFloor=max(0,(p-.5)/primary_trees),refinerFloor=(q-.5)/refiner_trees,nativeSupport=n)
        for p in [0,1,2,3,4] for q in [1,2,3] for n in [False,True]]
    counts={s:np.zeros((len(settings),3),np.int64) for s in ['train','dev','test'] if any(r['split']==s for r in rows)};start=time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads=[(r,str(args.primary),str(args.refiner),str(args.cache),settings,primary_trees) for r in rows]
        for i,(split,data) in enumerate(pool.map(measure,payloads,chunksize=8)):
            counts[split]+=data
            if (i+1)%500==0:print(f'Expansion evidence gate {i+1}/{len(payloads)}',flush=True)
    total=sum(counts.values());trials=[]
    for i,setting in enumerate(settings):
        tp,fp,fn=map(int,total[i]);trials.append(dict(**setting,TP=tp,FP=fp,FN=fn,recall=tp/(tp+fn),
            microIoU=tp/(tp+fp+fn),bySplit={s:dict(recall=float(v[i,0]/(v[i,0]+v[i,2])),microIoU=float(v[i,0]/v[i].sum())) for s,v in counts.items()}))
    eligible=[t for t in trials if t['recall']>=.999];selected=max(eligible,key=lambda t:t['microIoU']) if eligible else None
    save(args.out/'GATE-SEARCH.json',dict(selected=selected,trials=trials,seconds=time.monotonic()-start,
        GTAtInference=False,nativeValidated=False,GTChanged=False,evaluationSplit=args.split,
        primaryModelSHA256=sha(args.primary/'recall-full-rf-native-pixel-forest.json'),
        refinerModelSHA256=sha(args.refiner/'full-rf-pixel-fusion-model.json'),
        manifestSHA256=sha(args.primary/'evaluation-manifest.json'),
        parameterSelection='Observed corpus, global source thresholds'))
    print(json.dumps(dict(selected=selected,seconds=time.monotonic()-start),indent=2),flush=True)


if __name__=='__main__':main()
