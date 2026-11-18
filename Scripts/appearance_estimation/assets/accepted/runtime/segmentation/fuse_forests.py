#!/usr/bin/env python3
"""Combine source-group-trained forests and exact DEV votes, without refitting."""
import argparse
from pathlib import Path
import time

import numpy as np

from evaluate_gt import read,save,sha
from pixel_rfdetr_fusion import merge_forests


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--components',nargs='+',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args();roots=[p.resolve() for p in args.components];out=args.out.resolve()
    out.mkdir(parents=True,exist_ok=True)
    manifest_hash=sha(roots[0]/'evaluation-manifest.json')
    metadata=[]
    for root in roots:
        if sha(root/'evaluation-manifest.json')!=manifest_hash:raise ValueError('Source/GT/split/RF mismatch')
        receipt=read(root/'full-rf-DEV-PREDICTION-RUN.json')
        if receipt.get('modelSHA256')!=sha(root/'full-rf-pixel-fusion-model.json') or receipt.get('manifestSHA256')!=manifest_hash:
            raise ValueError('Unverified source-only DEV votes')
        metadata.append(read(root/'full-rf-PIXEL-MODEL-TRAINING.json'))
    for name in ['evaluation-manifest.json','rf-full','baseline']:
        destination=out/name
        if not destination.exists():destination.symlink_to(roots[0]/name)
    start=time.monotonic();source=out/'full-rf-pixel-fusion-model.json'
    model=merge_forests([r/'full-rf-pixel-fusion-model.json' for r in roots],source,allow_mixed_training=True)
    trees=sum(m['trees'] for m in metadata)
    manifest=read(out/'evaluation-manifest.json');rows=[r for r in manifest['items'] if r['split']=='dev']
    destination=out/'full-rf-dev-probabilities';destination.mkdir(exist_ok=True)
    for row in rows:
        votes=np.zeros((row['height'],row['width']),np.int32)
        for root,record in zip(roots,metadata):
            with np.load(root/'full-rf-dev-probabilities'/f'{row["id"]}.npz') as data:
                p=data['probability'].astype(np.float32)
            if p.shape!=votes.shape or not np.isfinite(p).all() or p.min()<0 or p.max()>1:
                raise ValueError('Invalid component probability cache')
            votes+=np.rint(p*record['trees']).astype(np.int32)
        with (destination/f'{row["id"]}.npz').open('wb') as stream:
            np.savez_compressed(stream,probability=(votes/trees).astype(np.float16))
    save(out/'full-rf-PIXEL-MODEL-TRAINING.json',dict(metadata[0],trees=trees,
        classifier='Exact vote concatenation of independently train-source-fitted forests',
        components=[dict(path=str(r),modelSHA256=sha(r/'full-rf-pixel-fusion-model.json'),trees=m['trees']) for r,m in zip(roots,metadata)],
        sampledPixels=None,sampledPixelDraws=sum(m.get('sampledPixels',0) for m in metadata),
        OOBDiagnostic='weighted component mean, not merged-forest OOB',refit=False,
        maximumDepth=max(m['maximumDepth'] for m in metadata),seconds=time.monotonic()-start))
    save(out/'full-rf-DEV-PREDICTION-RUN.json',dict(instances=len(rows),modelSHA256=sha(source),
        manifestSHA256=manifest_hash,GTReadByPredictor=False,holdoutTestOpened=False,
        exactIntegerVoteFusion=True,trees=trees,seconds=time.monotonic()-start))
    print(f'Fused {trees} trees and {len(rows)} source-only DEV probability maps',flush=True)


if __name__=='__main__':main()
