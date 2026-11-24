"""fit.py NAME COLS NL NTREES: CV-fit end regressor on feature subset, write adjust-NAME.json (train: fold-out preds; dev/test: all-train model)."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import EVAL  # noqa: E402
import pickle, json, collections, numpy as np, lightgbm as lgb, os
os.environ['ALL'] = '1'
from learn import BINS, FOLD
rows = pickle.load(open(os.environ.get('ROWS', EVAL / 'bboxagent/rows.pkl'), 'rb')); feats = pickle.load(open(os.environ.get('FEATS', EVAL / 'bboxagent/feats-all.pkl'), 'rb'))
names = [f'p{d}_{b:.1f}' for d in (0, 1, 3) for b in BINS] + ['T', 'len', 'score', 'vert', 'which', 'rfText', 'rfBalloon', 'gap', 'bg']
SETS = {'all': names, 'pix': [n for n in names if n not in ('score', 'rfText', 'rfBalloon', 'gap')],
        'nogap': [n for n in names if n != 'gap'], 'noscore': [n for n in names if n != 'score'], 'norf': [n for n in names if n not in ('rfText', 'rfBalloon')],
        'core': [n for n in names if n not in ('gap', 'score')], 'core13': [n for n in names if n not in ('gap', 'score') and not n.startswith('p0')],
        'pix1': [n for n in names if (n.startswith('p1') or n.startswith('p3')) or n in ('T', 'len', 'vert', 'which', 'bg')]}
name, cols, nl, nt = sys.argv[1], SETS[sys.argv[2]], int(sys.argv[3]), int(sys.argv[4])
ci = [names.index(c) for c in cols]
X = np.array([r[3] for r in rows], np.float32)[:, ci]; Y = np.array([r[4] for r in rows]); fo = np.array([FOLD[r[0]] for r in rows])
prm = dict(objective='huber', alpha=0.3, learning_rate=float(os.environ.get('LR', 0.1 if nt <= 100 else 0.05)), num_leaves=nl, min_data_in_leaf=40, feature_fraction=0.8,
           bagging_fraction=0.8, bagging_freq=1, verbose=-1, seed=1)
tr = ['f2', 'f3', 'f4']; pred = np.zeros(len(rows))
for f in tr:
    m = np.isin(fo, tr) & (fo != f) & np.isfinite(Y)
    pred[fo == f] = lgb.train(prm, lgb.Dataset(X[m], np.clip(Y[m], -1, 1.5)), nt).predict(X[fo == f])
m = np.isin(fo, tr) & np.isfinite(Y); b = lgb.train(prm, lgb.Dataset(X[m], np.clip(Y[m], -1, 1.5)), nt)
ho = ~np.isin(fo, tr); pred[ho] = b.predict(X[ho]); b.save_model(f'model-{name}.txt')
pickle.dump((cols, prm, nt), open(EVAL / f'bboxagent/model-{name}.pkl', 'wb'))
adj = collections.defaultdict(lambda: [0.0, 0.0])
for (pid, j, which, _, _), p in zip(rows, pred): adj[pid, j][which] = float(p)
out = collections.defaultdict(list)
for pid in feats:
    for j, it in enumerate(feats[pid]):
        x0, y0, x1, y1 = it['box']; a = adj[pid, j]
        out[pid].append([x0, y0, x1 - x0, y1 - y0, a[0] * it['T'], a[1] * it['T']])
json.dump(out, open(f'adjust-{name}.json', 'w'))
lab = np.isfinite(Y)
for f in tr + ['dev', 'test']:
    mm = lab & (fo == f); print(f, 'MAE base', np.abs(np.clip(Y[mm], -1, 1.5)).mean().round(4), 'model', np.abs(np.clip(Y[mm], -1, 1.5) - pred[mm]).mean().round(4))
