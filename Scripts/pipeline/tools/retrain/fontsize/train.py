"""S8 font size (PipelineFontCorrection.swift): fit the cell-pitch rule's table into PipelineFontSize.json.

Rule (as the Swift): A = the PipelineSimpleFont grouped size / exp(bias). A line's pitch = its ink extent along the
reading axis (Otsu ink of the line box padded by 15% of its short side) / its cell count, a linear table over 10
character classes plus ellipsis / !? runs. Per size group: P = cell-weighted median log pitch, N = cells,
S = weighted median |log pitch - P|; log size = log A + N/(N+n0) (P - log A) when S <= maxSpread, log A + latin for
mostly-Latin horizontal groups. `fontLevel` (PipelineTuning) is the global level on top and is not fit here.

Fit (train-split pages only, detected blocks of the run matched to GT paragraphs with a GT font size):
  1. cell table: soft-L1 (f_scale 0.05) least squares of log(ink extent / GT px) = log(cells) over the lines of
     matched vertical blocks, start 1 per class, 0 per run, -0.1 offset
  2. bias: median log(A_raw / GT px) over matched blocks
  3. n0, maxSpread, latin: grid (first best) on mean min(|log pred - log GT|, 0.3) over matched blocks
Method source: port-eval/stageopt/fontsize (round 4 'pruned table', port_params.json 'det').

usage: train.py RUN_PREFIX [--out PATH] [--check] [--eval]
"""
import argparse, collections, itertools, json, math, os, pickle, sys, tempfile, time
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.optimize import least_squares

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # tools dir
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # retrain dir (augment)
import workspace  # noqa: E402

SPEC = dict(
    name='fontsize',
    resource='Aidoku/Resources/Translation/PipelineFontSize.json',
    stage='S8',
    inputs='pages/ID.json blocks (bounds, sourceText, vertical, lines polygon/text/bounds: the blocks S8 sizes) + '
           'page pixels (manifest image) for the line ink extent; GT source_font_size, premerge lines and merge '
           'membership for the block -> paragraph match',
    needs_full=True,
    rerun_from='s8',
    # suggested --augment (AUGMENT.md round 2026-11-26): mixing the three upstream variants; jitter lost on size/chunk
    # Not adopted (2026-11-26 full-run A/B): mix improved this trainer's log error but raised app-level font >10% on
    # train/test (137/39 -> 166/42) at equal render; pass --augment 'mix=...' to try it.
    augment=None,
)
RESOURCE = workspace.REPO / SPEC['resource']
TUNING = workspace.REPO / 'Aidoku/Core/Translation/Pipeline/PipelineTuning.swift'
SCRATCH = ('retrain', 'fontsize')
SPLITS = ('train', 'dev', 'test')
CLASSES = ['cjk', 'small', 'long', 'halfPunct', 'ellipsis', 'dot', 'bang', 'tilde', 'ascii', 'other',
           'ellipsisRun', 'bangRun']
GRID = dict(n0=[0, 2, 4, 8, 16, 32], maxSpread=[0.05, 0.1, 0.2, 9], latin=[0, 0.15, 0.25, 0.3])

# --- PipelineSimpleFont (PipelineStyle.swift) ---------------------------------------------------------------------
SCALE, BIAS, MEMBER, BODYW, MAXD, GSCALE = (0.43853239073260936, 4.094089327930639, 0.4140206805546956,
                                             0.8212525806130213, 0.9705176286667344, 1.0252379527066393)


def _sf_median(items):
    s = sorted(items, key=lambda t: t[0]); half = sum(w for _, w in s) * 0.5; c = 0
    for i, (v, w) in enumerate(s):
        c += w
        if c == half and i + 1 < len(s): return (v + s[i + 1][0]) * 0.5
        if c > half: return v
    return s[-1][0] if s else 0


def _cross(a, b, p): return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])


def _hull(poly):
    n = len(poly); signed = sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1] for i in range(n))
    sign = 1 if signed > 0 else -1
    if signed != 0 and all(all(sign * _cross(poly[i], poly[(i + 1) % n], p) >= -1e-9 for p in poly) for i in range(n)):
        return poly
    u = []
    for p in sorted(poly):
        if not u or u[-1] != p: u.append(p)
    if len(u) <= 2: return u
    lo, up = [], []
    for p in u:
        while len(lo) >= 2 and _cross(lo[-2], lo[-1], p) <= 0: lo.pop()
        lo.append(p)
    for p in reversed(u):
        while len(up) >= 2 and _cross(up[-2], up[-1], p) <= 0: up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]


def _min_area_box(poly):
    h = _hull([(float(x), float(y)) for x, y in poly])
    if len(h) < 3: return None
    best = None
    for i in range(len(h)):
        a, b = h[i], h[(i + 1) % len(h)]; dx, dy = b[0] - a[0], b[1] - a[1]; L = math.hypot(dx, dy)
        if L <= 1e-9: continue
        ux, uy = dx / L, dy / L
        us = [(p[0] - a[0]) * ux + (p[1] - a[1]) * uy for p in h]; vs = [-(p[0] - a[0]) * uy + (p[1] - a[1]) * ux for p in h]
        w, hh = max(us) - min(us), max(vs) - min(vs)
        if w <= 1e-9 or hh <= 1e-9: continue
        if best is None or w * hh < best[1] - 1e-9: best = (min(w, hh), w * hh)
    return best


def _member_short(polys):
    boxes = [b for b in (_min_area_box(p) for p in polys if 3 <= len(p) <= 256) if b]
    if not boxes: return None
    s = sorted(boxes); half = sum(b[1] for b in s) * 0.5; c = 0
    for b in s:
        c += b[1]
        if c >= half: return b[0]
    return s[-1][0]


def simple_font(blocks):
    """-> (sizes, groups) as PipelineSimpleFont.estimate."""
    if not blocks: return [], []
    values, members, weights = [], [], []
    for b in blocks:
        x, y, w, h = b['bounds']; count = max(1, len(b['text']))
        prior = max(8, min(min(w, h), math.sqrt(w * h / count))) if w > 0 and h > 0 else 8
        m = _member_short([l['poly'] for l in b['lines']]); m = prior if m is None else m
        values.append(max(1, SCALE * prior + MEMBER * m + BIAS)); members.append(m); weights.append(float(count))
    if len(values) == 1: return [values[0] * GSCALE], [0]
    order = sorted(range(len(values)), key=lambda i: (-weights[i], values[i], members[i], i))
    groups = []
    for i in order:
        for g in groups:
            if all(abs(math.log(values[i] / values[o])) + BODYW * abs(math.log(members[i] / members[o])) <= MAXD for o in g):
                g.append(i); break
        else:
            groups.append([i])
    res, gid = list(values), [0] * len(values)
    for k, g in enumerate(groups):
        med = _sf_median([(values[i], weights[i]) for i in g])
        for i in g: res[i] = med; gid[i] = k
    return [v * GSCALE for v in res], gid


# --- cells (PipelineFontCorrection.cellClass / cellCount) ---------------------------------------------------------
SMALL = set('ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ')
LONG, HALF = set('ーｰ一—―－-'), set('、。，．,「」『』（）()【】〈〉《》“”"\'［］[]')
ELL, DOT, BANG, TILDE = set('…‥'), set('.・･·'), set('!?！？'), set('~～〜∼')


def cell_class(c):
    o = ord(c)
    if c in SMALL: return 1
    if c in LONG: return 2
    if c in HALF: return 3
    if c in ELL: return 4
    if c in DOT: return 5
    if c in BANG: return 6
    if c in TILDE: return 7
    if o < 128 and c.isalnum(): return 8
    if 0x3040 <= o <= 0x30FF or 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0xF900 <= o <= 0xFAFF or \
            0xFF10 <= o <= 0xFF5A or 0xAC00 <= o <= 0xD7AF: return 0
    return 9


def cell_vector(text):
    n = [0] * 12; prev = None
    for c in text:
        if c.isspace(): prev = None; continue
        k = cell_class(c); n[k] += 1
        if k != prev:
            if k == 4: n[10] += 1
            elif k == 6: n[11] += 1
        prev = k
    return n


def is_latin(blocks):
    if sum(not b['vertical'] for b in blocks) * 2 <= len(blocks): return False
    cls = [cell_class(c) for b in blocks for c in b['text'] if not c.isspace()]
    return sum(k == 8 for k in cls) / max(1, len(cls)) > 0.5


def wmed(v, w):
    o = np.argsort(v, kind='stable'); v = np.asarray(v, float)[o]; c = np.cumsum(np.asarray(w, float)[o])
    return float(v[np.searchsorted(c, 0.5 * c[-1])])


# --- ink extent (PipelineFontCorrection.inkExtent) ----------------------------------------------------------------
def _otsu(g):
    h = np.bincount(g.ravel(), minlength=256).astype(float); p = h / h.sum(); w = np.cumsum(p); mu = np.cumsum(p * np.arange(256))
    with np.errstate(divide='ignore', invalid='ignore'):
        s = (mu[-1] * w - mu) ** 2 / (w * (1 - w))
    s[~np.isfinite(s)] = 0
    return int(np.argmax(s))


def ink_extent(gray, poly, vertical):
    """Ink extent along the reading axis in px; None when the padded box is under 4 px."""
    xs = [p[0] for p in poly]; ys = [p[1] for p in poly]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    pad = 0.15 * ((x1 - x0) if vertical else (y1 - y0))
    H, W = gray.shape
    X0, X1 = int(max(0, np.floor(x0 - pad))), int(min(W, np.ceil(x1 + pad)))
    Y0, Y1 = int(max(0, np.floor(y0 - pad))), int(min(H, np.ceil(y1 + pad)))
    if X1 - X0 < 4 or Y1 - Y0 < 4: return None
    c = gray[Y0:Y1, X0:X1]
    if not vertical: c = c.T  # rows = along the reading axis
    dark = c <= _otsu(c)
    border = np.concatenate([dark[0], dark[-1], dark[:, 0], dark[:, -1]])
    ink = dark if border.mean() < 0.5 else ~dark
    along = ink.sum(1); mm = along.mean()
    on = np.nonzero(along >= 0.25 * mm)[0] if mm > 0 else []
    return float(on[-1] - on[0] + 1) if len(on) else 0.0


# --- data: GT, run pages, block -> GT paragraph match --------------------------------------------------------------
def _box(poly): xs = [p[0] for p in poly]; ys = [p[1] for p in poly]; return (min(xs), min(ys), max(xs), max(ys))


def _iou(a, b):
    w = max(0, min(a[2], b[2]) - max(a[0], b[0])); h = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - w * h
    return w * h / u if u > 0 else 0


def _letters(t): return sum(1 for c in t if not c.isspace())


def load_gt():
    st = os.stat(workspace.GT); cache = workspace.data(*SCRATCH, 'gt.pkl'); key = (str(workspace.GT), st.st_size, st.st_mtime)
    if cache.exists():
        d = pickle.load(open(cache, 'rb'))
        if d['key'] == key: return d['gt']
    lines, paras, mbox, sizes, part = (collections.defaultdict(dict), collections.defaultdict(list), {},
                                       collections.defaultdict(list), {})
    for r in json.load(open(workspace.GT))['records']:
        s, status, pid = r['scope'], r.get('status'), r['page_id']
        if s == 'individual_premerge_bbox' and status == 'canonical':
            lines[pid][r['label']['id']] = [[p['x'], p['y']] for p in r['label']['polygon']]
        elif s == 'merge_membership' and status == 'canonical':
            paras[pid].append((r['entity_id'], r['label']['sourceRegionIDs']))
        elif s == 'merged_bbox' and status == 'canonical':
            mbox[(pid, r['entity_id'])] = _box([[p['x'], p['y']] for p in r['label']['polygon']])
        elif s == 'source_font_size':
            l = r['label']; cb, b = l['cropBounds'], l['bboxInCrop']
            sizes[pid].append(dict(eid=r['entity_id'], box=(cb[0] + b[0], cb[1] + b[1], cb[0] + b[0] + b[2], cb[1] + b[1] + b[3]),
                                   px=float(l['fontSizePx']), lo=float(l['fontSizeIntervalPx'][0]), hi=float(l['fontSizeIntervalPx'][1])))
        elif s == 'exact_source_font_size_partition':
            for k, c in enumerate(r['label']['classes']):
                for m in c['memberIDs']: part[(pid, m)] = k
    gt = dict(lines=dict(lines), paras=dict(paras), mbox=mbox, sizes=dict(sizes), part=part)
    pickle.dump(dict(key=key, gt=gt), open(cache, 'wb'))
    return gt


def _match(pid, rec, gt):
    """-> (blocks, targets [(block index, gt size dict, class id)], matched-block count) for one run page."""
    gl = {gid: _box(poly) for gid, poly in gt['lines'].get(pid, {}).items()}
    line_para, P = {}, []
    for eid, members in gt['paras'][pid]:
        ms = [m for m in members if m in gl]
        if not ms: continue
        for m in ms: line_para[m] = eid
        mb = gt['mbox'].get((pid, eid)) or _box([p for m in ms for p in gt['lines'][pid][m]])
        cand = [(_iou(mb, s['box']), k) for k, s in enumerate(gt['sizes'].get(pid, []))]
        size = None
        if cand:
            v, k = max(cand)
            if v >= 0.5: size = gt['sizes'][pid][k]
        P.append(dict(eid=eid, mbox=mb, gt=size, cls=gt['part'].get((pid, size['eid'])) if size else None))
    paras = {p['eid']: p for p in P}
    B, T, matched = [], [], 0
    for b in rec['blocks']:
        # S8 sizes fonts on the pre-refine geometry (PipelineBlock.sizingGeometry: measureBounds, line measure).
        (x, y), (w, h) = b.get('measureBounds') or b['bounds']
        L = [dict(poly=l.get('measure') or l['polygon'], text=l['text']) for l in b['lines']]
        votes = collections.Counter()
        for l in b['lines']:
            (lx, ly), (lw, lh) = l['bounds']; lb = (lx, ly, lx + lw, ly + lh)
            g = max(gl, key=lambda g: _iou(lb, gl[g]), default=None)
            if g is not None and _iou(lb, gl[g]) >= 0.3 and g in line_para: votes[line_para[g]] += max(1, _letters(l['text']))
        para = None
        if votes:
            e, v = votes.most_common(1)[0]
            if v >= 0.5 * sum(votes.values()): para = e
        if para is None:
            bb = (x, y, x + w, y + h); best, cov = None, 0
            for p in P:
                a = p['mbox']; c = max(0, min(bb[2], a[2]) - max(bb[0], a[0])) * max(0, min(bb[3], a[3]) - max(bb[1], a[1])) / max(1e-9, w * h)
                if c > cov: best, cov = p['eid'], c
            if cov >= 0.5: para = best
        matched += para is not None
        B.append(dict(bounds=(x, y, w, h), text=b['sourceText'], vertical=bool(b['vertical']), lines=L,
                      swift=(b.get('style') or {}).get('fontPixels')))
        if para and paras[para]['gt']: T.append((len(B) - 1, paras[para]['gt'], paras[para]['cls']))
    return B, T, matched


def load_run(prefix, splits=SPLITS, jitter=None):
    """Pages of RUN_PREFIX_{splits} with a GT paragraph set; line ink extents cached per line geometry.
    jitter: (augment.Jitter factory seed -> Jitter, copy tag): the sizing geometry is jittered per page before the
    ink extents are measured (the block -> GT match keeps the run's own line bounds)."""
    gt = load_gt()
    man = {p['page_id']: p for p in json.load(open(workspace.MANIFEST))['pages']}
    cache = workspace.data(*SCRATCH, 'ink_%s.pkl' % Path(prefix).name) if jitter is None else \
        workspace.data(*SCRATCH, 'aug', 'ink_jit.pkl')
    ink = pickle.load(open(cache, 'rb')) if cache.exists() else {}
    n0 = len(ink); D = []
    for split in splits:
        d = Path(f'{prefix}_{split}') / 'pages'
        for f in sorted(os.listdir(d)):
            if not f.endswith('.json'): continue
            pid = f[:-5]
            if pid not in gt['paras'] or pid not in man: continue
            rec = json.load(open(d / f)); mp = man[pid]
            if jitter is not None: rec = jitter_page(rec, jitter[0](pid))
            B, T, matched = _match(pid, rec, gt)
            gray = None
            for b in B:
                for l in b['lines']:
                    k = (pid, b['vertical'], tuple(c for p in l['poly'] for c in p))
                    if k not in ink:
                        if gray is None: gray = np.asarray(Image.open(mp['image_path']).convert('L'))
                        ink[k] = ink_extent(gray, l['poly'], b['vertical'])
                    l['ink'] = ink[k]
            D.append(dict(page=pid, split=mp['split'], fold=mp['fold'], size=(rec['width'], rec['height']),
                          matched=matched, blocks=B, targets=T))
    if len(ink) != n0: pickle.dump(ink, open(cache, 'wb'))
    return D


# --- augmentation (--augment; retrain/augment.py) -----------------------------------------------------------------
def jitter_page(rec, J):
    """rec with each block's sizing geometry (line measure or polygon; measureBounds = their union) jittered by J."""
    out = dict(rec); out['blocks'] = []
    for b in rec['blocks']:
        nb = dict(b); nb['lines'] = []
        for l in b['lines']:
            poly = l.get('measure') or l['polygon']; x0, y0, x1, y1 = _box(poly)
            j = J.line(dict(bounds=[[x0, y0], [x1 - x0, y1 - y0]], polygon=poly, vertical=l['vertical']))
            nl = dict(l); nl['measure'] = j['polygon']; nb['lines'].append(nl)
        pts = [p for l in nb['lines'] for p in l['measure']]
        if pts:
            x0, y0, x1, y1 = _box(pts); nb['measureBounds'] = [[x0, y0], [x1 - x0, y1 - y0]]
        out['blocks'].append(nb)
    return out


def parse_augment(spec):
    """'mix=A,B;jitter=1.0x2' -> dict(mix=[run prefixes], jitter=(scale, copies)). Runs are augment.RUNS names
    or absolute prefixes."""
    import augment
    a = dict(mix=[], jitter=(0.0, 0))
    for part in filter(None, (spec or '').replace(' ', '').split(';')):
        k, v = part.split('=', 1)
        if k == 'mix': a['mix'] = [r if os.path.isabs(r) else str(augment.run_path(r)) for r in v.split(',') if r]
        elif k == 'jitter': s, n = v.split('x'); a['jitter'] = (float(s), int(n))
        else: raise SystemExit(f'unknown --augment key {k}')
    return a


def augmented_train(prefix, aug, base=None):
    """Train pages for the fit: the train pages of `prefix` and every `mix` run, plus `copies` jittered copies of each
    (fixed per-page seeds). Copies keep the page id, so the LOFO folds keep all copies of a page on one side."""
    import zlib, augment
    runs = [prefix] + [r for r in aug['mix'] if os.path.realpath(r) != os.path.realpath(prefix)]
    scale, copies = aug['jitter']; out = []
    for r in runs:
        P = base if (base is not None and r == prefix) else load_run(r, ('train',))
        out += [p for p in P if p['split'] == 'train']
        if scale > 0 and copies > 0:
            res = augment.residuals(r)  # S3-vs-GT offsets of the pre-refine (unrefined) S3 boxes of that run
            for c in range(copies):
                seed = lambda pid, c=c: augment.Jitter(res, scale, zlib.crc32(f'{pid}/{c}'.encode()))
                out += [p for p in load_run(r, ('train',), (seed, c)) if p['split'] == 'train']
    return out


# --- model --------------------------------------------------------------------------------------------------------
def prepare(D):
    """Per page: simple-font sizes, groups, Latin flags, line (cell vector, ink extent) per group (fixed per run)."""
    for p in D:
        B = p['blocks']; fonts, groups = simple_font(B); p['fonts'], p['groups'] = fonts, groups
        mem = {}
        for i, g in enumerate(groups): mem.setdefault(g, []).append(i)
        p['latin'] = {g: is_latin([B[i] for i in m]) for g, m in mem.items()}
        p['glines'] = {}
        for i, b in enumerate(B):
            for l in b['lines']:
                if l['text'] and l['ink']:
                    p['glines'].setdefault(groups[i], []).append((cell_vector(l['text']), l['ink']))


def fit_cells(pages):
    X, L, G = [], [], []
    for p in pages:
        for i, g, _ in p['targets']:
            b = p['blocks'][i]
            if not b['vertical']: continue
            for l in b['lines']:
                if l['ink'] and l['text']: X.append(cell_vector(l['text'])); L.append(l['ink']); G.append(g['px'])
    X, y = np.array(X, float), np.log(np.array(L) / np.array(G))
    res = lambda t: y - np.log(np.maximum(X @ t[:-1] + t[-1], 0.05))
    return least_squares(res, np.concatenate([np.ones(10), [0, 0], [-0.1]]), loss='soft_l1', f_scale=0.05).x


def rows(pages, theta, bias, all_blocks=False):
    """(page, block, gt, cls, [a0, latin, d, N, S]) for the matched blocks (or every block)."""
    out = []
    for p in pages:
        T = [(i, None, None) for i in range(len(p['blocks']))] if all_blocks else p['targets']
        if not T: continue
        st = {}
        for g, L in p['glines'].items():
            V = np.array([v for v, _ in L], float); c = V @ theta[:-1] + theta[-1]; e = np.array([x for _, x in L])
            ok = c >= 0.5
            if not ok.any(): continue
            v, w = np.log(e[ok] / c[ok]), c[ok]; P = wmed(v, w)
            st[g] = (P, float(w.sum()), wmed(np.abs(v - P), w))
        for i, gt, cls in T:
            g = p['groups'][i]; a0 = math.log(p['fonts'][i]) - bias; P, N, S = st.get(g, (0.0, 0.0, 9.0))
            out.append((p['page'], i, gt, cls, [a0, float(p['latin'][g]), P - a0 if N > 0 else 0.0, N, S]))
    return out


def rule(R, prm):
    a0, lat, d, N, S = R.T
    a = np.where(N > 0, N / np.where(N > 0, N + prm['n0'], 1), 0.0)
    out = np.where((N > 0) & (S <= prm['maxSpread']), a0 + a * d, a0)
    return np.where(lat > 0, a0 + prm['latin'], out)


def fit(pages):
    theta = fit_cells(pages)
    bias = float(np.median([math.log(p['fonts'][i] / g['px']) for p in pages for i, g, _ in p['targets']]))
    rr = rows(pages, theta, bias); R = np.array([r[4] for r in rr]); y = np.log([r[2]['px'] for r in rr])
    best = None; fit.grid = []
    for combo in itertools.product(*GRID.values()):
        prm = dict(zip(GRID, combo)); l = np.mean(np.minimum(np.abs(rule(R, prm) - y), 0.3))
        fit.grid.append((float(l), prm))
        if best is None or l < best[0] - 1e-12: best = (l, prm)
    return dict(cellClasses=CLASSES, cellWeights=[float(v) for v in theta[:-1]], cellOffset=float(theta[-1]), bias=bias,
                **{k: float(v) for k, v in best[1].items()})


def predict(pages, model, all_blocks=False):
    th = np.array(model['cellWeights'] + [model['cellOffset']])
    rr = rows(pages, th, model['bias'], all_blocks)
    if not rr: return []
    z = rule(np.array([r[4] for r in rr]), model)
    return [(r[0], r[1], float(math.exp(v)), r[2], r[3]) for r, v in zip(rr, z)]


# --- metric (port-eval/stageopt/fontsize/core.py) ------------------------------------------------------------------
def metrics(pr):
    p = np.array([r[2] for r in pr]); g = np.array([r[3]['px'] for r in pr])
    lo = np.array([r[3]['lo'] for r in pr]); hi = np.array([r[3]['hi'] for r in pr]); lr = np.log(p / g); e = np.abs(lr)
    pages, cl = {}, {}
    for r, v in zip(pr, lr): pages.setdefault(r[0], []).append(v)
    for r in pr:
        if r[4] is not None: cl.setdefault((r[0], r[4]), []).append(r[2])
    sp = [max(v) / min(v) for v in cl.values() if len(v) >= 2]
    return (f'n={len(pr):4d} med={np.median(e):.4f} mean={e.mean():.4f} inInt={((p >= lo - 1e-9) & (p <= hi + 1e-9)).mean():.3f} '
            f'w10={(np.abs(p / g - 1) <= 0.10).mean():.3f} bias={np.median(lr):+.3f} '
            f'pageSD={np.mean([np.std(v) for v in pages.values() if len(v) >= 2]):.4f} '
            f'cls<=1.1={np.mean([s <= 1.10 for s in sp]) if sp else float("nan"):.3f}')


def folds(train, scheme):
    """Train page -> held-out group: manifest folds, 3 page-size groups (greedy by matched blocks), 3 id chunks."""
    if scheme == 'page': return {p['page']: p['fold'] for p in train}
    if scheme == 'size':
        cnt = collections.Counter()
        for p in train: cnt[p['size']] += p['matched']
        load, of = {0: 0, 1: 0, 2: 0}, {}
        for s, n in sorted(cnt.items(), key=lambda kv: -kv[1]):
            f = min(load, key=load.get); of[s] = f; load[f] += n
        return {p['page']: of[p['size']] for p in train}
    ids = sorted(p['page'] for p in train)
    return {pid: min(2, 3 * i // len(ids)) for i, pid in enumerate(ids)}


def grid_margin(grid=None):
    """Grid loss margins of the last fit: best overall, and per n0 the best loss minus the overall best."""
    grid = grid or fit.grid; best = min(grid, key=lambda t: t[0])
    per = {}
    for l, prm in grid: per[prm['n0']] = min(per.get(prm['n0'], 9), l)
    second = min(l for l, prm in grid if prm != best[1])
    return best, second - best[0], {k: v - best[0] for k, v in per.items()}


def evaluate(D, fit_pages=None):
    """Train LOFO (fit on fit_pages outside the held-out group, default the run's train pages; scored on the run's
    own train pages of that group), then dev/test once."""
    train = [p for p in D if p['split'] == 'train']; fit_pages = train if fit_pages is None else fit_pages
    for scheme in ('page', 'size', 'chunk'):
        of = folds(train, scheme); pr = []
        for h in sorted(set(of.values())):
            m = fit([p for p in fit_pages if of.get(p['page'], h) != h])
            pr += predict([p for p in train if of[p['page']] == h], m)
        print(f'train LOFO {scheme:5s} {metrics(pr)}')
    m = fit(fit_pages)
    for s in ('dev', 'test'):
        print(f'{s:16s} {metrics(predict([p for p in D if p["split"] == s], m))}')


def write(model, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w') as f: json.dump(model, f, indent=1); f.write('\n')


def font_level():
    import re
    return float(re.search(r'var fontLevel = ([0-9.eE+-]+)', TUNING.read_text()).group(1))


def check(D, model):
    cur = json.load(open(RESOURCE))
    nums = lambda m: [m['bias'], m['n0'], m['maxSpread'], m['latin'], m['cellOffset']] + list(m['cellWeights'])
    a, b = nums(cur), nums(model)
    diff = max(abs(x - y) for x, y in zip(a, b)) if len(a) == len(b) else float('inf')
    print('fitted', json.dumps({k: v for k, v in model.items() if k != 'cellClasses'}))
    print('resource', 'identical' if a == b and cur.get('cellClasses') == model['cellClasses'] else f'max abs diff {diff:.3g}')
    pa, pb = predict(D, cur, True), predict(D, model, True)
    e = np.array([abs(math.log(x[2] / y[2])) for x, y in zip(pa, pb)])
    print(f'predictions on all {len(e)} run blocks: identical {(e == 0).mean():.4f}  |log diff| < 1e-9 {(e < 1e-9).mean():.4f}  max {e.max():.3g}')
    # Swift parity: valid only when the run was made with the current resource and fontLevel
    lv = font_level(); sw = {(p['page'], i): b['swift'] for p in D for i, b in enumerate(p['blocks'])}
    e = np.array([abs(math.log(r[2] * math.exp(lv) / sw[(r[0], r[1])])) for r in pa if sw[(r[0], r[1])]])
    print(f'current resource vs the run\'s Swift fontPixels (fontLevel {lv}): |log diff| < 1e-9 {(e < 1e-9).mean():.4f}  '
          f'< 1% {(e < .01).mean():.4f}  max {e.max():.3g}  (parity; meaningful only for a run made with the current resource)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run_prefix'); ap.add_argument('--out', default=str(RESOURCE))
    ap.add_argument('--check', action='store_true'); ap.add_argument('--eval', action='store_true')
    ap.add_argument('--augment', default=None, help="e.g. 'mix=retune/snap2/ref,speed2/all830;jitter=1.0x2' "
                    "(off by default; SPEC['augment'] is the suggested value)")
    a = ap.parse_args(); t0 = time.time()
    D = load_run(a.run_prefix); prepare(D)
    train = [p for p in D if p['split'] == 'train']
    fit_pages = train
    if a.augment:
        fit_pages = augmented_train(a.run_prefix, parse_augment(a.augment), D); prepare(fit_pages)
        print(f'augment {a.augment}: {len(fit_pages)} fit pages, {sum(len(p["targets"]) for p in fit_pages)} rows')
    model = fit(fit_pages)
    print(f'pages {len(D)} (train {len(train)}), matched train blocks {sum(len(p["targets"]) for p in train)}')
    if a.augment:
        (bl, bp), gap, per = grid_margin()
        print(f'grid best {bp} loss {bl:.5f}, margin to 2nd {gap:.2e}, per n0 ' + ' '.join(f'{k:g}:{v:+.1e}' for k, v in per.items()))
    if a.check:
        with tempfile.TemporaryDirectory() as d:
            write(model, Path(d) / 'PipelineFontSize.json'); check(D, json.load(open(Path(d) / 'PipelineFontSize.json')))
    else:
        write(model, a.out); print('wrote', a.out)
    if a.eval: evaluate(D, fit_pages if a.augment else None)
    print(f'{time.time() - t0:.0f} s')


if __name__ == '__main__':
    main()
