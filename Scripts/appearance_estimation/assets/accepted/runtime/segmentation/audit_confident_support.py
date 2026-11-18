"""Recover weak pixels only near a stricter prediction from the same source model."""
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
from apply_joint_mask_refinement import infer
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point

TEMPLATES = None
WEAK = [-100, -50, 0]
STRONG = [100, 200, 400, 800]
STRONG_PAIRS = [(d, d) for d in STRONG]
RADII = [1, 2, 3, 5, 7, 'font.025', 'font.05']


def initialize(root, model, cache, templates, fine=False):
    global TEMPLATES, WEAK, STRONG_PAIRS, RADII
    TEMPLATES = templates
    if fine:
        WEAK = [-100, -75, -50, -25, 0]
        STRONG_PAIRS = [(i, e) for i in [100, 200, 400, 600] for e in [100, 200, 300]]
        RADII = [1]
    joint.initialize(root, model, cache)


def plans():
    return [(t, weak, interior, exterior, radius) for t in range(len(TEMPLATES)) for weak in WEAK
            for interior, exterior in STRONG_PAIRS for radius in RADII]


def support_masks(base, distance, group, codes, template, font):
    """No GT is accepted; the strict mask is nested within the weak prediction."""
    weak_masks = {d: infer(base, distance, group, codes, dict(template,
        exteriorThresholdCode=template['exteriorThresholdCode'] + d)) > 0 for d in WEAK}
    strong_masks = {(i, e): infer(base, distance, group, codes, dict(template, coreRadiusPixels=0,
        interiorThresholdCode=template['interiorThresholdCode'] + i,
        exteriorThresholdCode=template['exteriorThresholdCode'] + e)) > 0 for i, e in STRONG_PAIRS}
    fields = {d: cv2.distanceTransform((~m).astype(np.uint8), cv2.DIST_C, 3)
              if m.any() else np.zeros(base.shape, np.float32) for d, m in strong_masks.items()}
    for weak in WEAK:
        for strong in STRONG_PAIRS:
            if np.any(strong_masks[strong] & ~weak_masks[weak]):
                raise ValueError('Strong evidence is not nested in weak mask')
            for radius in RADII:
                pixels = int(radius) if isinstance(radius, int) else max(1, min(12, int(np.ceil(font * float(radius[4:])))))
                yield weak_masks[weak] & (fields[strong] <= pixels)


def partition(payload):
    rows, ordinal = payload
    counts = {s: np.zeros((len(plans()), 3), np.int64) for s in ['train', 'dev', 'test']}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        values = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
        adjusted = []
        domain = base | (distance <= joint.RADIUS)
        for template in TEMPLATES:
            shifted = codes.copy()
            shifted[domain] = np.clip(codes[domain].astype(np.int32) + offset_for_style(values, template), 0, joint.BINS - 1)
            adjusted.append(shifted)
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        index = 0
        for t, template in enumerate(TEMPLATES):
            for mask in support_masks(base, distance, group, adjusted[t], template, row['fontPixels']):
                counts[row['split']][index] += [np.count_nonzero(mask & gt), np.count_nonzero(mask & ~gt),
                                              np.count_nonzero(~mask & gt)]
                index += 1
        if (i + 1) % 200 == 0:
            print(f'Confidence support shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return counts


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'source-report', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--fine', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    source = read(args.source_report)
    templates = [dict(source[k], sourceTemplateScope=k) for k in ['devRecall99999', 'allRecall99999']]
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=8, initializer=initialize,
            initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve(), templates, args.fine)) as pool:
        parts = list(pool.map(partition, [(rows[i::8], i) for i in range(8)]))
    counts = {s: sum(p[s] for p in parts) for s in ['train', 'dev', 'test']}
    global TEMPLATES, WEAK, STRONG_PAIRS, RADII
    TEMPLATES = templates
    if args.fine:
        WEAK = [-100, -75, -50, -25, 0]
        STRONG_PAIRS = [(i, e) for i in [100, 200, 400, 600] for e in [100, 200, 300]]
        RADII = [1]
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for i, (t, weak, interior, exterior, radius) in enumerate(plans()):
        totals = {s: c[i] for s, c in counts.items()}
        all_counts = sum(totals.values())
        for key, c in [('devRecall99999', totals['dev']), ('allRecall99999', all_counts),
                       ('allIoU70', all_counts), ('eachSplitRecall99999', all_counts)]:
            if key == 'devRecall99999' and templates[t]['sourceTemplateScope'] != 'devRecall99999':
                continue
            recall, iou = c[0] / (c[0] + c[2]), c[0] / c.sum()
            valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
            if key == 'eachSplitRecall99999':
                valid &= all(v[0] / (v[0] + v[2]) >= .99999 for v in totals.values())
            rank = float(recall if key == 'allIoU70' else iou), float(iou)
            if not valid or rank <= ranks[key]:
                continue
            ranks[key] = rank
            best[key] = dict(templates[t], confidenceSupport=dict(weakExteriorDelta=weak,
                strongInteriorDelta=interior, strongExteriorDelta=exterior, radius=radius,
                strongCoreRadiusPixels=0, emptyStrongFallback='retain-weak'),
                all=metrics(all_counts), bySplit={s: metrics(v) for s, v in totals.items()})
    np.savez_compressed(args.out / 'COUNTS.npz', **counts)
    save(args.out / 'RESULT.json', dict(**best, modelSHA256=sha(args.model), maskCount=len(rows),
        GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
        testPreviouslyInspected=True, candidateCount=len(plans()), seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
