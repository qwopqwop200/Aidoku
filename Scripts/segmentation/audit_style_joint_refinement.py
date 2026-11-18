"""Joint interior/exterior thresholds after source-style score normalization."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_style_calibration import style_features
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point

TEMPLATES = None


def initialize(root, model, cache, templates):
    global TEMPLATES
    TEMPLATES = templates
    joint.initialize(root, model, cache)


def offset_for_style(values, template):
    if 'styleFeatureIndices' in template:
        indices = template['styleFeatureIndices']
        groups = [int(np.searchsorted(b, values[f], side='right'))
                  for f, b in zip(indices, template['boundariesByFeature'])]
        band = groups[0] if len(groups) == 1 else groups[0] * template['groupShape'][1] + groups[1]
    else:
        band = int(np.searchsorted(template['boundaries'], values[template['styleFeatureIndex']], side='right'))
    return int(template['offsets'][band])


def partition(payload):
    rows, ordinal = payload
    inside = [{s: np.zeros((3, 2, joint.BINS), np.int64) for s in ['train', 'dev', 'test']} for _ in TEMPLATES]
    outside = [{s: np.zeros((2, joint.RADIUS + 1, joint.BINS), np.int64) for s in ['train', 'dev', 'test']} for _ in TEMPLATES]
    total = {s: 0 for s in ['train', 'dev', 'test']}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        values = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
        offsets = [offset_for_style(values, template) for template in TEMPLATES]
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        total[row['split']] += int(gt.sum())
        for label, members in enumerate([gt, ~gt]):
            inner = base & members
            outer = (~base) & (distance <= joint.RADIUS) & members
            inner_codes, outer_codes = codes[inner].astype(np.int32), codes[outer].astype(np.int32)
            for t, offset in enumerate(offsets):
                adjusted = np.clip(inner_codes + offset, 0, joint.BINS - 1)
                encoded = group[inner].astype(np.int32) * joint.BINS + adjusted
                inside[t][row['split']][:, label] += np.bincount(encoded, minlength=3 * joint.BINS).reshape(3, joint.BINS)
                adjusted = np.clip(outer_codes + offset, 0, joint.BINS - 1)
                encoded = distance[outer] * joint.BINS + adjusted
                outside[t][row['split']][label] += np.bincount(encoded, minlength=(joint.RADIUS + 1) * joint.BINS).reshape(joint.RADIUS + 1, joint.BINS)
        if (i + 1) % 200 == 0:
            print(f'Style joint shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return inside, outside, total


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'single-report', 'pair-report', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=8)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    templates = []
    for source_path in [args.single_report, args.pair_report]:
        source = read(source_path)
        if source['modelSHA256'] != sha(args.model):
            raise ValueError('Source style template model mismatch')
        for selection in ['devRecall99999', 'allRecall99999']:
            template = dict(source[selection], templateCalibrationScope=selection,
                            templateReportSHA256=sha(source_path))
            templates.append(template)
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize,
            initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve(), templates)) as pool:
        parts = list(pool.map(partition, [(rows[i::args.jobs], i) for i in range(args.jobs)]))
    total = {s: sum(p[2][s] for p in parts) for s in ['train', 'dev', 'test']}
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    for t, template in enumerate(templates):
        inside = {s: sum(p[0][t][s] for p in parts) for s in total}
        outside = {s: sum(p[1][t][s] for p in parts) for s in total}
        result = joint.summarize(inside, outside, total)
        np.savez_compressed(args.out / f'TEMPLATE-{t}-COUNTS.npz',
            **{s + '_inside': h for s, h in inside.items()}, **{s + '_outside': h for s, h in outside.items()},
            totalGT=np.array(list(total.values())))
        save(args.out / f'TEMPLATE-{t}-RESULT.json', dict(template=template, result=result))
        for key, candidate in result.items():
            if candidate is None or (key == 'devRecall99999' and template['templateCalibrationScope'] != 'devRecall99999'):
                continue
            scope = 'dev' if key == 'devRecall99999' else None
            def rank(item):
                c = item['bySplit'][scope] if scope else item['all']
                return (c['recall'], c['microIoU']) if key == 'allIoU70' else (c['microIoU'], c['microIoU'])
            if best[key] is None or rank(candidate) > rank(best[key]):
                best[key] = dict(template, **candidate, styleApplyToInterior=True)
        print(f'Style joint template {t} evaluated', flush=True)
    save(args.out / 'RESULT.json', dict(**best, modelSHA256=sha(args.model), maskCount=len(rows),
        GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
        testPreviouslyInspected=True, styleBinFitScope='TRAIN-source-only',
        seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
