"""Source-only point recovery inside bounded dilation; DEV-selected parameters."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

import evaluate_point_recovery as point
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha

BINS = 16384
MAX_DISTANCE = 17  # Last bucket contains every distance >16.
CONTEXTUAL = False


def initialize(root, model, contextual):
    global CONTEXTUAL
    CONTEXTUAL = contextual
    point.initialize(root, model)


def measure(row):
    if CONTEXTUAL:
        from train_context_recovery import features_and_base
    else:
        features_and_base = point.recovery.features_and_base
    features, base, _ = features_and_base(row)
    if features.shape[1] != point.MODEL.n_features_in_:
        raise ValueError('Model/source feature count mismatch')
    distance = cv2.distanceTransform((~base).astype(np.uint8), cv2.DIST_C, 3)
    positions = np.flatnonzero((~base).ravel())
    codes = np.empty(len(positions), np.int32)
    for start in range(0, len(positions), 65536):
        stop = start + 65536
        scores = point.MODEL.predict_proba(features[positions[start:stop]])[:, 1]
        codes[start:stop] = np.minimum((scores * BINS).astype(np.int32), BINS - 1)
    distances = np.minimum(distance.ravel()[positions], MAX_DISTANCE).astype(np.int32)
    codes += distances * BINS
    if sha(row['target']) != row['targetSHA256']:
        raise ValueError('GT changed')
    gt = np.asarray(Image.open(row['target'])) > 0
    positive = gt.ravel()[positions]
    shape = (MAX_DISTANCE + 1, BINS)
    hist = np.stack([np.bincount(codes[positive], minlength=np.prod(shape)).reshape(shape),
                     np.bincount(codes[~positive], minlength=np.prod(shape)).reshape(shape)])
    counts = np.array([np.count_nonzero(base & gt), np.count_nonzero(base & ~gt),
                       np.count_nonzero(~base & gt)], np.int64)
    indices = np.flatnonzero(hist)
    return row['split'], counts, indices, hist.ravel()[indices]


def candidates(hist, base):
    accumulated = {s: h.cumsum(axis=1) for s, h in hist.items()}
    for core in [0, 1, 2, 3]:
        for outer in [2, 3, 4, 5, 7, 10, 12, 16, 17]:
            if outer < core:
                continue
            totals = {}
            for split, h in accumulated.items():
                unconditional = h[:, core].sum(axis=1)
                conditional = (h[:, outer] - h[:, core])[:, ::-1].cumsum(axis=1)[:, ::-1]
                add = unconditional[:, None] + conditional
                totals[split] = base[split][:, None] + np.stack([add[0], add[1], -add[0]])
            yield core, outer, totals


def summarize(hist, base):
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70']}
    ranks = {k: (-1, -1) for k in best}
    for core, outer, totals in candidates(hist, base):
        all_counts = sum(totals.values())
        for key, c in [('devRecall99999', totals['dev']),
                       ('allRecall99999', all_counts), ('allIoU70', all_counts)]:
            recall = c[0] / (c[0] + c[2])
            iou = c[0] / c.sum(axis=0)
            valid = np.flatnonzero(iou >= .7 if key == 'allIoU70' else recall >= .99999)
            if not len(valid):
                continue
            score = recall if key == 'allIoU70' else iou
            index = int(valid[np.argmax(score[valid])])
            rank = (float(score[index]), float(iou[index]))
            if rank <= ranks[key]:
                continue
            ranks[key] = rank
            best[key] = dict(coreRadiusPixels=core, outerRadiusPixels=outer if outer < 17 else None,
                             threshold=index / BINS, all=metrics(all_counts[:, index]),
                             bySplit={s: metrics(v[:, index]) for s, v in totals.items()})
    return best


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'out', 'model']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--contextual', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    hist = {s: np.zeros((2, MAX_DISTANCE + 1, BINS), np.int64) for s in ['train', 'dev', 'test']}
    base = {s: np.zeros(3, np.int64) for s in hist}
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize,
                             initargs=(args.root.resolve(), args.model.resolve(), args.contextual)) as pool:
        for i, (split, counts, indices, values) in enumerate(pool.map(measure, rows, chunksize=4)):
            hist[split].ravel()[indices] += values
            base[split] += counts
            if (i + 1) % 500 == 0:
                print(f'Adaptive dilation {i + 1}/{len(rows)}', flush=True)
    result = summarize(hist, base)
    result.update(GTAtInference=False, GTChanged=False, additionalDilationAllowed=True,
                  sourceOnly=True, boundingBoxMaskClipping=False, productionEnabled=False,
                  testPreviouslyInspected=True, maskCount=len(rows), modelSHA256=sha(args.model),
                  contextual=args.contextual,
                  seconds=time.monotonic() - started)
    save(args.out / 'RESULT.json', result)
    np.savez_compressed(args.out / 'COUNTS.npz', **hist,
                        **{s + '_base': v for s, v in base.items()})
    print(result, flush=True)


if __name__ == '__main__':
    main()
