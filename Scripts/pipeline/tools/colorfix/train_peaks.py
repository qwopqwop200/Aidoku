"""Train the density-peak ranker on Swift-dumped options (dump3), fold CV, and export as the 4th forest."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import RUNS, WEIGHTS  # noqa: E402
import itertools, collections, warnings
import numpy as np, lightgbm as lgb
warnings.filterwarnings('ignore')
from errors import pairs, de
from cands import dump
from sim import FOLD
import forest
PRE = str(RUNS / 'imp/dump3'); TRAIN = ['f2', 'f3', 'f4']
BIN = str(WEIGHTS)
P = pairs(PRE); D = dump(PRE)
data = []; seen = set(); reach = collections.Counter()
for p in P:
    k = (p['page'], p['block'])
    if k not in D or k in seen or 'peaks' not in D[k]: continue
    seen.add(k); pk = D[k]['peaks']
    data.append((FOLD[p['page']], pk['colours'], np.array(pk['x'], dtype=np.float64), p['fill']))
    reach[(de(pk['colours'][0], p['fill']) <= 12, min(de(c, p['fill']) for c in pk['colours']) <= 12)] += 1
print('(pick ok, any option ok):', dict(reach))


def labels(cols, gt):
    ds = [de(c, gt) for c in cols]
    if ds[0] <= 12: j = 0
    else:
        j = int(np.argmin(ds))
        if ds[j] > 12: return None
    return np.array([1 if i == j else 0 for i in range(len(cols))])


def fit(folds, **hp):
    X, y, g = [], [], []
    for f, cols, Xb, gt in data:
        if f not in folds: continue
        l = labels(cols, gt)
        if l is None: continue
        X.append(Xb); y.append(l); g.append(len(l))
    m = lgb.LGBMRanker(objective='lambdarank', random_state=0, n_jobs=4, verbose=-1, **hp)
    m.fit(np.vstack(X), np.concatenate(y), group=g); return m


def errors(m, folds):
    e = collections.Counter()
    for f, cols, Xb, gt in data:
        if f in folds: e[f] += de(cols[0 if m is None else int(np.argmax(m.predict(Xb)))], gt) > 12
    return e


F = TRAIN + ['dev', 'test']
b = errors(None, F); print('pick only', {f: b[f] for f in F})
res = []
for l, n, r, s in itertools.product([4, 8, 16], [50, 100, 300], [0.05, 0.1], [10, 30]):
    hp = dict(num_leaves=l, n_estimators=n, learning_rate=r, min_child_samples=s)
    res.append((sum(errors(fit([f for f in TRAIN if f != h], **hp), [h])[h] for h in TRAIN), hp))
res.sort(key=lambda t: t[0]); print('top cv', [c for c, _ in res[:6]])
cv, hp = res[0]; m = fit(TRAIN, **hp); e = errors(m, ['dev', 'test'])
print('BEST cv', cv, hp, '| dev', e['dev'], 'test', e['test'])

trees = forest.flatten(m.booster_)
agree = sum(int(np.argmax([forest.logit(trees, x) for x in Xb])) == int(np.argmax(m.predict(Xb))) for _, _, Xb, _ in data)
print('pick parity', agree, '/', len(data))
if '--write' in sys.argv:
    forest.write(BIN, 3, trees); print('wrote 4th forest:', len(trees[0]), 'trees', len(trees[1]), 'nodes')
