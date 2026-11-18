"""OOF-primary pixel refinement with source-global style; no in-sample q teacher."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import time
import cv2
import joblib
import numpy as np
from PIL import Image
from sklearn.ensemble import HistGradientBoostingClassifier

from audit_style_calibration import style_features, NAMES
from boundary_refiner import source_features, validate_oof
from evaluate_gt import read, save, sha
from source_boundary_votes import SourceBoundaryVotes
from train_edge_boundary import edge_features

ROOT = None
VOTES = None


def initialize(root):
    global ROOT, VOTES
    ROOT = Path(root)
    VOTES = SourceBoundaryVotes(ROOT / 'boundary-lean', ROOT / 'deep-classifier-observations',
                                ROOT / 'edge-context60-native', ROOT / 'edge-context60-observations')
    cv2.setNumThreads(1)


def source_style(row, p, native):
    rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
    base = native > 0
    distance = cv2.distanceTransform((~base).astype(np.uint8), cv2.DIST_C, 3)
    case = read(ROOT / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
    return style_features(rgb, base, distance, p, p, row['fontPixels'], case)


def inference_features(row):
    inputs = {k: row[k] for k in ['id', 'rgb', 'rf', 'width', 'height', 'polygons', 'fontPixels']}
    matrix, names, p = source_features(inputs, ROOT / 'boundary-lean', ROOT / 'deep-classifier-observations', rich=True)
    rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
    native = matrix[:, 1].reshape(p.shape) > 0
    style = source_style(inputs, p, native).astype(np.float32)
    return np.column_stack([matrix, edge_features(rgb, row['fontPixels']),
                            np.broadcast_to(style, (len(matrix), len(style)))])


def training_style(payload):
    row, ordinal = payload
    with np.load(ROOT / 'oof-primary-matched/probabilities' / (row['id'] + '.npz')) as data:
        p = data['probability'].astype(np.float32)
    _, _, native = VOTES.load(row)
    style = source_style(row, p, native).astype(np.float32)
    if sha(row['target']) != row['targetSHA256'] or row['split'] != 'train':
        raise ValueError('TRAIN/GT contract mismatch')
    target = np.asarray(Image.open(row['target'])) > 0
    rng = np.random.default_rng(20261110 + ordinal)
    near = cv2.dilate(p, np.ones((9, 9), np.uint8)) > .1
    positions = []
    for mask, count in [(target, 128), (~target, 128), (target & (p < .75), 256), (~target & near, 256)]:
        indices = np.flatnonzero(mask.ravel())
        if len(indices):
            positions.extend(rng.choice(indices, min(count, len(indices)), replace=False))
    positions = np.unique(positions)
    return style, target.ravel()[positions].astype(np.int32), p.ravel()[positions]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    root = args.root
    manifest = read(root / 'boundary-lean/evaluation-manifest.json')
    oof = read(root / 'oof-primary-matched/OOF-COMPLETE.json')
    validate_oof(manifest, oof, read(root / 'oof-primary-matched/OOF-PROTOCOL.json'))
    samples = read(root / 'matched-rich-training-samples/SAMPLES.json')
    edge = read(root / 'edge-context60/full-rf-PIXEL-MODEL-TRAINING.json')
    if (samples['contract']['OOFReceiptSHA256'] != sha(root / 'oof-primary-matched/OOF-COMPLETE.json') or
            edge['featuresSHA256'] != sha(root / 'edge-context60/training-features.npy') or
            edge['manifestSHA256'] != sha(root / 'boundary-lean/evaluation-manifest.json')):
        raise ValueError('Frozen OOF samples changed')
    x = np.load(root / 'edge-context60/training-features.npy', mmap_mode='r')
    y = np.load(root / 'matched-rich-training-samples/labels.npy', mmap_mode='r')
    rows = [r for r in manifest['items'] if r['split'] == 'train']
    started = time.monotonic()
    extras = np.empty((len(y), len(NAMES)), np.float32)
    offset = 0
    with ProcessPoolExecutor(max_workers=4, initializer=initialize, initargs=(root.resolve(),)) as pool:
        for i, (style, labels, probabilities) in enumerate(pool.map(training_style, [(r, i) for i, r in enumerate(rows)], chunksize=4)):
            end = offset + len(labels)
            if not np.array_equal(y[offset:end], labels) or not np.array_equal(x[offset:end, 0], probabilities):
                raise ValueError('OOF sample alignment mismatch')
            extras[offset:end] = style
            offset = end
            if (i + 1) % 500 == 0:
                print(f'OOF style rows {i + 1}/{len(rows)}', flush=True)
    if offset != len(y):
        raise ValueError('OOF sample row count changed')
    augmented = np.column_stack([x, extras])
    del extras, x
    save(args.out / 'TRAINING-PROTOCOL.json', dict(trainOnly=True, sampledPixels=len(y), featureCount=augmented.shape[1],
        featureNames=edge['featureNames'] + ['globalStyle.' + n for n in NAMES],
        primaryTraining='source-group excluded OOF', inSampleBoundaryTeacherUsed=False,
        GTAtInference=False, caseIdentityFeatures=False, newCNN=False,
        OOFReceiptSHA256=sha(root / 'oof-primary-matched/OOF-COMPLETE.json')))
    fitted = []
    for foreground_weight in [1, 8]:
        model = HistGradientBoostingClassifier(max_iter=192, max_leaf_nodes=31, min_samples_leaf=256,
            l2_regularization=20, learning_rate=.1, max_bins=128, early_stopping=False, random_state=20261109)
        print(f'Fitting OOF style pixel weight={foreground_weight}', flush=True)
        model.fit(augmented, y, sample_weight=np.where(y > 0, float(foreground_weight), 1.))
        path = args.out / f'model-weight{foreground_weight}.joblib'
        joblib.dump(model, path, compress=3)
        fitted.append(dict(foregroundWeight=foreground_weight, model=path.name, SHA256=sha(path)))
    save(args.out / 'TRAINING-RESULT.json', dict(models=fitted, seconds=time.monotonic() - started,
        trainOnly=True, evaluationPending=True))
    print('OOF style pixel models trained', flush=True)


if __name__ == '__main__':
    main()
