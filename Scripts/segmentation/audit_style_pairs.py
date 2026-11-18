"""Two smooth source-style logit offsets, using frozen pixel predictions."""
import argparse
from pathlib import Path
import time
import numpy as np

import audit_joint_mask_refinement as joint
from audit_style_calibration import NAMES, INTERIOR, OUTER, shifted
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha

PAIRS = [(1, 5), (1, 10), (1, 7), (5, 9), (1, 12), (5, 13), (5, 16)]
COEFFICIENTS = [-8, -4, -2, 0, 2, 4, 6, 8, 12, 16, 24, 32]


def summarize(styles, core, scores, splits):
    splits = np.asarray(splits)
    base = {s: core[splits == s].sum(axis=0) for s in ['train', 'dev', 'test']}
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for f1, f2 in PAIRS:
        boundaries, member, marginal_centers = [], [], []
        for f in [f1, f2]:
            bounds = np.unique(np.quantile(styles[splits == 'train', f], np.arange(1, 16) / 16))
            group = np.searchsorted(bounds, styles[:, f], side='right')
            medians = np.array([np.median(styles[(splits == 'train') & (group == g), f])
                if np.any((splits == 'train') & (group == g)) else (bounds[min(g, len(bounds) - 1)] if len(bounds) else 0)
                for g in range(len(bounds) + 1)])
            boundaries.append(bounds)
            member.append(group)
            marginal_centers.append(medians)
        shape = [len(b) + 1 for b in boundaries]
        group = member[0] * shape[1] + member[1]
        centers = []
        for g in range(np.prod(shape)):
            train = (splits == 'train') & (group == g)
            if train.any():
                centers.append(np.median(styles[train][:, [f1, f2]], axis=0))
            else:
                centers.append([marginal_centers[0][g // shape[1]], marginal_centers[1][g % shape[1]]])
        centers = np.asarray(centers)
        active = np.unique(group)
        hist = {s: np.stack([scores[(splits == s) & (group == g)].sum(axis=0, dtype=np.int64)
                             for g in active]) for s in base}
        for c1 in COEFFICIENTS:
            for c2 in COEFFICIENTS:
                offsets = np.rint((centers[:, 0] * c1 + centers[:, 1] * c2) * joint.BINS / 48).astype(int)
                totals = {}
                for s, h in hist.items():
                    adjusted = sum(shifted(h[i], int(offsets[g])) for i, g in enumerate(active))
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
                    best[key] = dict(styleFeatureIndices=[f1, f2], styleFeatures=[NAMES[f1], NAMES[f2]],
                        boundariesByFeature=[b.tolist() for b in boundaries], groupShape=shape,
                        centers=centers.tolist(), coefficients=[c1, c2], offsets=offsets.tolist(),
                        interiorThresholdCode=INTERIOR, exteriorThresholdCode=t, coreRadiusPixels=0,
                        outerRadiusPixels=OUTER, protection='none', logitBinCount=joint.BINS,
                        logitMinimum=-24, logitMaximum=24, all=metrics(all_counts[:, t]),
                        bySplit={s: metrics(v[:, t]) for s, v in totals.items()})
        print(f'Style pair completed {NAMES[f1]} + {NAMES[f2]}', flush=True)
    return best


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'collected', 'source-report', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    source = read(args.source_report)
    manifest = args.root / 'boundary-lean/evaluation-manifest.json'
    if source['manifestSHA256'] != sha(manifest):
        raise ValueError('Collected data belongs to another manifest')
    started = time.monotonic()
    with np.load(args.collected) as data:
        styles, core, scores = data['styles'], data['core'], data['scores']
    rows = read(manifest)['items']
    if len(styles) != len(rows):
        raise ValueError('Collected row count mismatch')
    result = summarize(styles, core, scores, [r['split'] for r in rows])
    result.update(GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
        testPreviouslyInspected=True, styleBinCalibrationScope='TRAIN-source-features-only',
        interiorPolicyCalibrationScope='previous-observed-corpus', modelSHA256=source['modelSHA256'],
        collectedSHA256=sha(args.collected), sourceReportSHA256=sha(args.source_report),
        maskCount=len(rows), seconds=time.monotonic() - started)
    save(args.out / 'RESULT.json', result)
    print({key: value['all'] if value else None for key, value in result.items()
           if key in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}, flush=True)


if __name__ == '__main__':
    main()
