"""S4b model features and decision, the Python reference of PipelineInterior.swift: the grow rule (rule.py) + one
component pass (14 em window, open components retried with the ink closed by 2 cells, clipped to the RF box or
text +-3 em) + side profiles, a joint side model and a balloon/free gate. Everything in raster cells; rounding as
Swift `.rounded()`.

Set semantics use scipy (4-connected label / fill / cross dilation), order-dependent steps are defined here:
Voronoi owner = nearest member text box (squared cell distance), ties to the earlier member (the block first);
largest rectangle = gt.max_rect scan order.
"""
import math
import numpy as np
from scipy import ndimage
import rule as I
from gt import max_rect

WIN, REACH, CLOSE, D_EM = 14, 3, 2, 20
PATHS = ['none', 'toned', 'open', 'open-rf', 'enclosed', 'toned-rf', 'closed']
MISSING = -100.0
CROSS = ndimage.generate_binary_structure(2, 1)


def rnd(x):
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def to_cells(C, box):
    if box is None: return None
    return (rnd(box[0] * C.sx), rnd(box[1] * C.sy), rnd(box[2] * C.sx), rnd(box[3] * C.sy))


def paper_level(R, s):
    sub = R[s[1]:s[3], s[0]:s[2]].astype(np.int64)
    bands = np.bincount((sub >> 4).ravel(), minlength=16)
    sums = np.bincount((sub >> 4).ravel(), weights=sub.ravel(), minlength=16)
    band = int(np.argmax(bands))
    paper = int(sums[band]) // int(bands[band]) if bands[band] else 255
    return paper, bool(bands[band] == 0 or 96 < paper < 160)


def em_cells(b, C):
    th = sorted((l[2] - l[0]) if b['vertical'] else (l[3] - l[1]) for l in b['lines'])
    em = th[len(th) // 2]
    return em, max(1, math.ceil(em * C.sx))


def own_dirty(R, Wb, paper, b, C, e):
    sub = R[Wb[1]:Wb[3], Wb[0]:Wb[2]].astype(np.int64)
    dirty = np.abs(sub - paper) > 64
    pad = max(2, rnd(e * 0.2))
    for l in b['lines']:
        c = C.cells(l)
        if c is None: continue
        y0, y1 = max(0, c[1] - pad - Wb[1]), max(0, c[3] + pad - Wb[1])
        x0, x1 = max(0, c[0] - pad - Wb[0]), max(0, c[2] + pad - Wb[0])
        dirty[y0:y1, x0:x1] = False
    return dirty


def flood(free, s0):
    """Cells of `free` 4-connected to the free cells inside box s0 (window coords, clipped)."""
    lab, _ = ndimage.label(free, structure=CROSS)
    ids = np.unique(lab[s0[1]:s0[3], s0[0]:s0[2]]); ids = ids[ids > 0]
    return np.isin(lab, ids) if len(ids) else None


def border(m):
    return bool(m[0].any() or m[-1].any() or m[:, 0].any() or m[:, -1].any())


def component(i, blocks, cells, R, C, panel):
    """-> (comp box cells or None, path, comp_c2 box, path2, (x0, y0, mask) or None)."""
    b = blocks[i]; s = cells[i]
    _, e = em_cells(b, C)
    paper, toned = paper_level(R, s)
    W = [max(0, s[0] - WIN * e), max(0, s[1] - WIN * e), min(C.w, s[2] + WIN * e), min(C.h, s[3] + WIN * e)]
    pc = C.cells(panel) if panel is not None else None
    if pc:
        W = [max(W[0], pc[0]), max(W[1], pc[1]), min(W[2], pc[2]), min(W[3], pc[3])]
    if W[0] >= W[2] or W[1] >= W[3]:
        return None, 'none', None, 'none', None
    dirty = own_dirty(R, W, paper, b, C, e)
    s0 = (max(0, s[0] - W[0]), max(0, s[1] - W[1]), min(W[2], s[2]) - W[0], min(W[3], s[3]) - W[1])
    if s0[0] >= s0[2] or s0[1] >= s0[3]:
        return None, 'none', None, 'none', None
    comp = flood(~dirty, s0)
    if comp is None:
        return None, 'none', None, 'none', None
    touches = border(comp)
    path = 'toned' if toned else ('open' if touches else 'enclosed')
    variants = [(comp, touches, path)]
    if touches:
        dd = ndimage.binary_dilation(dirty, structure=CROSS, iterations=CLOSE)
        c2 = flood(~dd, s0)
        if c2 is not None:
            c2 = ndimage.binary_dilation(c2, structure=CROSS, iterations=CLOSE) & ~dirty
            if not border(c2):
                variants.append((c2, False, 'toned' if toned else 'closed'))
    if len(variants) == 1:
        variants.append(variants[0])
    out = []
    for m, t, pth in variants:
        m = m.copy()
        if t:
            if b.get('balloon') is not None:
                clip = C.cells(b['balloon']); pth += '-rf'
            else:
                clip = (s[0] - REACH * e, s[1] - REACH * e, s[2] + REACH * e, s[3] + REACH * e)
            keep = np.zeros(m.shape, bool)
            if clip is not None:
                keep[max(0, clip[1] - W[1]):max(0, clip[3] - W[1]), max(0, clip[0] - W[0]):max(0, clip[2] - W[0])] = True
            m &= keep
        m = ndimage.binary_fill_holes(m, structure=CROSS)
        m[s0[1]:s0[3], s0[0]:s0[2]] = True
        m = voronoi(m, i, cells, W, s0)
        r = max_rect(m)
        box = (min(r[0] + W[0], s[0]), min(r[1] + W[1], s[1]), max(r[2] + W[0], s[2]), max(r[3] + W[1], s[3]))
        out.append((box, pth, (W[0], W[1], m)))
    return out[0][0], out[0][1], out[1][0], out[1][1], out[0][2]


def voronoi(m, i, cells, W, s0):
    mem = [i]
    for j, c in enumerate(cells):
        if j == i or c is None: continue
        x0, y0 = max(c[0] - W[0], 0), max(c[1] - W[1], 0)
        x1, y1 = min(c[2] - W[0], m.shape[1]), min(c[3] - W[1], m.shape[0])
        if x0 < x1 and y0 < y1 and 2 * int(m[y0:y1, x0:x1].sum()) >= (c[2] - c[0]) * (c[3] - c[1]):
            mem.append(j)
    if len(mem) == 1:
        return m
    yy, xx = np.mgrid[0:m.shape[0], 0:m.shape[1]]
    best = None; owner = None
    for k, j in enumerate(mem):
        c = cells[j]
        dx = np.maximum(np.maximum(c[0] - W[0] - xx, 0), xx - (c[2] - 1 - W[0]))
        dy = np.maximum(np.maximum(c[1] - W[1] - yy, 0), yy - (c[3] - 1 - W[1]))
        d = dx * dx + dy * dy
        if best is None:
            best, owner = d, np.zeros(m.shape, np.int32)
        else:
            closer = d < best; best = np.where(closer, d, best); owner = np.where(closer, k, owner)
    m = m & (owner == 0)
    m[s0[1]:s0[3], s0[0]:s0[2]] = True
    return m


def first(prof, th):
    k = np.nonzero(prof > th)[0]
    return float(k[0]) if len(k) else float(len(prof))


def side_feats(R, C, b, k, cells, panel_cells, paper, ef):
    """Per side (left, right, top, bottom): first distance (em) where the strip's ink share passes
    0.05/0.2/0.5/0.9, first other-text contact, distance to the panel (or raster) edge, ink share over the
    first 1/2/4 em. Strips span the text box, outward to text +-20 em (raster-clipped)."""
    s = cells[k]
    Wd = int(D_EM * ef)
    Wb = (max(0, s[0] - Wd), max(0, s[1] - Wd), min(C.w, s[2] + Wd), min(C.h, s[3] + Wd))
    dirty = own_dirty(R, Wb, paper, b, C, ef)
    other = np.zeros(dirty.shape, bool)
    for j, c in enumerate(cells):
        if j != k and c is not None:
            other[max(0, c[1] - Wb[1]):max(0, c[3] - Wb[1]), max(0, c[0] - Wb[0]):max(0, c[2] - Wb[0])] = True
    clip = panel_cells or (0, 0, C.w, C.h)
    x0, y0, x1, y1 = s[0] - Wb[0], s[1] - Wb[1], s[2] - Wb[0], s[3] - Wb[1]
    h, w = dirty.shape
    out = []
    for side in range(4):
        if side == 0:
            D = dirty[y0:y1, :x0][:, ::-1]; O = other[y0:y1, :x0][:, ::-1]; ax = 0; edge = s[0] - clip[0]
        elif side == 1:
            D = dirty[y0:y1, x1:]; O = other[y0:y1, x1:]; ax = 0; edge = clip[2] - s[2]
        elif side == 2:
            D = dirty[:y0, x0:x1][::-1]; O = other[:y0, x0:x1][::-1]; ax = 1; edge = s[1] - clip[1]
        else:
            D = dirty[y1:, x0:x1]; O = other[y1:, x0:x1]; ax = 1; edge = clip[3] - s[3]
        span = D.shape[ax] if D.size else 0
        cnt = D.sum(ax).astype(np.int64) if D.size else np.zeros(0, np.int64)
        prof = cnt / span if span else np.zeros(0)
        op = O.sum(ax) / span if O.size else np.zeros(0)
        f = [first(prof, t) / ef for t in (0.05, 0.2, 0.5, 0.9)] + [first(op, 0.0) / ef, edge / ef]
        for kk in (1, 2, 4):
            n = min(max(1, int(kk * ef)), len(prof))
            f.append(int(cnt[:n].sum()) / (n * span) if len(prof) else 1.0)
        out.append(f)
    return out


def offsets(c, s, e):
    if c is None:
        return [MISSING] * 4
    return [(s[0] - c[0]) / e, (c[2] - s[2]) / e, (s[1] - c[1]) / e, (c[3] - s[3]) / e]


NAMES = ('comp', 'comp_c2', 'app', 'rfin', 'rf')


def items(p, blocks, R):
    """Per block (None for background / no lines): dict of features, candidate boxes and the component mask."""
    C = I.Ctx(R, p['W'], p['H'])
    base = I.apply(blocks, R, p['W'], p['H'], p['layout'], I.DEFAULT)
    cells = [C.cells(b['bounds']) if b['role'] != 'background' else None for b in blocks]
    out = []
    for k, b in enumerate(blocks):
        s = cells[k]
        if s is None or not b['lines']:
            out.append(None); continue
        appb, info = base[k]
        panel = info.get('panel')
        boxes = dict(app=to_cells(C, appb), rf=C.cells(b['balloon']) if b.get('balloon') else None)
        bal = b.get('balloon')
        if bal is not None:
            q = (1 - 0.7071) / 2; dx, dy = (bal[2] - bal[0]) * q, (bal[3] - bal[1]) * q
            boxes['rfin'] = to_cells(C, I.union([bal[0] + dx, bal[1] + dy, bal[2] - dx, bal[3] - dy], b['bounds']))
        else:
            boxes['rfin'] = None
        cb, path, c2b, path2, mask = component(k, blocks, cells, R, C, panel)
        boxes['comp'] = cb if cb is not None else boxes['app']
        boxes['comp_c2'] = c2b if c2b is not None else boxes['app']
        em, _ = em_cells(b, C)
        ef = max(1.0, em * C.sx)
        paper, toned = paper_level(R, s)
        pc = C.cells(panel) if panel is not None else None
        sf = side_feats(R, C, b, k, cells, pc, paper, ef)
        g = [(s[2] - s[0]) / ef, (s[3] - s[1]) / ef, float(b['vertical']), float(len(b['lines'])), float(toned),
             float(boxes['rf'] is not None), float(PATHS.index(path)), float(PATHS.index(path2))]
        off = {n: offsets(boxes[n], s, ef) for n in NAMES}
        out.append(dict(src=s, e=ef, g=g, sf=sf, off=off, boxes=boxes, path=path, mask=mask,
                        app_rows=info.get('rowspans'), sx=C.sx, sy=C.sy, rw=C.w, rh=C.h))
    return out


def joint_x(r, q):
    order = [q] + [t for t in range(4) if t != q]
    f = [float(q)] + list(r['g'])
    for t in order: f += r['sf'][t]
    for n in NAMES:
        o = r['off'][n]; f += [o[t] for t in order]
    return f


def gate_x(r):
    f = list(r['g'])
    for t in range(4): f += r['sf'][t]
    for n in ('comp', 'app', 'rfin', 'rf'): f += r['off'][n]
    return f


def box_from(r, o):
    s, e = r['src'], r['e']
    o = [max(0.0, v) for v in o]
    w, h = r['rw'], r['rh']
    return (max(0, rnd(s[0] - o[0] * e)), max(0, rnd(s[1] - o[2] * e)), min(w, rnd(s[2] + o[1] * e)), min(h, rnd(s[3] + o[3] * e)))


def rows_from(r, box):
    """Row spans of the component through the box centre (S4b `rows` for a model box): per row the centred clean
    half-width minus one cell, contiguous rows around the centre row, kept when some row is wider than the box."""
    if r['mask'] is None:
        return None
    x0, y0, m = r['mask']
    cx = (box[0] + box[2]) // 2 - x0; cy = (box[1] + box[3]) // 2 - y0
    h, w = m.shape
    if not (0 <= cx < w and 0 <= cy < h):
        return None

    def half(y):
        row = m[y]
        if not row[cx]: return 0
        l = rr = cx
        while l - 1 >= 0 and row[l - 1]: l -= 1
        while rr + 1 < w and row[rr + 1]: rr += 1
        return max(0, min(cx - l, rr - cx) - 1)
    halves = [half(cy)]
    if halves[0] <= 0:
        return None
    top = bottom = cy
    while top - 1 >= 0:
        v = half(top - 1)
        if v <= 0: break
        halves.insert(0, v); top -= 1
    while bottom + 1 < h:
        v = half(bottom + 1)
        if v <= 0: break
        halves.append(v); bottom += 1
    if max(halves) <= (box[2] - box[0]) // 2 + 1:
        return None
    sx, sy = r['sx'], r['sy']
    return dict(top=(top + y0) / sy, step=1 / sy, centre=(cx + x0 + 0.5) / sx, halfWidths=[v / sx for v in halves])


def tree_sum(trees, x):
    tot = 0.0
    for t in trees:
        n = 0
        while n >= 0:
            n = t['l'][n] if x[t['f'][n]] <= t['t'][n] else t['r'][n]
        tot += t['v'][-n - 1]
    return tot


def decide(r, model):
    """-> (balloon cells, rows dict or None, gated in?)."""
    z = tree_sum(model['gate']['trees'], gate_x(r))
    pb = 1 / (1 + math.exp(-z))
    if pb < model['threshold']:
        return r['boxes']['app'], r['app_rows'], False
    o = [tree_sum(model['joint']['trees'], joint_x(r, q)) for q in range(4)]
    box = box_from(r, o)
    return box, rows_from(r, box), True
