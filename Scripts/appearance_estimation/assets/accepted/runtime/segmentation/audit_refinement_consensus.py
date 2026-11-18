"""Global consensus of complementary source-only refiners; no case lookup rules."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from itertools import combinations
from pathlib import Path
import time
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_style_calibration import style_features
from apply_joint_mask_refinement import refine_source_mask
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha
import train_point_recovery as point

MEMBERS = None
PLANS = None


def initialize(root, model, cache, members, plans):
    global MEMBERS, PLANS
    MEMBERS, PLANS = members, plans
    joint.initialize(root, model, cache)


def partition(payload):
    rows, ordinal = payload
    counts = {s: np.zeros((len(PLANS), 3), np.int64) for s in ['train', 'dev', 'test']}
    for i, row in enumerate(rows):
        base, distance, group, codes = joint.source_predictions(row)
        p, q, _ = point.CONTEXT[2].load(row)
        rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
        case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
        values = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
        predictions = [(refine_source_mask(base, distance, group, codes, member, values, row['fontPixels']) > 0).astype(np.uint8)
                       for member in MEMBERS]
        if sha(row['target']) != row['targetSHA256']:
            raise ValueError('GT changed')
        gt = np.asarray(Image.open(row['target'])) > 0
        for j, (indices, required, scope) in enumerate(PLANS):
            mask = sum(predictions[index] for index in indices) >= required
            counts[row['split']][j] += [np.count_nonzero(mask & gt), np.count_nonzero(mask & ~gt),
                                       np.count_nonzero(~mask & gt)]
        if (i + 1) % 200 == 0:
            print(f'Refinement consensus shard {ordinal}: {i + 1}/{len(rows)}', flush=True)
    return counts


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--reports', type=Path, nargs='+', required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    members, plans = [], []
    model_sha = sha(args.model)
    for scope, key in [('dev', 'devRecall99999'), ('all', 'allRecall99999')]:
        offset = len(members)
        for path in args.reports:
            source = read(path)
            if source['modelSHA256'] != model_sha:
                raise ValueError('Consensus model source mismatch')
            members.append(dict(source[key], consensusMemberReportSHA256=sha(path)))
        for size in range(2, len(args.reports) + 1):
            for indices in combinations(range(offset, len(members)), size):
                plans.append((indices, size // 2 + 1, scope))
                if size == 2:
                    plans.append((indices, 1, scope))
                elif size == 4:
                    plans.append((indices, 2, scope))
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    started = time.monotonic()
    with ProcessPoolExecutor(max_workers=8, initializer=initialize,
            initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve(), members, plans)) as pool:
        parts = list(pool.map(partition, [(rows[i::8], i) for i in range(8)]))
    counts = {s: sum(p[s] for p in parts) for s in ['train', 'dev', 'test']}
    best = {k: None for k in ['devRecall99999', 'allRecall99999', 'allIoU70', 'eachSplitRecall99999']}
    ranks = {k: (-1., -1.) for k in best}
    for i, (indices, required, scope) in enumerate(plans):
        totals = {s: c[i] for s, c in counts.items()}
        all_counts = sum(totals.values())
        for key, c in [('devRecall99999', totals['dev']), ('allRecall99999', all_counts),
                       ('allIoU70', all_counts), ('eachSplitRecall99999', all_counts)]:
            if key == 'devRecall99999' and scope != 'dev':
                continue
            recall, iou = c[0] / (c[0] + c[2]), c[0] / c.sum()
            valid = iou >= .7 if key == 'allIoU70' else recall >= .99999
            if key == 'eachSplitRecall99999':
                valid &= all(v[0] / (v[0] + v[2]) >= .99999 for v in totals.values())
            rank = float(recall if key == 'allIoU70' else iou), float(iou)
            if not valid or rank <= ranks[key]:
                continue
            ranks[key] = rank
            best[key] = dict(ensembleMembers=[members[index] for index in indices], requiredVotes=required,
                sourceMemberIndices=list(indices), templateCalibrationScope=scope,
                all=metrics(all_counts), bySplit={s: metrics(v) for s, v in totals.items()})
    np.savez_compressed(args.out / 'COUNTS.npz', **counts)
    save(args.out / 'RESULT.json', dict(**best, modelSHA256=model_sha, maskCount=len(rows),
        GTAtInference=False, GTChanged=False, sourceOnly=True, productionEnabled=False,
        testPreviouslyInspected=True, candidateCount=len(plans), seconds=time.monotonic() - started))
    print({k: v['all'] if v else None for k, v in best.items()}, flush=True)


if __name__ == '__main__':
    main()
