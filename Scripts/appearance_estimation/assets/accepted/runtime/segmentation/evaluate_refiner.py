#!/usr/bin/env python3
"""Heldout research evaluation, explicitly not a native runtime mask claim."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import subprocess
import sys
import time

import cv2
import numpy as np

from boundary_refiner import predict_case
from evaluate_gt import read,save,sha

cv2.setNumThreads(1)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--base',type=Path,required=True)
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--split',choices=['test','all'],default='test')
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--reuse-component-probabilities',action='store_true')
    args=parser.parse_args();out=args.out.resolve();args.base=args.base.resolve();args.cache=args.cache.resolve()
    manifest=read(out/'evaluation-manifest.json');report=out/'calibration/HYSTERESIS-DENSE-ELLIPSE-SEARCH.json'
    model=out/'full-rf-pixel-fusion-model.json';selected=read(report)['selected']
    frozen=out/'REFINER-FROZEN-CANDIDATE.json'
    contract=dict(modelSHA256=sha(model),calibrationSHA256=sha(report),manifestSHA256=sha(out/'evaluation-manifest.json'),
        selectionSplit='dev',testUsedForSelection=False,prototypeOnly=True,nativeExportSupported=False)
    if frozen.exists() and read(frozen)!=contract:raise ValueError('Research candidate changed after freeze')
    save(frozen,contract)
    rows=[r for r in manifest['items'] if args.split=='all' or r['split']==args.split]
    keys=['id','rgb','rf','width','height','polygons','fontPixels']
    inputs=[({k:r[k] for k in keys},str(args.base),str(args.cache),str(out)) for r in rows]
    start=time.monotonic()
    if args.reuse_component_probabilities:
        receipt=read(out/f'PREDICTIONS-{args.split}-COMPLETE.json')
        if (receipt['modelSHA256']!=sha(model) or receipt['manifestSHA256']!=sha(out/'evaluation-manifest.json') or
                receipt['trainingSHA256']!=sha(out/'full-rf-PIXEL-MODEL-TRAINING.json') or
                not receipt.get('exactComponentVoteCombination') or receipt.get('GTMaskRead') or
                {r['id'] for r in receipt['records']}!={r['id'] for r in rows}):
            raise ValueError('Unverified combined probability cache')
        for record in receipt['records']:
            if sha(out/'full-rf-dev-probabilities'/f'{record["id"]}.npz')!=record['SHA256']:
                raise ValueError('Combined probability cache changed')
            if any(sha(p['path'])!=p['SHA256'] for p in record['components']):
                raise ValueError('Component probability cache changed')
    else:
        with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            for i,_ in enumerate(pool.map(predict_case,inputs,chunksize=4)):
                if (i+1)%100==0:print(f'Refiner research {args.split} {i+1}/{len(rows)}',flush=True)
    destination=out/f'python-research-{args.split}';destination.mkdir(exist_ok=True)
    for row in rows:
        with np.load(out/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:p=data['probability'].astype(np.float32)
        radius=min(selected['maximumRadiusPixels'],max(selected['minimumRadiusPixels'],round(row['fontPixels']*selected['radiusFontScale'])))
        seed=(p>=selected['strongThreshold']).astype(np.uint8)
        mask=cv2.dilate(seed,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(2*radius+1,2*radius+1)))>0
        mask|=p>=selected['weakThreshold']
        (mask.astype(np.uint8)*255).tofile(destination/f'{row["id"]}.u8')
    subprocess.run([sys.executable,str(Path(__file__).with_name('evaluate_gt.py')),'score','--out',str(out),
        '--predictions',str(destination),'--split',args.split],check=True)
    result=read(out/f'{destination.name}-scores.json')
    save(out/f'RESEARCH-{args.split.upper()}-RESULT.json',dict(all=result['all'],bySplit=result['bySplit'],
        seconds=time.monotonic()-start,prototypeOnly=True,nativeMasksProduced=False,testUsedForSelection=False,
        nativeIntegrationRequired=True,GTChanged=False))


if __name__=='__main__':main()
