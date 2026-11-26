"""Python port of the S4b grow rule in PipelineInterior.swift (the `app` box and its rows; the model falls back to
it below the gate threshold), boxes as [x0, y0, x1, y1] in page pixels.

apply(blocks, raster, W, H, layout, P) -> list of (balloon box or None, info) per block.
blocks: dicts with role, bounds, lines (boxes), vertical, balloon (S4 enclosing RF balloon or None).
"""
import math
import numpy as np

DEFAULT = dict(hreach=8.0, vreach=3.0, frame_score=0.7, balloon_floor=0.4, ink=64, base_h=3.0, base_v=1.5,
               step_h=1.0, step_v=0.5, steps=6, collision=0.02, edge_share=0.03, edge_guard=3, lobe_share=0.6,
               frame_hold=0.95, inscribed=0.7071, use_lobe=True, use_rf=True)


def area(r):
    return max(0, r[2] - r[0]) * max(0, r[3] - r[1])


def overlap(r, o):
    return max(0, min(r[2], o[2]) - max(r[0], o[0])) * max(0, min(r[3], o[3]) - max(r[1], o[1]))


def inter(a, b):
    """CGRect.intersects: the intersection is not null (touching counts)."""
    return max(a[0], b[0]) <= min(a[2], b[2]) and max(a[1], b[1]) <= min(a[3], b[3])


def union(a, b):
    return [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]


class Ctx:
    def __init__(self, raster, W, H):
        self.r = raster; self.h, self.w = raster.shape
        self.sx = self.w / W; self.sy = self.h / H

    def cells(self, rect):
        if rect is None or rect[2] <= rect[0] or rect[3] <= rect[1]:
            return None
        x0 = max(0, math.floor(rect[0] * self.sx)); x1 = min(self.w, math.ceil(rect[2] * self.sx))
        y0 = max(0, math.floor(rect[1] * self.sy)); y1 = min(self.h, math.ceil(rect[3] * self.sy))
        return (x0, y0, x1, y1) if x0 < x1 and y0 < y1 else None

    def page(self, c):
        return [c[0] / self.sx, c[1] / self.sy, c[2] / self.sx, c[3] / self.sy]


def limit_bounds(b, layout, P):
    a = area(b['bounds'])
    if a <= 0:
        return None
    c = [r['box'] for r in layout if r['kind'] == 'frame' and r['score'] >= P['frame_score']
         and inter(r['box'], b['bounds']) and overlap(r['box'], b['bounds']) >= a * P['frame_hold']]
    return min(c, key=area) if c else None


def avoided(b, layout, P):
    cx = (b['bounds'][0] + b['bounds'][2]) / 2; cy = (b['bounds'][1] + b['bounds'][3]) / 2
    return [r['box'] for r in layout if r['kind'] == 'balloon' and r['score'] >= P['balloon_floor']
            and not (r['box'][0] <= cx < r['box'][2] and r['box'][1] <= cy < r['box'][3])]


def enclosing_balloon(bounds, layout, P):
    a = area(bounds)
    if a <= 0:
        return None
    c = [r['box'] for r in layout if r['kind'] == 'balloon' and r['score'] >= P['balloon_floor']
         and inter(r['box'], bounds) and overlap(r['box'], bounds) >= a / 2]
    return min(c, key=area) if c else None


def apply(blocks, raster, W, H, layout, P=DEFAULT):
    C = Ctx(raster, W, H)
    text = [C.cells(b['bounds']) if b['role'] != 'background' else None for b in blocks]
    out = []
    for i, b in enumerate(blocks):
        panel = limit_bounds(b, layout, P)
        start = C.cells(b['bounds'])
        if b['role'] == 'background' or start is None:
            out.append((b.get('balloon'), dict(panel=panel)))
            continue
        others = [text[j] for j in range(len(blocks)) if j != i and text[j] is not None]
        cand = []; info = dict(panel=panel)
        g = grow(b, start, C, panel, avoided(b, layout, P), others, P, info)
        if g is not None:
            cand.append(C.page(g))
        bal = b.get('balloon')
        if P['use_rf'] and bal is not None and not any(j != i and blocks[j]['role'] != 'background' and inter(blocks[j]['bounds'], bal)
                                     for j in range(len(blocks))):
            k = (1 - P['inscribed']) / 2
            dx, dy = (bal[2] - bal[0]) * k, (bal[3] - bal[1]) * k
            cand.append([bal[0] + dx, bal[1] + dy, bal[2] - dx, bal[3] - dy])
        if not cand:
            out.append((bal, info)); continue
        cu = [union(c, b['bounds']) for c in cand]
        best = max(range(len(cu)), key=lambda k: (area(cu[k]), -k))
        info['source'] = 'grow' if (g is not None and best == 0) else 'rf'
        # Swift: rows kept when the grown candidate's union equals the chosen box
        if g is not None and cu[0] == cu[best] and 'rows' in info:
            t, c, hv = info['rows']
            info['rowspans'] = dict(top=t / C.sy, step=1 / C.sy, centre=(c + 0.5) / C.sx, halfWidths=[v / C.sx for v in hv])
        out.append((cu[best], info))
    return out


def grow(b, start, C, panel, avoid, others, P, info):
    w, h, R = C.w, C.h, C.r
    th = sorted((l[2] - l[0]) if b['vertical'] else (l[3] - l[1]) for l in b['lines'])
    em = th[len(th) // 2] if th else 0
    if em <= 0:
        return None
    unit = C.cells([0, 0, em, em])
    if unit is None:
        return None
    emX = max(1, unit[2] - unit[0]); emY = max(1, unit[3] - unit[1])
    lim = [max(0, start[0] - int(P['hreach'] * emX)), max(0, start[1] - int(P['vreach'] * emY)),
           min(w, start[2] + int(P['hreach'] * emX)), min(h, start[3] + int(P['vreach'] * emY))]
    for bound in (b.get('balloon'), panel):
        if bound is None:
            continue
        bx = C.cells(bound)
        if bx is None:
            continue
        lim = [max(lim[0], bx[0]), max(lim[1], bx[1]), min(lim[2], bx[2]), min(lim[3], bx[3])]
    base = [max(lim[0], start[0] - int(P['base_h'] * emX)), max(lim[1], start[1] - int(P['base_v'] * emY)),
            min(lim[2], start[2] + int(P['base_h'] * emX)), min(lim[3], start[3] + int(P['base_v'] * emY))]
    for o in others:
        if o[0] < base[2] and o[2] > base[0] and o[1] < base[3] and o[3] > base[1]:
            if o[0] >= start[2]: base[2] = min(base[2], o[0])
            elif o[2] <= start[0]: base[0] = max(base[0], o[2])
            elif o[1] >= start[3]: base[3] = min(base[3], o[1])
            elif o[3] <= start[1]: base[1] = max(base[1], o[3])
    sub = R[start[1]:start[3], start[0]:start[2]].astype(np.int64)
    bands = np.bincount((sub >> 4).ravel(), minlength=16); sums = np.bincount((sub >> 4).ravel(), weights=sub.ravel(), minlength=16)
    band = int(np.argmax(bands))
    paper = int(sums[band]) // int(bands[band]) if bands[band] > 0 else 255
    toned = bands[band] == 0 or (96 < paper < 160)
    blocked = [c for c in map(C.cells, avoid) if c is not None]
    pad = max(2, int(math.floor(emX * 0.2 + 0.5)))
    own = [(c[0] - pad, c[1] - pad, c[2] + pad, c[3] + pad) for c in map(C.cells, b['lines']) if c is not None]
    region = (min(lim[0], start[0]), min(lim[1], start[1]), max(lim[2], start[2]), max(lim[3], start[3]))
    if not toned:
        sr = R[region[1]:region[3], region[0]:region[2]].astype(np.int64)
        mask = np.abs(sr - paper) > P['ink']
        for bx in own:
            mask[max(bx[1], region[1]) - region[1]:max(0, min(bx[3], region[3]) - region[1]),
                 max(bx[0], region[0]) - region[0]:max(0, min(bx[2], region[2]) - region[0])] = False
        for bx in blocked:
            y0, y1 = max(bx[1], region[1]), min(bx[3], region[3]); x0, x1 = max(bx[0], region[0]), min(bx[2], region[2])
            if y0 < y1 and x0 < x1:
                mask[y0 - region[1]:y1 - region[1], x0 - region[0]:x1 - region[0]] = True
    info['paper'] = paper; info['toned'] = bool(toned); info['em'] = (emX, emY); info['limit'] = tuple(lim)

    def ink(s):
        return int(mask[s[1] - region[1]:s[3] - region[1], s[0] - region[0]:s[2] - region[0]].sum())
    best = list(base)
    for side in range(4):
        step = max(1, int(P['step_h'] * emX)) if side < 2 else max(1, int(P['step_v'] * emY))
        for _ in range(P['steps']):
            nx = list(best)
            if side == 0: nx[0] = max(lim[0], best[0] - step)
            elif side == 1: nx[2] = min(lim[2], best[2] + step)
            elif side == 2: nx[1] = max(lim[1], best[1] - step)
            else: nx[3] = min(lim[3], best[3] + step)
            strip = area(nx) - area(best)
            hit = sum(overlap(nx, o) - overlap(best, o) for o in others)
            if not (strip > 0 and hit <= strip * P['collision'] and not any(overlap(nx, o) > overlap(best, o) for o in blocked)):
                break
            if not toned and area(best) >= P['edge_guard'] * area(start):
                s = ((nx[0], nx[1], best[0], nx[3]), (best[2], nx[1], nx[2], nx[3]),
                     (nx[0], nx[1], nx[2], best[1]), (nx[0], best[3], nx[2], nx[3]))[side]
                if ink(s) > strip * P['edge_share']:
                    break
            best = nx
    if tuple(best) == tuple(start):
        return None
    info['grown'] = tuple(best)
    if toned or not P['use_lobe']:
        return tuple(best)
    lw, lh = lim[2] - lim[0], lim[3] - lim[1]
    box = tuple(best)
    if lw > 4 and lh > 4:
        inkm = mask[lim[1] - region[1]:lim[3] - region[1], lim[0] - region[0]:lim[2] - region[0]]
        lr = lobe_rect(tuple(lim), start, inkm)
        info['lobe'] = lr
        if lr is not None and area(lr) >= P['lobe_share'] * area(best):
            box = lr
    # Row spans (Swift `rows`): clean half-width about the source centre column, contiguous rows around the centre.
    def dirty(x, y):
        if region[0] <= x < region[2] and region[1] <= y < region[3]:
            return bool(mask[y - region[1], x - region[0]])
        if any(x >= bb[0] and x < bb[2] and y >= bb[1] and y < bb[3] for bb in blocked):
            return True
        if abs(int(R[y, x]) - paper) <= P['ink']:
            return False
        return not any(x >= o[0] and x < o[2] and y >= o[1] and y < o[3] for o in own)
    centre = (start[0] + start[2]) // 2; middle = (start[1] + start[3]) // 2

    def half(y):
        if dirty(centre, y):
            return 0
        l = r = centre
        while l - 1 >= lim[0] and not dirty(l - 1, y): l -= 1
        while r + 1 < lim[2] and not dirty(r + 1, y): r += 1
        return max(0, min(centre - l, r - centre) - 1)
    halves = [half(middle)]
    if halves[0] > 0:
        top = bottom = middle
        while top - 1 >= lim[1]:
            hh = half(top - 1)
            if hh <= 0: break
            halves.insert(0, hh); top -= 1
        while bottom + 1 < lim[3]:
            hh = half(bottom + 1)
            if hh <= 0: break
            halves.append(hh); bottom += 1
        if max(halves) > (best[2] - best[0]) // 2 + 1:
            info['rows'] = (top, centre, halves)
    return box


def lobe_rect(box, source, ink):
    """Port of lobeRect(_:source:ink:)."""
    w, h = box[2] - box[0], box[3] - box[1]
    if not (w > 4 and h > 4 and ink.shape == (h, w) and max(box[0], source[0]) < min(box[2], source[2])
            and max(box[1], source[1]) < min(box[3], source[3])):
        return None
    sx0 = max(box[0], source[0]) - box[0]; sx1 = min(box[2], source[2]) - box[0]
    sy0 = max(box[1], source[1]) - box[1]; sy1 = min(box[3], source[3]) - box[1]
    inkf = ink.ravel().tolist()
    m = [False] * (w * h); q = []
    for y in range(sy0, sy1):
        for x in range(sx0, sx1):
            if not inkf[y * w + x]:
                if x == 0 or x == w - 1 or y == 0 or y == h - 1:
                    return None
                m[y * w + x] = True; q.append(y * w + x)
    head = 0
    while head < len(q):
        cell = q[head]; x = cell % w; y = cell // w; head += 1
        if x > 0 and not m[cell - 1] and not inkf[cell - 1]:
            if x - 1 == 0 or y == 0 or y == h - 1: return None
            m[cell - 1] = True; q.append(cell - 1)
        if x + 1 < w and not m[cell + 1] and not inkf[cell + 1]:
            if x + 1 == w - 1 or y == 0 or y == h - 1: return None
            m[cell + 1] = True; q.append(cell + 1)
        if y > 0 and not m[cell - w] and not inkf[cell - w]:
            if y - 1 == 0 or x == 0 or x == w - 1: return None
            m[cell - w] = True; q.append(cell - w)
        if y + 1 < h and not m[cell + w] and not inkf[cell + w]:
            if y + 1 == h - 1 or x == 0 or x == w - 1: return None
            m[cell + w] = True; q.append(cell + w)
    if not q:
        return None
    qa = np.array(q); xs = qa % w; ys = qa // w
    ox, oy = int(xs.min()) - 1, int(ys.min()) - 1
    cw, ch = int(xs.max()) + 2 - ox, int(ys.max()) + 2 - oy
    paper = np.zeros((ch, cw), bool); paper[ys - oy, xs - ox] = True
    dist = chamfer(paper)
    peak = int(dist.max())
    if peak < 6:
        return None
    core = dist.astype(np.float64) >= peak * 0.32
    coreCount = int(core.sum())
    pf = paper.ravel().tolist(); cf = core.ravel().tolist(); cells = cw * ch
    label = [-1] * cells; seeds = 0
    for st in range(cells):
        if not (cf[st] and label[st] < 0):
            continue
        comp = [st]; label[st] = seeds; idx = 0
        while idx < len(comp):
            cell = comp[idx]; x = cell % cw; y = cell // cw; idx += 1
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if 0 <= x + dx < cw and 0 <= y + dy < ch:
                        nx = (y + dy) * cw + x + dx
                        if cf[nx] and label[nx] < 0:
                            label[nx] = seeds; comp.append(nx)
        if len(comp) >= max(4, coreCount * 3 // 100):
            seeds += 1
        else:
            for c in comp: label[c] = -2
    if seeds == 0:
        return None
    fr = []
    for c in range(cells):
        if label[c] >= 0: fr.append(c)
        else: label[c] = -1
    head = 0
    while head < len(fr):
        cell = fr[head]; x = cell % cw; y = cell // cw; head += 1
        own = label[cell]
        for nb, ok in ((cell - 1, x > 0), (cell + 1, x + 1 < cw), (cell - cw, y > 0), (cell + cw, y + 1 < ch)):
            if ok and pf[nb] and label[nb] < 0:
                label[nb] = own; fr.append(nb)
    L = np.array(label).reshape(ch, cw)
    cy0, cy1 = max(sy0 - oy, 0), min(sy1 - oy, ch); cx0, cx1 = max(sx0 - ox, 0), min(sx1 - ox, cw)
    cover = np.zeros(seeds, int)
    if cy0 < cy1 and cx0 < cx1:
        s = L[cy0:cy1, cx0:cx1]; s = s[s >= 0]
        cover += np.bincount(s, minlength=seeds)[:seeds]
    lobe = int(np.argmax(cover))
    if cover[lobe] < 0.7 * (source[2] - source[0]) * (source[3] - source[1]):
        return None
    left = [w] * h; right = [0] * h
    lys, lxs = np.nonzero(L == lobe)
    val = dist[lys, lxs].astype(np.float64) ** 2
    X = lxs + ox; Y = lys + oy
    for y in np.unique(Y):
        sel = Y == y
        left[y] = int(X[sel].min()); right[y] = int(X[sel].max()) + 1
    wt = val.sum(); cx = float((X * val).sum() / wt); cyv = float((Y * val).sum() / wt)
    rows = sorted(set([k * h // 48 for k in range(49)] + [int(math.floor(cyv + 0.5))]))
    best = None
    for i, a in enumerate(rows):
        if a > cyv:
            continue
        lo, hi, end = -10 ** 9, 10 ** 9, a
        for bb in rows[i + 1:]:
            while end < bb:
                lo = max(lo, left[end]); hi = min(hi, right[end]); end += 1
            if bb < cyv or hi <= lo:
                continue
            off = ((lo + hi) / 2 - cx) ** 2 + ((a + bb) / 2 - cyv) ** 2
            sc = (hi - lo) * (bb - a) / (1 + off / (w * h))
            if sc > (best[0] if best else 0):
                best = (sc, (lo + box[0], a + box[1], hi + box[0], bb + box[1]))
    if best is None:
        return None
    r = best[1]
    if min(r[2] - r[0], r[3] - r[1]) < 3:
        return None
    mx = (source[0] + source[2]) // 2; my = (source[1] + source[3]) // 2
    qx = (r[2] - r[0]) // 4; qy = (r[3] - r[1]) // 4
    if not (r[0] - qx <= mx <= r[2] + qx and r[1] - qy <= my <= r[3] + qy):
        return None
    return r


def chamfer(paper):
    """3-4 chamfer distance, the Swift two-pass order (rows in the crop, border cells capped at 3)."""
    ch, cw = paper.shape
    BIG = 1 << 40
    d = [[BIG if v else 0 for v in row] for row in paper.tolist()]
    for y in range(ch):
        row = d[y]; up = d[y - 1] if y > 0 else None
        for x in range(cw):
            if row[x] <= 0: continue
            best = 3 if (x == 0 or y == 0 or x == cw - 1 or y == ch - 1) else row[x]
            if up is not None:
                best = min(best, up[x] + 3)
                if x > 0: best = min(best, up[x - 1] + 4)
                if x + 1 < cw: best = min(best, up[x + 1] + 4)
            if x > 0: best = min(best, row[x - 1] + 3)
            row[x] = best
    for y in range(ch - 1, -1, -1):
        row = d[y]; dn = d[y + 1] if y + 1 < ch else None
        for x in range(cw - 1, -1, -1):
            if row[x] <= 0: continue
            best = 3 if (x == 0 or y == 0 or x == cw - 1 or y == ch - 1) else row[x]
            if dn is not None:
                best = min(best, dn[x] + 3)
                if x > 0: best = min(best, dn[x - 1] + 4)
                if x + 1 < cw: best = min(best, dn[x + 1] + 4)
            if x + 1 < cw: best = min(best, row[x + 1] + 3)
            row[x] = best
    return np.array(d, dtype=np.int64)
