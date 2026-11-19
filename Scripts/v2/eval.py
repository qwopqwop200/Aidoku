#!/usr/bin/env python3
"""End-to-end metrics for a V2 pipeline run (Scripts/image-translation.swift).

Reads RUN/pages/*.json (blocks with lines, placed, timings) and scores one split of
the canonical grouped-source manifest against aidoku-unified-gt-20261116.json:

- detection: recall/precision at polygon IoU 0.5/0.7 of the V2 accepted lines
  (block members, after line assembly and the recognition gate) against
  individual_premerge_bbox (status canonical, optimization_required). One-to-one
  Hungarian matching on polygon IoU, ported from the gtopt detection harness.
- grouping: pairwise precision/recall/F1, purity, exact-group rate and contaminated
  groups over V2 lines assigned to GT merged_bbox regions (>= 50% of the line box
  inside the region box), ported from the gtopt grouping harness (production-
  detection mode; the 6 not-required GT groups are excluded).
- translation coverage, page failures, per-stage timing median/p90.

The TEST split is refused unless --allow-test is given (final one-shot run only).

Usage: python3 Scripts/v2/eval.py RUN_DIR [--split dev] [--out RUN_DIR/eval.json]
"""
import argparse
import collections
import json
import statistics
import sys
from pathlib import Path

import numpy as np
import shapely
try:
    from scipy.optimize import linear_sum_assignment
except ImportError:  # broken/missing SciPy: exact greedy fallback is NOT Hungarian
    linear_sum_assignment = None
from shapely.geometry import Polygon

ROOT = Path(__file__).resolve().parents[3]
GT_PATH = ROOT / 'aidoku-unified-gt-20261116.json'
MANIFEST = ROOT / 'pipeline-generalization-20261117/evaluation-audit/CANONICAL-GROUPED-SOURCE-MANIFEST.json'
NOT_REQUIRED = {('0030', 'region-32'), ('0150', 'region-9'), ('0150', 'region-10'), ('0394', 'region-2'),
                ('0666', 'region-1'), ('0760', 'region-18')}
LEGACY = {'detection': {'recall@0.5': 0.974, 'recall@0.7': 0.939},
          'grouping': {'F1': 0.915, 'purity': 0.999}}


def load_gt(pages):
    data = json.load(open(GT_PATH))
    individual = collections.defaultdict(list)
    merged = collections.defaultdict(list)
    for r in data['records']:
        pid = r.get('page_id')
        if pid not in pages:
            continue
        if r['scope'] == 'individual_premerge_bbox':
            if r.get('status') == 'canonical' and r.get('optimization_required'):
                individual[pid].append([(p['x'], p['y']) for p in r['label']['polygon']])
        elif r['scope'] == 'merged_bbox' and r.get('status') == 'canonical':
            if (pid, r['entity_id']) in NOT_REQUIRED:
                continue
            merged[pid].append({'id': r['entity_id'], 'poly': [(p['x'], p['y']) for p in r['label']['polygon']]})
    return individual, merged


# --- detection (ported from gtopt/detection/common.py) ---
def poly(pts):
    p = Polygon(pts)
    return p if p.is_valid else p.buffer(0)


def iou_matrix(gt, pred):
    m = np.zeros((len(gt), len(pred)))
    if not gt or not pred:
        return m
    gp = [poly(g) for g in gt]
    pp = [poly(p) for p in pred]
    tree = shapely.STRtree(pp)
    gi, pi = tree.query(gp)
    a = np.array(gp, dtype=object)[gi]
    b = np.array(pp, dtype=object)[pi]
    inter = shapely.area(shapely.intersection(a, b))
    union = shapely.area(shapely.union(a, b))
    m[gi, pi] = np.divide(inter, union, out=np.zeros(len(gi)), where=union > 0)
    return m


def match(m, thr):
    if m.size == 0:
        return []
    if linear_sum_assignment is None:
        pairs, used_g, used_p = [], set(), set()
        for i, j in sorted(zip(*np.nonzero(m >= thr)), key=lambda ij: -m[ij]):
            if i not in used_g and j not in used_p:
                used_g.add(i); used_p.add(j); pairs.append((i, j, m[i, j]))
        return pairs
    w = np.where(m >= thr, m.shape[0] + 1 + m, 0)
    gi, pi = linear_sum_assignment(w, maximize=True)
    return [(i, j, m[i, j]) for i, j in zip(gi, pi) if m[i, j] >= thr]


def detection(gt, pred):
    m = iou_matrix(gt, pred)
    s = {'gt': len(gt), 'pred': len(pred)}
    for t in (0.5, 0.7):
        pairs = match(m, t)
        s[f'tp{t}'] = len(pairs)
        s[f'iousum{t}'] = float(sum(v for _, _, v in pairs))
    return s


def aggregate_detection(stats):
    g = sum(s['gt'] for s in stats)
    p = sum(s['pred'] for s in stats)
    out = {'pages': len(stats), 'gt': g, 'pred': p}
    for t in (0.5, 0.7):
        tp = sum(s[f'tp{t}'] for s in stats)
        r = tp / g if g else 0
        pr = tp / p if p else 0
        out[f'recall@{t}'] = round(r, 4)
        out[f'precision@{t}'] = round(pr, 4)
        out[f'meanIoU@{t}'] = round(sum(s[f'iousum{t}'] for s in stats) / tp, 4) if tp else 0
    return out


# --- grouping (ported from gtopt/grouping/evalg.py, production-detection mode) ---
def bbox(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return (min(xs), min(ys), max(xs), max(ys))


def inter(a, b):
    return max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))


def area(a):
    return max(0, a[2] - a[0]) * max(0, a[3] - a[1])


def iou(a, b):
    i = inter(a, b)
    u = area(a) + area(b) - i
    return i / u if u > 0 else 0


def score_partition(label, groups):
    tp = fp = fn = 0
    group_of = {u: gi for gi, g in enumerate(groups) for u in g}
    units = [u for u in label if label[u] is not None]
    for i in range(len(units)):
        for j in range(i + 1, len(units)):
            a, b = units[i], units[j]
            same, joined = label[a] == label[b], group_of[a] == group_of[b]
            tp += same and joined
            fp += (not same) and joined
            fn += same and (not joined)
    purity_num = purity_den = 0
    for g in groups:
        labels = [label[u] for u in g if label.get(u) is not None]
        if labels:
            purity_num += collections.Counter(labels).most_common(1)[0][1]
            purity_den += len(labels)
    truth = collections.defaultdict(set)
    for u in units:
        truth[label[u]].add(u)
    exact = sum(1 for s in truth.values() if any({u for u in g if label.get(u) is not None} == s for g in groups))
    contaminated = sum(1 for g in groups if any(label.get(u) is None for u in g) and any(label.get(u) is not None for u in g))
    return dict(tp=tp, fp=fp, fn=fn, pur_num=purity_num, pur_den=purity_den, exact=exact, ngt=len(truth),
                contam=contaminated)


def grouping(regions, blocks):
    region_boxes = [(r['id'], bbox(r['poly'])) for r in regions]
    label, groups, block_boxes = {}, [], []
    unit = 0
    for block in blocks:
        members = []
        for line in block['lines']:
            box = bbox([(p[0], p[1]) for p in line['polygon']])
            best, value = None, 0
            for rid, rb in region_boxes:
                v = inter(box, rb) / max(1e-9, area(box))
                if v > value:
                    best, value = rid, v
            label[unit] = best if value >= 0.5 else None
            members.append(unit)
            unit += 1
        groups.append(members)
        b = block['bounds']
        block_boxes.append((b[0][0], b[0][1], b[0][0] + b[1][0], b[0][1] + b[1][1]))
    s = score_partition(label, groups)
    s['ious'] = [max([iou(rb, x) for x in block_boxes], default=0) for _, rb in region_boxes]
    return s


def aggregate_grouping(rows):
    t = collections.Counter()
    ious = []
    for r in rows:
        for k, v in r.items():
            if k == 'ious':
                ious += v
            else:
                t[k] += v
    p = t['tp'] / (t['tp'] + t['fp']) if t['tp'] + t['fp'] else 1
    r = t['tp'] / (t['tp'] + t['fn']) if t['tp'] + t['fn'] else 1
    return dict(P=round(p, 4), R=round(r, 4), F1=round(2 * p * r / (p + r), 4) if p + r else 0,
                purity=round(t['pur_num'] / max(1, t['pur_den']), 4), exactGroup=round(t['exact'] / max(1, t['ngt']), 4),
                mIoU=round(sum(ious) / max(1, len(ious)), 4), iou50=round(sum(i >= 0.5 for i in ious) / max(1, len(ious)), 4),
                contaminatedGroups=t['contam'], nGTGroups=len(ious))


def percentile(values, q):
    if not values:
        return 0
    v = sorted(values)
    pos = q * (len(v) - 1)
    lo, hi = int(pos), min(len(v) - 1, int(pos) + 1)
    return v[lo] + (v[hi] - v[lo]) * (pos - lo)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run')
    ap.add_argument('--split', default='dev', choices=['dev', 'train', 'test', 'any'])
    ap.add_argument('--allow-test', action='store_true')
    ap.add_argument('--out')
    args = ap.parse_args()
    if args.split == 'test' and not args.allow_test:
        sys.exit('refusing to score TEST without --allow-test (final one-shot evaluation only)')
    run = Path(args.run)
    records = {}
    for f in sorted((run / 'pages').glob('*.json')):
        r = json.load(open(f))
        records[r['pageID']] = r
    manifest = {p['page_id']: p for p in json.load(open(MANIFEST))['pages']}
    if args.split != 'any':
        records = {k: v for k, v in records.items() if manifest.get(k, {}).get('split') == args.split}
    if any(manifest.get(k, {}).get('split') == 'test' for k in records) and not args.allow_test:
        sys.exit('run contains TEST pages; pass --allow-test only for the final evaluation')
    individual, merged = load_gt(set(records))
    det_rows, group_rows = [], []
    blocks_total = translated = 0
    replay = collections.Counter()
    stage_values = collections.defaultdict(list)
    failures = []
    for pid, r in sorted(records.items()):
        lines = [[(p[0], p[1]) for p in line['polygon']] for b in r['blocks'] for line in b['lines']]
        det_rows.append(detection(individual.get(pid, []), lines))
        if merged.get(pid):
            group_rows.append(grouping(merged[pid], r['blocks']))
        blocks_total += len(r['blocks'])
        translated += sum(1 for b in r['blocks'] if b.get('translation'))
        if r.get('replayLegacyRegions') is not None:
            replay['blocksMatched'] += r.get('replayMatched') or 0
            replay['legacyRegions'] += r['replayLegacyRegions']
            replay['legacyRegionsUsed'] += r.get('replayLegacyRegionsUsed') or 0
            replay['syntheticBlocks'] += len(r.get('replaySyntheticBlocks') or [])
        for k, v in r['timings'].items():
            stage_values[k].append(v)
        if r.get('failure'):
            failures.append({'page': pid, 'failure': r['failure']})
    result = {
        'run': str(run), 'split': args.split, 'pages': len(records),
        'detection': aggregate_detection(det_rows),
        'grouping': aggregate_grouping(group_rows),
        'translationCoverage': round(translated / blocks_total, 4) if blocks_total else 0,
        'blocks': blocks_total,
        'replay': dict(replay, blockCoverageFromLegacy=round(replay['blocksMatched'] / blocks_total, 4) if blocks_total else 0,
                       legacyRegionCoverage=round(replay['legacyRegionsUsed'] / replay['legacyRegions'], 4)
                       if replay['legacyRegions'] else 0),
        'failures': failures,
        'timingsMs': {k: {'median': round(statistics.median(v), 1), 'p90': round(percentile(v, 0.9), 1)}
                      for k, v in sorted(stage_values.items())},
        'legacyBaseline': LEGACY,
        'matching': 'hungarian' if linear_sum_assignment else 'greedy-fallback (SciPy unavailable)',
    }
    out = Path(args.out) if args.out else run / f'eval-{args.split}.json'
    out.write_text(json.dumps(result, indent=1, ensure_ascii=False))
    print(json.dumps({k: result[k] for k in ('pages', 'detection', 'grouping', 'translationCoverage', 'replay')}, indent=1))
    t = result['timingsMs'].get('total_non_llm')
    if t:
        print('non-LLM ms median %.0f p90 %.0f' % (t['median'], t['p90']))


if __name__ == '__main__':
    main()
