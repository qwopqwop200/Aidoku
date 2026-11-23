"""Offline page-style unification on raw S8 styles (AIDOKU_STYLE_NO_UNIFY replay) scored on the colour GT."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import MANIFEST  # noqa: E402
import json, os, sys, collections, itertools
from functools import lru_cache
from errors import gt, de, lab, ROOT
MAN = str(MANIFEST)
FOLD = {p['page_id']: ('dev' if p['split'] == 'dev' else 'test' if p['split'] == 'test' else f"f{p['fold']}") for p in json.load(open(MAN))['pages']}


@lru_cache(None)
def deq(a, b): return de(a, b)


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
                t = lambda q: None if q is None else (q['r'], q['g'], q['b'])
                blocks.append(dict(id=b['id'], bounds=b['bounds'], fill=t(st['textColor']), stroke=t(st.get('strokeColor')),
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
    # agglomerative: single / complete / average linkage at threshold T
    groups = [[i] for i in range(n)]
    def link(g, h):
        v = [D[a][b] for a in g for b in h]
        return min(v) if P['link'] == 'single' else max(v) if P['link'] == 'complete' else sum(v) / len(v)
    while True:
        best, pair = None, None
        for x, y in itertools.combinations(range(len(groups)), 2):
            l = link(groups[x], groups[y])
            if l <= P['T'] and (best is None or l < best): best, pair = l, (x, y)
        if not pair: break
        x, y = pair; groups[x] += groups[y]; del groups[y]
    for g in groups:
        if len(g) < 2: continue
        med = min(g, key=lambda i: sum(D[i][j] for j in g))
        outl = [i for i in g if blocks[idx[i]]['stroke']]
        smed = min(outl, key=lambda i: sum(deq(blocks[idx[i]]['stroke'], blocks[idx[j]]['stroke']) for j in outl)) if outl else None
        outline = 2 * len(outl) >= len(g)
        ratios = sorted(blocks[idx[i]]['width'] / max(1, blocks[idx[i]]['font']) for i in outl)
        r = (ratios[len(ratios) // 2] if len(ratios) % 2 else (ratios[len(ratios) // 2 - 1] + ratios[len(ratios) // 2]) / 2) if ratios else 0
        for i in g:
            o = out[idx[i]]
            if not P.get('keepfill'): o['fill'] = blocks[idx[med]]['fill']
            if outline and smed is not None:
                o['stroke'] = blocks[idx[smed]]['stroke']; o['width'] = r * blocks[idx[i]]['font']
            else:
                o['stroke'] = None; o['width'] = 0
    return out


def score(pages, P, folds=None):
    c = collections.Counter()
    for pid, (blocks, match) in pages.items():
        f = FOLD[pid]
        if folds and f not in folds: continue
        out = unify(blocks, P)
        for it, k in match:
            o = out[k]; key = f
            c[key, 'n'] += 1
            c[key, 'fill'] += deq(o['fill'], tuple(it['fill'])) > 12
            c[key, 'pres'] += (o['stroke'] is not None) != it['outline']
            c[key, 'scol'] += bool(o['stroke'] and it['stroke'] and deq(o['stroke'], tuple(it['stroke'])) > 20)
    return c


def total(c, folds, keys=('fill', 'pres', 'scol')):
    return sum(c[f, k] for f in folds for k in keys)


BASE = dict(T=20, link='single', sw=0.5, mis=40, minc=4)
if __name__ == '__main__':
    pages = load(sys.argv[1])
    F = ['f2', 'f3', 'f4', 'dev', 'test']
    for name, P in [('off', dict(BASE, T=0)), ('current T20 single', BASE)]:
        c = score(pages, P)
        print(f'{name:22}', ' '.join(f"{f}:{c[f,'fill']}/{c[f,'pres']}/{c[f,'scol']} of {c[f,'n']}" for f in F))
