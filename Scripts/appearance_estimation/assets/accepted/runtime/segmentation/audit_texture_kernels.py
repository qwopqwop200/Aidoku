"""Calibrate two dilation radii from source background texture, not box identities."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import cv2
import numpy as np
from audit_kernel_free_completion import component_candidates, metrics
from evaluate_gt import read, save

MASKS = None
NAMES = ['ringLuminanceStd', 'ringLuminanceRange90', 'ringChromaMean',
         'ringRGBStd', 'ringGradientMean', 'ringGradientFraction', 'ringNonwhiteFraction']


def initialize(masks):
    global MASKS
    MASKS = Path(masks)
    cv2.setNumThreads(1)


def source_features(row):
    rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3).astype(np.float32) / 255
    mask = np.fromfile(MASKS / (row['id'] + '.u8'), np.uint8).reshape(rgb.shape[:2])
    base = component_candidates(mask)['fillHoles'] > 0
    distance = cv2.distanceTransform((~base).astype(np.uint8), cv2.DIST_C, 3)
    ring = (distance > 0) & (distance <= max(3, min(12, row['fontPixels'] * .1)))
    if not ring.any():
        return np.zeros(len(NAMES), np.float64)
    luma = rgb[:, :, 0] * .2126 + rgb[:, :, 1] * .7152 + rgb[:, :, 2] * .0722
    gradient = cv2.dilate(luma, np.ones((3, 3), np.uint8)) - cv2.erode(luma, np.ones((3, 3), np.uint8))
    ring_rgb, ring_luma = rgb[ring], luma[ring]
    return np.array([ring_luma.std(), np.quantile(ring_luma, .95) - np.quantile(ring_luma, .05),
        (ring_rgb.max(axis=1) - ring_rgb.min(axis=1)).mean(), ring_rgb.std(axis=0).max(),
        gradient[ring].mean(), (gradient[ring] > .1).mean(), (ring_luma < .95).mean()])


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'counts', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    best = read(args.root / 'BEST-RESULT.json')
    masks = (args.root / best['modelPackage']).parent / 'native-masks'
    with ProcessPoolExecutor(max_workers=4, initializer=initialize, initargs=(masks.resolve(),)) as pool:
        features = np.stack(list(pool.map(source_features, rows, chunksize=8)))
    hist = np.load(args.counts)['hist'][:, 0]
    prefix = hist.cumsum(axis=2)
    positives = hist[:, 0].sum(axis=1)
    split = np.array([r['split'] for r in rows])
    index = np.arange(len(rows))
    selected, exploratory = None, None
    for feature, name in enumerate(NAMES):
        thresholds = np.unique(np.quantile(features[split == 'dev', feature], np.linspace(0, 1, 41)))
        for threshold in thresholds:
            for reverse in [False, True]:
                large = (features[:, feature] >= threshold) ^ reverse
                for small in [0, 1, 2, 3]:
                    for big in [3, 4, 5, 6, 7, 10, 12]:
                        if big < small:
                            continue
                        radii = np.where(large, big, small)
                        tp, fp = prefix[index, :, radii].T
                        values = np.stack([tp, fp, positives - tp], axis=1)
                        all_counts = values.sum(axis=0)
                        dev = values[split == 'dev'].sum(axis=0)
                        def record():
                            return dict(feature=name, threshold=float(threshold), reverse=reverse,
                                smallRadiusPixels=small, largeRadiusPixels=big, all=metrics(all_counts),
                                bySplit={s: metrics(values[split == s].sum(axis=0)) for s in ['train', 'dev', 'test']})
                        if dev[2] <= (dev[0] + dev[2]) * .00001:
                            if selected is None or dev[0] / dev.sum() > selected['bySplit']['dev']['microIoU']:
                                selected = record()
                        if all_counts[2] <= (all_counts[0] + all_counts[2]) * .00001:
                            if exploratory is None or all_counts[0] / all_counts.sum() > exploratory['all']['microIoU']:
                                exploratory = record()
    result = dict(devRecall99999=selected, allRecall99999=exploratory, sourceOnly=True,
                  GTAtInference=False, GTChanged=False, productionEnabled=False, testPreviouslyInspected=True)
    save(args.out / 'RESULT.json', result)
    np.savez_compressed(args.out / 'FEATURES.npz', features=features)
    print(result, flush=True)


if __name__ == '__main__':
    main()
