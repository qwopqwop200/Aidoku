"""LightGBM refit of the S8 fill picker (binary and lambdarank) with leave-one-fold-out CV on TRAIN folds."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import data  # noqa: E402
import itertools, collections, pickle, warnings
import numpy as np, lightgbm as lgb
warnings.filterwarnings('ignore')
import train_fill as T  # reuses rows / labels / errors (runs no grid on import? see guard)
rows, labels = T.rows, T.labels
TRAIN = ['f2', 'f3', 'f4']


def data(folds):
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
        s = model.predict(X, raw_score=True) if hasattr(model, 'predict') and not isinstance(model, lgb.LGBMRanker) else model.predict(X)
        c[f] += T.de(cores[int(np.argmax(s))], gt) > 12
    return c


def fit(folds, obj, **hp):
    X, y, g = data(folds)
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
