"""Protect flat weak pixels corroborated by source votes or nearby foreground."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time
import cv2
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_style_calibration import style_features
from boundary_uniformity_dense import rgb_gradient
from apply_joint_mask_refinement import refine_source_mask
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point

STRONG = None
WEAK = None
PLANS = [('manhattan', 1), ('manhattan', 2), ('chebyshev', 1), ('euclidean', 2)]


def initialize(root, model, cache, strong, weak):
    global STRONG, WEAK
    STRONG, WEAK = strong, weak
    joint.initialize(root, model, cache)


def partition(payload):
    rows, ordinal = payload
    shape = (len(PLANS), 2, 2, 9, 65, 49)
    hist = {s: np.zeros(shape, np.int64) for s in ['train', 'dev', 'test']}
    counts = {s: np.zeros((len(PLANS), 3), np.int64) for s in hist}
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
        distances = {name: cv2.distanceTransform((~strong).astype(np.uint8), kind, size)
            for name, kind, size in [('chebyshev', cv2.DIST_C, 3), ('manhattan', cv2.DIST_L1, 3),
                                    ('euclidean', cv2.DIST_L2, cv2.DIST_MASK_PRECISE)]}
        signal = rgb_gradient(rgb) > 0
        pv, qv = np.rint(p * 64).astype(np.int32), np.rint(q * 48).astype(np.int32)
        candidates = [weak & ~strong & (distances[metric] <= radius) for metric, radius in PLANS]
        neighborhoods = []
        for candidate in candidates:
            neighborhoods.append([cv2.filter2D(source.astype(np.uint8), cv2.CV_16U, np.ones((3, 3), np.uint8),
                borderType=cv2.BORDER_CONSTANT) for source in [strong, strong | (candidate & signal)]])
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        s = row['split']
        for j, candidate in enumerate(candidates):
            unfiltered = strong | candidate
            counts[s][j] += [np.count_nonzero(unfiltered & gt), np.count_nonzero(unfiltered & ~gt),
                            np.count_nonzero(~unfiltered & gt)]
            positions = np.flatnonzero((candidate & ~signal).ravel())
            for reference, neighbors in enumerate(neighborhoods[j]):
                code = (neighbors.ravel()[positions].astype(np.int32) * 65 + pv.ravel()[positions]) * 49 + qv.ravel()[positions]
                positive = gt.ravel()[positions]
                for label, member in enumerate([positive, ~positive]):
                    hist[s][j, reference, label] += np.bincount(code[member], minlength=9 * 65 * 49).reshape(9, 65, 49)
        if (i + 1) % 200 == 0:
            print(f'Recovery corroboration shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
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
    hist = {s: sum(p[1][s] for p in parts) for s in counts}
    prefix = {s: np.pad(h.cumsum(3).cumsum(4).cumsum(5), ((0, 0), (0, 0), (0, 0), (1, 0), (1, 0), (1, 0))) for s, h in hist.items()}
    best = {k: None for k in ['allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for j, (metric, radius) in enumerate(PLANS):
        for reference in range(2):
            for neighbors in range(2, 10):
                for primary in [1, 2, 4, 8, 16, 32, 65]:
                    for boundary in [1, 2, 4, 8, 16, 32, 49]:
                        totals = {}
                        for s, h in prefix.items():
                            reject = h[j, reference, :, neighbors, primary, boundary]
                            totals[s] = counts[s][j] + [-reject[0], -reject[1], reject[0]]
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
                                weakSignalGate=dict(radiusPixels=0, minimumContrast=1),
                                sourceCorroboration=dict(neighborReference='strong' if reference == 0 else 'accepted',
                                    minimumNeighbors=neighbors, minimumPrimaryVotes=primary, minimumBoundaryVotes=boundary)),
                                all=metrics(all_counts), bySplit={s: metrics(v) for s, v in totals.items()})
    np.savez_compressed(args.out / 'COUNTS.npz', **hist, **{s + '_base': c for s, c in counts.items()})
    save(args.out / 'RESULT.json', dict(**best, modelSHA256=sha(args.model), maskCount=len(rows),
        GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
        testPreviouslyInspected=True, templateCalibrationScope='observed-all', seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
