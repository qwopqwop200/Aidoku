"""Refit the S8 fill picker (fillPass2) on the colour GT with fold CV; compare with the shipped trees.
Run with the eval venv python (workspace.PYTHON: scikit-learn)."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import RUNS, data  # noqa: E402
import itertools, collections, sys, json, pickle
import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from errors import pairs, de
from cands import dump
from sim import FOLD
pre = str(RUNS / 'imp/rawdump')
P = pairs(pre); D = dump(pre)
blocks = {}
for p in P:
    k = (p['page'], p['block'])
    if k in D and k not in blocks: blocks[k] = (p, D[k])
rows = []  # (fold, key, X list, cores, gt)
for k, (p, d) in blocks.items():
    rows.append((FOLD[p['page']], k, np.array([c['x'] for c in d['cands']]), [c['core'] for c in d['cands']],
                 p['fill'], np.array([c['logit'] for c in d['cands']])))


def labels(cores, gt):
    ds = [de(c, gt) for c in cores]; j = int(np.argmin(ds))
    return None if ds[j] > 12 else np.array([1 if i == j else 0 for i in range(len(cores))])


def errors(model, folds):
    c = collections.Counter()
    for f, k, X, cores, gt, shipped in rows:
        if f not in folds: continue
        s = shipped if model is None else model.decision_function(X)
        c[f] += de(cores[int(np.argmax(s))], gt) > 12
    return c


def fit(folds, **hp):
    X, y = [], []
    for f, k, Xb, cores, gt, _ in rows:
        if f not in folds: continue
        l = labels(cores, gt)
        if l is None: continue
        X.append(Xb); y.append(l)
    m = GradientBoostingClassifier(random_state=0, **hp)
    m.fit(np.vstack(X), np.concatenate(y))
    return m


TRAIN = ['f2', 'f3', 'f4']
if __name__ == '__main__':
  base = errors(None, TRAIN + ['dev', 'test'])
  print('shipped', dict(base), flush=True)
  grid = list(itertools.product([100, 200, 400], [2, 3, 4], [0.05, 0.1], [1.0, 0.8]))
  res = []
  for n, depth, lr, sub in grid:
      hp = dict(n_estimators=n, max_depth=depth, learning_rate=lr, subsample=sub)
      cv = 0
      for hold in TRAIN:
          m = fit([f for f in TRAIN if f != hold], **hp)
          cv += errors(m, [hold])[hold]
      res.append((cv, hp)); print(cv, hp, flush=True)
  res.sort(key=lambda r: r[0])
  best = res[0][1]
  # shipped trees are fit on all TRAIN (in-sample there); for a fair CV reference use leave-one-fold-out of the new model only.
  m = fit(TRAIN, **best)
  e = errors(m, ['dev', 'test'])
  print('best', best, 'cv', res[0][0], '| dev', e['dev'], 'test', e['test'], '| shipped dev', base['dev'], 'test', base['test'])
  pickle.dump((best, m), open(data('colorfix', 'fill_model.pkl'), 'wb'))
