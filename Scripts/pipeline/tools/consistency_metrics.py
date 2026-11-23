#!/usr/bin/env python3
"""Painted-size consistency inside GT source-size classes (JSON only).

GT exact_source_font_size_partition: regions of one page whose source lettering has the
same px size. Each painted (non-synthetic) block is matched to the GT merged_bbox region
holding most of it (>= 50% of the block box). For every class with >= 2 matched blocks:
spread = max/min painted px. Reports classes, share with spread <= 1.10 / <= 1.25, mean
log-spread, and median painted/GT-source ratio.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # tools dir
from workspace import GT as _GT  # noqa: E402
import collections, json, math, statistics, sys
from pathlib import Path

GT = str(_GT)
_cache = {}


def gt():
    if 'd' not in _cache:
        d = json.load(open(GT))
        regions, classes, size = collections.defaultdict(dict), collections.defaultdict(list), {}
        for r in d['records']:
            if r['scope'] == 'merged_bbox' and r.get('status') == 'canonical':
                xs = [p['x'] for p in r['label']['polygon']]; ys = [p['y'] for p in r['label']['polygon']]
                regions[r['page_id']][r['entity_id']] = (min(xs), min(ys), max(xs), max(ys))
            elif r['scope'] == 'exact_source_font_size_partition':
                for c in r['label']['classes']:
                    classes[r['page_id']].append((c['fontSizePx'], c['memberIDs']))
                    for m in c['memberIDs']:
                        size[(r['page_id'], m)] = c['fontSizePx']
        _cache['d'] = (regions, classes, size)
    return _cache['d']


def run(path):
    regions, classes, size = gt()
    spreads, ratios = [], []
    for f in sorted(Path(path, 'pages').glob('*.json')):
        r = json.load(open(f))
        pid = r['pageID']
        blocks = {b['id']: b for b in r['blocks']}
        syn = set(r.get('replaySyntheticBlocks') or [])
        member = collections.defaultdict(list)
        for p in r['placed']:
            if p['blockID'] in syn:
                continue
            (x, y), (w, h) = blocks[p['blockID']]['bounds']
            best, val = None, 0
            for rid, (a, b, c, d) in regions.get(pid, {}).items():
                i = max(0, min(x + w, c) - max(x, a)) * max(0, min(y + h, d) - max(y, b))
                v = i / max(1e-9, w * h)
                if v > val:
                    best, val = rid, v
            if best is None or val < 0.5:
                continue
            member[best].append(p['fontPixels'])
            if (pid, best) in size:
                ratios.append(p['fontPixels'] / size[(pid, best)])
        for px, ids in classes.get(pid, []):
            sizes = [s for i in ids for s in member.get(i, [])]
            if len(sizes) >= 2:
                spreads.append(max(sizes) / min(sizes))
    n = len(spreads)
    return dict(classes=n, within110=round(sum(s <= 1.10 for s in spreads) / max(1, n), 4),
                within125=round(sum(s <= 1.25 for s in spreads) / max(1, n), 4),
                meanLogSpread=round(statistics.mean(math.log(s) for s in spreads), 4) if n else 0,
                paintedOverGTMedian=round(statistics.median(ratios), 4) if ratios else 0)


if __name__ == '__main__':
    for p in sys.argv[1:]:
        print(p.rstrip('/').split('/')[-1], json.dumps(run(p)))
