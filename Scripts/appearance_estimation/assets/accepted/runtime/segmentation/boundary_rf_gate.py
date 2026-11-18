#!/usr/bin/env python3
"""Calibrate global dual-classifier fringe gates with source RF corroboration.

Only completion pixels are eligible. GT is opened after prediction membership
is computed and supplies evaluation counts, never an inference feature.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image

from evaluate_gt import read, save, sha
from native_predict import load_classifier_observation
from rf_weak_rescue import owner_text_sfx_support


LIMIT = 8
RF_BINS = np.array([0, .01, .025, .05, .1, .15, .2, .3, .4, .5,
                    .6, .7, .8, .9, 1.01], np.float32)


def measure(payload):
    row, primary, refiner, cache, rf_base = payload
    primary, refiner, cache = map(Path, (primary, refiner, cache))
    receipt = read(primary / f'recall-full-rf-native-{row["split"]}/receipts/{row["id"]}.json')
    contract = receipt['contract']['observation']
    key = hashlib.sha256(json.dumps(contract, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    observed = load_classifier_observation(cache / f'{key}.npz', contract, 64)
    if observed is None:
        raise ValueError('Unverified primary observation')
    p, _ = observed
    with np.load(refiner / 'full-rf-dev-probabilities' / f'{row["id"]}.npz') as data:
        q = data['probability'].astype(np.float32)
    mask = np.fromfile(refiner / 'python-research-all' / f'{row["id"]}.u8', np.uint8).reshape(p.shape) > 0
    pv = np.minimum(LIMIT, np.rint(p * 64).astype(np.uint8))
    qv = np.minimum(LIMIT, np.rint(q * 48).astype(np.uint8))
    positions = np.flatnonzero((mask & (pv < LIMIT) & (qv < LIMIT)).ravel())
    support = owner_text_sfx_support(row, rf_base, positions) if len(positions) else np.empty(0, np.float32)
    rf_bucket = np.searchsorted(RF_BINS, support, side='right') - 1
    codes = ((pv.ravel()[positions].astype(np.int64) * LIMIT + qv.ravel()[positions]) * len(RF_BINS) + rf_bucket)
    # Prediction membership, including original-resolution RF sampling, is now fixed.
    if sha(row['target']) != row['targetSHA256']:
        raise ValueError('GT changed')
    target = np.asarray(Image.open(row['target'])) > 0
    positive = target.ravel()[positions]
    shape = (LIMIT, LIMIT, len(RF_BINS))
    hist = np.stack([np.bincount(codes[positive], minlength=np.prod(shape)).reshape(shape),
                     np.bincount(codes[~positive], minlength=np.prod(shape)).reshape(shape)])
    counts = np.array([np.count_nonzero(mask & target), np.count_nonzero(mask & ~target),
                       np.count_nonzero(~mask & target)], np.int64)
    return row['split'], counts, hist


def metrics(counts):
    tp, fp, fn = map(int, counts)
    return dict(TP=tp, FP=fp, FN=fn, recall=tp/(tp+fn), microIoU=tp/(tp+fp+fn))


def main():
    parser = argparse.ArgumentParser()
    for name in ['primary', 'refiner', 'cache', 'rf-base', 'out']:
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    manifest = read(args.primary / 'evaluation-manifest.json')
    counts = {s: np.zeros(3, np.int64) for s in ['train', 'dev', 'test']}
    histograms = {s: np.zeros((2, LIMIT, LIMIT, len(RF_BINS)), np.int64) for s in counts}
    start = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads = [(r, str(args.primary), str(args.refiner), str(args.cache), str(args.rf_base)) for r in manifest['items']]
        for i, (split, count, hist) in enumerate(pool.map(measure, payloads, chunksize=8)):
            counts[split] += count
            histograms[split] += hist
            if (i+1) % 400 == 0:
                print(f'RF boundary gate {i+1}/{len(payloads)}', flush=True)
    trials = []
    for p in range(1, LIMIT+1):
        for q in range(1, LIMIT+1):
            for k, threshold in enumerate(RF_BINS):
                split_counts = {}
                for split, hist in histograms.items():
                    removed_tp, removed_fp = hist[:, :p, :q, :k].sum(axis=(1, 2, 3))
                    split_counts[split] = counts[split] + [-removed_tp, -removed_fp, removed_tp]
                trials.append(dict(primaryVotes=p, boundaryVotes=q, RFThreshold=float(threshold),
                    **metrics(sum(split_counts.values())), bySplit={s: metrics(c) for s, c in split_counts.items()}))
    eligible = [t for t in trials if t['recall'] >= .999]
    best = max(eligible, key=lambda t: t['microIoU']) if eligible else None
    dev = [t for t in trials if t['bySplit']['dev']['recall'] >= .999]
    selected_dev = max(dev, key=lambda t: t['bySplit']['dev']['microIoU']) if dev else None
    save(args.out / 'SEARCH.json', dict(selectedObservedCorpus=best, selectedDev=selected_dev, trials=trials,
        seconds=time.monotonic()-start, instances=len(manifest['items']), GTChanged=False,
        GTAtInference=False, perCaseRules=False, nativeValidated=False, freshFinalHoldout=False))
    np.savez_compressed(args.out / 'COUNTS.npz', **{s: h for s, h in histograms.items()},
                        **{s+'_base': c for s, c in counts.items()})
    print(json.dumps(dict(best=best, selectedDev=selected_dev, seconds=time.monotonic()-start), indent=2), flush=True)


if __name__ == '__main__':
    main()
