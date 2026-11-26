"""Line-box metrics (the port-eval/linebox benchmark scorer): per page, Hungarian one-to-one matching by IoU.
mIoU (GT lines, unmatched = 0), R50/R70/R90, qIoU (GT polygon vs predicted quad), frag, merge, exact pages."""
import math
import numpy as np
from scipy.optimize import linear_sum_assignment


def iou_matrix(a, b):
    if not len(a) or not len(b): return np.zeros((len(a), len(b))), None, None
    A = np.asarray(a, float)[:, None, :]; B = np.asarray(b, float)[None, :, :]
    w = np.clip(np.minimum(A[..., 2], B[..., 2]) - np.maximum(A[..., 0], B[..., 0]), 0, None)
    h = np.clip(np.minimum(A[..., 3], B[..., 3]) - np.maximum(A[..., 1], B[..., 1]), 0, None)
    inter = w * h
    aa = (A[..., 2] - A[..., 0]) * (A[..., 3] - A[..., 1]); bb = (B[..., 2] - B[..., 0]) * (B[..., 3] - B[..., 1])
    return inter / np.maximum(aa + bb - inter, 1e-9), inter / np.maximum(aa, 1e-9), inter / np.maximum(bb, 1e-9)


def _order(poly):
    c = np.mean(poly, 0); return sorted(poly, key=lambda q: math.atan2(q[1] - c[1], q[0] - c[0]))


def _area(P):
    return 0.5 * abs(sum(P[i][0] * P[(i + 1) % len(P)][1] - P[(i + 1) % len(P)][0] * P[i][1] for i in range(len(P))))


def _clip(subject, clipper):
    out = subject
    for i in range(len(clipper)):
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]; inp, out = out, []
        if not inp: break
        def inside(p): return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]) >= 0
        def cut(p, q):
            x1, y1, x2, y2, x3, y3, x4, y4 = *p, *q, *a, *b
            d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
            if d == 0: return q
            t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d
            return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))
        for j in range(len(inp)):
            p, q = inp[j], inp[(j + 1) % len(inp)]
            if inside(q):
                if not inside(p): out.append(cut(p, q))
                out.append(q)
            elif inside(p): out.append(cut(p, q))
    return out


def poly_iou(a, b):
    A, B = _order([tuple(map(float, q)) for q in a]), _order([tuple(map(float, q)) for q in b])
    I = _clip(A, B); inter = _area(I) if len(I) >= 3 else 0.0
    u = _area(A) + _area(B) - inter
    return inter / u if u > 0 else 0.0


def quad(pr):
    if pr.get('poly') and len(pr['poly']) >= 4: return [tuple(map(float, q)) for q in pr['poly'][:4]]
    x0, y0, x1, y1 = map(float, pr['box'])
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def score_page(preds, gts):
    n, m = len(gts), len(preds)
    r = dict(gt=n, iou=0.0, r50=0, r70=0, r90=0, q=0.0, frag=0, merge=0)
    if m and n:
        iou, cov_g, cov_p = iou_matrix([g['box'] for g in gts], [p['box'] for p in preds])
        gi, pi = linear_sum_assignment(-iou); matched = set()
        for g, p in zip(gi, pi):
            if iou[g, p] > 0:
                v = iou[g, p]; matched.add(p); r['iou'] += v
                r['r50'] += v >= 0.5; r['r70'] += v >= 0.7; r['r90'] += v >= 0.9
                r['q'] += poly_iou(gts[g]['poly'], quad(preds[p]))
        for p in range(m):
            if (cov_g[:, p] >= 0.5).sum() >= 2: r['merge'] += 1
            elif p not in matched and (cov_p[:, p] >= 0.5).any(): r['frag'] += 1
    r['exact'] = int(r['r70'] == n and r['frag'] == 0 and r['merge'] == 0)
    return r


def score(preds, labels, pids):
    t = {}
    for pid in pids:
        for k, v in score_page(preds.get(pid, []), labels[pid]).items(): t[k] = t.get(k, 0) + v
    n = max(t.get('gt', 0), 1)
    return dict(pages=len(pids), gt=t.get('gt', 0), mIoU=round(float(t.get('iou', 0)) / n, 4), R50=round(float(t.get('r50', 0)) / n, 4),
                R70=round(float(t.get('r70', 0)) / n, 4), R90=round(float(t.get('r90', 0)) / n, 4), qIoU=round(float(t.get('q', 0)) / n, 4),
                frag=int(t.get('frag', 0)), merge=int(t.get('merge', 0)), exact=int(t.get('exact', 0)))
