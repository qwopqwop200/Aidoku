#!/usr/bin/env python3
"""Global source-pixel/RF prior calibration, with source-group-held-out evaluation.
No prediction function reads a GT mask, page ID, language or stored author recipe.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
import json
import math
import os
from pathlib import Path
import time
import tempfile

import cv2
import numpy as np
from PIL import Image

from evaluate_gt import DEFAULT_OUT, read, save, sha
cv2.setNumThreads(1)


def ownership(row):
    w, h = row['width'], row['height']
    out = np.zeros((h, w), np.uint8)
    # Same inclusive integer-lattice scan convention as NativeCurrentMaskCaller.raster.
    for polygon in row['polygons']:
        p = np.trunc(polygon).astype(int)
        for y in range(max(0, int(p[:, 1].min())), min(h - 1, int(p[:, 1].max())) + 1):
            crossings = []
            for i in range(len(p)):
                ax, ay = p[i]; bx, by = p[(i + 1) % len(p)]
                if ay == by:
                    if y == ay:
                        out[y, max(0, min(ax, bx)):min(w - 1, max(ax, bx)) + 1] = 1
                elif min(ay, by) <= y <= max(ay, by):
                    crossings.append(ax + (y - ay) * (bx - ax) / (by - ay))
            if crossings:
                lo, hi = max(0, math.floor(min(crossings) + .5)), min(w - 1, math.ceil(max(crossings) - .5))
                if lo <= hi:
                    out[y, lo:hi + 1] = 1
    return out


def feature_planes(row, baseline_folder, full_rf=False):
    """Source-only input contract shared with the future native deployment adapter."""
    h, w = row['height'], row['width']
    rgb = np.fromfile(row['rgb'], np.uint8).reshape(h, w, 3).astype(np.float32)
    base = (np.fromfile(baseline_folder / f'{row["id"]}.u8', np.uint8).reshape(h, w) > 0).astype(np.float32)
    with np.load(row['rf']) as data:
        rf = data['support'].astype(np.float32) / 255
    owned = ownership(row).astype(np.float32)
    font = max(1, row['fontPixels'])
    lum = rgb[:, :, 0] * .2126 + rgb[:, :, 1] * .7152 + rgb[:, :, 2] * .0722
    planes = [rgb[:, :, c] / 255 for c in range(3)]
    names = ['red', 'green', 'blue']
    planes += [lum / 255, (rgb.max(2) - rgb.min(2)) / 255, base, owned]
    names += ['luminance', 'chroma', 'nativeBase', 'ownedSeed']
    for label, size in zip(['3', '9', '21', 'fontQuarter'],
                           [3, 9, 21, max(3, min(65, int(round(font * .25)) | 1))]):
        mean = cv2.boxFilter(rgb, -1, (size, size), borderType=cv2.BORDER_REPLICATE)
        for c in range(3):
            planes.append((rgb[:, :, c] - mean[:, :, c]) / 255)
            names.append(f'colorContrast{["Red", "Green", "Blue"][c]}{label}')
        m = cv2.boxFilter(lum, -1, (size, size), borderType=cv2.BORDER_REPLICATE)
        variance = np.maximum(0, cv2.boxFilter(lum * lum, -1, (size, size), borderType=cv2.BORDER_REPLICATE) - m * m)
        planes += [np.sqrt(variance) / 128,
                   cv2.boxFilter(base, -1, (size, size), borderType=cv2.BORDER_REPLICATE)]
        names += [f'localStd{label}', f'baseDensity{label}']
    to_base = cv2.distanceTransform((base == 0).astype(np.uint8), cv2.DIST_L1, 3)
    from_base = cv2.distanceTransform(base.astype(np.uint8), cv2.DIST_L1, 3)
    to_owned = cv2.distanceTransform((owned == 0).astype(np.uint8), cv2.DIST_L1, 3)
    planes += [np.minimum(to_base, 32) / 32, np.minimum(from_base, 32) / 32,
               np.minimum(to_owned / font, 1)]
    names += ['outsideNativeDistance', 'insideNativeDistance', 'outsideOwnerRelativeDistance']
    rim = (cv2.dilate(owned, np.ones((5, 5), np.uint8)) > 0) & (owned == 0)
    if not rim.any():
        rim = np.ones((h, w), bool)
    bg = np.median(rgb[rim], axis=0)
    planes.append(np.max(np.abs(rgb - bg), axis=2) / 255)
    names.append('sourceBackgroundColorDistance')
    for c, name in enumerate(['rfText', 'rfSFX', 'rfBalloon', 'rfFrame']):
        planes.append(rf[:, :, c]); names.append(name)
    if full_rf:
        from prepare_full_rf import FEATURE_NAMES, load_case_features
        extra = load_case_features(row, baseline_folder.parent)
        if extra.shape != (h, w, len(FEATURE_NAMES)):
            raise ValueError('RF evidence/localization shape mismatch')
        planes.extend(extra[:, :, c] for c in range(extra.shape[2]))
        names.extend(FEATURE_NAMES)
    matrix = np.stack(planes, axis=2).reshape(-1, len(planes)).astype(np.float32)
    assert np.isfinite(matrix).all()
    return matrix, names


def sample_training_case(payload):
    r, output, full_rf, samples, boundary_samples, ordinal = payload
    target=np.asarray(Image.open(r['target']))>0
    # Targets are used only in the source-group training partition. Boundary
    # sampling teaches a single global forest anti-alias and halo distinctions;
    # neither the target distance nor identity is an inference feature.
    rng=np.random.default_rng(20261106+ordinal)
    selected=[]
    if boundary_samples:
        edge=cv2.morphologyEx(target.astype(np.uint8),cv2.MORPH_GRADIENT,np.ones((7,7),np.uint8))>0
    for positive in [False,True]:
        positions=np.flatnonzero(target.ravel()==positive)
        if len(positions):
            selected.extend(rng.choice(positions,min(samples,len(positions)),replace=False))
        if boundary_samples:
            positions=np.flatnonzero((edge&(target==positive)).ravel())
            if len(positions):
                selected.extend(rng.choice(positions,min(boundary_samples,len(positions)),replace=False))
    selected=np.unique(selected).astype(np.int64)
    features,names=feature_planes(r,Path(output)/'baseline',full_rf)
    return features[selected],target.ravel()[selected].astype(np.int32),names


def fit_forest(x,y,trees,depth,minimum_samples,seed):
    cv2.setRNGSeed(seed)
    model=cv2.ml.RTrees_create()
    model.setMaxDepth(depth)
    model.setMinSampleCount(minimum_samples)
    model.setActiveVarCount(max(4,int(np.sqrt(x.shape[1]))))
    model.setCalculateVarImportance(True)
    model.setTermCriteria((cv2.TERM_CRITERIA_MAX_ITER,trees,0))
    model.train(x,cv2.ml.ROW_SAMPLE,y)
    return model


def fit_shard(payload):
    root,ordinal,trees,depth,minimum_samples=payload
    root=Path(root)
    x=np.load(root/'features.npy',mmap_mode='r');y=np.load(root/'labels.npy',mmap_mode='r')
    model=fit_forest(x,y,trees,depth,minimum_samples,20261106+ordinal)
    output=root/f'shard-{ordinal}.json';model.save(str(output))
    print(f'Forest shard {ordinal} done ({trees} trees)',flush=True)
    return str(output)


def merge_forests(paths,output,allow_mixed_training=False):
    documents=[read(p)['opencv_ml_rtrees'] for p in paths]
    first=documents[0]
    for doc in documents[1:]:
        ignored={'trees','ntrees','oob_error','var_importance'}
        if allow_mixed_training:ignored.add('training_params')
        for key in first.keys()-ignored:
            if first[key]!=doc[key]:raise ValueError(f'Incompatible forest shard: {key}')
    weights=np.array([d['ntrees'] for d in documents],np.float64);weights/=weights.sum()
    merged=dict(first,trees=[t for d in documents for t in d['trees']],ntrees=sum(d['ntrees'] for d in documents),
        oob_error=float(sum(w*d['oob_error'] for w,d in zip(weights,documents))),
        var_importance=np.average([d['var_importance'] for d in documents],axis=0,weights=weights).tolist())
    if allow_mixed_training:
        merged['training_params']=dict(first['training_params'],
            max_depth=max(d['training_params']['max_depth'] for d in documents),
            min_sample_count=min(d['training_params']['min_sample_count'] for d in documents))
    output.write_text(json.dumps({'opencv_ml_rtrees':merged},separators=(',',':')))
    return cv2.ml.RTrees_load(str(output))


def train(args):
    manifest = read(args.out / 'evaluation-manifest.json')
    rows = [r for r in manifest['items'] if r['split'] == 'train']
    samples, labels = [], []
    start = time.monotonic()
    payloads=[(r,str(args.out),args.full_rf,args.samples,args.boundary_samples,i) for i,r in enumerate(rows)]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for i,(f,y,names) in enumerate(pool.map(sample_training_case,payloads,chunksize=4)):
            samples.append(f);labels.append(y)
            if (i+1)%250==0:
                print(f'Feature sample extraction {i+1}/{len(rows)}',flush=True)
    x, y = np.concatenate(samples), np.concatenate(labels)
    output=args.out/f'{args.prefix}pixel-fusion-model.json'
    if args.forest_jobs==1:
        model=fit_forest(x,y,args.trees,args.depth,args.minimum_samples,20261106)
        model.save(str(output))
    else:
        # Shared read-only feature arrays, bounded workers and automatic scratch
        # deletion. Each shard is an independent bagged forest, not a new split.
        with tempfile.TemporaryDirectory(prefix='forest-fit-',dir=args.out) as scratch:
            root=Path(scratch);np.save(root/'features.npy',x);np.save(root/'labels.npy',y)
            jobs=min(args.forest_jobs,args.trees)
            payloads=[(str(root),i,len(range(i,args.trees,jobs)),args.depth,args.minimum_samples) for i in range(jobs)]
            with ProcessPoolExecutor(max_workers=jobs) as pool:
                paths=list(pool.map(fit_shard,payloads))
            model=merge_forests(paths,output)
    save(args.out / f'{args.prefix}PIXEL-MODEL-TRAINING.json', dict(
        sourceGroupedTrainingInstances=len(rows), sampledPixels=len(y), featureCount=x.shape[1],
        boundarySamplesPerClass=args.boundary_samples,minimumSamplesToSplit=args.minimum_samples,
        forestJobs=args.forest_jobs,OOBDiagnostic='weighted shard mean, not merged-forest OOB' if args.forest_jobs>1 else 'single forest',
        featureNames=names, trees=args.trees, maximumDepth=args.depth, seconds=time.monotonic() - start,
        classifier='OpenCV random forest; independent of RF-DETR source prior detector',
        sourceFeatureInputs=['source RGB', 'local contrast/texture', 'OCR localization seeds',
                             'actual native base mask', 'RF-DETR text/SFX/balloon/frame support'],
        runtimeReadsGT=False, caseOrPageIdentityFeatures=False, fullRFQueries=args.full_rf,
        trainingSourceGroups=sorted({r['sourceGroup'] for r in rows}),
        manifestSHA256=sha(args.out / 'evaluation-manifest.json'),
        variableImportance=model.getVarImportance().reshape(-1).tolist()))
    print(json.dumps(dict(instances=len(rows), pixels=len(y), features=len(names),
        fullRF=args.full_rf, seconds=time.monotonic() - start)), flush=True)


_MODEL = None


def predict_one(payload):
    global _MODEL
    row, output, full_rf, prefix = payload
    output = Path(output)
    if _MODEL is None:
        _MODEL = cv2.ml.RTrees_load(str(output / f'{prefix}pixel-fusion-model.json'))
    features, _ = feature_planes(row, output / 'baseline', full_rf)
    scores = np.empty(len(features), np.float32)
    for start in range(0, len(features), 65536):
        votes = _MODEL.getVotes(features[start:start + 65536], 0)
        positive = np.flatnonzero(votes[0] == 1).item()
        scores[start:start + len(votes) - 1] = votes[1:, positive] / np.maximum(1, votes[1:].sum(1))
    path = output / f'{prefix}dev-probabilities' / f'{row["id"]}.npz'
    temporary=path.with_suffix(f'.{os.getpid()}.tmp')
    with temporary.open('wb') as stream:
        np.savez_compressed(stream,probability=scores.reshape(row['height'],row['width']).astype(np.float16))
    temporary.replace(path)
    return row['id']


def predict_dev(args):
    rows = [r for r in read(args.out / 'evaluation-manifest.json')['items'] if r['split'] == 'dev']
    (args.out / f'{args.prefix}dev-probabilities').mkdir(exist_ok=True)
    start = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        # Strip evaluation target paths and status before dispatch to predictor.
        keys = ['id', 'width', 'height', 'rgb', 'rf', 'polygons', 'fontPixels']
        inputs = [({k:r[k] for k in keys}, str(args.out), args.full_rf, args.prefix) for r in rows]
        for i, _ in enumerate(pool.map(predict_one, inputs, chunksize=4)):
            if (i + 1) % 100 == 0:
                print(f'DEV prediction {i + 1}/{len(rows)}', flush=True)
    save(args.out / f'{args.prefix}DEV-PREDICTION-RUN.json', dict(instances=len(rows), seconds=time.monotonic() - start,
        modelSHA256=sha(args.out/f'{args.prefix}pixel-fusion-model.json'),
        manifestSHA256=sha(args.out/'evaluation-manifest.json'),
        holdoutTestOpened=False, GTReadByPredictor=False))


def tune(args):
    rows = [r for r in read(args.out / 'evaluation-manifest.json')['items'] if r['split'] == 'dev']
    trees = read(args.out / f'{args.prefix}PIXEL-MODEL-TRAINING.json')['trees']
    # Search every distinct forest decision, not an arbitrary .025 grid that
    # skips some vote counts. Midpoints are stable under float16 score caching.
    thresholds = np.array([0.] + [(vote - .5) / trees for vote in range(1, trees + 1)])
    counts = np.zeros((len(thresholds), 3), np.int64)
    ious = np.zeros(len(thresholds), np.float64)
    for r in rows:
        with np.load(args.out / f'{args.prefix}dev-probabilities' / f'{r["id"]}.npz') as data:
            p = data['probability'].astype(np.float32)
        gt = np.asarray(Image.open(r['target'])) > 0
        for i, threshold in enumerate(thresholds):
            pred = p >= threshold
            tp, fp, fn = (np.count_nonzero(m) for m in [pred & gt, pred & ~gt, ~pred & gt])
            counts[i] += [tp, fp, fn]
            ious[i] += tp / max(1, tp + fp + fn)
    baseline = read(args.out / 'baseline-scores.json')['bySplit']['dev']
    trials = [dict(threshold=float(t), macroIoU=ious[i] / len(rows),
                   microIoU=int(tp) / max(1, int(tp + fp + fn)), precision=int(tp) / max(1, int(tp + fp)),
                   recall=int(tp) / max(1, int(tp + fn)))
              for i, (t, (tp, fp, fn)) in enumerate(zip(thresholds, counts))]
    eligible = [r for r in trials if r['recall'] >= baseline['recall']]
    chosen = max(eligible, key=lambda r:r['macroIoU']) if eligible else None
    save(args.out / f'{args.prefix}DEV-THRESHOLD-SEARCH.json', dict(baseline=baseline, trials=trials,
         rule='maximize DEV macroIoU subject to preserving baseline DEV foreground recall', selected=chosen,
         holdoutTestUsedForSelection=False))
    print(json.dumps(dict(baseline=baseline, selected=chosen), indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['train', 'predict-dev', 'tune'])
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--samples', type=int, default=256)
    parser.add_argument('--trees', type=int, default=48)
    parser.add_argument('--depth', type=int, default=10)
    parser.add_argument('--boundary-samples',type=int,default=0)
    parser.add_argument('--minimum-samples',type=int,default=100)
    parser.add_argument('--forest-jobs',type=int,default=1)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--full-rf', action='store_true')
    args = parser.parse_args()
    if not 1<=args.jobs<=16 or not 1<=args.forest_jobs<=8 or not 1<=args.trees<=255 or args.samples<1 or args.boundary_samples<0 or args.minimum_samples<1:
        parser.error('Require jobs1...16, trees1...255, positive samples/minimum-samples and nonnegative boundary-samples')
    args.out = args.out.resolve()
    args.prefix = 'full-rf-' if args.full_rf else ''
    {'train': train, 'predict-dev': predict_dev, 'tune': tune}[args.command](args)


if __name__ == '__main__':
    main()
