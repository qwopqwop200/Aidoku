"""Fit the font-size correction on Swift-dumped features (fontdump), fold CV, export as the 5th forest."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import RUNS, WEIGHTS  # noqa: E402
import json, os, itertools, warnings
import numpy as np, lightgbm as lgb
warnings.filterwarnings('ignore')
import consistency_metrics as cm
from sim import FOLD
import forest
REG, _, SIZE = cm.gt()
PRE = str(RUNS / 'imp/fontdump')
BIN = str(WEIGHTS)
X_ = {}
for s in ('dev', 'train', 'test'):
    for line in open(f'{PRE}_{s}.log', errors='ignore'):
        if line.startswith('FONTDUMP '):
            r = json.loads(line[9:]); X_[(r['page'], r['block'])] = r['x']
rows = []
for s in ('dev', 'train', 'test'):
    d = f'{PRE}_{s}/pages'
    for f in os.listdir(d):
        r = json.load(open(os.path.join(d, f))); pid = r['pageID']
        for eid, (a, bb, c, e) in REG.get(pid, {}).items():
            if (pid, eid) not in SIZE: continue
            area = (c - a) * (e - bb); best, cov = None, 0
            for blk in r['blocks']:
                (x, y), (w, h) = blk['bounds']
                ix = max(0, min(x + w, c) - max(x, a)) * max(0, min(y + h, e) - max(y, bb)) / max(1e-9, area)
                if ix > cov: best, cov = blk, ix
            if best is None or cov < 0.5 or (pid, best['id']) not in X_: continue
            x = X_[(pid, best['id'])]
            rows.append((FOLD[pid], x, np.log(SIZE[(pid, eid)] / x[0])))
F = ['f2', 'f3', 'f4', 'dev', 'test']; TRAIN = F[:3]
fold = np.array([r[0] for r in rows]); X = np.array([r[1] for r in rows], float); y = np.array([r[2] for r in rows])
def report(pred, folds, name):
    print(name, ' | '.join(f'{f}: med {np.median(e):.3f} >10% {(e > .1).mean():.3f} >20% {(e > .2).mean():.3f}'
                           for f in folds for e in [np.abs(np.exp(y[fold == f] - pred[fold == f]) - 1)]))
report(np.zeros(len(y)), F, 'app      ')
best = None
for l, n, lr, mcs in itertools.product([4, 8, 16], [100, 300], [0.03, 0.1], [20, 50]):
    hp = dict(num_leaves=l, n_estimators=n, learning_rate=lr, min_child_samples=mcs)
    oof = np.zeros(len(y))
    for h in TRAIN:
        tr = np.isin(fold, [f for f in TRAIN if f != h]); te = fold == h
        oof[te] = lgb.LGBMRegressor(random_state=0, n_jobs=4, verbose=-1, objective='l1', **hp).fit(X[tr], y[tr]).predict(X[te])
    m = np.isin(fold, TRAIN); score = (np.abs(np.exp(y[m] - oof[m]) - 1) > 0.1).mean()
    if best is None or score < best[0]: best = (score, hp, oof.copy())
score, hp, oof = best
report(oof, TRAIN, 'train CV ')
model = lgb.LGBMRegressor(random_state=0, n_jobs=4, verbose=-1, objective='l1', **hp).fit(X[np.isin(fold, TRAIN)], y[np.isin(fold, TRAIN)])
report(model.predict(X), ['dev', 'test'], 'held-out ')
print('hp', hp)
trees = forest.flatten(model.booster_)
diff = max(abs(forest.logit(trees, x) - p) for x, p in zip(X, model.predict(X)))
print('max |logit diff| exported vs lightgbm', diff)
if '--write' in sys.argv:
    forest.write(BIN, 4, trees); print('wrote 5th forest', len(trees[0]), 'trees')  # after 3 forests + fillPeaks
