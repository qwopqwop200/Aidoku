#!/usr/bin/env python3
"""Source-bound segmentation measurements; labels never enter native replay inputs."""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import time

import cv2
import numpy as np
from PIL import Image

cv2.setNumThreads(1)
ROOT = Path(__file__).resolve().parents[3]
DEFAULT_GT = ROOT / 'labels/segmentation-merged830-20261106-r64-aggressive'
DEFAULT_RF = ROOT / 'premerge-recall100-20261105/generalization-audit/signals-only/rf-masks-v1'
DEFAULT_OUT = ROOT / 'segmentation-accuracy-20261106'


def read(path):
    return json.loads(Path(path).read_text())


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    temporary.replace(path)


def grouped_splits(items, pixel_identities=None):
    """Union duplicate source/crop identities before assigning any split."""
    parent = {r['sourceImageSHA256']: r['sourceImageSHA256'] for r in items}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    identities = {}
    for image, identity in (pixel_identities or {}).items():
        if image not in parent:
            continue
        if identity in identities:
            a, b = sorted([find(image), find(identities[identity])])
            parent[b] = a
        identities[identity] = image
    crops = {}
    for r in items:
        # Same source pixels + same localization, irrespective of GT mask edits.
        key = (r['cropSHA256'], json.dumps(r['individualPolygonsCrop'], sort_keys=True))
        image = r['sourceImageSHA256']
        if key in crops:
            a, b = sorted([find(image), find(crops[key])])
            parent[b] = a
        crops[key] = image
    partitions = {}
    for image in parent:
        group = find(image)
        bucket = int(hashlib.sha256(('segmentation-source-split-v1:' + group).encode()).hexdigest()[:8], 16) % 100
        partitions[image] = (group, 'train' if bucket < 60 else 'dev' if bucket < 80 else 'test')
    return partitions


def crop_rf(record, row):
    x0, y0, x1, y1 = row['cropBounds']
    width, height = row['pageSize']
    side = int(record['side'])
    gx = np.clip(((np.arange(x0, x1) + .5) * side / width).astype(int), 0, side - 1)
    gy = np.clip(((np.arange(y0, y1) + .5) * side / height).astype(int), 0, side - 1)
    support = np.zeros((y1 - y0, x1 - x0, 4), np.uint8)
    for primitive in record['primitives']:
        semantic = int(primitive['semanticClass'])  # native text0/SFX1/balloon2/frame3
        if not 0 <= semantic < 4:
            raise ValueError('Unexpected RF native class')
        grid = np.zeros((side, side), np.uint8)
        for run in primitive['mask']['runs']:
            grid[run['y'], run['x0']:run['x1']] = 1
        region = grid[gy[:, None], gx[None, :]]
        confidence = round(255 * float(primitive['confidence']))
        support[:, :, semantic] = np.maximum(support[:, :, semantic], region * confidence)
    return support


def prepare(args):
    gt = read(args.gt / 'segmentation-gt.json')
    items = gt['items']
    rf_index = {r['sourceSHA256']: r for r in read(args.rf / 'page-index.json')}
    splits = grouped_splits(items)
    cache = args.out / 'inputs'
    cache.mkdir(parents=True, exist_ok=True)
    (args.out / 'baseline').mkdir(exist_ok=True)
    rf_records = {}
    rows, native = [], []
    for ordinal, item in enumerate(items):
        r = dict(item)
        id = r['itemID']
        crop = args.gt / r['crop']
        target = args.gt / r['mask']
        assert sha(crop) == r['cropSHA256'] and sha(target) == r['maskSHA256'], id
        rgb = np.asarray(Image.open(crop).convert('RGB'))
        image_hash = r['sourceImageSHA256']
        entry = rf_index[image_hash]
        if image_hash not in rf_records:
            with gzip.open(entry['record'], 'rt') as f:
                record = json.load(f)
            assert record['sourceSHA256'] == image_hash
            assert [record['sourceWidth'], record['sourceHeight']] == r['pageSize']
            rf_records[image_hash] = record
        record = rf_records[image_hash]
        rgb_path = cache / f'{id}.rgb'
        rgb.tofile(rgb_path)
        rf_path = cache / f'{id}-rf.npz'
        np.savez_compressed(rf_path, support=crop_rf(record, r))
        polygons = r['individualPolygonsCrop'] or [r['mergedPolygonCrop']]
        scale = float(np.median([max(1, min(np.ptp(np.array(p), axis=0))) for p in polygons]))
        group, split = splits[image_hash]
        rows.append(dict(id=id, page=r['page'], sourceSHA256=image_hash, sourceGroup=group,
                         split=split, crop=str(crop), cropSHA256=r['cropSHA256'],
                         target=str(target), targetSHA256=r['maskSHA256'], status=r['status'],
                         rgb=str(rgb_path), rf=str(rf_path), rfRecordSHA256=sha(entry['record']),
                         width=rgb.shape[1], height=rgb.shape[0], polygons=polygons, fontPixels=scale))
        # Deliberately separate predictor inputs: no target path, target pixels, GT status or split.
        native.append(dict(id=id, rgb=str(rgb_path), width=rgb.shape[1], height=rgb.shape[0],
                           polygons=polygons, fontPixels=scale,
                           output=str(args.out / 'baseline' / f'{id}.u8')))
        if (ordinal + 1) % 500 == 0:
            print(f'Prepared {ordinal + 1}/{len(items)}', flush=True)
    assert len(rows) == len(items)
    save(args.out / 'evaluation-manifest.json', dict(
        GT=str(args.gt), GTSHA256=sha(args.gt / 'segmentation-gt.json'), items=rows,
        scope='fixed-localization segmentation, not end-to-end detection/recognition',
        rfSemantics='cached native162 positive grid, nearest-cell source mapping; NOT retained full logits/bilinear',
        splitPolicy='source SHA groups unioned by exact crop+localization duplicates;60/20/20 hash buckets',
        splitCounts=dict(Counter(r['split'] for r in rows)),
        ambiguousGTIncluded=True, visualContextMaxEachSide=.15))
    for worker in range(args.jobs):
        save(args.out / f'native-input-{worker:02d}.json', native[worker::args.jobs])
    save(args.out / 'PREPARED.json', dict(items=len(rows), RFMatched=len(rows),
         sourceGroups=len({r['sourceGroup'] for r in rows}), splits=dict(Counter(r['split'] for r in rows)),
         runtimeInputHasGTMask=False, sourceCacheBytes=sum(p.stat().st_size for p in cache.iterdir())))
    print(json.dumps(read(args.out / 'PREPARED.json')), flush=True)


def resplit(args):
    manifest = read(args.out / 'evaluation-manifest.json')
    source_rows = read(args.gt / 'segmentation-gt.json')['items']
    needed = {r['sourceImageSHA256'] for r in source_rows}
    identities = {}
    for record in read(args.rf / 'page-index.json'):
        if record['sourceSHA256'] not in needed:
            continue
        with gzip.open(record['record'], 'rt') as f:
            raw = json.load(f)
        assert raw['sourceSHA256'] == record['sourceSHA256']
        identities[raw['sourceSHA256']] = raw['imageIdentity']
    assert needed == set(identities)
    partitions = grouped_splits(source_rows, identities)
    for row in manifest['items']:
        row['sourceGroup'], row['split'] = partitions[row['sourceSHA256']]
    manifest['splitPolicy'] = 'source encoded SHA + native decoded RGB identity + exact crop/localization duplicate union;60/20/20 deterministic buckets-v2'
    manifest['splitCounts'] = dict(Counter(r['split'] for r in manifest['items']))
    save(args.out / 'evaluation-manifest.json', manifest)
    report = dict(sourceGroups=len({r['sourceGroup'] for r in manifest['items']}),
                  rawPixelIdentities=len(set(identities.values())), splits=manifest['splitCounts'],
                  allDuplicatePixelSourcesShareSplit=True)
    save(args.out / 'SPLIT-AUDIT.json', report)
    print(json.dumps(report))


def baseline(args):
    def run(worker):
        with (args.out / f'baseline-{worker:02d}.jsonl').open('wb') as log, (args.out / f'baseline-{worker:02d}.stderr').open('wb') as err:
            result = subprocess.run([str(args.out / 'native-baseline'), str(args.out / f'native-input-{worker:02d}.json')], stdout=log, stderr=err)
        if result.returncode:
            raise RuntimeError(f'Native baseline shard{worker} failed: {result.returncode}')
        return worker
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for worker in pool.map(run, range(args.jobs)):
            print(f'Native source-kernel shard {worker} done', flush=True)
    save(args.out / 'BASELINE-RUN.json', dict(seconds=time.monotonic() - start,
        jobs=args.jobs, executableSHA256=sha(args.out / 'native-baseline'),
        factorySHA256=sha(ROOT / 'Aidoku/Aidoku/Core/Translation/NativeEngine/Ensemble/NativeEnsembleRemovalSourceFactory.swift'),
        scope='actual production source-base/chromatic kernels; conditional on frozen geometry; no DB/final RF protection/AOT',
        fullProductionPipeline=False))


def score(args):
    manifest = read(args.out / 'evaluation-manifest.json')
    records = []
    for r in manifest['items']:
        if args.split != 'all' and r['split'] != args.split:
            continue
        p = args.predictions / f'{r["id"]}.u8'
        prediction = np.fromfile(p, np.uint8).reshape(r['height'], r['width']) > 0
        target = np.asarray(Image.open(r['target'])) > 0
        assert sha(r['target']) == r['targetSHA256']
        tp = int(np.count_nonzero(prediction & target))
        fp = int(np.count_nonzero(prediction & ~target))
        fn = int(np.count_nonzero(~prediction & target))
        records.append(dict(id=r['id'], split=r['split'], status=r['status'], TP=tp, FP=fp, FN=fn,
                            IoU=tp / max(1, tp + fp + fn), precision=tp / max(1, tp + fp), recall=tp / max(1, tp + fn)))
    def aggregate(rows):
        tp, fp, fn = (sum(r[k] for r in rows) for k in ['TP', 'FP', 'FN'])
        return dict(instances=len(rows), macroIoU=float(np.mean([r['IoU'] for r in rows])) if rows else None,
                    macroRecall=float(np.mean([r['recall'] for r in rows])) if rows else None,
                    minimumInstanceRecall=min((r['recall'] for r in rows),default=None),
                    instancesBelow99Recall=sum(r['recall']<.99 for r in rows),
                    instancesBelow999Recall=sum(r['recall']<.999 for r in rows),
                    microIoU=tp / max(1, tp + fp + fn), precision=tp / max(1, tp + fp),
                    recall=tp / max(1, tp + fn), TP=tp, FP=fp, FN=fn)
    report = dict(predictions=str(args.predictions), evaluationSplit=args.split, all=aggregate(records),
                  bySplit={s: aggregate([r for r in records if r['split'] == s]) for s in ['train', 'dev', 'test']},
                  byGTStatus={s: aggregate([r for r in records if r['status'] == s]) for s in ['complete', 'ambiguous']},
                  backgroundTrueNegativesNotUsedAsAccuracy=True,
                  fullProductionPipeline=False, instances=records)
    save(args.out / f'{args.predictions.name}-scores.json', report)
    print(json.dumps({k:v for k,v in report.items() if k != 'instances'}, indent=2))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['prepare', 'resplit', 'baseline', 'score'])
    p.add_argument('--gt', type=Path, default=DEFAULT_GT)
    p.add_argument('--rf', type=Path, default=DEFAULT_RF)
    p.add_argument('--out', type=Path, default=DEFAULT_OUT)
    p.add_argument('--jobs', type=int, default=8)
    p.add_argument('--predictions', type=Path)
    p.add_argument('--split', choices=['all', 'train', 'dev', 'test'], default='all')
    args = p.parse_args()
    args.gt, args.rf, args.out = args.gt.resolve(), args.rf.resolve(), args.out.resolve()
    args.predictions = args.predictions or args.out / 'baseline'
    {'prepare': prepare, 'resplit': resplit, 'baseline': baseline, 'score': score}[args.command](args)


if __name__ == '__main__':
    main()
