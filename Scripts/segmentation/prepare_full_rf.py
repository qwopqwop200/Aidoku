#!/usr/bin/env python3
"""Consume all native RF tensors, retain source-only evidence, delete raw spool.

The two-stage cache preserves full-query semantic/instance evidence at the
native grid. Sampling uses the production half-pixel bilinear convention.
No target-mask pixels are opened, and no class acceptance threshold is used.
"""
import argparse
from collections import defaultdict
from functools import lru_cache
import json
from pathlib import Path
import subprocess
import time

import cv2
import numpy as np

from evaluate_gt import DEFAULT_OUT, ROOT, read, save, sha

cv2.setNumThreads(1)
SIDE = 162
SCHEMA = 2
COMPACT_SCHEMA = 3
FEATURE_NAMES = [f'rfAllQueriesClass{c}{stat}' for c in range(5)
                 for stat in ['MaxMaskProbability', 'MeanMaskProbability', 'BoxConfidence']]
FEATURE_NAMES += [f'rfOwnerQueryClass{c}{stat}' for c in range(5)
                  for stat in ['MaskProbability', 'Affinity']]
FEATURE_NAMES += ['rfSemanticMargin', 'rfMaskUncertainty']


def sigmoid(values):
    return 1 / (1 + np.exp(-np.clip(values, -80, 80)))


def sample(grid, bounds, width, height):
    x0, y0, x1, y1 = bounds
    xs = np.clip((np.arange(x0, x1, dtype=np.float32) + .5) * SIDE / width - .5, 0, SIDE - 1)
    ys = np.clip((np.arange(y0, y1, dtype=np.float32) + .5) * SIDE / height - .5, 0, SIDE - 1)
    left, top = xs.astype(int), ys.astype(int)
    right, bottom = np.minimum(SIDE - 1, left + 1), np.minimum(SIDE - 1, top + 1)
    dx, dy = xs - left, ys - top
    upper = grid[top[:, None], left] * (1 - dx) + grid[top[:, None], right] * dx
    lower = grid[bottom[:, None], left] * (1 - dx) + grid[bottom[:, None], right] * dx
    return (upper * (1 - dy[:, None]) + lower * dy[:, None]).astype(np.float32)


def evidence_grids(boxes, logits, masks):
    classes, occupancy = sigmoid(logits), sigmoid(masks)
    grids = []
    axis = (np.arange(SIDE) + .5) / SIDE
    for c in range(5):
        weighted = occupancy * classes[:, c, None, None]
        maximum = weighted.max(0)
        mean = weighted.sum(0) / max(1e-9, classes[:, c].sum())
        box = np.zeros((SIDE, SIDE), np.float32)
        for q, (cx, cy, width, height) in enumerate(boxes):
            inside = ((axis[None, :] >= cx - width / 2) & (axis[None, :] <= cx + width / 2)
                      & (axis[:, None] >= cy - height / 2) & (axis[:, None] <= cy + height / 2))
            np.maximum(box, inside * classes[q, c], out=box)
        grids.extend([maximum, mean, box])
    return classes, occupancy, grids


@lru_cache(maxsize=2)
def native_grids(path):
    with np.load(path) as data:
        return {k:data[k] for k in data.files}


def load_case_features(row, out):
    destination = Path(out) / 'rf-full' / 'crops'
    legacy = destination / f'{row["id"]}.npz'
    if legacy.exists() and not (destination / f'{row["id"]}.json').exists():
        with np.load(legacy) as data:
            if 'schema' not in data or int(data['schema']) != SCHEMA:
                raise ValueError('Stale RF evidence schema')
            return data['features'].astype(np.float32)
    case = read(destination / f'{row["id"]}.json')
    if case['schema'] != COMPACT_SCHEMA:
        raise ValueError('Unexpected RF cache schema')
    source = native_grids(str((destination / case['nativeGrids']).resolve()))
    width, height = case['pageSize']; bounds = case['cropBounds']
    h, w = bounds[3] - bounds[1], bounds[2] - bounds[0]
    planes = [sample(g, bounds, width, height) for g in source['globalGrids'][:15]]
    queries = {int(q):i for i,q in enumerate(source['queryIDs'])}
    for q, score in zip(case['ownerQueries'], case['affinityScores']):
        planes.extend([sigmoid(sample(source['queryLogits'][queries[q]], bounds, width, height)),
                       np.full((h,w), score, np.float32)])
    planes.extend(sample(g,bounds,width,height) for g in source['globalGrids'][15:])
    return np.stack(planes,axis=2).astype(np.float16).astype(np.float32)


def process(record, rows, spool, destination, compact=False):
    source = record['sourceSHA256']
    paths = [spool / f'{source}-{name}.f32' for name in ['boxes', 'logits', 'instance_masks']]
    boxes, logits, masks = [np.fromfile(p, '<f4').reshape(shape)
                            for p, shape in zip(paths, [(300, 4), (300, 5), (300, SIDE, SIDE)])]
    if not all(np.isfinite(a).all() for a in (boxes, logits, masks)):
        raise ValueError('Nonfinite native RF output')
    classes, occupancy, global_grids = evidence_grids(boxes, logits, masks)
    w, h = record['width'], record['height']
    if record.get('selectedPrimitives') is not None:
        coarse = np.zeros((SIDE,SIDE,4),np.uint8)
        for primitive in record['selectedPrimitives']:
            q, c = primitive['queryID'], primitive['semanticClass']
            confidence = round(primitive['confidence'] * 255)
            np.maximum(coarse[:,:,c], (masks[q] > 0).astype(np.uint8) * confidence, out=coarse[:,:,c])
        inputs = destination.parent.parent / 'inputs'; inputs.mkdir(exist_ok=True)
        for row in rows:
            x0,y0,x1,y1 = row['cropBounds']
            gx = np.minimum(SIDE-1,((np.arange(x0,x1)+.5)*SIDE/w).astype(int))
            gy = np.minimum(SIDE-1,((np.arange(y0,y1)+.5)*SIDE/h).astype(int))
            np.savez_compressed(inputs/f'{row["id"]}-rf.npz',support=coarse[gy[:,None],gx])
    cases = []; selected_queries = set()
    ranked = np.sort(np.stack([global_grids[3 * c] for c in range(4)]), axis=0)
    extra_grids = [ranked[-1] - ranked[-2],4 * ranked[-1] * (1-ranked[-1])]
    for row in rows:
        if row['pageSize'] != [w, h]:
            raise ValueError('RF source dimensions disagree with localization')
        owner = np.zeros((SIDE, SIDE), np.uint8)
        x0, y0, _, _ = row['cropBounds']
        for polygon in row['polygons']:
            points = np.asarray(polygon, np.float32) + [x0, y0]
            points = np.rint(points * [SIDE / w, SIDE / h] - .5).astype(np.int32)
            cv2.fillPoly(owner, [points], 1)
        if not owner.any():
            raise ValueError('Empty RF owner localization')
        affinity = occupancy[:, owner > 0].mean(1)
        features = [sample(g, row['cropBounds'], w, h) for g in global_grids] if not compact else []
        queries = []
        affinity_scores = []
        for c in range(5):
            scores = classes[:, c] * affinity
            q = int(np.argmax(scores)); queries.append(q)
            affinity_scores.append(float(scores[q]))
            # Per-owner mask: interpolate raw logits BEFORE sigmoid, exactly
            # matching native source-coordinate decision at probability > .5.
            if not compact:
                features.extend([sigmoid(sample(masks[q], row['cropBounds'], w, h)),
                             np.full((row['cropBounds'][3] - y0, row['cropBounds'][2] - x0),
                                     scores[q], np.float32)])
        if compact:
            selected_queries.update(queries)
            cases.append(dict(schema=COMPACT_SCHEMA,id=row['id'],pageSize=[w,h],cropBounds=row['cropBounds'],
                nativeGrids=f'../native-grids/{source}.npz',ownerQueries=queries,affinityScores=affinity_scores,
                sourceSHA256=source,modelWeightsSHA256=record.get('modelWeightsSHA256','')))
            continue
        features.extend(sample(g, row['cropBounds'], w, h)
                        for g in [ranked[-1] - ranked[-2], 4 * ranked[-1] * (1 - ranked[-1])])
        features = np.stack(features, axis=2)
        path = destination / f'{row["id"]}.npz'
        temporary = path.with_suffix('.tmp.npz')
        np.savez_compressed(temporary, features=features.astype(np.float16), ownerQueries=queries, schema=SCHEMA)
        temporary.replace(path)
    if compact:
        native = destination.parent / 'native-grids'; native.mkdir(exist_ok=True)
        queries = sorted(selected_queries)
        np.savez_compressed(native/f'{source}.npz',globalGrids=np.stack(global_grids+extra_grids),
                            queryIDs=np.array(queries,np.int32),queryLogits=masks[queries])
        for case in cases:
            save(destination/f'{case["id"]}.json',case)
    # Raw float32 logits were consumed, never rounded before evidence formation.
    for p in paths:
        p.unlink()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT)
    parser.add_argument('--limit', type=int)
    parser.add_argument('--compact', action='store_true')
    parser.add_argument('--model', type=Path)
    parser.add_argument('--native', type=Path)
    args = parser.parse_args()
    out = args.out.resolve(); cache = out / 'rf-full'; spool = cache / 'spool'
    destination = cache / 'crops'
    spool.mkdir(exist_ok=True); destination.mkdir(exist_ok=True)
    manifest = read(out / 'evaluation-manifest.json')
    # Authoring metadata supplies fixed localization only, not target pixels.
    geometry = {r['itemID']: r for r in read(Path(manifest['GT']) / 'segmentation-gt.json')['items']}
    by_source = defaultdict(list)
    for r in manifest['items']:
        g = geometry[r['id']]
        by_source[r['sourceSHA256']].append(dict(id=r['id'], polygons=r['polygons'],
            cropBounds=g['cropBounds'], pageSize=g['pageSize']))
    def valid(item):
        if args.compact:
            path = destination / f'{item["id"]}.json'
            if not path.exists():
                return False
            case = read(path)
            return case.get('schema') == COMPACT_SCHEMA and (
                not manifest.get('RFModelSHA256') or case.get('modelWeightsSHA256') == manifest['RFModelSHA256'])
        path = destination / f'{item["id"]}.npz'
        if not path.exists():
            return False
        with np.load(path) as data:
            return 'schema' in data and int(data['schema']) == SCHEMA
    sources = [r for r in read(cache / 'sources.json')
               if any(not valid(g) for g in by_source[r['sourceSHA256']])]
    if args.limit:
        sources = sources[:args.limit]
    save(cache / 'pending.json', sources)
    model = args.model or ROOT / 'Aidoku/build/image-translation-host/Models.bundle/Contents/Resources/KoharuHighres648FP16.mlmodelc'
    binary = args.native or cache / 'export-native'
    start = time.monotonic(); completed = 0
    with (cache / 'native-stderr.log').open('a') as err:
        proc = subprocess.Popen([str(binary), str(cache / 'pending.json'), str(model), str(spool)],
                                stdout=subprocess.PIPE, stdin=subprocess.PIPE, stderr=err, text=True)
        try:
            for line in proc.stdout:
                record = json.loads(line); key = record['sourceSHA256']
                if manifest.get('RFModelSHA256') and record.get('modelWeightsSHA256') != manifest['RFModelSHA256']:
                    raise ValueError('RF checkpoint differs from the declared corpus')
                process(record, by_source[key], spool, destination, compact=args.compact)
                proc.stdin.write(key + '\n'); proc.stdin.flush()
                completed += 1
                if completed % 10 == 0 or completed == len(sources):
                    print(f'Full RF source evidence {completed}/{len(sources)}', flush=True)
                save(cache / 'STATUS.json', dict(completedThisRun=completed, requestedThisRun=len(sources),
                    seconds=time.monotonic() - start, featureNames=FEATURE_NAMES, GTMaskRead=False, schema=SCHEMA,
                    queries=300, rawSpoolMaxSources=1, allClassLogitsUsed=5,
                    maskSampling='owner: bilinear logits then sigmoid; all-query summaries: bilinear native-grid summaries',
                    derivedCacheDtype='native float32 grids; float16 source planes' if args.compact else 'float16',
                    storageSchema=COMPACT_SCHEMA if args.compact else SCHEMA,
                    model=str(model), binarySHA256=sha(binary)))
            if proc.wait() != 0:
                raise RuntimeError(f'Native RF evidence export failed: {proc.returncode}')
        finally:
            if proc.poll() is None:
                proc.terminate(); proc.wait()


if __name__ == '__main__':
    main()
