#!/usr/bin/env python3
"""Placement vs GT balloon/narration masks (JSON + RLE only, no page pixels).

For every painted (non-synthetic) block whose source bounds lie mostly (>= 50%) in a GT
balloon instance: share of its text frame rectangle outside that mask (an upper bound
on painted glyph area outside the balloon), and the frame's fill of the mask.
"""
import collections, json, statistics, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))  # tools dir
from workspace import GT as _GT, data  # noqa: E402
GT = str(_GT)
CACHE = data('balloon_masks.npz')


def decode(seg):
    h, w = seg['size']
    flat = np.zeros(h * w, dtype=np.uint8)
    pos, val = 0, 0
    for c in seg['counts']:
        if val:
            flat[pos:pos + c] = 1
        pos += c
        val ^= 1
    return flat.reshape((w, h)).T  # column-major


def load(pages):
    d = json.load(open(GT))
    masks = collections.defaultdict(list)
    for r in d['records']:
        if r['scope'] != 'balloon_narration_instance_segmentation' or r.get('page_id') not in pages:
            continue
        m = decode(r['label']['segmentation'])
        ys, xs = np.nonzero(m)
        if len(xs) == 0:
            continue
        masks[r['page_id']].append((m, (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1), int(m.sum())))
    return masks


def run(path):
    pages = {}
    for f in sorted(Path(path, 'pages').glob('*.json')):
        r = json.load(open(f))
        pages[r['pageID']] = r
    masks = load(set(pages))
    outs, fills, n_free, n_in = [], [], 0, 0
    bad = 0
    for pid, r in pages.items():
        blocks = {b['id']: b for b in r['blocks']}
        syn = set(r.get('replaySyntheticBlocks') or [])
        for p in r['placed']:
            if p['blockID'] in syn:
                continue
            b = blocks[p['blockID']]
            (bx, by), (bw, bh) = b['bounds']
            x0, y0, x1, y1 = int(bx), int(by), int(bx + bw) + 1, int(by + bh) + 1
            best = None
            for m, box, area in masks.get(pid, []):
                sub = m[max(0, y0):y1, max(0, x0):x1]
                cov = sub.sum() / max(1, (x1 - x0) * (y1 - y0))
                if cov >= 0.5 and (best is None or cov > best[0]):
                    best = (cov, m, area)
            if best is None:
                n_free += 1
                continue
            n_in += 1
            (fx, fy), (fw, fh) = p['frame']
            X0, Y0 = max(0, int(round(fx))), max(0, int(round(fy)))
            X1, Y1 = int(round(fx + fw)), int(round(fy + fh))
            m = best[1]
            inside = m[Y0:Y1, X0:X1].sum()
            tot = max(1, (X1 - X0) * (Y1 - Y0))
            o = 1 - inside / tot
            outs.append(o)
            fills.append(tot / best[2])
            bad += o > 0.05
    return dict(inBalloon=n_in, free=n_free, outsideMean=round(float(np.mean(outs)), 4) if outs else 0,
                framesOver5pctOutside=int(bad), frameFillOfBalloonMedian=round(float(np.median(fills)), 4) if fills else 0)


if __name__ == '__main__':
    for p in sys.argv[1:]:
        print(p.split('/')[-1], json.dumps(run(p)))
