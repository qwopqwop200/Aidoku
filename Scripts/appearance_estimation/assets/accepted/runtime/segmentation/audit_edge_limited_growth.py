"""RGB edge/normal-constrained growth; labels only enter scoring, never growth."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time

import cv2
import numpy as np
from PIL import Image

from audit_kernel_free_completion import component_candidates, metrics
from boundary_uniformity_dense import rgb_gradient
from evaluate_gt import read, save, sha

NAMES = ['gradientMaxRadius' + str(r) for r in [0, 1, 2, 3, 5]]
NAMES += ['gradientMaxFont' + str(s) for s in [.025, .05, .1]]
NAMES += ['nearestBaseRGBDifference']
SIDES = 18


def source_signals(rgb, base, font):
    gradient = rgb_gradient(rgb)
    radii = [0, 1, 2, 3, 5] + [max(0, min(16, int(np.ceil(font * s)))) for s in [.025, .05, .1]]
    cache = {0: gradient}
    for radius in set(radii) - {0}:
        cache[radius] = cv2.dilate(gradient, np.ones((2 * radius + 1, 2 * radius + 1), np.uint8))
    fields = [cache[r] for r in radii]
    if base.any():
        _, labels = cv2.distanceTransformWithLabels((~base).astype(np.uint8), cv2.DIST_L2, 5,
                                                   labelType=cv2.DIST_LABEL_PIXEL)
        colors = np.vstack([np.zeros((1, 3), np.uint8), rgb[base]])
        delta = np.max(np.abs(rgb.astype(np.int16) - colors[labels].astype(np.int16)), axis=2).astype(np.uint8)
    else:
        delta = np.zeros(base.shape, np.uint8)
    fields.append(delta)
    return fields


def partition(payload):
    rows, masks, ordinal = payload
    cv2.setNumThreads(1)
    hist = {s: np.zeros((len(NAMES), 2, SIDES, 256), np.int64) for s in ['train', 'dev', 'test']}
    base_counts = {s: np.zeros(3, np.int64) for s in hist}
    for i, row in enumerate(rows):
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        mask = np.fromfile(Path(masks) / (row['id'] + '.u8'), np.uint8).reshape(rgb.shape[:2])
        base = component_candidates(mask)['fillHoles'] > 0
        distance = cv2.distanceTransform((~base).astype(np.uint8), cv2.DIST_C, 3)
        positions = np.flatnonzero(((distance > 0) & (distance <= 16)).ravel())
        d = distance.ravel()[positions].astype(np.int32)
        fields = source_signals(rgb, base, row['fontPixels'])
        # No target is available until source fields and candidate positions are fixed.
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        positive = gt.ravel()[positions]
        base_counts[row['split']] += [np.count_nonzero(base & gt), np.count_nonzero(base & ~gt),
                                     np.count_nonzero(~base & gt)]
        for f, field in enumerate(fields):
            code = d * 256 + field.ravel()[positions].astype(np.int32)
            for label, member in enumerate([positive, ~positive]):
                hist[row['split']][f, label] += np.bincount(code[member], minlength=SIDES * 256).reshape(SIDES, 256)
        if (i + 1) % 200 == 0:
            print(f'Edge growth shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return hist, base_counts


def summarize(hist, base_counts):
    accumulated = {s: h.cumsum(axis=2) for s, h in hist.items()}
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70']}
    ranks = {k: (-1., -1.) for k in best}
    for f, name in enumerate(NAMES):
        for core in [0, 1, 2, 3]:
            for outer in [3, 4, 5, 7, 10, 12, 16]:
                if outer < core:
                    continue
                totals = {}
                for s, a in accumulated.items():
                    unconditional = a[f, :, core].sum(axis=1)
                    conditional = (a[f, :, outer] - a[f, :, core])[:, ::-1].cumsum(axis=1)[:, ::-1]
                    add = unconditional[:, None] + conditional
                    totals[s] = base_counts[s][:, None] + np.stack([add[0], add[1], -add[0]])
                all_counts = sum(totals.values())
                for key, c in [('devRecall99999', totals['dev']), ('allRecall99999', all_counts), ('allIoU70', all_counts)]:
                    recall = c[0] / (c[0] + c[2])
                    iou = c[0] / c.sum(axis=0)
                    eligible = np.flatnonzero(iou >= .7 if key == 'allIoU70' else recall >= .99999)
                    if not len(eligible):
                        continue
                    score = recall if key == 'allIoU70' else iou
                    threshold = int(eligible[np.argmax(score[eligible])])
                    rank = float(score[threshold]), float(iou[threshold])
                    if rank <= ranks[key]:
                        continue
                    ranks[key] = rank
                    best[key] = dict(signal=name, minimumSignal=threshold, coreRadiusPixels=core,
                        outerRadiusPixels=outer, all=metrics(all_counts[:, threshold]),
                        bySplit={s: metrics(v[:, threshold]) for s, v in totals.items()})
    return best


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    best = read(args.root / 'BEST-RESULT.json')
    masks = ((args.root / best['modelPackage']).parent / 'native-masks').resolve()
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        parts = list(pool.map(partition, [(rows[i::args.jobs], masks, i) for i in range(args.jobs)]))
    hist = {s: sum(p[0][s] for p in parts) for s in ['train', 'dev', 'test']}
    base_counts = {s: sum(p[1][s] for p in parts) for s in hist}
    result = summarize(hist, base_counts)
    result.update(GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
                  testPreviouslyInspected=True, maskCount=len(rows), seconds=time.monotonic() - started)
    save(args.out / 'RESULT.json', result)
    np.savez_compressed(args.out / 'COUNTS.npz', **hist, **{s + '_base': b for s, b in base_counts.items()})
    print(result, flush=True)


if __name__ == '__main__':
    main()
