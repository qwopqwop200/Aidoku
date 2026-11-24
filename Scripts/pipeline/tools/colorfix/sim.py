"""Offline page-style unification on raw S8 styles (AIDOKU_STYLE_NO_UNIFY replay) scored on the colour GT.
usage: sim.py RUN_PREFIX. Also the shared page -> fold map (FOLD: f2, f3, f4, dev, test)."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import MANIFEST  # noqa: E402
import json, os, collections, itertools, statistics
from functools import lru_cache
from errors import gt, de
FOLD = {p['page_id']: p['split'] if p['split'] in ('dev', 'test') else f"f{p['fold']}"
        for p in json.load(open(MANIFEST))['pages']}


@lru_cache(None)
def deq(a, b): return de(a, b)


def rgb(q): return None if q is None else (q['r'], q['g'], q['b'])


def load(prefix):
    G = gt(); pages = {}
    for split in ('dev', 'train', 'test'):
        d = f'{prefix}_{split}/pages'
        for f in os.listdir(d):
            r = json.load(open(os.path.join(d, f))); pid = r['pageID']
            blocks = []
            for b in r['blocks']:
                st = b.get('style')
                if not st: continue
                blocks.append(dict(id=b['id'], bounds=b['bounds'], fill=rgb(st['textColor']), stroke=rgb(st.get('strokeColor')),
                                   width=st.get('strokeWidth') or 0, font=st['fontPixels'], chars=len(b.get('sourceText') or '')))
            # GT matching (same rule as errors.pairs)
            match = []
            for it in G.get(pid, []):
                a, bb, c, e = it['box']; area = max(1e-9, (c - a) * (e - bb)); best, cov = None, 0
                for k, b in enumerate(blocks):
                    (x, y), (w, h) = b['bounds']
                    ix = max(0, min(x + w, c) - max(x, a)) * max(0, min(y + h, e) - max(y, bb)) / area
                    if ix > cov: best, cov = k, ix
                if best is not None and cov >= 0.5: match.append((it, best))
            pages[pid] = (blocks, match)
    return pages


def dist(s, t, P):
    d = deq(s['fill'], t['fill'])
    if s['stroke'] and t['stroke']: d = max(d, P['sw'] * deq(s['stroke'], t['stroke']))
    elif (s['stroke'] is None) != (t['stroke'] is None): d = max(d, P['mis'])
    return d


def unify(blocks, P):
    idx = [i for i, b in enumerate(blocks) if b['chars'] >= P['minc']]
    out = [dict(b) for b in blocks]
    if P['T'] <= 0 or len(idx) < 2: return out
    n = len(idx); D = [[0.0] * n for _ in range(n)]
    for a, b in itertools.combinations(range(n), 2):
        D[a][b] = D[b][a] = dist(blocks[idx[a]], blocks[idx[b]], P)
    # agglomerative, single linkage at threshold T
    groups = [[i] for i in range(n)]
    while True:
        best, pair = None, None
        for x, y in itertools.combinations(range(len(groups)), 2):
            l = min(D[a][b] for a in groups[x] for b in groups[y])
            if l <= P['T'] and (best is None or l < best): best, pair = l, (x, y)
        if not pair: break
        x, y = pair; groups[x] += groups[y]; del groups[y]
    for g in groups:
        if len(g) < 2: continue
        med = min(g, key=lambda i: sum(D[i][j] for j in g))
        outl = [i for i in g if blocks[idx[i]]['stroke']]
        smed = min(outl, key=lambda i: sum(deq(blocks[idx[i]]['stroke'], blocks[idx[j]]['stroke']) for j in outl)) if outl else None
        outline = 2 * len(outl) >= len(g)
        ratios = [blocks[idx[i]]['width'] / max(1, blocks[idx[i]]['font']) for i in outl]
        r = statistics.median(ratios) if ratios else 0
        for i in g:
            o = out[idx[i]]
            o['fill'] = blocks[idx[med]]['fill']
            if outline and smed is not None:
                o['stroke'] = blocks[idx[smed]]['stroke']; o['width'] = r * blocks[idx[i]]['font']
            else:
                o['stroke'] = None; o['width'] = 0
    return out


def score(pages, P):
    c = collections.Counter()
    for pid, (blocks, match) in pages.items():
        f = FOLD[pid]
        out = unify(blocks, P)
        for it, k in match:
            o = out[k]
            c[f, 'n'] += 1
            c[f, 'fill'] += deq(o['fill'], tuple(it['fill'])) > 12
            c[f, 'pres'] += (o['stroke'] is not None) != it['outline']
            c[f, 'scol'] += bool(o['stroke'] and it['stroke'] and deq(o['stroke'], tuple(it['stroke'])) > 20)
    return c


BASE = dict(T=20, sw=0.5, mis=40, minc=4)
if __name__ == '__main__':
    pages = load(sys.argv[1])
    F = ['f2', 'f3', 'f4', 'dev', 'test']
    for name, P in [('off', dict(BASE, T=0)), ('current T20 single', BASE)]:
        c = score(pages, P)
        print(f'{name:22}', ' '.join(f"{f}:{c[f,'fill']}/{c[f,'pres']}/{c[f,'scol']} of {c[f,'n']}" for f in F))
