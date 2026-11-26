"""Training-data augmentation shared by the retrain/<part> trainers (training only; the app is unchanged).

Two kinds, both meant to make a part less tied to one exact upstream output:
  1. mixing real upstream variants: train on the union of several host runs whose upstream differs (for example S3
     lines before and after the line-box refinement, or an older S2b/S4), see RUNS below and `mixed_pages`;
  2. S3 jitter: move each S3 line box by a draw from the measured S3-vs-GT box error, so a part sees boxes as varied as
     the detector really produces (`Jitter`).

S3 error model: per GT-matched train line (IoU >= 0.5, greedy), the outward offset of each edge of the S3 box from the
GT box in line thicknesses, in reading order (along start, along end, cross start, cross end; along = y for vertical
lines). A jittered box is box + scale * (a - b) / sqrt(2) * thickness for two draws a, b of the same orientation: the
difference of two errors keeps the measured spread and edge correlations without knowing the line's own error.
"""
import collections, json, math, os, pickle
from pathlib import Path

import numpy as np

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import workspace as ws  # noqa: E402

# Real upstream variants (RUN_PREFIX -> what differs). Runs live under $AIDOKU_EVAL_DIR/runs; check they exist.
RUNS = {
    'speed2/all830': 'full; S3 before the line-box refinement (current S2b/keep/S4/S4b/S8 of 2026-11-25)',
    'retune/snap2/ref': 'full; S3 refined + pre-refine sizing geometry (measure), snap1-retrained S4/S4b/S8',
    'retune/snap1/ref': 'full; S3 refined, old S4/S4b/S8 resources',
    'speed2/base830': 'full; old S2b assembly and old S4 (before the 2026-11-25 stage port)',
    'speed2/keep830': 'S1-S4b (--ocr-only); keep gate, no refinement',
    'speed2/lb830': 'S1-S4b (--ocr-only); keep gate + refinement',
}
SPLITS = ('train', 'dev', 'test')


def run_path(name):
    return ws.RUNS / name


def available(names=None):
    """The RUNS (or `names`) whose _train directory exists, as absolute prefixes."""
    out = []
    for n in names or RUNS:
        p = Path(n) if os.path.isabs(n) else run_path(n)
        if Path(f'{p}_train').is_dir():
            out.append(str(p))
    return out


def gt_lines():
    """{page: [GT line box x0,y0,x1,y1]} (individual_premerge_bbox, canonical), cached per GT file version."""
    st = os.stat(ws.GT)
    key = (str(ws.GT), st.st_size, st.st_mtime_ns)
    cache = ws.data('retrain', 'augment', 'gt_lines.pkl')
    if cache.exists():
        c = pickle.load(open(cache, 'rb'))
        if c['key'] == key:
            return c['lines']
    out = collections.defaultdict(list)
    for r in json.load(open(ws.GT))['records']:
        if r['scope'] == 'individual_premerge_bbox' and r.get('status') == 'canonical':
            xs = [p['x'] for p in r['label']['polygon']]; ys = [p['y'] for p in r['label']['polygon']]
            out[r['page_id']].append((min(xs), min(ys), max(xs), max(ys)))
    out = dict(out)
    pickle.dump(dict(key=key, lines=out), open(cache, 'wb'))
    return out


def rect(b):
    """Swift CGRect JSON [[x, y], [w, h]] -> (x0, y0, x1, y1)."""
    (x, y), (w, h) = b
    return (x, y, x + w, y + h)


def _iou(a, b):
    iw = min(a[2], b[2]) - max(a[0], b[0]); ih = min(a[3], b[3]) - max(a[1], b[1])
    if iw <= 0 or ih <= 0:
        return 0.0
    i = iw * ih
    return i / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i)


def edge_offsets(box, vertical, ref):
    """Outward offsets of `box` from `ref` in thicknesses of `box`: (along0, along1, cross0, cross1)."""
    x0, y0, x1, y1 = box; g0, h0, g1, h1 = ref
    th = max(1e-6, (x1 - x0) if vertical else (y1 - y0))
    if vertical:
        return ((h0 - y0) / th, (y1 - h1) / th, (g0 - x0) / th, (x1 - g1) / th)
    return ((g0 - x0) / th, (x1 - g1) / th, (h0 - y0) / th, (y1 - h1) / th)


def apply_offsets(box, vertical, off):
    """`box` with each edge moved outward by off (along0, along1, cross0, cross1) thicknesses of `box`."""
    x0, y0, x1, y1 = box
    th = (x1 - x0) if vertical else (y1 - y0)
    a0, a1, c0, c1 = (o * th for o in off)
    if vertical:
        return (x0 - c0, y0 - a0, x1 + c1, y1 + a1)
    return (x0 - a0, y0 - c0, x1 + a1, y1 + c1)


def residuals(prefix, field=None, splits=('train',)):
    """{'v': array (n, 4), 'h': array (n, 4)} of S3-vs-GT edge offsets on the run's train pages (see module doc).
    field: the front.json line list (default: `unrefined` when present, else `recognized`). Cached per run."""
    tag = Path(prefix).name + '-' + Path(prefix).parent.name + '-' + (field or 'auto') + '-' + '+'.join(splits)
    cache = ws.data('retrain', 'augment', f'res-{tag}.pkl')
    if cache.exists():
        return pickle.load(open(cache, 'rb'))
    gt = gt_lines()
    out = {'v': [], 'h': []}
    for split in splits:
        d = Path(f'{prefix}_{split}') / 'stages'
        for fn in sorted(d.glob('*.front.json')):
            pid = fn.name.split('.')[0]
            if pid not in gt:
                continue
            f = json.load(open(fn))
            src = field or ('unrefined' if f.get('unrefined') is not None else 'recognized')
            lines = [(rect(l['bounds']), bool(l['vertical'])) for l in (f.get(src) or [])]
            pairs = sorted(((_iou(b, g), i, j) for i, (b, _) in enumerate(lines) for j, g in enumerate(gt[pid])), reverse=True)
            used_l, used_g = set(), set()
            for v, i, j in pairs:
                if v < 0.5:
                    break
                if i in used_l or j in used_g:
                    continue
                used_l.add(i); used_g.add(j)
                b, vert = lines[i]
                out['v' if vert else 'h'].append(edge_offsets(b, vert, gt[pid][j]))
    res = {k: np.clip(np.array(v, float).reshape(-1, 4), -1.5, 1.5) for k, v in out.items()}
    pickle.dump(res, open(cache, 'wb'))
    return res


class Jitter:
    """Draws plausible alternative S3 boxes (module doc). scale 0 = identity."""

    def __init__(self, res, scale=1.0, seed=0, edges=(0, 1, 2, 3)):
        self.res, self.scale, self.rng = res, scale, np.random.default_rng(seed)
        self.mask = np.array([1.0 if k in edges else 0.0 for k in range(4)])

    def offsets(self, vertical):
        r = self.res['v' if vertical else 'h']
        if self.scale == 0 or len(r) < 2:
            return (0.0, 0.0, 0.0, 0.0)
        a, b = r[self.rng.integers(len(r), size=2)]
        return tuple(self.scale * (a - b) / math.sqrt(2) * self.mask)

    def box(self, box, vertical):
        nb = apply_offsets(box, vertical, self.offsets(vertical))
        if nb[2] - nb[0] < 2 or nb[3] - nb[1] < 2:
            return tuple(box)
        return nb

    def line(self, line):
        """A Swift-checkpoint line dict (bounds [[x,y],[w,h]], polygon [[x,y],...]) with a jittered box; the polygon
        is mapped per axis onto the new box (as the app's refinement does)."""
        ob = rect(line['bounds']); nb = self.box(ob, bool(line['vertical']))
        out = dict(line)
        out['bounds'] = [[nb[0], nb[1]], [nb[2] - nb[0], nb[3] - nb[1]]]
        sx = (nb[2] - nb[0]) / max(ob[2] - ob[0], 1e-6); sy = (nb[3] - nb[1]) / max(ob[3] - ob[1], 1e-6)
        out['polygon'] = [[nb[0] + (p[0] - ob[0]) * sx, nb[1] + (p[1] - ob[1]) * sy] for p in line['polygon']]
        return out

    def block(self, block):
        """A checkpoint/page block dict with jittered lines and bounds = union of the jittered line polygons."""
        out = dict(block)
        out['lines'] = [self.line(l) for l in block['lines']]
        pts = [p for l in out['lines'] for p in l['polygon']]
        if pts:
            xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
            out['bounds'] = [[min(xs), min(ys)], [max(xs) - min(xs), max(ys) - min(ys)]]
        return out


def summary(res):
    """Numbers only: count, median |offset| and std per edge per orientation."""
    return {k: dict(n=len(v), med=np.round(np.median(np.abs(v), 0), 4).tolist(), std=np.round(v.std(0), 4).tolist())
            for k, v in res.items() if len(v)}


if __name__ == '__main__':
    for p in available():
        print(p, summary(residuals(p)))
