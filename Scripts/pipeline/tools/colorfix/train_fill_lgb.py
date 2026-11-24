"""Refit the S8 fill picker (fillPass2) with LightGBM (binary and lambdarank) on the colour GT, leave-one-fold-out
CV on TRAIN folds; saves the best choice for export_fill.py."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import RUNS, data  # noqa: E402
import itertools, collections, pickle, warnings
import numpy as np, lightgbm as lgb
warnings.filterwarnings('ignore')
from errors import pairs, de
from cands import dump
from sim import FOLD
TRAIN = ['f2', 'f3', 'f4']
PRE = str(RUNS / 'imp/rawdump')
P = pairs(PRE); D = dump(PRE)
rows = []  # (fold, key, candidate features, candidate core colours, GT fill, shipped logits)
seen = set()
for p in P:
    k = (p['page'], p['block'])
    if k in D and k not in seen:
        seen.add(k); cands = D[k]['cands']
        rows.append((FOLD[p['page']], k, np.array([c['x'] for c in cands]), [c['core'] for c in cands], p['fill'],
                     np.array([c['logit'] for c in cands])))


def labels(cores, gt):
    """One-hot on the candidate nearest the GT fill, None when none is within dE 12."""
    ds = [de(c, gt) for c in cores]; j = int(np.argmin(ds))
    return None if ds[j] > 12 else np.array([1 if i == j else 0 for i in range(len(cores))])


def training_set(folds):
    X, y, g = [], [], []
    for f, k, Xb, cores, gt, _ in rows:
        if f not in folds: continue
        l = labels(cores, gt)
        if l is None: continue
        X.append(Xb); y.append(l); g.append(len(l))
    return np.vstack(X), np.concatenate(y), g


def errors(model, folds):
    c = collections.Counter()
    for f, k, X, cores, gt, shipped in rows:
        if f not in folds: continue
        c[f] += de(cores[int(np.argmax(model.predict(X, raw_score=True)))], gt) > 12
    return c


def fit(folds, obj, **hp):
    X, y, g = training_set(folds)
    if obj == 'rank':
        m = lgb.LGBMRanker(objective='lambdarank', random_state=0, n_jobs=4, verbose=-1, **hp); m.fit(X, y, group=g)
    else:
        m = lgb.LGBMClassifier(random_state=0, n_jobs=4, verbose=-1, **hp); m.fit(X, y)
    return m


if __name__ == '__main__':
    res = []
    for obj, leaves, n, lr, mcs in itertools.product(['binary', 'rank'], [4, 8, 16], [100, 300], [0.05, 0.1], [10, 30]):
        hp = dict(num_leaves=leaves, n_estimators=n, learning_rate=lr, min_child_samples=mcs)
        cv = sum(errors(fit([f for f in TRAIN if f != h], obj, **hp), [h])[h] for h in TRAIN)
        res.append((cv, obj, hp)); print(cv, obj, hp, flush=True)
    res.sort(key=lambda r: r[0])
    cv, obj, hp = res[0]
    m = fit(TRAIN, obj, **hp); e = errors(m, ['dev', 'test'])
    print('BEST', obj, hp, 'cv', cv, '| dev', e['dev'], 'test', e['test'])
    pickle.dump((obj, hp), open(data('colorfix', 'fill_lgb_best.pkl'), 'wb'))
