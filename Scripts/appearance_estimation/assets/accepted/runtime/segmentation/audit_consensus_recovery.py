"""Conservative consensus plus nearby weak-consensus recovery; source masks only."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time
import cv2
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_style_calibration import style_features
from apply_joint_mask_refinement import refine_source_mask
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point

STRONG = None
WEAK = None
PLANS = [('chebyshev', r) for r in [1, 2, 3, 5]] + [('manhattan', r) for r in [1, 2, 3, 5]]
PLANS += [('euclidean', r) for r in [1, 1.5, 2, 2.5, 3, 4, 5]]


def initialize(root, model, cache, strong, weak):
    global STRONG, WEAK
    STRONG, WEAK = strong, weak
    joint.initialize(root, model, cache)


def partition(payload):
    rows, ordinal = payload
    counts = {s: np.zeros((len(PLANS), 3), np.int64) for s in ['train', 'dev', 'test']}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        values = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
        strong = refine_source_mask(base, distance, group, codes, STRONG, values, row['fontPixels']) > 0
        weak = refine_source_mask(base, distance, group, codes, WEAK, values, row['fontPixels']) > 0
        fields = {}
        for name, kind, size in [('chebyshev', cv2.DIST_C, 3), ('manhattan', cv2.DIST_L1, 3),
                                 ('euclidean', cv2.DIST_L2, cv2.DIST_MASK_PRECISE)]:
            fields[name] = cv2.distanceTransform((~strong).astype(np.uint8), kind, size) if strong.any() else np.zeros(base.shape)
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        for j, (metric, radius) in enumerate(PLANS):
            mask = strong | (weak & (fields[metric] <= radius))
            counts[row['split']][j] += [np.count_nonzero(mask & gt), np.count_nonzero(mask & ~gt),
                                       np.count_nonzero(~mask & gt)]
        if (i + 1) % 200 == 0:
            print(f'Consensus recovery shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return counts


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'source-report', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    source = read(args.source_report)
    strong, weak = source['allIoU70'], source['allRecall99999']
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=8, initializer=initialize,
            initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve(), strong, weak)) as pool:
        parts = list(pool.map(partition, [(rows[i::8], i) for i in range(8)]))
    counts = {s: sum(p[s] for p in parts) for s in ['train', 'dev', 'test']}
    best = {k: None for k in ['allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for i, (metric, radius) in enumerate(PLANS):
        totals = {s: c[i] for s, c in counts.items()}
        all_counts = sum(totals.values())
        for key in best:
            c = all_counts
            recall, iou = c[0] / (c[0] + c[2]), c[0] / c.sum()
            valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
            if key == 'eachSplitRecall99999':
                valid &= all(v[0] / (v[0] + v[2]) >= .99999 for v in totals.values())
            rank = float(recall if key == 'allIoU70' else iou), float(iou)
            if not valid or rank <= ranks[key]:
                continue
            ranks[key] = rank
            best[key] = dict(confidenceRecovery=dict(strong=strong, weak=weak,
                metric=metric, radiusPixels=radius, emptyStrongFallback='retain-weak'),
                all=metrics(all_counts), bySplit={s: metrics(v) for s, v in totals.items()})
    np.savez_compressed(args.out / 'COUNTS.npz', **counts)
    save(args.out / 'RESULT.json', dict(**best, modelSHA256=sha(args.model), maskCount=len(rows),
        GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
        testPreviouslyInspected=True, templateCalibrationScope='observed-all',
        candidateCount=len(PLANS), seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
