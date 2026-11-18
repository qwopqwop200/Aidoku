"""RF non-text disagreement plus weak pixel evidence; never bbox clipping."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_style_calibration import style_features
from apply_joint_mask_refinement import refine_source_mask
from boundary_uniformity_dense import rgb_gradient
from prepare_full_rf import load_case_features
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point

CONFIGS = None
MARGINS = 513


def initialize(root, model, cache, configs):
    global CONFIGS
    CONFIGS = configs
    joint.initialize(root, model, cache)


def partition(payload):
    rows, ordinal = payload
    shape = (len(CONFIGS), 2, 2, 2, 2, 65, MARGINS)
    hist = {s: np.zeros(shape, np.int64) for s in ['train', 'dev', 'test']}
    counts = {s: np.zeros((len(CONFIGS), 3), np.int64) for s in hist}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        values = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
        predictions = [refine_source_mask(base, distance, group, codes, cfg, values,
            row['fontPixels'], rgb, (p, q)) > 0 for cfg in CONFIGS]
        full = load_case_features(row, joint.STATE['root'] / 'boundary-lean')
        text = [np.maximum(full[:, :, 0], full[:, :, 3]),
                np.maximum(full[:, :, 15] * full[:, :, 16], full[:, :, 17] * full[:, :, 18])]
        nontext = [[full[:, :, 6], full[:, :, 9]],
                   [full[:, :, 19] * full[:, :, 20], full[:, :, 21] * full[:, :, 22]]]
        strength = np.minimum(64, np.ceil(np.maximum(p, q) * 64 - 1e-6)).astype(np.int32)
        flat = rgb_gradient(rgb) == 0
        fields = [[np.clip(np.rint((field - text[mode] + 1) * 256), 0, MARGINS - 1).astype(np.int32)
                   for field in nontext[mode]] for mode in range(2)]
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        s = row['split']
        for variant, mask in enumerate(predictions):
            counts[s][variant] += [np.count_nonzero(mask & gt), np.count_nonzero(mask & ~gt), np.count_nonzero(~mask & gt)]
            for mode in range(2):
                for semantic in range(2):
                    field = fields[mode][semantic]
                    for flat_only in range(2):
                        selected = mask & (flat if flat_only else True)
                        positions = np.flatnonzero(selected.ravel())
                        code = strength.ravel()[positions] * MARGINS + field.ravel()[positions]
                        positive = gt.ravel()[positions]
                        for label, members in enumerate([positive, ~positive]):
                            hist[s][variant, mode, semantic, flat_only, label] += np.bincount(
                                code[members], minlength=65 * MARGINS).reshape(65, MARGINS)
        if (i + 1) % 200 == 0:
            print(f'Semantic pruning shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return counts, hist


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--reports', type=Path, nargs='+', required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    configs = [read(path)['allRecall99999'] for path in args.reports]
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=8, initializer=initialize,
            initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve(), configs)) as pool:
        parts = list(pool.map(partition, [(rows[i::8], i) for i in range(8)]))
    counts = {s: sum(p[0][s] for p in parts) for s in ['train', 'dev', 'test']}
    hist = {s: sum(p[1][s] for p in parts) for s in counts}
    cumulative = {s: h.cumsum(axis=5)[:, :, :, :, :, :, ::-1].cumsum(axis=6)[:, :, :, :, :, :, ::-1]
                  for s, h in hist.items()}
    best = {k: None for k in ['allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for v, config in enumerate(configs):
        for mode in range(2):
            for semantic in range(2):
                for flat_only in range(2):
                    for strength in [0, 1, 2, 3, 4, 8, 16, 32, 64]:
                        values = {}
                        for s, h in cumulative.items():
                            removed = h[v, mode, semantic, flat_only, :, strength]
                            values[s] = counts[s][v, :, None] + np.stack([-removed[0], -removed[1], removed[0]])
                        all_counts = sum(values.values())
                        for key in best:
                            c = all_counts
                            recall = c[0] / (c[0] + c[2])
                            iou = c[0] / c.sum(axis=0)
                            valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
                            if key == 'eachSplitRecall99999':
                                for a in values.values():
                                    valid &= a[0] / (a[0] + a[2]) >= .99999
                            eligible = np.flatnonzero(valid)
                            if not len(eligible):
                                continue
                            objective = recall if key == 'allIoU70' else iou
                            margin = int(eligible[np.argmax(objective[eligible])])
                            rank = float(objective[margin]), float(iou[margin])
                            if rank <= ranks[key]:
                                continue
                            ranks[key] = rank
                            best[key] = dict(config, semanticBackgroundGate=dict(
                                rfEvidence='global' if mode == 0 else 'owner',
                                competingClass=2 if semantic == 0 else 3,
                                flatSourceOnly=bool(flat_only), maximumPixelStrengthCode=strength,
                                minimumMarginCode=margin, marginOffset=1, marginScale=256),
                                all=metrics(all_counts[:, margin]), bySplit={s: metrics(a[:, margin]) for s, a in values.items()})
    np.savez_compressed(args.out / 'COUNTS.npz', **hist, **{s + '_base': c for s, c in counts.items()})
    save(args.out / 'RESULT.json', dict(**best, GTAtInference=False, GTChanged=False, sourceOnly=True,
        bboxClipping=False, productionEnabled=False, testPreviouslyInspected=True,
        modelSHA256=sha(args.model), maskCount=len(rows), seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
