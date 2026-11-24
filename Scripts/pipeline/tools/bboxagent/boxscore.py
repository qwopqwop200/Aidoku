"""Final lines vs GT individual line boxes (numbers only).
usage: boxscore.py RUN_PREFIX [DUMP_DIR]   (RUN_PREFIX_{dev,train,test}/pages; DUMP_DIR has the RF layout per page)
Per fold: frag/over/miss (lineasm/score.py rules), IoU of each GT line's one-to-one match, end errors in GT line
thickness units, noise = lines overlapping no GT line, split by centre inside an RF balloon/text region or not."""
from pathlib import Path
import json, os, sys, collections
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lineasm'))
from score import gt, inside  # noqa: E402  (also puts tools/ and colorfix/ on the path)
from sim import FOLD  # noqa: E402
from scipy.optimize import linear_sum_assignment  # noqa: E402

FOLDS = ['f2', 'f3', 'f4', 'dev', 'test']


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - ix
    return ix / u if u > 0 else 0


def run_lines(prefix):
    out = {}
    for s in ('dev', 'train', 'test'):
        d = f'{prefix}_{s}/pages'
        if not os.path.isdir(d): continue
        for f in os.listdir(d):
            r = json.load(open(os.path.join(d, f)))
            L = []
            for b in r['blocks']:
                for l in b['lines']:
                    (x, y), (w, h) = l['bounds']; L.append((x, y, x + w, y + h))
            out[r['pageID']] = L
    return out


def layout(dump, pid):
    if not dump: return []
    p = os.path.join(dump, pid + '.json')
    if not os.path.exists(p): return []
    r = json.load(open(p))
    return [((x, y, x + w, y + h)) for q in r['layout'] if q['kind'] in ('balloon', 'text') and q['score'] >= 0.5
            for (x, y), (w, h) in [q['bounds']]]


def page_stats(G, L, R, c, fo):
    for gb in G:
        members = [l for l in L if inside(l, gb) >= 0.5]
        cov = max([inside(gb, l) for l in L], default=0)
        c[fo, 'gt'] += 1
        if len(members) > 1: c[fo, 'fragmented'] += 1
        if not members and cov < 0.5: c[fo, 'missed'] += 1
    for l in L:
        if sum(inside(gb, l) >= 0.5 for gb in G) > 1: c[fo, 'overjoined'] += 1
        if all(inside(l, g) < 0.1 and inside(g, l) < 0.1 for g in G):
            cx, cy = (l[0] + l[2]) / 2, (l[1] + l[3]) / 2
            c[fo, 'noiseIn' if any(r[0] <= cx <= r[2] and r[1] <= cy <= r[3] for r in R) else 'noiseOut'] += 1
    c[fo, 'pred'] += len(L)
    ious = np.zeros(len(G))
    if G and L:
        M = np.array([[iou(g, l) for l in L] for g in G])
        ri, ci = linear_sum_assignment(-M)
        for i, j in zip(ri, ci):
            ious[i] = M[i, j]
            if M[i, j] >= 0.3:
                g, l = G[i], L[j]
                vert = (g[3] - g[1]) >= (g[2] - g[0])
                t = (g[2] - g[0]) if vert else (g[3] - g[1])
                e = [abs(l[k] - g[k]) / t for k in range(4)]
                along = (e[1] + e[3]) / 2 if vert else (e[0] + e[2]) / 2
                cross = (e[0] + e[2]) / 2 if vert else (e[1] + e[3]) / 2
                c[fo, 'ealong'] += along; c[fo, 'ecross'] += cross; c[fo, 'nm'] += 1
                # signed along-axis end error (pred - gt, positive = pred longer)
                c[fo, 'sAlong'] += ((g[1] - l[1]) + (l[3] - g[3])) / t if vert else ((g[0] - l[0]) + (l[2] - g[2])) / t
    c[fo, 'ious'] = c.get((fo, 'ious'), []) + list(ious)


def score(prefix, dump=None, pages=None):
    G = gt(); P = run_lines(prefix); c = collections.defaultdict(float)
    for pid, L in P.items():
        if pages is not None and pid not in pages: continue
        fo = FOLD[pid]
        page_stats(G.get(pid, []), L, layout(dump, pid), c, fo)
    return c


def fmt(c, folds=FOLDS):
    rows = []
    for f in folds + ['train']:
        fs = ['f2', 'f3', 'f4'] if f == 'train' else [f]
        g = lambda k: sum(c.get((x, k), 0) for x in fs)
        I = np.concatenate([np.array(c.get((x, 'ious'), [])) for x in fs]) if g('gt') else np.zeros(1)
        n = max(1, g('nm'))
        rows.append(f"{f:5s} gt {int(g('gt')):5d} pred {int(g('pred')):5d} mIoU {I.mean():.3f} med {np.median(I):.3f} "
                    f">=.5 {np.mean(I >= .5):.3f} >=.7 {np.mean(I >= .7):.3f} eAlong {g('ealong')/n:.3f} eCross {g('ecross')/n:.3f} "
                    f"sAlong {g('sAlong')/n:+.3f} frag {int(g('fragmented'))} over {int(g('overjoined'))} miss {int(g('missed'))} "
                    f"noiseIn {int(g('noiseIn'))} noiseOut {int(g('noiseOut'))}")
    return '\n'.join(rows)


if __name__ == '__main__':
    p = sys.argv[1]; d = sys.argv[2] if len(sys.argv) > 2 else None
    print(p.split('/')[-1]); print(fmt(score(p, d)))
