"""Python port of S8 colour (PipelineStyle.swift, copied from port-eval/stageopt/fill/port.py): font estimate,
per-block analysis (k-means candidates, exterior flood, cluster measures, density peaks, ring profiles), fill pick
(fillPass1/fillPass2 forests), peak choice (PipelineFillPeaks.json ranker), outline decision and page unification.
Pixels are read numerically only."""
import math, struct, sys
from pathlib import Path
import numpy as np
from scipy import ndimage as ndi

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # tools dir
from workspace import WEIGHTS  # noqa: E402

F32 = np.float32
K = 5; KI = 3; MAXPIX = 90_000; MAXSAMP = 4_000
COLOURNORM = 441.6729559300637
OUTLINE_PAGE = [0.4094924613695863, 0.19954881908897934, -0.9404877504298349]
W_RING, W_FONT, W_BIAS = 0.49653723604023625, 0.042260916827793475, -0.04776139182973868


# ---------------------------------------------------------------- weights / forests
class Forest:
    def __init__(self, base, rate, roots, feat, thr, left, right, val):
        self.base, self.rate = base, rate
        self.roots = np.asarray(roots, np.int64); self.feat = np.asarray(feat, np.int64)
        self.thr = np.asarray(thr, np.float64); self.left = np.asarray(left, np.int64)
        self.right = np.asarray(right, np.int64); self.val = np.asarray(val, np.float64)

    def logits(self, X):
        X = np.asarray(X, np.float64)
        if X.ndim == 1: X = X[None]
        Xf = X.astype(np.float32).astype(np.float64)
        n = len(Xf); node = np.tile(self.roots, (n, 1))
        rows = np.arange(n)[:, None]
        while True:
            l = self.left[node]; act = l >= 0
            if not act.any(): break
            go = Xf[rows, self.feat[node]] <= self.thr[node]
            node = np.where(act, np.where(go, l, self.right[node]), node)
        return self.base + self.rate * self.val[node].sum(1)


def load_weights(path=WEIGHTS):
    data = open(path, 'rb').read(); off = [0]
    def read(fmt):
        n = struct.unpack_from('<I', data, off[0])[0]; sz = struct.calcsize(fmt)
        v = struct.unpack_from('<' + fmt * n, data, off[0] + 4); off[0] += 4 + n * sz; return list(v)
    read('f'); read('f')
    def forest():
        sc = read('d'); return Forest(sc[0], sc[1], read('i'), read('h'), read('d'), read('i'), read('i'), read('d'))
    W = dict(fillPass1=forest(), fillPass2=forest(), outline=forest())
    W['fillPeaks'] = forest() if off[0] < len(data) else None
    return W


# ---------------------------------------------------------------- font (PipelineSimpleFont)
FS = dict(scale=0.43853239073260936, bias=4.094089327930639, ms=0.4140206805546956, brw=0.8212525806130213,
          maxd=0.9705176286667344, gs=1.0252379527066393)


def _cross(a, b, p): return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])


def _hull(poly):
    n = len(poly); signed = 0.0
    for i in range(n): signed += poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1]
    sign = 1.0 if signed > 0 else -1.0
    if signed != 0 and all(sign * _cross(poly[i], poly[(i + 1) % n], p) >= -1e-9 for i in range(n) for p in poly):
        return poly
    uniq = []
    for p in sorted(poly):
        if not uniq or uniq[-1] != p: uniq.append(p)
    if len(uniq) <= 2: return uniq
    lo, up = [], []
    for p in uniq:
        while len(lo) >= 2 and _cross(lo[-2], lo[-1], p) <= 0: lo.pop()
        lo.append(p)
    for p in reversed(uniq):
        while len(up) >= 2 and _cross(up[-2], up[-1], p) <= 0: up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]


def _minbox(poly):
    h = _hull([(float(x), float(y)) for x, y in poly])
    if len(h) < 3: return None
    best = None
    for i in range(len(h)):
        a, b = h[i], h[(i + 1) % len(h)]
        dx, dy = b[0] - a[0], b[1] - a[1]; L = math.hypot(dx, dy)
        if L <= 1e-9: continue
        ux, uy = dx / L, dy / L
        us = [(p[0] - a[0]) * ux + (p[1] - a[1]) * uy for p in h]
        vs = [-(p[0] - a[0]) * uy + (p[1] - a[1]) * ux for p in h]
        w, hh = max(us) - min(us), max(vs) - min(vs)
        if w <= 1e-9 or hh <= 1e-9: continue
        if best is None or w * hh < best[1] - 1e-9: best = (min(w, hh), w * hh)
    return best


def _member_short(polys):
    boxes = [b for b in (_minbox(p) for p in polys if 3 <= len(p) <= 256) if b]
    if not boxes: return None
    boxes.sort(); half = sum(b[1] for b in boxes) * 0.5; cum = 0
    for b in boxes:
        cum += b[1]
        if cum >= half: return b[0]
    return boxes[-1][0]


def _wmedian(items):
    s = sorted(items, key=lambda t: t[0]); half = sum(w for _, w in s) * 0.5; cum = 0
    for i, (v, w) in enumerate(s):
        cum += w
        if cum == half and i + 1 < len(s): return (v + s[i + 1][0]) * 0.5
        if cum > half: return v
    return s[-1][0] if s else 0


def font_estimate(blocks):
    """blocks: dicts with bounds ((x,y),(w,h)), lines [polygon], chars."""
    if not blocks: return []
    vals, mem, wts = [], [], []
    for b in blocks:
        # The font prior reads the pre-refine geometry when the block has it (PipelineBlock.sizingGeometry).
        (x, y), (w, h) = b.get('size_bounds') or b['bounds']; c = max(1, b['chars']); wts.append(float(c))
        prior = max(8, min(min(w, h), math.sqrt(w * h / c))) if w > 0 and h > 0 else 8
        m = _member_short(b.get('size_lines') or b['lines']); m = prior if m is None else m
        mem.append(m); vals.append(max(1, FS['scale'] * prior + FS['ms'] * m + FS['bias']))
    if len(vals) == 1: return [vals[0] * FS['gs']]
    order = sorted(range(len(vals)), key=lambda i: (-wts[i], vals[i], mem[i], i))
    groups = []
    for i in order:
        for g in groups:
            if all(abs(math.log(vals[i] / vals[o])) + FS['brw'] * abs(math.log(mem[i] / mem[o])) <= FS['maxd'] for o in g):
                g.append(i); break
        else: groups.append([i])
    res = list(vals)
    for g in groups:
        med = _wmedian([(vals[i], wts[i]) for i in g])
        for i in g: res[i] = med
    return [v * FS['gs'] for v in res]


# ---------------------------------------------------------------- crop
def fill_polygon(mask, pts):
    """Non-antialiased fill (pixel centre inside, nonzero winding) of a polygon in crop pixel coords."""
    h, w = mask.shape
    P = np.asarray(pts, np.float64)
    x0 = max(0, int(math.floor(P[:, 0].min() - 1))); x1 = min(w, int(math.ceil(P[:, 0].max() + 1)))
    y0 = max(0, int(math.floor(P[:, 1].min() - 1))); y1 = min(h, int(math.ceil(P[:, 1].max() + 1)))
    if x1 <= x0 or y1 <= y0: return
    ys = np.arange(y0, y1) + 0.5; xs = np.arange(x0, x1) + 0.5
    wind = np.zeros((len(ys), len(xs)), np.int32)
    Q = np.roll(P, -1, axis=0)
    for (ax, ay), (bx, by) in zip(P, Q):
        if ay == by: continue
        up = ay <= by
        lo_, hi_ = (ay, by) if up else (by, ay)
        sel = (ys >= lo_) & (ys < hi_)
        if not sel.any(): continue
        yy = ys[sel]; xc = ax + (yy - ay) * (bx - ax) / (by - ay)
        right = xs[None, :] < xc[:, None]
        wind[sel] += np.where(right, 1 if up else -1, 0)
    mask[y0:y1, x0:x1] |= wind != 0


def make_crop(img, bounds, lines, font):
    H, W = img.shape[:2]
    m = max(6, 0.5 * font)
    (bx, by), (bw, bh) = bounds
    px = lambda v, lim: int(min(float(lim), max(0.0, v)))
    x0, y0 = px(bx - m, W), px(by - m, H)
    x1, y1 = px(math.ceil(bx + bw + m), W), px(math.ceil(by + bh + m), H)
    if x1 - x0 < 4 or y1 - y0 < 4: return None
    s = min(1.0, math.sqrt(MAXPIX / ((x1 - x0) * (y1 - y0))))
    w, h = x1 - x0, y1 - y0
    region = img[y0:y1, x0:x1]
    if s < 1:
        w = max(4, int((x1 - x0) * s)); h = max(4, int((y1 - y0) * s)); s = w / (x1 - x0)
        from PIL import Image
        rgb = np.asarray(Image.fromarray(region).resize((w, h), Image.HAMMING))  # the port's choice (closest to Core Graphics)
    else:
        rgb = region
    mask = np.zeros((h, w), bool)
    for poly in lines:
        if len(poly) >= 3:
            fill_polygon(mask, [((x - x0) * s, (y - y0) * s) for x, y in poly])
    return np.ascontiguousarray(rgb, dtype=np.uint8), mask, s, (x0, y0, x1, y1)


def load_page(path):
    from PIL import Image
    im = Image.open(path)
    if im.mode == 'RGBA':
        a = np.asarray(im)
        if a[..., 3].min() < 255:
            al = a[..., 3:4].astype(np.float64) / 255
            return np.round(a[..., :3] * al + 255 * (1 - al)).astype(np.uint8)
        return np.ascontiguousarray(a[..., :3])
    return np.asarray(im.convert('RGB'))


# ---------------------------------------------------------------- primitives
BIG = np.int64(2**31 - 1)


def sqdist(target):
    """Squared Euclidean distance to the nearest True pixel; 2^31-1 with none."""
    if not target.any(): return np.full(target.shape, BIG, np.int64)
    _, (iy, ix) = ndi.distance_transform_edt(~target, return_indices=True)
    yy, xx = np.indices(target.shape)
    return ((yy - iy) ** 2 + (xx - ix) ** 2).astype(np.int64)


def lum32(x):  # x float32 (n,3)
    return F32(0.299) * x[:, 0] + F32(0.587) * x[:, 1] + F32(0.114) * x[:, 2]


def d2_32(x, c):
    a = x[:, 0] - c[0]; b = x[:, 1] - c[1]; z = x[:, 2] - c[2]
    return a * a + b * b + z * z


def pct32(v, q):
    pos = q / 100 * (len(v) - 1); lo = int(pos); hi = min(len(v) - 1, lo + 1)
    s = np.partition(v, (lo, hi)) if hi != lo else np.partition(v, lo)
    low = s[lo]; high = s[hi] if hi != lo else low
    return F32(low + F32(pos - lo) * (high - low))


def kmeans(rgbflat, include, k):
    idx = np.flatnonzero(include)
    step = max(1, len(idx) // MAXSAMP)
    x = rgbflat[idx[::step]].astype(np.float32)
    n = len(x)
    lum = lum32(x)
    rank = int(0.05 * (n - 1))
    first = int(np.argsort(lum, kind='stable')[rank])
    c = np.zeros((k, 3), np.float32); c[0] = x[first]
    dmin = d2_32(x, c[0])
    for j in range(1, k):
        t = pct32(dmin, 98)
        best = int(np.argmin(np.abs(dmin - t)))
        c[j] = x[best]; dmin = np.minimum(dmin, d2_32(x, c[j]))
    xd = x.astype(np.float64)
    for _ in range(8):
        D = np.stack([d2_32(x, c[j]) for j in range(k)], 1)
        lab = np.argmin(D, 1)
        moved = False
        for j in range(k):
            sel = lab == j
            cnt = int(sel.sum())
            if cnt == 0: continue
            v = (xd[sel].sum(0) / cnt).astype(np.float32)
            if (v != c[j]).any(): moved = True
            c[j] = v
        if not moved: break
    return c


def nearest(rgbflat, c):
    x = rgbflat.astype(np.float32)
    D = np.stack([d2_32(x, c[j]) for j in range(len(c))], 1)
    return np.argmin(D, 1).astype(np.uint8)


def med3(rgbflat, idx):
    if len(idx) == 0: return [255.0, 255.0, 255.0]
    return [float(v) for v in np.median(rgbflat[idx].astype(np.float64), axis=0)]


def lab(c):
    c = np.asarray(c, np.float64) / 255
    l = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    r, g, b = l[..., 0], l[..., 1], l[..., 2]
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: np.where(t > 0.008856, t ** (1.0 / 3), 7.787 * t + 16.0 / 116)
    fx, fy, fz = f(x), f(y), f(z)
    return np.stack([116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)], -1)


def dE(a, b):
    if a is None or b is None: return None
    return float(np.sqrt(((lab(a) - lab(b)) ** 2).sum(-1)))


# ---------------------------------------------------------------- analysis
OFFS = [(-2, 0), (2, 0), (0, -2), (0, 2), (-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]
SHELL = np.zeros((5, 5), bool)
for dx, dy in OFFS: SHELL[dy + 2, dx + 2] = True
CROSS = ndi.generate_binary_structure(2, 1)


def measure(crop, members_mask, s, assign, own, extd2):
    """members_mask: bool (h,w)."""
    h, w = members_mask.shape
    cnt = int(members_mask.sum())
    c = dict(count=cnt, inLines=0.0, inRing=0.0, exterior=0.0, core=[0.0, 0.0, 0.0], coreCount=0, strokeWidth=0.0,
             exteriorDistance=0.0, neighbourPurity=0.0, shellExterior=0.0, enclosed=False, interior=False,
             neighbours=[])
    if cnt < 4: return c
    mm = members_mask
    c['exterior'] = float((mm & own).sum()) / cnt
    er4 = ndi.binary_erosion(mm, CROSS, border_value=0)
    perim = int((mm & ~er4).sum())
    core = mm & ndi.binary_erosion(mm, np.ones((3, 3), bool), border_value=1)
    cc = int(core.sum())
    flat = crop.reshape(-1, 3)
    if cc >= 4: c['core'] = med3(flat, np.flatnonzero(core)); c['coreCount'] = cc
    else: c['core'] = med3(flat, np.flatnonzero(mm)); c['coreCount'] = cnt
    c['strokeWidth'] = 2 * cnt / max(1, perim) / s
    c['exteriorDistance'] = float(np.median(np.sqrt(extd2[mm].astype(np.float64)))) / s
    shell = ndi.binary_dilation(mm, SHELL, border_value=0) & ~mm
    sh = int(shell.sum())
    nb = np.bincount(assign[shell], minlength=K)[:K].astype(np.float64)
    c['neighbourPurity'] = float(nb.max()) / max(1, sh)
    c['neighbours'] = list(nb / max(1, sh))
    c['shellExterior'] = float((shell & own).sum()) / max(1, sh)
    return c


def density_peaks(flat, lines, BIN=6.0):
    li = np.flatnonzero(lines.reshape(-1))
    if len(li) < 16: return []
    step = max(1, len(li) // 20000)
    samp = li[::step]
    L = lab(flat[samp].astype(np.float64))
    keys = np.floor(L / BIN).astype(np.int64)
    pack = ((keys[:, 0] + 64) << 16) | ((keys[:, 1] + 64) << 8) | (keys[:, 2] + 64)
    uniq, first, counts = np.unique(pack, return_index=True, return_counts=True)
    cmap = dict(zip(uniq.tolist(), counts.tolist()))
    total = float(len(samp)); peaks = []
    for u in uniq[np.argsort(first)].tolist():
        cc = cmap[u]
        if cc < 0.01 * total: continue
        k0, k1, k2 = (u >> 16) - 64, ((u >> 8) & 255) - 64, (u & 255) - 64
        ok = True
        for a in (-1, 0, 1):
            for b in (-1, 0, 1):
                for d in (-1, 0, 1):
                    if (a, b, d) == (0, 0, 0): continue
                    nk = ((k0 + a + 64) << 16) | ((k1 + b + 64) << 8) | (k2 + d + 64)
                    if cmap.get(nk, 0) > cc: ok = False
        if ok: peaks.append((cc, u, (k0, k1, k2)))
    peaks.sort(key=lambda p: (-p[0], -p[1]))
    out = []
    for cc, u, kk in peaks[:8]:
        sel = (np.abs(keys - np.array(kk)) <= 1).all(1)
        out.append(dict(rgb=med3(flat, samp[sel]), share=cc / total))
    return out


def ring_profile(A, j):
    crop, s, font = A['crop'], A['scale'], A['font']
    mask = cand_mask(A, j)
    d2 = sqdist(mask)
    limit = max(2, 0.45 * font * s); lim2 = limit * limit
    bins = min(40, max(12, int(math.ceil(0.3 * font * s))))
    top = (bins + 1) ** 2
    v = d2.reshape(-1); line = A['lineD2'].reshape(-1)
    ok = (v > 0) & (v < top) & (line.astype(np.float64) <= lim2)
    b = np.zeros(len(v), np.int64)
    b[ok] = np.ceil(np.sqrt(v[ok].astype(np.float64)) - 0.5).astype(np.int64)
    flat = crop.reshape(-1, 3).astype(np.float64)
    rings = []
    for k in range(1, bins + 1):
        idx = np.flatnonzero(ok & (b == k))
        if len(idx) < 4: rings.append(None); continue
        px = flat[idx]; med = np.median(px, 0)
        tot = np.abs(px - med).sum(1)
        q = np.floor(tot * 2 + 0.5)  # rounded (half away from zero; values >= 0)
        rings.append(dict(distance=k / s, median=[float(t) for t in med], mad=float(np.median(q)) / 2))
    return rings


def cand_mask(A, j):
    if j >= 2 * K: return A['iassign'] == (j - 2 * K)
    base = (A['assign'] == (j % K)) & (A['lineD2'] <= 4)
    if j >= K: base &= ~A['own']
    return base


def analyze(img, bounds, lines, font):
    r = make_crop(img, bounds, lines, font)
    if r is None: return None
    crop, linesm, s, box = r
    h, w = linesm.shape; n = h * w
    lc = int(linesm.sum())
    if lc < 16: return None
    flat = crop.reshape(-1, 3)
    lineD2 = sqdist(linesm)
    rr = max(2, 0.2 * font * s)
    ring = lineD2.astype(np.float64) > rr * rr
    if ring.sum() < 16: ring = ~linesm
    cen = kmeans(flat, linesm.reshape(-1), K)
    assign = nearest(flat, cen).reshape(h, w)
    inL = np.bincount(assign[linesm], minlength=K)
    inR = np.bincount(assign[ring], minlength=K); rc = int(ring.sum())
    ringBg = [255.0, 255.0, 255.0] if rc == 0 else med3(flat, np.flatnonzero(ring.reshape(-1)))
    own = ring.copy()
    for lab_ in range(K):
        comp, nc = ndi.label(assign == lab_, CROSS)
        if nc == 0: continue
        hit = np.unique(comp[ring & (assign == lab_)])
        hit = hit[hit > 0]
        if len(hit): own |= np.isin(comp, hit)
    if not own.any(): return None
    extd2 = sqdist(own)
    near = lineD2 <= 4
    clusters = []
    for j in range(K):
        mm = (assign == j) & near
        c = measure(crop, mm, s, assign, own, extd2)
        c['inLines'] = inL[j] / lc; c['inRing'] = inR[j] / max(1, rc)
        clusters.append(c)
    def extra(mm, **flags):
        c = measure(crop, mm, s, assign, own, extd2)
        c.update(flags)
        c['inLines'] = float((mm & linesm).sum()) / lc
        if c['count'] < 16: c['count'] = 0
        return c
    for j in range(K):
        if clusters[j]['count'] >= 4 and clusters[j]['exterior'] >= 0.3:
            clusters.append(extra((assign == j) & near & ~own, enclosed=True))
        else:
            c = measure(crop, np.zeros_like(linesm), s, assign, own, extd2); c['enclosed'] = True; clusters.append(c)
    interior = linesm & ~own
    ic = int(interior.sum())
    iassign = np.full((h, w), 255, np.uint8)
    if ic >= 16:
        cen2 = kmeans(flat, interior.reshape(-1), KI)
        sel = near & ~own
        iassign[sel] = nearest(flat[sel.reshape(-1)], cen2)
    for j in range(KI):
        if ic >= 16: clusters.append(extra(iassign == j, interior=True))
        else:
            c = measure(crop, np.zeros_like(linesm), s, assign, own, extd2); c['interior'] = True; clusters.append(c)
    A = dict(font=font, scale=s, ringBackground=ringBg, clusters=clusters, modes=density_peaks(flat, linesm), box=box)
    A['crop'] = crop; A['assign'] = assign; A['lineD2'] = lineD2; A['own'] = own; A['iassign'] = iassign
    A['lines'] = linesm
    return A


# ---------------------------------------------------------------- decisions
def dist(a, b): return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b))) / COLOURNORM
def lumi(c): return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
def chroma(c): return (max(c) - min(c)) / 255
def cmedian(cols):
    out = []
    for ch in range(3):
        v = sorted(c[ch] for c in cols); m = len(v) // 2
        out.append(v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2)
    return out


def valid(c): return c['count'] >= 4


def cand_features(A, j, consensus):
    cl = A['clusters']; c = cl[j]; font = A['font']
    ids = [i for i in range(len(cl)) if valid(cl[i])]
    big = [i for i in ids if cl[i]['inLines'] >= 0.08]
    pool = big if big else ids
    maxD = max((cl[i]['exteriorDistance'] for i in pool), default=0)
    plain = [i for i in ids if i < K]
    bgj = None
    if plain:
        bgj = plain[0]
        for i in plain:
            if cl[i]['inRing'] > cl[bgj]['inRing']: bgj = i
    lums = [lumi(q['core']) for q in cl]
    colour = c['core']; lum = lums[j]
    fM, fR = c['inLines'], c['inRing']
    if bgj is None: bgj = j
    d = bgj
    if c['neighbours'] and max(c['neighbours']) > 0: d = c['neighbours'].index(max(c['neighbours']))
    dc = cl[d] if valid(cl[d]) else cl[bgj]
    cnt = float(len(ids))
    darker = sum(lums[i] < lum for i in ids); nearer = sum(cl[i]['exteriorDistance'] < c['exteriorDistance'] for i in ids)
    x = [c['exterior'], math.log((fM + 0.01) / (fR + 0.01)), fM, fR, lum / 255,
         dist(colour, A['ringBackground']), c['neighbourPurity'], c['strokeWidth'] / font, chroma(colour),
         1 if lum > 200 else 0, c['exteriorDistance'] / font, c['coreCount'] / max(1, c['count']),
         c['shellExterior'], 1 if (c['exteriorDistance'] >= maxD and j in pool) else 0,
         dist(colour, consensus) if consensus is not None else 0, 1 if c['enclosed'] else 0, 1 if c['interior'] else 0,
         darker / cnt, nearer / cnt,
         dc['exterior'], cl[d]['inRing'], dc['exteriorDistance'] / font, dist(colour, dc['core']),
         (lum - lumi(dc['core'])) / 255, dist(colour, cl[bgj]['core']), (lum - lums[bgj]) / 255,
         0 if consensus is None else 1]
    i, nearest_ = -1, 0.0
    for o in ids:
        if o == j: continue
        v = dist(colour, cl[o]['core'])
        if i < 0 or v < nearest_: i, nearest_ = o, v
    if i >= 0:
        x += [nearest_, fR - cl[i]['inRing'], (c['exteriorDistance'] - cl[i]['exteriorDistance']) / font,
              1 if (cl[i]['interior'] or cl[i]['enclosed']) else 0, fM - cl[i]['inLines']]
    else:
        x += [1, 0, 0, 0, 0]
    return x


def cand_matrix(A, consensus):
    ids = [j for j in range(len(A['clusters'])) if valid(A['clusters'][j])]
    return ids, np.array([cand_features(A, j, consensus) for j in ids]) if ids else np.zeros((0, 32))


def scored_pick(A, forest, consensus):
    ids, X = cand_matrix(A, consensus)
    if not ids: return None
    z = forest.logits(X); b = int(np.argmax(z))  # first max, like Swift's strict >
    zs = np.sort(z); A['_pm'] = float(zs[-1] - zs[-2]) if len(zs) > 1 else 9.0
    return ids[b], float(z[b])


def halo(c, far, fill):
    v = [c[i] - far[i] for i in range(3)]; u = [far[i] - fill[i] for i in range(3)]
    nrm = math.sqrt(sum(t * t for t in u))
    if nrm > 1e-9:
        u = [t / nrm for t in u]; p = sum(v[i] * u[i] for i in range(3))
        if p < 0: v = [v[i] - p * u[i] for i in range(3)]
    return math.sqrt(sum(t * t for t in v)) / COLOURNORM


def outline_obs(A, j, profile, background):
    rings = [r for r in profile if r is not None]
    if not rings: return None
    far = rings[-1]; fill = A['clusters'][j]['core']; font = A['font']
    limit = max(3, 0.22 * font)
    nr = [r for r in rings if 1.5 <= r['distance'] <= limit]
    near = nr if nr else [rings[0]]
    pi, ps = 0, -math.inf
    for k, r in enumerate(near):
        sc = halo(r['median'], far['median'], fill)
        if sc > ps: pi, ps = k, sc
    peak = near[pi]; colour = peak['median']; step = ps
    width, seen = 0.0, False
    for r in rings:
        if r['distance'] == peak['distance']: seen = True
        if seen:
            if dist(r['median'], colour) > 0.5 * step: break
            width = r['distance']
    x = [step, dist(colour, fill), dist(far['median'], fill), peak['mad'] / 441, far['mad'] / 441,
         lumi(colour) / 255, lumi(fill) / 255, A['clusters'][j]['inRing'], dist(colour, background),
         1 if lumi(colour) > 200 else 0, width / font, math.log1p(step * 441), math.log1p(step * 441 / (1 + far['mad'] + peak['mad'])),
         chroma(fill), chroma(colour), font / 100]
    return dict(features=x, colour=colour, ringWidth=width)


def peak_features(A, pick, pick_logit, outline):
    ring = A['ringBackground']; cols = [pick] + [m['rgb'] for m in A['modes']]
    shares = [m['share'] for m in A['modes']]
    def lc(c):
        l = lab(c); return float(l[0]), float(math.sqrt(l[1] ** 2 + l[2] ** 2))
    lp, cp = lc(pick)
    X = []
    for i, col in enumerate(cols):
        l, c = lc(col); share = 0 if i == 0 else shares[i - 1]
        rank = -1 if i == 0 else float(shares.index(share))
        X.append([1 if i == 0 else 0, share, rank, dE(col, pick), dE(col, ring), dE(col, outline), l, c, l - lp, c - cp,
                  dE(pick, ring), dE(pick, outline), pick_logit, A['font'] / 100, float(len(A['modes'])),
                  dE(col, ring) - dE(pick, ring)])
    return cols, np.array(X)


def rgb8(c): return tuple(int(max(0, min(255, round(v)))) for v in c)  # Python round = half to even


def profile(A, j):
    P = A.setdefault('profiles', {})
    if j not in P: P[j] = ring_profile(A, j)
    return P[j]


def axis_features(A, cols, X, ocol, j):
    """The 10 axisFeatures appended to the 16 peakFeatures (26 ranker inputs): position along the outline -> pick
    axis in Lab, distance off it, axis length, lightness / chroma gaps, pick thinness, in-lines share, core share,
    crop scale."""
    P = lab(list(cols[0])); Oc = lab(list(ocol)); ax = P - Oc; n2 = float(ax @ ax) + 1e-6
    c = A['clusters'][j]; f = A['font']
    rows = []
    for col in cols:
        Q = lab(list(col)); t = float((Q - Oc) @ ax) / n2
        perp = float(np.linalg.norm(Q - Oc - t * ax))
        rows.append([t, perp, math.sqrt(n2), abs(Q[0] - Oc[0]), Q[0] - P[0],
                     math.hypot(Q[1], Q[2]) - math.hypot(Oc[1], Oc[2]),
                     c['strokeWidth'] / f, c['inLines'], c['coreCount'] / max(1, c['count']), A['scale']])
    return np.hstack([X, np.array(rows)])


def tree_score(trees, x):
    """PipelineFillPeakRanker.score: flat trees, `x[f] <= t` left, negative child = leaf -child-1 (doubles)."""
    s = 0.0
    for t in trees:
        n = 0
        while n >= 0: n = t['l'][n] if x[t['f'][n]] <= t['t'][n] else t['r'][n]
        s += t['v'][-n - 1]
    return s


def flat_ranker(trees):
    """-> option picker for decide(): the first option with the highest flat-tree score (Swift's strict >)."""
    def pick(A, cols, X, ocol, j):
        F = axis_features(A, cols, X, ocol, j)
        best, bs = 0, -math.inf
        for i, x in enumerate(F):
            v = tree_score(trees, x)
            if v > bs: best, bs = i, v
        return best
    return pick


def decide(analyses, fonts, W, ranker=None):
    """Per block dict(fill, stroke, width, pick, ...). W: fillPass1 / fillPass2 / outline forests. ranker(A, cols, X,
    ocol, j) -> option index (None keeps the pass-2 pick); the peak options are kept for ranker training."""
    picks = []
    for A in analyses:
        if A is None: continue
        r = scored_pick(A, W['fillPass1'], None)
        if r: picks.append(A['clusters'][r[0]]['core'])
    consensus = cmedian(picks) if picks else None
    res = [dict(font=f, fill=(0, 0, 0), stroke=None, width=0.0) for f in fonts]
    obs = [None] * len(analyses); scores = [None] * len(analyses)
    for k, A in enumerate(analyses):
        if A is None: continue
        A['consensus'] = consensus
        r = scored_pick(A, W['fillPass2'], consensus)
        if r is None: continue
        j, pl = r
        prof = profile(A, j)
        rings = [q for q in prof if q is not None]
        bg = A['ringBackground'] if not rings else cmedian([q['median'] for q in rings[-3:]])
        bg = [float(np.round(v)) for v in bg]
        res[k]['fill'] = rgb8(A['clusters'][j]['core']); res[k]['pick'] = j; res[k]['pickLogit'] = pl
        o = outline_obs(A, j, prof, bg)
        if o:
            obs[k] = o; scores[k] = float(W['outline'].logits(o['features'])[0])
        if A['modes']:
            ocol = o['colour'] if o else A['ringBackground']
            cols, X = peak_features(A, A['clusters'][j]['core'], pl, ocol)
            res[k]['ocol'] = ocol; res[k]['peakcols'] = cols; res[k]['peakX'] = X
            if ranker is not None:
                b = ranker(A, cols, X, ocol, j)
                res[k]['fill'] = rgb8(cols[b]); res[k]['peak'] = b
    pres = [s for s in scores if s is not None]
    if not pres: return res
    ps = sorted(pres); m = len(ps) // 2
    page = ps[m] if len(ps) % 2 else (ps[m - 1] + ps[m]) / 2
    for k in range(len(analyses)):
        if scores[k] is None or obs[k] is None: continue
        z = OUTLINE_PAGE[0] * scores[k] + OUTLINE_PAGE[1] * page + OUTLINE_PAGE[2]
        if z >= 0:
            res[k]['stroke'] = rgb8(obs[k]['colour'])
            res[k]['width'] = max(0.0, W_RING * obs[k]['ringWidth'] + W_FONT * fonts[k] + W_BIAS)
    return res


def _de8(a, b): return dE(list(a), list(b))


def sdist(a, b):
    d = _de8(a['fill'], b['fill'])
    if a['stroke'] is not None and b['stroke'] is not None: d = max(d, 0.5 * _de8(a['stroke'], b['stroke']))
    elif (a['stroke'] is None) != (b['stroke'] is None): d = max(d, 40.0)
    return d


def unify(styles, chars, T=15.0):
    """PipelineStyleConsistency.unify: complete linkage at T over blocks with >= 4 characters; medoid fill,
    majority outline, medoid stroke, median width per font px."""
    idx = [i for i in range(len(styles)) if chars[i] >= 4]
    out = [dict(s) for s in styles]
    S = [styles[i] for i in idx]; n = len(S)
    if n < 2: return out
    D = np.zeros((n, n))
    for a in range(n):
        for b in range(a + 1, n): D[a, b] = D[b, a] = sdist(S[a], S[b])
    groups = [[i] for i in range(n)]
    while True:
        best, pair = math.inf, None
        for a in range(len(groups)):
            for b in range(a + 1, len(groups)):
                link = max(D[i, j] for i in groups[a] for j in groups[b])
                if link <= T and link < best: best, pair = link, (a, b)
        if pair is None: break
        a, b = pair; groups[a] += groups[b]; del groups[b]
    for g in groups:
        if len(g) < 2: continue
        med, bt = g[0], math.inf
        for i in g:
            t = sum(D[i, j] for j in g)
            if t < bt: bt, med = t, i
        outl = [i for i in g if S[i]['stroke'] is not None]
        sm, bs = None, math.inf
        for i in outl:
            t = sum(_de8(S[i]['stroke'], S[j]['stroke']) for j in outl)
            if t < bs: bs, sm = t, i
        outline = 2 * len(outl) >= len(g)
        ratios = sorted(S[i]['width'] / max(1, S[i]['font']) for i in outl)
        ratio = 0.0
        if ratios:
            m = len(ratios) // 2; ratio = ratios[m] if len(ratios) % 2 else (ratios[m - 1] + ratios[m]) / 2
        for i in g:
            o = out[idx[i]]; o['fill'] = S[med]['fill']
            if outline and sm is not None: o['stroke'] = S[sm]['stroke']; o['width'] = ratio * S[i]['font']
            else: o['stroke'] = None; o['width'] = 0.0
    return out
