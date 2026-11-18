#!/usr/bin/env python3
"""Native rescue evaluation; immutable primary outputs, source-only RF inputs."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import numpy as np

from evaluate_gt import ROOT,read,save,sha
from native_predict import classifier_identity,observation_contract,load_classifier_observation
from rf_weak_rescue import owner_text_sfx_support


def build(out):
    engine=ROOT/'Aidoku/Aidoku/Core/Translation/NativeEngine'
    sources=[engine/'Layout/NativeRFDETRSemanticGrid.swift',engine/'Layout/NativeRFDETRLayoutModels.swift']
    sources.extend(engine/'Ensemble'/name for name in ['NativeEnsembleRemovalSourceFactory.swift',
        'NativePixelRFFeatures.swift','NativePixelRFForest.swift','NativePixelRFEvidence.swift','NativePixelRFSegmentation.swift'])
    sources.append(Path(__file__).with_name('NativeRFWeakRescueReplay.swift'))
    compiler=subprocess.check_output(['xcrun','swiftc','--version'])
    fingerprint=hashlib.sha256(compiler+b''.join(p.read_bytes() for p in sources)).hexdigest()
    binary=out/'native-rf-weak-rescue';receipt=out/'NATIVE-RESCUE-BUILD.json'
    if binary.exists() and receipt.exists() and read(receipt)['fingerprint']==fingerprint:return binary
    cache=ROOT/'Aidoku/build/segmentation-gt-replay-module-cache'
    with (cache/'.compile.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        start=time.monotonic();command=['xcrun','swiftc','-O','-parse-as-library','-module-cache-path',str(cache),
            *map(str,sources),'-o',str(binary)]
        subprocess.run(command,check=True)
    save(receipt,dict(fingerprint=fingerprint,seconds=time.monotonic()-start,command=command,
        sources={str(p):sha(p) for p in sources},binarySHA256=sha(binary)))
    return binary


def predict(payload):
    rows,base,narrow,cache,out,worker=payload
    base=Path(base);narrow=Path(narrow);cache=Path(cache);out=Path(out)
    identity,trees=classifier_identity(base/'recall-full-rf-native-pixel-forest.json')
    primary_binary=sha(base/'native-pixel-rf-segmentation');narrow_model=sha(narrow/'recall-full-rf-native-pixel-forest.json')
    policy=read(out/'POLICY.json');records=[]
    with tempfile.TemporaryDirectory(prefix=f'rescue-{worker}-',dir=out) as scratch:
        scratch=Path(scratch)
        with (out/f'worker-{worker}.stderr').open('w') as err:
            proc=subprocess.Popen([str(out/'native-rf-weak-rescue'),str(out/'POLICY.json')],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True)
            try:
                for i,row in enumerate(rows):
                    contract=observation_contract(row,base,identity,primary_binary,True)
                    key=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
                    observed=load_classifier_observation(cache/f'{key}.npz',contract,trees)
                    if observed is None:raise ValueError(f'Primary source observation missing: {row["id"]}')
                    probability,_=observed
                    folder=narrow/f'recall-full-rf-native-{row["split"]}'
                    mask_path=folder/f'{row["id"]}.u8';mask=np.fromfile(mask_path,np.uint8).reshape(probability.shape)
                    receipt=read(folder/'receipts'/f'{row["id"]}.json')
                    if (receipt['contract']['observation']!=contract or receipt['contract']['modelSHA256']!=narrow_model or
                            receipt['outputSHA256']!=sha(mask_path)):
                        raise ValueError('Primary source mask provenance changed')
                    positions=np.flatnonzero(((mask==0)&(probability>=policy['probabilityThreshold'])).ravel())
                    support=np.zeros(probability.shape,np.float32)
                    if len(positions):support.ravel()[positions]=owner_text_sfx_support(row,base,positions)
                    probability.tofile(scratch/'p.f32');support.tofile(scratch/'support.f32')
                    destination=out/'native-masks'/f'{row["id"]}.u8'
                    message=dict(mask=str(mask_path),probabilities=str(scratch/'p.f32'),support=str(scratch/'support.f32'),
                        output=str(destination),width=row['width'],height=row['height'])
                    proc.stdin.write(json.dumps(message)+'\n');proc.stdin.flush();response=proc.stdout.readline()
                    if not response:raise RuntimeError(f'Native rescue failed: {row["id"]}')
                    records.append(dict(id=row['id'],**json.loads(response)))
                    if (i+1)%100==0:print(f'Native RF rescue worker{worker}: {i+1}/{len(rows)}',flush=True)
                proc.stdin.close()
                if proc.wait():raise RuntimeError('Native rescue process failed')
            finally:
                if proc.poll() is None:proc.terminate();proc.wait()
    return records


def main():
    parser=argparse.ArgumentParser()
    for key in ['base','narrow','cache','out','search']:parser.add_argument('--'+key,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    search=read(args.search);selected=search['selected']
    floor=search['probabilityThreshold']
    save(out/'POLICY.json',dict(probabilityThreshold=floor,supportThreshold=selected['RFThreshold']))
    manifest=read(args.base/'evaluation-manifest.json');(out/'native-masks').mkdir(exist_ok=True)
    if not (out/'evaluation-manifest.json').exists():(out/'evaluation-manifest.json').symlink_to((args.base/'evaluation-manifest.json').resolve())
    build(out);start=time.monotonic();keys=['id','split','width','height','rgb','rf','polygons','fontPixels']
    rows=[{k:r[k] for k in keys} for r in manifest['items']]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads=[(rows[i::args.jobs],str(args.base.resolve()),str(args.narrow.resolve()),str(args.cache.resolve()),str(out),i) for i in range(args.jobs)]
        records=[r for group in pool.map(predict,payloads) for r in group]
    save(out/'NATIVE-RUN.json',dict(instances=len(records),seconds=time.monotonic()-start,records=records,
        GTMaskReadByPredictor=False,primaryClassifierObservations='authenticated frozen native outputs',
        nativeRescueExecuted=True,fullProductionPipeline=False))
    subprocess.run([sys.executable,str(Path(__file__).with_name('evaluate_gt.py')),'score','--out',str(out),
        '--predictions',str(out/'native-masks'),'--split','all'],check=True)
    score=read(out/'native-masks-scores.json')
    equal=all(score['all'][k]==selected[k] for k in ['TP','FP','FN'])
    save(out/'RESULT.json',dict(all=score['all'],bySplit=score['bySplit'],
        nativeMatchesCalibration=equal,meetsRecallFloor=score['all']['recall']>=.999,
        parameters=read(out/'POLICY.json'),GTChanged=False,productionEnabled=False,
        fullProductionPipeline=False,calibrationScope='previously observed corpus; global thresholds, no case rules'))
    if not equal:raise RuntimeError('Native rescue and source-bound calibration differ')


if __name__=='__main__':main()
