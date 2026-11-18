"""Evaluate point recovery thresholds without feeding targets to inference."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time

import joblib
import numpy as np
from PIL import Image

import train_point_recovery as recovery
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha

MODEL = None
BINS = 65536


def initialize(root, model):
    global MODEL
    recovery.initialize(root)
    MODEL = joblib.load(model)


def measure(row):
    features, base, names = recovery.features_and_base(row)
    positions = np.flatnonzero((~base).ravel())
    codes = np.empty(len(positions), np.int32)
    for start in range(0, len(positions), 65536):
        stop = start + 65536
        scores = MODEL.predict_proba(features[positions[start:stop]])[:, 1]
        codes[start:stop] = np.minimum((scores * BINS).astype(np.int32), BINS - 1)
    # Targets enter only after all source-only predictions are complete.
    if sha(row['target']) != row['targetSHA256']:
        raise ValueError('GT changed')
    gt = np.asarray(Image.open(row['target'])) > 0
    positive = gt.ravel()[positions]
    hist = np.stack([np.bincount(codes[positive], minlength=BINS),
                     np.bincount(codes[~positive], minlength=BINS)])
    counts = np.array([np.count_nonzero(base & gt), np.count_nonzero(base & ~gt),
                       np.count_nonzero(~base & gt)], np.int64)
    return row['split'], counts, hist


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    hist = {s: np.zeros((2, BINS), np.int64) for s in ['train', 'dev', 'test']}
    base = {s: np.zeros(3, np.int64) for s in hist}
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize,
                             initargs=(args.root.resolve(), args.model.resolve())) as pool:
        for i, (split, counts, bins) in enumerate(pool.map(measure, rows, chunksize=4)):
            hist[split] += bins
            base[split] += counts
            if (i + 1) % 250 == 0:
                print(f'Point recovery evaluation {i + 1}/{len(rows)}', flush=True)
    totals = {}
    for split in hist:
        additions = hist[split][:, ::-1].cumsum(axis=1)[:, ::-1]
        totals[split] = base[split][:, None] + np.stack([
            additions[0], additions[1], -additions[0]])
    all_counts = sum(totals.values())
    recalls = all_counts[0] / (all_counts[0] + all_counts[2])
    ious = all_counts[0] / all_counts.sum(axis=0)

    def entry(index):
        if index is None:
            return None
        return dict(threshold=int(index) / BINS, all=metrics(all_counts[:, index]),
                    bySplit={s: metrics(c[:, index]) for s, c in totals.items()})

    eligible = np.flatnonzero(recalls >= .99999)
    target = int(eligible[np.argmax(ious[eligible])]) if len(eligible) else None
    eligible = np.flatnonzero(ious >= .7)
    pareto = int(eligible[np.argmax(recalls[eligible])]) if len(eligible) else None
    save(args.out / 'RESULT.json', dict(bestIoUAtRecall99999=entry(target),
        bestRecallAtIoU70=entry(pareto), baseline=metrics(sum(base.values())),
        GTAtInference=False, GTChanged=False, extraDilationKernel=False,
        trainingSplitOnly=True, thresholdCalibrationScope='observed-all-not-fresh-test',
        modelSHA256=sha(args.model), seconds=time.monotonic() - started))
    np.savez_compressed(args.out / 'COUNTS.npz', **hist,
                        **{s + '_base': c for s, c in base.items()})
    print(read(args.out / 'RESULT.json'), flush=True)


if __name__ == '__main__':
    main()
