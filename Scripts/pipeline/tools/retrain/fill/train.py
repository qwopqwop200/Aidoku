"""Retrain the S8 fill colour models (PipelineStyle.swift): the fillPass1 / fillPass2 candidate forests in
Resources/Translation/PipelineWeights.bin (slots 0 and 1) and the fill peak ranker Resources/Translation/PipelineFillPeaks.json.

  train.py RUN_PREFIX [--out DIR] [--check] [--eval] [--keep-forests] [--stages PREFIX] [--rebuild]

Input: RUN_PREFIX_{train,dev,test}/pages/ID.json (final blocks: bounds, line polygons, sourceText length) plus the
page pixels; the GT-input blocks are the source_appearance GT paragraphs, with character counts from the recognised
S3 lines of `--stages PREFIX`/stages/ID.front.json (default RUN_PREFIX; front-only runs without stages/ need it).
The per-block pixel analyses (Python port of S8, s8.py) are cached under workspace.data('retrain', 'fill').

Method (old colorfix/train_fill_lgb.py + export_fill.py for the forests, port-eval/stageopt/fill R1 for the ranker):
  1. fillPass1 (no page consensus) and fillPass2 (consensus = median pass-1 pick of the page): LightGBM on the
     candidate features of every detected block matched to a GT paragraph (first matching paragraph per block),
     label = the candidate core nearest the GT fill when within dE 12. Hyper-parameters: grid binary / lambdarank
     x leaves 4/8/16 x trees 100/300 x rate .05/.1 x min-child 10/30, leave-one-fold-out over folds 2/3/4, criterion
     = held-out pick errors (core dE > 12). Pass 2 is selected and fitted on the final pass-1 consensus.
  2. Peak ranker: LambdaRank over the options (pass-2 pick + density peaks) of every GT-matched block of both inputs
     (detected and GT paragraphs), 16 peakFeatures + 10 axisFeatures, label = the pick when within dE 12, else the
     nearest option when within dE 12. Grid leaves 4/8 x trees 100/300 x rate .05/.1 x min-child 10/30, LOFO over
     folds 2/3/4 with the full decision + page unification, criterion = detected + GT-input fill errors.
  --keep-forests leaves the forests as they are and retrains the ranker only (the way the shipped ranker was made).
Fit on manifest split == train pages only; all seeds fixed, n_jobs=1.

--augment SPEC (off by default; without it the output is unchanged) adds training copies of the train pages,
detected input only (the GT-input paragraphs are GT geometry and stay single); parts joined by ';':
  mix=RUN,RUN      the detected blocks + pixel analyses of other host runs (prefixes under $AIDOKU_EVAL_DIR/runs or
                   absolute; RUN_PREFIX itself is skipped), e.g. mix=speed2/all830,speed2/base830
  jitter=SxN       N copies of RUN_PREFIX's detected blocks with every line box (polygon and sizing quad, same map)
                   moved by retrain/augment.py Jitter at scale S (S3-vs-GT residuals of RUN_PREFIX, refined boxes),
                   block bounds rebuilt; seeds 1..N, per page crc32. The blocks are re-matched to GT and re-analysed.
Labels stay the GT fills. Copies keep their page's fold, so LOFO folds hold all copies of a page out together; only
the RUN_PREFIX pages are scored (selection and metric).

--out DIR writes PipelineFillPeaks.json and PipelineWeights.bin into DIR (the bin = the current repo file with slots
0/1 replaced); default: the app resources. --check trains into a temp dir and compares. --eval prints the fill metric
(GT paragraphs with dE76(fill, GT fill) > 12, median dE, same-colour pair inconsistency) for chained train LOFO
(pass 1, pass 2 and ranker refit without the fold) and dev/test, next to the current resources.
"""
import argparse, collections, zlib, hashlib, itertools, json, math, os, pickle, shutil, statistics, struct, sys, tempfile, time
import warnings
from pathlib import Path
import numpy as np
import lightgbm as lgb

warnings.filterwarnings('ignore')
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1])); sys.path.insert(0, str(HERE.parents[1] / 'colorfix')); sys.path.insert(0, str(HERE))
import workspace as ws  # noqa: E402
import forest  # noqa: E402  (colorfix/forest.py: LightGBM -> PipelineWeights.bin forest tables)
import s8  # noqa: E402
sys.path.append(str(HERE.parent))  # retrain/ (appended: its train.py must not shadow this one)
import augment  # noqa: E402  (retrain/augment.py)

RANKER = 'Aidoku/Resources/Translation/PipelineFillPeaks.json'
WEIGHTS = 'Aidoku/Resources/Translation/PipelineWeights.bin'
SPEC = {
    'name': 'fill',
    'resource': [RANKER, WEIGHTS + ' (forest slots 0 fillPass1, 1 fillPass2)'],
    'stage': 'S8',
    'inputs': 'pages/ID.json blocks (final S4-grouped blocks: bounds, line polygons, sourceText length) + page '
              'pixels; front.recognized (S3 lines, character counts of the GT-input paragraphs); '
              'source_appearance GT (fill.rgb)',
    'needs_full': False,
    'rerun_from': 's8',
    # The driver retrains the peak ranker only: refit fill forests could not beat the shipped ones on dev/test.
    'train_args': ['--keep-forests'],
    # Suggested --augment for the ranker (2026-11-26 study, port-eval/retrain/fill/aug): train LOFO page 44 / size 70 /
    # chunk 57 det+gt errors vs 48/70/57 without; cross-run all830 -> ref 46 vs 52; dev/test 28/49 vs 31/51. Not in
    # train_args: the lead decides. The mix should name the eval run's sibling (pre-refine) run.
    'augment': 'mix=retune/snap2/ref,speed2/all830;jitter=0.5x1',
}
TRAIN = ['f2', 'f3', 'f4']
SPLITS = ('train', 'dev', 'test')
T_ERR = 12.0
PASS_GRID = [dict(obj=o, num_leaves=l, n_estimators=n, learning_rate=r, min_child_samples=s)
             for o, l, n, r, s in itertools.product(['binary', 'rank'], [4, 8, 16], [100, 300], [0.05, 0.1], [10, 30])]
RANK_GRID = [dict(num_leaves=l, n_estimators=n, learning_rate=r, min_child_samples=s)
             for l, n, r, s in itertools.product([4, 8], [100, 300], [0.05, 0.1], [10, 30])]
SLOTS = {'fillPass1': 0, 'fillPass2': 1}
ORDER = ['f', 'f'] + ['d', 'i', 'h', 'd', 'i', 'i', 'd'] * 5  # two stage tables + 5 forests (PipelineWeights.swift)


def log(*a): print(*a, flush=True)


# ---------------------------------------------------------------- inputs
def folds():
    return {p['page_id']: (p['split'] if p['split'] in ('dev', 'test') else f"f{p['fold']}")
            for p in json.load(open(ws.MANIFEST))['pages']}


def gt_items():
    """{page: [GT paragraph]} from source_appearance records, cached per GT file version."""
    st = os.stat(ws.GT); key = f'{ws.GT}:{st.st_size}:{st.st_mtime_ns}'
    f = ws.data('retrain', 'fill', 'gt_items.pkl')
    if f.exists():
        k, v = pickle.load(open(f, 'rb'))
        if k == key: return v
    out = collections.defaultdict(list)
    for r in json.load(open(ws.GT))['records']:
        if r.get('scope') != 'source_appearance': continue
        l = r['label']; x0, y0 = l['cropBounds'][:2]
        polys = l.get('individualPolygonsCrop') or [l['mergedPolygonCrop']]
        polys = [[(p[0] + x0, p[1] + y0) for p in q] for q in polys]
        xs = [p[0] for q in polys for p in q]; ys = [p[1] for q in polys for p in q]
        out[l['page']].append(dict(box=(min(xs), min(ys), max(xs), max(ys)), polys=polys, fill=l['fill']['rgb']))
    out = dict(out)
    pickle.dump((key, out), open(f, 'wb'))
    return out


def match(items, blocks):
    """colorfix/errors.py rule: the block whose bounds cover the largest share of the GT box, kept at >= 0.5."""
    m = {}
    for gi, it in enumerate(items):
        a, b, c, e = it['box']; area = max(1e-9, (c - a) * (e - b)); best, cov = None, 0
        for k, blk in enumerate(blocks):
            (x, y), (w, h) = blk['bounds']
            ix = max(0, min(x + w, c) - max(x, a)) * max(0, min(y + h, e) - max(y, b)) / area
            if ix > cov: best, cov = k, ix
        if best is not None and cov >= 0.5: m[gi] = best
    return m


def pages(prefix, stages):
    """Ordered {pid: page}: split dirs train/dev/test, file names sorted."""
    G = gt_items(); FOLD = folds(); out = {}
    for split in SPLITS:
        d = Path(f'{prefix}_{split}') / 'pages'
        for fn in sorted(os.listdir(d)):
            if not fn.endswith('.json'): continue
            r = json.load(open(d / fn)); pid = r['pageID']
            det = [dict(bounds=b['bounds'], lines=[l['polygon'] for l in b['lines']], chars=len(b.get('sourceText') or ''),
                        size_bounds=b.get('measureBounds') or b['bounds'],
                        size_lines=[l.get('measure') or l['polygon'] for l in b['lines']])
                   for b in r['blocks']]
            items = G.get(pid, [])
            st = json.load(open(Path(f'{stages}_{split}') / 'stages' / f'{pid}.front.json'))
            rec = [(l['bounds'], len(l.get('text') or '')) for l in st['recognized']]
            gtb = []
            for it in items:
                a, b_, c, e = it['box']
                ch = sum(n for (p, sz), n in rec if a <= p[0] + sz[0] / 2 <= c and b_ <= p[1] + sz[1] / 2 <= e)
                gtb.append(dict(bounds=[[a, b_], [c - a, e - b_]], lines=it['polys'], chars=ch))
            out[pid] = dict(split=split, fold=FOLD[pid], image=r['image'], det=det, gt=gtb, items=items, match=match(items, det),
                            size=(r.get('width'), r.get('height')))
    return out


ANALYSIS_VERSION = 'hamming-1'  # bump when s8.analyze changes
LITE = ('font', 'scale', 'ringBackground', 'clusters', 'modes', 'profiles')


def lite(A):
    """The analysis without pixel planes, with the ring profile of every valid candidate (any can become the pick)."""
    if A is None: return None
    for j in range(len(A['clusters'])):
        if s8.valid(A['clusters'][j]): s8.profile(A, j)
    return {k: A[k] for k in LITE}


def analyses(P, prefix, stages, rebuild=False, tag='', inputs=('det', 'gt')):
    """{pid: {det|gt: (fonts, [lite analysis])}}, cached per run + block content (+ tag/inputs for augment copies)."""
    if inputs == ('det', 'gt'): key = [ANALYSIS_VERSION] + [(pid, p['det'], p['gt']) for pid, p in P.items()]
    else: key = [ANALYSIS_VERSION, list(inputs)] + [(pid, [p[w] for w in inputs]) for pid, p in P.items()]
    h = hashlib.sha1(json.dumps(key).encode()).hexdigest()[:12]
    f = ws.data('retrain', 'fill', f'an_{Path(prefix).name}{tag}_{h}.pkl')
    if f.exists() and not rebuild: return pickle.load(open(f, 'rb'))
    out = {}; t0 = time.time()
    for n, (pid, p) in enumerate(P.items()):
        img = s8.load_page(p['image']); rec = {}
        for which in inputs:
            fonts = s8.font_estimate(p[which])
            rec[which] = (fonts, [lite(s8.analyze(img, b['bounds'], b['lines'], fz)) for b, fz in zip(p[which], fonts)])
        out[pid] = rec
        if n % 100 == 0: log(f'  analysed {n}/{len(P)} pages, {time.time() - t0:.0f}s')
    pickle.dump(out, open(f, 'wb'))
    return out


# ---------------------------------------------------------------- augmentation
def parse_augment(spec):
    """'mix=a,b;jitter=1.0x2' -> dict(mix=[run], jitter=(scale, copies))."""
    out = dict(mix=[], jitter=(0.0, 0))
    for part in filter(None, (q.strip() for q in (spec or '').split(';'))):
        k, v = part.split('=', 1)
        if k == 'mix': out['mix'] = [r for r in v.split(',') if r]
        elif k == 'jitter':
            sc, n = v.split('x'); out['jitter'] = (float(sc), int(n))
        else: raise SystemExit(f'--augment: unknown part {k!r}')
    return out


def run_prefix(name):
    return str(Path(name)) if os.path.isabs(name) else str(augment.run_path(name))


def jitter_blocks(raw, J):
    """Page-JSON blocks -> det block dicts with every line's box jittered; polygon and sizing quad follow the same
    per-axis map from the old box onto the new one; bounds (and measure bounds) = union of the moved points."""
    det = []
    for b in raw:
        lines, meas = [], []
        for l in b['lines']:
            ob = augment.rect(l['bounds']); nb = J.box(ob, bool(l['vertical']))
            sx = (nb[2] - nb[0]) / max(ob[2] - ob[0], 1e-6); sy = (nb[3] - nb[1]) / max(ob[3] - ob[1], 1e-6)
            mp = lambda q: [nb[0] + (q[0] - ob[0]) * sx, nb[1] + (q[1] - ob[1]) * sy]
            lines.append([mp(q) for q in l['polygon']])
            meas.append([mp(q) for q in (l.get('measure') or l['polygon'])])
        def union(qs):
            xs = [q[0] for p in qs for q in p]; ys = [q[1] for p in qs for q in p]
            return [[min(xs), min(ys)], [max(xs) - min(xs), max(ys) - min(ys)]]
        bounds = union(lines) if lines else b['bounds']
        sb = (union(meas) if lines else b['measureBounds']) if b.get('measureBounds') else bounds
        det.append(dict(bounds=bounds, lines=lines, chars=len(b.get('sourceText') or ''), size_bounds=sb, size_lines=meas))
    return det


def jitter_pages(P, prefix, scale, seed):
    """{pid: page} of the train pages of P with jittered detected blocks (det input only), re-matched to GT."""
    res = augment.residuals(prefix, 'recognized'); out = {}
    for pid, p in P.items():
        if p['fold'] not in TRAIN or p.get('copy'): continue
        r = json.load(open(Path(f'{prefix}_{p["split"]}') / 'pages' / f'{pid}.json'))
        det = jitter_blocks(r['blocks'], augment.Jitter(res, scale, zlib.crc32(f'{seed}:{pid}'.encode())))
        out[pid] = dict(p, det=det, gt=[], match=match(p['items'], det))
    return out


def copy_pages(Q, AQ, tag):
    """Training copies (det input only) of the train pages of Q, keyed tag|pid, fold and group of their page."""
    P, AN = {}, {}
    for pid, q in Q.items():
        if q['fold'] not in TRAIN: continue
        P[f'{tag}|{pid}'] = dict(q, gt=[], copy=tag, group=pid, inputs=('det',))
        AN[f'{tag}|{pid}'] = {'det': AQ[pid]['det']}
    return P, AN


def augment_data(P, AN, prefix, spec, rebuild=False):
    """P, AN extended with the copies of --augment SPEC (see the module doc)."""
    A = parse_augment(spec); P, AN = dict(P), dict(AN)
    for run in A['mix']:
        rp = run_prefix(run)
        if Path(rp).resolve() == Path(prefix).resolve(): continue
        Q = pages(rp, rp); AQ = analyses(Q, rp, rp, rebuild)
        p2, a2 = copy_pages(Q, AQ, 'mix:' + run); P.update(p2); AN.update(a2)
        log(f'  augment mix {run}: {len(p2)} train pages')
    scale, n = A['jitter']
    for seed in range(1, n + 1):
        Q = jitter_pages(P, prefix, scale, seed)
        AQ = analyses(Q, prefix, prefix, rebuild, tag=f'_j{scale:g}s{seed}', inputs=('det',))
        p2, a2 = copy_pages(Q, AQ, f'jit{scale:g}s{seed}'); P.update(p2); AN.update(a2)
        log(f'  augment jitter {scale:g} seed {seed}: {len(p2)} train pages')
    return P, AN


def inputs(p): return p.get('inputs', ('det', 'gt'))


def base_pids(P, pids): return [q for q in pids if not P[q].get('copy')]


def matched(p, which):
    """(GT index, block index) pairs: every GT paragraph of the GT input, matched paragraphs of the detected input."""
    return [(gi, gi) for gi in range(len(p['items']))] if which == 'gt' else list(p['match'].items())


# ---------------------------------------------------------------- weights file
def read_tables(path):
    data = open(path, 'rb').read(); off = 0; chunks = []
    for fmt in ORDER:
        if off >= len(data): break
        n = struct.unpack_from('<I', data, off)[0]; size = 4 + n * struct.calcsize(fmt)
        chunks.append(data[off:off + size]); off += size
    assert off == len(data), 'unexpected PipelineWeights.bin layout'
    return chunks


def pack_forest(fr):
    """forest.py tables (scalars [base 0, rate 1], roots, feature, threshold, left, right, value) as bytes."""
    tables = zip('dihdiid', ([0.0, 1.0],) + tuple(fr))
    return [struct.pack('<I', len(xs)) + struct.pack('<' + fmt * len(xs), *xs) for fmt, xs in tables]


def write_slots(src, dst, forests):
    """Copy the weights file with only the given forest slots replaced ({slot: forest.flatten tables}); other slots
    byte-identical. forest.write() keeps a prefix and drops later slots, so slots 0/1 are spliced in place here with
    forest.py's table layout."""
    chunks = read_tables(src)
    for slot, fr in forests.items():
        a = 2 + 7 * slot
        chunks[a:a + 7] = pack_forest(fr)
    open(dst, 'wb').write(b''.join(chunks))
    # round trip: every slot readable, replaced slots equal, the rest unchanged
    new, old = read_tables(dst), read_tables(src)
    assert len(new) == len(old)
    for slot in range((len(old) - 2) // 7):
        a = 2 + 7 * slot
        if slot in forests: assert new[a:a + 7] == pack_forest(forests[slot]), slot
        else: assert new[a:a + 7] == old[a:a + 7], slot
    assert new[:2] == old[:2]
    W = s8.load_weights(dst)
    for slot, fr in forests.items():
        f = W[['fillPass1', 'fillPass2'][slot]]
        assert list(f.roots) == list(fr[0]) and list(f.val) == list(fr[5])


def as_forest(fr): return s8.Forest(0.0, 1.0, *fr)


# ---------------------------------------------------------------- pass-1 / pass-2 forests
def pass_rows(P, AN, pids, consensus_of):
    """Per detected block matched to GT (first paragraph per block): (fold, X, candidate cores, GT fill).
    consensus_of(pid) -> page consensus or None (pass 1)."""
    rows = []
    for pid in pids:
        p = P[pid]; seen = set(); cons = consensus_of(pid)
        for gi, k in p['match'].items():
            if k in seen: continue
            seen.add(k); A = AN[pid]['det'][1][k]
            if A is None: continue
            ids, X = s8.cand_matrix(A, cons)
            if not ids: continue
            rows.append((p['fold'], X, [A['clusters'][j]['core'] for j in ids], list(p['items'][gi]['fill']), bool(p.get('copy'))))
    return rows


def onehot(cores, gt):
    ds = [s8.dE(list(c), gt) for c in cores]; j = int(np.argmin(ds))
    return None if ds[j] > T_ERR else np.eye(len(cores))[j]


def fit_pass(rows, folds_, hp):
    X, y, g = [], [], []
    for f, Xb, cores, gt, *_ in rows:
        if f not in folds_: continue
        l = onehot(cores, gt)
        if l is None: continue
        X.append(Xb); y.append(l); g.append(len(l))
    hp = dict(hp); obj = hp.pop('obj')
    if obj == 'rank':
        m = lgb.LGBMRanker(objective='lambdarank', random_state=0, n_jobs=1, verbose=-1, **hp); m.fit(np.vstack(X), np.concatenate(y), group=g)
    else:
        m = lgb.LGBMClassifier(random_state=0, n_jobs=1, verbose=-1, **hp); m.fit(np.vstack(X), np.concatenate(y))
    return m


def pass_errors(m, rows, f):
    return sum(s8.dE(list(cores[int(np.argmax(m.predict(Xb, raw_score=True)))]), gt) > T_ERR
               for fold, Xb, cores, gt, cp in rows if fold == f and not cp)


def select_pass(rows, name):
    res = []
    for hp in PASS_GRID:
        cv = sum(pass_errors(fit_pass(rows, [f for f in TRAIN if f != h], hp), rows, h) for h in TRAIN)
        res.append((cv, hp))
    res.sort(key=lambda r: r[0])
    log(f'  {name}: LOFO pick errors best {res[0][0]} {res[0][1]} (grid of {len(res)}, worst {res[-1][0]})')
    return res[0][1]


def consensus_fn(AN, f1):
    def cons(pid):
        picks = []
        for A in AN[pid]['det'][1]:
            if A is None: continue
            r = s8.scored_pick(A, f1, None)
            if r: picks.append(A['clusters'][r[0]]['core'])
        return s8.cmedian(picks) if picks else None
    return cons


def fit_forests(P, AN, train_pids, hp1=None, hp2=None, folds_=TRAIN):
    """-> (pass-1 tables, pass-2 tables, hp1, hp2). Selects hp by LOFO when not given."""
    rows1 = pass_rows(P, AN, train_pids, lambda pid: None)
    hp1 = hp1 or select_pass(rows1, 'fillPass1')
    f1 = forest.flatten(fit_pass(rows1, folds_, hp1).booster_)
    rows2 = pass_rows(P, AN, train_pids, consensus_fn(AN, as_forest(f1)))
    hp2 = hp2 or select_pass(rows2, 'fillPass2')
    f2 = forest.flatten(fit_pass(rows2, folds_, hp2).booster_)
    return f1, f2, hp1, hp2


# ---------------------------------------------------------------- peak ranker
def decide_all(P, AN, W, pids):
    """Pre-ranker decisions (pass 1, pass 2, outline, peak options) per page and input."""
    return {pid: {w: s8.decide(AN[pid][w][1], AN[pid][w][0], W) for w in inputs(P[pid])} for pid in pids}


def rank_groups(P, AN, D, pids):
    """{pid: [(X 26 features, option dE to GT)]} over GT-matched blocks of both inputs."""
    G = {}
    for pid in pids:
        p = P[pid]; L = []
        for which in inputs(p):
            res = D[pid][which]; an = AN[pid][which][1]
            for gi, k in matched(p, which):
                r = res[k]
                if 'peakcols' not in r: continue
                cols = r['peakcols']
                X = s8.axis_features(an[k], cols, r['peakX'], r['ocol'], r['pick'])
                gt = list(p['items'][gi]['fill'])
                L.append((X, [s8.dE(list(c), gt) for c in cols]))
        G[pid] = L
    return G


def rank_label(ds):
    if ds[0] <= T_ERR: j = 0
    else:
        j = int(np.argmin(ds))
        if ds[j] > T_ERR: return None
    return np.eye(len(ds))[j]


def fit_ranker(G, pids, hp):
    X, y, g = [], [], []
    for pid in pids:
        for Xb, ds in G[pid]:
            l = rank_label(ds)
            if l is None: continue
            X.append(Xb); y.append(l); g.append(len(l))
    m = lgb.LGBMRanker(objective='lambdarank', random_state=0, n_jobs=1, verbose=-1, **hp)
    m.fit(np.vstack(X), np.concatenate(y), group=g)
    return m


def flatten_ranker(booster):
    """LightGBM -> PipelineFillPeaks.json trees (`x[f] <= t` left, negative child = leaf -child-1)."""
    trees = []
    for t in booster.dump_model()['tree_info']:
        f, th, l, r, v = [], [], [], [], []
        def add(n):
            if 'leaf_value' in n:
                v.append(n['leaf_value']); return -len(v)
            assert n['decision_type'] == '<=' and n.get('missing_type', 'None') in ('None', None), n
            i = len(f); f.append(n['split_feature']); th.append(n['threshold']); l.append(0); r.append(0)
            l[i] = add(n['left_child']); r[i] = add(n['right_child'])
            return i
        root = add(t['tree_structure'])
        if root < 0: f, th, l, r = [0], [1e300], [-1], [-1]
        trees.append(dict(f=f, t=th, l=l, r=r, v=v))
    return trees


def lgb_picker(m):
    return lambda A, cols, X, ocol, j: int(np.argmax(m.predict(s8.axis_features(A, cols, X, ocol, j))))


def finish(P, AN, D, pids, picker_of):
    """Apply a per-page option picker to the pre-ranker decisions, then unify -> {pid: {which: [fill]}}."""
    out = {}
    for pid in pids:
        out[pid] = {}
        pick = picker_of(pid)
        for which in ('det', 'gt'):
            res = [dict(r) for r in D[pid][which]]; an = AN[pid][which][1]
            if pick is not None:
                for k, r in enumerate(res):
                    if 'peakcols' in r:
                        b = pick(an[k], r['peakcols'], r['peakX'], r['ocol'], r['pick']); r['fill'] = s8.rgb8(r['peakcols'][b])
            out[pid][which] = [x['fill'] for x in s8.unify(res, [b['chars'] for b in P[pid][which]])]
    return out


def select_ranker(P, AN, D, G, train_pids):
    res = []
    for hp in RANK_GRID:
        M = {f: fit_ranker(G, [q for q in train_pids if P[q]['fold'] != f], hp) for f in TRAIN}
        preds = finish(P, AN, D, base_pids(P, train_pids), lambda pid: lgb_picker(M[P[pid]['fold']]))
        e = sum(table(P, preds, w)['train'][0] for w in ('det', 'gt'))
        res.append((e, hp))
    res.sort(key=lambda r: r[0])
    log(f'  ranker: LOFO fill errors det+gt best {res[0][0]} {res[0][1]} (grid of {len(res)}, worst {res[-1][0]})')
    return res[0][1]


# ---------------------------------------------------------------- metric
def scored(P, preds, which):
    for pid, p in P.items():
        if pid not in preds or p.get('copy'): continue
        fills = preds[pid][which]
        for gi, it in enumerate(p['items']):
            k = gi if which == 'gt' else p['match'].get(gi)
            if k is None or fills[k] is None: continue
            yield p['fold'], pid, it, fills[k], s8.dE(list(fills[k]), list(it['fill']))


def table(P, preds, which):
    E = collections.defaultdict(list)
    for fold, pid, it, f, d in scored(P, preds, which):
        E['train' if fold in TRAIN else fold].append(d)
    return {k: (sum(d > T_ERR for d in v), len(v), statistics.median(v) if v else float('nan')) for k, v in
            ((k, E.get(k, [])) for k in ('train', 'dev', 'test'))}


def inconsistency(P, preds, which):
    """Same-page GT pairs with GT fills within dE 6 whose predicted fills differ by more than dE 6."""
    by = collections.defaultdict(list); c = collections.Counter()
    for fold, pid, it, f, d in scored(P, preds, which): by[('train' if fold in TRAIN else fold, pid)].append((it['fill'], f))
    for (key, pid), L in by.items():
        for (g1, f1), (g2, f2) in itertools.combinations(L, 2):
            if s8.dE(list(g1), list(g2)) > 6: continue
            c[key] += s8.dE(list(f1), list(f2)) > 6
    return {k: c[k] for k in ('train', 'dev', 'test')}


def report(name, P, preds):
    for w in ('det', 'gt'):
        t = table(P, preds, w); inc = inconsistency(P, preds, w)
        log(f'{name:34} {w:3} errors dE>12 ' + '  '.join(f'{k} {t[k][0]}/{t[k][1]}' for k in t) +
            ' | median dE ' + ' '.join(f'{t[k][2]:.2f}' for k in t) +
            ' | inconsistent pairs ' + '/'.join(str(inc[k]) for k in inc))


# ---------------------------------------------------------------- driver
def load_ranker(path):
    m = json.load(open(path)); assert m['features'] == 26
    return m['trees']


def train(P, AN, args):
    """-> dict(trees, f1, f2 (None with --keep-forests), hp, W, D, G)."""
    train_pids = [pid for pid in P if P[pid]['fold'] in TRAIN]
    W = s8.load_weights(ws.REPO / WEIGHTS)
    out = dict(f1=None, f2=None)
    if not args.keep_forests:
        t = time.time()
        f1, f2, hp1, hp2 = fit_forests(P, AN, train_pids)
        W = dict(W, fillPass1=as_forest(f1), fillPass2=as_forest(f2))
        out.update(f1=f1, f2=f2, hp1=hp1, hp2=hp2); log(f'  forests {time.time() - t:.0f}s')
    t = time.time()
    D = decide_all(P, AN, W, list(P))
    G = rank_groups(P, AN, D, train_pids)
    hp = select_ranker(P, AN, D, G, train_pids)
    m = fit_ranker(G, train_pids, hp)
    trees = flatten_ranker(m.booster_)
    diff = max(abs(s8.tree_score(trees, x) - r) for pid in train_pids for Xb, _ in G[pid] for x, r in zip(Xb, m.predict(Xb)))
    log(f'  ranker {len(trees)} trees, max |flat - lightgbm| {diff:.2e}, {time.time() - t:.0f}s')
    out.update(trees=trees, hp=hp, W=W, D=D, G=G)
    return out


def write(res, outdir):
    outdir = Path(outdir); outdir.mkdir(parents=True, exist_ok=True)
    json.dump(dict(features=26, trees=res['trees']), open(outdir / Path(RANKER).name, 'w'), separators=(',', ':'))
    dst = outdir / Path(WEIGHTS).name; src = ws.REPO / WEIGHTS
    if res['f1'] is not None:
        tmp = outdir / (Path(WEIGHTS).name + '.tmp')
        write_slots(src, tmp, {0: res['f1'], 1: res['f2']}); os.replace(tmp, dst)
    elif dst.resolve() != src.resolve():
        shutil.copy(src, dst)
    log('wrote', outdir / Path(RANKER).name, dst)


def check(P, AN, res, outdir):
    cur_json = ws.REPO / RANKER; cur_bin = ws.REPO / WEIGHTS
    a, b = json.load(open(cur_json)), json.load(open(Path(outdir) / Path(RANKER).name))
    if a == b: log('PipelineFillPeaks.json: identical')
    else:
        same = len(a['trees']) == len(b['trees']) and all(
            (x['f'], x['l'], x['r']) == (y['f'], y['l'], y['r']) for x, y in zip(a['trees'], b['trees']))
        md = max(max(abs(u - v) for u, v in zip(x['t'] + x['v'], y['t'] + y['v'])) for x, y in zip(a['trees'], b['trees'])) if same else None
        log(f"PipelineFillPeaks.json: differs; trees {len(a['trees'])} vs {len(b['trees'])}, same structure {same}, max abs diff {md}")
    old, new = read_tables(cur_bin), read_tables(Path(outdir) / Path(WEIGHTS).name)
    for name, slot in SLOTS.items():
        same = old[2 + 7 * slot: 9 + 7 * slot] == new[2 + 7 * slot: 9 + 7 * slot]
        log(f'PipelineWeights.bin slot {slot} {name}: {"identical" if same else "differs"}')
    log(f'PipelineWeights.bin other slots identical: {old[:2] + old[16:] == new[:2] + new[16:]}')
    # prediction agreement on every block of the run (both inputs, all splits)
    Wc = s8.load_weights(cur_bin); Wn = s8.load_weights(Path(outdir) / Path(WEIGHTS).name)
    rc, rn = s8.flat_ranker(load_ranker(cur_json)), s8.flat_ranker(res['trees'])
    c = collections.Counter()
    for pid in base_pids(P, P):
        for w in ('det', 'gt'):
            fonts, an = AN[pid][w]
            dc, dn = s8.decide(an, fonts, Wc, rc), s8.decide(an, fonts, Wn, rn)
            ch = [b['chars'] for b in P[pid][w]]
            uc, un = s8.unify(dc, ch), s8.unify(dn, ch)
            for k in range(len(an)):
                if an[k] is None: continue
                c[w, 'n'] += 1
                c[w, 'pick'] += dc[k].get('pick') == dn[k].get('pick')
                c[w, 'fill'] += tuple(dc[k]['fill']) == tuple(dn[k]['fill'])
                c[w, 'final'] += tuple(uc[k]['fill']) == tuple(un[k]['fill'])
    for w in ('det', 'gt'):
        n = c[w, 'n']
        log(f'agreement {w}: {n} blocks; pass-2 pick {c[w, "pick"] / n:.4%}, fill before unify {c[w, "fill"] / n:.4%}, '
            f'final fill {c[w, "final"] / n:.4%}')


def evaluate(P, AN, res, args):
    train_pids = [pid for pid in P if P[pid]['fold'] in TRAIN]
    held = [pid for pid in P if P[pid]['fold'] not in TRAIN]
    # current resources
    Wc = s8.load_weights(ws.REPO / WEIGHTS); rc = s8.flat_ranker(load_ranker(ws.REPO / RANKER))
    B = base_pids(P, P)
    Dc = decide_all(P, AN, Wc, B)
    report('current resources (in-sample train)', P, finish(P, AN, Dc, B, lambda pid: rc))
    # chained LOFO on train folds with the selected hyper-parameters; dev/test with the final models
    preds = {}
    for f in TRAIN:
        tr = [q for q in train_pids if P[q]['fold'] != f]; te = base_pids(P, [q for q in train_pids if P[q]['fold'] == f])
        W = res['W']
        if not args.keep_forests:
            f1, f2, _, _ = fit_forests(P, AN, tr, res['hp1'], res['hp2'], folds_=[g for g in TRAIN if g != f])
            W = dict(W, fillPass1=as_forest(f1), fillPass2=as_forest(f2))
        D = decide_all(P, AN, W, tr + te)
        G = rank_groups(P, AN, D, tr)
        r = s8.flat_ranker(flatten_ranker(fit_ranker(G, tr, res['hp']).booster_))
        preds.update(finish(P, AN, D, te, lambda pid: r))
    rn = s8.flat_ranker(res['trees'])
    preds.update(finish(P, AN, res['D'], held, lambda pid: rn))
    report('retrained (train LOFO, dev/test)', P, preds)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run_prefix')
    ap.add_argument('--out', help='output directory (default: the app resources)')
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--eval', action='store_true')
    ap.add_argument('--keep-forests', action='store_true', help='retrain the peak ranker only')
    ap.add_argument('--stages', help='run prefix with stages/ID.front.json (GT-input character counts)')
    ap.add_argument('--rebuild', action='store_true', help='recompute the cached pixel analyses')
    ap.add_argument('--augment', default=None, help="training copies, e.g. 'mix=speed2/all830;jitter=1.0x2' (module doc)")
    args = ap.parse_args()
    t0 = time.time()
    prefix = args.run_prefix; stages = args.stages or prefix
    P = pages(prefix, stages)
    log(f'{len(P)} pages ({sum(p["fold"] in TRAIN for p in P.values())} train) from {Path(prefix).name}, '
        f'stages {Path(stages).name}')
    AN = analyses(P, prefix, stages, args.rebuild)
    if args.augment:
        P, AN = augment_data(P, AN, prefix, args.augment, args.rebuild)
        log(f'augment {args.augment}: {len(P)} pages with copies')
    log(f'analyses ready {time.time() - t0:.0f}s')
    res = train(P, AN, args)
    if args.check:
        with tempfile.TemporaryDirectory() as d:
            write(res, d); check(P, AN, res, d)
    else:
        write(res, args.out or ws.REPO / Path(RANKER).parent)
    if args.eval: evaluate(P, AN, res, args)
    log(f'done {time.time() - t0:.0f}s')


if __name__ == '__main__':
    main()
