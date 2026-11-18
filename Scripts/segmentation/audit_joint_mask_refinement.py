"""Joint source-only interior cleanup/outer recovery with reusable prediction cache."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from functools import lru_cache
import hashlib
import inspect
import json
from pathlib import Path
import tempfile
import time

import cv2
import joblib
import numpy as np
from PIL import Image

from audit_kernel_free_completion import component_candidates, metrics
from compiled_point_predict import CompiledPointPredictor
from evaluate_gt import read, save, sha
import train_context_recovery as context
import train_point_recovery as point

BINS = 8192
RADIUS = 12
STATE = None


@lru_cache(maxsize=128)
def frozen_file_sha(path):
    return sha(path)


def initialize(root, model_path, cache):
    global STATE
    root = Path(root)
    point.initialize(root)
    model = joblib.load(model_path)
    predictor = CompiledPointPredictor(model)
    code = ''.join(inspect.getsource(module) for module in [context, point])
    STATE = dict(root=root, cache=Path(cache), predictor=predictor, modelSHA256=sha(model_path),
                 featureCodeSHA256=hashlib.sha256(code.encode()).hexdigest())
    cv2.setNumThreads(1)


def source_predictions(row):
    """No target path or target pixels are consumed in this function."""
    state = STATE
    root, native, votes = point.CONTEXT
    inputs = {k: row[k] for k in ['id', 'rgb', 'rf', 'width', 'height', 'polygons', 'fontPixels']}
    p, q, _ = votes.load(inputs)
    native_path = native / 'native-masks' / (row['id'] + '.u8')
    raw = np.fromfile(native_path, np.uint8).reshape(p.shape)
    base = component_candidates(raw)['fillHoles'] > 0
    distance = cv2.distanceTransform((~base).astype(np.uint8), cv2.DIST_C, 3).astype(np.int32)
    group = ((p >= .5).astype(np.uint8) + (q >= .3).astype(np.uint8))
    case_path = root / 'boundary-lean/rf-full/crops' / (row['id'] + '.json')
    rf_case = read(case_path)
    full_grid = (case_path.parent / rf_case['nativeGrids']).resolve()
    contract = dict(schema=1, bins=BINS, maximumRadius=RADIUS, modelSHA256=state['modelSHA256'],
        featureCodeSHA256=state['featureCodeSHA256'], rgbSHA256=sha(row['rgb']), rfSHA256=sha(row['rf']),
        fullRFCaseSHA256=sha(case_path), fullRFGridSHA256=frozen_file_sha(str(full_grid)),
        baseSHA256=sha(native_path), primarySHA256=hashlib.sha256(p.tobytes()).hexdigest(),
        boundarySHA256=hashlib.sha256(q.tobytes()).hexdigest(), inputs=inputs)
    key = hashlib.sha256(json.dumps(contract, sort_keys=True).encode()).hexdigest()
    destination = state['cache'] / (key + '.npz')
    if destination.exists():
        with np.load(destination) as data:
            if json.loads(str(data['contract'])) != contract:
                raise ValueError('Prediction cache source contract mismatch')
            codes = data['codes']
        if codes.shape != base.shape or codes.dtype != np.uint16:
            raise ValueError('Invalid prediction cache dimensions')
        return base, distance, group, codes
    features, repeated_base, _ = context.features_and_base(inputs)
    if not np.array_equal(base, repeated_base):
        raise ValueError('Base source changed during extraction')
    indices = np.flatnonzero((base | (distance <= RADIUS)).ravel())
    probabilities = state['predictor'].probabilities(features, indices)
    odds = np.log(np.maximum(probabilities, 1e-12)) - np.log(np.maximum(1 - probabilities, 1e-12))
    quantized = np.clip(np.floor((odds + 24) * BINS / 48), 0, BINS - 1).astype(np.uint16)
    codes = np.full(base.size, 65535, np.uint16)
    codes[indices] = quantized
    codes = codes.reshape(base.shape)
    with tempfile.NamedTemporaryFile(dir=state['cache'], suffix='.npz', delete=False) as handle:
        temporary = Path(handle.name)
        np.savez_compressed(handle, codes=codes, contract=json.dumps(contract, sort_keys=True))
    temporary.replace(destination)
    return base, distance, group, codes


def partition(payload):
    rows, ordinal = payload
    inside = {s: np.zeros((3, 2, BINS), np.int64) for s in ['train', 'dev', 'test']}
    outside = {s: np.zeros((2, RADIUS + 1, BINS), np.int64) for s in inside}
    total_gt = {s: 0 for s in inside}
    for i, row in enumerate(rows):
        base, distance, group, codes = source_predictions(row)
        # Scoring starts only after source predictions are fixed and persisted.
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        total_gt[row['split']] += int(gt.sum())
        for label, members in enumerate([gt, ~gt]):
            selected = base & members
            encoded = group[selected].astype(np.int32) * BINS + codes[selected].astype(np.int32)
            inside[row['split']][:, label] += np.bincount(encoded, minlength=3 * BINS).reshape(3, BINS)
            selected = (~base) & (distance <= RADIUS) & members
            encoded = distance[selected] * BINS + codes[selected].astype(np.int32)
            outside[row['split']][label] += np.bincount(encoded, minlength=(RADIUS + 1) * BINS).reshape(RADIUS + 1, BINS)
        if (i + 1) % 100 == 0:
            print(f'Joint refinement shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return inside, outside, total_gt


def summarize(inside, outside, total_gt):
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    rank = {k: (-1., -1.) for k in best}
    outer_prefix = {s: v.cumsum(axis=1) for s, v in outside.items()}
    for protection in ['none', 'anyStrong', 'consensus']:
        protected = [] if protection == 'none' else ([1, 2] if protection == 'anyStrong' else [2])
        core_curves = {}
        for s, h in inside.items():
            fixed = h[protected].sum(axis=(0, 2)) if protected else np.zeros(2, np.int64)
            variable = h[[i for i in range(3) if i not in protected]].sum(axis=0)
            core_curves[s] = fixed[:, None] + variable[:, ::-1].cumsum(axis=1)[:, ::-1]
        train_core_gt = inside['train'][:, 0].sum()
        train_lost = train_core_gt - core_curves['train'][0]
        budgets = np.unique(np.rint(np.geomspace(1, 20000, 64)).astype(np.int64))
        thresholds = np.unique(np.concatenate([[0], np.linspace(0, BINS - 1, 65, dtype=int),
            np.minimum(np.searchsorted(train_lost, budgets, side='right') - 1, BINS - 1)]))
        thresholds = thresholds[thresholds >= 0]
        for core in [0, 1, 2]:
            for outer in [3, 4, 5, 7, 10, 12]:
                outer_curves = {}
                for s, h in outer_prefix.items():
                    fixed = h[:, core].sum(axis=1)
                    variable = (h[:, outer] - h[:, core])[:, ::-1].cumsum(axis=1)[:, ::-1]
                    outer_curves[s] = fixed[:, None] + variable
                for core_threshold in thresholds:
                    totals = {}
                    for s, curve in core_curves.items():
                        tp_fp = curve[:, core_threshold, None] + outer_curves[s]
                        totals[s] = np.vstack([tp_fp, total_gt[s] - tp_fp[0]])
                    all_counts = sum(totals.values())
                    for key, c in [('devRecall99999', totals['dev']), ('allRecall99999', all_counts),
                                   ('allIoU70', all_counts), ('eachSplitRecall99999', all_counts)]:
                        recall = c[0] / (c[0] + c[2])
                        iou = c[0] / c.sum(axis=0)
                        valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
                        if key == 'eachSplitRecall99999':
                            for v in totals.values():
                                valid &= v[0] / (v[0] + v[2]) >= .99999
                        indices = np.flatnonzero(valid)
                        if not len(indices):
                            continue
                        score = recall if key == 'allIoU70' else iou
                        t = int(indices[np.argmax(score[indices])])
                        candidate_rank = float(score[t]), float(iou[t])
                        if candidate_rank <= rank[key]:
                            continue
                        rank[key] = candidate_rank
                        best[key] = dict(protection=protection, coreRadiusPixels=core, outerRadiusPixels=outer,
                            interiorThresholdCode=int(core_threshold), exteriorThresholdCode=t,
                            logitBinCount=BINS, logitMinimum=-24, logitMaximum=24,
                            all=metrics(all_counts[:, t]), bySplit={s: metrics(v[:, t]) for s, v in totals.items()})
    return best


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'out', 'cache']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=8)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize,
                             initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve())) as pool:
        parts = list(pool.map(partition, [(rows[i::args.jobs], i) for i in range(args.jobs)]))
    inside = {s: sum(p[0][s] for p in parts) for s in ['train', 'dev', 'test']}
    outside = {s: sum(p[1][s] for p in parts) for s in inside}
    total_gt = {s: sum(p[2][s] for p in parts) for s in inside}
    np.savez_compressed(args.out / 'COUNTS.npz', **{s + '_inside': h for s, h in inside.items()},
                        **{s + '_outside': h for s, h in outside.items()}, totalGT=np.array(list(total_gt.values())))
    result = summarize(inside, outside, total_gt)
    result.update(maskCount=len(rows), sourceOnly=True, GTAtInference=False, GTChanged=False,
                  testPreviouslyInspected=True, productionEnabled=False, modelSHA256=sha(args.model),
                  seconds=time.monotonic() - started, coreThresholdGridScope='TRAIN-positive-score-quantiles')
    save(args.out / 'RESULT.json', result)
    print(result, flush=True)


if __name__ == '__main__':
    main()
