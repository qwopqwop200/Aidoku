"""GT interiors, per-item targets and the S4b interior metric (raster cells).

masks(): per page, the GT balloon/narration interiors (`balloon_narration_instance_segmentation`) on the S4 raster
grid (BOX-averaged, > 0.5) as (x0, y0, x1, y1, bool crop). Cached under workspace.data('retrain', 'interior').
Each non-background item whose bounds lie >= 50% (in raster cells) in a GT interior is scored against it. Items
sharing a mask split it by nearest text box (Voronoi on the cells); the item's allowed region is its share of the
mask plus its own text box. Target T = largest axis-aligned rectangle inside the allowed region.
Metric per item: iou = IoU(pred, T) (primary); over5 = share of items > 5% outside the allowed region;
font_s50 = share of scored items whose usable area is < half the app rule's; free_s50 = share of free-text items
(no GT interior) whose box is < half the app rule's area.
"""
import collections, json, pickle
import numpy as np
from PIL import Image
from scipy import ndimage
import rule as I


def raster_size(W, H):
    s = min(1.0, 768 / max(W, H))
    return max(1, int(W * s)), max(1, int(H * s))


def _decode(seg):
    h, w = seg['size']
    counts = np.asarray(seg['counts'], dtype=np.int64)
    flat = np.repeat((np.arange(len(counts)) % 2).astype(np.uint8), counts)
    if flat.size < h * w:
        flat = np.concatenate([flat, np.zeros(h * w - flat.size, np.uint8)])
    return flat[:h * w].reshape((w, h)).T


def masks(gt_path, manifest, cache):
    """{page: [(x0, y0, x1, y1, crop)]} for the manifest pages; the cache is keyed by the GT file's size and mtime."""
    st = gt_path.stat(); key = (str(gt_path), st.st_size, st.st_mtime_ns)
    if cache.exists():
        d = pickle.load(open(cache, 'rb'))
        if d['key'] == key and set(manifest) <= set(d['masks']):
            return d['masks']
    segs = collections.defaultdict(list)
    for r in json.load(open(gt_path))['records']:
        if r['scope'] == 'balloon_narration_instance_segmentation':
            segs[r.get('page_id')].append(r['label']['segmentation'])
    out = {}
    for pid, m in manifest.items():
        W, H = int(m['width']), int(m['height']); rw, rh = raster_size(W, H)
        ms = []
        for seg in segs.get(pid, []):
            full = _decode(seg)
            if not full.any():
                continue
            sm = np.asarray(Image.fromarray(full * 255).resize((rw, rh), Image.BOX)) > 127
            ys, xs = np.nonzero(sm)
            if len(xs) == 0:
                continue
            x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
            ms.append((int(x0), int(y0), int(x1), int(y1), sm[y0:y1, x0:x1].copy()))
        out[pid] = ms
    pickle.dump(dict(key=key, masks=out), open(cache, 'wb'))
    return out


def max_rect(m):
    """Largest all-True axis-aligned rectangle (x0, y0, x1, y1) in a bool array (the Swift scan order)."""
    h, w = m.shape
    best = (0, (0, 0, 0, 0)); hts = np.zeros(w, np.int64)
    for y in range(h):
        hts = np.where(m[y], hts + 1, 0)
        H = hts.tolist(); st = []
        for x in range(w + 1):
            cur = H[x] if x < w else 0
            s = x
            while st and st[-1][1] >= cur:
                s, hh = st.pop()
                a = hh * (x - s)
                if a > best[0]:
                    best = (a, (s, y - hh + 1, x, y + 1))
            st.append((s, cur))
    return best[1]


def targets(C, masks_, blocks):
    """Per block: None or dict(allowed crop at (X0, Y0), T rect, src cells)."""
    area = I.area
    cells = [C.cells(b['bounds']) if b['role'] != 'background' else None for b in blocks]
    owner = [None] * len(blocks)
    for i, c in enumerate(cells):
        if c is None:
            continue
        best = (0.5, None)
        for k, (x0, y0, x1, y1, m) in enumerate(masks_):
            ix0, iy0, ix1, iy1 = max(c[0], x0), max(c[1], y0), min(c[2], x1), min(c[3], y1)
            if ix0 >= ix1 or iy0 >= iy1:
                continue
            cov = m[iy0 - y0:iy1 - y0, ix0 - x0:ix1 - x0].sum() / area(c)
            if cov >= best[0]:
                best = (cov, k)
        owner[i] = best[1]
    out = [None] * len(blocks)
    for k, (x0, y0, x1, y1, m) in enumerate(masks_):
        mem = [i for i in range(len(blocks)) if owner[i] == k]
        if not mem:
            continue
        X0 = min([x0] + [cells[i][0] for i in mem]); Y0 = min([y0] + [cells[i][1] for i in mem])
        X1 = max([x1] + [cells[i][2] for i in mem]); Y1 = max([y1] + [cells[i][3] for i in mem])
        full = np.zeros((Y1 - Y0, X1 - X0), bool); full[y0 - Y0:y1 - Y0, x0 - X0:x1 - X0] = m
        if len(mem) > 1:
            seed = np.zeros(full.shape, np.int32)
            for j, i in enumerate(mem):
                c = cells[i]; seed[c[1] - Y0:c[3] - Y0, c[0] - X0:c[2] - X0] = j + 1
            _, (iy, ix) = ndimage.distance_transform_edt(seed == 0, return_indices=True)
            lab = seed[iy, ix]
        for j, i in enumerate(mem):
            c = cells[i]
            allowed = full & (lab == j + 1) if len(mem) > 1 else full.copy()
            allowed[c[1] - Y0:c[3] - Y0, c[0] - X0:c[2] - X0] = True
            r = max_rect(allowed)
            out[i] = dict(X0=X0, Y0=Y0, allowed=allowed, T=(r[0] + X0, r[1] + Y0, r[2] + X0, r[3] + Y0), src=c)
    return out


def _inside(c, t):
    al = t['allowed']; X0, Y0 = t['X0'], t['Y0']
    ax0, ay0, ax1, ay1 = max(c[0] - X0, 0), max(c[1] - Y0, 0), min(c[2] - X0, al.shape[1]), min(c[3] - Y0, al.shape[0])
    return int(al[ay0:ay1, ax0:ax1].sum()) if ax0 < ax1 and ay0 < ay1 else 0


def metrics(rows, key):
    """rows: dicts with t (target or None), src, boxes {app, key}. -> iou, over5, font_s50, free_s50, n, free_n."""
    area = I.area
    iou, over5, shrink, free = [], [], [], []
    for r in rows:
        c = r['boxes'].get(key) or r['src']; app = r['boxes']['app'] or r['src']
        t = r['t']
        if t is None:
            free.append(area(c) / max(1, area(app))); continue
        T = t['T']
        it = max(0, min(c[2], T[2]) - max(c[0], T[0])) * max(0, min(c[3], T[3]) - max(c[1], T[1]))
        iou.append(it / max(1, area(c) + area(T) - it))
        over5.append(1 - _inside(c, t) / max(1, area(c)) > 0.05)
        shrink.append(_inside(c, t) / max(1, _inside(app, t)))
    free = np.array(free)
    return dict(iou=float(np.mean(iou)) if iou else float('nan'), over5=float(np.mean(over5)) if over5 else float('nan'),
                font_s50=float((np.array(shrink) < 0.5).mean()) if shrink else float('nan'),
                free_s50=float((free < 0.5).mean()) if len(free) else float('nan'), n=len(iou), free_n=len(free))
