#!/usr/bin/env python3
"""Capture source-only classifier observations and verify existing masks exactly."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

from evaluate_gt import read,save,sha


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--cache',type=Path,required=True)
    parser.add_argument('--jobs',type=int,default=4)
    args=parser.parse_args();out=args.out.resolve();manifest=read(out/'evaluation-manifest.json')
    reference=out/'PRE-CACHE-MASK-HASHES.json'
    model=out/'recall-full-rf-native-pixel-forest.json'
    if not reference.exists():
        masks={r['id']:sha(out/f'recall-full-rf-native-{r["split"]}'/f'{r["id"]}.u8') for r in manifest['items']}
        save(reference,dict(modelSHA256=sha(model),manifestSHA256=sha(out/'evaluation-manifest.json'),masks=masks))
    original=read(reference)
    if original['modelSHA256']!=sha(model) or original['manifestSHA256']!=sha(out/'evaluation-manifest.json'):
        raise ValueError('Original reference source/policy changed')
    start=time.monotonic();runs=[]
    for split in ['dev','test','train']:
        print(f'Capturing classifier observations: {split}',flush=True)
        with (out/f'capture-classifier-{split}.log').open('a') as log:
            subprocess.run([sys.executable,str(Path(__file__).with_name('native_predict.py')),
                '--out',str(out),'--recall-first','--split',split,'--jobs',str(args.jobs),
                '--classifier-cache',str(args.cache.resolve())],stdout=log,stderr=subprocess.STDOUT,check=True)
        rows=[r for r in manifest['items'] if r['split']==split]
        mismatches=[r['id'] for r in rows if original['masks'][r['id']]!=sha(out/f'recall-full-rf-native-{split}'/f'{r["id"]}.u8')]
        if mismatches:
            save(out/'CLASSIFIER-CACHE-PARITY.json',dict(passed=False,split=split,mismatches=mismatches))
            raise RuntimeError('Refactored live output differs from original masks')
        run=read(out/f'recall-full-rf-NATIVE-{split.upper()}-RUN.json')
        runs.append(dict(split=split,instances=len(rows),seconds=run['seconds'],
            captured=run['classifierObservationsCaptured'],reused=run['classifierObservationsReused']))
        save(out/'CLASSIFIER-CACHE-PARITY.json',dict(passed=True,complete=split=='train',
            masksVerified=sum(r['instances'] for r in runs),runs=runs,seconds=time.monotonic()-start,
            GTMaskRead=False,allMasksByteIdentical=True))
    print(f'All {len(original["masks"])} existing native masks reproduced byte-for-byte',flush=True)


if __name__=='__main__':main()
