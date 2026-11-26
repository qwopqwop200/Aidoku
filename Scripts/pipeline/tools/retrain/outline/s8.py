"""Python port of the app's S8 style estimator (PipelineStyle.swift), copied from port-eval/stageopt/outline/s8.py:
font prior, per-block crop analysis (k-means candidates, ring profiles, density peaks), fill picks
(PipelineWeights.bin forests), the outline observation + presence forest + page-consensus logistic + ring line, and
page style unification. Numbers only; pixels are read numerically.
The page logistic and ring line come from Resources/Translation/PipelineOutlineWidth.json (`presencePage`, `ringLine`).
Known gap: the fill colour still takes the old density-peak forest (bin slot 3) instead of PipelineFillPeaks.json.
It only moves the page unification grouping (the eval), never the width training rows (ring width and font)."""
import json, struct, math
import numpy as np
from scipy import ndimage as ndi
from PIL import Image
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # tools dir
from workspace import WEIGHTS, REPO  # noqa: E402

K = 5; KI = 3; MAXPIX = 90_000; MAXS = 4_000
NORM = 441.6729559300637
F32 = np.float32


# ---------------- weights ----------------
def load_forests(path=WEIGHTS):
    data = open(path, 'rb').read(); off = 0
    def read(fmt):
        nonlocal off
        n = struct.unpack_from('<I', data, off)[0]; sz = struct.calcsize(fmt)
        v = np.frombuffer(data, dtype={'f': '<f4', 'd': '<f8', 'i': '<i4', 'h': '<i2'}[fmt], count=n, offset=off + 4)
        off += 4 + n * sz
        return v
    read('f'); read('f')
    out = []
    while off < len(data):
        sc = read('d'); out.append(dict(base=sc[0], rate=sc[1], roots=read('i'), feat=read('h'), thr=read('d'),
                                        left=read('i'), right=read('i'), val=read('d')))
    return out  # fillPass1, fillPass2, outline, fillPeaks, lineEnds


def flogit(fo, x):
    x = [float(np.float32(v)) for v in x]
    z = 0.0; L = fo['left']; R = fo['right']; T = fo['thr']; Fe = fo['feat']; V = fo['val']
    for n in fo['roots']:
        n = int(n)
        while L[n] >= 0:
            n = int(L[n]) if x[Fe[n]] <= T[n] else int(R[n])
        z += V[n]
    return fo['base'] + fo['rate'] * z


FORESTS = load_forests()
P1, P2, OUT, PEAKS = FORESTS[0], FORESTS[1], FORESTS[2], FORESTS[3]
_CONST = json.load(open(REPO / 'Aidoku/Resources/Translation/PipelineOutlineWidth.json'))
OUTLINE_PAGE = list(_CONST['presencePage'])
W_RING, W_FONT, W_BIAS = _CONST['ringLine']


# ---------------- colour ----------------
def lab(c):
    def lin(v):
        v = v / 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(float(v)) for v in c)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047; y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]


def dE(a, b):
    p, q = lab(a), lab(b)
    return math.sqrt(sum((u - v) ** 2 for u, v in zip(p, q)))


def dist(a, b): return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3))) / NORM
def lum(c): return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
def chroma(c): return (max(c) - min(c)) / 255
def cmedian(cols):
    a = np.array(cols, float); return list(np.median(a, axis=0))
def rgb8(c): return tuple(int(np.clip(np.rint(v), 0, 255)) for v in c)


def lab_arr(rgb):
    t = rgb.astype(np.float64) / 255
    t = np.where(t <= 0.04045, t / 12.92, ((t + 0.055) / 1.055) ** 2.4)
    r, g, b = t[..., 0], t[..., 1], t[..., 2]
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047; y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda q: np.where(q > 0.008856, np.cbrt(q), 7.787 * q + 16 / 116)
    fx, fy, fz = f(x), f(y), f(z)
    return np.stack([116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)], -1)


# ---------------- font prior (PipelineSimpleFont) ----------------
def _hull(pts):
    pts = sorted(set(map(tuple, pts)))
    if len(pts) <= 2: return pts
    cr = lambda o, a, b: (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in pts:
        while len(lo) >= 2 and cr(lo[-2], lo[-1], p) <= 0: lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(up) >= 2 and cr(up[-2], up[-1], p) <= 0: up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]


def _minbox(poly):
    h = _hull(poly)
    if len(h) < 3: return None
    best = None
    for i in range(len(h)):
        a, b = h[i], h[(i + 1) % len(h)]
        dx, dy = b[0] - a[0], b[1] - a[1]; L = math.hypot(dx, dy)
        if L <= 1e-9: continue
        ux, uy = dx / L, dy / L
        us = [(p[0] - a[0]) * ux + (p[1] - a[1]) * uy for p in h]; vs = [-(p[0] - a[0]) * uy + (p[1] - a[1]) * ux for p in h]
        w, hh = max(us) - min(us), max(vs) - min(vs)
        if w <= 1e-9 or hh <= 1e-9: continue
        if best is None or w * hh < best[1] - 1e-9: best = (min(w, hh), w * hh)
    return best


def font_prior(blocks):
    """blocks: dicts with bounds (x, y, w, h), lines (list of polygons), chars."""
    vals, mem, wts = [], [], []
    for b in blocks:
        # The font prior reads the pre-refine geometry when the block has it (PipelineBlock.sizingGeometry).
        x, y, w, h = b.get('size_bounds') or b['bounds']; cnt = max(1, b['chars']); wts.append(float(cnt))
        prior = max(8, min(min(w, h), math.sqrt(w * h / cnt))) if w > 0 and h > 0 else 8
        boxes = [q for q in (_minbox(p) for p in (b.get('size_lines') or b['lines']) if 3 <= len(p) <= 256) if q]
        if boxes:
            boxes.sort(); half = sum(a for _, a in boxes) * 0.5; c = 0; m = boxes[-1][0]
            for s_, a in boxes:
                c += a
                if c >= half: m = s_; break
        else: m = prior
        mem.append(m); vals.append(max(1, 0.43853239073260936 * prior + 0.4140206805546956 * m + 4.094089327930639))
    S = 1.0252379527066393
    if len(vals) <= 1: return [v * S for v in vals]
    order = sorted(range(len(vals)), key=lambda i: (-wts[i], vals[i], mem[i], i))
    groups = []
    for i in order:
        for g in groups:
            if all(abs(math.log(vals[i] / vals[o])) + 0.8212525806130213 * abs(math.log(mem[i] / mem[o])) <= 0.9705176286667344 for o in g):
                g.append(i); break
        else: groups.append([i])
    res = list(vals)
    for g in groups:
        it = sorted(((vals[i], wts[i]) for i in g)); half = sum(w for _, w in it) * 0.5; c = 0; med = it[-1][0]
        for k, (v, w) in enumerate(it):
            c += w
            if c == half and k + 1 < len(it): med = (v + it[k + 1][0]) * 0.5; break
            if c > half: med = v; break
        for i in g: res[i] = med
    return [v * S for v in res]


# ---------------- crop ----------------
def fill_polys(h, w, polys):
    """Pixel-centre polygon fill (non-antialiased, nonzero/even-odd same for simple polygons)."""
    m = np.zeros((h, w), bool)
    for P in polys:
        P = np.asarray(P, float)
        if len(P) < 3: continue
        y0 = max(0, int(math.floor(P[:, 1].min() - 0.5))); y1 = min(h, int(math.ceil(P[:, 1].max() + 0.5)))
        x0 = max(0, int(math.floor(P[:, 0].min() - 0.5))); x1 = min(w, int(math.ceil(P[:, 0].max() + 0.5)))
        if y1 <= y0 or x1 <= x0: continue
        ys = np.arange(y0, y1) + 0.5; xs = np.arange(x0, x1) + 0.5
        X, Y = np.meshgrid(xs, ys)
        inside = np.zeros(X.shape, bool)
        n = len(P)
        for i in range(n):
            ax, ay = P[i]; bx, by = P[(i + 1) % n]
            if ay == by: continue
            cond = (ay <= Y) != (by <= Y)
            xi = ax + (Y - ay) * (bx - ax) / (by - ay)
            inside ^= cond & (X < xi)
        m[y0:y1, x0:x1] |= inside
    return m


def make_crop(img, bounds, lines, font, resample=Image.BILINEAR):
    H, W = img.shape[:2]
    m = max(6, 0.5 * font)
    bx, by, bw, bh = bounds
    px = lambda v, L: int(min(L, max(0, v)))
    x0, y0 = px(bx - m, W), px(by - m, H)
    x1, y1 = px(math.ceil(bx + bw + m), W), px(math.ceil(by + bh + m), H)
    if x1 - x0 < 4 or y1 - y0 < 4: return None
    s = min(1, math.sqrt(MAXPIX / ((x1 - x0) * (y1 - y0))))
    w, h = x1 - x0, y1 - y0
    sub = img[y0:y1, x0:x1]
    if s < 1:
        w = max(4, int((x1 - x0) * s)); h = max(4, int((y1 - y0) * s)); s = w / (x1 - x0)
        sub = np.asarray(Image.fromarray(sub).resize((w, h), resample))
    polys = [[((p[0] - x0) * s, (p[1] - y0) * s) for p in L] for L in lines if len(L) >= 3]
    return dict(rgb=np.ascontiguousarray(sub[:, :, :3]), lines=fill_polys(h, w, polys), s=s, w=w, h=h, x0=x0, y0=y0)


def sqdist(mask):
    """Exact squared distance to the nearest True pixel (int64); huge where none."""
    if not mask.any(): return np.full(mask.shape, 2 ** 31 - 1, np.int64)
    _, ind = ndi.distance_transform_edt(~mask, return_indices=True)
    yy, xx = np.indices(mask.shape)
    return (yy - ind[0]).astype(np.int64) ** 2 + (xx - ind[1]).astype(np.int64) ** 2


def kmeans(rgb, k, include):
    flat = rgb.reshape(-1, 3)[include.reshape(-1)]
    total = len(flat); step = max(1, total // MAXS)
    x = flat[::step].astype(F32); n = len(x)
    lu = F32(0.299) * x[:, 0] + F32(0.587) * x[:, 1] + F32(0.114) * x[:, 2]
    rank = int(0.05 * (n - 1))
    first = np.argsort(lu, kind='stable')[rank]
    c = np.zeros((k, 3), F32); c[0] = x[first]
    def d2(cc):
        d = x - cc; return d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1] + d[:, 2] * d[:, 2]
    dmin = d2(c[0])
    for ch in range(1, k):
        pos = 0.98 * (n - 1); lo = int(pos); up = min(n - 1, lo + 1)
        srt = np.sort(dmin); low = srt[lo]; high = srt[up]
        thr = F32(low + F32(pos - lo) * (high - low))
        best = int(np.argmin(np.abs(dmin - thr)))
        c[ch] = x[best]; dmin = np.minimum(dmin, d2(c[ch]))
    for _ in range(8):
        D = np.stack([d2(c[j]) for j in range(k)], 1); a = np.argmin(D, 1)
        moved = False
        for j in range(k):
            sel = a == j
            if not sel.any(): continue
            v = (np.cumsum(x[sel].astype(np.float64), 0)[-1] / sel.sum()).astype(F32)
            if (v != c[j]).any(): moved = True
            c[j] = v
        if not moved: break
    return c


def assign(rgb, c):
    x = rgb.reshape(-1, 3).astype(F32)
    D = np.stack([((x - c[j]) ** 2) @ np.ones(3, F32) if False else
                  (lambda d: d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1] + d[:, 2] * d[:, 2])(x - c[j]) for j in range(len(c))], 1)
    return np.argmin(D, 1).astype(np.uint8)


FOOT = np.array([[abs(dy) + abs(dx) <= 2 and dx * dx + dy * dy <= 4 for dx in range(-2, 3)] for dy in range(-2, 3)])


def measure(cr, M, s):
    """M: member mask (HxW bool)."""
    c = dict(count=int(M.sum()), inLines=0.0, inRing=0.0, exterior=0.0, core=[0, 0, 0], coreCount=0, strokeWidth=0.0,
             exteriorDistance=0.0, neighbourPurity=0.0, shellExterior=0.0, neighbours=[], enclosed=False, interior=False)
    if c['count'] < 4: return c
    own = cr['own']; a = cr['assign2d']; rgb = cr['rgb']
    cnt = c['count']
    c['exterior'] = float((M & own).sum()) / cnt
    P = np.pad(M, 1, constant_values=False)
    inner = P[:-2, 1:-1] & P[2:, 1:-1] & P[1:-1, :-2] & P[1:-1, 2:]
    perim = int((M & ~inner).sum())
    Q = np.pad(M, 1, constant_values=True)
    core = M.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0: continue
            core &= Q[1 + dy:Q.shape[0] - 1 + dy, 1 + dx:Q.shape[1] - 1 + dx]
    cc = int(core.sum())
    src = core if cc >= 4 else M
    c['core'] = list(np.median(rgb[src].astype(np.float64), axis=0)); c['coreCount'] = cc if cc >= 4 else cnt
    c['strokeWidth'] = 2 * cnt / max(1, perim) / s
    c['exteriorDistance'] = float(np.median(np.sqrt(cr['ext2'][M].astype(np.float64)))) / s
    shell = ndi.binary_dilation(M, structure=FOOT) & ~M
    sh = int(shell.sum())
    nb = np.bincount(a[shell], minlength=K)[:K].astype(float)
    c['neighbourPurity'] = float(nb.max()) / max(1, sh) if sh else 0.0
    c['neighbours'] = list(nb / max(1, sh))
    c['shellExterior'] = float((shell & own).sum()) / max(1, sh)
    return c


def ring_profile(cr, M, s, font):
    d2 = sqdist(M)
    limit = max(2, 0.45 * font * s)
    bins = min(40, max(12, int(math.ceil(0.3 * font * s))))
    top = (bins + 1) ** 2
    ok = (d2 > 0) & (d2 < top) & (cr['line2'] <= limit * limit)
    b = np.zeros(d2.shape, np.int64)
    b[ok] = np.ceil(np.sqrt(d2[ok].astype(np.float64)) - 0.5).astype(np.int64)
    rgb = cr['rgb']; out = []
    for k in range(1, bins + 1):
        sel = ok & (b == k)
        n = int(sel.sum())
        if n < 4: out.append(None); continue
        px = rgb[sel].astype(np.float64)
        med = np.median(px, axis=0)
        tot = np.abs(px - med).sum(1)
        mad = float(np.median(np.floor(tot * 2 + 0.5))) / 2
        out.append(dict(distance=k / s, median=list(med), mad=mad, n=n))
    return out


def density_peaks(cr):
    idx = np.flatnonzero(cr['lines'].reshape(-1))
    if len(idx) < 16: return []
    step = max(1, len(idx) // 20000); smp = idx[::step]
    px = cr['rgb'].reshape(-1, 3)[smp]
    L = np.floor(lab_arr(px) / 6.0).astype(np.int64)
    pk = ((L[:, 0] + 64) << 16) | ((L[:, 1] + 64) << 8) | (L[:, 2] + 64)
    u, first, inv, cnt = np.unique(pk, return_index=True, return_inverse=True, return_counts=True)
    counts = dict(zip(u.tolist(), cnt.tolist()))
    total = float(len(smp)); peaks = []
    for f in sorted(first.tolist()):
        key = int(pk[f]); c = counts[key]
        if c < 0.01 * total: continue
        k0, k1, k2 = L[f]; isp = True
        for a in (-1, 0, 1):
            for b in (-1, 0, 1):
                for d in (-1, 0, 1):
                    if a == b == d == 0: continue
                    n = counts.get(int(((k0 + a + 64) << 16) | ((k1 + b + 64) << 8) | (k2 + d + 64)))
                    if n is not None and n > c: isp = False
        if isp: peaks.append((c, key, (k0, k1, k2)))
    peaks.sort(key=lambda p: (-p[0], -p[1]))
    out = []
    for c, key, (k0, k1, k2) in peaks[:8]:
        sel = (np.abs(L[:, 0] - k0) <= 1) & (np.abs(L[:, 1] - k1) <= 1) & (np.abs(L[:, 2] - k2) <= 1)
        out.append(dict(rgb=list(np.median(px[sel].astype(np.float64), axis=0)), share=c / total))
    return out


def analyze(img, bounds, lines, font, resample=Image.BILINEAR):
    cr = make_crop(img, bounds, lines, font, resample)
    if cr is None: return None
    s = cr['s']; Lm = cr['lines']; lc = int(Lm.sum())
    if lc < 16: return None
    cr['line2'] = sqdist(Lm)
    rr = max(2, 0.2 * font * s)
    ring = cr['line2'] > rr * rr
    if ring.sum() < 16: ring = ~Lm
    cen = kmeans(cr['rgb'], K, Lm)
    a = assign(cr['rgb'], cen).reshape(Lm.shape); cr['assign2d'] = a
    rb = cr['rgb'][ring]
    ring_bg = list(np.median(rb.astype(np.float64), axis=0)) if len(rb) else [255, 255, 255]
    # exterior flood: same-label 4-connected components touching the ring
    own = ring.copy()
    st4 = ndi.generate_binary_structure(2, 1)
    for j in range(K):
        lab_, nl = ndi.label(a == j, structure=st4)
        if nl == 0: continue
        hit = np.unique(lab_[ring & (a == j)]); hit = hit[hit > 0]
        if len(hit): own |= np.isin(lab_, hit)
    if not own.any(): return None
    cr['own'] = own; cr['ext2'] = sqdist(own)
    near = cr['line2'] <= 4
    nring = int(ring.sum())
    cl = []
    plain = []
    for j in range(K):
        M = (a == j) & near; plain.append(M)
        c = measure(cr, M, s)
        c['inLines'] = float(((a == j) & Lm).sum()) / lc; c['inRing'] = float(((a == j) & ring).sum()) / max(1, nring)
        c['mask'] = ('plain', j)
        cl.append(c)
    def extra(M):
        c = measure(cr, M, s); c['inLines'] = float((M & Lm).sum()) / lc
        if c['count'] < 16: c['count'] = 0
        return c
    masks = list(plain)
    for j in range(K):
        if cl[j]['count'] >= 4 and cl[j]['exterior'] >= 0.3:
            M = plain[j] & ~own; c = extra(M)
        else:
            M = np.zeros_like(Lm); c = dict(measure(cr, M, s))
        c['enclosed'] = True; cl.append(c); masks.append(M)
    interior = Lm & ~own
    if interior.sum() >= 16:
        ci = kmeans(cr['rgb'], KI, interior)
        ia = assign(cr['rgb'], ci).reshape(Lm.shape)
        zone = near & ~own
        for j in range(KI):
            M = zone & (ia == j); c = extra(M); c['interior'] = True; cl.append(c); masks.append(M)
    else:
        for j in range(KI):
            M = np.zeros_like(Lm); c = measure(cr, M, s); c['interior'] = True; cl.append(c); masks.append(M)
    for c in cl: c['valid'] = c['count'] >= 4
    modes = density_peaks(cr)
    return dict(font=font, scale=s, ringBackground=ring_bg, clusters=cl, masks=masks, crop=cr, modes=modes, profiles={})


# ---------------- decisions ----------------
def cand_feats(f, j, consensus, ctx):
    cl = f['clusters']; c = cl[j]; font = f['font']
    ids, pool, maxd, lums, bgj0 = ctx
    colour = c['core']; lu = lums[j]; sw = c['strokeWidth'] / font
    fM, fR = c['inLines'], c['inRing']
    bgj = bgj0 if bgj0 is not None else j
    d = bgj
    if c['neighbours'] and max(c['neighbours']) > 0: d = c['neighbours'].index(max(c['neighbours']))
    dc = cl[d] if cl[d]['valid'] else cl[bgj]
    cnt = float(len(ids))
    darker = sum(1 for i in ids if lums[i] < lu); nearer = sum(1 for i in ids if cl[i]['exteriorDistance'] < c['exteriorDistance'])
    x = [c['exterior'], math.log((fM + 0.01) / (fR + 0.01)), fM, fR, lu / 255, dist(colour, f['ringBackground']),
         c['neighbourPurity'], sw, chroma(colour), 1 if lu > 200 else 0, c['exteriorDistance'] / font,
         c['coreCount'] / max(1, c['count']), c['shellExterior'],
         1 if (c['exteriorDistance'] >= maxd and j in pool) else 0,
         dist(colour, consensus) if consensus is not None else 0, 1 if c['enclosed'] else 0, 1 if c['interior'] else 0,
         darker / cnt, nearer / cnt, dc['exterior'], cl[d]['inRing'], dc['exteriorDistance'] / font, dist(colour, dc['core']),
         (lu - lum(dc['core'])) / 255, dist(colour, cl[bgj]['core']), (lu - lums[bgj]) / 255, 0 if consensus is None else 1]
    i = -1; nearest = 0.0
    for o in ids:
        if o == j: continue
        v = dist(colour, cl[o]['core'])
        if i < 0 or v < nearest: i, nearest = o, v
    if i >= 0:
        x += [nearest, fR - cl[i]['inRing'], (c['exteriorDistance'] - cl[i]['exteriorDistance']) / font,
              1 if (cl[i]['interior'] or cl[i]['enclosed']) else 0, fM - cl[i]['inLines']]
    else: x += [1, 0, 0, 0, 0]
    return x


def context(f):
    cl = f['clusters']; ids = [i for i, c in enumerate(cl) if c['valid']]
    big = [i for i in ids if cl[i]['inLines'] >= 0.08]; pool = big or ids
    maxd = max((cl[i]['exteriorDistance'] for i in pool), default=0)
    plain = [i for i in ids if i < K]; bgj = None
    if plain:
        bgj = plain[0]
        for i in plain:
            if cl[i]['inRing'] > cl[bgj]['inRing']: bgj = i
    return ids, pool, maxd, [lum(c['core']) for c in cl], bgj


def scored_pick(f, forest, consensus):
    ctx = context(f); best = None; bs = -math.inf
    for j in ctx[0]:
        sc = flogit(forest, cand_feats(f, j, consensus, ctx))
        if sc > bs: best, bs = j, sc
    return None if best is None else (best, bs)


def halo(c, far, fill):
    v = [c[i] - far[i] for i in range(3)]; u = [far[i] - fill[i] for i in range(3)]
    nrm = math.sqrt(sum(t * t for t in u))
    if nrm > 1e-9:
        u = [t / nrm for t in u]; pr = sum(v[i] * u[i] for i in range(3))
        if pr < 0: v = [v[i] - pr * u[i] for i in range(3)]
    return math.sqrt(sum(t * t for t in v)) / NORM


def observation(f, j, profile, background):
    rings = [r for r in profile if r]
    if not rings: return None
    far = rings[-1]; fill = f['clusters'][j]['core']; font = f['font']
    limit = max(3, 0.22 * font)
    near = [r for r in rings if 1.5 <= r['distance'] <= limit] or [rings[0]]
    pi, ps = 0, -math.inf
    for i, r in enumerate(near):
        sc = halo(r['median'], far['median'], fill)
        if sc > ps: pi, ps = i, sc
    peak = near[pi]; colour = peak['median']; step = ps
    width = 0.0; seen = False
    for r in rings:
        if r['distance'] == peak['distance']: seen = True
        if seen:
            if dist(r['median'], colour) > 0.5 * step: break
            width = r['distance']
    x = [step, dist(colour, fill), dist(far['median'], fill), peak['mad'] / 441, far['mad'] / 441,
         lum(colour) / 255, lum(fill) / 255, f['clusters'][j]['inRing'], dist(colour, background),
         1 if lum(colour) > 200 else 0, width / font, math.log1p(step * 441), math.log1p(step * 441 / (1 + far['mad'] + peak['mad'])),
         chroma(fill), chroma(colour), font / 100]
    return dict(x=x, colour=colour, ringWidth=width, peak=peak, far=far)


def peak_feats(f, pick, plogit, outline):
    ring = f['ringBackground']; cols = [pick] + [m['rgb'] for m in f['modes']]; shares = [m['share'] for m in f['modes']]
    def lc(c): l = lab(c); return l[0], math.hypot(l[1], l[2])
    lp, cp = lc(pick); X = []
    for i, col in enumerate(cols):
        l, c = lc(col); sh = 0 if i == 0 else shares[i - 1]; rank = -1 if i == 0 else shares.index(sh)
        X.append([1 if i == 0 else 0, sh, rank, dE(col, pick), dE(col, ring), dE(col, outline), l, c, l - lp, c - cp,
                  dE(pick, ring), dE(pick, outline), plogit, f['font'] / 100, len(f['modes']), dE(col, ring) - dE(pick, ring)])
    return cols, X


def decide(analyses, fonts):
    """-> per block dict(fill, stroke, width, score, obs, j) before unification."""
    picked = []
    for a in analyses:
        if a is None: continue
        p = scored_pick(a, P1, None)
        if p: picked.append(a['clusters'][p[0]]['core'])
    consensus = cmedian(picked) if picked else None
    res = [dict(fill=(0, 0, 0), stroke=None, width=0.0, score=None, obs=None, j=None, font=fonts[i]) for i in range(len(analyses))]
    for i, a in enumerate(analyses):
        if a is None: continue
        p = scored_pick(a, P2, consensus)
        if p is None: continue
        j, pl = p
        prof = ring_profile(a['crop'], a['masks'][j], a['scale'], a['font'])
        a['profile'] = prof; a['j'] = j
        rings = [r for r in prof if r]
        bg = [float(np.rint(v)) for v in (cmedian([r['median'] for r in rings[-3:]]) if rings else a['ringBackground'])]
        res[i]['fill'] = rgb8(a['clusters'][j]['core']); res[i]['j'] = j; res[i]['bg'] = bg
        ob = observation(a, j, prof, bg)
        if ob:
            res[i]['obs'] = ob; res[i]['score'] = flogit(OUT, ob['x'])
        if a['modes']:
            cols, X = peak_feats(a, a['clusters'][j]['core'], pl, ob['colour'] if ob else a['ringBackground'])
            sc = [flogit(PEAKS, x) for x in X]; res[i]['fill'] = rgb8(cols[int(np.argmax(sc))])
    pres = [r['score'] for r in res if r['score'] is not None]
    if not pres: return res
    pm = float(np.median(pres))
    for r in res:
        r['pageScore'] = pm
        if r['score'] is None or r['obs'] is None: continue
        z = OUTLINE_PAGE[0] * r['score'] + OUTLINE_PAGE[1] * pm + OUTLINE_PAGE[2]
        r['z'] = z
        if z >= 0:
            r['stroke'] = rgb8(r['obs']['colour'])
            r['width'] = max(0.0, W_RING * r['obs']['ringWidth'] + W_FONT * r['font'] + W_BIAS)
    return res


def style_dist(a, b):
    d = dE(a['fill'], b['fill'])
    if a['stroke'] is not None and b['stroke'] is not None: d = max(d, 0.5 * dE(a['stroke'], b['stroke']))
    elif (a['stroke'] is None) != (b['stroke'] is None): d = max(d, 40.0)
    return d


def unify(styles, chars, T=15.0):
    out = [dict(s) for s in styles]
    mem = [i for i in range(len(styles)) if chars[i] >= 4]
    n = len(mem)
    if n < 2: return out
    S = [styles[i] for i in mem]
    D = np.zeros((n, n))
    for a in range(n):
        for b in range(a + 1, n): D[a, b] = D[b, a] = style_dist(S[a], S[b])
    groups = [[i] for i in range(n)]
    while True:
        best = math.inf; pair = None
        for a in range(len(groups)):
            for b in range(a + 1, len(groups)):
                link = max(D[i, j] for i in groups[a] for j in groups[b])
                if link <= T and link < best: best, pair = link, (a, b)
        if not pair: break
        a, b = pair; groups[a] += groups[b]; del groups[b]
    for g in groups:
        if len(g) < 2: continue
        med = min(g, key=lambda i: (sum(D[i, j] for j in g), g.index(i)))
        ol = [i for i in g if S[i]['stroke'] is not None]
        sm = None; bs = math.inf
        for i in ol:
            t = sum(dE(S[i]['stroke'], S[j]['stroke']) for j in ol)
            if t < bs: bs, sm = t, i
        outline = 2 * len(ol) >= len(g)
        ratios = sorted(S[i]['width'] / max(1, S[i]['font']) for i in ol)
        ratio = float(np.median(ratios)) if ratios else 0.0
        for i in g:
            o = out[mem[i]]; o['fill'] = S[med]['fill']; o['group'] = len(g)
            if outline and sm is not None:
                o['stroke'] = S[sm]['stroke']; o['width'] = ratio * S[i]['font']
            else:
                o['stroke'] = None; o['width'] = 0.0
    return out
