#!/usr/bin/env python3
"""Reclass scorer: per-page item counts for one run dir (cached under RUNS/reclass/cache).

Uses the render / balloon / consistency / place / align / merge-GT metrics, plus a GT source-text check: a block
is "bad" when its source letters (NFKC letters and digits) differ from those of the GT regions it covers.
"""
import collections, json, sys, unicodedata
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import render_metrics as rm, balloon_metrics as bm, consistency_metrics as cm, place_metrics as pm
import merge_gt_eval as mg, align_metrics as am
from workspace import GT as _GT, EVAL, RUNS  # noqa: E402

GT = str(_GT)
_src = {}
_small = None
_load = json.load


def _cached_load(f, *a, **k):
    global _small
    if getattr(f, 'name', None) == GT:
        if _small is None:
            import pickle
            _small = pickle.load(open(EVAL / 'reclass/gt_small.pkl', 'rb'))
        return _small
    return _load(f, *a, **k)


json.load = _cached_load  # every GT load (here and in the metric modules) reads the pickled subset


def gt_source():
    if not _src:
        for r in json.load(open(GT))['records']:
            if r['scope'] == 'merged_bbox' and r.get('status') == 'canonical':
                xs = [p['x'] for p in r['label']['polygon']]; ys = [p['y'] for p in r['label']['polygon']]
                _src.setdefault(r['page_id'], []).append(((min(xs), min(ys), max(xs), max(ys)), r['label'].get('source') or ''))
    return _src


def letters(s):
    s = unicodedata.normalize('NFKC', s)
    return collections.Counter(c for c in s if unicodedata.category(c)[0] in 'LN')


def src_bad(r):
    regs = gt_source().get(r['pageID'], [])
    bad = 0
    for b in r['blocks']:
        (x, y), (w, h) = b['bounds']
        got = collections.Counter()
        for (a, c, d, e), text in regs:
            ix = max(0, min(x + w, d) - max(x, a)) * max(0, min(y + h, e) - max(y, c))
            if ix >= 0.5 * max(1e-9, (d - a) * (e - c)):
                got += letters(text)
        have = letters(b.get('sourceText') or '')
        if not have:
            continue
        bad += (have - got).total() + (got - have).total() > 0
    return bad


def sig(r):
    blocks = {b['id']: b for b in r['blocks']}
    out = []
    for b in r['blocks']:
        out.append(('b', tuple(round(v) for v in b['bounds'][0] + b['bounds'][1]), b.get('sourceText')))
    for p in r['placed']:
        b = blocks.get(p['blockID'], {})
        out.append(('p', tuple(round(v) for v in b.get('bounds', [[0, 0], [0, 0]])[0]),
                    tuple(round(v, 1) for v in p['frame'][0] + p['frame'][1]), round(p['fontPixels'], 2),
                    tuple(p['lines']), p['vertical']))
    return out


def run(path):
    path = str(path).rstrip('/')
    cache = Path(RUNS / 'reclass/cache', path.replace('/', '_') + '.json')
    cache.parent.mkdir(exist_ok=True)
    if cache.exists():
        return json.load(open(cache))
    pages = {}
    recs = {}
    for f in sorted(Path(path, 'pages').glob('*.json')):
        r = json.load(open(f))
        recs[r['pageID']] = r
        pages[r['pageID']] = dict(lineout5=0, cut=0, kin=0, pun=0, lt06=0, ovl=0, vert=0, out5=0, art5=0, dist2=0,
                                  dists=[], risks=[], fills=[], ratios=[], vsgt=[], cons={}, lt025=0, pairs=0,
                                  src=src_bad(r), sig=[list(map(lambda v: list(v) if isinstance(v, tuple) else v, s)) for s in sig(r)])
    for row in rm.analyze(path):
        p = pages[row['page']]
        p['cut'] += row['cuts'] > 0; p['kin'] += row['kin']; p['pun'] += row['pun']; p['vert'] += row['vertical']
        p['ovl'] += row.get('pageOverlaps', 0)
        if row['ratio']:
            p['ratios'].append(row['ratio']); p['lt06'] += row['ratio'] < 0.6
    # balloon: frame > 5% outside its GT balloon, frame / balloon area
    seg = collections.defaultdict(list)
    for rec in json.load(open(GT))['records']:
        if rec['scope'] == 'balloon_narration_instance_segmentation' and rec.get('page_id') in recs:
            seg[rec['page_id']].append(rec['label']['segmentation'])
    for pid, r in recs.items():
        masks = [(m, int(m.sum())) for m in map(bm.decode, seg.get(pid, [])) if m.any()]
        blocks = {b['id']: b for b in r['blocks']}
        syn = set(r.get('replaySyntheticBlocks') or [])
        for pl in r['placed']:
            if pl['blockID'] in syn:
                continue
            b = blocks[pl['blockID']]
            (bx, by), (bw, bh) = b['bounds']
            x0, y0, x1, y1 = int(bx), int(by), int(bx + bw) + 1, int(by + bh) + 1
            best = None
            for m, area in masks:
                sub = m[max(0, y0):y1, max(0, x0):x1]
                cov = sub.sum() / max(1, (x1 - x0) * (y1 - y0))
                if cov >= 0.5 and (best is None or cov > best[0]):
                    best = (cov, m, area)
            if best is None:
                continue
            (fx, fy), (fw, fh) = pl['frame']
            X0, Y0 = max(0, int(round(fx))), max(0, int(round(fy)))
            X1, Y1 = int(round(fx + fw)), int(round(fy + fh))
            inside = best[1][Y0:Y1, X0:X1].sum()
            tot = max(1, (X1 - X0) * (Y1 - Y0))
            pages[pid]['out5'] += (1 - inside / tot) > 0.05
            pages[pid]['fills'].append(float(tot / best[2]))
            # Line ink rectangles (approximate advances), aligned left for leading else centred.
            if not pl['vertical']:
                size = pl['fontPixels']; lead = pl.get('leading', b.get('role') == 'narration')
                for k, text in enumerate(pl['lines']):
                    adv = sum(1 if ord(ch) > 0x2E80 else 0.3 if ch == ' ' else 0.55 for ch in text) * size * (pl.get('condense') or 1)
                    lx0 = fx if lead else fx + fw / 2 - adv / 2
                    ly0 = fy + k * size * 1.18
                    A0, B0, A1, B1 = max(0, int(lx0)), max(0, int(ly0)), int(lx0 + adv), int(ly0 + size * 1.18)
                    t2 = max(1, (A1 - A0) * (B1 - B0))
                    pages[pid]['lineout5'] += (1 - best[1][B0:B1, A0:A1].sum() / t2) > 0.05
    for pid, r in recs.items():
        spreads, ratios = cm.page(r)
        pages[pid]['vsgt'] += ratios
        for px, ids, spread in spreads:
            pages[pid]['cons'][f'{px}:{",".join(ids)}'] = spread
        for dist, risk in pm.page(r):
            if dist is not None:
                pages[pid]['dists'].append(dist); pages[pid]['dist2'] += dist > 2
            pages[pid]['risks'].append(risk); pages[pid]['art5'] += risk > 0.05
    # align pairs
    for pid, r in recs.items():
        prs = am.gt_pairs(r)
        if not prs:
            continue
        placed = {p['blockID']: p for p in r['placed']}
        for a, b in prs:
            if a in placed and b in placed:
                pa, pb = placed[a], placed[b]
                em = (pa['fontPixels'] + pb['fontPixels']) / 2
                pages[pid]['pairs'] += 1
                pages[pid]['lt025'] += abs(pa['frame'][0][1] - pb['frame'][0][1]) / em < 0.25
    # merge GT
    for row in mg.score([path]):
        p = pages[row['page']]
        p['exact'] = int(row['exact']); p['wrong'] = len(row['wrongJoins']); p['frag'] = len(row['fragmented'])
    json.dump(pages, open(cache, 'w'), default=lambda o: o.item() if hasattr(o, 'item') else str(o))
    return pages


if __name__ == '__main__':
    for a in sys.argv[1:]:
        p = run(a)
        print(a, len(p), sum(v['cut'] for v in p.values()), sum(v['src'] for v in p.values()))
