#!/usr/bin/env python3
"""Native 55-feature boundary inference over source-authenticated primary votes."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import numpy as np

from evaluate_gt import ROOT,read,save,sha
from native_predict import classifier_identity,observation_contract,load_classifier_observation
from prepare_full_rf import load_case_features
from export_forest import flatten,collapse_constant_branches


def export_model(base,refiner,out,gate_policy=None):
    training=read(refiner/'full-rf-PIXEL-MODEL-TRAINING.json')
    source=refiner/'full-rf-pixel-fusion-model.json';model=read(source)['opencv_ml_rtrees']
    count=model['var_count'];edge=count==60 and training.get('featureVariant')=='contextual-boundary-rgb-edges-research-v1'
    if count not in [55,60] or (count==60 and not edge) or model['class_labels']!=[0,1] or not training.get('richEvidence'):
        raise ValueError('Unvalidated research feature contract')
    if training['primaryModelSHA256']!=sha(base/'recall-full-rf-native-pixel-forest.json'):
        raise ValueError('Research primary classifier changed')
    calibration=refiner/'calibration/HYSTERESIS-DENSE-ELLIPSE-SEARCH.json'
    if calibration.exists():chosen=read(calibration)['selected']
    elif edge:chosen=dict(strongThreshold=.5,weakThreshold=.05,kernel='ellipse',radiusFontScale=.08,minimumRadiusPixels=1,maximumRadiusPixels=2)
    else:raise ValueError('Uncalibrated boundary model')
    if chosen is None:raise ValueError('No qualifying DEV completion policy')
    trees=[collapse_constant_branches(flatten(t,count)) for t in model['trees']]
    document=dict(schema=1,featureCount=count,featureNames=training['featureNames'],trees=trees,
        sourceFeatureVariant='pixel-boundary-rgb-edges-rf-v2' if edge else 'pixel-boundary-full-rf-v1',sourceModelSHA256=sha(source),threshold=chosen['strongThreshold'],
        primarySourceModelSHA256=read(base/'recall-full-rf-native-pixel-forest.json')['sourceModelSHA256'],
        completion=dict(unionNative=False,weakThreshold=chosen['weakThreshold'],kernel=chosen['kernel'],
            radiusFontScale=chosen['radiusFontScale'],minimumRadiusPixels=chosen['minimumRadiusPixels'],
            maximumRadiusPixels=chosen['maximumRadiusPixels']))
    if gate_policy:
        gate=read(gate_policy)
        if (gate.get('evaluationSplit') not in ['dev','all'] or gate.get('primaryModelSHA256')!=sha(base/'recall-full-rf-native-pixel-forest.json') or
                gate.get('refinerModelSHA256')!=sha(source) or gate.get('manifestSHA256')!=sha(base/'evaluation-manifest.json') or
                gate.get('GTAtInference') is not False or not gate.get('selected')):
            raise ValueError('Unverified DEV source evidence gate')
        if gate['evaluationSplit']=='all' and (gate.get('freshFinalHoldout') is not False or gate.get('testUsedForSelection') is not True):
            raise ValueError('Observed-corpus calibration must disclose test reuse')
        selected=gate['selected']
        document['boundaryEvidenceGate']=dict(primaryThreshold=selected['primaryFloor'],
            boundaryThreshold=selected['refinerFloor'],includeNativeSupport=selected['nativeSupport'])
        if selected.get('colorCorroboration'):
            document['boundaryEvidenceGate']['colorCorroboration']=selected['colorCorroboration']
        if selected.get('chromaticOverride'):
            document['boundaryEvidenceGate']['chromaticOverride']=selected['chromaticOverride']
        if selected.get('uniformityGate'):
            document['boundaryEvidenceGate']['uniformityGate']=selected['uniformityGate']
        if selected.get('recoveryGate'):
            document['boundaryEvidenceGate']['recoveryGate']=selected['recoveryGate']
    encoded=json.dumps(document,separators=(',',':')).encode()
    if len(encoded)>32*1_048_576:
        document['trees']=[[[n[k] for k in ['feature','threshold','left','right','positive']] for n in t] for t in trees]
        encoded=json.dumps(document,separators=(',',':')).encode()
    if len(encoded)>32*1_048_576 or sum(map(len,trees))>1_000_000:raise ValueError('Native model budget exceeded')
    frozen=out/'FROZEN-CLASSIFIER-PRODUCER.json'
    if frozen.exists() and hashlib.sha256(encoded).hexdigest()!=read(frozen)['modelSHA256']:
        raise ValueError('Frozen boundary producer model cannot be changed in place; choose a new output directory')
    (out/'boundary-forest.json').write_bytes(encoded)


def build(out):
    engine=ROOT/'Aidoku/Aidoku/Core/Translation/NativeEngine'
    sources=[engine/'Layout/NativeRFDETRSemanticGrid.swift',engine/'Layout/NativeRFDETRLayoutModels.swift']
    sources.extend(engine/'Ensemble'/name for name in ['NativeEnsembleRemovalSourceFactory.swift','NativePixelRFFeatures.swift',
        'NativePixelRFForest.swift','NativePixelRFEvidence.swift','NativePixelRFSegmentation.swift',
        'NativePixelRFBoundaryFeatures.swift','NativePixelRFBoundarySegmentation.swift'])
    sources.append(Path(__file__).with_name('NativeBoundaryRefinerReplay.swift'))
    compiler=subprocess.check_output(['xcrun','swiftc','--version'])
    fingerprint=hashlib.sha256(compiler+b''.join(p.read_bytes() for p in sources)).hexdigest()
    receipt=out/'NATIVE-BUILD.json';binary=out/'native-boundary-refiner'
    if receipt.exists() and binary.exists() and read(receipt)['fingerprint']==fingerprint:return binary
    if (out/'FROZEN-CLASSIFIER-PRODUCER.json').exists():
        raise RuntimeError('Frozen boundary producer cannot be rebuilt in place; choose a new output directory')
    cache=ROOT/'Aidoku/build/segmentation-gt-replay-module-cache'
    with (cache/'.compile.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX);start=time.monotonic()
        command=['xcrun','swiftc','-O','-parse-as-library','-module-cache-path',str(cache),*map(str,sources),'-o',str(binary)]
        subprocess.run(command,check=True)
    save(receipt,dict(fingerprint=fingerprint,command=command,seconds=time.monotonic()-start,
        sources={str(p):sha(p) for p in sources},binarySHA256=sha(binary)))
    return binary


def prepare(row,base,cache,identity,trees,producer,scratch,out,feature_mode):
    contract=observation_contract(row,base,identity,producer,True)
    key=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    observed=load_classifier_observation(cache/f'{key}.npz',contract,trees)
    if observed is None:raise ValueError('Primary source observation missing')
    p,native=observed;p.tofile(scratch/'p.f32');native.tofile(scratch/'base.u8')
    with np.load(row['rf']) as data:(data['support'].astype(np.float32)/255).tofile(scratch/'coarse.f32')
    load_case_features(row,base).tofile(scratch/'full.f32')
    output=scratch/'features.f32' if feature_mode else out/'native-masks'/f'{row["id"]}.u8'
    return dict(rgb=row['rgb'],primary=str(scratch/'p.f32'),nativeMask=str(scratch/'base.u8'),
        coarseRF=str(scratch/'coarse.f32'),fullRF=str(scratch/'full.f32'),width=row['width'],height=row['height'],
        fontPixels=row['fontPixels'],output=str(output),constrainExpansion=True)


def parity(base,cache,out,rows):
    from boundary_refiner import source_features
    identity,trees=classifier_identity(base/'recall-full-rf-native-pixel-forest.json');producer=sha(base/'native-pixel-rf-segmentation')
    count=read(out/'boundary-forest.json')['featureCount'];errors=np.zeros(count,np.float64);records=[]
    with tempfile.TemporaryDirectory(prefix='boundary-parity-',dir=out) as scratch:
        scratch=Path(scratch)
        proc=subprocess.Popen([str(out/'native-boundary-refiner'),'--edge-context-features' if count==60 else '--features'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
        try:
            for row in rows:
                message=prepare(row,base,cache,identity,trees,producer,scratch,out,True)
                proc.stdin.write(json.dumps(message)+'\n');proc.stdin.flush()
                if not proc.stdout.readline():raise RuntimeError('Native feature replay failed')
                actual=np.fromfile(message['output'],np.float32).reshape(-1,count)
                expected,_,_=source_features(row,base,cache,rich=True)
                if count==60:
                    from train_edge_boundary import edge_features
                    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
                    expected=np.concatenate([expected,edge_features(rgb,row['fontPixels'])],axis=1)
                error=np.max(np.abs(actual-expected),axis=0);errors=np.maximum(errors,error)
                records.append(dict(id=row['id'],maximumAbsoluteError=float(error.max())))
            proc.stdin.close()
            if proc.wait():raise RuntimeError('Feature replay exited nonzero')
        finally:
            if proc.poll() is None:proc.terminate();proc.wait()
    result=dict(instances=len(rows),maximumAbsoluteError=float(errors.max()),byFeature=errors.tolist(),records=records,
        GTMaskRead=False,nativeMasksProduced=False)
    save(out/'FEATURE-PARITY.json',result)
    print(json.dumps(result,indent=2),flush=True)
    if errors.max()>.0005:raise RuntimeError('Native boundary feature parity exceeded tolerance')


def predict(payload):
    rows,base,cache,out,worker,boundary_cache,save_probabilities=payload;base=Path(base);cache=Path(cache);out=Path(out)
    identity,trees=classifier_identity(base/'recall-full-rf-native-pixel-forest.json');producer=sha(base/'native-pixel-rf-segmentation')
    if boundary_cache:
        boundary_cache=Path(boundary_cache);boundary_cache.mkdir(parents=True,exist_ok=True)
        boundary_identity,boundary_trees=classifier_identity(out/'boundary-forest.json')
        if boundary_trees>255:raise ValueError('Byte vote observations require at most255 trees')
        boundary_binary=sha(out/'native-boundary-refiner')
    records=[]
    with tempfile.TemporaryDirectory(prefix=f'native-boundary-{worker}-',dir=out) as scratch:
        scratch=Path(scratch)
        with (out/f'worker-{worker}.stderr').open('w') as stderr:
            proc=subprocess.Popen([str(out/'native-boundary-refiner'),str(out/'boundary-forest.json')],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,text=True)
            try:
                for i,row in enumerate(rows):
                    message=prepare(row,base,cache,identity,trees,producer,scratch,out,False)
                    if boundary_cache:message['probabilityOutput']=str(scratch/'boundary-probabilities.f32')
                    proc.stdin.write(json.dumps(message)+'\n');proc.stdin.flush();response=proc.stdout.readline()
                    if not response:raise RuntimeError(f'Native boundary failed: {row["id"]}')
                    if Path(message['output']).stat().st_size!=row['width']*row['height']:raise RuntimeError('Invalid native mask size')
                    record=dict(id=row['id'],**json.loads(response))
                    if boundary_cache:
                        contract=observation_contract(row,base,boundary_identity,boundary_binary,True)
                        contract.update(primaryClassifierSHA256=identity,primaryExecutableSHA256=producer,
                            schema='source-boundary-classifier-observation-v1')
                        key=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
                        probability=np.fromfile(message['probabilityOutput'],np.float32).reshape(row['height'],row['width'])
                        votes=np.rint(probability*boundary_trees).astype(np.uint8)
                        if not np.array_equal(votes.astype(np.float32)/np.float32(boundary_trees),probability):
                            raise ValueError('Native boundary votes are not exactly byte-reconstructible')
                        native=np.fromfile(scratch/'base.u8',np.uint8).reshape(probability.shape)
                        destination=boundary_cache/f'{key}.npz'
                        with destination.with_suffix('.lock').open('a') as lock:
                            fcntl.flock(lock,fcntl.LOCK_EX)
                            if load_classifier_observation(destination,contract,boundary_trees) is None:
                                temporary=destination.with_suffix(f'.{os.getpid()}.tmp')
                                with temporary.open('wb') as stream:np.savez_compressed(stream,votes=votes,nativeBase=native)
                                temporary.replace(destination)
                                save(destination.with_suffix('.json'),dict(contract=contract,archiveSHA256=sha(destination),GTRead=False))
                        record['boundaryObservation']=str(destination)
                        if save_probabilities:
                            np.savez_compressed(out/'full-rf-dev-probabilities'/f'{row["id"]}.npz',probability=probability.astype(np.float16))
                    records.append(record)
                    if (i+1)%100==0:print(f'Native boundary worker{worker}: {i+1}/{len(rows)}',flush=True)
                proc.stdin.close()
                if proc.wait():raise RuntimeError('Native boundary replay failed')
            finally:
                if proc.poll() is None:proc.terminate();proc.wait()
    return records


def main():
    parser=argparse.ArgumentParser()
    for key in ['base','refiner','cache','out']:parser.add_argument('--'+key,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--parity-only',action='store_true')
    parser.add_argument('--gate-policy',type=Path)
    parser.add_argument('--boundary-cache',type=Path)
    parser.add_argument('--save-probabilities',action='store_true')
    parser.add_argument('--split',choices=['all','dev','test','train'],default='all')
    args=parser.parse_args();base=args.base.resolve();refiner=args.refiner.resolve();cache=args.cache.resolve();out=args.out.resolve()
    out.mkdir(parents=True,exist_ok=True);manifest=read(base/'evaluation-manifest.json')
    if not (out/'evaluation-manifest.json').exists():(out/'evaluation-manifest.json').symlink_to(base/'evaluation-manifest.json')
    for name in ['full-rf-PIXEL-MODEL-TRAINING.json','full-rf-pixel-fusion-model.json']:
        if not (out/name).exists():(out/name).symlink_to(refiner/name)
    if args.save_probabilities and not args.boundary_cache:parser.error('--save-probabilities requires authenticated --boundary-cache capture')
    export_model(base,refiner,out,args.gate_policy);build(out)
    keys=['id','width','height','rgb','rf','polygons','fontPixels']
    rows=[{k:r[k] for k in keys} for r in manifest['items'] if args.split=='all' or r['split']==args.split]
    sample=sorted(rows,key=lambda r:hashlib.sha256(r['id'].encode()).hexdigest())[:12]
    parity(base,cache,out,sample)
    if args.parity_only:return
    (out/'native-masks').mkdir(exist_ok=True);start=time.monotonic()
    if args.save_probabilities:(out/'full-rf-dev-probabilities').mkdir(exist_ok=True)
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads=[(rows[i::args.jobs],str(base),str(cache),str(out),i,
            str(args.boundary_cache.resolve()) if args.boundary_cache else None,args.save_probabilities) for i in range(args.jobs)]
        records=[r for group in pool.map(predict,payloads) for r in group]
    save(out/('NATIVE-RUN.json' if args.split=='all' else f'NATIVE-RUN-{args.split}.json'),dict(instances=len(records),seconds=time.monotonic()-start,records=records,
        GTMaskReadByPredictor=False,sourceBoundPrimaryReused=True,nativeBoundaryFeaturesAndForestExecuted=True,
        boundaryObservationsCaptured=sum('boundaryObservation' in r for r in records)))
    subprocess.run([sys.executable,str(Path(__file__).with_name('evaluate_gt.py')),'score','--out',str(out),
        '--predictions',str(out/'native-masks'),'--split',args.split],check=True)
    score=read(out/'native-masks-scores.json');save(out/('RESULT.json' if args.split=='all' else f'RESULT-{args.split}.json'),dict(all=score['all'],bySplit=score['bySplit'],
        meetsRecallFloor=score['all']['recall']>=.999,GTChanged=False,productionEnabled=False,fullProductionPipeline=False))


if __name__=='__main__':main()
