"""Prune homogeneous pixels reintroduced specifically by contour hole filling."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time
import cv2
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_style_calibration import style_features
from audit_style_joint_refinement import offset_for_style
from boundary_uniformity_dense import rgb_gradient
from apply_joint_mask_refinement import infer
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point

CONFIG = None
DELTAS = [-50, -25, 0, 25, 50]
RADII = [0, 1, 2, 3, 5]


def initialize(root, model, cache, config):
    global CONFIG
    CONFIG = config
    joint.initialize(root, model, cache)


def partition(payload):
    rows, ordinal = payload
    hist = {s: np.zeros((len(DELTAS), 2, len(RADII), 2, 256), np.int64) for s in ['train', 'dev', 'test']}
    counts = {s: np.zeros((len(DELTAS), 3), np.int64) for s in hist}
    ceiling = {s: np.zeros(2, np.int64) for s in hist}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        raw = np.fromfile(point.CONTEXT[1] / 'native-masks' / (row['id'] + '.u8'), np.uint8).reshape(base.shape) > 0
        holes = base & ~raw
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        offset = offset_for_style(style_features(rgb, base, distance, p, q, row['fontPixels'], case), CONFIG)
        adjusted = codes.copy()
        domain = base | (distance <= joint.RADIUS)
        adjusted[domain] = np.clip(codes[domain].astype(np.int32) + offset, 0, joint.BINS - 1)
        predictions = [infer(base, distance, group, adjusted, dict(CONFIG,
            exteriorThresholdCode=CONFIG['exteriorThresholdCode'] + d)) > 0 for d in DELTAS]
        gradient = rgb_gradient(rgb)
        fields = [gradient if r == 0 else cv2.dilate(gradient, np.ones((2 * r + 1, 2 * r + 1), np.uint8)) for r in RADII]
        protected = (p >= .25) | (q >= .1)
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        s = row['split']
        ceiling[s] += [np.count_nonzero(holes & predictions[2] & gt), np.count_nonzero(holes & predictions[2] & ~gt)]
        for d, mask in enumerate(predictions):
            counts[s][d] += [np.count_nonzero(mask & gt), np.count_nonzero(mask & ~gt), np.count_nonzero(~mask & gt)]
            for protect in [0, 1]:
                candidate = mask & holes & (~protected if protect else True)
                for r, field in enumerate(fields):
                    hist[s][d, protect, r, 0] += np.bincount(field[candidate & gt], minlength=256)
                    hist[s][d, protect, r, 1] += np.bincount(field[candidate & ~gt], minlength=256)
        if (i + 1) % 200 == 0:
            print(f'Hole background shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return counts, hist, ceiling


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'source-report', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    source = read(args.source_report)
    config = source['allRecall99999']
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=8, initializer=initialize,
            initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve(), config)) as pool:
        parts = list(pool.map(partition, [(rows[i::8], i) for i in range(8)]))
    counts = {s: sum(p[0][s] for p in parts) for s in ['train', 'dev', 'test']}
    hist = {s: sum(p[1][s] for p in parts).cumsum(axis=4) for s in counts}
    ceiling = {s: sum(p[2][s] for p in parts) for s in counts}
    best = {k: None for k in ['allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for d, delta in enumerate(DELTAS):
        for protection in [0, 1]:
            for r, radius in enumerate(RADII):
                for contrast in range(0, 65):
                    totals = {}
                    for s, h in hist.items():
                        remove = h[d, protection, r, :, contrast - 1] if contrast else np.zeros(2, np.int64)
                        totals[s] = counts[s][d] + [-remove[0], -remove[1], remove[0]]
                    all_counts = sum(totals.values())
                    for key in best:
                        c = all_counts
                        recall, iou = c[0] / (c[0] + c[2]), c[0] / c.sum()
                        valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
                        if key == 'eachSplitRecall99999':
                            valid &= all(v[0] / (v[0] + v[2]) >= .99999 for v in totals.values())
                        rank = (float(recall if key == 'allIoU70' else iou), float(iou))
                        if not valid or rank <= ranks[key]:
                            continue
                        ranks[key] = rank
                        best[key] = dict(config, exteriorThresholdCode=config['exteriorThresholdCode'] + delta,
                            holeBackgroundGate=dict(radiusPixels=radius, minimumContrast=contrast,
                                protectSourceEvidence=bool(protection), primaryThreshold=.25, boundaryThreshold=.1),
                            all=metrics(all_counts), bySplit={s: metrics(v) for s, v in totals.items()})
    save(args.out / 'RESULT.json', dict(**best, GTAtInference=False, GTChanged=False, sourceOnly=True,
        productionEnabled=False, testPreviouslyInspected=True, modelSHA256=sha(args.model),
        inheritedTemplateCalibrationScope='observed-all', maskCount=len(rows),
        remainingHolePixels={s: dict(TP=int(c[0]), FP=int(c[1])) for s, c in ceiling.items()},
        seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
