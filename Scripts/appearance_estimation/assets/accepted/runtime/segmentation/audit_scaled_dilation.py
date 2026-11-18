"""Compare font-scaled square/disc/diamond kernels; calibrate on DEV only."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import cv2
import numpy as np
from PIL import Image
from audit_kernel_free_completion import component_candidates, metrics
from evaluate_gt import read, save, sha

MASKS = None
LIMIT = 65


def initialize(masks):
    global MASKS
    MASKS = Path(masks)
    cv2.setNumThreads(1)


def measure(row):
    mask = np.fromfile(MASKS / (row['id'] + '.u8'), np.uint8).reshape(row['height'], row['width'])
    base = component_candidates(mask)['fillHoles'] > 0
    distances = [cv2.distanceTransform((~base).astype(np.uint8), kind, size)
                 for kind, size in [(cv2.DIST_C, 3), (cv2.DIST_L2, cv2.DIST_MASK_PRECISE), (cv2.DIST_L1, 3)]]
    if sha(row['target']) != row['targetSHA256']:
        raise ValueError('GT changed')
    gt = np.asarray(Image.open(row['target'])) > 0
    hist = []
    for distance in distances:
        d = np.minimum(np.ceil(distance - 1e-6), LIMIT).astype(np.int32)
        hist.append(np.stack([np.bincount(d[gt], minlength=LIMIT + 1),
                              np.bincount(d[~gt], minlength=LIMIT + 1)]))
    return np.stack(hist)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    best = read(args.root / 'BEST-RESULT.json')
    masks = (args.root / best['modelPackage']).parent / 'native-masks'
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize, initargs=(masks.resolve(),)) as pool:
        hist = np.stack(list(pool.map(measure, rows, chunksize=8)))
    np.savez_compressed(args.out / 'COUNTS.npz', hist=hist)
    prefix = hist.cumsum(axis=3)
    font = np.array([r['fontPixels'] for r in rows])
    split = np.array([r['split'] for r in rows])
    positives = hist[:, 0, 0].sum(axis=1)
    index = np.arange(len(rows))
    selected = None
    exploratory = None
    for kind, name in enumerate(['square', 'disc', 'diamond']):
        for minimum in [0, 1, 2, 3]:
            for maximum in [4, 6, 8, 12, 16, 24, 32]:
                for scale in np.arange(0, .30001, .0025):
                    radii = np.clip(np.ceil(font * scale), minimum, maximum).astype(int)
                    tp, fp = prefix[index, kind, :, radii].T
                    values = np.stack([tp, fp, positives - tp], axis=1)
                    all_counts = values.sum(axis=0)
                    dev = values[split == 'dev'].sum(axis=0)
                    def record():
                        return dict(kernel=name, radiusFontScale=float(scale), minimumRadiusPixels=minimum,
                                    maximumRadiusPixels=maximum, rounding='ceil', all=metrics(all_counts),
                                    bySplit={s: metrics(values[split == s].sum(axis=0)) for s in ['train', 'dev', 'test']})
                    if dev[2] <= (dev[0] + dev[2]) * .00001:
                        iou = dev[0] / dev.sum()
                        if selected is None or iou > selected['bySplit']['dev']['microIoU']:
                            selected = record()
                    if all_counts[2] <= (all_counts[0] + all_counts[2]) * .00001:
                        iou = all_counts[0] / all_counts.sum()
                        if exploratory is None or iou > exploratory['all']['microIoU']:
                            exploratory = record()
    result = dict(devRecall99999=selected, allRecall99999=exploratory, GTAtInference=False,
                  sourceOnly=True, GTChanged=False, productionEnabled=False, testPreviouslyInspected=True)
    save(args.out / 'RESULT.json', result)
    print(result, flush=True)


if __name__ == '__main__':
    main()
