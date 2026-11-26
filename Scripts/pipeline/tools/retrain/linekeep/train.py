"""Retrain the S3 line-keep gate (PipelineLineKeep.swift, Resources/Translation/PipelineLineKeep.json).

  train.py RUN_PREFIX [--out PATH] [--check] [--eval]

Input: a PRE-GATE run (RUN_PREFIX_{train,dev,test}, saved with --save-stages). stages/ID.front.json `recognized`
must hold the S3 lines after the 0.30 confidence cut but before PipelineLineKeep.filter, plus `layout` (S1) and
pages/ID.json width/height. The gate itself only runs on the fresh S3 path, so a gated run cannot be un-gated.
Make a pre-gate run with S1-S4 `--ocr-only --save-stages` while PipelineLineKeep.json is absent from
$AIDOKU_PIPELINE_ROOT/Aidoku/Resources/Translation (the host reads it there; without it the gate keeps every line).
The resource was trained on runs/speed2/asm830 (a pre-gate S1-S4 run).

Method (port-eval/stageopt/filter/port): LightGBM, 7 leaves x 300 trees, 34 features (features.py), fit on TRAIN
pages, label = >= 50% of the line's area inside GT line boxes (individual_premerge_bbox, canonical).
Threshold: for each fold scheme (page = manifest folds 2/3/4, size = greedy page-size groups, chunk = page-id
thirds) the largest grid value with zero extra GT-line losses on held-out train pages; the joint threshold is the
minimum over schemes. A GT line counts as covered when >= 50% of its 16x16 sample grid lies inside kept lines;
"extra lost" = GT lines covered by all pre-gate lines but not by the kept ones.
"""
import argparse, collections, json, os, re, sys, tempfile, time
from pathlib import Path
import numpy as np
import lightgbm as lgb

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1])); sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent))
import workspace as ws  # noqa: E402
import features as PF  # noqa: E402
import augment as AUG  # noqa: E402

RESOURCE = 'Aidoku/Resources/Translation/PipelineLineKeep.json'
SPEC = {
    'name': 'linekeep',
    'resource': [RESOURCE],
    'stage': 'S3keep',
    'inputs': 'front.unrefined (else front.recognized) + front.layout + pages/ID.json width/height of a PRE-GATE run: '
              'S3 lines after the 0.30 confidence cut, before PipelineLineKeep.filter (asm830; regenerate with S1-S4 '
              '--ocr-only --save-stages and the tuning knob lineKeepScale = 0); GT individual_premerge_bbox',
    'input_run': {'env': {'AIDOKU_PIPELINE_TUNING': '{"lineKeepScale": 0}'}},
    'needs_full': False,
    'rerun_from': 's4',
    'rerun_note': 'the gate runs only on the fresh S3 path; --from-stages reuses saved lines ungated, so a new gate '
                  'needs a fresh S1-S4 run before anything downstream is rerun',
    # --augment default proposal (train.py applies it only when --augment is given; see aug_eval.py for the study).
    # Not adopted (2026-11-26): jitter=1.0x2 left 10-30% less junk at zero real loss, but lost a GT line on jittered
    # test pages; the gate must not drop text. Pass --augment jitter=1.0x2 to try it.
    'augment': None,
}
P = dict(num_leaves=7, n_estimators=300, min_child_samples=60, learning_rate=0.05, subsample=0.8, subsample_freq=1,
         colsample_bytree=0.8, reg_lambda=1.0, n_jobs=1, verbose=-1)
GRID = np.geomspace(1e-5, 0.5, 200)
N = 16  # GT sample grid per side


# ---------------- data ----------------
def gt_lines():
    """{page_id: [GT line boxes]} from canonical individual_premerge_bbox records, cached per GT file version."""
    st = os.stat(ws.GT); key = f'{ws.GT}:{st.st_size}:{st.st_mtime_ns}'
    cache = ws.data('retrain', 'linekeep', 'gt_lines.json')
    if cache.exists():
        c = json.load(open(cache))
        if c.get('key') == key:
            return c['lines']
    out = collections.defaultdict(list)
    for r in json.load(open(ws.GT))['records']:
        if r['scope'] == 'individual_premerge_bbox' and r['status'] == 'canonical':
            P_ = r['label']['polygon']; xs = [p['x'] for p in P_]; ys = [p['y'] for p in P_]
            out[r['page_id']].append([min(xs), min(ys), max(xs), max(ys)])
    json.dump({'key': key, 'lines': out}, open(cache, 'w'))
    return out


def area(b):
    return max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])


def inter(a, b):
    return max(0.0, min(a[2], b[2]) - max(a[0], b[0])) * max(0.0, min(a[3], b[3]) - max(a[1], b[1]))


def is_text(box, gts):
    A = area(box)
    return A > 0 and min(1.0, sum(inter(box, g) for g in gts) / A) >= 0.5


def samples(g):
    xs = g[0] + (np.arange(N) + 0.5) / N * (g[2] - g[0]); ys = g[1] + (np.arange(N) + 0.5) / N * (g[3] - g[1])
    X, Y = np.meshgrid(xs, ys)
    return X.ravel(), Y.ravel()


def masks(box, gts, S):
    out = {}
    for k, g in enumerate(gts):
        if inter(box, g) <= 0:
            continue
        X, Y = S[k]
        m = (X >= box[0]) & (X <= box[2]) & (Y >= box[1]) & (Y <= box[3])
        if m.any():
            out[k] = m
    return out


def prefix_path(prefix):
    p = Path(prefix)
    return p if p.is_absolute() or Path(f'{p}_train').exists() else ws.RUNS / p


def make_page(p, lines, layout, W, H, gts, **kw):
    S = [samples(g) for g in gts]
    X = np.array(PF.page_rows(lines, layout, W, H), float).reshape(-1, len(PF.NAMES))
    return dict(page=p['page_id'], split=p['split'], fold=p['fold'], W=W, H=H, X=X, n=len(lines),
                y=np.array([is_text(l['box'], gts) for l in lines], bool),
                masks=[masks(l['box'], gts, S) for l in lines], ngt=len(gts), **kw)


def load(prefix, raw=False):
    prefix = prefix_path(prefix); G = gt_lines(); pages = []
    for p in json.load(open(ws.MANIFEST))['pages']:  # manifest order (LightGBM row order matters)
        d = Path(f"{prefix}_{p['split']}")
        f = d / 'stages' / f"{p['page_id']}.front.json"
        if not f.exists():
            continue
        pj = json.load(open(d / 'pages' / f"{p['page_id']}.json"))
        lines, layout = PF.front_lines(json.load(open(f)))
        gts = [tuple(g) for g in G.get(p['page_id'], [])]
        pg = make_page(p, lines, layout, pj['width'], pj['height'], gts)
        if raw:  # kept for augmentation (re-featurising jittered geometry)
            pg.update(meta=p, lines=lines, layout=layout, gts=gts)
        pages.append(pg)
    if not pages:
        sys.exit(f'no stages/*.front.json under {prefix}_{{train,dev,test}}')
    return pages


# ---------------- augmentation (--augment) ----------------
def parse_augment(spec):
    """'mix=RUN,RUN;jitter=SCALExN[;res=RUN]' -> dict(mix=[...], scale, copies, res). Parts separated by ';' or ' '."""
    out = dict(mix=[], scale=0.0, copies=0, res=None, seed=1000)
    for part in re.split(r'[; ]+', (spec or '').strip()):
        if not part:
            continue
        k, v = part.split('=', 1)
        if k == 'mix':
            out['mix'] = [x for x in v.split(',') if x]
        elif k == 'jitter':
            sc, n = v.split('x'); out['scale'], out['copies'] = float(sc), int(n)
        elif k in ('res', 'seed'):
            out[k] = v if k == 'res' else int(v)
        else:
            raise SystemExit(f'--augment: unknown part {part!r}')
    return out


def line_key(pg):
    return pg['X'].tobytes()


def jitter_page(pg, J, keep_labels=True):
    """A copy of a raw page with every S3 line box jittered and the features recomputed from the new geometry.
    keep_labels: y (and masks) stay those of the original boxes (training rows); else they follow the new boxes
    (an evaluation copy: 'would the gate lose a real line if S3 drew these boxes')."""
    lines = [dict(l, box=J.box(l['box'], bool(l['vertical']))) for l in pg['lines']]
    q = make_page(pg['meta'], lines, pg['layout'], pg['W'], pg['H'], pg['gts'], aug=True)
    if keep_labels:
        q['y'], q['masks'] = pg['y'], pg['masks']
    return q


def augment_pages(pages, prefix, aug, log=print):
    """Extra TRAIN rows: pages of the mix runs that differ from the primary's (identical pages are not duplicated),
    then `copies` jittered copies of every distinct train page (fixed seeds). Each extra page keeps its page id, so
    every LOFO scheme puts all copies of a page on the same side as the original."""
    base = [p for p in pages if p['split'] == 'train']
    seen = {(p['page'], line_key(p)) for p in base}
    extra = []
    for run in aug['mix']:
        if prefix_path(run) == prefix_path(prefix):
            continue
        add = 0
        for q in load(run, raw=True):
            if q['split'] == 'train' and (q['page'], line_key(q)) not in seen:
                seen.add((q['page'], line_key(q))); q['aug'] = True; extra.append(q); add += 1
        log(f'augment mix {run}: {add} distinct train pages added')
    if aug['copies']:
        res = AUG.residuals(str(prefix_path(aug['res'] or prefix)))
        src = base + [q for q in extra]
        for k in range(aug['copies']):
            J = AUG.Jitter(res, aug['scale'], seed=aug['seed'] + k)
            extra += [jitter_page(pg, J) for pg in src]
        log(f"augment jitter {aug['scale']} x {aug['copies']} (res {aug['res'] or prefix}): {len(extra)} extra pages")
    return extra


# ---------------- metric / threshold ----------------
def covered(masks_, keep):
    acc = {}
    for m, a in zip(masks_, keep):
        if a:
            for g, v in m.items():
                acc[g] = acc[g] | v if g in acc else v
    return {g for g, v in acc.items() if v.sum() >= 0.5 * N * N}


def score(pages, probs, t):
    kept = kt = cov = ngt = extra = junk_app = n_app = 0
    for pg, p in zip(pages, probs):
        k = p >= t
        full = covered(pg['masks'], np.ones(pg['n'], bool)); c = covered(pg['masks'], k)
        kept += k.sum(); kt += (k & pg['y']).sum(); cov += len(c); ngt += pg['ngt']; extra += len(full - c)
        n_app += pg['n']; junk_app += (~pg['y']).sum()
    return dict(P=float(kt / max(kept, 1)), R=cov / max(ngt, 1), missed=int(ngt - cov), junk=int(kept - kt),
                extra_lost=int(extra), ngt=int(ngt), kept=int(kept), lines=int(n_app), app_junk=int(junk_app),
                app_P=float((n_app - junk_app) / max(n_app, 1)), pages=len(pages))


def strict(pages, probs):
    """Largest grid threshold with zero extra GT-line losses (binary search, as in the method)."""
    lo, hi, best = 0, len(GRID) - 1, 0.0
    while lo <= hi:
        mid = (lo + hi) // 2
        if score(pages, probs, GRID[mid])['extra_lost'] == 0:
            best = GRID[mid]; lo = mid + 1
        else:
            hi = mid - 1
    return float(best)


def schemes(train):
    out = {'page': {p['page']: p['fold'] for p in train}}
    n = collections.Counter()
    for p in train:
        n[(p['W'], p['H'])] += p['n']
    load_ = {f: 0 for f in (2, 3, 4)}; of = {}
    for s, c in sorted(n.items(), key=lambda kv: -kv[1]):
        f = min(load_, key=load_.get); of[s] = f; load_[f] += c
    out['size'] = {p['page']: of[(p['W'], p['H'])] for p in train}
    ids = sorted(p['page'] for p in train); k = len(ids)
    out['chunk'] = {pid: (2, 3, 4)[min(2, 3 * i // k)] for i, pid in enumerate(ids)}
    return out


# ---------------- model ----------------
def fit(pages):
    return lgb.LGBMClassifier(**P).fit(np.vstack([p['X'] for p in pages]), np.concatenate([p['y'] for p in pages]))


def export(m, t):
    d = m.booster_.dump_model()
    feature, threshold, left, right, value, roots = [], [], [], [], [], []
    for tree in d['tree_info']:
        def walk(node):
            i = len(feature); feature.append(-1); threshold.append(0.0); left.append(-1); right.append(-1); value.append(0.0)
            if 'leaf_value' in node:
                value[i] = node['leaf_value']
                return i
            assert node['decision_type'] == '<='
            feature[i] = node['split_feature']; threshold[i] = node['threshold']
            left[i] = walk(node['left_child']); right[i] = walk(node['right_child'])
            return i
        roots.append(walk(tree['tree_structure']))
    return dict(features=PF.NAMES, threshold=t, roots=roots, feature=feature, split=threshold, left=left, right=right,
                value=value, note='LightGBM binary: p = sigmoid(sum of leaf values); go left when x <= split')


def prob(J, X):
    """The app's evaluator (PipelineLineKeep.probability), vectorised: same comparisons, same summation order."""
    if not len(X):
        return np.zeros(0)
    L, R, F, S, V = (np.array(J[k]) for k in ('left', 'right', 'feature', 'split', 'value'))
    z = np.zeros(len(X)); rows = np.arange(len(X))
    for r in J['roots']:
        node = np.full(len(X), r)
        while (L[node] >= 0).any():
            inner = L[node] >= 0
            go = X[rows, np.maximum(F[node], 0)] <= S[node]
            node = np.where(inner, np.where(go, L[node], R[node]), node)
        z += V[node]
    return 1 / (1 + np.exp(-z))


def train_all(pages, log=print, extra=()):
    """extra: augmentation pages (train rows only; never scored, never used to pick the threshold)."""
    train = [p for p in pages if p['split'] == 'train']
    S = schemes(train); held = {}
    for name, fmap in S.items():
        probs = {}
        for g in (2, 3, 4):
            m = fit([p for p in train if fmap[p['page']] != g] + [p for p in extra if fmap[p['page']] != g])
            for p in train:
                if fmap[p['page']] == g:
                    probs[p['page']] = m.predict_proba(p['X'])[:, 1] if p['n'] else np.zeros(0)
        held[name] = [probs[p['page']] for p in train]
    per = {name: strict(train, held[name]) for name in S}
    tj = min(per.values())
    log('per-scheme strict ' + ' '.join(f'{k} {v:.6f}' for k, v in per.items()) + f' -> joint {tj:.6f}')
    m = fit(train + list(extra))
    J = export(m, tj)
    Xall = np.vstack([p['X'] for p in pages if p['n']])
    pl = m.predict_proba(Xall)[:, 1]; pw = prob(J, Xall)
    log(f'evaluator vs lightgbm: max |dp| {np.abs(pl - pw).max():.3g}, decision agree {((pl >= tj) == (pw >= tj)).mean():.6f}')
    return J, dict(train=train, schemes=S, held=held, per=per, t=tj)


def write(J, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f:
        json.dump(J, f, separators=(',', ':'))


def fmt(r):
    return (f"P {r['P']:.4f} (pre-gate {r['app_P']:.4f}) R {r['R']:.4f} missed {r['missed']} extra lost {r['extra_lost']} "
            f"junk {r['junk']} (pre-gate {r['app_junk']}) kept {r['kept']}/{r['lines']} GT {r['ngt']} pages {r['pages']}")


def evaluate(pages, J, info):
    train, S, held, tj = info['train'], info['schemes'], info['held'], info['t']
    for name in S:  # nested: threshold chosen without the held-out group, then scored on it
        e = 0
        for g in (2, 3, 4):
            out_ = [i for i, p in enumerate(train) if S[name][p['page']] != g]
            in_ = [i for i, p in enumerate(train) if S[name][p['page']] == g]
            tg = min(strict([train[i] for i in out_], [held[q][i] for i in out_]) for q in S)
            e += score([train[i] for i in in_], [held[name][i] for i in in_], tg)['extra_lost']
        print(f"train LOFO {name:5} t {tj:.6f}: {fmt(score(train, held[name], tj))} | nested extra lost {e}")
    for sp in ('dev', 'test'):
        ps = [p for p in pages if p['split'] == sp]
        if ps:
            print(f'{sp:16} t {tj:.6f}: {fmt(score(ps, [prob(J, p["X"]) for p in ps], tj))}')


def check(pages, J, current):
    C = json.load(open(current))
    a, b = json.dumps(J, separators=(',', ':')), json.dumps(C, separators=(',', ':'))
    if a == b:
        print('resource: identical')
    else:
        same = all(J[k] == C[k] for k in ('features', 'roots', 'feature', 'left', 'right'))
        d = max([abs(J['threshold'] - C['threshold'])] + ([float(np.abs(np.subtract(J[k], C[k])).max())
                                                          for k in ('split', 'value')] if same else []))
        print(f"resource: differs (tree structure {'same' if same else 'different'}, max abs diff {d:.3g}, "
              f"threshold {J['threshold']:.6g} vs {C['threshold']:.6g})")
    for sp in ('train', 'dev', 'test'):
        ps = [p for p in pages if p['split'] == sp and p['n']]
        if not ps:
            continue
        X = np.vstack([p['X'] for p in ps])
        kn, kc = prob(J, X) >= J['threshold'], prob(C, X) >= C['threshold']
        print(f'{sp:5} decision agreement {(kn == kc).mean():.6f} ({int((kn != kc).sum())} of {len(X)} lines differ)')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('run_prefix'); ap.add_argument('--out', default=str(ws.REPO / RESOURCE))
    ap.add_argument('--check', action='store_true'); ap.add_argument('--eval', action='store_true')
    ap.add_argument('--augment', default=None, help="off by default; e.g. 'mix=speed2/asm830,speed2/det830;jitter=1.0x2'")
    a = ap.parse_args()
    t0 = time.time()
    aug = parse_augment(a.augment) if a.augment else None
    pages = load(a.run_prefix, raw=bool(aug))
    current = ws.REPO / RESOURCE
    if current.exists():  # the current gate drops ~11% of pre-gate lines (asm830) but ~0.6% of a gated run (keep830)
        C = json.load(open(current)); X = np.vstack([p['X'] for p in pages if p['n']])
        drop = float((prob(C, X) < C['threshold']).mean())
        if drop < 0.03:
            print(f'WARNING: the current gate drops only {drop:.2%} of these lines; the run looks gated, not pre-gate',
                  file=sys.stderr, flush=True)
    split_n = collections.Counter(p['split'] for p in pages)
    print(f"{len(pages)} pages ({', '.join(f'{s} {split_n[s]}' for s in ('train', 'dev', 'test'))}), "
          f"{sum(p['n'] for p in pages)} lines")
    extra = augment_pages(pages, a.run_prefix, aug) if aug else ()
    J, info = train_all(pages, extra=extra)
    if a.check:
        with tempfile.TemporaryDirectory() as tmp:
            write(J, Path(tmp) / 'PipelineLineKeep.json')
            check(pages, json.load(open(Path(tmp) / 'PipelineLineKeep.json')), current)
    else:
        write(J, a.out); print('wrote', a.out)
    if a.eval:
        evaluate(pages, J, info)
    print(f'{time.time() - t0:.0f} s')


if __name__ == '__main__':
    main()
