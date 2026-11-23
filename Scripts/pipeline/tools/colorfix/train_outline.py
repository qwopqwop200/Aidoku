"""Outline presence: LightGBM on the picked fill's outline observation + page median score; fold CV vs the shipped rule."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import RUNS  # noqa: E402
import collections, itertools, warnings
import numpy as np, lightgbm as lgb
warnings.filterwarnings('ignore')
from errors import pairs, de
from cands import dump
from sim import FOLD
P = pairs(str(RUNS / 'imp/dump3')); D = dump(str(RUNS / 'imp/dump3'))
CUR = {p['id']: p for p in pairs(str(RUNS / 'imp/colourpeaks'))}
OP = [0.4094924613695863, 0.19954881908897934, -0.9404877504298349]
pages = collections.defaultdict(list)
for (pid, bid), d in D.items():
    pick = max(d['cands'], key=lambda c: c['logit'])
    if 'oscore' in pick: pages[pid].append(pick['oscore'])
rows = []; seen = set()
for p in P:
    k = (p['page'], p['block'])
    if k not in D or k in seen: continue
    seen.add(k); pick = max(D[k]['cands'], key=lambda c: c['logit'])
    if 'ox' not in pick: continue
    pm = float(np.median(pages[p['page']]))
    vis = p['outline'] and p['bg'] is not None and de(p['stroke'], p['bg']) >= 10
    shipped = OP[0] * pick['oscore'] + OP[1] * pm + OP[2] >= 0
    rows.append((FOLD[p['page']], list(pick['ox']) + [pick['oscore'], pm], int(p['outline']), vis, shipped))
fold = np.array([r[0] for r in rows]); X = np.array([r[1] for r in rows]); y = np.array([r[2] for r in rows])
vis = np.array([r[3] for r in rows]); ship = np.array([r[4] for r in rows])
F = ['f2', 'f3', 'f4', 'dev', 'test']; TRAIN = F[:3]
def errs(pred, f):
    m = fold == f; wrong = pred[m] != y[m]
    visible = (wrong & (vis[m] | (pred[m] == 1)))  # an invisible outline missed is harmless; an invented one is not
    return int(wrong.sum()), int(visible.sum())
print('shipped rule ', {f: errs(ship.astype(int), f) for f in F}, '(all wrong, visible wrong)')
best = None
for l, n, lr, mcs in itertools.product([4, 8, 16], [100, 300], [0.05, 0.1], [10, 30]):
    hp = dict(num_leaves=l, n_estimators=n, learning_rate=lr, min_child_samples=mcs)
    oof = np.zeros(len(y))
    for h in TRAIN:
        tr = np.isin(fold, [f for f in TRAIN if f != h]); te = fold == h
        oof[te] = lgb.LGBMClassifier(random_state=0, n_jobs=4, verbose=-1, **hp).fit(X[tr], y[tr]).predict_proba(X[te])[:, 1]
    for t in [0.3, 0.4, 0.5, 0.6]:
        s = sum(errs((oof >= t).astype(int), f)[1] for f in TRAIN)
        if best is None or s < best[0]: best = (s, hp, t, oof.copy())
s, hp, t, oof = best
print('train CV     ', {f: errs((oof >= t).astype(int), f) for f in TRAIN}, hp, 't', t)
m = lgb.LGBMClassifier(random_state=0, n_jobs=4, verbose=-1, **hp).fit(X[np.isin(fold, TRAIN)], y[np.isin(fold, TRAIN)])
pr = (m.predict_proba(X)[:, 1] >= t).astype(int)
print('held-out     ', {f: errs(pr, f) for f in ['dev', 'test']})
