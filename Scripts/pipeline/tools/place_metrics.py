#!/usr/bin/env python3
"""Placement metrics needing source pixels (processed in code only, never viewed).

srcDist: |frame centre - source bounds centre| / source px (median, p90).
artRisk: for painted frames, share of frame cells (768-px gray raster, excluding every
block's source bounds) whose gradient magnitude > 48: text painted over art/outlines.
Reported as mean and the count of frames with risk > 0.05.
"""
import json, statistics, sys
from pathlib import Path
import numpy as np
from PIL import Image

_raster = {}


def raster(path):
    if path not in _raster:
        im = Image.open(path).convert('L')
        w, h = im.size
        s = min(1, 768 / max(w, h))
        g = np.asarray(im.resize((max(1, int(w * s)), max(1, int(h * s))), Image.BILINEAR), dtype=np.int16)
        gx = np.zeros_like(g); gy = np.zeros_like(g)
        gx[:, 1:-1] = np.abs(g[:, 2:] - g[:, :-2]); gy[1:-1, :] = np.abs(g[2:, :] - g[:-2, :])
        _raster.clear()
        _raster[path] = ((gx + gy) > 48, s)
    return _raster[path]


def run(path):
    dists, risks = [], []
    for f in sorted(Path(path, 'pages').glob('*.json')):
        r = json.load(open(f))
        blocks = {b['id']: b for b in r['blocks']}
        syn = set(r.get('replaySyntheticBlocks') or [])
        placed = [p for p in r['placed'] if p['blockID'] not in syn]
        if not placed:
            continue
        edge, s = raster(r['image'])
        keep = np.ones_like(edge)
        for b in r['blocks']:
            (x, y), (w, h) = b['bounds']
            keep[max(0, int(y * s) - 1):int((y + h) * s) + 2, max(0, int(x * s) - 1):int((x + w) * s) + 2] = False
        for p in placed:
            b = blocks[p['blockID']]
            src = (b.get('style') or {}).get('fontPixels') or 0
            (x, y), (w, h) = b['bounds']
            (fx, fy), (fw, fh) = p['frame']
            if src:
                dists.append(np.hypot(fx + fw / 2 - (x + w / 2), fy + fh / 2 - (y + h / 2)) / src)
            sub = edge[int(fy * s):int((fy + fh) * s) + 1, int(fx * s):int((fx + fw) * s) + 1]
            k = keep[int(fy * s):int((fy + fh) * s) + 1, int(fx * s):int((fx + fw) * s) + 1]
            n = k.sum()
            risks.append(float((sub & k).sum() / n) if n else 0.0)
    return dict(srcDistMedian=round(statistics.median(dists), 3), srcDistP90=round(float(np.percentile(dists, 90)), 3),
                artRiskMean=round(statistics.mean(risks), 4), artRiskOver5=sum(x > 0.05 for x in risks))


if __name__ == '__main__':
    for p in sys.argv[1:]:
        print(p.rstrip('/').split('/')[-1], json.dumps(run(p)))
