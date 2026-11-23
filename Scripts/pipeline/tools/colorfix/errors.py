"""Classify S8 colour errors against the appearance GT (numbers only; no images viewed).
usage: errors.py RUN_PREFIX [--list]"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import WORKSPACE, GT, data  # noqa: E402
import json, os, sys, collections, pickle
ROOT = str(WORKSPACE)
CACHE = str(data('colorfix', 'gt.pkl'))


def lab(c):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(float(v)) for v in c)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047; y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))


def de(a, b):
    if a is None or b is None: return None
    return sum((u - v) ** 2 for u, v in zip(lab(a), lab(b))) ** 0.5


def gt():
    if os.path.exists(CACHE): return pickle.load(open(CACHE, 'rb'))
    g = json.load(open(GT))
    out = collections.defaultdict(list)
    for r in g['records']:
        if r.get('scope') != 'source_appearance': continue
        l = r['label']; x0, y0 = l['cropBounds'][:2]
        polys = l.get('individualPolygonsCrop') or [l['mergedPolygonCrop']]
        xs = [p[0] + x0 for q in polys for p in q]; ys = [p[1] + y0 for q in polys for p in q]
        o, bg = l['outline'], l.get('background') or {}
        out[l['page']].append(dict(id=l['itemID'], box=(min(xs), min(ys), max(xs), max(ys)), fill=l['fill']['rgb'],
            mode=l['fill']['mode'], outline=bool(o.get('present')), stroke=o.get('rgb') if o.get('present') else None,
            width=o.get('widthPx') or 0, bg=bg.get('rgb'), bgmode=bg.get('mode'), font=l.get('fontPixels'),
            split=r['links'].get('evaluation_split_evidence', {}).get('split')))
    pickle.dump(dict(out), open(CACHE, 'wb'))
    return dict(out)


def pairs(prefix):
    G = gt(); res = []
    for split in ('dev', 'train', 'test'):
        d = f'{prefix}_{split}/pages'
        if not os.path.isdir(d): continue
        for f in os.listdir(d):
            r = json.load(open(os.path.join(d, f))); pid = r['pageID']
            for it in G.get(pid, []):
                a, b, c, e = it['box']; area = max(1e-9, (c - a) * (e - b)); best, cov = None, 0
                for blk in r['blocks']:
                    (x, y), (w, h) = blk['bounds']
                    ix = max(0, min(x + w, c) - max(x, a)) * max(0, min(y + h, e) - max(y, b)) / area
                    if ix > cov: best, cov = blk, ix
                if best is None or cov < 0.5 or not best.get('style'): continue
                st = best['style']; rgb = lambda q: None if q is None else [q['r'], q['g'], q['b']]
                # other GT items inside the same predicted block
                (x, y), (w, h) = best['bounds']
                mates = [o for o in G[pid] if o is not it and
                         max(0, min(x + w, o['box'][2]) - max(x, o['box'][0])) * max(0, min(y + h, o['box'][3]) - max(y, o['box'][1]))
                         >= 0.5 * (o['box'][2] - o['box'][0]) * (o['box'][3] - o['box'][1])]
                res.append(dict(it, page=pid, run_split=split, pfill=rgb(st.get('textColor')), pstroke=rgb(st.get('strokeColor')),
                                pwidth=st.get('strokeWidth') or 0, pfont=st.get('fontPixels'), role=best.get('role'),
                                chars=len(best.get('sourceText') or ''), block=best['id'], mates=mates))
    return res


def classify(p):
    e = de(p['pfill'], p['fill'])
    if e is None or e <= 12: return None
    mixed = any(de(m['fill'], p['fill']) > 12 for m in p['mates'])
    if mixed: return 'merged-block (mates differ)'
    if p['mode'] != 'solid': return 'gt-multicolor/gradient'
    if p['stroke'] and de(p['pfill'], p['stroke']) < 15: return 'swap: picked outline colour'
    if p['bg'] and de(p['pfill'], p['bg']) < 15: return 'picked background'
    if p['stroke'] and de(p['pfill'], p['stroke']) < e: return 'between fill and outline (blend)'
    if e < 25: return 'near miss 12-25'
    return 'other'


if __name__ == '__main__':
    P = pairs(sys.argv[1])
    print('pairs', len(P), collections.Counter(p['run_split'] for p in P))
    cats = collections.Counter(); ex = collections.defaultdict(list)
    for p in P:
        c = classify(p)
        if c: cats[c] += 1; ex[c].append(p)
    print('fill dE>12:', sum(cats.values()))
    for c, n in cats.most_common(): print(f'  {c}: {n}  splits {dict(collections.Counter(p["run_split"] for p in ex[c]))}')
    # outline presence
    miss = [p for p in P if p['outline'] and p['pstroke'] is None]
    inv = [p for p in P if not p['outline'] and p['pstroke'] is not None]
    print('outline missed', len(miss), 'invented', len(inv), 'of', sum(p['outline'] for p in P), 'outlined GT')
    import statistics as S
    def desc(xs): xs = sorted(xs); return f'med {S.median(xs):.1f} p25 {xs[len(xs)//4]:.1f} p75 {xs[3*len(xs)//4]:.1f}' if xs else '-'
    hit = [p for p in P if p['outline'] and p['pstroke'] is not None]
    for name, grp in (('missed', miss), ('caught', hit)):
        print(f' {name}: width {desc([p["width"] for p in grp])} | width/font {desc([p["width"]/max(1,p["font"] or 1) for p in grp])} | '
              f'stroke-vs-bg dE {desc([de(p["stroke"], p["bg"]) for p in grp if p["bg"]])} | stroke-vs-fill dE {desc([de(p["stroke"], p["fill"]) for p in grp])}')
    print(' missed with mates outlined differently:', sum(any(m['outline'] != p['outline'] for m in p['mates']) for p in miss))
    print(' missed chars<4:', sum(p['chars'] < 4 for p in miss))
    if '--list' in sys.argv:
        for c in cats:
            for p in ex[c][:12]:
                print(c[:10], p['id'], p['run_split'], 'gt', p['fill'], 'st', p['stroke'], 'bg', p['bg'], '-> pred', p['pfill'], p['pstroke'], f"dE {de(p['pfill'], p['fill']):.0f}", 'font', p['font'], 'chars', p['chars'])
