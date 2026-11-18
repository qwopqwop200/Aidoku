#!/usr/bin/env python3
"""Replay shared native policies from authenticated native source votes only."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import numpy as np

from evaluate_gt import read, save, sha
from native_boundary_refiner import export_model, build
from native_predict import classifier_identity, observation_contract, load_classifier_observation


def cache_path(cache, contract):
    key=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return cache/f'{key}.npz'


def predict(payload):
    rows,base,primary_cache,producer,boundary_cache,out,worker=payload
    base,primary_cache,producer,boundary_cache,out=map(Path,(base,primary_cache,producer,boundary_cache,out))
    primary_identity,primary_trees=classifier_identity(base/'recall-full-rf-native-pixel-forest.json')
    primary_binary=sha(base/'native-pixel-rf-segmentation')
    boundary_identity,boundary_trees=classifier_identity(producer/'boundary-forest.json')
    if classifier_identity(out/'boundary-forest.json')!=(boundary_identity,boundary_trees):
        raise ValueError('Replay would use votes from a different boundary classifier')
    boundary_binary=sha(producer/'native-boundary-refiner');records=[]
    with tempfile.TemporaryDirectory(prefix=f'policy-{worker}-',dir=out) as work:
        work=Path(work)
        with (out/f'worker-{worker}.stderr').open('w') as stderr:
            proc=subprocess.Popen([str(out/'native-boundary-refiner'),str(out/'boundary-forest.json')],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,text=True)
            try:
                for i,row in enumerate(rows):
                    primary_contract=observation_contract(row,base,primary_identity,primary_binary,True)
                    primary=load_classifier_observation(cache_path(primary_cache,primary_contract),primary_contract,primary_trees)
                    boundary_contract=observation_contract(row,base,boundary_identity,boundary_binary,True)
                    boundary_contract.update(primaryClassifierSHA256=primary_identity,primaryExecutableSHA256=primary_binary,
                        schema='source-boundary-classifier-observation-v1')
                    boundary=load_classifier_observation(cache_path(boundary_cache,boundary_contract),boundary_contract,boundary_trees)
                    if primary is None or boundary is None:raise ValueError('Missing or stale source-bound classifier votes')
                    p,base_mask=primary;q,other_base=boundary
                    if not np.array_equal(base_mask,other_base):raise ValueError('Classifier observations disagree on source extraction')
                    p.tofile(work/'primary.f32');q.tofile(work/'boundary.f32');base_mask.tofile(work/'base.u8')
                    destination=out/'native-masks'/f'{row["id"]}.u8'
                    message=dict(rgb=row['rgb'],primary=str(work/'primary.f32'),boundaryProbabilities=str(work/'boundary.f32'),
                        nativeMask=str(work/'base.u8'),coarseRF='',fullRF='',width=row['width'],height=row['height'],
                        fontPixels=row['fontPixels'],output=str(destination),constrainExpansion=True)
                    proc.stdin.write(json.dumps(message)+'\n');proc.stdin.flush();response=proc.stdout.readline()
                    if not response:raise RuntimeError(f'Native policy failed: {row["id"]}')
                    if destination.stat().st_size!=row['width']*row['height']:raise ValueError('Native mask has wrong size')
                    audit=json.loads(response)
                    if not audit.get('boundaryObservationReused') or audit.get('GTRead') is not False:
                        raise ValueError('Replay source contract not acknowledged')
                    records.append(dict(id=row['id'],**audit))
                    if (i+1)%200==0:print(f'Native policy worker{worker}: {i+1}/{len(rows)}',flush=True)
                proc.stdin.close()
                if proc.wait():raise RuntimeError('Native policy replay failed')
            finally:
                if proc.poll() is None:proc.terminate();proc.wait()
    return records


def main():
    parser=argparse.ArgumentParser()
    for name in ['base','refiner','primary-cache','producer','boundary-cache','out','gate-policy']:
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--build-only',action='store_true')
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    base,refiner,producer=args.base.resolve(),args.refiner.resolve(),args.producer.resolve()
    if not (out/'evaluation-manifest.json').exists():(out/'evaluation-manifest.json').symlink_to(base/'evaluation-manifest.json')
    export_model(base,refiner,out,args.gate_policy);build(out)
    if args.build_only:return
    manifest=read(base/'evaluation-manifest.json');run=read(producer/'NATIVE-RUN.json')
    if run.get('boundaryObservationsCaptured')!=len(manifest['items']):
        raise ValueError('Source boundary producer has not completed the fixed corpus')
    fields=['id','rgb','rf','width','height','polygons','fontPixels'];rows=[{k:r[k] for k in fields} for r in manifest['items']]
    (out/'native-masks').mkdir(exist_ok=True);start=time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads=[(rows[i::args.jobs],str(base),str(args.primary_cache.resolve()),str(producer),
            str(args.boundary_cache.resolve()),str(out),i) for i in range(args.jobs)]
        records=[r for group in pool.map(predict,payloads) for r in group]
    save(out/'NATIVE-RUN.json',dict(instances=len(records),seconds=time.monotonic()-start,records=records,
        GTMaskReadByPredictor=False,sourceBoundPrimaryReused=True,sourceBoundBoundaryReused=True,
        nativeBoundaryFeaturesAndForestExecuted=False,sharedNativeCompletionExecuted=True,
        boundaryProducer=str(producer),boundaryProducerSHA256=sha(producer/'native-boundary-refiner')))
    subprocess.run([sys.executable,str(Path(__file__).with_name('evaluate_gt.py')),'score','--out',str(out),
        '--predictions',str(out/'native-masks'),'--split','all'],check=True)
    score=read(out/'native-masks-scores.json');save(out/'RESULT.json',dict(all=score['all'],bySplit=score['bySplit'],
        meetsRecallFloor=score['all']['recall']>=.999,GTChanged=False,productionEnabled=False,
        fullProductionPipeline=False,nativePolicyReplay=True,fullClassifiersExecutedThisRun=False))


if __name__=='__main__':main()
