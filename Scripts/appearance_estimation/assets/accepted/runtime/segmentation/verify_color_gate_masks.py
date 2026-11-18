#!/usr/bin/env python3
"""Independent OpenCV/RGB reference versus actual Swift masks, no GT reads."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np

from boundary_color_gate import source_color_distances
from boundary_uniformity import edge_distances
from evaluate_gt import read, save, sha
from native_predict import classifier_identity, observation_contract, load_classifier_observation

cv2.setNumThreads(1)
_MODEL=None
_PRIMARY=None
_BOUNDARY=None


def initialize(model_path,primary,boundary_producer=None,boundary_cache=None):
    global _MODEL,_PRIMARY,_BOUNDARY
    document=read(model_path)
    _MODEL={k:document[k] for k in ['threshold','completion','boundaryEvidenceGate'] if k in document}
    identity,trees=classifier_identity(primary/'recall-full-rf-native-pixel-forest.json')
    _PRIMARY=(identity,trees,sha(primary/'native-pixel-rf-segmentation'))
    _BOUNDARY=None
    if boundary_producer is not None:
        boundary_producer=Path(boundary_producer)
        identity,trees=classifier_identity(boundary_producer/'boundary-forest.json')
        if classifier_identity(model_path)!=(identity,trees):
            raise ValueError('Boundary observations belong to a different classifier')
        _BOUNDARY=(identity,trees,sha(boundary_producer/'native-boundary-refiner'),Path(boundary_cache))


def verify(payload):
    row,primary,refiner,cache,native=payload;model=_MODEL
    primary,refiner,cache,native=map(Path,(primary,refiner,cache,native))
    identity,trees,producer=_PRIMARY
    contract=observation_contract(row,primary,identity,producer,True)
    key=hashlib.sha256(json.dumps(contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    observed=load_classifier_observation(cache/f'{key}.npz',contract,trees)
    if observed is None:raise ValueError('Source primary observation mismatch')
    p,base=observed
    if _BOUNDARY is None:
        with np.load(refiner/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:q=data['probability'].astype(np.float32)
    else:
        boundary_identity,boundary_trees,boundary_binary,boundary_cache=_BOUNDARY
        boundary_contract=observation_contract(row,primary,boundary_identity,boundary_binary,True)
        boundary_contract.update(primaryClassifierSHA256=identity,primaryExecutableSHA256=producer,
                                 schema='source-boundary-classifier-observation-v1')
        key=hashlib.sha256(json.dumps(boundary_contract,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        boundary=load_classifier_observation(boundary_cache/f'{key}.npz',boundary_contract,boundary_trees)
        if boundary is None or not np.array_equal(boundary[1],base):
            raise ValueError('Source boundary observation mismatch')
        q=boundary[0]
    c=model['completion'];radius=min(c['maximumRadiusPixels'],max(c['minimumRadiusPixels'],round(row['fontPixels']*c['radiusFontScale'])))
    kernel={'ellipse':cv2.MORPH_ELLIPSE,'square':cv2.MORPH_RECT,'cross':cv2.MORPH_CROSS}[c.get('kernel','square')]
    seed=q>=model['threshold']
    if c['unionNative']:seed|=base>0
    mask=cv2.dilate(seed.astype(np.uint8),cv2.getStructuringElement(kernel,(2*radius+1,2*radius+1)))>0
    if c.get('fringeThreshold'):mask&=q>=c['fringeThreshold']
    if c.get('weakThreshold') is not None:mask|=q>=c['weakThreshold']
    # Native's legacy implicit gate rejects expanded pixels with zero votes
    # from both forests, even when no explicit evidence policy was exported.
    gate=model.get('boundaryEvidenceGate',dict(primaryThreshold=np.nextafter(np.float32(0),np.float32(1)),
                                              boundaryThreshold=np.nextafter(np.float32(0),np.float32(1)),
                                              includeNativeSupport=False))
    rgb=np.fromfile(row['rgb'],np.uint8).reshape(row['height'],row['width'],3)
    alternate=gate.get('chromaticOverride')
    alternate_member=(rgb.max(2)-rgb.min(2)>=alternate['minimumChroma']) if alternate else np.zeros(p.shape,bool)
    support=np.zeros(p.shape,bool)
    for policy,member in [(gate,~alternate_member),*( [(alternate,alternate_member)] if alternate else [])]:
        supported=(p>=policy['primaryThreshold'])|(q>=policy['boundaryThreshold'])
        if policy['includeNativeSupport']:supported|=base>0
        support|=supported&member
        color=policy.get('colorCorroboration')
        if color:
            positions=np.flatnonzero((mask&member&~supported).ravel())
            seeds=(p>=color['primarySeedThreshold'])|(q>=color['boundarySeedThreshold'])
            distance=source_color_distances(rgb,seeds,positions,[color['radius']])[0]
            support.ravel()[positions[distance<=color['tolerance']]]=True
    expected=(mask&support).astype(np.uint8)*255
    recovery=gate.get('recoveryGate');recovery_base=expected.copy() if recovery else None
    uniform=gate.get('uniformityGate')
    if uniform:
        distance=edge_distances(rgb,uniform['contrastThreshold'])
        minimum=max(uniform['minimumDistancePixels'],min(65535,int(np.ceil(row['fontPixels']*uniform['distanceFontScale']))))
        remove=(expected>0)&(p<uniform['maximumPrimaryProbability'])&(q<uniform['maximumBoundaryProbability'])&(distance>=minimum)
        if uniform['preserveConsensusNeighbors']:
            radius=uniform['consensusRadius']
            consensus=(p>=uniform['primarySeedThreshold'])&(q>=uniform['boundarySeedThreshold'])
            nearby=cv2.dilate(consensus.astype(np.uint8),np.ones((2*radius+1,2*radius+1),np.uint8))>0
            remove&=~nearby
        expected[remove]=0
    if recovery:
        seeds=(recovery_base>0)&(p>=recovery['primarySeedThreshold'])&(q>=recovery['boundarySeedThreshold'])
        radius=recovery['radius'];nearby=cv2.dilate(seeds.astype(np.uint8),np.ones((2*radius+1,2*radius+1),np.uint8))>0
        candidate=(recovery_base==0)&nearby
        if recovery['requireNativeSupport']:candidate&=base>0
        if recovery['maximumEdgeDistancePixels']>=0:
            candidate&=edge_distances(rgb,recovery['edgeContrastThreshold'])<=recovery['maximumEdgeDistancePixels']
        positions=np.flatnonzero(candidate.ravel())
        difference=source_color_distances(rgb,seeds,positions,[radius])[0]
        expected.ravel()[positions[difference<=recovery['colorTolerance']]]=255
    actual=np.fromfile(native/'native-masks'/f'{row["id"]}.u8',np.uint8).reshape(p.shape)
    differences=int(np.count_nonzero(actual!=expected))
    if differences:raise ValueError(f'Native/reference mask mismatch: {row["id"]}: {differences} pixels')
    return actual.size


def main():
    parser=argparse.ArgumentParser()
    for name in ['primary','refiner','cache','native']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--boundary-producer',type=Path)
    parser.add_argument('--boundary-cache',type=Path)
    args=parser.parse_args();model=read(args.native/'boundary-forest.json')
    if (args.boundary_producer is None)!=(args.boundary_cache is None):
        parser.error('--boundary-producer and --boundary-cache must be supplied together')
    if model['sourceModelSHA256']!=sha(args.refiner/'full-rf-pixel-fusion-model.json'):
        raise ValueError('Research/native classifier mismatch')
    manifest=read(args.primary/'evaluation-manifest.json')
    # Whitelist source fields: evaluation labels/status never reach workers.
    fields=['id','rgb','rf','width','height','fontPixels','polygons']
    rows=[{k:r[k] for k in fields} for r in manifest['items']]
    with ProcessPoolExecutor(max_workers=args.jobs,initializer=initialize,initargs=(args.native/'boundary-forest.json',args.primary,args.boundary_producer,args.boundary_cache)) as pool:
        sizes=list(pool.map(verify,[(r,str(args.primary),str(args.refiner),str(args.cache),str(args.native)) for r in rows],chunksize=8))
    save(args.native/'MASK-PARITY.json',dict(masksVerified=len(rows),pixelsVerified=sum(sizes),
        allMasksByteIdentical=True,GTMaskRead=False,wholePagesRead=False,
        authenticatedBoundaryObservations=args.boundary_producer is not None,
        nativeModelSHA256=sha(args.native/'boundary-forest.json'),reference='Independent OpenCV completion and bounded RGB corroboration'))
    print(f'Independent source-only mask parity: {len(rows)} masks, {sum(sizes)} pixels, byte-identical',flush=True)


if __name__=='__main__':main()
