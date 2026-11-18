"""Train generalized color/seed context recovery, including intact weak strokes."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time

import cv2
import joblib
import numpy as np
from PIL import Image
from sklearn.ensemble import HistGradientBoostingClassifier

import train_point_recovery as point
from evaluate_gt import read, save, sha

INCLUDE_BASE_NEGATIVES = False


def initialize(root, include_base_negatives=False):
    global INCLUDE_BASE_NEGATIVES
    INCLUDE_BASE_NEGATIVES = include_base_negatives
    point.initialize(root)


def context_features(features, base, font):
    """Source-only spatial/color evidence; never accepts labels or GT paths."""
    h, w = base.shape
    planes = features.reshape(h, w, -1)
    font = max(1., float(font))
    p, q = planes[:, :, 0], planes[:, :, -1]
    extra, names = [], []
    for size in [3, 7, 15, max(3, min(65, int(round(font * .25)) | 1))]:
        for source, label in [(q, 'boundary'), (base.astype(np.float32), 'base')]:
            extra.extend([cv2.dilate(source, np.ones((size, size), np.uint8)),
                          cv2.boxFilter(source, -1, (size, size), borderType=cv2.BORDER_REPLICATE)])
            suffix = str(size) if len(names) < 24 else 'FontQuarter'
            names.extend([label + 'Max' + suffix, label + 'Mean' + suffix])
    for threshold in [.1, .5]:
        distance = cv2.distanceTransform((q < threshold).astype(np.uint8), cv2.DIST_L2, 5)
        extra.append(np.minimum(distance / font, 1.))
        names.append('boundaryRelativeDistance' + str(threshold))
    seed = (p >= .75) & (q >= .5)
    if not seed.any():
        seed = (p >= .25) | (q >= .25)
    rgb = planes[:, :, 2:5]
    if seed.any():
        distance, labels = cv2.distanceTransformWithLabels((~seed).astype(np.uint8), cv2.DIST_L2,
                                                        5, labelType=cv2.DIST_LABEL_PIXEL)
        colors = np.vstack([np.zeros((1, 3), np.float32), rgb[seed]])
        if int(labels.max()) >= len(colors):
            raise ValueError('Unexpected nearest-source seed labels')
        delta = np.abs(rgb - colors[labels])
        relative = np.minimum(distance / font, 1.)
    else:
        delta = np.ones_like(rgb)
        relative = np.ones(base.shape, np.float32)
    extra.extend([relative, delta.max(axis=2), delta.mean(axis=2)])
    names.extend(['nearestConsensusDistanceRelativeFont', 'nearestConsensusRGBMaxDifference',
                  'nearestConsensusRGBMeanDifference'])
    outside = cv2.distanceTransform((~base).astype(np.uint8), cv2.DIST_L2, 5)
    extra.append(np.minimum(outside / font, 1.))
    names.append('baseDistanceRelativeFont')
    return np.concatenate([features, np.stack(extra, axis=2).reshape(-1, len(extra))], axis=1), names


def features_and_base(row):
    features, base, names = point.features_and_base(row)
    features, extra_names = context_features(features, base, row['fontPixels'])
    # Font-relative neighborhoods have stable names independent of per-crop sizes.
    extra_names[12:16] = ['boundaryMaxFontQuarter', 'boundaryMeanFontQuarter',
                          'baseMaxFontQuarter', 'baseMeanFontQuarter']
    return features, base, names + extra_names


def sample(payload):
    row, ordinal = payload
    features, base, names = features_and_base(row)
    if row['split'] != 'train' or sha(row['target']) != row['targetSHA256']:
        raise ValueError('TRAIN/GT contract changed')
    gt = (np.asarray(Image.open(row['target'])) > 0).ravel()
    outside = (~base).ravel()
    residual = np.flatnonzero(gt & outside)
    rng = np.random.default_rng(20261110 + ordinal)
    choices = [residual]
    weak = (features[:, 0] < .25) | (features[:, 60] < .25)
    # Include weak true strokes already rescued by the original completion, rather
    # than learning only its unusually rare training failures.
    for selection, count in [(gt & ~outside & weak, 256), (gt & ~outside, 64),
                              (~gt & outside & (features[:, -1] < .3), 1024),
                              (~gt & outside, 256)]:
        candidates = np.flatnonzero(selection)
        if len(candidates):
            choices.append(rng.choice(candidates, min(count, len(candidates)), replace=False))
    if INCLUDE_BASE_NEGATIVES:
        negatives = np.flatnonzero(~gt & ~outside)
        if len(negatives):
            choices.append(rng.choice(negatives, min(512, len(negatives)), replace=False))
    positions = np.unique(np.concatenate(choices))
    y = gt[positions]
    weights = np.where(y, np.where(outside[positions], 50., 8.), 1.)
    return features[positions], y, weights, names, len(residual)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--include-base-negatives', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rows = [r for r in read(args.root / 'boundary-lean/evaluation-manifest.json')['items'] if r['split'] == 'train']
    started = time.monotonic()
    parts, targets, weights = [], [], []
    residuals = 0
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize,
                             initargs=(args.root.resolve(), args.include_base_negatives)) as pool:
        for i, (x, y, weight, names, residual) in enumerate(pool.map(sample, [(r, i) for i, r in enumerate(rows)], chunksize=4)):
            parts.append(x)
            targets.append(y)
            weights.append(weight)
            residuals += residual
            if (i + 1) % 500 == 0:
                print(f'Context TRAIN {i + 1}/{len(rows)}', flush=True)
    x, y, weight = np.concatenate(parts), np.concatenate(targets), np.concatenate(weights)
    del parts, targets, weights
    save(args.out / 'TRAINING-PROTOCOL.json', dict(trainOnly=True, featureNames=names,
         featureCount=x.shape[1], samples=len(y), residualPixels=residuals,
         GTAtInference=False, sourceOnly=True, newCNN=False, caseIdentityFeatures=False,
         includeBaseNegatives=args.include_base_negatives,
         manifestSHA256=sha(args.root / 'boundary-lean/evaluation-manifest.json')))
    model = HistGradientBoostingClassifier(max_iter=192, max_leaf_nodes=31, min_samples_leaf=128,
        l2_regularization=20, learning_rate=.1, max_bins=128, early_stopping=False, random_state=20261110)
    print(f'Fitting context model {x.shape}', flush=True)
    model.fit(x, y, sample_weight=weight)
    joblib.dump(model, args.out / 'model.joblib', compress=3)
    save(args.out / 'TRAINING-RESULT.json', dict(seconds=time.monotonic() - started,
         trainOnly=True, modelSHA256=sha(args.out / 'model.joblib'), evaluationPending=True))
    print('Context recovery trained', flush=True)


if __name__ == '__main__':
    main()
