"""S4b interior trainer: the joint side model (quantile 0.35 LightGBM, per-side outward offset in em) and the
balloon/free gate of PipelineInterior.swift, written as Resources/Translation/PipelineInterior.json.

python train.py RUN_PREFIX [--out PATH] [--check] [--eval] [--raster DIR] [--rebuild] [--augment SPEC]

Inputs per page of RUN_PREFIX_{train,dev,test}/stages/ID.front.json: `classified` (the S4 blocks S4b reads) and
`layout`; the app's S4 gray raster (CoreGraphics decode, <= 768 px long side) as DIR/ID.raw + DIR/ID.size, written
by `swift rasterdump.swift LIST DIR` (LIST = "ID<TAB>image path" lines; the trainer writes it when rasters are
missing); the GT balloon/narration interiors. Items = non-background classified blocks with lines.
Fit (train split only): the gate on all items (label: inside a GT interior), the joint model on scored items; the
gate threshold is picked on train leave-one-fold-out (folds 2/3/4) as the best mean IoU with free-text
shrink (box < half the rule's area) <= 2%, on the grid 0.05..0.95 step 0.05. Below it the item keeps the rule box.

--augment SPEC (off by default; without it the output is unchanged): extra train rows, comma/space separated parts
  mix=RUN[+RUN...]  train pages of these runs (names under $AIDOKU_EVAL_DIR/runs, see retrain/augment.py RUNS) are added
  jitter=SxN        N jittered copies of every train page of RUN_PREFIX (and of each mixed run) at scale S: each
                    classified block through augment.Jitter.block (S3 line boxes moved by the run's measured
                    `recognized`-vs-GT residuals, block bounds rebuilt), features recomputed; GT targets and gate
                    labels are those of the unjittered block.
  e.g. `mix=speed2/all830`, `jitter=1.0x1`, `mix=speed2/all830;jitter=0.5x1`. Extra rows are only fitted on; the gate
  threshold is still picked on RUN_PREFIX's own train rows (out of fold). All copies of a page share its fold.
"""
import argparse, hashlib, json, math, pickle, sys, time, zlib
from pathlib import Path
import numpy as np
import lightgbm as lgb

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parents[1])); sys.path.insert(0, str(HERE.parent))
import workspace  # noqa: E402
import rule as I, features as F, gt as G  # noqa: E402

SPEC = dict(
    name='interior',
    resource=['Aidoku/Resources/Translation/PipelineInterior.json'],
    stage='S4b',
    inputs='front.classified + front.layout: S4 blocks (bounds, lines, role, vertical, RF balloon) and layout boxes '
           'as S4b reads them; the S4 CoreGraphics gray raster (rasterdump.swift); GT balloon/narration interiors',
    needs_full=False,
    rerun_from='s4',
    augment='mix=speed2/all830;jitter=0.5x1',   # augmentation-round candidate, not applied by default (the lead decides)
)
RESOURCE = workspace.REPO / SPEC['resource'][0]
SCRATCH = workspace.EVAL / 'retrain' / 'interior'
JOINT = dict(n_estimators=600, num_leaves=15, learning_rate=0.05, min_child_samples=20, objective='quantile', alpha=0.35)
GATE = dict(n_estimators=200, num_leaves=15, learning_rate=0.05, min_child_samples=20)
CAP = 0.02
GRID = np.linspace(0.05, 0.95, 19)
FOLDS = ('2', '3', '4')


def rect(b):
    (x, y), (w, h) = b
    return [x, y, x + w, y + h]


def strip(bl):
    return [dict(id=b['id'], role=b['role'], vertical=b['vertical'], bounds=rect(b['bounds']),
                 balloon=rect(b['balloon']) if b.get('balloon') else None,
                 lines=[rect(l['bounds']) for l in b['lines']]) for b in bl]


def manifest():
    return {p['page_id']: p for p in sorted(json.load(open(workspace.MANIFEST))['pages'], key=lambda p: p['page_id'])}


def stage_file(prefix, m):
    return Path(f"{prefix}_{m['split']}") / 'stages' / f"{m['page_id']}.front.json"


def raster(pid, m, rdir):
    W, H = int(m['width']), int(m['height'])
    f = rdir / f'{pid}.raw'
    w, h = map(int, (rdir / f'{pid}.size').read_text().split())
    assert (w, h) == G.raster_size(W, H), (pid, w, h)
    return np.fromfile(f, np.uint8).reshape(h, w)


def check_rasters(man, rdir):
    miss = [pid for pid in man if not (rdir / f'{pid}.raw').exists() or not (rdir / f'{pid}.size').exists()]
    if miss:
        lst = SCRATCH / 'raster-list.tsv'
        lst.write_text(''.join(f"{pid}\t{man[pid]['image_path']}\n" for pid in miss))
        sys.exit(f'{len(miss)} rasters missing in {rdir}; write them with:\n  swift {HERE / "rasterdump.swift"} {lst} {rdir}')


def build(prefix, rdir, rebuild, jitter=None):
    """All items of the run (train/dev/test) with features, candidate boxes and GT targets, cached on disk.
    jitter=(scale, copy): train pages only, blocks through augment.Jitter.block (seed from page and copy), targets
    from the unjittered blocks."""
    man = manifest()
    have = {pid: m for pid, m in man.items() if stage_file(prefix, m).exists()}
    if jitter is not None:
        have = {pid: m for pid, m in have.items() if m['split'] == 'train'}
    if len(have) < len(man):
        print(f'warning: {len(man) - len(have)} manifest pages have no front.json in {prefix}_*', flush=True)
    check_rasters(have, rdir)
    h = hashlib.sha1(str(Path(prefix).resolve()).encode())
    for pid, m in have.items():
        for f in (stage_file(prefix, m), rdir / f'{pid}.raw'):
            st = f.stat(); h.update(f'{pid}{st.st_size}{st.st_mtime_ns}'.encode())
    h.update(b''.join(Path(HERE / n).read_bytes() for n in ('rule.py', 'features.py', 'gt.py')))
    tag = Path(prefix).name
    if jitter is not None:
        import augment as A
        h.update(f'jitter{jitter[0]!r}x{jitter[1]}'.encode() + (HERE.parent / 'augment.py').read_bytes())
        res = A.residuals(prefix, 'recognized')
        tag += f'-j{jitter[0]:g}c{jitter[1]}'
    cache = SCRATCH / 'cache' / f'{tag}-{h.hexdigest()[:12]}.pkl'
    if cache.exists() and not rebuild:
        return pickle.load(open(cache, 'rb'))
    cache.parent.mkdir(parents=True, exist_ok=True)
    masks = G.masks(workspace.GT, have, SCRATCH / 'gt_masks.pkl')
    rows = []; t0 = time.time()
    for n, (pid, m) in enumerate(have.items()):
        f = json.load(open(stage_file(prefix, m)))
        p = dict(page=pid, W=int(m['width']), H=int(m['height']),
                 layout=[dict(kind=r['kind'], score=r['score'], box=rect(r['bounds'])) for r in f['layout']])
        bl = strip(f['classified']); R = raster(pid, m, rdir)
        T = G.targets(I.Ctx(R, p['W'], p['H']), masks[pid], bl)
        if jitter is not None:
            J = A.Jitter(res, jitter[0], seed=zlib.crc32(f'{pid}:{jitter[1]}'.encode()))
            bl = strip([J.block(b) for b in f['classified']])
            T = [None if t is None else dict(T=t['T']) for t in T]   # fit-only rows: the target box suffices
        for k, it in enumerate(F.items(p, bl, R)):
            if it is None:
                continue
            it.pop('mask'); it.pop('app_rows')
            rows.append(dict(it, page=pid, split=m['split'], fold=str(m['fold']), W=p['W'], H=p['H'], item=k, t=T[k],
                             toff=F.offsets(T[k]['T'], it['src'], it['e']) if T[k] is not None else None))
            if jitter is not None:
                rows[-1].pop('boxes')
        if (n + 1) % 100 == 0:
            print(f'  built {n + 1}/{len(have)} pages {time.time() - t0:.0f}s', flush=True)
    pickle.dump(rows, open(cache, 'wb'))
    return rows


# --- fit ---------------------------------------------------------------------------------------------------------

def fit_joint(rs):
    X = [F.joint_x(r, q) for r in rs for q in range(4)]; y = [r['toff'][q] for r in rs for q in range(4)]
    return lgb.LGBMRegressor(n_jobs=1, verbose=-1, **JOINT).fit(np.array(X), np.array(y))


def fit_gate(rs):
    return lgb.LGBMClassifier(n_jobs=1, verbose=-1, **GATE).fit(np.array([F.gate_x(r) for r in rs]),
                                                                 [r['t'] is not None for r in rs])


def fit(rs):
    """-> (joint, gate) LightGBM models on train rows rs."""
    return fit_joint([r for r in rs if r['t'] is not None]), fit_gate(rs)


def group_of(tr, scheme):
    """Train page -> fold: manifest folds ('page'), page-size groups balanced over 3 folds ('size'), or 3 contiguous
    chunks of the sorted page IDs ('chunk')."""
    pids = sorted({r['page'] for r in tr})
    if scheme == 'page':
        f = {r['page']: r['fold'] for r in tr}
        return {q: f[q] for q in pids}
    if scheme == 'size':
        wh = {r['page']: (r['W'], r['H']) for r in tr}
        sizes = {}
        for q in pids: sizes[wh[q]] = sizes.get(wh[q], 0) + 1
        load = {f: 0 for f in FOLDS}; of = {}
        for s, n in sorted(sizes.items(), key=lambda kv: -kv[1]):
            f = min(load, key=load.get); of[s] = f; load[f] += n
        return {q: of[wh[q]] for q in pids}
    return {q: FOLDS[min(2, 3 * i // len(pids))] for i, q in enumerate(pids)}


def lofo(tr, scheme, extra=()):
    """Out-of-fold joint box (boxes['joint']) and gate probability (r['pb']) on the train rows; `extra` (augment
    rows, same page IDs) are fitted on with their page's fold and never scored."""
    gm = group_of(list(tr) + list(extra), scheme)
    for f in sorted(set(gm.values())):
        jm, gate = fit([r for r in list(tr) + list(extra) if gm[r['page']] != f])
        held = [r for r in tr if gm[r['page']] == f]
        pb = gate.predict_proba(np.array([F.gate_x(r) for r in held]))[:, 1]
        off = jm.predict(np.array([F.joint_x(r, q) for r in held for q in range(4)])).reshape(-1, 4)
        for r, v, o in zip(held, pb, off):
            r['boxes']['joint'] = F.box_from(r, list(o)); r['pb'] = float(v)


def gated(rows, th):
    for r in rows:
        r['boxes']['R4'] = r['boxes']['joint'] if r['pb'] >= th else r['boxes']['app']


def pick(tr):
    best = None
    for th in GRID:
        gated(tr, th); a = G.metrics(tr, 'R4')
        if a['free_s50'] <= CAP and (best is None or a['iou'] > best[1]):
            best = (float(th), a['iou'])
    gated(tr, best[0])
    return best[0]


def dump(model):
    trees = []
    for t in model.booster_.dump_model()['tree_info']:
        f, th, l, r, v = [], [], [], [], []

        def walk(n):
            if 'split_index' not in n:
                v.append(n['leaf_value']); return -len(v)
            assert n['decision_type'] == '<=', n['decision_type']
            k = len(f); f.append(n['split_feature']); th.append(n['threshold']); l.append(0); r.append(0)
            l[k] = walk(n['left_child']); r[k] = walk(n['right_child'])
            return k
        if walk(t['tree_structure']) < 0:   # a single-leaf tree
            f, th, l, r = [0], [0.0], [-1], [-1]
        trees.append(dict(f=f, t=th, l=l, r=r, v=v))
    return dict(trees=trees)


def forest(trees, X):
    """Sum of the exported trees per row of X, the Swift walk (x <= t goes left)."""
    X = np.asarray(X, np.float64); tot = np.zeros(len(X)); rows = np.arange(len(X))
    for t in trees:
        f, th, l, r = (np.array(t[k]) for k in ('f', 't', 'l', 'r')); v = np.array(t['v'])
        node = np.zeros(len(X), np.int64)
        while (node >= 0).any():
            a = node >= 0; n = node[a]
            node[a] = np.where(X[rows[a], f[n]] <= th[n], l[n], r[n])
        tot += v[-node - 1]
    return tot


def predict(model, rows):
    """S4b decision per row with the exported model: (gate probability, box)."""
    if not rows:
        return []
    z = forest(model['gate']['trees'], [F.gate_x(r) for r in rows])
    o = forest(model['joint']['trees'], [F.joint_x(r, q) for r in rows for q in range(4)]).reshape(-1, 4)
    out = []
    for r, zz, oo in zip(rows, z, o):
        pb = 1 / (1 + math.exp(-zz))
        out.append((pb, F.box_from(r, list(oo)) if pb >= model['threshold'] else r['boxes']['app']))
    return out


def train(rows, extra=()):
    tr = [r for r in rows if r['split'] == 'train']
    lofo(tr, 'page', extra); th = pick(tr)
    jm, gm = fit(tr + list(extra))
    return dict(threshold=th, joint=dump(jm), gate=dump(gm)), (jm, gm)


# --- modes -------------------------------------------------------------------------------------------------------

def show(tag, rows, key):
    a = G.metrics(rows, key)
    print('%-18s %-4s iou %.4f over5 %.4f free_s50 %.4f font_s50 %.4f n %d free_n %d' % (
        tag, key, a['iou'], a['over5'], a['free_s50'], a['font_s50'], a['n'], a['free_n']), flush=True)


def evaluate(rows, model, extra=()):
    tr = [r for r in rows if r['split'] == 'train']
    for scheme in ('page', 'size', 'chunk'):
        lofo(tr, scheme, extra); th = pick(tr)
        print(f'train LOFO {scheme} threshold {th:.2f}')
        for key in ('app', 'comp', 'R4'): show(f'train-lofo-{scheme}', tr, key)
    for split in ('dev', 'test'):
        rs = [r for r in rows if r['split'] == split]
        for r, (_, box) in zip(rs, predict(model, rs)): r['boxes']['R4'] = box
        for key in ('app', 'comp', 'R4'): show(split, rs, key)


def check(rows, new):
    old = json.load(open(RESOURCE))
    if json.dumps(old, separators=(',', ':')) == json.dumps(new, separators=(',', ':')):
        print('resource identical')
    else:
        d = abs(old['threshold'] - new['threshold']); same = True
        for m in ('joint', 'gate'):
            if len(old[m]['trees']) != len(new[m]['trees']): same = False; continue
            for a, b in zip(old[m]['trees'], new[m]['trees']):
                if any(a[k] != b[k] for k in ('f', 'l', 'r')): same = False; continue
                d = max(d, max(abs(x - y) for x, y in zip(a['t'] + a['v'], b['t'] + b['v'])))
        print('resource differs: tree structure %s, max abs diff %.3g' % ('same' if same else 'DIFFERENT', d))
    po, pn = predict(old, rows), predict(new, rows)
    gate = sum((a[0] >= old['threshold']) == (b[0] >= new['threshold']) for a, b in zip(po, pn))
    box = sum(a[1] == b[1] for a, b in zip(po, pn))
    print('items %d: gate agree %.4f, balloon box identical %.4f' % (len(rows), gate / len(rows), box / len(rows)))


def parse_augment(spec):
    """'mix=A+B;jitter=1.0x2' -> (mix run prefixes, (scale, copies) or None)."""
    mix, jit = [], None
    for part in spec.replace(';', ' ').split():
        k, _, v = part.partition('=')
        if k == 'mix':
            mix += [str(workspace.RUNS / n) for n in v.replace(',', '+').split('+') if n]
        elif k == 'jitter':
            s, _, n = v.partition('x'); jit = (float(s), int(n or 1))
        else:
            sys.exit(f'bad --augment part {part!r}')
    return mix, jit


def augment_rows(prefix, spec, rdir, rebuild):
    """Extra fit-only train rows for --augment SPEC (mixed runs' train rows, jittered copies)."""
    mix, jit = parse_augment(spec)
    mix = [m for m in mix if Path(m).resolve() != Path(prefix).resolve()]
    extra = []
    for m in mix:
        extra += [dict(r, run=m) for r in build(m, rdir, rebuild) if r['split'] == 'train']
    if jit is not None:
        for src in [prefix] + mix:
            for c in range(jit[1]):
                extra += [dict(r, run=src, boxes={}) for r in build(src, rdir, rebuild, (jit[0], c))]
    return extra


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('run_prefix'); ap.add_argument('--out', default=str(RESOURCE))
    ap.add_argument('--check', action='store_true'); ap.add_argument('--eval', action='store_true')
    ap.add_argument('--raster', default=str(SCRATCH / 'cgraw'), help='DIR of ID.raw / ID.size S4 rasters')
    ap.add_argument('--rebuild', action='store_true', help='recompute the item cache')
    ap.add_argument('--augment', default=None, help='extra train rows: mix=RUN[+RUN], jitter=SCALExCOPIES (module doc)')
    a = ap.parse_args()
    t0 = time.time(); SCRATCH.mkdir(parents=True, exist_ok=True)
    rows = build(a.run_prefix, Path(a.raster), a.rebuild)
    print('items %d (train %d, scored %d) %.0fs' % (len(rows), sum(r['split'] == 'train' for r in rows),
                                                   sum(r['t'] is not None for r in rows), time.time() - t0), flush=True)
    extra = augment_rows(a.run_prefix, a.augment, Path(a.raster), a.rebuild) if a.augment else []
    if extra:
        print('augment %s: %d extra train rows' % (a.augment, len(extra)), flush=True)
    model, _ = train(rows, extra)
    print('threshold %.2f, trees joint %d gate %d' % (model['threshold'], len(model['joint']['trees']), len(model['gate']['trees'])))
    if a.check:
        check(rows, model)
    else:
        out = Path(a.out)
        json.dump(model, open(out, 'w'), separators=(',', ':'))
        print('wrote', out)
    if a.eval:
        evaluate(rows, model, extra)
    print('done %.0fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
