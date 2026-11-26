"""S6 line ends: Python port of PipelineLineEnds (45 features, ink run) and the GT targets per line end.

Per page and line (front.recognized, or the lines of the non-background front.blocks = the S6 inputs):
  f      the 45 features PipelineLineEnds.offsets feeds both models, per end (start, end)
  run    the ink run past the end (deltas[0] profile, gaps <= 0.4 T, at most 3 T), in T, as Swift's run()
  ybox   GT line box end past the box end, in T (regressor target; line matched to a GT box, IoU >= 0.5)
  yg     GT glyph extent past the box end, in T (classifier target; matched, glyph mask, same orientation)
  gb, gl glyph pixels of the matched GT line per 0.1 T bin from -1 T to +3 T past the end, and in all (pxMiss)
Pixels are read numerically only."""
import json, os, pickle
import numpy as np
from scipy.optimize import linear_sum_assignment

DELTAS = (40, 90)
REACH = 1.5
NBIN = 19
MAXT = 400.0                 # PipelineRemovalMask.maximumThickness
RUN_INK, RUN_GAP, RUN_REACH = 0.02, 0.4, 3.0
GAP, WIN = 0.6, 3.0          # GT glyph run: gaps up to GAP T, searched WIN T past the GT box
VERSION = 1


def gray_of(path):
    from PIL import Image
    a = np.asarray(Image.open(path).convert('RGB')).astype(np.int32)
    return ((a[..., 0] * 19595 + a[..., 1] * 38470 + a[..., 2] * 7471 + 0x8000) >> 16).astype(np.uint8)


def rint(x):  # Swift .toNearestOrEven
    return int(round(x))


def profile(gray, box):
    H, W = gray.shape
    x0, y0, x1, y1 = box
    if not all(np.isfinite(v) and abs(v) <= 1e6 for v in box): return None
    v = (y1 - y0) >= (x1 - x0)
    T = (x1 - x0) if v else (y1 - y0)
    if not (T > 0 and T <= MAXT): return None
    bx0, by0 = max(0, int(x0)), max(0, int(y0)); bx1, by1 = min(W, int(np.ceil(x1))), min(H, int(np.ceil(y1)))
    bg = float(np.median(gray[by0:by1, bx0:bx1])) if (bx1 > bx0 and by1 > by0) else 255.0
    cl, ch = (x0, x1) if v else (y0, y1); al, ah = (y0, y1) if v else (x0, x1)
    climit, alimit = (W, H) if v else (H, W)
    start = rint(cl + 0.1 * T); a = max(0, start); c = min(climit, max(start + 1, rint(ch - 0.1 * T)))
    if c <= a: return None
    return dict(v=v, T=T, bg=bg, a=a, c=c, al=al, ah=ah, alimit=alimit, r=int(np.ceil(REACH * T)))


def band(gray, pr, lo, hi, deltas=DELTAS):
    """Ink fraction per along index lo..hi-1 over the cross band [a, c): (len(deltas), hi - lo)."""
    a, c, v, alimit = pr['a'], pr['c'], pr['v'], pr['alimit']
    out = np.zeros((len(deltas), hi - lo))
    s, e = max(0, lo), min(alimit, hi)
    if e > s:
        blk = gray[s:e, a:c] if v else gray[a:c, s:e].T
        d = np.abs(blk.astype(np.float64) - pr['bg'])
        for k, dl in enumerate(deltas): out[k, s - lo:e - lo] = (d > dl).sum(1) / (c - a)
    return out


def region_dist(regions, box, v, T, which):
    x0, y0, x1, y1 = box; cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    end = (y1 if which else y0) if v else (x1 if which else x0); sign = 1 if which else -1
    res = []
    for kind in ('text', 'balloon'):
        best = 9.0
        for k, q in regions:
            if k != kind or not (q[0] <= cx <= q[2] and q[1] <= cy <= q[3]): continue
            edge = (q[3] if which else q[1]) if v else (q[2] if which else q[0])
            best = min(best, sign * (edge - end) / T)
        res.append(best)
    return res


def ink_run(gray, pr, which):
    """Swift PipelineLineEnds.run: walk outward from the rounded end on the deltas[0] fraction."""
    T = pr['T']; e = rint(pr['ah'] if which else pr['al']); n = int(np.floor(RUN_REACH * T + 1e-9)) + 1
    lo, hi = (e, e + n) if which else (e - n, e)
    fr = band(gray, pr, lo, hi, deltas=DELTAS[:1])[0]
    if not which: fr = fr[::-1]
    lim = pr['alimit']; gap = RUN_GAP * T; last = -1; i = 0
    while i <= RUN_REACH * T:
        along = e + i if which else e - 1 - i
        if along < 0 or along >= lim: break
        if fr[i] > RUN_INK: last = i
        elif i - last > gap: break
        i += 1
    return (last + 1) / T


def line_features(gray, box, regions):
    """(2 x 45 features, profile dict) or (None, None) where Swift returns nil."""
    pr = profile(gray, box)
    if pr is None: return None, None
    T, r = pr['T'], pr['r']
    lo, hi = int(np.floor(pr['al'])) - r, int(np.ceil(pr['ah'])) + r
    P = band(gray, pr, lo, hi); length = hi - lo
    first, last = int(np.floor(pr['al'])) - lo, int(np.ceil(pr['ah'])) - lo
    out = []
    for which in (0, 1):
        pos, sign = (last, 1.0) if which else (first, -1.0)
        x = []
        for prof in P:
            for k in range(NBIN):
                p = pos + sign * ((k - 6) / 10) * T; q = pos + sign * ((k - 5) / 10) * T
                fr = max(0, rint(min(p, q))); to = min(length, max(fr + 1, rint(max(p, q))))
                x.append(prof[fr:to].sum() / (to - fr) if to > fr else 0.0)
        x += [T, (pr['ah'] - pr['al']) / T, 1.0 if pr['v'] else 0.0, float(which)] + \
             region_dist(regions, box, pr['v'], T, which) + [pr['bg']]
        out.append(x)
    return out, pr


# ---------------------------------------------------------------- GT
def glyph_ends(lab, gbox, others):
    """Along-axis glyph extent (start, end) of a GT line in page coordinates, or None: pixels of the glyph instance
    owning the box, in its middle 70 % across the axis, grown outward across gaps <= GAP T, never into another GT
    line box of the same column, at most WIN T past the box."""
    H, W = lab.shape
    x0, y0, x1, y1 = gbox; v = (y1 - y0) >= (x1 - x0); T = (x1 - x0) if v else (y1 - y0)
    if T <= 1: return None
    ix0, iy0, ix1, iy1 = max(0, int(np.floor(x0))), max(0, int(np.floor(y0))), min(W, int(np.ceil(x1))), min(H, int(np.ceil(y1)))
    inner = lab[iy0:iy1, ix0:ix1]; nz = inner[inner > 0]
    if nz.size < 5: return None
    inst = np.bincount(nz).argmax()
    cl, ch = (x0, x1) if v else (y0, y1); al, ah = (y0, y1) if v else (x0, x1)
    a, c = int(round(cl + 0.15 * T)), int(round(ch - 0.15 * T)); c = max(c, a + 1)
    alimit = H if v else W; climit = W if v else H
    a, c = max(0, a), min(climit, c)
    if c <= a: return None
    w = int(np.ceil(WIN * T)); lo, hi = max(0, int(np.floor(al)) - w), min(alimit, int(np.ceil(ah)) + w)
    blk = lab[lo:hi, a:c] if v else lab[a:c, lo:hi].T
    ink = (blk == inst).sum(1) >= max(1, 0.02 * (c - a))
    wall0, wall1 = lo, hi
    for o in others:
        oc = (min(x1, o[2]) - max(x0, o[0])) if v else (min(y1, o[3]) - max(y0, o[1]))
        if oc < 0.3 * T: continue
        oal, oah = (o[1], o[3]) if v else (o[0], o[2])
        if oal >= ah - 0.3 * T: wall1 = min(wall1, int(np.floor(oal)))
        if oah <= al + 0.3 * T: wall0 = max(wall0, int(np.ceil(oah)))
    s_in, e_in = int(np.floor(al)) - lo, int(np.ceil(ah)) - lo
    core = np.nonzero(ink[s_in:e_in])[0]
    if core.size == 0: return None
    gap = GAP * T
    last = s_in + core[-1]; i = last + 1; stop1 = min(hi, wall1) - lo
    while i < stop1:
        if ink[i]: last = i
        elif i - last > gap: break
        i += 1
    first = s_in + core[0]; i = first - 1; stop0 = max(lo, wall0) - lo
    while i >= stop0:
        if ink[i]: first = i
        elif first - i > gap: break
        i -= 1
    return (lo + first, lo + last + 1)


def glyph_bins(lab, g, t, box, v, T, which, inst):
    """Glyph pixels of GT line g (instance inst, run t) per 0.1 T bin from -1 T to +3 T past this end, and in all."""
    H, W = lab.shape; x0, y0, x1, y1 = box
    end = (y1 if which else y0) if v else (x1 if which else x0); sign = 1 if which else -1
    c0, c1 = (int(g[0]), int(np.ceil(g[2]))) if v else (int(g[1]), int(np.ceil(g[3])))
    lo_a, hi_a = int(t[0]), int(t[1])
    alimit = H if v else W; climit = W if v else H
    c0, c1 = max(0, c0), min(climit, c1)
    s0 = max(0, min(lo_a, int(np.floor(end - 3.2 * T)))); s1 = min(alimit, max(hi_a, int(np.ceil(end + 3.2 * T))))
    blk = lab[s0:s1, c0:c1] if v else lab[c0:c1, s0:s1].T
    gcnt = (blk == inst).sum(1).astype(np.float32)
    pos = np.arange(s0, s1); inrun = (pos >= lo_a) & (pos < hi_a)
    b = np.floor(sign * (pos + 0.5 - end) / T * 10).astype(int) + 10
    ok = inrun & (b >= 0) & (b < 40)
    gb = np.zeros(40, np.float32); np.add.at(gb, b[ok], gcnt[ok])
    return gb, float(gcnt[inrun].sum())


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - ix
    return ix / u if u > 0 else 0


def gt_lines(gt_path, cache):
    """{page_id: [GT line boxes]}: canonical individual_premerge_bbox records, in file order."""
    st = os.stat(gt_path); key = f'{gt_path}:{st.st_size}:{st.st_mtime_ns}'
    if cache.exists():
        c = pickle.load(open(cache, 'rb'))
        if c['key'] == key: return c['G']
    G = {}
    for r in json.load(open(gt_path))['records']:
        if r['scope'] == 'individual_premerge_bbox' and r.get('status') == 'canonical':
            q = r['label']['polygon']; xs = [t['x'] for t in q]; ys = [t['y'] for t in q]
            G.setdefault(r['page_id'], []).append((min(xs), min(ys), max(xs), max(ys)))
    pickle.dump(dict(key=key, G=G), open(cache, 'wb'))
    return G


def _box(l):
    (x, y), (w, h) = l['bounds']
    return (x, y, x + w, y + h)


def page(pid, page_json, front_json, lines_mode, G, lab_path, jit=None):
    """Per-line rows of one page (see the module docstring). jit: optional box -> box (augmentation); lines are
    matched to GT on their own boxes, features and targets are taken from the jittered boxes."""
    rec = json.load(open(page_json)); st = json.load(open(front_json))
    gray = gray_of(rec['image']); H, W = gray.shape
    lab = None
    if lab_path.exists():
        lab = np.load(lab_path)['lab']
        if lab.shape != gray.shape: lab = None
    regions = [(q['kind'], _box(q)) for q in st['layout'] if q['score'] >= 0.5 and q['kind'] in ('text', 'balloon')]
    if lines_mode == 'recognized':
        boxes = [_box(l) for l in (st.get('recognized') or [])]
    else:
        boxes = [_box(l) for b in (st.get('blocks') or []) if b['role'] != 'background' for l in b['lines']]
    orig = boxes
    if jit is not None: boxes = [jit(b) for b in orig]
    match = {}
    if G and boxes:
        M = np.array([[iou(g, d) for d in orig] for g in G]); ri, ci = linear_sum_assignment(-M)
        match = {int(j): int(i) for i, j in zip(ri, ci) if M[i, j] >= 0.5}
    tg = [glyph_ends(lab, g, [o for k, o in enumerate(G) if k != n]) for n, g in enumerate(G)] if lab is not None else [None] * len(G)
    inst = {}
    out = []
    for j, box in enumerate(boxes):
        f, pr = line_features(gray, box, regions)
        if f is None: continue
        v, T = pr['v'], pr['T']
        d = dict(j=j, box=box, T=T, v=v, f=np.array(f, np.float32), run=[ink_run(gray, pr, w) for w in (0, 1)],
                 ybox=[np.nan, np.nan], yg=[np.nan, np.nan], gb=np.zeros((2, 40), np.float32), gl=[0.0, 0.0])
        gi = match.get(j)
        if gi is not None:
            g = G[gi]; gv = (g[3] - g[1]) >= (g[2] - g[0]); t = tg[gi]
            for which in (0, 1):
                sign = 1 if which else -1
                end = (box[3] if v else box[2]) if which else (box[1] if v else box[0])
                ge = (g[3] if v else g[2]) if which else (g[1] if v else g[0])
                d['ybox'][which] = sign * (ge - end) / T
                if t is not None and gv == v:
                    d['yg'][which] = sign * ((t[1] if which else t[0]) - end) / T
                    if gi not in inst:
                        ix0, iy0, ix1, iy1 = max(0, int(g[0])), max(0, int(g[1])), min(W, int(np.ceil(g[2]))), min(H, int(np.ceil(g[3])))
                        nz = lab[iy0:iy1, ix0:ix1]; nz = nz[nz > 0]
                        inst[gi] = np.bincount(nz).argmax() if nz.size else -1
                    d['gb'][which], d['gl'][which] = glyph_bins(lab, g, t, box, v, T, which, inst[gi])
        out.append(d)
    return dict(pid=pid, W=W, H=H, lines=out)
