#!/usr/bin/env python3
"""Recall-first global completion search; no bbox fills or per-case rules."""
import argparse
from collections import defaultdict
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from evaluate_gt import DEFAULT_OUT, read, save

cv2.setNumThreads(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--minimum-recall', type=float, default=.999)
    parser.add_argument('--refine', action='store_true', help='Global vote/radius refinement; no per-crop rules')
    args = parser.parse_args(); out = args.out.resolve()
    rows = [r for r in read(out / 'evaluation-manifest.json')['items'] if r['split'] == 'dev']
    trees = read(out / 'full-rf-PIXEL-MODEL-TRAINING.json')['trees']
    # Every seed requires at least one positive tree vote. Never select the
    # zero-threshold all-background crop as a way to claim perfect recall.
    trials = [dict(minimumVotes=v, threshold=(v - .5) / trees, unionNative=u, radiusFontScale=s,
                   minimumRadiusPixels=1 if s else 0, maximumRadiusPixels=8)
              for v in [1, 2, 3, 4, 6, 8, 10, 12, 16, 19]
              for u in [False, True] for s in [0, .01, .02, .04, .08]]
    if args.refine:
        trials = [dict(minimumVotes=v, threshold=(v-.5)/trees, unionNative=False,
                       radiusFontScale=s, minimumRadiusPixels=1, maximumRadiusPixels=cap)
                  for v in [8,10,12,14,16]
                  for s in [.025,.03,.035,.04,.045,.05,.06]
                  for cap in [3,5,8]]
    counts = np.zeros((len(trials), 3), np.int64)
    macro = np.zeros((len(trials), 2), np.float64)
    low = np.zeros(len(trials), np.int64)
    start = time.monotonic()
    for ordinal, row in enumerate(rows):
        gt = np.asarray(Image.open(row['target'])) > 0
        with np.load(out / 'full-rf-dev-probabilities' / f'{row["id"]}.npz') as data:
            probability = data['probability'].astype(np.float32)
        base = np.fromfile(out / 'baseline' / f'{row["id"]}.u8', np.uint8).reshape(gt.shape) > 0
        for i, trial in enumerate(trials):
            prediction = probability >= trial['threshold']
            if trial['unionNative']:
                prediction |= base
            radius = min(trial['maximumRadiusPixels'], max(trial['minimumRadiusPixels'], round(row['fontPixels'] * trial['radiusFontScale'])))
            if radius:
                prediction = cv2.dilate(prediction.astype(np.uint8), np.ones((2 * radius + 1, 2 * radius + 1), np.uint8)) > 0
            tp = np.count_nonzero(prediction & gt); fp = np.count_nonzero(prediction & ~gt)
            fn = np.count_nonzero(~prediction & gt)
            counts[i] += [tp, fp, fn]
            recall = tp / max(1, tp + fn)
            macro[i] += [tp / max(1, tp + fp + fn), recall]
            low[i] += recall < .99
        if (ordinal + 1) % 100 == 0:
            print(f'Recall completion calibration {ordinal + 1}/{len(rows)}', flush=True)
    for i, trial in enumerate(trials):
        tp, fp, fn = map(int, counts[i])
        trial.update(TP=tp, FP=fp, FN=fn, recall=tp / max(1, tp + fn), precision=tp / max(1, tp + fp),
                     microIoU=tp / max(1, tp + fp + fn), macroIoU=macro[i, 0] / len(rows),
                     macroRecall=macro[i, 1] / len(rows), instancesBelow99Recall=int(low[i]))
    eligible = [r for r in trials if r['recall'] >= args.minimum_recall]
    chosen = max(eligible, key=lambda r:(r['macroIoU'], r['macroRecall'])) if eligible else None
    report = dict(selectionRule='maximize development macroIoU subject to high foreground recall; positive seeds only',
                  targetRecall=args.minimum_recall, selected=chosen, trials=trials, instances=len(rows),
                  seconds=time.monotonic() - start, holdoutTestUsed=False, pageSpecificRules=False,
                  backgroundTrueNegativesNotCountedAsAccuracy=True, bboxFillAllowed=False)
    save(out / ('RECALL-COMPLETION-REFINEMENT.json' if args.refine else 'RECALL-COMPLETION-SEARCH.json'), report)
    print(__import__('json').dumps({k:v for k,v in report.items() if k != 'trials'}, indent=2))


if __name__ == '__main__':
    main()
