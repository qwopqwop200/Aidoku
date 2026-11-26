"""S3refine line-box features, tree export/eval and box assembly: the Python reference of PipelineLineBoxes.swift.

Method (port-eval/linebox/algos/profile_snap.py, the line-box benchmark winner): the app's S3 lines (after the keep
gate) keep their set; each of the 4 box edges moves by an offset in line-thickness units predicted by a boosted tree
model from an ink projection profile, the page context (S1 text/balloon regions, other lines, S2 detector frags) and
the text shape. The detector quad is stretched onto the new box.

Gray parity with the app: the profiles are read from the S4 gray raster (PipelineGrayRaster: CoreGraphics decode,
<= 768 px long side, DeviceGray, medium interpolation), not from the full-size page. Geometry, context and the
thickness unit stay in page pixels; only the pixel windows live on the raster grid (page coordinate * raster/page).
Every operation is written so that Swift (Double, Int truncation, explicit clamping) gives the same numbers:
integer ink counts, one division per mean, prefix sums, round = floor(x + 0.5), stable index sorts.
"""
import math
import numpy as np

# ---- constants (written into PipelineLineBoxes.json; Swift reads them from there) ----
C = dict(
    ext=1.2,                       # along profile reach past each end, thicknesses
    thresholds=[40, 70],           # ink = |gray - inner median| > T
    gaps=[0.1, 0.25, 0.5],         # along ink-run gap tolerances
    bins=[[0, .1], [.1, .2], [.2, .35], [.35, .6], [.6, 1.0]],
    inner=[[0, .1], [.1, .25]],
    clip=[-0.4, 1.0],              # along target clip (training only)
    xext=0.5,                      # cross profile reach
    tw=0.12,                       # transition window
    cgaps=[0.0, 0.05, 0.12],
    cbins=[[0, .05], [.05, .1], [.1, .2], [.2, .35], [.35, .5]],
    cinner=[[0, .05], [.05, .15]],
    cclip=[-0.3, 0.3],
    minThickness=4.0,              # page px
    minSide=2.0,                   # a refined box thinner than this keeps the input box
)
ALONG = dict(max_iter=300, max_depth=6, learning_rate=0.05, min_samples_leaf=30)
CROSS = dict(max_iter=150, max_depth=4, learning_rate=0.08, min_samples_leaf=40)

SMALL = set('ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ')
END = set('!?！？')
DOTS = set('…‥・.。、,，')
LONG = set('ー〜～—-－')
OPEN = set('「『（(【〈《“"')
CLOSE = set('」』）)】〉》”"')
CHARSETS = [''.join(sorted(s)) for s in (END, DOTS, LONG, OPEN, CLOSE, SMALL)]   # classes 1..6, in order


def char_class(ch):
    if ch in END: return 1
    if ch in DOTS: return 2
    if ch in LONG: return 3
    if ch in OPEN: return 4
    if ch in CLOSE: return 5
    if ch in SMALL: return 6
    o = ord(ch)
    if 0x3040 <= o <= 0x30ff: return 7
    if 0x4e00 <= o <= 0x9fff: return 8
    if o < 128 and ch.isalnum(): return 9
    return 0


def f32(x):
    """A Swift Float field as the Double Swift widens it to (the checkpoint JSON prints the shortest Float repr)."""
    return float(np.float32(x or 0.0))


def rnd(x):
    return math.floor(x + 0.5)


def clamp_range(a, b, n):
    """numpy slice [a:b] of a length-n axis for a, b >= 0 (no negative wrap is ever used here)."""
    a = min(max(a, 0), n); b = min(max(b, a), n)
    return a, b


# ---- profile features on integer ink counts (cnt[i] ink cells of n in cell i) ----
def _frac(cs, a, b, n, N):
    a = max(0, a); b = min(N, b)
    if b <= a or n <= 0: return None
    return (cs[b] - cs[a]) / ((b - a) * n)


def _edge(cnt, cs, n, e, d, th, gaps, bins, inb, lim_in, lim_out, tw):
    N = len(cnt)
    rows = [n > 0 and c / n > 0.02 for c in cnt]
    f = []
    ig = 0; i = e
    while 0 <= i < N and not rows[i] and ig < lim_in:
        ig += 1; i -= d
    f.append(ig / th)
    st = min(max(i, 0), N - 1)
    for gp in gaps:
        gap = int(gp * th); t = st; g = 0; j = st + d
        while 0 <= j < N and abs(j - st) <= lim_out:
            if rows[j]: t = j; g = 0
            else:
                g += 1
                if g > gap: break
            j += d
        f.append((t - e) * d / th)
    for a, b in bins:
        lo = e + d * (int(a * th) + 1); hi = e + d * (int(b * th) + 1)
        v = _frac(cs, min(lo, hi), max(lo, hi), n, N)
        f.append(-1.0 if v is None else v)
    for a, b in inb:
        lo = e - d * int(a * th); hi = e - d * int(b * th); k = 1 if d > 0 else 0
        v = _frac(cs, min(lo, hi) + k, max(lo, hi) + k, n, N)
        f.append(-1.0 if v is None else v)
    # transitions: best ink->blank step offset and strength, first plateau end
    w = max(2, int(tw * th))
    def mean(a, b):
        v = _frac(cs, a, b, n, N)
        return 0.0 if v is None else v
    best, bu, first = -1.0, 0.0, None
    floor_k = -((lim_in + 1) // 2)        # python -lim_in // 2
    for k in range(-lim_in, lim_out + 1):
        i = e + d * k
        if d > 0: inn, out = mean(i - w + 1, i + 1), mean(i + 1, i + 1 + w)
        else: inn, out = mean(i, i + w), mean(i - w, i)
        sc = inn - out
        if sc > best: best, bu = sc, k / th
        if first is None and inn > 0.05 and out < 0.01 and k >= floor_k: first = k / th
    if first is None: first = lim_out / th
    f += [bu, best, first]
    return f


def _prefix(cnt):
    cs = [0] * (len(cnt) + 1)
    for i, c in enumerate(cnt): cs[i + 1] = cs[i] + c
    return cs


def _swap(b):
    return [b[1], b[0], b[3], b[2]]


def line_features(line, others, regions, frags, gray, W, H):
    """4 x 65 feature rows (top, bottom, left, right in the line's own frame: along = y for vertical lines) and the
    meta (vertical, page box in that frame, thickness). others/regions/frags are already in the line's frame."""
    v = bool(line['vertical'])
    B = [float(z) for z in line['box']]
    if not v: B = _swap(B)
    pw, ph = (W, H) if v else (H, W)                     # page extent across / along in the frame
    x0, y0, x1, y1 = B
    th = max(x1 - x0, C['minThickness']); L = max(y1 - y0, 1.0)
    text = line.get('text') or ''
    nch = len(text)
    cyc = (y0 + y1) / 2; cxc = (x0 + x1) / 2
    best = None
    for kind, R in regions:
        if R[0] <= cxc <= R[2] and R[1] <= cyc <= R[3]:
            a = (R[2] - R[0]) * (R[3] - R[1])
            if best is None or a < best[0]: best = (a, R, kind)
    rk = (1 if best[2] == 'text' else 2) if best else 0
    R = best[1] if best else None
    nb = [3.0, 3.0, 3.0, 3.0]
    for o in others:
        ov = min(x1, o[2]) - max(x0, o[0])
        if ov >= 0.5 * min(th, o[2] - o[0]):
            if o[3] <= y0 + 0.2 * th and o[1] < y0: nb[0] = min(nb[0], (y0 - o[3]) / th)
            if o[1] >= y1 - 0.2 * th and o[3] > y1: nb[1] = min(nb[1], (o[1] - y1) / th)
        ova = min(y1, o[3]) - max(y0, o[1])
        if ova >= 0.3 * min(L, o[3] - o[1]):
            if o[2] <= x0 + 0.3 * th and o[0] < x0: nb[2] = min(nb[2], (x0 - o[2]) / th)
            if o[0] >= x1 - 0.3 * th and o[2] > x1: nb[3] = min(nb[3], (o[0] - x1) / th)
    fe = [-1.0, -1.0, -1.0, -1.0]; nf = 0
    for o in frags:
        ov = min(x1, o[2]) - max(x0, o[0]); ova = min(y1, o[3]) - max(y0, o[1])
        if ov < 0.5 * min(th, o[2] - o[0]) or ova < -0.3 * th: continue
        nf += 1
        fe[0] = max(fe[0], (y0 - o[1]) / th); fe[1] = max(fe[1], (o[3] - y1) / th)
        fe[2] = max(fe[2], (x0 - o[0]) / th); fe[3] = max(fe[3], (o[2] - x1) / th)
    poly = [[float(q[0]), float(q[1])] for q in (line.get('poly') or [])]
    skew = 0.0
    if len(poly) == 4:
        P = poly if v else [[q[1], q[0]] for q in poly]
        order = sorted(range(4), key=lambda k: (P[k][1], k))
        top = (P[order[0]][0] + P[order[1]][0]) / 2; bot = (P[order[2]][0] + P[order[3]][0]) / 2
        skew = (bot - top) / th
    g = [th, L / th, float(nch), (L / th) / max(nch, 1), 0.0, float(v), float(rk), f32(line.get('conf')),
         f32(line.get('score')), skew, abs(skew)]

    # ---- pixels on the raster grid ----
    gh, gw = gray.shape
    sa = (gh / H) if v else (gw / W)                     # along scale (raster / page)
    sc = (gw / W) if v else (gh / H)
    ha, wc = (gh, gw) if v else (gw, gh)                 # raster extent along / across
    tr = th * sc
    ry0, ry1, rx0, rx1 = y0 * sa, y1 * sa, x0 * sc, x1 * sc
    ex = int(C['ext'] * tr) + 1; cx = int(C['xext'] * tr) + 1
    Y0 = int(max(0.0, ry0 - ex)); Y1 = int(min(float(ha), ry1 + ex))
    X0 = int(max(0.0, rx0 - cx)); X1 = int(min(float(wc), rx1 + cx))
    ch, cw = max(0, Y1 - Y0), max(0, X1 - X0)
    crop = gray[Y0:Y0 + ch, X0:X0 + cw] if v else gray[X0:X0 + cw, Y0:Y0 + ch].T   # [along, cross]
    crop = np.asarray(crop, np.int32)
    iy0 = rnd(ry0) - Y0; iy1 = rnd(ry1) - Y0; ix0 = rnd(rx0) - X0; ix1 = rnd(rx1) - X0
    bx0 = max(0, int(rx0 + 0.1 * tr) - X0); bx1 = min(cw, int(rx1 - 0.1 * tr) - X0)
    if bx1 <= bx0: bx0, bx1 = max(0, ix0), min(cw, ix1 + 1)
    r0, r1 = clamp_range(iy0, max(iy0 + 1, iy1), ch); c0, c1 = clamp_range(ix0, max(ix0 + 1, ix1), cw)
    inner = crop[r0:r1, c0:c1]
    if inner.size:
        hist = np.bincount(inner.ravel(), minlength=256); m = inner.size; cum = np.cumsum(hist)
        lo = int(np.searchsorted(cum, (m - 1) // 2 + 1)); hi = int(np.searchsorted(cum, m // 2 + 1))
        bg = (lo + hi) / 2.0
    else:
        bg = 255.0
    g[4] = bg
    dev = np.abs(crop - bg)
    b0, b1 = clamp_range(bx0, bx1, cw)
    ys0, ys1 = clamp_range(max(0, iy0), max(iy0 + 1, iy1), ch)
    ink = [dev > t for t in C['thresholds']]
    ca = [k[:, b0:b1].sum(1).astype(int).tolist() for k in ink]       # along counts per row, of (b1 - b0)
    cc = [k[ys0:ys1].sum(0).astype(int).tolist() for k in ink]        # cross counts per column, of (ys1 - ys0)
    csa = [_prefix(a) for a in ca]; csc = [_prefix(c) for c in cc]
    # continuation evidence (T = 70): band vs side-margin ink, inside the line and in two outer windows
    ml = clamp_range(max(0, ix0 - int(0.4 * tr)), max(0, ix0 - int(0.1 * tr)), cw)
    mr = clamp_range(min(cw, ix1 + int(0.1 * tr)), min(cw, ix1 + int(0.4 * tr)), cw)
    k70 = ink[1]
    cl = _prefix(k70[:, ml[0]:ml[1]].sum(1).astype(int).tolist())
    cr = _prefix(k70[:, mr[0]:mr[1]].sum(1).astype(int).tolist())
    cb = csa[1]

    def win(a, b):
        a = max(0, a); b = min(ch, b)
        if b <= a: return [-1.0, -1.0]
        band = (cb[b] - cb[a]) / ((b - a) * (b1 - b0)) if b1 > b0 else 0.0
        side = -1.0
        for cs_, (m0, m1) in ((cl, ml), (cr, mr)):
            if m1 > m0: side = max(side, (cs_[b] - cs_[a]) / ((b - a) * (m1 - m0)))
        return [band, side]
    ref = win(ys0, ys1)
    cont = []
    for side in (0, 1):
        e = iy0 if side == 0 else iy1; d = -1 if side == 0 else 1
        c = list(ref)
        for a, b in ((0, .5), (.5, 1.0)):
            lo, hi = e + d * int(a * tr), e + d * int(b * tr)
            c += win(min(lo, hi), max(lo, hi))
        cont.append(c)
    rows = []
    for side in range(4):
        f = list(g)
        f += [float(side == k) for k in range(4)]
        if side < 2:
            chr_ = (text[0] if side == 0 else text[-1]) if nch else ''
            cls = char_class(chr_) if chr_ else -1
        else:
            cls = -2
        f += [float(cls == k) for k in range(-1, 10)]
        rd = ([(y0 - R[1]), (R[3] - y1), (x0 - R[0]), (R[2] - x1)][side] / th) if R is not None else 9.0
        f += [rd, nb[side], [y0, ph - y1, x0, pw - x1][side] / th, fe[side], float(nf)]
        for k in range(len(C['thresholds'])):
            if side < 2:
                e = iy0 if side == 0 else iy1 - 1; d = -1 if side == 0 else 1
                f += _edge(ca[k], csa[k], b1 - b0, e, d, tr, C['gaps'], C['bins'], C['inner'], int(0.5 * tr), ex, C['tw'])
            else:
                e = ix0 if side == 2 else ix1 - 1; d = -1 if side == 2 else 1
                f += _edge(cc[k], csc[k], ys1 - ys0, e, d, tr, C['cgaps'], C['cbins'], C['cinner'], int(0.3 * tr), cx,
                           C['tw'])
        f += cont[side] if side < 2 else [0.0] * 6
        rows.append(f)
    return rows, (v, B, th)


def page_features(page, gray):
    """page: dict(width, height, lines[{box, poly, vertical, text, conf, score}], frags[{box}], layout[{kind, box}])."""
    W, H = float(page['width']), float(page['height'])
    lines = page['lines']
    regions = [(r['kind'], r['box']) for r in page['layout'] if r['kind'] in ('text', 'balloon')]
    frag_boxes = [f['box'] for f in page['frags']]
    out = []
    for i, l in enumerate(lines):
        v = l['vertical']
        tf = (lambda b: b) if v else _swap
        oth = [tf(o['box']) for j, o in enumerate(lines) if j != i] + [tf(b) for b in frag_boxes]
        regs = [(k, tf(R)) for k, R in regions]
        out.append(line_features(l, oth, regs, [tf(b) for b in frag_boxes], gray, W, H))
    return out


NFEAT = 65


# ---- trees ----
def fit_trees(X, Y, clip, kw):
    from sklearn.ensemble import HistGradientBoostingRegressor
    m = HistGradientBoostingRegressor(loss='absolute_error', random_state=0, **kw)
    m.fit(np.asarray(X, float), np.clip(np.asarray(Y, float), *clip))
    return export(m), m


def export(m):
    """Flat arrays as PipelineLineKeep: x[feature] <= split goes left, left < 0 marks a leaf (value)."""
    roots, feat, split, left, right, value = [], [], [], [], [], []
    for pr in m._predictors:
        t = pr[0].nodes; base = len(feat); roots.append(base)
        for nd in t:
            leaf = bool(nd['is_leaf'])
            feat.append(0 if leaf else int(nd['feature_idx']))
            split.append(0.0 if leaf else float(nd['num_threshold']))
            left.append(-1 if leaf else base + int(nd['left']))
            right.append(-1 if leaf else base + int(nd['right']))
            value.append(float(nd['value']) if leaf else 0.0)
    return dict(base=float(np.ravel(m._baseline_prediction)[0]), roots=roots, feature=feat, split=split,
                left=left, right=right, value=value)


def tree_predict(t, X):
    """Sequential sum over trees from the baseline, the Swift order."""
    X = np.asarray(X, float); n = len(X)
    feat = np.asarray(t['feature']); split = np.asarray(t['split']); left = np.asarray(t['left'])
    right = np.asarray(t['right']); value = np.asarray(t['value'])
    z = np.full(n, t['base']); rows = np.arange(n)
    for r in t['roots']:
        node = np.full(n, r)
        while True:
            inner = left[node] >= 0
            if not inner.any(): break
            go = X[rows, feat[node]] <= split[node]
            node = np.where(inner, np.where(go, left[node], right[node]), node)
        z = z + value[node]
    return z


def offsets(model, feats):
    """feats: page_features output -> n x 4 offsets (top, bottom, left, right in the line frame, thickness units)."""
    if not feats: return np.zeros((0, 4))
    X = np.array([r for r, _ in feats], float)          # n x 4 x 65
    oa = tree_predict(model['along'], X[:, :2].reshape(-1, NFEAT)).reshape(-1, 2)
    oc = tree_predict(model['cross'], X[:, 2:].reshape(-1, NFEAT)).reshape(-1, 2)
    return np.concatenate([oa, oc], 1)


def assemble(meta, off):
    v, B, th = meta
    nb = [B[0] - off[2] * th, B[1] - off[0] * th, B[2] + off[3] * th, B[3] + off[1] * th]
    if nb[3] - nb[1] < C['minSide'] or nb[2] - nb[0] < C['minSide']: return None
    return nb if v else _swap(nb)


def targets(meta, G):
    v, B, th = meta
    G = list(map(float, G))
    if not v: G = _swap(G)
    return [(B[1] - G[1]) / th, (G[3] - B[3]) / th, (B[0] - G[0]) / th, (G[2] - B[2]) / th]


def map_poly(poly, ob, nb):
    """The detector quad stretched onto the new box by a per-axis linear map."""
    if not poly or len(poly) < 4: return poly
    sx = (nb[2] - nb[0]) / max(ob[2] - ob[0], 1e-6); sy = (nb[3] - nb[1]) / max(ob[3] - ob[1], 1e-6)
    return [[nb[0] + (q[0] - ob[0]) * sx, nb[1] + (q[1] - ob[1]) * sy] for q in poly]


def refine(page, gray, model):
    """[{box, poly, moved}] per input line (box/poly unchanged when the refined box is degenerate)."""
    feats = page_features(page, gray)
    off = offsets(model, feats)
    out = []
    for l, (_, meta), o in zip(page['lines'], feats, off):
        nb = assemble(meta, o)
        if nb is None: out.append(dict(box=list(l['box']), poly=l.get('poly'), moved=False))
        else: out.append(dict(box=nb, poly=map_poly(l.get('poly'), l['box'], nb), moved=True))
    return out


# ---- gray raster ----
def raster_size(W, H):
    s = min(1.0, 768 / max(W, H))
    return max(1, int(W * s)), max(1, int(H * s))


def emulate_gray(path, W, H):
    """Stand-in for the CoreGraphics raster when no dump exists: sRGB luminance (linear Rec.709, sRGB re-encoded)
    over white, Hamming downscale. Mean |diff| vs the CG raster is about 0.5 gray levels."""
    from PIL import Image
    im = Image.open(path).convert('RGBA')
    bgi = Image.new('RGBA', im.size, (255, 255, 255, 255))
    A = np.asarray(Image.alpha_composite(bgi, im).convert('RGB'), np.float32) / 255
    lin = np.where(A <= 0.04045, A / 12.92, ((A + 0.055) / 1.055) ** 2.4)
    Y = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    g = np.where(Y <= 0.0031308, 12.92 * Y, 1.055 * np.power(np.maximum(Y, 0), 1 / 2.4) - 0.055)
    G = Image.fromarray(np.clip(g * 255 + 0.5, 0, 255).astype(np.uint8))
    rw, rh = raster_size(*G.size) if (W, H) == G.size else raster_size(W, H)
    return np.asarray(G.resize((rw, rh), Image.HAMMING), np.uint8)


def load_gray(pid, image, W, H, dirs):
    """(raster, 'cg' | 'emulated'): the CG dump DIR/ID.raw + DIR/ID.size from the first dir that has it."""
    for d in dirs:
        raw, size = d / f'{pid}.raw', d / f'{pid}.size'
        if raw.exists() and size.exists():
            w, h = map(int, open(size).read().split())
            if (w, h) == raster_size(W, H):
                return np.fromfile(raw, np.uint8).reshape(h, w), 'cg'
    return emulate_gray(image, W, H), 'emulated'
