#!/usr/bin/env python3
"""Shared-top alignment against the legacy source clusters (predicted-clusters830.json).

Clusters map onto blocks by source-box overlap (>= 50% of the smaller box). For each block pair in one
'top'-axis cluster: |painted top difference| / mean painted font px; reports the share < 0.25 and < 0.1 em.

usage: align_metrics.py RUN [RUN...] [--folds]
"""
import json, sys, itertools, statistics
from collections import defaultdict
from pathlib import Path

from workspace import SIZE_CLUSTERS as GT, MANIFEST
_gt = None


def gt():
    global _gt
    if _gt is None:
        _gt = {p['page']: p for p in json.load(open(GT))['pages']}
    return _gt


def folds():
    return {p['page_id']: (p['split'], p['fold']) for p in json.load(open(MANIFEST))['pages']}


def rect(b):
    (x, y), (w, h) = b
    return x, y, w, h


def overlap(a, b):
    ax, ay, aw, ah = a; bx, by, bw, bh = b
    ix = max(0, min(ax + aw, bx + bw) - max(ax, bx)); iy = max(0, min(ay + ah, by + bh) - max(ay, by))
    m = min(aw * ah, bw * bh)
    return ix * iy / m if m > 0 else 0


def gt_pairs(r):
    """Block id pairs in one top-axis legacy cluster."""
    page = gt().get(r['pageID'])
    if not page:
        return None
    blocks = r['blocks']
    def owner(item):
        best = max(blocks, key=lambda b: overlap(item['bbox'], rect(b['bounds'])), default=None)
        return best['id'] if best and overlap(item['bbox'], rect(best['bounds'])) >= 0.5 else None
    pairs = set()
    for g in page['groups']:
        rows = [page['items'][i] for i in g['members']]
        xs = [i['bbox'][0] for i in rows]; ys = [i['bbox'][1] for i in rows]
        if max(xs) - min(xs) < max(ys) - min(ys):
            continue
        ids = {o for o in map(owner, rows) if o is not None}
        pairs |= {tuple(sorted(p)) for p in itertools.combinations(ids, 2)}
    return pairs


def run(path, by_fold=False):
    split = folds()
    diffs = defaultdict(list)
    for f in sorted(Path(path, 'pages').glob('*.json')):
        r = json.load(open(f))
        pairs = gt_pairs(r)
        if not pairs:
            continue
        placed = {p['blockID']: p for p in r['placed']}
        key = split.get(r['pageID'], ('?', '?'))
        for a, b in pairs:
            if a not in placed or b not in placed:
                continue
            pa, pb = placed[a], placed[b]
            em = (pa['fontPixels'] + pb['fontPixels']) / 2
            diffs[key[1] if by_fold and key[0] == 'train' else 'all'].append(abs(pa['frame'][0][1] - pb['frame'][0][1]) / em)
    out = {}
    for k, d in sorted(diffs.items()):
        out[k] = dict(pairs=len(d), lt025=round(sum(x < 0.25 for x in d) / len(d), 4),
                      lt010=round(sum(x < 0.1 for x in d) / len(d), 4), median=round(statistics.median(d), 3))
    return out


if __name__ == '__main__':
    by_fold = '--folds' in sys.argv
    for p in [a for a in sys.argv[1:] if not a.startswith('--')]:
        print(p.rstrip('/').split('/')[-1], json.dumps(run(p, by_fold)))
