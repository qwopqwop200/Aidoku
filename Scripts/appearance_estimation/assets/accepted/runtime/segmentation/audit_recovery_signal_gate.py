"""Keep strong consensus; restrict only added weak pixels using source RGB variation."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time
import cv2
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_style_calibration import style_features
from audit_consensus_recovery import PLANS
from boundary_uniformity_dense import rgb_gradient
from apply_joint_mask_refinement import refine_source_mask
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point

STRONG = None
WEAK = None
RADII = [0, 1, 2, 3, 5]


def initialize(root, model, cache, strong, weak):
    global STRONG, WEAK
    STRONG, WEAK = strong, weak
    joint.initialize(root, model, cache)


def partition(payload):
    rows, ordinal = payload
    hist = {s: np.zeros((len(PLANS), len(RADII), 2, 256), np.int64) for s in ['train', 'dev', 'test']}
    counts = {s: np.zeros(3, np.int64) for s in hist}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        values = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
        strong = refine_source_mask(base, distance, group, codes, STRONG, values, row['fontPixels'], rgb) > 0
        weak = refine_source_mask(base, distance, group, codes, WEAK, values, row['fontPixels'], rgb) > 0
        if not strong.any():
            strong = weak.copy()
        fields = {name: cv2.distanceTransform((~strong).astype(np.uint8), kind, size)
            for name, kind, size in [('chebyshev', cv2.DIST_C, 3), ('manhattan', cv2.DIST_L1, 3),
                                    ('euclidean', cv2.DIST_L2, cv2.DIST_MASK_PRECISE)]}
        gradient = rgb_gradient(rgb)
        signals = [gradient if r == 0 else cv2.dilate(gradient, np.ones((2 * r + 1, 2 * r + 1), np.uint8)) for r in RADII]
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        s = row['split']
        counts[s] += [np.count_nonzero(strong & gt), np.count_nonzero(strong & ~gt), np.count_nonzero(~strong & gt)]
        for j, (metric, radius) in enumerate(PLANS):
            candidate = weak & ~strong & (fields[metric] <= radius)
            for r, signal in enumerate(signals):
                hist[s][j, r, 0] += np.bincount(signal[candidate & gt], minlength=256)
                hist[s][j, r, 1] += np.bincount(signal[candidate & ~gt], minlength=256)
        if (i + 1) % 200 == 0:
            print(f'Recovery signal shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return counts, hist


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
    counts = {s: sum(p[0][s] for p in parts) for s in ['train', 'dev', 'test']}
    hist = {s: sum(p[1][s] for p in parts)[:, :, :, ::-1].cumsum(axis=3)[:, :, :, ::-1] for s in counts}
    best = {k: None for k in ['allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for j, (metric, radius) in enumerate(PLANS):
        for r, signal_radius in enumerate(RADII):
            for contrast in range(65):
                totals = {}
                for s, h in hist.items():
                    add = h[j, r, :, contrast]
                    totals[s] = counts[s] + [add[0], add[1], -add[0]]
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
                        metric=metric, radiusPixels=radius, emptyStrongFallback='retain-weak',
                        weakSignalGate=dict(radiusPixels=signal_radius, minimumContrast=contrast)),
                        all=metrics(all_counts), bySplit={s: metrics(v) for s, v in totals.items()})
    np.savez_compressed(args.out / 'COUNTS.npz', **hist, **{s + '_base': c for s, c in counts.items()})
    save(args.out / 'RESULT.json', dict(**best, modelSHA256=sha(args.model), maskCount=len(rows),
        GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
        testPreviouslyInspected=True, templateCalibrationScope='observed-all', seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
