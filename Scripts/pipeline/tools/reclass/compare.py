#!/usr/bin/env python3
"""Mechanical reclass decision: compare.py BASE_PREFIX VAR_PREFIX [--json OUT]

Prefixes name run dirs PREFIX_dev and PREFIX_train (or pass a,b dirs joined by ','). Per page, per metric,
gain = max(0, improvement), loss = max(0, worsening); pooled train(folds 2,3,4)+dev, also per fold.
"""
import collections, json, sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace import MANIFEST  # noqa: E402
import score

MAN = str(MANIFEST)
FOLD = {p['page_id']: (1 if p['split'] == 'dev' else p.get('fold')) for p in json.load(open(MAN))['pages'] if p['split'] != 'test'}
LOWER = ['cut', 'kin', 'pun', 'lt06', 'ovl', 'out5', 'art5', 'wrong', 'dist2']  # fewer = gain


def dirs(prefix):
    if ',' in prefix:
        return prefix.split(',')
    return [prefix + '_dev', prefix + '_train']


def load(prefix):
    out = {}
    for d in dirs(prefix):
        out.update(score.run(d))
    return out


def changed(a, b):
    """Blocks or placements present in one run and not in the other (the larger count)."""
    sigs = [collections.Counter(json.dumps(x) for x in r['sig']) for r in (a, b)]
    out = 0
    for kind in ('["p"', '["b"'):
        x, y = (collections.Counter({k: n for k, n in c.items() if k.startswith(kind)}) for c in sigs)
        out = max(out, (x - y).total(), (y - x).total())
    return out


def compare(base, var):
    B, V = load(base), load(var)
    pages = sorted(set(B) & set(V))
    assert len(pages) == len(B) == len(V), (len(pages), len(B), len(V))
    g = collections.defaultdict(lambda: collections.Counter()); l = collections.defaultdict(lambda: collections.Counter())
    nchg = collections.Counter(); chpages = []
    for pid in pages:
        a, b, f = B[pid], V[pid], FOLD[pid]
        c = changed(a, b)
        nchg[f] += c
        if c:
            chpages.append(pid)
        def tally(k, d):
            if d > 0: g[f][k] += d
            elif d < 0: l[f][k] -= d
        for k in LOWER + (['lineout5'] if '--lines' in sys.argv else []):
            tally(k, a.get(k, 0) - b.get(k, 0))
        tally('exact', b.get('exact', 0) - a.get('exact', 0))
        tally('lt025', b['lt025'] - a['lt025'])
        tally('src', a['src'] - b['src'])
        for t, k in ((1.10, 'cons10'), (1.25, 'cons25')):
            for key in set(a['cons']) | set(b['cons']):
                wa = a['cons'].get(key, 9) <= t; wb = b['cons'].get(key, 9) <= t
                if wb and not wa: g[f][k] += 1
                elif wa and not wb: l[f][k] += 1
    return B, V, pages, g, l, nchg, chpages


def report_only(P, pages):
    def cat(k): return [x for p in pages for x in P[p][k]]
    d, r = cat('dists'), cat('risks')
    return dict(vert=sum(P[p]['vert'] for p in pages), fill=round(float(np.median(cat('fills'))), 3) if cat('fills') else 0,
                ratio=round(float(np.median(cat('ratios'))), 3), vsGT=round(float(np.median(cat('vsgt'))), 3),
                distP90=round(float(np.percentile(d, 90)), 3) if d else 0, art=round(float(np.mean(r)), 4) if r else 0,
                frag=sum(P[p].get('frag', 0) for p in pages))


def main():
    base, var = sys.argv[1], sys.argv[2]
    B, V, pages, g, l, nchg, chpages = compare(base, var)
    G = sum(g.values(), collections.Counter()); L = sum(l.values(), collections.Counter())
    gains, losses, nb = sum(G.values()), sum(L.values()), sum(nchg.values())
    noise = max(3, 0.01 * nb)
    net = gains - losses
    items = gains + losses
    if net > noise: cls = 'B'
    elif items < noise: cls = 'A (효과 없음)'
    else: cls = 'A (손해>=이득)'
    print(f'{var} vs {base}: changed blocks {nb} on {len(chpages)} pages, noise {noise:.1f}')
    print(f'  net {net:+d} = gains {gains} - losses {losses} -> {cls}')
    ints = lambda c: {k: int(v) for k, v in c.items()}
    print('  gains ', ints(G)); print('  losses', ints(L))
    for f in sorted(set(nchg)):
        print(f'  fold{f}: changed {nchg[f]} gains {dict(g[f])} losses {dict(l[f])}')
    for name, P in (('base', B), ('var', V)):
        for f in (1, 2, 3, 4):
            ps = [p for p in pages if FOLD[p] == f]
            print(f'  {name} fold{f} report-only', report_only(P, ps))
    if '--json' in sys.argv:
        json.dump(dict(base=base, var=var, net=int(net), gains=ints(G), losses=ints(L), changed=nb, noise=noise, cls=cls,
                       pages=chpages, folds={f: dict(g=ints(g[f]), l=ints(l[f]), changed=nchg[f]) for f in nchg}),
                  open(sys.argv[sys.argv.index('--json') + 1], 'w'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
