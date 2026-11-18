"""Source-mask closing after calibrated classification, before any GT scoring."""
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
DELTAS = [0, 25, 50, 75, 100, 150, 200, 300]
OPERATIONS = ['none', 'close3', 'close5', 'close7', 'ellipse5', 'cross5', 'horizontal7', 'vertical7',
              'fillHoles', 'close3FillHoles', 'close5FillHoles']


def initialize(root, model, cache, templates):
    global TEMPLATES
    TEMPLATES = templates
    joint.initialize(root, model, cache)


def finish_mask(mask, operation):
    """This function accepts only a predicted mask and a global operation."""
    if operation == 'none':
        return mask
    if operation == 'fillHoles':
        result = mask.copy()
    else:
        if operation.startswith('close3'):
            kernel = np.ones((3, 3), np.uint8)
        elif operation.startswith('close5'):
            kernel = np.ones((5, 5), np.uint8)
        elif operation == 'close7':
            kernel = np.ones((7, 7), np.uint8)
        elif operation == 'ellipse5':
            kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
        elif operation == 'cross5':
            kernel = cv2.getStructuringElement(cv2.MORPH_CROSS, (5, 5))
        elif operation == 'horizontal7':
            kernel = np.ones((1, 7), np.uint8)
        elif operation == 'vertical7':
            kernel = np.ones((7, 1), np.uint8)
        else:
            raise ValueError('Unknown mask postprocess')
        result = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    if operation == 'fillHoles' or operation.endswith('FillHoles'):
        contours, _ = cv2.findContours(result, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(result, contours, -1, 255, cv2.FILLED)
    return result


def settings():
    return [(t, core, delta, operation) for t in range(len(TEMPLATES)) for core in [0, 1]
            for delta in DELTAS for operation in OPERATIONS]


def partition(payload):
    rows, ordinal = payload
    plans = settings()
    counts = {s: np.zeros((len(plans), 3), np.int64) for s in ['train', 'dev', 'test']}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        values = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
        shifted_codes = []
        domain = base | (distance <= joint.RADIUS)
        for template in TEMPLATES:
            offset = offset_for_style(values, template)
            adjusted = codes.copy()
            adjusted[domain] = np.clip(codes[domain].astype(np.int32) + offset, 0, joint.BINS - 1)
            shifted_codes.append(adjusted)
        # All inference parameters are fixed and label-free. GT is consumed only
        # by the independent count expressions, never by infer/finish_mask.
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        previous, raw_mask = None, None
        for j, (t, core, delta, operation) in enumerate(plans):
            key = t, core, delta
            if key != previous:
                config = dict(TEMPLATES[t], coreRadiusPixels=core,
                              exteriorThresholdCode=TEMPLATES[t]['exteriorThresholdCode'] + delta)
                raw_mask = infer(base, distance, group, shifted_codes[t], config)
                previous = key
            result = finish_mask(raw_mask, operation) > 0
            counts[row['split']][j] += [np.count_nonzero(result & gt), np.count_nonzero(result & ~gt),
                                       np.count_nonzero(~result & gt)]
        if (i + 1) % 100 == 0:
            print(f'Final closing shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return counts


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'source-report', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=8)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    source = read(args.source_report)
    templates = [dict(source[k], sourceTemplateScope=k) for k in ['devRecall99999', 'allRecall99999']]
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize,
            initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve(), templates)) as pool:
        parts = list(pool.map(partition, [(rows[i::args.jobs], i) for i in range(args.jobs)]))
    counts = {s: sum(p[s] for p in parts) for s in ['train', 'dev', 'test']}
    global TEMPLATES
    TEMPLATES = templates
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    rank = {k: (-1., -1.) for k in best}
    for i, (t, core, delta, operation) in enumerate(settings()):
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
            candidate_rank = (float(recall if key == 'allIoU70' else iou), float(iou))
            if not valid or candidate_rank <= rank[key]:
                continue
            rank[key] = candidate_rank
            best[key] = dict(templates[t], coreRadiusPixels=core,
                exteriorThresholdCode=templates[t]['exteriorThresholdCode'] + delta,
                finalMaskPostprocess=operation, all=metrics(all_counts),
                bySplit={s: metrics(c) for s, c in totals.items()})
    np.savez_compressed(args.out / 'COUNTS.npz', **counts)
    save(args.out / 'RESULT.json', dict(**best, modelSHA256=sha(args.model), maskCount=len(rows),
        GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
        testPreviouslyInspected=True, sourceReportSHA256=sha(args.source_report),
        candidateCount=len(settings()), seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
