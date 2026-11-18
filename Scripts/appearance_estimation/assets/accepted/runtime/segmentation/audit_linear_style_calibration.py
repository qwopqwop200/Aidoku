"""Regularized shared crop-style offsets on a frozen per-pixel classifier."""
import argparse
from pathlib import Path
import time
import numpy as np
from scipy.optimize import minimize
from scipy.special import expit

import audit_joint_mask_refinement as joint
from audit_style_calibration import NAMES, INTERIOR, OUTER, shifted
from audit_style_pairs import PAIRS
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha


def expanded(styles):
    return np.column_stack([styles, styles * styles,
                            *[styles[:, a] * styles[:, b] for a, b in PAIRS]])


def normalized_features(styles, mean, scale):
    return np.clip((expanded(styles) - mean) / scale, -8, 8)


def training_data(features, scores, selected):
    parts, logits, targets, weights = [], [], [], []
    for i in np.flatnonzero(selected):
        h = scores[i]
        positive = np.flatnonzero(h[0])
        negative = h[1].reshape(128, -1).sum(axis=1)
        indices = np.flatnonzero(negative)
        positions = np.arange(joint.BINS).reshape(128, -1)
        weighted = (h[1].reshape(128, -1) * positions).sum(axis=1)
        negative_codes = weighted[indices] / negative[indices]
        codes = np.concatenate([positive, negative_codes])
        parts.append(np.repeat(features[i:i + 1], len(codes), axis=0))
        logits.append(codes * 48 / joint.BINS - 24)
        targets.append(np.concatenate([np.ones(len(positive)), np.zeros(len(indices))]))
        weights.append(np.concatenate([h[0, positive], negative[indices]]))
    return np.concatenate(parts), np.concatenate(logits), np.concatenate(targets), np.concatenate(weights)


def evaluate_offsets(offsets, core, scores, splits):
    base = {s: core[splits == s].sum(axis=0) for s in ['train', 'dev', 'test']}
    hist = {s: np.zeros((2, joint.BINS), np.int64) for s in base}
    for i, offset in enumerate(offsets):
        hist[splits[i]] += shifted(scores[i].astype(np.int64), int(offset))
    totals = {}
    for s, h in hist.items():
        add = h[:, ::-1].cumsum(axis=1)[:, ::-1]
        tp, fp = base[s][:2, None] + add
        totals[s] = np.stack([tp, fp, base[s][2] - tp])
    return totals


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'collected', 'source-report', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = args.root / 'boundary-lean/evaluation-manifest.json'
    source = read(args.source_report)
    if source['manifestSHA256'] != sha(manifest):
        raise ValueError('Collected manifest mismatch')
    with np.load(args.collected) as data:
        styles, core, scores = data['styles'], data['core'], data['scores']
    rows = read(manifest)['items']
    splits = np.array([r['split'] for r in rows])
    raw = expanded(styles)
    mean, scale = raw[splits == 'train'].mean(axis=0), np.maximum(raw[splits == 'train'].std(axis=0), .02)
    features = normalized_features(styles, mean, scale)
    x, z, y, raw_weight = training_data(features, scores, splits != 'test')
    x = np.column_stack([x, np.ones(len(x))])
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    training = []
    started = time.monotonic()
    for positive_weight in [100, 1000, 10000]:
        weight = raw_weight * np.where(y, positive_weight, 1.)
        weight = weight / weight.sum()
        for penalty in [.0001, .001, .01]:
            def objective(beta):
                values = z + x @ beta
                residual = weight * (expit(values) - y)
                loss = np.dot(weight, np.logaddexp(0, values) - y * values)
                reg = beta.copy()
                reg[-1] = 0
                return loss + penalty * np.dot(reg, reg) / 2, x.T @ residual + penalty * reg
            fit = minimize(objective, np.zeros(x.shape[1]), method='L-BFGS-B', jac=True,
                           options=dict(maxiter=1000, maxcor=30, ftol=1e-9, gtol=1e-6))
            if not fit.success:
                raise ValueError('Style optimizer did not converge: ' + str(fit.message))
            coefficients = fit.x[:-1]
            offsets = np.rint((features @ coefficients) * joint.BINS / 48).astype(int)
            totals = evaluate_offsets(offsets, core, scores, splits)
            all_counts = sum(totals.values())
            model = dict(kind='regularized-linear-style-logit-offset', sourceFeatureNames=NAMES,
                squareFeatures=True, productFeatureIndices=[list(p) for p in PAIRS],
                mean=mean.tolist(), scale=scale.tolist(), coefficients=coefficients.tolist(),
                normalizedFeatureClip=8, interceptUsedOnlyDuringTraining=float(fit.x[-1]),
                positiveWeight=positive_weight, l2Penalty=penalty, fitScope='TRAIN+DEV; excludes TEST')
            training.append(dict(positiveWeight=positive_weight, penalty=penalty, iterations=int(fit.nit),
                                  loss=float(fit.fun), converged=bool(fit.success)))
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
                best[key] = dict(styleCalibration=model, interiorThresholdCode=INTERIOR,
                    exteriorThresholdCode=t, coreRadiusPixels=0, outerRadiusPixels=OUTER,
                    protection='none', logitBinCount=joint.BINS, logitMinimum=-24, logitMaximum=24,
                    all=metrics(all_counts[:, t]), bySplit={s: metrics(v[:, t]) for s, v in totals.items()})
            print(f'Linear style calibrated weight={positive_weight}, L2={penalty}', flush=True)
    save(args.out / 'RESULT.json', dict(**best, training=training, trainingHistogramRows=len(y),
        parameterCount=features.shape[1], GTAtInference=False, GTChanged=False, sourceOnly=True,
        caseIdentityFeatures=False, productionEnabled=False, testPreviouslyInspected=True,
        styleNormalizationFitScope='TRAIN-source-only', styleCoefficientFitScope='TRAIN+DEV; no TEST',
        interiorPolicyCalibrationScope='previous-observed-corpus', maskCount=len(rows),
        modelSHA256=source['modelSHA256'], collectedSHA256=sha(args.collected), seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
