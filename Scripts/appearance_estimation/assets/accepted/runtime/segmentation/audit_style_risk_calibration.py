"""Broad source-style risk calibration, fitted on TRAIN+DEV, never TEST labels."""
import argparse
from pathlib import Path
import time
import numpy as np

import audit_joint_mask_refinement as joint
from audit_style_calibration import NAMES, INTERIOR, OUTER
from audit_style_pairs import PAIRS
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha


def summarize(styles, core, scores, rows):
    splits = np.array([r['split'] for r in rows])
    sources = np.array([r['sourceGroup'] for r in rows])
    base = {s: core[splits == s].sum(axis=0) for s in ['train', 'dev', 'test']}
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    layouts = [([f], 8) for f in range(len(NAMES))] + [(list(pair), 4) for pair in PAIRS]
    for features, bins in layouts:
        bounds, shape, member = [], [], []
        for f in features:
            boundaries = np.unique(np.quantile(styles[splits == 'train', f], np.arange(1, bins) / bins))
            bounds.append(boundaries)
            shape.append(len(boundaries) + 1)
            member.append(np.searchsorted(boundaries, styles[:, f], side='right'))
        groups = member[0] if len(features) == 1 else member[0] * shape[1] + member[1]
        count = int(np.prod(shape))
        hist = {s: np.stack([scores[(splits == s) & (groups == g)].sum(axis=0, dtype=np.int64)
                             for g in range(count)]) for s in base}
        train_sources = [len(np.unique(sources[(splits == 'train') & (groups == g)])) for g in range(count)]
        dev_sources = [len(np.unique(sources[(splits == 'dev') & (groups == g)])) for g in range(count)]
        supported = np.array([(a >= 20 and b >= 5) for a, b in zip(train_sources, dev_sources)])
        curves = {s: h[:, :, ::-1].cumsum(axis=2)[:, :, ::-1] for s, h in hist.items()}
        fit = curves['train'] + curves['dev']
        global_fit = fit.sum(axis=0)
        seen = set()

        def evaluate(penalty):
            thresholds = np.argmin(fit[:, 1] - penalty * fit[:, 0], axis=1)
            fallback = int(np.argmin(global_fit[1] - penalty * global_fit[0]))
            thresholds[~supported] = fallback
            totals = {}
            for s, c in curves.items():
                addition = c[np.arange(count), :, thresholds].sum(axis=0)
                tp, fp = base[s][:2] + addition
                totals[s] = np.array([tp, fp, base[s][2] - tp], np.int64)
            return thresholds, totals

        penalties = [(v, 'common') for v in np.geomspace(1., 1e9, 100)]
        # Tighten three recall frontiers without reading TEST labels while fitting
        # the per-style table. TEST is only an explicitly observed scoring scope.
        for selection in ['dev', 'all', 'each']:
            low, high = 1., 1e10
            for _ in range(36):
                middle = np.sqrt(low * high)
                _, totals = evaluate(middle)
                c = totals['dev'] if selection == 'dev' else sum(totals.values())
                valid = c[2] <= (c[0] + c[2]) * .00001
                if selection == 'each':
                    valid = all(v[2] <= (v[0] + v[2]) * .00001 for v in totals.values())
                if valid:
                    high = middle
                else:
                    low = middle
            penalties += [(v, selection) for v in [high, high * 1.00001, low]]
        for penalty, scope in penalties:
            thresholds, totals = evaluate(penalty)
            signature = thresholds.tobytes()
            if signature in seen:
                continue
            seen.add(signature)
            all_counts = sum(totals.values())
            for key, c in [('devRecall99999', totals['dev']), ('allRecall99999', all_counts),
                           ('allIoU70', all_counts), ('eachSplitRecall99999', all_counts)]:
                if key == 'devRecall99999' and scope in ['all', 'each']:
                    continue
                recall = c[0] / (c[0] + c[2])
                iou = c[0] / c.sum()
                valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
                if key == 'eachSplitRecall99999':
                    valid &= all(v[0] / (v[0] + v[2]) >= .99999 for v in totals.values())
                if not valid:
                    continue
                rank = float(recall if key == 'allIoU70' else iou), float(iou)
                if rank <= ranks[key]:
                    continue
                ranks[key] = rank
                best[key] = dict(styleFeatureIndices=features, styleFeatures=[NAMES[f] for f in features],
                    boundariesByFeature=[b.tolist() for b in bounds], groupShape=shape,
                    exteriorThresholds=thresholds.tolist(), falseNegativePenalty=float(penalty),
                    trainSourceGroupsPerBin=train_sources, devSourceGroupsPerBin=dev_sources,
                    sourceSupportFallback=(~supported).tolist(), minimumTrainSourceGroups=20,
                    minimumDevSourceGroups=5, interiorThresholdCode=INTERIOR, coreRadiusPixels=0,
                    outerRadiusPixels=OUTER, protection='none', logitBinCount=joint.BINS,
                    logitMinimum=-24, logitMaximum=24, all=metrics(all_counts),
                    bySplit={s: metrics(v) for s, v in totals.items()})
        print('Risk style completed ' + ' + '.join(NAMES[f] for f in features), flush=True)
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
        raise ValueError('Collected manifest mismatch')
    with np.load(args.collected) as data:
        styles, core, scores = data['styles'], data['core'], data['scores']
    started = time.monotonic()
    rows = read(manifest)['items']
    result = summarize(styles, core, scores, rows)
    result.update(GTAtInference=False, GTChanged=False, sourceOnly=True, caseIdentityFeatures=False,
        productionEnabled=False, testPreviouslyInspected=True, styleBinCalibrationScope='TRAIN-source-only',
        styleThresholdFitScope='TRAIN+DEV-labels; no TEST labels',
        interiorPolicyCalibrationScope='previous-observed-corpus', maskCount=len(rows),
        modelSHA256=source['modelSHA256'], collectedSHA256=sha(args.collected), seconds=time.monotonic() - started)
    save(args.out / 'RESULT.json', result)
    print({k: v['all'] if v else None for k, v in result.items()
           if k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}, flush=True)


if __name__ == '__main__':
    main()
