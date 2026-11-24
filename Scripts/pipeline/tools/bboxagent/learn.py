"""Learned along-axis line-end offsets (LightGBM), fold CV on train; numbers only.
usage: learn.py RUN_PREFIX DUMP FEATS.pkl[,FEATS2.pkl]"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import EVAL  # noqa: E402
import glob, json, os, pickle, collections
import numpy as np, lightgbm as lgb
from boxscore import gt, FOLD, page_stats, iou, linear_sum_assignment
BINS = np.array([(k - 6) / 10 for k in range(19)])  # exact in Swift as Double(k - 6) / 10
ALL = os.environ.get('ALL') == '1'


def finals(prefix):
    out = {}
    for s in ('dev', 'train', 'test'):
        for f in glob.glob(f'{prefix}_{s}/pages/*.json'):
            r = json.load(open(f))
            out[r['pageID']] = [tuple(map(tuple, l['bounds'])) for b in r['blocks'] for l in b['lines']]
    return out


def stats(B):
    G = gt(); c = collections.defaultdict(float)
    for pid, L in B.items():
        page_stats(G.get(pid, []), L, [], c, FOLD[pid])
    return c


def miou(c, folds):
    return np.concatenate([np.array(c.get((x, 'ious'), [])) for x in folds]).mean()


def end_feats(it, which, rf, others):
    T = it['T']; P = it['P'].astype(np.float32)
    if which == 1: pos, sgn = it['end'], 1
    else: pos, sgn = it['start'], -1
    f = []
    for di in (0, 1, 3):
        for k in range(len(BINS)):
            b, b1 = (k - 6) / 10, (k - 5) / 10
            a = pos + sgn * b * T; c = pos + sgn * b1 * T
            lo, hi = int(round(min(a, c))), int(round(max(a, c)))
            lo, hi = max(0, lo), min(P.shape[1], max(lo + 1, hi))
            f.append(float(P[di, lo:hi].mean()) if hi > lo else 0.0)
    x0, y0, x1, y1 = it['box']; v = it['vert']
    L = (y1 - y0) if v else (x1 - x0)
    endc = (y1 if which else y0) if v else (x1 if which else x0)
    # RF: along-axis distance from end to containing region's edge (T units); 9 if none
    def rfd(kind):
        best = 9.0
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        for k, q in rf:
            if k != kind or not (q[0] <= cx <= q[2] and q[1] <= cy <= q[3]): continue
            edge = (q[3] if which else q[1]) if v else (q[2] if which else q[0])
            best = min(best, sgn * (edge - endc) / T)
        return best
    # nearest other line beyond this end in the same column/row (cross overlap >= 0.3T)
    gap = 9.0
    for o in others:
        if o is it['box']: continue
        cross = (min(x1, o[2]) - max(x0, o[0])) if v else (min(y1, o[3]) - max(y0, o[1]))
        if cross < 0.3 * T: continue
        d = ((o[1] - y1) if which else (y0 - o[3])) if v else ((o[0] - x1) if which else (x0 - o[2]))
        if d > -0.3 * T: gap = min(gap, d / T)
    return f + [T, L / T, it['score'], float(v), float(which), rfd('text'), rfd('balloon'), gap, it['bg']]


def build(prefix, dump, feats):
    F = finals(prefix); G = gt(); rows = []
    for pid, fin in F.items():
        if pid not in feats: continue
        d = json.load(open(os.path.join(dump, pid + '.json')))
        rf = [(q['kind'], (q['bounds'][0][0], q['bounds'][0][1], q['bounds'][0][0] + q['bounds'][1][0], q['bounds'][0][1] + q['bounds'][1][1]))
              for q in d['layout'] if q['score'] >= 0.5]
        idx = {(round(it['box'][0], 3), round(it['box'][1], 3)): it for it in feats[pid]}
        its = [idx[(round(x, 3), round(y, 3))] for (x, y), _ in fin] if not ALL else list(feats[pid])
        others = [it['box'] for it in feats[pid]]
        g = G.get(pid, []); tgt = {}
        if g and its:
            M = np.array([[iou(a, it['box']) for it in its] for a in g]); ri, ci = linear_sum_assignment(-M)
            for i, j in zip(ri, ci):
                if M[i, j] >= 0.5: tgt[j] = g[i]
        for j, it in enumerate(its):
            for which in (0, 1):
                y = np.nan
                if j in tgt:
                    a = tgt[j]; v = it['vert']; x0, y0, x1, y1 = it['box']
                    y = (((a[3] - y1) if which else (y0 - a[1])) if v else ((a[2] - x1) if which else (x0 - a[0]))) / it['T']
                rows.append((pid, j, which, end_feats(it, which, rf, others), y))
    return F, feats, rows


def apply(F, feats, rows, pred, k):
    adj = collections.defaultdict(lambda: [0.0, 0.0])
    for (pid, j, which, _, _), p in zip(rows, pred): adj[pid, j][which] = p * k
    out = {}
    for pid, fin in F.items():
        if pid not in feats: continue
        idx = {(round(it['box'][0], 3), round(it['box'][1], 3)): n for n, it in enumerate(feats[pid])}
        L = []
        for j, ((x, y), _) in enumerate(fin):
            n = idx[(round(x, 3), round(y, 3))]; it = feats[pid][n]
            x0, y0, x1, y1 = it['box']; T = it['T']; a0, a1 = adj[pid, n if ALL else j]
            L.append((x0, y0 - a0 * T, x1, y1 + a1 * T) if it['vert'] else (x0 - a0 * T, y0, x1 + a1 * T, y1))
        out[pid] = L
    return out


if __name__ == '__main__':
    prefix, dump, fp = sys.argv[1:4]
    feats = {}
    for p in fp.split(','): feats.update(pickle.load(open(p, 'rb')))
    F, feats, rows = build(prefix, dump, feats)
    pickle.dump(rows, open(EVAL / 'bboxagent/rows.pkl', 'wb'))
    X = np.array([r[3] for r in rows], np.float32); Y = np.array([r[4] for r in rows]); fo = np.array([FOLD[r[0]] for r in rows])
    print('rows', len(rows), 'labelled', np.isfinite(Y).sum())
    prm = dict(objective='huber', alpha=0.3, learning_rate=0.05, num_leaves=15, min_data_in_leaf=40, feature_fraction=0.8,
               bagging_fraction=0.8, bagging_freq=1, verbose=-1, seed=1)
    pred = np.zeros(len(rows))
    tr = ['f2', 'f3', 'f4']
    for f in tr:
        m = np.isin(fo, tr) & (fo != f) & np.isfinite(Y)
        b = lgb.train(prm, lgb.Dataset(X[m], np.clip(Y[m], -1, 1.5)), 300)
        pred[fo == f] = b.predict(X[fo == f])
    m = np.isin(fo, tr) & np.isfinite(Y)
    b = lgb.train(prm, lgb.Dataset(X[m], np.clip(Y[m], -1, 1.5)), 300)
    ho = ~np.isin(fo, tr); pred[ho] = b.predict(X[ho])
    b.save_model('endreg.txt')
    base = stats(apply(F, feats, rows, pred, 0.0))
    folds = ['f2', 'f3', 'f4', 'dev', 'test']
    print('base', {f: round(miou(base, [f]), 4) for f in folds})
    for k in (0.25, 0.5, 0.75, 1.0):
        c = stats(apply(F, feats, rows, pred, k)); print('k', k, {f: round(miou(c, [f]), 4) for f in folds})
    # constant
    for cst in (0.03, 0.05, 0.08):
        c = stats(apply(F, feats, rows, np.full(len(rows), cst), 1.0)); print('const', cst, {f: round(miou(c, [f]), 4) for f in folds})
    pickle.dump(pred, open(EVAL / 'bboxagent/pred.pkl', 'wb'))
    if ALL:
        out = collections.defaultdict(list); adj = collections.defaultdict(lambda: [0.0, 0.0])
        for (pid, j, which, _, _), p in zip(rows, pred): adj[pid, j][which] = float(p)
        for pid in feats:
            for j, it in enumerate(feats[pid]):
                x0, y0, x1, y1 = it['box']; a = adj[pid, j]
                out[pid].append([x0, y0, x1 - x0, y1 - y0, a[0] * it['T'], a[1] * it['T']])
        json.dump(out, open(os.environ.get('OUT', 'adjust.json'), 'w'))
