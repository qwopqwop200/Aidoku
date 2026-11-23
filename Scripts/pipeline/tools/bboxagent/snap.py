"""Simulate along-axis end snapping on final lines; grid-search by train-fold CV. numbers only."""
import json, os, sys, pickle, glob, itertools, collections
import numpy as np
from boxscore import gt, FOLD, page_stats, fmt, iou, linear_sum_assignment


def finals(prefix):
    out = {}
    for s in ('dev', 'train', 'test'):
        for f in glob.glob(f'{prefix}_{s}/pages/*.json'):
            r = json.load(open(f))
            out[r['pageID']] = [tuple(map(tuple, l['bounds'])) for b in r['blocks'] for l in b['lines']]
    return out


def ext_end(P, end, T, f, g, E, m):
    last = end; n = len(P); lim = min(n, end + int(E * T))
    i = end
    while i < lim:
        if P[i] > f: last = i + 1
        elif i - last >= g * T: break
        i += 1
    return last + (m * T if last > end else 0)


def refine(it, prm):
    di, f, g, E, m, c = prm
    P = it['P'][di].astype(np.float32); T = it['T']; lo = it['lo']
    s, e = it['start'], it['end']
    ne = ext_end(P, e, T, f, g, E, m) if E > 0 else e
    ns = len(P) - ext_end(P[::-1], len(P) - s, T, f, g, E, m) if E > 0 else s
    x0, y0, x1, y1 = it['box']
    # convert integer strip positions back; keep fractional original when unchanged
    a = (lo + ns) if ns != s else (y0 if it['vert'] else x0)
    b = (lo + ne) if ne != e else (y1 if it['vert'] else x1)
    a -= c * T; b += c * T
    return (x0, a, x1, b) if it['vert'] else (a, y0, b, y1)


def boxes(F, feats, prm):
    out = {}
    for pid, fin in F.items():
        idx = {((round(it['box'][0], 3), round(it['box'][1], 3))): it for it in feats[pid]}
        L = []
        for (x, y), (w, h) in fin:
            it = idx.get((round(x, 3), round(y, 3)))
            L.append(refine(it, prm) if (it is not None and prm is not None) else (x, y, x + w, y + h))
        out[pid] = L
    return out


def stats(B, pages=None):
    G = gt(); c = collections.defaultdict(float)
    for pid, L in B.items():
        if pages is not None and pid not in pages: continue
        page_stats(G.get(pid, []), L, [], c, FOLD[pid])
    return c


def miou(c, folds):
    I = np.concatenate([np.array(c.get((x, 'ious'), [])) for x in folds]); return I.mean()
