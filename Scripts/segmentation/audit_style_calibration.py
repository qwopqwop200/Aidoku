"""Source-style logit offsets on cached predictions; no item-specific thresholds."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time
import cv2
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_kernel_free_completion import metrics
from audit_texture_kernels import NAMES as RING_NAMES
from evaluate_gt import read, save, sha
import train_point_recovery as point

NAMES = RING_NAMES + ['consensusLuminanceMean', 'consensusLuminanceStd', 'consensusChromaMean',
        'consensusDarkFraction', 'consensusBrightFraction', 'fontRelative128']
NAMES += ['rfOwnerAffinityClass' + str(c) for c in range(5)]
INTERIOR = 2815
OUTER = 7
COEFFICIENTS = [-16, -12, -8, -6, -4, -3, -2, -1, 0, 1, 2, 3, 4, 6, 8, 12, 16]


def style_features(rgb, base, distance, p, q, font, rf_case):
    """All crop statistics come from source predictions and RGB, not GT masks."""
    rgb = rgb.astype(np.float32) / 255
    luma = rgb[:, :, 0] * .2126 + rgb[:, :, 1] * .7152 + rgb[:, :, 2] * .0722
    ring = (distance > 0) & (distance <= max(3, min(12, font * .1)))
    if ring.any():
        gradient = cv2.dilate(luma, np.ones((3, 3), np.uint8)) - cv2.erode(luma, np.ones((3, 3), np.uint8))
        colors, light = rgb[ring], luma[ring]
        values = [light.std(), np.quantile(light, .95) - np.quantile(light, .05),
                  (colors.max(axis=1) - colors.min(axis=1)).mean(), colors.std(axis=0).max(),
                  gradient[ring].mean(), (gradient[ring] > .1).mean(), (light < .95).mean()]
    else:
        values = [0.] * len(RING_NAMES)
    seed = (p >= .5) & (q >= .3)
    if not seed.any():
        seed = base
    if seed.any():
        colors, light = rgb[seed], luma[seed]
        values += [light.mean(), light.std(), (colors.max(axis=1) - colors.min(axis=1)).mean(),
                   (light < .25).mean(), (light > .75).mean()]
    else:
        values += [0.] * 5
    values += [min(1., font / 128)] + rf_case['affinityScores']
    return np.asarray(values, np.float64)


def collect(row):
    base, distance, group, codes = joint.source_predictions(row)
    p, q, _ = point.CONTEXT[2].load(row)
    rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
    case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
    styles = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
    inside = base & (codes >= INTERIOR)
    positions = (~base) & (distance <= OUTER)
    if sha(row['target']) != row['targetSHA256']:
        raise ValueError('GT changed')
    gt = np.asarray(Image.open(row['target'])) > 0
    core = np.array([np.count_nonzero(inside & gt), np.count_nonzero(inside & ~gt),
                     np.count_nonzero(gt)], np.int64)
    scores = np.stack([np.bincount(codes[positions & gt], minlength=joint.BINS),
                       np.bincount(codes[positions & ~gt], minlength=joint.BINS)]).astype(np.uint32)
    return styles, core, scores


def shifted(hist, offset):
    """Exact integer-code shift with saturating endpoints."""
    if offset == 0:
        return hist.copy()
    result = np.zeros_like(hist)
    if offset >= hist.shape[-1]:
        result[:, -1] = hist.sum(axis=1)
    elif offset <= -hist.shape[-1]:
        result[:, 0] = hist.sum(axis=1)
    elif offset > 0:
        result[:, offset:] = hist[:, :-offset]
        result[:, -1] += hist[:, -offset:].sum(axis=1)
    else:
        result[:, :offset] = hist[:, -offset:]
        result[:, 0] += hist[:, :-offset].sum(axis=1)
    return result


def summarize(styles, core, scores, splits):
    splits = np.asarray(splits)
    base = {s: core[splits == s].sum(axis=0) for s in ['train', 'dev', 'test']}
    best = {key: None for key in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for f, name in enumerate(NAMES):
        boundaries = np.unique(np.quantile(styles[splits == 'train', f], np.arange(1, 32) / 32))
        groups = np.searchsorted(boundaries, styles[:, f], side='right')
        centers = np.array([np.median(styles[(splits == 'train') & (groups == g), f])
            if np.any((splits == 'train') & (groups == g)) else (boundaries[min(g, len(boundaries) - 1)] if len(boundaries) else 0)
            for g in range(len(boundaries) + 1)])
        hist = {s: np.stack([scores[(splits == s) & (groups == g)].sum(axis=0, dtype=np.int64)
                             for g in range(len(centers))]) for s in base}
        for coefficient in COEFFICIENTS:
            offsets = np.rint(centers * coefficient * joint.BINS / 48).astype(int)
            totals = {}
            for s, h in hist.items():
                adjusted = sum(shifted(h[g], int(offset)) for g, offset in enumerate(offsets))
                additions = adjusted[:, ::-1].cumsum(axis=1)[:, ::-1]
                tp = base[s][0] + additions[0]
                fp = base[s][1] + additions[1]
                totals[s] = np.stack([tp, fp, base[s][2] - tp])
            all_counts = sum(totals.values())
            for key, c in [('devRecall99999', totals['dev']), ('allRecall99999', all_counts),
                           ('allIoU70', all_counts), ('eachSplitRecall99999', all_counts)]:
                recall = c[0] / (c[0] + c[2])
                iou = c[0] / c.sum(axis=0)
                valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
                if key == 'eachSplitRecall99999':
                    for v in totals.values():
                        valid &= v[0] / (v[0] + v[2]) >= .99999
                eligible = np.flatnonzero(valid)
                if not len(eligible):
                    continue
                score = recall if key == 'allIoU70' else iou
                t = int(eligible[np.argmax(score[eligible])])
                rank = float(score[t]), float(iou[t])
                if rank <= ranks[key]:
                    continue
                ranks[key] = rank
                best[key] = dict(styleFeature=name, styleFeatureIndex=f, boundaries=boundaries.tolist(),
                    centers=centers.tolist(), coefficient=coefficient, offsets=offsets.tolist(),
                    interiorThresholdCode=INTERIOR, exteriorThresholdCode=t, coreRadiusPixels=0,
                    outerRadiusPixels=OUTER, protection='none', logitBinCount=joint.BINS,
                    logitMinimum=-24, logitMaximum=24, all=metrics(all_counts[:, t]),
                    bySplit={s: metrics(v[:, t]) for s, v in totals.items()})
    return best


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=8)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=joint.initialize,
                             initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve())) as pool:
        parts = list(pool.map(collect, rows, chunksize=8))
    styles = np.stack([p[0] for p in parts])
    core = np.stack([p[1] for p in parts])
    scores = np.stack([p[2] for p in parts])
    del parts
    np.savez_compressed(args.out / 'COLLECTED.npz', styles=styles, core=core, scores=scores)
    result = summarize(styles, core, scores, [r['split'] for r in rows])
    result.update(GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
                  styleBinCalibrationScope='TRAIN-source-features-only', interiorPolicyCalibrationScope='previous-observed-corpus',
                  testPreviouslyInspected=True, maskCount=len(rows), seconds=time.monotonic() - started,
                  modelSHA256=sha(args.model), manifestSHA256=sha(args.root / 'boundary-lean/evaluation-manifest.json'))
    save(args.out / 'RESULT.json', result)
    print(result, flush=True)


if __name__ == '__main__':
    main()
