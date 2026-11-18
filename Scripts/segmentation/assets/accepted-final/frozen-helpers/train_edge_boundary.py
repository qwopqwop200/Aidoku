#!/usr/bin/env python3
"""TRAIN-only edge-context forest ablation reusing verified OOF sample rows."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import inspect
import json
from pathlib import Path
import tempfile
import time

import cv2
import numpy as np
from PIL import Image

from boundary_refiner import source_features,sample_case,validate_oof
from boundary_uniformity import edge_distances
from boundary_uniformity_dense import rgb_gradient
from evaluate_gt import read,save,sha
from pixel_rfdetr_fusion import fit_shard,merge_forests

cv2.setNumThreads(1)
EDGE_NAMES=['rgbEdgeDistance8RelativeFont','rgbEdgeDistance32RelativeFont','rgbEdgeDistance64RelativeFont',
            'rgbRange3','rgbRangeMeanFontHalf']


def edge_features(rgb,font):
    font=max(1,float(font));gradient=rgb_gradient(rgb).astype(np.float32)/np.float32(255)
    size=max(3,min(257,int(round(font*.5))|1))
    planes=[np.minimum(edge_distances(rgb,t).astype(np.float64)/font,1).astype(np.float32) for t in [8,32,64]]
    planes.extend([gradient,cv2.boxFilter(gradient,-1,(size,size),borderType=cv2.BORDER_REPLICATE)])
    return np.stack(planes,axis=2).reshape(-1,len(EDGE_NAMES))


def sample_extra(payload):
    row,ordinal,oof=payload[:3]
    if len(payload)>3:
        observed=read(Path(payload[3])/f'recall-full-rf-native-train/receipts/{row["id"]}.json')['contract']['observation']
        if sha(row['rgb'])!=observed['rgbSHA256']:raise ValueError('Source RGB differs from frozen native producer')
    with np.load(Path(oof)/'probabilities'/f'{row["id"]}.npz') as data:p=data['probability'].astype(np.float32)
    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
    features=edge_features(rgb,row['fontPixels'])
    if sha(row['target'])!=row['targetSHA256']:raise ValueError('GT changed')
    target=np.asarray(Image.open(row['target']))>0;rng=np.random.default_rng(20261110+ordinal);positions=[]
    near=cv2.dilate(p,np.ones((9,9),np.uint8))>.1
    for mask,count in [(target,128),(~target,128),(target&(p<.75),256),(~target&near,256)]:
        indices=np.flatnonzero(mask.ravel())
        if len(indices):positions.extend(rng.choice(indices,min(count,len(indices)),replace=False))
    positions=np.unique(positions).astype(np.int64)
    return (features[positions],target.ravel()[positions].astype(np.int32),p.ravel()[positions],
            rgb.reshape(-1,3)[positions].astype(np.float32)/np.float32(255))


def main():
    parser=argparse.ArgumentParser()
    for name in ['base','samples','oof','out']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--trees',type=int,default=48)
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True);start=time.monotonic()
    if not 1<=args.jobs<=8 or not 1<=args.trees<=255:parser.error('Require jobs1...8 and trees1...255')
    manifest=read(args.base/'evaluation-manifest.json');samples=read(args.samples/'SAMPLES.json');oof=read(args.oof/'OOF-COMPLETE.json')
    contract=samples['contract'];expected=hashlib.sha256((inspect.getsource(source_features)+inspect.getsource(sample_case)).encode()).hexdigest()
    if (not samples['trainOnly'] or not contract['rich'] or contract['manifestSHA256']!=sha(args.base/'evaluation-manifest.json') or
            contract['featureSourceSHA256']!=expected or contract['OOFReceiptSHA256']!=sha(args.oof/'OOF-COMPLETE.json') or
            contract['primaryModelSHA256']!=sha(args.base/'recall-full-rf-native-pixel-forest.json') or
            contract['primaryExecutableSHA256']!=sha(args.base/'native-pixel-rf-segmentation') or
            contract['RFAdapterSHA256']!=sha(Path(__file__).with_name('prepare_full_rf.py'))):raise ValueError('Stale original sample contract')
    validate_oof(manifest,oof,read(args.oof/'OOF-PROTOCOL.json'))
    if oof['DEVAndTestUsed'] or oof['sourceGroupLeakage'] or oof['manifestSHA256']!=contract['manifestSHA256']:raise ValueError('Teacher source leakage/mismatch')
    for m in oof['models']:
        if sha(args.oof/f'fold-{m["fold"]}.json')!=m['SHA256']:raise ValueError('Teacher model changed')
    for name in ['features','labels']:
        if sha(args.samples/f'{name}.npy')!=samples[name+'SHA256']:raise ValueError('Original samples corrupted')
    x=np.load(args.samples/'features.npy',mmap_mode='r');y=np.load(args.samples/'labels.npy',mmap_mode='r')
    if x.shape!=(len(y),55):raise ValueError('Require original55-feature samples')
    rows=[r for r in manifest['items'] if r['split']=='train'];matrix=out/'training-features.npy'
    state=dict(status='extracting-five-source-edge-features',GTChanged=False,trainOnly=True,nativeExportSupported=False)
    save(out/'PROTOTYPE-STATE.json',state)
    augmented=np.lib.format.open_memmap(matrix,mode='w+',dtype=np.float32,shape=(len(y),60));offset=0
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads=[(r,i,str(args.oof.resolve()),str(args.base.resolve())) for i,r in enumerate(rows)]
        for i,(extra,labels,primary,rgb) in enumerate(pool.map(sample_extra,payloads,chunksize=4)):
            end=offset+len(labels)
            if (not np.array_equal(y[offset:end],labels) or not np.array_equal(x[offset:end,0],primary) or
                    not np.array_equal(x[offset:end,2:5],rgb)):
                raise ValueError('Reconstructed OOF sample rows differ from frozen original')
            augmented[offset:end,:55]=x[offset:end];augmented[offset:end,55:]=extra;offset=end
            if (i+1)%250==0:print(f'Edge TRAIN rows {i+1}/{len(rows)}',flush=True)
    if offset!=len(y):raise ValueError('Sample count changed')
    augmented.flush();del augmented
    state['status']='fitting60-feature-boundary-forest';save(out/'PROTOTYPE-STATE.json',state)
    with tempfile.TemporaryDirectory(prefix='edge-fit-',dir=out) as scratch:
        root=Path(scratch);(root/'features.npy').symlink_to(matrix);(root/'labels.npy').symlink_to((args.samples/'labels.npy').resolve())
        jobs=min(args.jobs,args.trees)
        with ProcessPoolExecutor(max_workers=jobs) as pool:
            paths=list(pool.map(fit_shard,[(str(root),i,len(range(i,args.trees,jobs)),14,64) for i in range(jobs)]))
        merge_forests(paths,out/'full-rf-pixel-fusion-model.json')
    save(out/'full-rf-PIXEL-MODEL-TRAINING.json',dict(trees=args.trees,featureCount=60,featureNames=samples['featureNames']+EDGE_NAMES,
        sampledPixels=len(y),sourceGroupedTrainingInstances=len(rows),maximumDepth=14,minimumSamplesToSplit=64,
        primaryModelSHA256=contract['primaryModelSHA256'],manifestSHA256=contract['manifestSHA256'],
        OOFReceiptSHA256=contract['OOFReceiptSHA256'],teacherTrainingProbabilities='excluded-source OOF',
        runtimeReadsGT=False,caseIdentityFeatures=False,richEvidence=True,nativeExportSupported=False,
        featureVariant='contextual-boundary-rgb-edges-research-v1',featuresSHA256=sha(matrix),
        featureCodeSHA256=hashlib.sha256((inspect.getsource(edge_features)+inspect.getsource(edge_distances)+inspect.getsource(rgb_gradient)).encode()).hexdigest()))
    state.update(status='trained-requires-native60-feature-contract',seconds=time.monotonic()-start,heldoutTestOpened=False,
        nativeExportSupported=False,trainingSamplesReusedExactly=True)
    save(out/'PROTOTYPE-STATE.json',state);print(json.dumps(state,indent=2),flush=True)


if __name__=='__main__':main()
