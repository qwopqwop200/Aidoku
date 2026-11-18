"""Independent OOF-trained pixel posterior prunes weak evidence from source unions."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import inspect
import hashlib
from pathlib import Path
import time
import cv2
import joblib
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_style_calibration import style_features
from apply_joint_mask_refinement import refine_source_mask
from compiled_point_predict import CompiledPointPredictor
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point
import train_oof_style_pixel as oof

STATE = None


def initialize(root, base_model, cache, models, parents, score_cache):
    global STATE
    joint.initialize(root, base_model, cache)
    oof.initialize(root)
    STATE = dict(predictors=[CompiledPointPredictor(joblib.load(p)) for p in models],
                 modelSHA256=[sha(p) for p in models], parents=parents, scoreCache=Path(score_cache),
                 featureSHA256=hashlib.sha256(inspect.getsource(oof).encode()).hexdigest())


def partition(payload):
    rows, ordinal = payload
    count = len(STATE['predictors'])
    hist = {s: np.zeros((count, 3, 2, 17, joint.BINS), np.int64) for s in ['train', 'dev', 'test']}
    baseline = {s: np.zeros((3, 3), np.int64) for s in hist}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        styles = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
        masks = [refine_source_mask(base, distance, group, codes, parent, styles, row['fontPixels'], rgb, (p, q)) > 0
                 for parent in STATE['parents']]
        masks.append(masks[0] | masks[1])
        strength = np.minimum(64, np.ceil(np.maximum(p, q) * 64 - 1e-6)).astype(np.int32)
        positions = np.flatnonzero((masks[2] & (strength <= 16)).ravel())
        features = oof.inference_features(row)
        if features.dtype != np.float32 or features.shape[1] != 78:
            raise ValueError('OOF style feature contract changed')
        source_codes = []
        for predictor in STATE['predictors']:
            probability = predictor.probabilities(features, positions)
            odds = np.log(np.maximum(probability, 1e-12)) - np.log(np.maximum(1 - probability, 1e-12))
            source_codes.append(np.clip(np.floor((odds + 24) * joint.BINS / 48), 0, joint.BINS - 1).astype(np.uint16))
        np.savez_compressed(STATE['scoreCache'] / (row['id'] + '.npz'), positions=positions.astype(np.uint32),
            codes=np.stack(source_codes), rgbSHA256=sha(row['rgb']), modelSHA256=np.array(STATE['modelSHA256']),
            featureSHA256=STATE['featureSHA256'])
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        labels = gt.ravel()[positions]
        strengths = strength.ravel()[positions]
        s = row['split']
        for variant, mask in enumerate(masks):
            baseline[s][variant] += [np.count_nonzero(mask & gt), np.count_nonzero(mask & ~gt), np.count_nonzero(~mask & gt)]
            included = mask.ravel()[positions]
            for model, score in enumerate(source_codes):
                encoded = strengths * joint.BINS + score.astype(np.int32)
                for label, member in enumerate([included & labels, included & ~labels]):
                    hist[s][model, variant, label] += np.bincount(encoded[member], minlength=17 * joint.BINS).reshape(17, joint.BINS)
        if (i + 1) % 100 == 0:
            print(f'OOF pixel pruning shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return baseline, hist


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'base-model', 'cache', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--models', type=Path, nargs='+', required=True)
    parser.add_argument('--reports', type=Path, nargs=2, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    score_cache = args.out / 'source-scores'
    score_cache.mkdir(exist_ok=True)
    parents = [read(path)['allRecall99999'] for path in args.reports]
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=8, initializer=initialize,
            initargs=(args.root.resolve(), args.base_model.resolve(), args.cache.resolve(),
                      [p.resolve() for p in args.models], parents, score_cache.resolve())) as pool:
        parts = list(pool.map(partition, [(rows[i::8], i) for i in range(8)]))
    baseline = {s: sum(p[0][s] for p in parts) for s in ['train', 'dev', 'test']}
    hist = {s: sum(p[1][s] for p in parts) for s in baseline}
    cumulative = {s: np.pad(h.cumsum(axis=3).cumsum(axis=4),
        ((0, 0), (0, 0), (0, 0), (0, 0), (1, 0))) for s, h in hist.items()}
    best = {k: None for k in ['allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    variant_configs = parents + [dict(ensembleMembers=parents, requiredVotes=1)]
    for model, path in enumerate(args.models):
        for variant, config in enumerate(variant_configs):
            for cap in [0, 1, 2, 4, 8, 12, 16]:
                totals = {}
                for s, h in cumulative.items():
                    removed = h[model, variant, :, cap]
                    totals[s] = baseline[s][variant, :, None] + np.stack([-removed[0], -removed[1], removed[0]])
                all_counts = sum(totals.values())
                for key in best:
                    c = all_counts
                    recall, iou = c[0] / (c[0] + c[2]), c[0] / c.sum(axis=0)
                    valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
                    if key == 'eachSplitRecall99999':
                        for a in totals.values():
                            valid &= a[0] / (a[0] + a[2]) >= .99999
                    eligible = np.flatnonzero(valid)
                    if not len(eligible):
                        continue
                    objective = recall if key == 'allIoU70' else iou
                    threshold = int(eligible[np.argmax(objective[eligible])])
                    rank = float(objective[threshold]), float(iou[threshold])
                    if rank <= ranks[key]:
                        continue
                    ranks[key] = rank
                    best[key] = dict(config, auxiliaryPixelGate=dict(modelPath=str(path.resolve()),
                        modelSHA256=sha(path), featureVariant='oof-primary-style78-v1', maximumSourceStrengthCode=cap,
                        thresholdCode=threshold, logitBinCount=joint.BINS, logitMinimum=-24, logitMaximum=24),
                        all=metrics(all_counts[:, threshold]), bySplit={s: metrics(a[:, threshold]) for s, a in totals.items()})
    np.savez_compressed(args.out / 'COUNTS.npz', **hist, **{s + '_base': c for s, c in baseline.items()})
    save(args.out / 'RESULT.json', dict(**best, GTAtInference=False, GTChanged=False, sourceOnly=True,
        modelSHA256=sha(args.base_model), pixelModels=[dict(path=str(p.resolve()), SHA256=sha(p)) for p in args.models],
        trainingScope='source-excluded OOF TRAIN only', templateCalibrationScope='observed-all',
        productionEnabled=False, testPreviouslyInspected=True, maskCount=len(rows), seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
