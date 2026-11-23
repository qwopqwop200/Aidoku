"""V2 lines (after S2b assembly) vs GT individual line boxes: fragmented / over-joined / missed per fold (numbers only).
usage: score.py RUN_PREFIX (dirs PREFIX_dev, PREFIX_train[, PREFIX_test])"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import GT, data  # noqa: E402
import json, os, sys, collections, pickle
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'colorfix'))
from sim import FOLD
CACHE = str(data('lineasm', 'gt_lines.pkl'))


def gt():
    if os.path.exists(CACHE): return pickle.load(open(CACHE, 'rb'))
    g = json.load(open(GT))
    G = collections.defaultdict(list)
    for r in g['records']:
        if r['scope'] == 'individual_premerge_bbox' and r.get('status') == 'canonical':
            p = r['label']['polygon']; xs = [q['x'] for q in p]; ys = [q['y'] for q in p]
            G[r['page_id']].append((min(xs), min(ys), max(xs), max(ys)))
    pickle.dump(dict(G), open(CACHE, 'wb')); return dict(G)


def inside(a, b):  # share of box a inside box b
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    return ix / max(1e-9, (a[2] - a[0]) * (a[3] - a[1]))


def score(prefix, splits=('dev', 'train', 'test')):
    G = gt(); c = collections.Counter()
    for s in splits:
        d = f'{prefix}_{s}/pages'
        if not os.path.isdir(d): continue
        for f in os.listdir(d):
            r = json.load(open(os.path.join(d, f))); pid = r['pageID']; fo = FOLD[pid]
            lines = []
            for b in r['blocks']:
                for l in b['lines']:
                    (x, y), (w, h) = l['bounds']; lines.append((x, y, x + w, y + h))
            for gb in G.get(pid, []):
                members = [l for l in lines if inside(l, gb) >= 0.5]
                cov = max([inside(gb, l) for l in lines], default=0)
                c[fo, 'gt'] += 1
                if len(members) > 1: c[fo, 'fragmented'] += 1
                if not members and cov < 0.5: c[fo, 'missed'] += 1
            for l in lines:
                if sum(inside(gb, l) >= 0.5 for gb in G.get(pid, [])) > 1: c[fo, 'overjoined'] += 1
    return c


if __name__ == '__main__':
    for p in sys.argv[1:]:
        c = score(p)
        print(p.split('/')[-1], ' '.join(f"{f}: frag {c[f,'fragmented']} over {c[f,'overjoined']} miss {c[f,'missed']} /{c[f,'gt']}" for f in ['f2', 'f3', 'f4', 'dev', 'test']))
