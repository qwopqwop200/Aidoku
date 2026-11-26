"""GT-derived data for the typesetting scorer (typeset_score.py), cached under $AIDOKU_EVAL_DIR/typeset.

gt()            {page: regions (merged_bbox boxes), size (GT font size with its interval), classes (GT size classes),
                ink (source glyph mask bounds), look (fill / outline / background), weight (bold), balloon (the GT
                balloon a region sits in and the source ink's distance to its edge)}
balloons(page)  the page's GT balloons as (x0, y0, x1, y1, inside-distance map of that crop)
art(page, ...)  edge cells of the source page outside every GT text box (where painted text would cover art)

The font-size GT has its own region ids; its records are attached to merged regions by box overlap.
Numbers only: masks and the source page are read as arrays, never viewed.
"""
import collections, json, pickle, sys, os
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))  # tools dir
import workspace as ws  # noqa: E402

ART_SIDE, ART_GRADIENT = 768, 48   # as place_metrics.py
GT_CACHE = 2                       # bump when gt() changes what it stores
_gt = None
_balloons = {}
_art = {}


# ---------- GT ----------

def _decode(seg):
    h, w = seg['size']
    flat = np.zeros(h * w, dtype=np.uint8)
    pos, val = 0, 0
    for c in seg['counts']:
        if val:
            flat[pos:pos + c] = 1
        pos += c
        val ^= 1
    return flat.reshape((w, h)).T  # column-major


def _edge(dist, box):
    """Smallest value of the distance map `dist` (whole-crop coordinates) on the border of `box`; 0 off the map."""
    h, w = dist.shape
    x0, y0, x1, y1 = (int(round(v)) for v in box)
    if x0 < 0 or y0 < 0 or x1 > w or y1 > h or x1 - x0 < 1 or y1 - y0 < 1:
        return 0.0
    x1 -= 1; y1 -= 1
    return float(min(dist[y0, x0:x1 + 1].min(), dist[y1, x0:x1 + 1].min(), dist[y0:y1 + 1, x0].min(), dist[y0:y1 + 1, x1].min()))


def gt():
    """Per page: regions, sizes, size classes, source ink boxes, appearance, weight, each region's balloon and
    source margin. Cached per GT file version; balloon distance maps are stored per page beside it."""
    global _gt
    if _gt is not None:
        return _gt
    st = os.stat(ws.GT)
    key = (str(ws.GT), st.st_size, st.st_mtime_ns, GT_CACHE)
    cache = ws.data('typeset', 'gt.pkl')
    if cache.exists():
        c = pickle.load(open(cache, 'rb'))
        if c['key'] == key:
            _gt = c['pages']
            return _gt
    from scipy.ndimage import distance_transform_edt
    P = collections.defaultdict(lambda: dict(regions={}, size={}, classes=[], ink={}, look={}, weight={}, balloon={}))
    segs = collections.defaultdict(list)
    sized = collections.defaultdict(dict)    # the size GT has its own region ids: {page: {size id: (px, lo, hi, box)}}
    bold, groups = collections.defaultdict(dict), collections.defaultdict(list)
    for r in json.load(open(ws.GT))['records']:
        s, status, l, p = r['scope'], r.get('status'), r['label'], P[r['page_id']]
        if s == 'merged_bbox' and status == 'canonical':
            xs = [q['x'] for q in l['polygon']]; ys = [q['y'] for q in l['polygon']]
            p['regions'][r['entity_id']] = (min(xs), min(ys), max(xs), max(ys))
        elif s == 'source_font_size' and status == 'canonical':
            lo, hi = l.get('fontSizeIntervalPx') or (l['fontSizePx'], l['fontSizePx'])
            (cx, cy), q = l['cropBounds'][:2], l['bboxInCrop']
            sized[r['page_id']][r['entity_id']] = (float(l['fontSizePx']), float(min(lo, l['fontSizePx'])), float(max(hi, l['fontSizePx'])),
                                                   (cx + q[0], cy + q[1], cx + q[2], cy + q[3]))
        elif s == 'exact_source_font_size_partition' and status == 'canonical':
            groups[r['page_id']] += [c['memberIDs'] for c in l['classes']]
        elif s == 'text_glyph_instance_mask' and status == 'current':
            p['ink'][l['regionID']] = tuple(float(v) for v in l['maskBoundsOriginalImage'])
        elif s == 'source_appearance' and status == 'current':
            o, bg = l['outline'], l.get('background') or {}
            p['look'][l['regionID']] = dict(fill=l['fill'].get('rgb') if l['fill'].get('mode') == 'solid' else None,
                                            outline=bool(o.get('present')), stroke=o.get('rgb') if o.get('present') else None,
                                            width=o.get('widthRelativeToReferenceFont') or 0, bg=bg.get('rgb'))
        elif s == 'source_font_weight' and status == 'current':
            if l['weight'].get('label') in ('regular', 'bold'):
                bold[r['page_id']][l['regionID']] = l['weight']['label'] == 'bold'
        elif s == 'balloon_narration_instance_segmentation' and status == 'current':
            segs[r['page_id']].append(l['segmentation'])
    for pid, p in P.items():
        # size GT region -> the merged region that holds most of its box (>= 50%)
        owner, held = {}, {}
        for sid, (px, lo, hi, box) in sized.get(pid, {}).items():
            area = max(1e-9, (box[2] - box[0]) * (box[3] - box[1]))
            best = max(p['regions'], key=lambda rid: _inter(box, p['regions'][rid]), default=None)
            if best is None or _inter(box, p['regions'][best]) < 0.5 * area:
                continue
            owner[sid] = best
            if _inter(box, p['regions'][best]) > held.get(best, 0):
                held[best] = _inter(box, p['regions'][best]); p['size'][best] = (px, lo, hi)
                if sid in bold.get(pid, {}):
                    p['weight'][best] = bold[pid][sid]
        p['classes'] = [sorted({owner[i] for i in ids if i in owner}) for ids in groups.get(pid, [])]
    for pid, p in P.items():
        boxes, maps = [], []
        for seg in segs.get(pid, []):
            m = _decode(seg)
            ys, xs = np.nonzero(m)
            if not len(xs):
                continue
            x0, y0, x1, y1 = int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1
            crop = m[y0:y1, x0:x1]
            d = np.minimum(distance_transform_edt(np.pad(crop, 1))[1:-1, 1:-1], 255).astype(np.uint8)
            for rid, box in p['regions'].items():
                a = p['ink'].get(rid, box)
                X0, Y0, X1, Y1 = (int(round(v)) for v in a)
                inside = m[max(0, Y0):Y1, max(0, X0):X1].sum() / max(1, (X1 - X0) * (Y1 - Y0))
                if inside >= 0.5 and inside > p['balloon'].get(rid, (0, 0, 0))[1]:
                    p['balloon'][rid] = (len(boxes), float(inside), _edge(d, (a[0] - x0, a[1] - y0, a[2] - x0, a[3] - y0)))
            boxes.append((x0, y0, x1, y1)); maps.append(d)
        if boxes:
            np.savez_compressed(ws.data('typeset', 'balloon', f'{pid}.npz'), boxes=np.array(boxes), **{f'd{i}': d for i, d in enumerate(maps)})
    _gt = {pid: dict(p) for pid, p in P.items()}
    pickle.dump(dict(key=key, pages=_gt), open(cache, 'wb'))
    return _gt


def balloons(pid):
    """[(x0, y0, x1, y1, inside-distance map of the crop)] of the page's GT balloons."""
    if pid not in _balloons:
        f = ws.data('typeset', 'balloon', f'{pid}.npz')
        if f.exists():
            z = np.load(f)
            _balloons[pid] = [(*map(int, b), z[f'd{i}']) for i, b in enumerate(z['boxes'])]
        else:
            _balloons[pid] = []
    return _balloons[pid]


def art(pid, image, regions):
    """(edge cells of the source page outside every GT text box, scale): where painted text would cover art."""
    if pid not in _art:
        f = ws.data('typeset', 'art', f'{pid}.npz')
        if f.exists():
            z = np.load(f)
            _art[pid] = (np.unpackbits(z['bits'])[:int(z['shape'][0]) * int(z['shape'][1])].reshape(z['shape']).astype(bool), float(z['scale']))
        else:
            from PIL import Image
            im = Image.open(image).convert('L')
            w, h = im.size
            s = min(1, ART_SIDE / max(w, h))
            g = np.asarray(im.resize((max(1, int(w * s)), max(1, int(h * s))), Image.BILINEAR), dtype=np.int16)
            gx = np.zeros_like(g); gy = np.zeros_like(g)
            gx[:, 1:-1] = np.abs(g[:, 2:] - g[:, :-2]); gy[1:-1, :] = np.abs(g[2:, :] - g[:-2, :])
            e = (gx + gy) > ART_GRADIENT
            for x0, y0, x1, y1 in regions:
                e[max(0, int(y0 * s) - 1):int(y1 * s) + 2, max(0, int(x0 * s) - 1):int(x1 * s) + 2] = False
            np.savez_compressed(f, bits=np.packbits(e), shape=np.array(e.shape), scale=s)
            _art[pid] = (e, s)
    return _art[pid]


def _inter(a, b):
    return max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
