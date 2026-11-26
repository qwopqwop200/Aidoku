"""Retrain the S8 outline (PipelineStyle.swift decide/outlineWidth; Resources/Translation/PipelineOutlineWidth.json).

  train.py RUN_PREFIX [--out PATH] [--check] [--eval] [--full [--out-bin PATH]] [--augment SPEC]

Input: a run prefix (RUN_PREFIX_{train,dev,test}) with pages/ID.json (any run that reached S8, --ocr-only is enough;
stages/ID.front.json `blocks` is the fallback), the page images from the manifest (pixels read numerically), and the
GT `source_appearance` records (outline presence, colour, widthRangePx). The Python S8 port (s8.py) re-derives each
block's font prior, fill pick, outline observation (16 presence features, colour, ring width) and presence score;
the result is cached per run and resource version under workspace.data('retrain', 'outline').
The shipped width model was trained on runs/speed2/obase (STAGES=inew2 --from s4, ring-line widths).

Learned parts and what this trainer refits:
- width (default, port-eval/stageopt/outline R4, export_r4.py): interval-hit LightGBM classifier P(candidate c in
  GT widthRangePx | ring width, font, c, c / font, c - ring line) over c = 1..12 px step 0.5, plus a centre forest
  (L1, GT range centre from ring width and font); width = the most probable candidate, ties (within 0.02) to the one
  nearest the centre. Rows: matched GT outlined paragraphs on TRAIN pages whose block has an observation (det match:
  the block covering >= 0.5 of the GT paragraph's line bbox). Fixed hyperparameters, no selection step.
- presence forest (PipelineWeights.bin slot 2), page logistic `presencePage` and `ringLine` (JSON): kept as shipped.
  Their original training data is gone (an older dump and GT); the shipped forest is a class-balanced sklearn GBM
  (120 depth-3 trees, rate 0.1) and cannot be reproduced. `--full` refits all three on this run (selection by
  train LOFO; see refit_presence), writes slot 2 through colorfix/forest.py and leaves every other slot byte-identical.
  The stage notes rejected a presence retrain (held-out not better), so --full is opt-in.

--augment SPEC (off by default; without it the output is unchanged), comma-free parts joined by ';' or given as
  'mix=A,B' and/or 'jitter=SxN' (e.g. 'mix=retune/snap2/ref,speed2/all830;jitter=1.0x2'):
- mix=RUNS: train rows from the union of RUN_PREFIX and these runs (names under workspace RUNS, train pages only).
- jitter=SxN: N jittered copies of RUN_PREFIX's train pages at scale S (retrain/augment.py Jitter, raw-S3 residuals of
  AUG_RES): each line's polygon and its sizing polygon (`measure`) move by the same draw, block bounds and
  measureBounds are rebuilt as the unions, and the S8 port reruns on the jittered geometry (cached per run, scale and
  copy; seed per copy and page). GT labels are unchanged; every copy keeps its page's fold, so LOFO keeps all copies
  of a page on one side. With --augment the default outputs go to workspace.data('retrain', 'outline', 'aug').
"""
import argparse, hashlib, itertools, json, os, pickle, shutil, sys, time, zlib
from pathlib import Path
import numpy as np
import lightgbm as lgb
from PIL import Image

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parents[1]
sys.path.insert(0, str(TOOLS)); sys.path.insert(0, str(HERE)); sys.path.insert(0, str(TOOLS / 'colorfix'))
import workspace as ws  # noqa: E402
import s8  # noqa: E402
import forest as FO  # noqa: E402  colorfix/forest.py
sys.path.insert(0, str(HERE.parent))
import augment as AUG  # noqa: E402  retrain/augment.py

RESOURCE = 'Aidoku/Resources/Translation/PipelineOutlineWidth.json'
BIN = 'Aidoku/Resources/Translation/PipelineWeights.bin'
OUTLINE_SLOT = 2  # fillPass1, fillPass2, outline, (old fill peaks), lineEnds
SPEC = {
    'name': 'outline',
    'resource': [RESOURCE],
    'resource_full': [RESOURCE, BIN + ' (slot 2, outline presence forest)'],
    'stage': 'S8',
    'inputs': 'pages/ID.json blocks (bounds, line polygons, sourceText length) at S8 + page pixels: the Python S8 '
              'port re-derives font prior, fill pick, outline observation and ring width; GT source_appearance '
              '(outline present / widthRangePx)',
    'needs_full': False,
    'rerun_from': 's8',
    'augment': 'mix=speed2/all830,speed2/base830',  # chosen --augment SPEC of the augmentation round (the lead decides whether to adopt it)
}
AUG_RES = 'retune/snap2/ref'  # jitter residuals: raw S3 (unrefined) vs GT line edges on this run's train pages
GRID = [float(c) for c in np.arange(1.0, 12.01, 0.5)]
TIE = 0.02
HPW = dict(objective='l1', num_leaves=4, n_estimators=50, learning_rate=0.1, min_child_samples=50, n_jobs=1, verbose=-1)
HPC = dict(num_leaves=8, n_estimators=150, learning_rate=0.05, min_child_samples=40, n_jobs=1, verbose=-1)
TRAIN = ['f2', 'f3', 'f4']
SPLITS = ('train', 'dev', 'test')


# ---------------------------------------------------------------- data
def manifest():
    return {p['page_id']: p for p in json.load(open(ws.MANIFEST))['pages']}


def fold_of(p):
    return p['split'] if p['split'] in ('dev', 'test') else 'f%d' % p['fold']


def gt_items():
    """{page: [GT source_appearance paragraph]}, cached per GT file version."""
    st = os.stat(ws.GT); key = f'{ws.GT}:{st.st_size}:{st.st_mtime_ns}'
    cache = ws.data('retrain', 'outline', 'gt_items.pkl')
    if cache.exists():
        c = pickle.load(open(cache, 'rb'))
        if c.get('key') == key: return c['items']
    out = {}
    for r in json.load(open(ws.GT))['records']:
        if r.get('scope') != 'source_appearance': continue
        l = r['label']; x0, y0 = l['cropBounds'][:2]
        polys = l.get('individualPolygonsCrop') or [l['mergedPolygonCrop']]
        polys = [[(p[0] + x0, p[1] + y0) for p in q] for q in polys]
        o = l['outline']; bg = l.get('background') or {}
        out.setdefault(l['page'], []).append(dict(
            id=l['itemID'], lines=polys, outline=bool(o.get('present')), stroke=o.get('rgb') if o.get('present') else None,
            width=o.get('widthPx') or 0, wrange=o.get('widthRangePx'), bg=bg.get('rgb')))
    pickle.dump(dict(key=key, items=out), open(cache, 'wb'))
    return out


def _move(poly, vertical, off):
    """Polygon mapped per axis from its bbox onto the bbox with edges moved outward by off (thicknesses)."""
    xs = [q[0] for q in poly]; ys = [q[1] for q in poly]; ob = (min(xs), min(ys), max(xs), max(ys))
    if ob[2] - ob[0] < 1e-6 or ob[3] - ob[1] < 1e-6: return poly
    nb = AUG.apply_offsets(ob, vertical, off)
    if nb[2] - nb[0] < 2 or nb[3] - nb[1] < 2: return poly
    sx = (nb[2] - nb[0]) / (ob[2] - ob[0]); sy = (nb[3] - nb[1]) / (ob[3] - ob[1])
    return [[nb[0] + (q[0] - ob[0]) * sx, nb[1] + (q[1] - ob[1]) * sy] for q in poly]


def _union(polys):
    pts = [q for P in polys for q in P]
    xs = [q[0] for q in pts]; ys = [q[1] for q in pts]
    return [[min(xs), min(ys)], [max(xs) - min(xs), max(ys) - min(ys)]]


def jitter_blocks(src, J):
    """Page blocks with each line's polygon and sizing polygon moved by one S3 jitter draw; bounds rebuilt."""
    out = []
    for b in src:
        b = dict(b); lines = []
        for L in b['lines']:
            L = dict(L); v = bool(L.get('vertical', b.get('vertical'))); off = J.offsets(v)
            if len(L['polygon']) >= 3: L['polygon'] = _move(L['polygon'], v, off)
            if L.get('measure') and len(L['measure']) >= 3: L['measure'] = _move(L['measure'], v, off)
            lines.append(L)
        b['lines'] = lines
        if lines:
            b['bounds'] = _union([L['polygon'] for L in lines])
            if b.get('measureBounds'): b['measureBounds'] = _union([L.get('measure') or L['polygon'] for L in lines])
        out.append(b)
    return out


def run_blocks(d, pid, jitter=None):
    """-> (page record, blocks) from pages/ID.json, else stages/ID.front.json blocks.
    jitter: (augment.Jitter residuals, scale, copy) -> S3-jittered geometry (seed per copy and page)."""
    p = d / 'pages' / f'{pid}.json'
    if p.exists():
        rec = json.load(open(p)); src = rec['blocks']
    else:
        rec = json.load(open(d / 'stages' / f'{pid}.front.json')); src = rec['blocks']
    if jitter is not None:
        res, scale, copy = jitter
        src = jitter_blocks(src, AUG.Jitter(res, scale, seed=zlib.crc32(f'outline:{copy}:{pid}'.encode())))
    bl = []
    for b in src:
        (x, y), (w, h) = b['bounds']
        (sx, sy), (sw, sh) = b.get('measureBounds') or b['bounds']
        bl.append(dict(bounds=(x, y, w, h), lines=[[tuple(q) for q in L['polygon']] for L in b['lines']],
                       chars=len(b.get('sourceText') or ''), id=b['id'], size_bounds=(sx, sy, sw, sh),
                       size_lines=[[tuple(q) for q in (L.get('measure') or L['polygon'])] for L in b['lines']]))
    return rec, bl


def page_ids(d):
    sub = d / 'pages' if (d / 'pages').is_dir() else d / 'stages'
    return sorted({f.split('.')[0] for f in os.listdir(sub) if f.endswith('.json')})


def fingerprint(prefix):
    h = hashlib.sha1(str(Path(prefix).resolve()).encode())
    h.update(open(ws.WEIGHTS, 'rb').read())
    h.update(json.dumps([s8.OUTLINE_PAGE, [s8.W_RING, s8.W_FONT, s8.W_BIAS]]).encode())
    h.update(open(s8.__file__, 'rb').read())
    return h.hexdigest()[:16]


def features(prefix, jitter=None, splits=SPLITS):
    """{page: dict(fold, split, blocks)} for pages with GT, the S8 port run per page (cached, resumable).
    jitter: (scale, copy) -> the S3-jittered copy (cached separately under aug/)."""
    prefix = Path(prefix); key = fingerprint(prefix); jit = None
    cache = ws.data('retrain', 'outline', f'{prefix.parent.name}_{prefix.name}_{key}.pkl')
    if jitter is not None:
        scale, copy = jitter; jit = (AUG.residuals(str(ws.RUNS / AUG_RES)), scale, copy)
        cache = ws.data('retrain', 'outline', 'aug', f'{prefix.parent.name}_{prefix.name}_{key}_j{scale:g}c{copy}.pkl')
    done = pickle.load(open(cache, 'rb')) if cache.exists() else {}
    MAN = manifest(); G = gt_items(); n = 0; t0 = time.time()
    for split in splits:
        d = Path(f'{prefix}_{split}')
        for pid in page_ids(d):
            if pid in done or pid not in G or pid not in MAN: continue
            rec, bl = run_blocks(d, pid, jit)
            img = np.asarray(Image.open(MAN[pid]['image_path']).convert('RGB'))
            fonts = s8.font_prior(bl)
            an = [s8.analyze(img, b['bounds'], b['lines'], fonts[i]) for i, b in enumerate(bl)]
            res = s8.decide(an, fonts)
            blocks = []
            for i, b in enumerate(bl):
                r = res[i]; ob = r['obs']
                blocks.append(dict(id=b['id'], bounds=b['bounds'], chars=b['chars'], font=fonts[i], raw_fill=r['fill'],
                                   raw_stroke=r['stroke'], score=r['score'],
                                   ox=None if ob is None else ob['x'], ocolour=None if ob is None else s8.rgb8(ob['colour']),
                                   ringWidth=None if ob is None else ob['ringWidth']))
            done[pid] = dict(fold=fold_of(MAN[pid]), split=split, blocks=blocks)
            n += 1
            if n % 50 == 0:
                pickle.dump(done, open(cache, 'wb'))
                print(f'  s8 port {n} pages, {time.time() - t0:.0f}s', flush=True)
    if n: pickle.dump(done, open(cache, 'wb'))
    return {p: v for p, v in done.items() if v['split'] in splits}, G


def parse_augment(spec):
    """'mix=A,B;jitter=1.0x2' (or 'mix=A,B jitter=..') -> dict(mix=[run names], jitter=(scale, copies) or None)."""
    out = dict(mix=[], jitter=None)
    for part in spec.replace(' ', ';').split(';'):
        if not part: continue
        k, v = part.split('=', 1)
        if k == 'mix': out['mix'] = [r for r in v.split(',') if r]
        elif k == 'jitter':
            s, c = v.split('x'); out['jitter'] = (float(s), int(c))
        else: raise SystemExit(f'--augment: unknown part {k!r}')
    return out


def augmented(prefix, spec, D, G):
    """-> (D, G) for training: RUN_PREFIX's pages plus the mixed runs' and jittered copies' train pages under keys
    'page@tag' (same fold as the page, GT items shared)."""
    A = parse_augment(spec) if isinstance(spec, str) else spec
    D2, G2 = dict(D), dict(G); own = Path(prefix).resolve()
    extra = []
    for r in A['mix']:
        p = Path(r) if os.path.isabs(r) else ws.RUNS / r
        if p.resolve() != own: extra.append((r.replace('/', '_'), features(p, splits=('train',))[0]))
    if A['jitter']:
        s, c = A['jitter']
        for k in range(c): extra.append((f'j{s:g}c{k}', features(prefix, (s, k), splits=('train',))[0]))
    for tag, E in extra:
        for pid, P in E.items():
            if P['fold'] in TRAIN: D2[f'{pid}@{tag}'] = P; G2[f'{pid}@{tag}'] = G.get(pid, [])
    return D2, G2


def match(P, items):
    """-> [(GT item, block index)]: the block covering >= 0.5 of the GT paragraph's line bbox (colorfix/errors.py)."""
    out = []
    for it in items:
        xs = [p[0] for q in it['lines'] for p in q]; ys = [p[1] for q in it['lines'] for p in q]
        a, b, c, e = min(xs), min(ys), max(xs), max(ys); area = max(1e-9, (c - a) * (e - b)); best, cov = None, 0
        for k, blk in enumerate(P['blocks']):
            x, y, w, h = blk['bounds']
            ix = max(0, min(x + w, c) - max(x, a)) * max(0, min(y + h, e) - max(y, b)) / area
            if ix > cov: best, cov = k, ix
        if best is not None and cov >= 0.5: out.append((it, best))
    return out


# ---------------------------------------------------------------- width model (R4)
def line_w(line, rw, f): return max(0.0, line[0] * rw + line[1] * f + line[2])


def cand(line, rw, f):
    sw = line_w(line, rw, f); return np.array([[rw, f, c, c / f, c - sw] for c in GRID])


def flat(booster):
    """LightGBM trees as the JSON's flat arrays: x[f] <= t goes left, a negative child is leaf -child - 1."""
    trees = []
    for t in booster.dump_model()['tree_info']:
        f, th, l, r, v = [], [], [], [], []
        def node(n):
            if 'leaf_value' in n:
                v.append(n['leaf_value']); return -len(v)
            i = len(f); f.append(n['split_feature']); th.append(n['threshold']); l.append(0); r.append(0)
            assert n['decision_type'] == '<=' and n.get('missing_type') != 'NaN'
            l[i] = node(n['left_child']); r[i] = node(n['right_child'])
            return i
        root = node(t['tree_structure'])
        if root < 0:  # single leaf: a dummy split that always goes left
            f, th, l, r = [0], [1e300], [root], [root]
        trees.append(dict(f=f, t=th, l=l, r=r, v=v))
    return trees


def fsum(trees, x):
    z = 0.0
    for t in trees:
        n = 0
        while n >= 0: n = t['l'][n] if x[t['f'][n]] <= t['t'][n] else t['r'][n]
        z += t['v'][-n - 1]
    return z


def width(model, rw, f):
    """PipelineStyleEstimator.outlineWidth with the shipped model (Swift: PipelineOutlineWidthModel.width)."""
    line = model['ringLine']
    if f <= 0: return line_w(line, rw, f)
    p = np.array([1 / (1 + np.exp(-fsum(model['hit'], x))) for x in cand(line, rw, f)])
    wf = fsum(model['centre'], [rw, f])
    ok = np.flatnonzero(p >= p.max() - model['tie'])
    g = np.array(model['grid'])
    return float(g[ok[np.argmin(np.abs(g[ok] - wf))]])


def width_rows(D, G, folds):
    rows = []
    for pid, P in D.items():
        if P['fold'] not in folds: continue
        for it, k in match(P, G.get(pid, [])):
            b = P['blocks'][k]
            if it['outline'] and b['ox'] is not None: rows.append((b['ringWidth'], b['font'], *it['wrange']))
    return rows


def fit_width(rows, line):
    X = np.vstack([cand(line, rw, f) for rw, f, lo, hi in rows])
    g = np.array(GRID)
    y = np.concatenate([((g >= lo) & (g <= hi)).astype(int) for rw, f, lo, hi in rows])
    clf = lgb.LGBMClassifier(**HPC).fit(X, y)
    reg = lgb.LGBMRegressor(**HPW).fit(np.array([[rw, f] for rw, f, _, _ in rows]),
                                       np.array([(lo + hi) / 2 for rw, f, lo, hi in rows]))
    return dict(hit=flat(clf.booster_), centre=flat(reg.booster_)), (clf, reg, X)


# ---------------------------------------------------------------- legacy parts (--full)
def fit_ring_line(rows):
    """Ring line (ring, font, bias) minimising the mean distance to the GT width range (Nelder-Mead, fixed start)."""
    from scipy.optimize import minimize
    a = np.array(rows, float); A = np.c_[a[:, 0], a[:, 1], np.ones(len(a))]
    def loss(w):
        q = np.maximum(0, A @ w); return np.maximum(0, np.maximum(a[:, 2] - q, q - a[:, 3])).mean()
    return [float(v) for v in minimize(loss, [0.5, 0.04, 0.0], method='Nelder-Mead', options=dict(maxiter=4000)).x]


PRES_GRID = dict(num_leaves=[4, 8, 16], n_estimators=[100, 300], learning_rate=[0.05, 0.1], min_child_samples=[10, 30])


def presence_rows(D, G, folds):
    """Labelled rows: (page, block index, outline present, visible = dE(GT stroke, GT bg) >= 10)."""
    out = []
    for pid, P in D.items():
        if P['fold'] not in folds: continue
        for it, k in match(P, G.get(pid, [])):
            if P['blocks'][k]['ox'] is not None:
                vis = it['outline'] and it['bg'] is not None and s8.dE(it['stroke'], it['bg']) >= 10
                out.append((pid, k, int(it['outline']), vis))
    return out


def lgb_presence(D, rows, hp):
    X = np.array([D[p]['blocks'][k]['ox'] for p, k, _, _ in rows], np.float32); y = np.array([r[2] for r in rows])
    return lgb.LGBMClassifier(objective='binary', class_weight='balanced', random_state=0, n_jobs=1, verbose=-1, **hp).fit(X, y)


def page_scores(D, pages, booster_for):
    """{page: [forest logit per block or None]} with the model booster_for(fold)."""
    out = {}
    for p in pages:
        P = D[p]; m = booster_for(P['fold']); xs = [b['ox'] for b in P['blocks']]
        idx = [i for i, x in enumerate(xs) if x is not None]
        z = m.predict(np.array([xs[i] for i in idx], np.float32), raw_score=True) if idx else []
        s = [None] * len(xs)
        for i, v in zip(idx, z): s[i] = float(v)
        out[p] = s
    return out


def refit_presence(D, G, folds):
    """Presence forest (16 observation features, class-balanced LightGBM; hyperparameters by train LOFO visible
    errors at logit 0) + page logistic on the LOFO logits and their page median. -> (booster, presencePage)."""
    from sklearn.linear_model import LogisticRegression
    rows = presence_rows(D, G, folds); pages = sorted({p for p, *_ in rows})
    def lofo(hp):
        ms = {h: lgb_presence(D, [r for r in rows if D[r[0]]['fold'] != h], hp) for h in folds}
        return page_scores(D, pages, lambda f: ms[f])
    best = None
    for vals in itertools.product(*PRES_GRID.values()):
        hp = dict(zip(PRES_GRID, vals)); S = lofo(hp)
        verr = sum(1 for p, k, y, vis in rows if (S[p][k] >= 0) != y and (vis or S[p][k] >= 0))
        if best is None or verr < best[0]: best = (verr, hp, S)
    _, hp, S = best
    X, y = [], []
    for p, k, lab, _ in rows:
        X.append([S[p][k], float(np.median([v for v in S[p] if v is not None]))]); y.append(lab)
    lr = LogisticRegression(C=1.0).fit(np.array(X), np.array(y))
    return lgb_presence(D, rows, hp), [float(lr.coef_[0][0]), float(lr.coef_[0][1]), float(lr.intercept_[0])], hp


def bin_slots(data):
    """-> byte spans of (stage tables, forest 0, forest 1, ...) in PipelineWeights.bin."""
    import struct
    off = 0; spans = []
    def skip(fmt):
        nonlocal off
        off += 4 + struct.unpack_from('<I', data, off)[0] * struct.calcsize(fmt)
    skip('f'); skip('f'); spans.append((0, off))
    while off < len(data):
        s = off
        for fmt in 'dihdiid': skip(fmt)
        spans.append((s, off))
    assert off == len(data)
    return spans


def write_slot(path, booster, X):
    """Replace forest slot 2 via colorfix/forest.py (flatten + write); the later slots are copied back unchanged.
    X: observation rows for the Swift-style (float32) evaluation parity check against LightGBM."""
    data = open(path, 'rb').read(); spans = bin_slots(data)
    tail = data[spans[1 + OUTLINE_SLOT][1]:]
    tables = FO.flatten(booster.booster_)
    ref = booster.predict(np.array(X, np.float32), raw_score=True)
    diff = max(abs(FO.logit(tables, x) - r) for x, r in zip(X, ref))
    assert diff < 1e-9, f'forest.py logit vs LightGBM {diff}'
    FO.write(path, OUTLINE_SLOT, tables)
    open(path, 'ab').write(tail)
    new = open(path, 'rb').read(); ns = bin_slots(new)
    assert len(ns) == len(spans)
    for i, (a, b) in enumerate(spans):  # round trip: every other slot byte-identical
        if i != 1 + OUTLINE_SLOT: assert data[a:b] == new[ns[i][0]:ns[i][1]], f'slot {i - 1} changed'
    return new


def read_slot(path):
    return s8.load_forests(path)[OUTLINE_SLOT]


# ---------------------------------------------------------------- fit / decide / eval
def train(D, G, folds=TRAIN, full=False, base=None):
    """-> (JSON model, presence booster or None)."""
    base = base or json.load(open(ws.REPO / RESOURCE))
    line, page, booster = list(base['ringLine']), list(base['presencePage']), None
    if full:
        line = fit_ring_line(width_rows(D, G, folds))
        booster, page, _ = refit_presence(D, G, folds)
    m, _ = fit_width(width_rows(D, G, folds), line)
    return dict(grid=GRID, tie=TIE, hit=m['hit'], centre=m['centre'], presencePage=page, ringLine=line), booster


def decide_page(P, model, booster):
    """Per block (stroke or None, width) before unification; presence shipped (cached) or refit."""
    if booster is None:
        st = [b['raw_stroke'] for b in P['blocks']]
    else:
        xs = [b['ox'] for b in P['blocks']]; idx = [i for i, x in enumerate(xs) if x is not None]
        z = booster.predict(np.array([xs[i] for i in idx], np.float32), raw_score=True) if idx else []
        sc = {i: float(v) for i, v in zip(idx, z)}; pm = float(np.median(list(sc.values()))) if sc else 0.0
        a = model['presencePage']
        st = [P['blocks'][i]['ocolour'] if i in sc and a[0] * sc[i] + a[1] * pm + a[2] >= 0 else None for i in range(len(xs))]
    return [((s, width(model, b['ringWidth'], b['font'])) if s is not None else (None, 0.0)) for s, b in zip(st, P['blocks'])]


def unify_page(P, dec):
    st = [dict(fill=b['raw_fill'], stroke=s, width=w, font=b['font']) for b, (s, w) in zip(P['blocks'], dec)]
    return s8.unify(st, [b['chars'] for b in P['blocks']])


def score(rows):
    """rows (gt item, stroke, width) -> presence err / VISerr / F1, width in-range share / mean distance to range."""
    tp = sum(1 for it, s, w in rows if it['outline'] and s is not None)
    fp = sum(1 for it, s, w in rows if not it['outline'] and s is not None)
    fn = sum(1 for it, s, w in rows if it['outline'] and s is None)
    fnv = sum(1 for it, s, w in rows if it['outline'] and s is None and not (it['bg'] and s8.dE(it['stroke'], it['bg']) < 10))
    P_ = tp / max(1, tp + fp); R = tp / max(1, tp + fn)
    e = np.array([max(0, it['wrange'][0] - w, w - it['wrange'][1]) for it, s, w in rows if it['outline'] and s is not None])
    return dict(n=len(rows), err=fp + fn, VISerr=fp + fnv, F1=2 * P_ * R / max(1e-9, P_ + R),
                win=float((e == 0).mean()) if len(e) else 0.0, wMAE=float(e.mean()) if len(e) else 0.0)


def evaluate(D, G, full, DT=None, GT=None):
    """Train LOFO (fit on the other train folds of DT, default D) and dev/test (fit on all train folds), scored on D."""
    DT, GT = (D, G) if DT is None else (DT, GT)
    models = {h: train(DT, GT, [f for f in TRAIN if f != h], full) for h in TRAIN}
    models['dev'] = models['test'] = train(DT, GT, TRAIN, full)
    rows = {k: [] for k in ('train LOFO', 'dev', 'test')}
    for pid, P in D.items():
        m, bo = models[P['fold']]
        u = unify_page(P, decide_page(P, m, bo))
        g = 'train LOFO' if P['fold'] in TRAIN else P['fold']
        rows[g] += [(it, u[k]['stroke'], u[k]['width']) for it, k in match(P, G.get(pid, []))]
    for g, R in rows.items():
        s = score(R)
        print(f"{g:10s} n {s['n']}  presence err {s['err']} VISerr {s['VISerr']} F1 {s['F1']:.3f}  "
              f"width win {s['win']:.3f} wMAE {s['wMAE']:.3f}")


def dump(model):
    return json.dumps(model, separators=(',', ':'))


def max_diff(a, b):
    if isinstance(a, dict):
        if not isinstance(b, dict) or a.keys() != b.keys(): return float('inf')
        return max((max_diff(a[k], b[k]) for k in a), default=0.0)
    if isinstance(a, list):
        if not isinstance(b, list) or len(a) != len(b): return float('inf')
        return max((max_diff(x, y) for x, y in zip(a, b)), default=0.0)
    return abs(float(a) - float(b))


def check(D, model, booster, full):
    path = ws.REPO / RESOURCE; cur = json.load(open(path))
    print('JSON identical' if dump(model) == path.read_text() else f'JSON max abs diff {max_diff(model, cur):.3g}')
    blocks = [b for P in D.values() for b in P['blocks'] if b['ox'] is not None]
    same = sum(width(model, b['ringWidth'], b['font']) == width(cur, b['ringWidth'], b['font']) for b in blocks)
    print(f'width agreement {same}/{len(blocks)} blocks with an outline observation ({same / max(1, len(blocks)):.4%})')
    if full:
        old = read_slot(ws.WEIGHTS); X = [b['ox'] for b in blocks]
        z_old = np.array([s8.flogit(old, x) for x in X]); z_new = booster.predict(np.array(X, np.float32), raw_score=True)
        print(f'presence forest sign agreement {np.mean((z_old >= 0) == (z_new >= 0)):.4%}')
        agree = n = 0
        for P in D.values():
            a = [d[0] is not None for d in decide_page(P, model, booster)]; b = [b['raw_stroke'] is not None for b in P['blocks']]
            agree += sum(x == y for x, y in zip(a, b)); n += len(a)
        print(f'presence decision agreement {agree}/{n} blocks ({agree / max(1, n):.4%})')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run_prefix'); ap.add_argument('--out', default=str(ws.REPO / RESOURCE))
    ap.add_argument('--out-bin', default=str(ws.WEIGHTS)); ap.add_argument('--check', action='store_true')
    ap.add_argument('--eval', action='store_true'); ap.add_argument('--full', action='store_true')
    ap.add_argument('--augment', default=None, help="e.g. 'mix=retune/snap2/ref,speed2/all830;jitter=1.0x2'")
    A = ap.parse_args(); t0 = time.time()
    if A.augment:  # never overwrite the app resources by default with an augmented fit
        ad = ws.data('retrain', 'outline', 'aug'); ad.mkdir(parents=True, exist_ok=True)
        if A.out == str(ws.REPO / RESOURCE): A.out = str(ad / Path(RESOURCE).name)
        if A.out_bin == str(ws.WEIGHTS): A.out_bin = str(ad / ws.WEIGHTS.name)
    D, G = features(A.run_prefix)
    DT, GT = augmented(A.run_prefix, A.augment, D, G) if A.augment else (D, G)
    print(f'pages {len(D)} (train {sum(P["fold"] in TRAIN for P in D.values())}), '
          f'width rows {len(width_rows(DT, GT, TRAIN))}, features {time.time() - t0:.0f}s', flush=True)
    model, booster = train(DT, GT, TRAIN, A.full)
    if A.check:
        check(D, model, booster, A.full)
    else:
        Path(A.out).write_text(dump(model)); print('wrote', A.out)
        if A.full:
            if Path(A.out_bin).resolve() != ws.WEIGHTS.resolve(): shutil.copy(ws.WEIGHTS, A.out_bin)
            X = [b['ox'] for P in D.values() for b in P['blocks'] if b['ox'] is not None]
            write_slot(A.out_bin, booster, X); print('wrote slot', OUTLINE_SLOT, 'of', A.out_bin, '(other slots identical)')
    if A.eval:
        evaluate(D, G, A.full, DT, GT)
    print(f'runtime {time.time() - t0:.0f}s')


if __name__ == '__main__':
    main()
