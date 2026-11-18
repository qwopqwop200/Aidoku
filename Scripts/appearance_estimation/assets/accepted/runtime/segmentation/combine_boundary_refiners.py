#!/usr/bin/env python3
"""Combine compatible source-only boundary forests and their exact DEV votes."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

import numpy as np

from evaluate_gt import read, save, sha
from pixel_rfdetr_fusion import merge_forests


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--input',type=Path,action='append',required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--predictions-only',action='store_true')
    parser.add_argument('--split',choices=['dev','test','all'],default='dev')
    args=parser.parse_args();folders=[p.resolve() for p in args.input];out=args.out.resolve()
    if len(folders)<2:parser.error('At least two component forests required')
    metadata=[read(p/'full-rf-PIXEL-MODEL-TRAINING.json') for p in folders]
    keys=['featureNames','featureCount','primaryModelSHA256','manifestSHA256','richEvidence',
          'OOFReceiptSHA256','teacherTrainingProbabilities']
    if any(any(m.get(k)!=metadata[0].get(k) for k in keys) for m in metadata[1:]):
        raise ValueError('Incompatible feature/source-group contracts')
    if not metadata[0].get('richEvidence') or metadata[0].get('teacherTrainingProbabilities')!='excluded-source OOF':
        raise ValueError('Require validated source-group OOF refiners')
    for folder,m in zip(folders,metadata):
        if sha(folder/'evaluation-manifest.json')!=m['manifestSHA256']:
            raise ValueError('Manifest changed')
        if read(folder/'PROTOTYPE-STATE.json')['status']!='development-evaluated':
            raise ValueError('Component DEV prediction incomplete')
    out.mkdir(parents=True,exist_ok=True)
    for name in ['evaluation-manifest.json','baseline']:
        if not (out/name).exists():(out/name).symlink_to(folders[0]/name)
    paths=[p/'full-rf-pixel-fusion-model.json' for p in folders]
    components=[dict(modelSHA256=sha(p),trees=m['trees'],sampledPixels=m.get('sampledPixels'),
            hardSamplesPerClass=m.get('hardSamplesPerClass',0)) for p,m in zip(paths,metadata)]
    if args.predictions_only:
        existing=read(out/'full-rf-PIXEL-MODEL-TRAINING.json')
        if existing['componentForests']!=components:raise ValueError('Combined model components changed')
    else:
        merge_forests(paths,out/'full-rf-pixel-fusion-model.json',allow_mixed_training=True)
    training={k:metadata[0][k] for k in keys}
    training.update(trees=sum(m['trees'] for m in metadata),runtimeReadsGT=False,caseIdentityFeatures=False,
        featureVariant='contextual-boundary-research-v2-rich',nativeExportSupported=False,
        componentForests=components)
    if not args.predictions_only:save(out/'full-rf-PIXEL-MODEL-TRAINING.json',training)
    rows=[r for r in read(out/'evaluation-manifest.json')['items'] if args.split=='all' or r['split']==args.split]
    probabilities=out/'full-rf-dev-probabilities';probabilities.mkdir(exist_ok=True)
    records=[]
    for row in rows:
        total=np.zeros((row['height'],row['width']),np.int32)
        sources=[]
        for folder,m in zip(folders,metadata):
            source=folder/'full-rf-dev-probabilities'/f'{row["id"]}.npz'
            with np.load(source) as data:
                probability=data['probability'].astype(np.float32)
            sources.append(dict(path=str(source),SHA256=sha(source)))
            votes=probability*m['trees'];rounded=np.rint(votes)
            if probability.shape!=total.shape or not np.isfinite(votes).all() or np.max(np.abs(votes-rounded))>.04:
                raise ValueError('Invalid component vote cache')
            if rounded.min()<0 or rounded.max()>m['trees']:raise ValueError('Out-of-range votes')
            total+=rounded.astype(np.int32)
        destination=probabilities/f'{row["id"]}.npz'
        np.savez_compressed(destination,probability=(total/training['trees']).astype(np.float16))
        records.append(dict(id=row['id'],SHA256=sha(destination),components=sources))
    save(out/f'PREDICTIONS-{args.split}-COMPLETE.json',dict(modelSHA256=sha(out/'full-rf-pixel-fusion-model.json'),
        manifestSHA256=sha(out/'evaluation-manifest.json'),trainingSHA256=sha(out/'full-rf-PIXEL-MODEL-TRAINING.json'),
        records=records,exactComponentVoteCombination=True,GTMaskRead=False))
    if args.predictions_only:
        print(f'Combined {len(rows)} {args.split} vote caches without repeated inference',flush=True)
        return
    if args.split!='dev':raise ValueError('Calibration requires the DEV split')
    subprocess.run([sys.executable,str(Path(__file__).with_name('hysteresis_completion.py')),
        '--out',str(out),'--results',str(out/'calibration'),'--minimum-recall','.9993',
        '--dense','--kernel','ellipse','--objective','microIoU'],check=True)
    selected=read(out/'calibration/HYSTERESIS-DENSE-ELLIPSE-SEARCH.json')['selected']
    save(out/'PROTOTYPE-STATE.json',dict(status='development-evaluated',selected=selected,
        nativeExportSupported=False,GTChanged=False,heldoutTestOpened=False,nativeMasksProduced=False,
        exactComponentVoteCombination=True,DEVInstances=len(rows)))
    print(json.dumps(dict(selected=selected),indent=2),flush=True)


if __name__=='__main__':main()
