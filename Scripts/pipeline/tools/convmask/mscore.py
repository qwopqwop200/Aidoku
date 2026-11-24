"""mscore.py DUMP_DIR [RUN_PREFIX] -> per-page mask metrics vs GT glyph masks (pixels in code only).
targeted region: GT glyph region with >= 50% of its pixels inside the bounds of a paintable block.
resid region = targeted region with miss > 2% of its px; far = mask px > 3 px (Chebyshev) from every GT glyph px;
art = far px on a strong original-image gradient (|dx|+|dy| > 48)."""
import json, sys, zlib, collections
import multiprocessing as mp
from pathlib import Path
import numpy as np
from PIL import Image
import cv2
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace import RUNS  # noqa: E402
import blocks
from blocks import META, S
PREFIX = str(RUNS / 'imp/rescue')
FOLDS = {1: 'dev', 2: 'f2', 3: 'f3', 4: 'f4', 0: 'test'}


def record(pid, prefix):
    for sp in ('dev', 'train', 'test'):
        f = Path(f'{prefix}_{sp}/pages/{pid}.json')
        if f.exists(): return json.load(open(f))


def page(args):
    dump, pid, prefix = args
    m = META[pid]; w, h = m['w'], m['h']
    js = json.load(open(dump / f'{pid}.json'))
    if (js['w'], js['h']) != (w, h):
        return pid, None
    M = np.frombuffer(zlib.decompress(open(dump / f'{pid}.z', 'rb').read(), -15), np.uint8).reshape(h, w) > 0
    lab = np.load(S / 'gt' / f'{pid}.npz')['lab']
    rec = record(pid, prefix)
    ids = set(js['ids'])
    inb = np.zeros((h, w), bool)
    for b in rec['blocks']:
        if int(b['id']) in ids:
            (x, y), (bw, bh) = b['bounds']
            inb[max(0, int(y)):int(y + bh) + 1, max(0, int(x)):int(x + bw) + 1] = True
    G = lab > 0
    r = collections.Counter()
    n = np.bincount(lab.ravel(), minlength=len(m['regs']) + 1)
    nin = np.bincount(lab[inb].ravel(), minlength=len(m['regs']) + 1)
    nmiss = np.bincount(lab[~M].ravel(), minlength=len(m['regs']) + 1)
    for k in range(1, len(n)):
        if n[k] and nin[k] >= 0.5 * n[k]:
            r['tgt'] += 1; r['tgtPx'] += int(n[k]); r['miss'] += int(nmiss[k])
            r['resid'] += int(nmiss[k] > 0.02 * n[k])
            r['resid10'] += int(nmiss[k] > 0.10 * n[k])
            r[f'reg{k}'] = round(float(nmiss[k] / n[k]), 4)
    far = M & ~(cv2.dilate(G.astype(np.uint8), np.ones((7, 7), np.uint8)) > 0)
    g = np.asarray(Image.open(rec['image']).convert('L'), np.int16)
    gr = np.zeros_like(g)
    gr[1:-1, 1:-1] = np.abs(g[1:-1, 2:] - g[1:-1, :-2]) + np.abs(g[2:, 1:-1] - g[:-2, 1:-1])
    r['far'] = int(far.sum()); r['art'] = int((far & (gr > 48)).sum()); r['mask'] = int(M.sum())
    # farA/artA: far px inside the frames of blocks whose line polygons hold GT glyph px (annotated blocks);
    # far px elsewhere may be unannotated text.
    ann = np.zeros((h, w), bool)
    for b in blocks.load(pid)[1]:
        x0, y0, bw, bh = b['frame']
        if (G[y0:y0 + bh, x0:x0 + bw] & (b['poly'] > 0)).any(): ann[y0:y0 + bh, x0:x0 + bw] = True
    r['farA'] = int((far & ann).sum()); r['artA'] = int((far & ann & (gr > 48)).sum())
    return pid, dict(r)


def run(dump, prefix=None):
    # Spawned workers re-import this module, so the run prefix travels with each task, not as a global.
    dump = Path(dump); prefix = prefix or PREFIX
    cache = dump / 'mscore.json'
    if cache.exists(): return json.load(open(cache))
    pids = sorted(p.stem for p in dump.glob('*.z') if p.stem in META)
    with mp.get_context("spawn").Pool(8) as pool:
        res = dict(x for x in pool.map(page, [(dump, p, prefix) for p in pids]) if x[1] is not None)
    json.dump(res, open(cache, 'w'))
    return res


def table(res):
    agg = collections.defaultdict(collections.Counter)
    for pid, r in res.items():
        f = FOLDS[META[pid]['fold']]
        r = {k: v for k, v in r.items() if not k.startswith('reg')}
        agg[f].update(r); agg['all'].update(r)
        if f in ('f2', 'f3', 'f4'): agg['train'].update(r)
    for f in ['f2', 'f3', 'f4', 'train', 'dev', 'test', 'all']:
        a = agg[f]
        if not a: continue
        print(f"{f:5s}: pages {sum(1 for p in res if FOLDS[META[p]['fold']] == f) if f not in ('all','train') else ''} tgt {a['tgt']} "
              f"recall {1 - a['miss'] / max(1, a['tgtPx']):.5f} resid>2% {a['resid']} resid>10% {a['resid10']} "
              f"far {a['far']} art {a['art']} farA {a['farA']} artA {a['artA']} mask {a['mask']}")


if __name__ == '__main__':
    res = run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None); table(res)
