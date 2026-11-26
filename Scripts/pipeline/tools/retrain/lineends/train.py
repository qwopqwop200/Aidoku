"""Retrain the S6 line ends (PipelineLineEnds.swift): the line-end regressor (lineEnds forest, the last slot of
Resources/Translation/PipelineWeights.bin) and the missing-glyph classifier (Resources/Translation/PipelineLineEnds.json).

  train.py RUN_PREFIX [--out DIR] [--check] [--eval] [--lines blocks|recognized] [--only reg|clf]

Input: RUN_PREFIX_{train,dev,test} with pages/ID.json (page image) and stages/ID.front.json (layout, recognized,
blocks). The lines are the S6 inputs, i.e. the lines of the non-background front.blocks (--lines blocks, default),
or all S3 lines (--lines recognized, what both resources were fitted on). GT: canonical individual_premerge_bbox
line boxes and the convmask GT glyph masks ($AIDOKU_EVAL_DIR/convmask/gt/ID.npz).

Both models read the same 45 features per line end (features.py, a port of PipelineLineEnds.offsets). Fit on TRAIN
pages only, lines matched one-to-one to GT line boxes (Hungarian, IoU >= 0.5), all seeds fixed, one thread:
  - regressor: LightGBM huber (alpha 0.3), 15 leaves x 150 trees, lr 0.05; target = GT box end past the box end in T,
    clipped to [-1, 1.5] (the old tools/bboxagent fit.py `core13` recipe, which is replaced by this trainer).
    S6 searches each end up to max(lineEndExtension, offset + lineEndMargin) T (PipelineTuning; refit lineEndMargin
    with retune.py after a new regressor).
  - classifier (port-eval/stageopt/lineends M0): LightGBM binary, 7 leaves x 100 trees, lr 0.05; target = GT glyph
    ink more than lineEndExtension + gateScale (0.75 T) past the box end. Fires at p >= 0.3 inside an RF text region;
    the end then reaches along the ink run (capped at the region edge) + 0.1 T.
--eval: the stage metric per detected end with a GT glyph target (under = glyph end past reach + gate; over = mean
reach past the glyph end, T; over>1T; pxMiss = GT glyph pixels past reach + gate / all glyph pixels of the matched
lines) plus the regressor MAE, for train leave-one-group-out (page = folds 2/3/4, size, chunk; both models refit
per fold) and dev/test (fit on all train), and the current resources on dev/test.
"""
import argparse, json, os, re, shutil, struct, sys, tempfile, time, collections, pickle, zlib
from pathlib import Path
import numpy as np
import lightgbm as lgb

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1])); sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parents[1] / 'colorfix'))
import workspace as ws  # noqa: E402
import features as LF  # noqa: E402
import forest as FO  # noqa: E402
sys.path.insert(0, str(HERE.parent))
import augment as AU  # noqa: E402

CLF_RES = 'Aidoku/Resources/Translation/PipelineLineEnds.json'
REG_RES = 'Aidoku/Resources/Translation/PipelineWeights.bin'
REG_SLOT = 4   # forests: fillPass1, fillPass2, outline, old peaks, lineEnds
SPEC = {
    'name': 'lineends',
    'resource': [CLF_RES, REG_RES + ' (lineEnds forest, slot 4)'],
    'stage': 'S6',
    'inputs': 'front.blocks (non-background block lines = the S6 inputs, after S4/S4b) + front.layout + the page image '
              '(pages/ID.json); GT individual_premerge_bbox boxes and convmask GT glyph masks. '
              '--lines recognized: front.recognized (S3 lines), the input both current resources were fitted on',
    'needs_full': False,
    'rerun_from': 's5',
    'augment': 'mix=retune/snap2/ref,speed2/all830;jitter=0.5x2',   # proposed --augment (off unless passed)
}
TRAIN, SPLITS = ['f2', 'f3', 'f4'], ('train', 'dev', 'test')
PRM_REG = dict(objective='huber', alpha=0.3, learning_rate=0.05, num_leaves=15, min_data_in_leaf=40, feature_fraction=0.8,
               bagging_fraction=0.8, bagging_freq=1, verbose=-1, seed=1, num_threads=1)
NT_REG, YCLIP_REG = 150, (-1.0, 1.5)
PRM_CLF = dict(objective='binary', learning_rate=0.05, num_leaves=7, min_data_in_leaf=40, feature_fraction=0.8,
               bagging_fraction=0.8, bagging_freq=1, verbose=-1, seed=1, num_threads=1)
NT_CLF, TAU, RUN_PAD = 100, 0.3, 0.1
YCLIP = (-1.0, 3.0)
LB = np.arange(-10, 30) / 10   # glyph-pixel bins (T past the end)
EDGE = 42                      # feature index of distance(.text)


def swift_const(file, pattern, default):
    try:
        m = re.search(pattern, (ws.REPO / 'Aidoku/Core/Translation/Pipeline' / file).read_text())
        return float(m.group(1)) if m else default
    except OSError:
        return default


EXT = swift_const('PipelineTuning.swift', r'var lineEndExtension = ([0-9.]+)', 0.5)
MARGIN = swift_const('PipelineTuning.swift', r'var lineEndMargin = ([0-9.]+)', 0.35)
GATE = swift_const('PipelineRemovalMask.swift', r'static let gateScale = ([0-9.]+)', 0.25)
CUT = EXT + GATE


# ---------------------------------------------------------------- data
def folds():
    return {p['page_id']: p['split'] if p['split'] in ('dev', 'test') else f"f{p['fold']}"
            for p in json.load(open(ws.MANIFEST))['pages']}


def load(prefix, lines_mode, jitter=None, train_only=False):
    """Rows of one run. jitter = (scale, copy): every line box moved by augment.Jitter (the run's own S3-vs-GT
    residuals of front.recognized, seed fixed per page and copy); train_only: train pages only."""
    prefix = Path(prefix); FOLD = folds()
    G = LF.gt_lines(ws.GT, ws.data('retrain', 'lineends', 'gt_lines.pkl'))
    tag = f'.j{jitter[0]:g}k{jitter[1]}' if jitter else ''
    cache = ws.data('retrain', 'lineends', f'{prefix.parent.name}-{prefix.name}.{lines_mode}.v{LF.VERSION}{tag}', 'x')
    cache.parent.mkdir(parents=True, exist_ok=True)
    gtkey = os.stat(ws.GT).st_mtime_ns
    res = AU.residuals(str(prefix), 'recognized') if jitter else None
    pages, t0, n = [], time.time(), 0
    for pid in sorted(FOLD):
        f = FOLD[pid]; sp = 'train' if f.startswith('f') else f
        if (train_only or jitter) and f not in TRAIN: continue
        pj, fj = Path(f'{prefix}_{sp}/pages/{pid}.json'), Path(f'{prefix}_{sp}/stages/{pid}.front.json')
        if not (pj.exists() and fj.exists()): continue
        key = (os.stat(fj).st_mtime_ns, os.stat(pj).st_mtime_ns, gtkey)
        cp = cache.parent / f'{pid}.pkl'
        d = None
        if cp.exists():
            d = pickle.load(open(cp, 'rb'))
            if d.get('key') != key: d = None
        if d is None:
            jit = None
            if jitter:
                J = AU.Jitter(res, jitter[0], seed=zlib.crc32(f'{pid}:{jitter[1]}'.encode()))
                jit = lambda b, J=J: J.box(b, (b[3] - b[1]) >= (b[2] - b[0]))
            d = LF.page(pid, pj, fj, lines_mode, G.get(pid, []), ws.EVAL / f'convmask/gt/{pid}.npz', jit=jit); d['key'] = key
            pickle.dump(d, open(cp, 'wb')); n += 1
        d['fold'] = f; pages.append(d)
    if n: print(f'# features: {n} pages computed in {time.time() - t0:.0f} s', file=sys.stderr)
    rows = collections.defaultdict(list)
    for d in pages:
        for it in d['lines']:
            for w in (0, 1):
                rows['X'].append(it['f'][w]); rows['pid'].append(d['pid']); rows['fold'].append(d['fold'])
                rows['wh'].append((d['W'], d['H'])); rows['ybox'].append(it['ybox'][w]); rows['yg'].append(it['yg'][w])
                rows['run'].append(it['run'][w]); rows['gb'].append(it['gb'][w]); rows['gl'].append(it['gl'][w])
    R = {k: np.array(v) for k, v in rows.items()}
    R['X'] = R['X'].astype(np.float32); R['ybox'] = R['ybox'].astype(float); R['yg'] = R['yg'].astype(float)
    R['train'] = np.isin(R['fold'], TRAIN)
    R['base'] = np.ones(len(R['X']), bool)
    return R


def parse_augment(spec):
    """'mix=RUN,RUN;jitter=SCALExN' (either part optional; RUN relative to $AIDOKU_EVAL_DIR/runs) -> dict."""
    out = dict(mix=[], jitter=None)
    for part in filter(None, re.split(r'[;\s]+', spec or '')):
        k, v = part.split('=', 1)
        if k == 'mix': out['mix'] = [x for x in v.split(',') if x]
        elif k == 'jitter':
            sc, nn = v.split('x'); out['jitter'] = (float(sc), int(nn))
        else: raise SystemExit(f'--augment: unknown part {k!r}')
    return out


def concat(Rs):
    R = {k: np.concatenate([r[k] for r in Rs]) for k in Rs[0]}
    return R


def load_augmented(prefix, lines_mode, spec):
    """The run's own rows (base) plus the augmentation rows (train pages only, base False): the train rows of
    every mix run other than RUN_PREFIX, and `jitter` N jittered copies of each run's train pages. Copies keep their
    page id, so every page-grouped fold keeps them on the page's side."""
    R = load(prefix, lines_mode)
    if not spec: return R
    a = parse_augment(spec)
    me = Path(prefix).resolve(); runs = [Path(prefix)]
    for m in a['mix']:
        p = Path(m) if os.path.isabs(m) else AU.run_path(m)
        if p.resolve() != me and p.resolve() not in [r.resolve() for r in runs]: runs.append(p)
    parts = [R]
    for k, p in enumerate(runs):
        if k: parts.append(load(p, lines_mode, train_only=True))
        if a['jitter'] and a['jitter'][0] > 0:
            for c in range(a['jitter'][1]): parts.append(load(p, lines_mode, jitter=(a['jitter'][0], c)))
    for r in parts[1:]: r['base'] = np.zeros(len(r['X']), bool)
    return concat(parts)


def subset(R, m):
    return {k: v[m] for k, v in R.items()}


def group_folds(R, scheme):
    """page = manifest folds; size = 3 groups of page W x H balanced by line ends; chunk = 3 page-id thirds.
    Groups are formed on the base rows and applied to every row by page id (augmentation copies follow their page)."""
    g = R['fold'].copy()
    if scheme == 'page': return g
    trm = R['train'] & R['base']; tp = sorted(set(R['pid'][trm]))
    if scheme == 'size':
        cnt = collections.Counter(map(tuple, R['wh'][trm]))
        load_ = {f: 0 for f in TRAIN}; of = {}
        for s, k in sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0])):
            f = min(load_, key=load_.get); of[s] = f; load_[f] += k
        wh = {p: tuple(w) for p, w in zip(R['pid'], R['wh'])}
        pg = {p: of[wh[p]] for p in tp}
    else:
        pg = {p: TRAIN[min(2, 3 * i // len(tp))] for i, p in enumerate(tp)}
    for n in np.nonzero(R['train'])[0]: g[n] = pg.get(R['pid'][n], g[n])
    return g


# ---------------------------------------------------------------- models
def fit_reg(R, m):
    m = m & np.isfinite(R['ybox'])
    return lgb.train(PRM_REG, lgb.Dataset(R['X'][m], np.clip(R['ybox'][m], *YCLIP_REG)), NT_REG)


def fit_clf(R, m):
    m = m & np.isfinite(R['yg'])
    return lgb.train(PRM_CLF, lgb.Dataset(R['X'][m], (R['yg'][m] > CUT).astype(float)), NT_CLF)


def reach(R, off, p):
    """S6 search reach past each end (T): max(ext, offset + margin); a gated fire reaches the capped ink run + pad."""
    app = np.maximum(EXT, off + MARGIN)
    edge = R['X'][:, EDGE].astype(float)
    fire = (edge < 9) & (p >= TAU)
    ext = np.minimum(R['run'], np.maximum(edge, 0)) + RUN_PAD
    return np.where(fire, np.maximum(app, ext), app), fire


def stage_metric(R, s, off, m):
    """under / over / over>1T / pxMiss over ends in m with a glyph target, and the regressor MAE over m."""
    k = m & np.isfinite(R['yg']); y = np.clip(R['yg'][k], *YCLIP); d = s[k] - y
    hi = (s[k] + GATE)[:, None]; B0 = LB[None, :]
    w = np.clip(np.minimum(B0 + 0.1, hi) - np.maximum(B0, 0), 0, 0.1) / 0.1
    g = R['gb'][k] * (B0 >= 0); tot = R['gl'][k].sum() / 2
    b = m & np.isfinite(R['ybox'])
    return dict(n=int(k.sum()), under=float(np.mean(y > s[k] + GATE)), over=float(np.mean(np.maximum(0, d))),
                over1=float(np.mean(d > 1.0)), px=float((g * (1 - w)).sum() / max(tot, 1)),
                mae=float(np.mean(np.abs(np.clip(R['ybox'][b], *YCLIP_REG) - off[b]))))


def fmt(name, sp, mt, fire):
    return (f"| {name} | {sp} | {mt['n']} | {mt['mae']:.4f} | {mt['under']*100:.2f}% | {mt['over']:.3f} | "
            f"{mt['over1']*100:.2f}% | {mt['px']*100:.3f}% | {fire*100:.2f}% |")


# ---------------------------------------------------------------- export / read
def clf_json(b):
    """Flat trees, `Float(x[f]) <= t` goes left, a negative child is leaf -c-1 (PipelineOutlineWidthModel.Tree)."""
    trees = []
    for t in b.dump_model()['tree_info']:
        f_, t_, l_, r_, v_ = [], [], [], [], []
        def add(n):
            if 'leaf_value' in n:
                v_.append(n['leaf_value']); return -len(v_)
            i = len(f_); f_.append(n['split_feature']); t_.append(n['threshold']); l_.append(0); r_.append(0)
            assert n['decision_type'] == '<='
            l_[i] = add(n['left_child']); r_[i] = add(n['right_child']); return i
        root = add(t['tree_structure'])
        if root < 0: f_, t_, l_, r_ = [0], [0.0], [root], [root]
        trees.append(dict(f=f_, t=t_, l=l_, r=r_, v=v_))
    return dict(features=b.num_feature(), threshold=float(np.log(TAU / (1 - TAU))), trees=trees)


def clf_raw(model, X):
    z = np.zeros(len(X)); X = X.astype(np.float32).astype(np.float64)
    for t in model['trees']:
        f, th, l, r, v = (np.array(t[k]) for k in 'ftlrv')
        node = np.zeros(len(X), int); act = node >= 0
        while act.any():
            n = node[act]; go = X[act, f[n]] <= th[n]
            node[act] = np.where(go, l[n], r[n]); act = node >= 0
        z += v[-node - 1]
    return z


def read_forests(path):
    """[(raw bytes, forest dict)] of every forest slot (after the two retired MLP tables)."""
    data = open(path, 'rb').read(); off = 0
    def table(fmt):
        nonlocal off
        n = struct.unpack_from('<I', data, off)[0]; s = struct.calcsize(fmt); o = off
        off += 4 + n * s; return np.frombuffer(data, '<' + fmt, n, o + 4), data[o:off]
    head = table('f')[1] + table('f')[1]; out = []
    while off < len(data):
        start = off; t = [table(c)[0] for c in 'dihdiid']
        sc = t[0]; out.append((data[start:off], dict(base=sc[0], rate=sc[1], roots=t[1], feature=t[2], threshold=t[3],
                                                     left=t[4], right=t[5], value=t[6])))
    assert off == len(data), 'trailing data'
    return head, out


def forest_logit(F, X):
    """PipelineStyleForest.logit (float32 compare) over rows of X."""
    X = X.astype(np.float32).astype(np.float64); z = np.full(len(X), F['base'])
    for r in F['roots']:
        node = np.full(len(X), r); act = F['left'][node] >= 0
        while act.any():
            n = node[act]; go = X[act, F['feature'][n]] <= F['threshold'][n]
            node[act] = np.where(go, F['left'][n], F['right'][n]); act = F['left'][node] >= 0
        z += F['rate'] * F['value'][node]
    return z


def write_reg(src_bin, dst_bin, booster):
    if Path(src_bin).resolve() != Path(dst_bin).resolve(): shutil.copyfile(src_bin, dst_bin)
    _, before = read_forests(dst_bin)
    assert len(before) >= REG_SLOT, 'weights file has fewer forests than expected'
    fl = FO.flatten(booster)
    FO.write(str(dst_bin), REG_SLOT, fl)
    _, after = read_forests(dst_bin)
    assert len(after) == REG_SLOT + 1
    for k in range(REG_SLOT): assert after[k][0] == before[k][0], f'slot {k} changed'
    return fl


def save(R, reg, clf, out_dir):
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True); res = {}
    if clf is not None:
        model = clf_json(clf)
        k = np.random.default_rng(0).choice(len(R['X']), min(3000, len(R['X'])), replace=False)
        diff = np.abs(clf.predict(R['X'][k], raw_score=True) - clf_raw(model, R['X'][k])).max()
        assert diff < 1e-9, f'classifier export differs from LightGBM by {diff}'
        p = out_dir / 'PipelineLineEnds.json'
        json.dump(model, open(p, 'w'), separators=(',', ':')); res['clf'] = p
        print(f'# classifier: {len(model["trees"])} trees, {sum(len(t["f"]) for t in model["trees"])} splits, '
              f'export max |raw diff| {diff:.1e}, {os.path.getsize(p)} bytes -> {p}', file=sys.stderr)
    if reg is not None:
        p = out_dir / 'PipelineWeights.bin'
        write_reg(ws.WEIGHTS if not p.exists() else p, p, reg)
        _, F = read_forests(p); F = F[REG_SLOT][1]
        diff = np.abs(forest_logit(F, R['X']) - reg.predict(R['X'])).max()
        assert diff < 1e-9, f'regressor round trip differs from LightGBM by {diff}'
        res['reg'] = p
        print(f'# regressor: {len(F["roots"])} trees, {len(F["feature"])} nodes; round-trip read of {REG_SLOT + 1} slots OK, '
              f'slots 0-{REG_SLOT - 1} byte-identical, max |logit diff| {diff:.1e} -> {p}', file=sys.stderr)
    return res


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('run_prefix')
    ap.add_argument('--out', help='directory for PipelineLineEnds.json and PipelineWeights.bin (default: the app resources)')
    ap.add_argument('--check', action='store_true'); ap.add_argument('--eval', action='store_true')
    ap.add_argument('--lines', choices=('blocks', 'recognized'), default='blocks')
    ap.add_argument('--only', choices=('reg', 'clf'))
    ap.add_argument('--augment', metavar='SPEC', help="training augmentation, off by default: 'mix=RUN,RUN', "
                    "'jitter=SCALExN' or both joined by ';' (SPEC['augment'] holds the proposed default)")
    a = ap.parse_args(); t0 = time.time()
    RA = load_augmented(a.run_prefix, a.lines, a.augment); R = subset(RA, RA['base']); trm = R['train']
    if a.augment:
        print(f"# augment {a.augment}: {len(RA['X'])} ends, {RA['train'].sum()} train ({(~RA['base']).sum()} added)", file=sys.stderr)
    print(f"# {a.lines} lines: {len(R['X'])} ends ({trm.sum()} train), regressor targets {np.isfinite(R['ybox'][trm]).sum()}, "
          f"classifier targets {np.isfinite(R['yg'][trm]).sum()} (positives {(R['yg'][trm] > CUT).sum()}); "
          f"ext {EXT} margin {MARGIN} gate {GATE}", file=sys.stderr)
    reg = fit_reg(RA, RA['train']) if a.only != 'clf' else None
    clf = fit_clf(RA, RA['train']) if a.only != 'reg' else None

    if a.check:
        with tempfile.TemporaryDirectory() as tmp:
            res = save(R, reg, clf, tmp)
            if 'clf' in res:
                cur, new = json.load(open(ws.REPO / CLF_RES)), json.load(open(res['clf']))
                same = open(ws.REPO / CLF_RES, 'rb').read() == open(res['clf'], 'rb').read()
                shape = [len(t['f']) for t in cur['trees']] == [len(t['f']) for t in new['trees']]
                md = max((max(np.abs(np.array(x[k], float) - np.array(y[k], float)).max() for k in 'tv')
                          for x, y in zip(cur['trees'], new['trees'])), default=0) if shape else float('nan')
                zc, zn = clf_raw(cur, R['X']), clf_raw(new, R['X'])
                gate = R['X'][:, EDGE] < 9
                fc, fn = zc >= cur['threshold'], zn >= new['threshold']
                print(f"check classifier: {'IDENTICAL' if same else 'differs'} (same tree shapes {shape}, max abs diff {md:.3g}); "
                      f"fire agreement {np.mean(fc == fn)*100:.3f}% of {len(fc)} ends, gated {np.mean((fc & gate) == (fn & gate))*100:.3f}% "
                      f"(gated fires current {int((fc & gate).sum())} new {int((fn & gate).sum())}); max |raw diff| {np.abs(zc - zn).max():.3g}")
            if 'reg' in res:
                _, cur = read_forests(ws.WEIGHTS); _, new = read_forests(res['reg'])
                same = cur[REG_SLOT][0] == new[REG_SLOT][0]
                others = all(cur[k][0] == new[k][0] for k in range(REG_SLOT))
                oc, on = forest_logit(cur[REG_SLOT][1], R['X']), forest_logit(new[REG_SLOT][1], R['X'])
                d = np.abs(oc - on); T = R['X'][:, 38].astype(float)
                rc = np.maximum(EXT, oc + MARGIN) * T; rn = np.maximum(EXT, on + MARGIN) * T
                print(f"check regressor: slot {REG_SLOT} {'IDENTICAL' if same else 'differs'}, other slots identical {others}; "
                      f"offset |diff| mean {d.mean():.4f} max {d.max():.4f} T, <0.01 T {np.mean(d < 0.01)*100:.2f}%, "
                      f"S6 reach within 0.5 px {np.mean(np.abs(rc - rn) < 0.5)*100:.2f}%, within 2 px {np.mean(np.abs(rc - rn) < 2)*100:.2f}% "
                      f"of {len(d)} ends")
    else:
        save(R, reg, clf, a.out or (ws.REPO / 'Aidoku/Resources/Translation'))

    if a.eval:
        print(f'| model | split | ends | regMAE (T) | under | over (T) | over>1T | pxMiss | fires |')
        print('|---|---|---|---|---|---|---|---|---|')
        def preds(rm, cm, m):
            off = rm.predict(R['X'][m]) if rm is not None else forest_logit(read_forests(ws.WEIGHTS)[1][REG_SLOT][1], R['X'][m])
            p = cm.predict(R['X'][m]) if cm is not None else 1 / (1 + np.exp(-clf_raw(json.load(open(ws.REPO / CLF_RES)), R['X'][m])))
            return off, p
        for sch in ('page', 'size', 'chunk'):
            gf = group_folds(R, sch); gfa = group_folds(RA, sch); off = np.zeros(len(R['X'])); p = np.zeros(len(R['X']))
            for f in TRAIN:
                tr, ho = RA['train'] & (gfa != f), trm & (gf == f)
                rm = fit_reg(RA, tr) if a.only != 'clf' else None
                cm = fit_clf(RA, tr) if a.only != 'reg' else None
                off[ho], p[ho] = preds(rm, cm, ho)
            s, fire = reach(R, off, p)
            print(fmt(f'new, {sch} LOFO', 'train', stage_metric(R, s, off, trm), fire[trm].mean()))
        for name, rm, cm in (('new', reg, clf), ('current', None, None)):
            off, p = preds(rm, cm, np.ones(len(R['X']), bool)); s, fire = reach(R, off, p)
            for sp in ('dev', 'test'):
                m = R['fold'] == sp; print(fmt(name, sp, stage_metric(R, s, off, m), fire[m].mean()))
    print(f'# runtime {time.time() - t0:.0f} s', file=sys.stderr)


if __name__ == '__main__':
    main()
