#!/usr/bin/env python3
"""Research-only contextual boundary forest over verified native observations.

No native promotion: source-group DEV must improve before adding a runtime
feature contract. The primary classifier is frozen and never retrained here.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import inspect
import fcntl

import cv2
import numpy as np
from PIL import Image

from evaluate_gt import read,save,sha
from native_predict import classifier_identity,observation_contract,load_classifier_observation
from pixel_rfdetr_fusion import fit_shard,merge_forests
from prepare_full_rf import load_case_features,FEATURE_NAMES

cv2.setNumThreads(1)
_PRIMARY=None


def validate_oof(manifest,receipt,protocol):
    train=[r for r in manifest['items'] if r['split']=='train']
    groups={r['sourceGroup'] for r in train}
    folds={p['fold']:p for p in protocol['folds']}
    if set(folds)!={0,1,2} or set(receipt['foldByItem'])!={r['id'] for r in train}:
        raise ValueError('Incomplete source-group cross fitting')
    seen={}
    for row in train:
        fold=receipt['foldByItem'][row['id']];partition=folds[fold]
        included=set(partition['trainingGroups']);excluded=set(partition['excludedGroups'])
        if (included&excluded or included|excluded!=groups or row['sourceGroup'] not in excluded or
                (row['sourceGroup'] in seen and seen[row['sourceGroup']]!=fold)):
            raise ValueError('Source-group teacher leakage')
        seen[row['sourceGroup']]=fold


def source_features(row,base,cache,training_probability=None,rich=False):
    global _PRIMARY
    base=Path(base);cache=Path(cache)
    if _PRIMARY is None:
        identity,trees=classifier_identity(base/'recall-full-rf-native-pixel-forest.json')
        _PRIMARY=(identity,trees,sha(base/'native-pixel-rf-segmentation'))
    identity,trees,binary=_PRIMARY
    contract=observation_contract(row,base,identity,binary,True)
    key=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    cached=load_classifier_observation(cache/f'{key}.npz',contract,trees)
    if cached is None:raise ValueError(f'Unverified primary observation: {row["id"]}')
    probability,native=cached
    if training_probability:
        with np.load(training_probability) as data:probability=data['probability'].astype(np.float32)
        if probability.shape!=native.shape or not np.isfinite(probability).all() or probability.min()<0 or probability.max()>1:
            raise ValueError('Invalid excluded-source teacher probabilities')
    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3).astype(np.float32)/255
    luminance=rgb[:,:,0]*.2126+rgb[:,:,1]*.7152+rgb[:,:,2]*.0722
    with np.load(row['rf']) as data:rf=data['support'].astype(np.float32)/255
    planes=[probability,(native>0).astype(np.float32),*[rgb[:,:,c] for c in range(3)],
            luminance,rgb.max(2)-rgb.min(2),*[rf[:,:,c] for c in range(4)]]
    names=['primaryProbability','nativeBase','red','green','blue','luminance','chroma',
           'rfText','rfSFX','rfBalloon','rfFrame']
    for size in [3,5,9]:
        planes.extend([cv2.dilate(probability,np.ones((size,size),np.uint8)),
            cv2.boxFilter(probability,-1,(size,size),borderType=cv2.BORDER_REPLICATE),
            luminance-cv2.boxFilter(luminance,-1,(size,size),borderType=cv2.BORDER_REPLICATE)])
        names.extend([f'primaryMax{size}',f'primaryMean{size}',f'luminanceContrast{size}'])
    for threshold in [.25,.5]:
        distance=cv2.distanceTransform((probability<threshold).astype(np.uint8),cv2.DIST_L1,3)
        planes.append(np.minimum(distance,8)/8);names.append(f'primarySeedDistance{threshold}')
    if rich:
        font=max(1,float(row['fontPixels']));size=max(3,min(65,int(round(font*.25))|1))
        mean=cv2.boxFilter(luminance,-1,(size,size),borderType=cv2.BORDER_REPLICATE)
        variance=np.maximum(0,cv2.boxFilter(luminance*luminance,-1,(size,size),borderType=cv2.BORDER_REPLICATE)-mean*mean)
        planes.extend([cv2.dilate(probability,np.ones((size,size),np.uint8)),
            cv2.boxFilter(probability,-1,(size,size),borderType=cv2.BORDER_REPLICATE),
            luminance-mean,np.sqrt(variance)])
        names.extend(['primaryMaxFontQuarter','primaryMeanFontQuarter','luminanceContrastFontQuarter','luminanceStdFontQuarter'])
        for threshold in [.25,.5]:
            distance=cv2.distanceTransform((probability<threshold).astype(np.uint8),cv2.DIST_L1,3)
            planes.append(np.minimum(distance/font,1));names.append(f'primaryRelativeSeedDistance{threshold}')
        full=load_case_features(row,base)
        planes.extend(full[:,:,c] for c in range(len(FEATURE_NAMES)));names.extend(FEATURE_NAMES)
    matrix=np.stack(planes,axis=2).reshape(-1,len(planes)).astype(np.float32)
    if not np.isfinite(matrix).all():raise ValueError('Nonfinite source boundary features')
    return matrix,names,probability


def sample_case(payload):
    row,base,cache,ordinal,training_probabilities,rich=payload
    # Feature extraction receives no target path/status. Labels enter only
    # below, after source feature construction in the TRAIN partition.
    inputs={k:row[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']}
    override=Path(training_probabilities)/'probabilities'/f'{row["id"]}.npz' if training_probabilities else None
    features,names,p=source_features(inputs,base,cache,override,rich)
    target=np.asarray(Image.open(row['target']))>0
    rng=np.random.default_rng(20261110+ordinal);positions=[]
    near=cv2.dilate(p,np.ones((9,9),np.uint8))>.1
    for mask,count in [(target,128),(~target,128),(target&(p<.75),256),(~target&near,256)]:
        indices=np.flatnonzero(mask.ravel())
        if len(indices):positions.extend(rng.choice(indices,min(count,len(indices)),replace=False))
    positions=np.unique(positions).astype(np.int64)
    return features[positions],target.ravel()[positions].astype(np.int32),names


def sample_hard_case(payload):
    row,base,cache,ordinal,training_probabilities,rich,hard_samples=payload
    inputs={k:row[k] for k in ['id','rgb','rf','width','height','polygons','fontPixels']}
    override=Path(training_probabilities)/'probabilities'/f'{row["id"]}.npz' if training_probabilities else None
    features,names,p=source_features(inputs,base,cache,override,rich)
    target=np.asarray(Image.open(row['target']))>0
    rng=np.random.default_rng(20261110+ordinal);positions=[]
    near=cv2.dilate(p,np.ones((9,9),np.uint8))>.1
    # The low-confidence subset is defined using an excluded-source teacher.
    # Both classes are sampled, avoiding a blanket foreground prior increase.
    groups=[(target,128),(~target,128),(target&(p<.75),256),(~target&near,256),
            (target&(p<.125),hard_samples),(~target&near&(p<.125),hard_samples)]
    for mask,count in groups:
        indices=np.flatnonzero(mask.ravel())
        if len(indices):positions.extend(rng.choice(indices,min(count,len(indices)),replace=False))
    positions=np.unique(positions).astype(np.int64)
    return features[positions],target.ravel()[positions].astype(np.int32),names


_MODEL=None
_RICH=False


def predict_case(payload):
    global _MODEL,_RICH
    row,base,cache,out=payload;out=Path(out)
    if _MODEL is None:
        _MODEL=cv2.ml.RTrees_load(str(out/'full-rf-pixel-fusion-model.json'))
        _RICH=read(out/'full-rf-PIXEL-MODEL-TRAINING.json').get('richEvidence',False)
    features,_,_=source_features(row,base,cache,rich=_RICH)
    result=np.empty(len(features),np.float32)
    for start in range(0,len(features),65536):
        votes=_MODEL.getVotes(features[start:start+65536],0)
        positive=np.flatnonzero(votes[0]==1).item()
        result[start:start+len(votes)-1]=votes[1:,positive]/votes[1:].sum(1)
    np.savez_compressed(out/'full-rf-dev-probabilities'/f'{row["id"]}.npz',
        probability=result.reshape(row['height'],row['width']).astype(np.float16))
    return row['id']


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--base',type=Path,required=True)
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--training-probabilities',type=Path)
    parser.add_argument('--rich-evidence',action='store_true')
    parser.add_argument('--trees',type=int,default=32)
    parser.add_argument('--depth',type=int,default=10)
    parser.add_argument('--minimum-samples',type=int,default=128)
    parser.add_argument('--training-cache',type=Path)
    parser.add_argument('--hard-samples',type=int,default=0)
    args=parser.parse_args();args.base=args.base.resolve();args.cache=args.cache.resolve();out=args.out.resolve()
    if args.hard_samples<0:parser.error('--hard-samples must be nonnegative')
    out.mkdir(parents=True,exist_ok=True);start=time.monotonic()
    manifest=read(args.base/'evaluation-manifest.json');rows=[r for r in manifest['items'] if r['split']=='train']
    if args.training_probabilities:
        receipt=read(args.training_probabilities/'OOF-COMPLETE.json')
        if (receipt['manifestSHA256']!=sha(args.base/'evaluation-manifest.json') or
                receipt['sourceGroupLeakage'] or receipt['DEVAndTestUsed'] or
                set(receipt['foldByItem'])!={r['id'] for r in rows}):
            raise ValueError('Unverified source-group cross fitting')
        validate_oof(manifest,receipt,read(args.training_probabilities/'OOF-PROTOCOL.json'))
        for model in receipt['models']:
            if model['SHA256']!=sha(args.training_probabilities/f'fold-{model["fold"]}.json'):
                raise ValueError('Cross-fitted teacher weights changed')
    for name in ['evaluation-manifest.json','baseline']:
        if not (out/name).exists():(out/name).symlink_to(args.base/name)
    state=dict(status='extracting-training-features',nativeExportSupported=False,GTChanged=False)
    save(out/'PROTOTYPE-STATE.json',state)
    def extract():
        samples=[];labels=[]
        with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            payloads=[(r,str(args.base),str(args.cache),i,str(args.training_probabilities.resolve()) if args.training_probabilities else None,args.rich_evidence) for i,r in enumerate(rows)]
            sampler=sample_case
            if args.hard_samples:
                sampler=sample_hard_case;payloads=[(*p,args.hard_samples) for p in payloads]
            for i,(features,y,names) in enumerate(pool.map(sampler,payloads,chunksize=4)):
                samples.append(features);labels.append(y)
                if (i+1)%250==0:print(f'Boundary feature extraction {i+1}/{len(rows)}',flush=True)
        return np.concatenate(samples),np.concatenate(labels),names
    if args.training_cache:
        args.training_cache=args.training_cache.resolve();args.training_cache.mkdir(parents=True,exist_ok=True)
        contract=dict(manifestSHA256=sha(args.base/'evaluation-manifest.json'),primaryModelSHA256=sha(args.base/'recall-full-rf-native-pixel-forest.json'),
            primaryExecutableSHA256=sha(args.base/'native-pixel-rf-segmentation'),rich=args.rich_evidence,
            featureSourceSHA256=hashlib.sha256((inspect.getsource(source_features)+inspect.getsource(sample_case)).encode()).hexdigest(),
            RFAdapterSHA256=sha(Path(__file__).with_name('prepare_full_rf.py')),
            OOFReceiptSHA256=sha(args.training_probabilities/'OOF-COMPLETE.json') if args.training_probabilities else None)
        if args.hard_samples:
            contract.update(hardSamplesPerClass=args.hard_samples,
                hardSamplingSHA256=hashlib.sha256(inspect.getsource(sample_hard_case).encode()).hexdigest())
        with (args.training_cache/'.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            receipt=args.training_cache/'SAMPLES.json'
            if receipt.exists():
                saved=read(receipt)
                if saved['contract']!=contract:raise ValueError('Training feature cache source mismatch')
                for name in ['features','labels']:
                    if sha(args.training_cache/f'{name}.npy')!=saved[f'{name}SHA256']:raise ValueError('Training feature cache corrupted')
                x=np.load(args.training_cache/'features.npy',mmap_mode='r');y=np.load(args.training_cache/'labels.npy',mmap_mode='r');names=saved['featureNames']
                print(f'Reused {len(y)} verified TRAIN samples',flush=True)
            else:
                x,y,names=extract();np.save(args.training_cache/'features.npy',x);np.save(args.training_cache/'labels.npy',y)
                save(receipt,dict(contract=contract,featureNames=names,featuresSHA256=sha(args.training_cache/'features.npy'),
                    labelsSHA256=sha(args.training_cache/'labels.npy'),trainOnly=True))
    else:x,y,names=extract()
    trees=args.trees
    state['status']='fitting-boundary-forest';save(out/'PROTOTYPE-STATE.json',state)
    with tempfile.TemporaryDirectory(prefix='refiner-fit-',dir=out) as scratch:
        root=Path(scratch)
        for name,value in [('features',x),('labels',y)]:
            if args.training_cache:(root/f'{name}.npy').symlink_to(args.training_cache/f'{name}.npy')
            else:np.save(root/f'{name}.npy',value)
        jobs=min(args.jobs,trees)
        with ProcessPoolExecutor(max_workers=jobs) as pool:
            paths=list(pool.map(fit_shard,[(str(root),i,len(range(i,trees,jobs)),args.depth,args.minimum_samples) for i in range(jobs)]))
        merge_forests(paths,out/'full-rf-pixel-fusion-model.json')
    save(out/'full-rf-PIXEL-MODEL-TRAINING.json',dict(trees=trees,featureNames=names,featureCount=x.shape[1],
        sampledPixels=len(y),sourceGroupedTrainingInstances=len(rows),maximumDepth=args.depth,minimumSamplesToSplit=args.minimum_samples,
        primaryModelSHA256=sha(args.base/'recall-full-rf-native-pixel-forest.json'),
        manifestSHA256=sha(out/'evaluation-manifest.json'),runtimeReadsGT=False,caseIdentityFeatures=False,
        featureVariant='contextual-boundary-research-v2-rich' if args.rich_evidence else 'contextual-boundary-research-v1',
        richEvidence=args.rich_evidence,nativeExportSupported=False))
    training=read(out/'full-rf-PIXEL-MODEL-TRAINING.json')
    training['teacherTrainingProbabilities']='excluded-source OOF' if args.training_probabilities else 'in-sample primary'
    training['OOFReceiptSHA256']=sha(args.training_probabilities/'OOF-COMPLETE.json') if args.training_probabilities else None
    training['hardSamplesPerClass']=args.hard_samples
    save(out/'full-rf-PIXEL-MODEL-TRAINING.json',training)
    state['status']='predicting-development';save(out/'PROTOTYPE-STATE.json',state)
    (out/'full-rf-dev-probabilities').mkdir(exist_ok=True)
    keys=['id','rgb','rf','width','height','polygons','fontPixels']
    development=[{k:r[k] for k in keys} for r in manifest['items'] if r['split']=='dev']
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for i,_ in enumerate(pool.map(predict_case,[(r,str(args.base),str(args.cache),str(out)) for r in development],chunksize=4)):
            if (i+1)%100==0:print(f'Boundary DEV prediction {i+1}/{len(development)}',flush=True)
    state['status']='development-calibration';save(out/'PROTOTYPE-STATE.json',state)
    with (out/'calibration.log').open('w') as log:
        subprocess.run([sys.executable,str(Path(__file__).with_name('hysteresis_completion.py')),
            '--out',str(out),'--results',str(out/'calibration'),'--minimum-recall','.9993',
            '--dense','--kernel','ellipse','--objective','microIoU'],stdout=log,stderr=subprocess.STDOUT,check=True)
    selected=read(out/'calibration/HYSTERESIS-DENSE-ELLIPSE-SEARCH.json')['selected']
    state.update(status='development-evaluated',selected=selected,seconds=time.monotonic()-start,
        heldoutTestOpened=False,nativeMasksProduced=False)
    save(out/'PROTOTYPE-STATE.json',state);print(json.dumps(state,indent=2),flush=True)


if __name__=='__main__':main()
