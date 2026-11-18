#!/usr/bin/env python3
"""Measure RF-corroborated primary strokes missed by the boundary completer."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import hashlib
import json
from pathlib import Path
import time

import numpy as np
from PIL import Image

from boundary_rf_gate import RF_BINS, metrics
from evaluate_gt import read, save, sha
from native_predict import load_classifier_observation
from rf_weak_rescue import owner_text_sfx_support


def measure(payload):
    row, primary, refiner, cache, native, rf_base, support_kind = payload
    primary, refiner, cache, native = map(Path, (primary, refiner, cache, native))
    receipt = read(primary / f'recall-full-rf-native-{row["split"]}/receipts/{row["id"]}.json')
    contract = receipt['contract']['observation']
    key = hashlib.sha256(json.dumps(contract, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    observed = load_classifier_observation(cache / f'{key}.npz', contract, 64)
    if observed is None:
        raise ValueError('Unverified primary observation')
    p, source_mask = observed
    with np.load(refiner / 'full-rf-dev-probabilities' / f'{row["id"]}.npz') as data:
        q = data['probability'].astype(np.float32)
    mask = np.fromfile(native / 'native-masks' / f'{row["id"]}.u8', np.uint8).reshape(p.shape) > 0
    pv = np.rint(p * 64).astype(np.uint8)
    qv = np.rint(q * 48).astype(np.uint8)
    positions = np.flatnonzero((~mask & (pv >= 1)).ravel())
    if support_kind == 'native':
        support = (source_mask.ravel()[positions] > 0).astype(np.float32)
    else:
        support = owner_text_sfx_support(row, rf_base, positions) if len(positions) else np.empty(0, np.float32)
    rf_bucket = np.searchsorted(RF_BINS, support, side='right') - 1
    codes = ((pv.ravel()[positions].astype(np.int64) * 49 + qv.ravel()[positions]) * len(RF_BINS) + rf_bucket)
    if sha(row['target']) != row['targetSHA256']:
        raise ValueError('GT changed')
    target = np.asarray(Image.open(row['target'])) > 0
    positive = target.ravel()[positions]
    shape = (65, 49, len(RF_BINS))
    hist = np.stack([np.bincount(codes[positive], minlength=np.prod(shape)).reshape(shape),
                     np.bincount(codes[~positive], minlength=np.prod(shape)).reshape(shape)])
    counts = np.array([np.count_nonzero(mask & target), np.count_nonzero(mask & ~target),
                       np.count_nonzero(~mask & target)], np.int64)
    return row['split'], counts, hist


def main():
    parser = argparse.ArgumentParser()
    for name in ['primary', 'refiner', 'cache', 'native', 'rf-base', 'out']:
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--support', choices=['rf', 'native'], default='rf')
    args = parser.parse_args()
    manifest = read(args.primary / 'evaluation-manifest.json')
    counts = {s: np.zeros(3, np.int64) for s in ['train', 'dev', 'test']}
    histograms = {s: np.zeros((2, 65, 49, len(RF_BINS)), np.int64) for s in counts}
    start = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        payloads = [(r, str(args.primary), str(args.refiner), str(args.cache), str(args.native),
                     str(args.rf_base), args.support) for r in manifest['items']]
        for i, (split, count, hist) in enumerate(pool.map(measure, payloads, chunksize=8)):
            counts[split] += count
            histograms[split] += hist
            if (i+1) % 400 == 0:
                print(f'RF boundary rescue {i+1}/{len(payloads)}', flush=True)
    for split, expected in read(args.native/'RESULT.json')['bySplit'].items():
        if tuple(counts[split]) != tuple(expected[k] for k in ['TP', 'FP', 'FN']):
            raise ValueError('Base masks do not reproduce current native result')
    cumulative = {s: h[:, ::-1, ::-1, ::-1].cumsum(1).cumsum(2).cumsum(3)[:, ::-1, ::-1, ::-1]
                  for s, h in histograms.items()}
    trials = []
    for p in range(1, 65):
        for q in [0, 1, 2, 3, 4, 6, 8, 12, 16, 24]:
            for k, threshold in enumerate(RF_BINS[:-1]):
                split_counts = {}
                for split, h in cumulative.items():
                    tp, fp = h[:, p, q, k]
                    split_counts[split] = counts[split] + [tp, fp, -tp]
                trials.append(dict(primaryVotes=p, boundaryVotes=q, RFThreshold=float(threshold),
                    **metrics(sum(split_counts.values())), bySplit={s: metrics(c) for s, c in split_counts.items()}))
    eligible = [t for t in trials if t['recall'] >= .999]
    best = max(eligible, key=lambda t: t['microIoU'])
    dev = [t for t in trials if t['bySplit']['dev']['recall'] >= .999]
    selected_dev = max(dev, key=lambda t: t['bySplit']['dev']['microIoU']) if dev else None
    every_split = [t for t in trials if all(s['recall'] >= .999 for s in t['bySplit'].values())]
    selected_all = max(every_split, key=lambda t: t['microIoU']) if every_split else None
    save(args.out / 'SEARCH.json', dict(bestObservedCorpus=best, selectedDev=selected_dev,
        selectedAllSplits=selected_all, trials=trials, seconds=time.monotonic()-start,
        instances=len(manifest['items']), GTChanged=False, GTAtInference=False, perCaseRules=False,
        nativeValidated=False, freshFinalHoldout=False, supportKind=args.support))
    np.savez_compressed(args.out/'COUNTS.npz', **histograms, **{s+'_base': c for s, c in counts.items()})
    print(json.dumps(dict(best=best, selectedDev=selected_dev, selectedAllSplits=selected_all,
                          seconds=time.monotonic()-start), indent=2), flush=True)


if __name__ == '__main__':
    main()
